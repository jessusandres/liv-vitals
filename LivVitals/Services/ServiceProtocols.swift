import Foundation
import LivCore

// Every data source the models use. The protocols and their real implementations are `nonisolated` and
// `@concurrent`: with the app's default MainActor isolation, a plain `async` method would run on the main
// actor and a disk walk would freeze the window.

/// Progress of a cleaning scan: a fraction when it is known, and the path being looked at.
nonisolated struct ScanUpdate: Sendable {
    var fraction: Double?
    var currentPath: String
}

/// One item a cleanup could not do, and why.
nonisolated struct CleanupProblem: Sendable, Equatable {
    let item: CleanupItem
    let reason: String
}

/// What a cleanup did, item by item.
nonisolated struct CleanupOutcome: Sendable {
    /// Only what was actually done. Empty for a dry run.
    var record: CleanupRecord
    var trashedSize: ByteSize
    var deletedSize: ByteSize
    var failures: [CleanupProblem]
    var skipped: [CleanupProblem]
    var wasDryRun: Bool
    /// Something the end screen should explain, e.g. that what was removed as an administrator stays owned by root.
    var notice: String?

    var isEmpty: Bool { record.itemCount == 0 }
}

/// How a cleanup should run, read from Settings when the user confirms.
nonisolated struct CleanOptions: Sendable {
    var moveToTrash = true
    /// Plan and log, change nothing.
    var dryRun = false
    /// Folders cleaning must never touch.
    var whitelist: [URL] = []
    /// The folders Dev Projects may clean inside; nothing outside them can be removed.
    var projectRoots: [URL] = []
    /// Where Installers may remove from. Nil: Downloads and the Desktop.
    var installerFolders: [URL]?
    /// The run these items belong to, when several modules clean as one (Smart Care). Nil gives each its own.
    var runID: UUID?
}

/// What a scan needs from Settings, read when the user starts it.
nonisolated struct ScanOptions: Sendable {
    /// Folders the scan must never look into.
    var whitelist: [URL] = []
    /// Where Dev Projects looks for build folders.
    var projectRoots: [URL] = []
    /// Leave projects edited in the last 7 days unchecked.
    var skipRecentProjects = true
    /// Where Installers looks for disk images and packages. Nil: Downloads and the Desktop.
    var installerFolders: [URL]?
}

nonisolated extension CleanupItem {
    /// What happens to the item. What is already in the Trash is deleted, since moving it into the Trash
    /// again would free nothing.
    func action(moveToTrash: Bool) -> CleanupAction {
        category == .trash || !moveToTrash ? .delete : .moveToTrash
    }
}

nonisolated protocol CleanupScanning: Sendable {
    /// True while this module gets made-up data from the service. The UI says so.
    func isSimulated(_ module: AppModule) -> Bool

    @concurrent func scan(
        module: AppModule,
        options: ScanOptions,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> ScanResult

    /// Acts on `items` found by `module`. `source` is how History names the run.
    @concurrent func clean(
        module: AppModule,
        _ items: [CleanupItem],
        source: String,
        options: CleanOptions,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> CleanupOutcome

    /// Permanently deletes what is in the Trash. Needs Full Disk Access.
    @concurrent func emptyTrash(options: CleanOptions, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> CleanupOutcome

    /// Names of the running apps that own the clutter in `items`, for the "quit these first" notice.
    @concurrent func runningOwners(of items: [CleanupItem]) async -> [String]
}

nonisolated protocol DiskTreeProviding: Sendable {
    var isSimulated: Bool { get }

    /// The tree below `url`, real folders down to `depth` and deeper ones collapsed.
    @concurrent func tree(
        at url: URL,
        depth: Int,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> (node: DiskNode, issues: [ScanIssue])
}

nonisolated protocol MetricsProviding: Sendable {
    var isSimulated: Bool { get }

    /// A snapshot every `interval` until the consumer stops listening; stopping also stops the sampling. Without
    /// processes nothing like `top` is started, which is what the menu bar indicators want. Temperature sensors are
    /// read only when `includeTemperature` is true; the GPU's also in a light stream when `includeGPUTemperature` is.
    func snapshots(every interval: Duration, includeProcesses: Bool, includeTemperature: Bool, includeGPUTemperature: Bool) -> AsyncStream<MetricsSnapshot>
}

extension MetricsProviding {
    nonisolated func snapshots(every interval: Duration, includeProcesses: Bool) -> AsyncStream<MetricsSnapshot> {
        snapshots(every: interval, includeProcesses: includeProcesses, includeTemperature: false, includeGPUTemperature: false)
    }

    nonisolated func snapshots(every interval: Duration) -> AsyncStream<MetricsSnapshot> {
        snapshots(every: interval, includeProcesses: true)
    }
}

/// How one maintenance task ended.
nonisolated enum MaintenanceOutcome: Sendable, Equatable {
    case done
    /// With the reason, in English.
    case failed(String)
    /// It did not run: the password dialog was cancelled, or an earlier step it depends on failed.
    case skipped(String)
}

/// Progress of a maintenance run, in the order it happens.
nonisolated enum MaintenanceEvent: Sendable, Equatable {
    case started(String)
    case finished(String, MaintenanceOutcome)
}

nonisolated struct MaintenanceOptions: Sendable {
    /// Log what would run and run nothing ("Simulate cleaning").
    var dryRun = false
}

nonisolated protocol MaintenanceRunning: Sendable {
    var isSimulated: Bool { get }
    var tasks: [MaintenanceTask] { get }

    /// Runs the whole selection, so the tasks that need a password can share one dialog. Returns how each
    /// task ended, by task ID. `onEvent` reports tasks as they start and finish.
    @concurrent func run(
        _ tasks: [MaintenanceTask],
        options: MaintenanceOptions,
        onEvent: @escaping @Sendable (MaintenanceEvent) -> Void
    ) async throws -> [String: MaintenanceOutcome]
}

/// The launch agents and daemons on this Mac. Read-only: Liv Vitals shows them and changes nothing.
nonisolated protocol StartupItemsProviding: Sendable {
    var isSimulated: Bool { get }

    @concurrent func items() async -> [LaunchItem]
}

nonisolated protocol PermissionProviding: Sendable {
    /// Whether the app can read files that only Full Disk Access unlocks. Quick enough to call on the main actor.
    func fullDiskAccess() -> FullDiskAccess.Status
}

/// One item "Put Back" could not restore, and why.
nonisolated struct RestoreProblem: Sendable, Equatable {
    let originalPath: String
    let reason: String
}

/// What "Put Back" would do with a selection, shown before the user confirms.
nonisolated struct RestorePreview: Sendable, Equatable {
    /// Items that can go back.
    var restorable = 0
    /// How many of those ask for the administrator's password.
    var needsPassword = 0
    /// Items that stay where they are, with the reason.
    var skipped: [RestoreProblem] = []
}

/// What "Put Back" did.
nonisolated struct RestoreOutcome: Sendable, Equatable {
    var restored = 0
    var skipped: [RestoreProblem] = []
    var failed: [RestoreProblem] = []
    /// Something the end screen should explain, e.g. that restored services start again after a restart.
    var notice: String?
}

nonisolated protocol HistoryProviding: Sendable {
    var isSimulated: Bool { get }

    /// Every finished cleanup with what it removed, newest first.
    @concurrent func runs() async -> [HistoryRun]
    @concurrent func record(_ record: CleanupRecord) async

    /// What putting `items` back would do, without moving anything.
    @concurrent func preview(_ items: [HistoryItem]) async -> RestorePreview

    /// Puts `items` of the cleanup `run` back from the Trash, logging every step. What needs the administrator
    /// goes through a single password dialog.
    @concurrent func putBack(
        _ items: [HistoryItem],
        of run: UUID,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> RestoreOutcome
}

nonisolated enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case disabled
    /// Registered, but the user still has to allow it in System Settings › Login Items.
    case requiresApproval
}

/// Whether the app opens when the user logs in. The state lives in macOS, not in `settings.json`.
nonisolated protocol LoginItemControlling: Sendable {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}
