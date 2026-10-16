import AppKit
import Foundation
import LivCore
import Testing
@testable import LivVitals

@MainActor
struct ProcessIconCacheTests {
    private func process(_ pid: Int32) -> ProcessUsage {
        ProcessUsage(pid: pid, name: "Process \(pid)", cpuPercent: 1, memoryBytes: 1)
    }

    @Test func oneLookupPerProcessEvenAfterManyRenders() {
        let cache = ProcessIconCache { _ in NSImage() }
        for _ in 0..<100 {
            for pid in Int32(1)...5 { _ = cache.icon(for: process(pid)) }
        }
        #expect(cache.lookups == 5)
    }

    @Test func aProcessThatLeftIsForgottenSoAReusedPidLooksUpAgain() {
        let cache = ProcessIconCache { _ in NSImage() }
        _ = cache.icon(for: process(1))
        _ = cache.icon(for: process(2))
        cache.keep(only: [2])
        _ = cache.icon(for: process(1))
        _ = cache.icon(for: process(2))
        #expect(cache.lookups == 3)
    }

    /// The Monitor refreshes every second: the icons for the rows on screen must not be looked up again each time.
    @Test func theModelPrunesIconsOfProcessesThatDisappeared() async {
        let metrics = FakeMetrics()
        let model = MonitorModel(service: metrics)
        model.start()
        defer { model.stop() }

        let first = [process(10), process(11)]
        metrics.send(.sample(cpu: 0.1, processes: first))
        #expect(await waitUntil { model.latest != nil })
        for row in first { _ = model.icons.icon(for: row) }
        let before = model.icons.lookups

        metrics.send(.sample(cpu: 0.1, processes: [process(11)]))
        #expect(await waitUntil { model.processes.count == 1 })
        _ = model.icons.icon(for: process(11))
        #expect(model.icons.lookups == before)
        _ = model.icons.icon(for: process(10))
        #expect(model.icons.lookups == before + 1)
    }
}
