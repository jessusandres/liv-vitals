import Foundation
import LivCore
import os
@testable import LivVitals

/// A throwaway folder inside the system temporary directory. App tests never touch any other path.
struct TemporaryDirectory {
    let url: URL

    static func use<T>(_ body: (TemporaryDirectory) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "LivVitalsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(TemporaryDirectory(url: url))
    }

    /// The folder with its symlinks resolved, as `SafetyGuard` and the admin policy report paths.
    var resolved: URL { url.resolvingSymlinksInPath() }

    func path(_ relative: String) -> URL { url.appending(path: relative) }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 0) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: target)
        return target
    }

    /// Sets the modification date of a file or folder to `days` days before now.
    func age(_ relative: String, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -days * 86_400)],
            ofItemAtPath: path(relative).path
        )
    }

    @discardableResult
    func hardLink(_ relative: String, to existing: URL) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: existing, to: target)
        return target
    }
}

/// A remover that records what it was asked and removes nothing, so no test ever touches a real Trash.
nonisolated final class RecordingRemover: FileRemoving, Sendable {
    private struct State {
        var trashed: [URL] = []
        var deleted: [URL] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var trashed: [URL] { state.withLock { $0.trashed } }
    var deleted: [URL] { state.withLock { $0.deleted } }

    func trash(_ url: URL) throws -> URL? {
        state.withLock { $0.trashed.append(url) }
        return URL(filePath: "/fake/.Trash/\(url.lastPathComponent)")
    }

    func delete(_ url: URL) throws {
        state.withLock { $0.deleted.append(url) }
    }
}

/// A git a test scripts, so no test depends on the git installed on this Mac or runs it.
nonisolated final class FakeGit: GitInspecting, Sendable {
    private let tracked = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Every repository the scan asked about, to see that git was really asked.
    private let asked = OSAllocatedUnfairLock(initialState: [String]())

    var repositoriesAsked: [String] { asked.withLock { $0 } }

    /// From now on `path` counts as tracked.
    func track(_ path: String) { tracked.withLock { _ = $0.insert(path) } }

    func trackedPaths(_ paths: [URL], in repository: URL) async throws -> Set<URL> {
        asked.withLock { $0.append(repository.path) }
        let known = tracked.withLock { $0 }
        return Set(paths.filter { known.contains($0.path) })
    }

    func lastCommitDate(touching path: URL, in repository: URL) async throws -> Date? { nil }
}

/// Polls until `condition` holds, so tests can wait for a model's background task without sleeping a fixed time.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

nonisolated struct FakeFailure: Error, LocalizedError {
    var errorDescription: String? { "Something went wrong." }
}

/// A cleaning service a test scripts, remembering what it was asked to do.
nonisolated struct FakeCleanupScanner: CleanupScanning {
    struct Calls: Sendable {
        var scans: [ScanOptions] = []
        var cleaned: [[CleanupItem]] = []
        var options: [CleanOptions] = []
        var emptied = 0
    }

    var isSimulated = false
    var result: ScanResult = .empty
    /// How long `scan` and `clean` take; use a long delay to test cancellation.
    var delay: Duration = .zero
    var failure: FakeFailure?
    /// Running apps reported as owners of the selection.
    var owners: [String] = []
    /// Replaces the outcome `clean` would build from the items.
    var cleanOutcome: CleanupOutcome?
    var trashFailure: FakeFailure?
    let calls = OSAllocatedUnfairLock(initialState: Calls())

    func isSimulated(_ module: AppModule) -> Bool { isSimulated }

    func scan(module: AppModule, options: ScanOptions, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> ScanResult {
        calls.withLock { $0.scans.append(options) }
        onUpdate(ScanUpdate(fraction: 0.5, currentPath: "/tmp/scanning"))
        try await Task.sleep(for: delay)
        if let failure { throw failure }
        return result
    }

    func clean(
        module: AppModule,
        _ items: [CleanupItem],
        source: String,
        options: CleanOptions,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> CleanupOutcome {
        calls.withLock {
            $0.cleaned.append(items)
            $0.options.append(options)
        }
        onUpdate(ScanUpdate(fraction: 1, currentPath: "/tmp/cleaning"))
        try await Task.sleep(for: delay)
        if let failure { throw failure }
        if let cleanOutcome { return cleanOutcome }
        let done = options.dryRun ? [] : items
        let toTrash = done.filter { $0.action(moveToTrash: options.moveToTrash) == .moveToTrash }.map(\.size).sum()
        let freed = done.map(\.size).sum()
        return CleanupOutcome(
            record: CleanupRecord(date: .now, source: source, itemCount: done.count, freed: freed, movedToTrash: toTrash == freed),
            trashedSize: toTrash,
            deletedSize: ByteSize(freed.bytes - toTrash.bytes),
            failures: [],
            skipped: [],
            wasDryRun: options.dryRun
        )
    }

    func emptyTrash(options: CleanOptions, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> CleanupOutcome {
        calls.withLock { $0.emptied += 1 }
        if let trashFailure { throw trashFailure }
        let size = ByteSize(2_000)
        return CleanupOutcome(
            record: CleanupRecord(date: .now, source: "Empty Trash", itemCount: 3, freed: size, movedToTrash: false),
            trashedSize: .zero, deletedSize: size, failures: [], skipped: [], wasDryRun: options.dryRun
        )
    }

    func runningOwners(of items: [CleanupItem]) async -> [String] { owners }
}

/// What one `FakeMaintenance.run` was asked to do.
nonisolated struct MaintenanceCall: Sendable, Equatable {
    var ids: [String]
    var dryRun: Bool
}

nonisolated struct FakeMaintenance: MaintenanceRunning {
    var isSimulated = false
    var tasks: [MaintenanceTask] = [
        MaintenanceTask(id: "a", title: "A", summary: "", requiresAdmin: false),
        MaintenanceTask(id: "b", title: "B", summary: "", requiresAdmin: true),
        MaintenanceTask(id: "c", title: "C", summary: "", requiresAdmin: false, isSelectedByDefault: false),
    ]
    /// How each task ends; a task not listed is done.
    var outcomes: [String: MaintenanceOutcome] = [:]
    /// Makes the whole run throw.
    var failure: FakeFailure?
    let calls = OSAllocatedUnfairLock(initialState: [MaintenanceCall]())

    func run(
        _ tasks: [MaintenanceTask],
        options: MaintenanceOptions,
        onEvent: @escaping @Sendable (MaintenanceEvent) -> Void
    ) async throws -> [String: MaintenanceOutcome] {
        calls.withLock { $0.append(MaintenanceCall(ids: tasks.map(\.id), dryRun: options.dryRun)) }
        if let failure { throw failure }
        var result: [String: MaintenanceOutcome] = [:]
        for task in tasks {
            onEvent(.started(task.id))
            let outcome = outcomes[task.id] ?? .done
            result[task.id] = outcome
            onEvent(.finished(task.id, outcome))
        }
        return result
    }
}

/// A command runner a test scripts. Nothing is ever run.
nonisolated final class FakeCommands: CommandRunning, Sendable {
    private struct State {
        var calls: [String] = []
        var runs: [String: Int] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// The result for a program, by its path; anything else answers status 0.
    let results: [String: CommandResult]
    /// Results for a program, one per run in order; the last one repeats. Wins over `results`.
    let sequences: [String: [CommandResult]]
    /// Programs whose run throws.
    let throwing: Set<String>

    init(results: [String: CommandResult] = [:], sequences: [String: [CommandResult]] = [:], throwing: Set<String> = []) {
        self.results = results
        self.sequences = sequences
        self.throwing = throwing
    }

    /// Every command asked, as typed: `/usr/bin/killall Dock`.
    var calls: [String] { state.withLock { $0.calls } }

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        let run = state.withLock { state in
            state.calls.append(([executable] + arguments).joined(separator: " "))
            defer { state.runs[executable, default: 0] += 1 }
            return state.runs[executable, default: 0]
        }
        if throwing.contains(executable) { throw FakeFailure() }
        if let sequence = sequences[executable], !sequence.isEmpty { return sequence[min(run, sequence.count - 1)] }
        return results[executable] ?? CommandResult(status: 0)
    }
}

/// Stands for the password dialog: records the commands it was asked to run as root and answers as scripted.
nonisolated final class FakeAdminDialog: AdminDialogRunning, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [[[String]]]())
    /// What it answers for a command; by default status 0 with no output.
    let answer: @Sendable ([String]) -> CommandResult
    /// The user dismisses the dialog.
    let cancels: Bool

    init(cancels: Bool = false, answer: @escaping @Sendable ([String]) -> CommandResult = { _ in CommandResult(status: 0) }) {
        self.cancels = cancels
        self.answer = answer
    }

    /// One entry per dialog, each with the commands it ran.
    var dialogs: [[[String]]] { state.withLock { $0 } }

    func runAsRoot(_ commands: [[String]], reason: String) async throws -> [CommandResult] {
        state.withLock { $0.append(commands) }
        if cancels { throw PrivilegedError.cancelled }
        return commands.map(answer)
    }
}

/// A privileged runner a test scripts. It records what it was asked and changes nothing on the Mac.
nonisolated final class FakePrivileged: PrivilegedRunning, Sendable {
    struct RestoreMove: Sendable, Equatable {
        let from: URL
        let to: URL
    }

    struct State: Sendable {
        var ruleInstalled: Bool
        var rootRuns: [[CommandStep]] = []
        var trashed: [[URL]] = []
        var restored: [[RestoreMove]] = []
        var bootouts: [[String]] = []
        var installedRules: [String] = []
        var removals = 0
        /// Order of the calls, to check what happens before what.
        var order: [String] = []
    }

    let state: OSAllocatedUnfairLock<State>
    /// The user dismisses the password dialog in every call that needs it.
    let cancels: Bool
    /// What a step answers, by its program path.
    let stepResults: [String: CommandResult]
    /// Paths that fail to move, with the reason.
    let trashFailures: [String: String]
    /// Sources (`from` paths) that fail to be put back, with the reason.
    let restoreFailures: [String: String]
    /// Targets (`system/<label>`) that cannot be stopped, with the reason.
    let bootoutFailures: [String: String]
    let installFailure: PrivilegedError?

    init(
        ruleInstalled: Bool = false,
        cancels: Bool = false,
        stepResults: [String: CommandResult] = [:],
        trashFailures: [String: String] = [:],
        restoreFailures: [String: String] = [:],
        bootoutFailures: [String: String] = [:],
        installFailure: PrivilegedError? = nil
    ) {
        state = OSAllocatedUnfairLock(initialState: State(ruleInstalled: ruleInstalled))
        self.cancels = cancels
        self.stepResults = stepResults
        self.trashFailures = trashFailures
        self.restoreFailures = restoreFailures
        self.bootoutFailures = bootoutFailures
        self.installFailure = installFailure
    }

    var rootRuns: [[CommandStep]] { state.withLock { $0.rootRuns } }
    var trashed: [[URL]] { state.withLock { $0.trashed } }
    var restored: [[RestoreMove]] { state.withLock { $0.restored } }
    var bootouts: [[String]] { state.withLock { $0.bootouts } }
    var installedRules: [String] { state.withLock { $0.installedRules } }
    var removals: Int { state.withLock { $0.removals } }
    var order: [String] { state.withLock { $0.order } }

    func runAsRoot(_ steps: [CommandStep], reason: String) async throws -> [CommandResult] {
        state.withLock {
            $0.rootRuns.append(steps)
            $0.order.append("run")
        }
        if cancels { throw PrivilegedError.cancelled }
        return steps.map { stepResults[$0.executable] ?? CommandResult(status: 0) }
    }

    func moveToTrashAsRoot(_ urls: [URL], trash: URL) async throws -> [URL: Result<URL, PrivilegedError>] {
        state.withLock {
            $0.trashed.append(urls)
            $0.order.append("trash")
        }
        if cancels { throw PrivilegedError.cancelled }
        return Dictionary(uniqueKeysWithValues: urls.map { url in
            if let reason = trashFailures[url.path] { return (url, .failure(.failed(reason))) }
            return (url, .success(trash.appending(path: url.lastPathComponent)))
        })
    }

    func restoreAsRoot(_ moves: [(from: URL, to: URL)]) async throws -> [URL: Result<Void, PrivilegedError>] {
        state.withLock {
            $0.restored.append(moves.map { RestoreMove(from: $0.from, to: $0.to) })
            $0.order.append("restore")
        }
        if cancels { throw PrivilegedError.cancelled }
        return Dictionary(uniqueKeysWithValues: moves.map { move in
            if let reason = restoreFailures[move.from.path] { return (move.from, .failure(.failed(reason))) }
            return (move.from, .success(()))
        })
    }

    func bootout(_ jobs: [LaunchJobTarget]) async throws -> [String: String?] {
        state.withLock {
            $0.bootouts.append(jobs.map(\.specifier))
            $0.order.append("bootout")
        }
        if cancels, jobs.contains(where: { $0.domain == .system }) { throw PrivilegedError.cancelled }
        return Dictionary(uniqueKeysWithValues: jobs.map { ($0.specifier, bootoutFailures[$0.specifier]) })
    }

    func installRule(_ contents: String) async throws {
        state.withLock { $0.installedRules.append(contents) }
        if cancels { throw PrivilegedError.cancelled }
        if let installFailure { throw installFailure }
        state.withLock { $0.ruleInstalled = true }
    }

    func removeRule() async throws {
        state.withLock { $0.removals += 1 }
        if cancels { throw PrivilegedError.cancelled }
        state.withLock { $0.ruleInstalled = false }
    }

    func isRuleInstalled() async -> Bool { state.withLock { $0.ruleInstalled } }
}

nonisolated struct FakeStartupItems: StartupItemsProviding {
    var isSimulated = false
    var found: [LaunchItem] = []

    func items() async -> [LaunchItem] { found }
}

actor FakeHistory: HistoryProviding {
    nonisolated let isSimulated: Bool
    private(set) var stored: [HistoryRun]
    /// What `preview` and `putBack` answer, and what they were asked.
    var previewAnswer = RestorePreview()
    var putBackAnswer = RestoreOutcome()
    private(set) var previewed: [[HistoryItem]] = []
    private(set) var putBacks: [(items: [HistoryItem], run: UUID)] = []

    init(isSimulated: Bool = false, stored: [HistoryRun] = []) {
        self.isSimulated = isSimulated
        self.stored = stored
    }

    func runs() -> [HistoryRun] { stored }
    func record(_ record: CleanupRecord) { stored.insert(HistoryRun(record: record, items: []), at: 0) }

    func preview(_ items: [HistoryItem]) -> RestorePreview {
        previewed.append(items)
        return previewAnswer
    }

    func putBack(_ items: [HistoryItem], of run: UUID, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> RestoreOutcome {
        putBacks.append((items, run))
        return putBackAnswer
    }

    func scripted(preview: RestorePreview? = nil, putBack: RestoreOutcome? = nil) {
        if let preview { previewAnswer = preview }
        if let putBack { putBackAnswer = putBack }
    }
}

extension HistoryRun {
    /// A run of `count` items that went to a fake Trash, for model tests.
    static func sample(_ source: String = "Cleanup", count: Int = 2, trashed: Bool = true, id: UUID = UUID()) -> HistoryRun {
        let items = (0..<count).map { index in
            HistoryItem(
                originalPath: "/tmp/home/Library/Caches/item\(index)",
                trashedPath: trashed ? "/tmp/home/.Trash/item\(index)" : nil,
                bytes: 100
            )
        }
        return HistoryRun(
            record: CleanupRecord(id: id, date: .now, source: source, itemCount: count, freed: ByteSize(Int64(count) * 100), movedToTrash: trashed),
            items: items
        )
    }
}

/// A restorer that records the moves and performs none.
nonisolated final class RecordingRestorer: FileRestoring, Sendable {
    private let moves = OSAllocatedUnfairLock(initialState: [(from: URL, to: URL)]())

    var restored: [(from: URL, to: URL)] { moves.withLock { $0 } }

    func restore(_ trashed: URL, to original: URL) throws {
        moves.withLock { $0.append((trashed, original)) }
    }
}

/// A permission state a test can change between reads.
nonisolated struct FakePermissions: PermissionProviding {
    private let state: OSAllocatedUnfairLock<FullDiskAccess.Status>

    init(_ status: FullDiskAccess.Status = .granted) {
        state = OSAllocatedUnfairLock(initialState: status)
    }

    func set(_ status: FullDiskAccess.Status) { state.withLock { $0 = status } }
    func fullDiskAccess() -> FullDiskAccess.Status { state.withLock { $0 } }
}

/// Metrics a test pushes by hand, counting how many streams were opened and closed.
nonisolated final class FakeMetrics: MetricsProviding, Sendable {
    private struct State {
        var continuations: [AsyncStream<MetricsSnapshot>.Continuation] = []
        var started = 0
        var terminated = 0
        var requests: [(interval: Duration, includeProcesses: Bool, includeTemperature: Bool, includeGPUTemperature: Bool)] = []
    }

    let isSimulated = false
    private let state = OSAllocatedUnfairLock(initialState: State())

    var started: Int { state.withLock { $0.started } }
    var terminated: Int { state.withLock { $0.terminated } }

    /// What each opened stream asked for, in order.
    var requests: [(interval: Duration, includeProcesses: Bool, includeTemperature: Bool, includeGPUTemperature: Bool)] { state.withLock { $0.requests } }

    func snapshots(every interval: Duration, includeProcesses: Bool, includeTemperature: Bool, includeGPUTemperature: Bool) -> AsyncStream<MetricsSnapshot> {
        AsyncStream { continuation in
            state.withLock {
                $0.continuations.append(continuation)
                $0.started += 1
                $0.requests.append((interval, includeProcesses, includeTemperature, includeGPUTemperature))
            }
            continuation.onTermination = { [state] _ in state.withLock { $0.terminated += 1 } }
        }
    }

    func send(_ snapshot: MetricsSnapshot) {
        let targets = state.withLock { $0.continuations }
        for continuation in targets { continuation.yield(snapshot) }
    }
}

extension MetricsSnapshot {
    /// A snapshot with round numbers, for asserting what the model derives from it.
    static func sample(
        cpu: Double = 0.25,
        pressure: MemoryPressure = .normal,
        battery: BatteryReading? = nil,
        processes: [ProcessUsage] = [],
        health: Int = 90
    ) -> MetricsSnapshot {
        MetricsSnapshot(
            date: .now,
            cpu: cpu,
            cpuAverage: cpu,
            memory: MemoryReading(
                totalBytes: 16 * 1_073_741_824,
                usedBytes: 8 * 1_073_741_824,
                wiredBytes: 1_073_741_824,
                compressedBytes: 1_073_741_824,
                pressure: pressure,
                appBytes: 5 * 1_073_741_824,
                cachedBytes: 4 * 1_073_741_824
            ),
            disk: DiskReading(totalBytes: 500_000_000_000, availableBytes: 200_000_000_000),
            downloadBytesPerSecond: 2_500_000,
            uploadBytesPerSecond: 500_000,
            battery: battery,
            topProcesses: processes,
            health: health
        )
    }
}

/// Disk trees a test scripts: the root answers the first scan, `subtrees` answer folders opened later.
nonisolated struct FakeDiskTree: DiskTreeProviding {
    var isSimulated = false
    var tree: DiskNode
    var subtrees: [URL: DiskNode] = [:]
    var issues: [ScanIssue] = []
    var subtreeIssues: [ScanIssue] = []
    var delay: Duration = .zero
    /// Limits `delay` to these folders; nil delays every request.
    var delayOnly: Set<URL>?
    var failure: FakeFailure?
    /// Fails only when a folder below the root is opened.
    var subtreeFailure: FakeFailure?
    /// A folder below the root has been deleted since it was listed.
    var subtreeNotFound = false
    /// Every URL the model asked for, in order.
    let requests = OSAllocatedUnfairLock(initialState: [URL]())

    func tree(at url: URL, depth: Int, onProgress: @escaping @Sendable (ScanProgress) -> Void) async throws -> (node: DiskNode, issues: [ScanIssue]) {
        requests.withLock { $0.append(url) }
        onProgress(ScanProgress(filesVisited: 10, bytesCounted: ByteSize(100), currentPath: url.path))
        if delayOnly?.contains(url) ?? true { try await Task.sleep(for: delay) }
        if url == tree.url {
            if let failure { throw failure }
            return (tree, issues)
        }
        if subtreeNotFound { throw ScanError.notFound(url) }
        if let subtreeFailure { throw subtreeFailure }
        return (subtrees[url] ?? tree, subtreeIssues)
    }
}

extension ServiceContainer {
    /// A container of fakes with in-memory settings, for model tests.
    @MainActor
    static func fake(
        cleanup: any CleanupScanning = FakeCleanupScanner(),
        diskTree: any DiskTreeProviding = FakeDiskTree(tree: .directory(URL(filePath: "/tmp/home"), children: [])),
        metrics: any MetricsProviding = FakeMetrics(),
        maintenance: any MaintenanceRunning = FakeMaintenance(),
        privileged: any PrivilegedRunning = FakePrivileged(),
        startupItems: any StartupItemsProviding = FakeStartupItems(),
        history: any HistoryProviding = FakeHistory(),
        permissions: any PermissionProviding = FakePermissions(),
        loginItem: any LoginItemControlling = MockLoginItem(),
        settingsStore: SettingsStore = SettingsStore(fileURL: nil, home: URL(filePath: "/tmp/home")),
        labelsSimulatedData: Bool = true
    ) -> ServiceContainer {
        ServiceContainer(
            cleanup: cleanup,
            diskTree: diskTree,
            metrics: metrics,
            maintenance: maintenance,
            privileged: privileged,
            startupItems: startupItems,
            history: history,
            permissions: permissions,
            loginItem: loginItem,
            settingsStore: settingsStore,
            home: URL(filePath: "/tmp/home"),
            labelsSimulatedData: labelsSimulatedData
        )
    }
}
