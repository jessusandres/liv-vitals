import AppKit
import Foundation
import LivCore
import os

/// What the user cannot do right now, in words for the screen.
nonisolated enum CleanupServiceError: Error, LocalizedError {
    case fullDiskAccessRequired

    var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired: String(localized: "Full Disk Access is needed to empty the Trash.")
        }
    }
}

/// Real cleaning for the Cleanup module (rules → measure → plan → run), for Dev Projects (find artifacts →
/// drop what git tracks → measure → plan → run), for the Uninstaller and Installers, for removing one item from
/// Space Lens, and for Smart Care, which runs Cleanup, Installers and Dev Projects together.
nonisolated struct LiveCleanupScanner: CleanupScanning {
    static let sharedNote = CleanupItem.sharedSpaceNote
    static let trackedByGitReason = "Tracked by git"

    let home: URL
    let permissions: any PermissionProviding
    let remover: any FileRemoving
    let log: OperationLog
    let rules: [CleanupRule]
    /// nil when no developer tools are installed: tracked files cannot be ruled out then, and the scan says so.
    let git: (any GitInspecting)?
    /// Running apps as bundle ID → name. Injected so tests do not depend on what happens to be open.
    let runningApps: @Sendable () async -> [String: String]
    /// Where the Uninstaller looks for apps.
    let appFolders: [URL]
    /// `/Library`, where launch daemons and privileged helpers live. A test points it at a fake folder.
    let systemLibrary: URL
    /// Liv Vitals never offers to uninstall itself.
    let ownBundleID: String?
    /// Whether macOS knows an app with this bundle ID anywhere, so its files are no leftovers.
    let isKnownBundleID: @Sendable (String) -> Bool
    /// Asks the apps with these bundle IDs to quit and returns the ones still running afterwards.
    let quitApps: @Sendable ([String]) async -> Set<String>
    /// Paths of the disk images attached right now.
    let mountedImages: @Sendable () async -> Set<String>
    /// What removes apps and system files that need administrator rights. nil: those are left alone.
    let privileged: (any PrivilegedRunning)?

    init(
        home: URL,
        permissions: any PermissionProviding,
        remover: any FileRemoving = SystemFileRemover(),
        log: OperationLog,
        rules: [CleanupRule] = CleanupRule.builtIn,
        git: (any GitInspecting)? = SystemGit(),
        privileged: (any PrivilegedRunning)? = nil,
        runningApps: @escaping @Sendable () async -> [String: String] = LiveCleanupScanner.systemRunningApps,
        appFolders: [URL]? = nil,
        systemLibrary: URL = URL(filePath: "/Library", directoryHint: .isDirectory),
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        isKnownBundleID: @escaping @Sendable (String) -> Bool = LiveCleanupScanner.systemKnowsBundleID,
        quitApps: @escaping @Sendable ([String]) async -> Set<String> = LiveCleanupScanner.systemQuitApps,
        mountedImages: @escaping @Sendable () async -> Set<String> = LiveCleanupScanner.systemMountedImages
    ) {
        self.home = home
        self.permissions = permissions
        self.remover = remover
        self.log = log
        self.rules = rules
        self.git = git
        self.privileged = privileged
        self.runningApps = runningApps
        self.appFolders = appFolders ?? AppInventory.standardFolders(home: home)
        self.systemLibrary = systemLibrary
        self.ownBundleID = ownBundleID
        self.isKnownBundleID = isKnownBundleID
        self.quitApps = quitApps
        self.mountedImages = mountedImages
    }

    static let systemRunningApps: @Sendable () async -> [String: String] = {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.reduce(into: [String: String]()) { names, app in
                if let id = app.bundleIdentifier { names[id] = app.localizedName ?? id }
            }
        }
    }

    func isSimulated(_ module: AppModule) -> Bool { false }

    // MARK: - Scanning

    func scan(
        module: AppModule,
        options: ScanOptions,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> ScanResult {
        let found: ScanResult
        switch module {
        case .cleanup: found = try await scanCleanup(whitelist: options.whitelist, onUpdate: onUpdate)
        case .devProjects: found = try await scanDevProjects(options, onUpdate: onUpdate)
        case .applications: found = try await scanApplications(options, onUpdate: onUpdate)
        case .installers: found = try await scanInstallers(options, onUpdate: onUpdate)
        case .smartCare: return try await scanSmartCare(options, onUpdate: onUpdate)
        default: return .empty
        }
        return Self.tagged(found, as: module)
    }

    /// Every item remembers which module found it, so Smart Care can clean it with that module's checks.
    static func tagged(_ result: ScanResult, as module: AppModule) -> ScanResult {
        ScanResult(
            items: result.items.map { $0.withModule(module.rawValue) },
            scannedAt: result.scannedAt,
            locationsNeedingAccess: result.locationsNeedingAccess,
            issues: result.issues
        )
    }

    func scanDevProjects(_ options: ScanOptions, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> ScanResult {
        let guardian = projectGuard(roots: options.projectRoots, whitelist: options.whitelist)
        let scan = DevProjectsScan(
            roots: options.projectRoots,
            guard: guardian,
            git: git,
            skipRecentProjects: options.skipRecentProjects
        )
        return try await scan.run { progress in
            onUpdate(ScanUpdate(fraction: progress.fraction, currentPath: URL(filePath: progress.currentPath).abbreviatedPath))
        }
    }

    func scanCleanup(whitelist: [URL], onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> ScanResult {
        let guardian = ruleGuard(whitelist: whitelist)
        let engine = CleanupRuleEngine(home: home, fullDiskAccess: permissions.fullDiskAccess() == .granted, guard: guardian)
        let found = engine.matches(for: rules)
        try Task.checkCancellation()

        let measurements = try await measure(found.matches.map(\.url), guardian: guardian, onUpdate: onUpdate)
        let running = await runningApps()

        let items = found.matches.compactMap { match -> CleanupItem? in
            guard let measurement = measurements[match.url], measurement.size.bytes > 0 else { return nil }
            return item(for: match, measurement: measurement, running: running)
        }
        return ScanResult(items: items, locationsNeedingAccess: found.skippedRules.count)
    }

    private func item(for match: RuleMatch, measurement: LivCore.Measurement, running: [String: String]) -> CleanupItem {
        let rule = match.rule
        var notes: [String] = []
        var selected = rule.defaultSelected

        // Hard links keep the data alive after the move, so most of a mostly-shared item is not freed.
        if measurement.sharedSize.bytes * 2 > measurement.size.bytes {
            notes.append(Self.sharedNote)
            selected = false
        }
        if let app = rule.ownerBundleIDs.compactMap({ running[$0] }).first {
            notes.append("Quit \(app) to clean this.")
            selected = false
        }
        let modified = try? match.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return CleanupItem(
            url: match.url,
            category: rule.category,
            size: measurement.size,
            lastModified: modified,
            isSelectedByDefault: selected,
            note: notes.isEmpty ? nil : notes.joined(separator: " "),
            ruleID: rule.id
        )
    }

    func measure(
        _ urls: [URL],
        guardian: SafetyGuard,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> [URL: LivCore.Measurement] {
        // The fraction comes from finished paths, the path shown from the walk in progress.
        let state = OSAllocatedUnfairLock(initialState: ScanUpdate(fraction: 0, currentPath: ""))
        return try await FileScanner(guard: guardian).measureAll(
            urls,
            progress: { progress in
                onUpdate(state.withLock { update in
                    update.currentPath = progress.currentPath
                    return update
                })
            },
            rootFinished: { done, total in
                onUpdate(state.withLock { update in
                    update.fraction = Double(done) / Double(max(total, 1))
                    return update
                })
            }
        )
    }

    // MARK: - Cleaning

    func clean(
        module: AppModule,
        _ items: [CleanupItem],
        source: String,
        options: CleanOptions,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> CleanupOutcome {
        let guardian: SafetyGuard
        switch module {
        case .cleanup: guardian = ruleGuard(whitelist: options.whitelist)
        case .spaceLens: guardian = SafetyGuard(home: home, allowedRoots: [home], whitelist: options.whitelist)
        case .devProjects: return try await cleanDevProjects(items, source: source, options: options, onUpdate: onUpdate)
        case .applications: return try await cleanApplications(items, source: source, options: options, onUpdate: onUpdate)
        case .installers: guardian = installerGuard(whitelist: options.whitelist, folders: options.installerFolders)
        case .smartCare: return try await cleanSmartCare(items, source: source, options: options, onUpdate: onUpdate)
        default: return emptyOutcome(source: source, dryRun: options.dryRun)
        }
        return try await run(items, source: source, options: options, guardian: guardian, onUpdate: onUpdate)
    }

    /// Asks git again about what was selected, since a project can start tracking a folder after the scan.
    /// What is tracked now never reaches the runner. If git cannot answer, the selection stands: the scan
    /// already said so on those items and the user kept them checked.
    private func cleanDevProjects(
        _ items: [CleanupItem],
        source: String,
        options: CleanOptions,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> CleanupOutcome {
        let guardian = projectGuard(roots: options.projectRoots, whitelist: options.whitelist)
        let tracked = try await trackedNow(items, roots: options.projectRoots)
        let remaining = items.filter { !tracked.contains($0.url) }
        let skipped = items.filter { tracked.contains($0.url) }.map {
            CleanupProblem(item: $0, reason: Self.trackedByGitReason)
        }

        var outcome = remaining.isEmpty
            ? emptyOutcome(source: source, dryRun: options.dryRun)
            : try await run(remaining, source: source, options: options, guardian: guardian, onUpdate: onUpdate)
        outcome.skipped += skipped
        return outcome
    }

    private func trackedNow(_ items: [CleanupItem], roots: [URL]) async throws -> Set<URL> {
        guard let git else { return [] }
        // Shallowest root first, like the scan, which drops a root nested inside another.
        let resolvedRoots = roots.map { $0.resolvingSymlinksInPath() }.sorted { $0.path.count < $1.path.count }

        var byRepository: [URL: [URL]] = [:]
        for item in items {
            guard let root = resolvedRoots.first(where: { item.url.path.hasPrefix($0.path + "/") }),
                  let repository = gitRepositoryRoot(containing: item.url, stopAt: root) else { continue }
            byRepository[repository, default: []].append(item.url)
        }

        var tracked = Set<URL>()
        for (repository, urls) in byRepository {
            try Task.checkCancellation()
            do {
                tracked.formUnion(try await git.trackedPaths(urls, in: repository))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return tracked
    }

    func emptyTrash(options: CleanOptions, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> CleanupOutcome {
        guard permissions.fullDiskAccess() == .granted else { throw CleanupServiceError.fullDiskAccessRequired }
        guard let trashRule = rules.first(where: { $0.id == "trash" }) else { return emptyOutcome(source: "Empty Trash", dryRun: options.dryRun) }

        let guardian = ruleGuard(whitelist: options.whitelist)
        let engine = CleanupRuleEngine(home: home, fullDiskAccess: true, guard: guardian)
        let matches = engine.matches(for: [trashRule]).matches
        let measurements = try await measure(matches.map(\.url), guardian: guardian, onUpdate: onUpdate)
        let items = matches.compactMap { match -> CleanupItem? in
            guard let measurement = measurements[match.url], measurement.size.bytes > 0 else { return nil }
            return item(for: match, measurement: measurement, running: [:])
        }
        guard !items.isEmpty else { return emptyOutcome(source: "Empty Trash", dryRun: options.dryRun) }
        return try await run(items, source: "Empty Trash", options: options, guardian: guardian, onUpdate: onUpdate)
    }

    func runningOwners(of items: [CleanupItem]) async -> [String] {
        if items.contains(where: { $0.category == .applications || ($0.category == .appLeftovers && $0.group != nil) }) {
            return await runningApps(owning: items).values.sorted()
        }
        let owners = Set(items.compactMap { item in rules.first { $0.id == item.ruleID }?.ownerBundleIDs }.flatMap { $0 })
        guard !owners.isEmpty else { return [] }
        let running = await runningApps()
        return owners.compactMap { running[$0] }.sorted()
    }

    // MARK: - Shared

    /// Roots are the folders the rules reach into; whatever is outside them cannot be touched.
    private func ruleGuard(whitelist: [URL]) -> SafetyGuard {
        SafetyGuard(home: home, allowedRoots: CleanupRuleEngine.roots(for: rules, home: home), whitelist: whitelist)
    }

    /// Only inside the project folders the user chose, and only the ones that exist.
    private func projectGuard(roots: [URL], whitelist: [URL]) -> SafetyGuard {
        SafetyGuard(
            home: home,
            allowedRoots: roots.filter { FileManager.default.fileExists(atPath: $0.path) },
            whitelist: whitelist
        )
    }

    func run(
        _ items: [CleanupItem],
        source: String,
        options: CleanOptions,
        guardian: SafetyGuard,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> CleanupOutcome {
        let runID = options.runID ?? UUID()
        let entries = try await runEntries(items, source: source, options: options, guardian: guardian, runID: runID, onUpdate: onUpdate)
        return Self.outcome(from: entries, items: items, source: source, runID: runID, dryRun: options.dryRun)
    }

    /// Plans and runs `items` and returns what the executor logged, so a caller can add more lines under the
    /// same `runID` before reading the whole run back.
    func runEntries(
        _ items: [CleanupItem],
        source: String,
        options: CleanOptions,
        guardian: SafetyGuard,
        runID: UUID,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> [LogEntry] {
        let plan = CleanupPlanner.plan(items, action: { $0.action(moveToTrash: options.moveToTrash) }, guard: guardian)
        if options.dryRun {
            return try await DryRunExecutor(log: log, runID: runID, source: source).execute(plan)
        }
        let runner = CleanupRunner(guard: guardian, remover: remover, log: log, runID: runID, source: source) { done, total, url in
            onUpdate(ScanUpdate(fraction: Double(done) / Double(max(total, 1)), currentPath: url.abbreviatedPath))
        }
        return try await runner.execute(plan)
    }

    func emptyOutcome(source: String, dryRun: Bool) -> CleanupOutcome {
        CleanupOutcome(
            record: CleanupRecord(date: .now, source: source, itemCount: 0, freed: .zero, movedToTrash: false),
            trashedSize: .zero, deletedSize: .zero, failures: [], skipped: [], wasDryRun: dryRun
        )
    }

    /// Reads what the executor logged back into what the screen shows.
    static func outcome(from entries: [LogEntry], items: [CleanupItem], source: String, runID: UUID, dryRun: Bool) -> CleanupOutcome {
        let byPath = Dictionary(items.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        var failures: [CleanupProblem] = []
        var skipped: [CleanupProblem] = []
        var trashed: Int64 = 0
        var deleted: Int64 = 0
        var doneCount = 0

        for entry in entries {
            guard let item = byPath[entry.path] else { continue }
            switch entry.outcome {
            case .done:
                doneCount += 1
                if entry.kind == .trash { trashed += entry.bytes } else { deleted += entry.bytes }
            case .failed:
                failures.append(CleanupProblem(item: item, reason: entry.detail ?? "Unknown error"))
            case .skipped:
                skipped.append(CleanupProblem(item: item, reason: entry.detail ?? "Skipped"))
            case .planned:
                break
            }
        }
        return CleanupOutcome(
            record: CleanupRecord(
                id: runID, date: .now, source: source, itemCount: doneCount,
                freed: ByteSize(trashed + deleted), movedToTrash: deleted == 0
            ),
            trashedSize: ByteSize(trashed),
            deletedSize: ByteSize(deleted),
            failures: failures,
            skipped: skipped,
            wasDryRun: dryRun
        )
    }
}
