#if DEBUG || PERF_PROBE
import Dispatch
import Foundation
import LivCore
import os

/// Read-only timing probe: `LivVitals -LivPerfProbe <cleanup|smartcare|spacelens|uninstaller> [-LivPerfRuns 2]` runs one
/// scan with the real services, prints one JSON line per run (seconds, files visited, items found, the longest time the
/// main thread did not answer, plus `ok` and, on failure, `error`) and quits with status 1 when any run failed. Peak memory comes from `/usr/bin/time -l` around the whole process.
/// `scripts/perf-probe.sh` builds it (Release with `-DPERF_PROBE`) and runs the three scenarios. It changes nothing on disk.
enum PerfProbe {
    static func runIfRequested() {
        guard let scenario = UserDefaults.standard.string(forKey: "LivPerfProbe") else { return }
        let runs = max(1, UserDefaults.standard.integer(forKey: "LivPerfRuns"))
        Task { @MainActor in
            let stalls = StallMonitor()
            stalls.start()
            var failed = false
            for run in 1...runs {
                stalls.reset()
                let result = await measure(scenario)
                if result.error != nil { failed = true }
                var line: [String: Any] = [
                    "scenario": scenario,
                    "run": run,
                    "seconds": (result.seconds * 100).rounded() / 100,
                    "filesVisited": result.files,
                    "items": result.items,
                    "maxMainThreadStallMs": stalls.maxStallMilliseconds,
                    "ok": result.error == nil,
                ]
                if let error = result.error { line["error"] = error }
                if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                    fflush(stdout)
                }
            }
            exit(failed ? 1 : 0)
        }
    }

    private struct Measurement {
        var seconds: Double
        var files = 0
        var items = 0
        var error: String?
    }

    private static func measure(_ scenario: String) async -> Measurement {
        let services = ServiceContainer.live
        let home = services.home
        let clock = ContinuousClock()
        let visited = OSAllocatedUnfairLock(initialState: 0)
        let start = clock.now
        var result = Measurement(seconds: 0)
        switch scenario {
        case "spacelens":
            do {
                let tree = try await services.diskTree.tree(at: home, depth: 2, onProgress: { progress in
                    visited.withLock { $0 = progress.filesVisited }
                })
                result.files = visited.withLock { $0 }
                result.items = tree.node.children.count
            } catch {
                result.error = error.localizedDescription
            }
        case "cleanup", "smartcare", "uninstaller":
            let module: AppModule = scenario == "cleanup" ? .cleanup : scenario == "smartcare" ? .smartCare : .applications
            let options = ScanOptions(projectRoots: [home.appending(path: "personal"), home.appending(path: "Developer")])
            do {
                let scan = try await services.cleanup.scan(module: module, options: options, onUpdate: { _ in })
                result.items = scan.items.count
                result.files = scan.items.count
            } catch {
                result.error = error.localizedDescription
            }
        default:
            result.error = "unknown scenario \(scenario)"
        }
        let elapsed = start.duration(to: clock.now)
        result.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return result
    }
}

/// Asks the main thread to answer every 20 ms and remembers the longest wait: the window freezes when it is long.
private final class StallMonitor: @unchecked Sendable {
    private let longest = OSAllocatedUnfairLock(initialState: 0.0)
    private let queue = DispatchQueue(label: "perf.stall-monitor")

    var maxStallMilliseconds: Int { Int(longest.withLock { $0 } * 1000) }

    func reset() { longest.withLock { $0 = 0 } }

    func start() {
        schedule()
    }

    private func schedule() {
        queue.asyncAfter(deadline: .now() + 0.02) { [self] in
            let asked = DispatchTime.now()
            DispatchQueue.main.async { [self] in
                let waited = Double(DispatchTime.now().uptimeNanoseconds - asked.uptimeNanoseconds) / 1e9
                longest.withLock { $0 = max($0, waited) }
                schedule()
            }
        }
    }
}
#endif
