import Foundation
import LivCore
import os

// Simulated services: the Stage 1 behavior, timings included, moved out of the models.

nonisolated struct MockCleanupScanner: CleanupScanning {
    /// Makes cleaning report a failure and a skipped item, to look at the end screen with problems.
    var simulatesProblems = false

    func isSimulated(_ module: AppModule) -> Bool { true }

    func scan(module: AppModule, options: ScanOptions, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> ScanResult {
        let found = MockData.scanResult(for: module)
        let paths = found.items.map(\.url.abbreviatedPath)
        let steps = 70
        for step in 1...steps {
            try await Task.sleep(for: .milliseconds(35))
            onUpdate(ScanUpdate(fraction: Double(step) / Double(steps), currentPath: paths.isEmpty ? "" : paths[step % paths.count]))
        }
        return found
    }

    func clean(
        module: AppModule,
        _ items: [CleanupItem],
        source: String,
        options: CleanOptions,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> CleanupOutcome {
        let delay = max(40, 1_800 / max(items.count, 1))
        for (index, item) in items.enumerated() {
            try await Task.sleep(for: .milliseconds(delay))
            onUpdate(ScanUpdate(fraction: Double(index + 1) / Double(items.count), currentPath: item.url.abbreviatedPath))
        }
        var failures: [CleanupProblem] = []
        var skipped: [CleanupProblem] = []
        var done = items
        if simulatesProblems, items.count >= 3 {
            failures = [CleanupProblem(item: items[0], reason: "The file is in use by another app.")]
            skipped = [CleanupProblem(item: items[1], reason: "No longer exists")]
            done = Array(items.dropFirst(2))
        }
        if options.dryRun { done = [] }
        let freed = done.map(\.size).sum()
        let toTrash = done.filter { $0.action(moveToTrash: options.moveToTrash) == .moveToTrash }.map(\.size).sum()
        return CleanupOutcome(
            record: CleanupRecord(date: .now, source: source, itemCount: done.count, freed: freed, movedToTrash: options.moveToTrash),
            trashedSize: toTrash,
            deletedSize: ByteSize(freed.bytes - toTrash.bytes),
            failures: failures,
            skipped: skipped,
            wasDryRun: options.dryRun
        )
    }

    func emptyTrash(options: CleanOptions, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> CleanupOutcome {
        try await Task.sleep(for: .milliseconds(600))
        let size = ByteSize.gigabytes(2)
        return CleanupOutcome(
            record: CleanupRecord(date: .now, source: "Empty Trash", itemCount: 1, freed: size, movedToTrash: false),
            trashedSize: .zero, deletedSize: size, failures: [], skipped: [], wasDryRun: false
        )
    }

    func runningOwners(of items: [CleanupItem]) async -> [String] { [] }
}

nonisolated struct MockDiskTree: DiskTreeProviding {
    let isSimulated = true

    func tree(
        at url: URL,
        depth: Int,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> (node: DiskNode, issues: [ScanIssue]) {
        let steps = 50
        for step in 1...steps {
            try await Task.sleep(for: .milliseconds(30))
            onProgress(ScanProgress(
                filesVisited: step * 1_800,
                bytesCounted: ByteSize(Int64(step) * 900_000_000),
                currentPath: "~/Library/Caches"
            ))
        }
        let full = MockData.diskTree
        return (full.node(at: url) ?? full, [])
    }
}

nonisolated struct MockMaintenance: MaintenanceRunning {
    let isSimulated = true
    var tasks: [MaintenanceTask] { MockData.maintenanceTasks }

    func run(
        _ tasks: [MaintenanceTask],
        options: MaintenanceOptions,
        onEvent: @escaping @Sendable (MaintenanceEvent) -> Void
    ) async throws -> [String: MaintenanceOutcome] {
        var outcomes: [String: MaintenanceOutcome] = [:]
        for task in tasks {
            onEvent(.started(task.id))
            try await Task.sleep(for: .milliseconds(900))
            outcomes[task.id] = .done
            onEvent(.finished(task.id, .done))
        }
        return outcomes
    }
}

nonisolated struct MockStartupItems: StartupItemsProviding {
    let isSimulated = true

    func items() async -> [LaunchItem] {
        try? await Task.sleep(for: .milliseconds(300))
        return MockData.startupItems
    }
}

/// Never asks for a password and never runs anything: previews and snapshots only pretend. The rule starts as
/// the scenario says and flips when the screen installs or removes it.
nonisolated final class MockPrivileged: PrivilegedRunning, Sendable {
    private let ruleInstalled: OSAllocatedUnfairLock<Bool>

    init(ruleInstalled: Bool = false) {
        self.ruleInstalled = OSAllocatedUnfairLock(initialState: ruleInstalled)
    }

    func runAsRoot(_ steps: [CommandStep], reason: String) async throws -> [CommandResult] {
        steps.map { _ in CommandResult(status: 0) }
    }

    func moveToTrashAsRoot(_ urls: [URL], trash: URL) async throws -> [URL: Result<URL, PrivilegedError>] {
        Dictionary(uniqueKeysWithValues: urls.map { ($0, .success(trash.appending(path: $0.lastPathComponent))) })
    }

    func restoreAsRoot(_ moves: [(from: URL, to: URL)]) async throws -> [URL: Result<Void, PrivilegedError>] {
        Dictionary(uniqueKeysWithValues: moves.map { ($0.from, .success(())) })
    }

    func bootout(_ jobs: [LaunchJobTarget]) async throws -> [String: String?] {
        Dictionary(uniqueKeysWithValues: jobs.map { ($0.specifier, nil) })
    }

    func installRule(_ contents: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
        ruleInstalled.withLock { $0 = true }
    }

    func removeRule() async throws {
        try await Task.sleep(for: .milliseconds(400))
        ruleInstalled.withLock { $0 = false }
    }

    func isRuleInstalled() async -> Bool { ruleInstalled.withLock { $0 } }
}

/// The Stage 1 random walk, as snapshots. It hands out 60 samples at once so charts look filled from the start,
/// then one per interval.
nonisolated struct MockMetrics: MetricsProviding {
    let isSimulated = true

    private struct Walk {
        var cpu = 30.0
        var download = 2.5
        var upload = 0.6
        var memoryGB = 10.4
        var battery = 0.78
        var temperature = 52.0
        var processes: [(pid: Int32, name: String, cpu: Double, memoryMB: Double)] = [
            (101, "Xcode", 34, 3_100),
            (102, "Google Chrome Helper", 18, 1_450),
            (103, "OrbStack", 9, 2_200),
            (104, "Spotify", 4, 610),
            (105, "WindowServer", 6, 380),
        ]

        private func step(_ value: Double, _ size: Double, _ range: ClosedRange<Double>) -> Double {
            min(range.upperBound, max(range.lowerBound, value + .random(in: -size...size)))
        }

        mutating func next(includeTemperature: Bool) -> MetricsSnapshot {
            cpu = step(cpu, 9, 4...96)
            download = step(download, 1.2, 0.1...14)
            upload = step(upload, 0.4, 0.05...4)
            memoryGB = step(memoryGB, 0.15, 8...14.5)
            battery = max(0.05, battery - 0.0003)
            temperature = step(temperature, 2, 35...95)
            for index in processes.indices { processes[index].cpu = step(processes[index].cpu, 3, 0.5...60) }

            let memory = MemoryReading(
                totalBytes: 16 * 1_073_741_824,
                usedBytes: UInt64(memoryGB * 1_073_741_824),
                wiredBytes: 2 * 1_073_741_824,
                compressedBytes: 1_073_741_824,
                pressure: memoryGB / 16 > 0.85 ? .warning : .normal,
                appBytes: UInt64(max(0, memoryGB - 3) * 1_073_741_824),
                cachedBytes: 4 * 1_073_741_824
            )
            let disk = DiskReading(totalBytes: 494_000_000_000, availableBytes: 82_000_000_000)
            let usages = processes.map { ProcessUsage(pid: $0.pid, name: $0.name, cpuPercent: $0.cpu, memoryBytes: UInt64($0.memoryMB * 1_048_576)) }
            return MetricsSnapshot(
                date: .now,
                cpu: cpu / 100,
                cpuAverage: cpu / 100,
                memory: memory,
                disk: disk,
                downloadBytesPerSecond: download * 1_000_000,
                uploadBytesPerSecond: upload * 1_000_000,
                battery: BatteryReading(level: battery, isCharging: false, isOnACPower: false, cycleCount: 212, health: 0.91),
                topProcesses: usages.sorted { $0.cpuPercent > $1.cpuPercent },
                health: HealthScore.compute(cpu: cpu / 100, memoryPressure: memory.pressure, diskUsedFraction: disk.usedFraction),
                temperature: includeTemperature ? TemperatureReading(cpu: temperature, gpu: temperature - 6, battery: 31) : nil,
                topMemoryProcesses: usages.sorted { $0.memoryBytes > $1.memoryBytes }
            )
        }
    }

    func snapshots(every interval: Duration, includeProcesses: Bool, includeTemperature: Bool, includeGPUTemperature: Bool) -> AsyncStream<MetricsSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                var walk = Walk()
                for _ in 0..<60 { continuation.yield(walk.next(includeTemperature: includeTemperature)) }
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    continuation.yield(walk.next(includeTemperature: includeTemperature))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Always granted, so previews and snapshots never show the onboarding sheet.
nonisolated struct MockPermissions: PermissionProviding {
    func fullDiskAccess() -> FullDiskAccess.Status { .granted }
}

actor MockHistory: HistoryProviding {
    nonisolated let isSimulated = true
    private var stored = MockData.history

    func runs() -> [HistoryRun] { stored }

    func record(_ record: CleanupRecord) {
        stored.insert(HistoryRun(record: record, items: []), at: 0)
    }

    func preview(_ items: [HistoryItem]) -> RestorePreview {
        RestorePreview(restorable: items.filter { $0.trashedPath != nil }.count)
    }

    func putBack(_ items: [HistoryItem], of run: UUID, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> RestoreOutcome {
        onUpdate(ScanUpdate(fraction: nil, currentPath: "Putting items back…"))
        try await Task.sleep(for: .milliseconds(500))
        let paths = Set(items.map(\.originalPath))
        stored = stored.map { existing in
            guard existing.id == run else { return existing }
            return HistoryRun(record: existing.record, items: existing.items.map {
                paths.contains($0.originalPath) && $0.trashedPath != nil
                    ? HistoryItem(originalPath: $0.originalPath, trashedPath: $0.trashedPath, bytes: $0.bytes, restoredAt: .now)
                    : $0
            })
        }
        return RestoreOutcome(restored: items.filter { $0.trashedPath != nil }.count)
    }
}

/// A login item that only remembers what it was told, for previews, snapshots and tests.
nonisolated final class MockLoginItem: LoginItemControlling, Sendable {
    private struct State {
        var status: LoginItemStatus
        var failure: String?
        var settingsOpened = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ status: LoginItemStatus = .disabled, failure: String? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(status: status, failure: failure))
    }

    var status: LoginItemStatus { state.withLock { $0.status } }
    var settingsOpened: Int { state.withLock { $0.settingsOpened } }
    func setStatus(_ status: LoginItemStatus) { state.withLock { $0.status = status } }

    func setEnabled(_ enabled: Bool) throws {
        try state.withLock { state in
            if let failure = state.failure { throw MockLoginItemError(message: failure) }
            state.status = enabled ? .enabled : .disabled
        }
    }

    func openSystemSettings() { state.withLock { $0.settingsOpened += 1 } }
}

nonisolated struct MockLoginItemError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Power assertions that only remember what they were told, so tests and snapshots never hold a real one.
nonisolated final class MockPowerAssertions: PowerAssertionHolding {
    private struct State {
        var held = false
        var acquired = 0
        var released = 0
        var failure: String?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(failure: String? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(failure: failure))
    }

    var isHeld: Bool { state.withLock { $0.held } }
    /// How many times a real acquire happened (not counting repeats while held).
    var acquireCount: Int { state.withLock { $0.acquired } }
    var releaseCount: Int { state.withLock { $0.released } }
    func setFailure(_ failure: String?) { state.withLock { $0.failure = failure } }

    func acquire(reason: String) throws {
        try state.withLock { state in
            if let failure = state.failure { throw MockLoginItemError(message: failure) }
            if !state.held { state.held = true; state.acquired += 1 }
        }
    }

    func release() {
        state.withLock { state in
            if state.held { state.held = false; state.released += 1 }
        }
    }
}
