import AppKit
import Darwin
import Foundation
import LivCore

/// The Uninstaller: every app the user can remove, with the files it left in `~/Library` and `/Library`, and the
/// leftovers of apps that are gone. What needs administrator rights (an app owned by root or from the App Store,
/// a launch daemon) is marked and removed with one password dialog.
nonisolated extension LiveCleanupScanner {
    static let stillRunningReason = "Still running. Quit it and try again."
    static let runningNote = "Open now; it will be quit first."
    static let orphanNote = "No installed app uses this."
    static let sharedContainerNote = "May be shared with other apps from the same developer."
    static let appManagementHint = "If macOS keeps refusing, allow Liv Vitals in System Settings › Privacy & Security › App Management (click + and add it from Applications if it is not listed)."
    static let adminCancelledReason = "The password was not entered."
    static let adminUnavailableReason = "Needs administrator rights, which this build cannot ask for."
    static let serviceNotStoppedPrefix = "Could not stop its service: "
    static let rootOwnedNotice = "What was removed as an administrator is still owned by root in the Trash. Finder empties it and asks for your password."
    static let alwaysTrashNotice = "Items that need administrator rights always go to the Trash, never straight to deletion."

    // MARK: - System hooks

    static let systemKnowsBundleID: @Sendable (String) -> Bool = { bundleID in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// `terminate()` lets each app save and ask about unsaved work; it gets 10 seconds.
    static let systemQuitApps: @Sendable ([String]) async -> Set<String> = { bundleIDs in
        func running() async -> Set<String> {
            await MainActor.run {
                Set(bundleIDs.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
            }
        }
        await MainActor.run {
            for id in bundleIDs {
                NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        var still = await running()
        while !still.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            still = await running()
        }
        return still
    }

    // MARK: - Scanning

    func scanApplications(_ options: ScanOptions, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> ScanResult {
        onUpdate(ScanUpdate(fraction: nil, currentPath: "Looking for apps…"))
        let installed = AppInventory(folders: appFolders).apps()
        let listed = installed.filter { (!$0.isApple || $0.isAppStore) && $0.bundleID != ownBundleID }
        let guardian = uninstallGuard(whitelist: options.whitelist)
        let fullDiskAccess = permissions.fullDiskAccess() == .granted
        let leftovers = LeftoverFinder(
            home: home, systemLibrary: systemLibrary, fullDiskAccess: fullDiskAccess, installed: installed, guard: guardian
        ).find(isKnownBundleID: isKnownBundleID)
        try Task.checkCancellation()

        let urls = listed.map(\.url) + listed.flatMap { leftovers.byApp[$0.url] ?? [] }.map(\.url) + leftovers.orphans.map(\.url)
        let measurements = try await measure(urls, guardian: guardian, onUpdate: onUpdate)
        let running = await runningApps()
        func size(_ url: URL) -> ByteSize { measurements[url]?.size ?? .zero }

        // What needs a password is removed under the admin policy; whatever it refuses is shown blocked, with why.
        let policy = removalPolicy()
        func refusal(of url: URL, needsAdmin: Bool) -> String? {
            guard needsAdmin else { return nil }
            do {
                _ = try policy.validate(url)
                return nil
            } catch {
                return error.description
            }
        }

        var items: [CleanupItem] = []
        for app in listed {
            items.append(CleanupItem(
                url: app.url,
                category: .applications,
                size: size(app.url),
                lastModified: InstalledApp.lastUsedDate(of: app.url),
                note: running[app.bundleID] != nil ? Self.runningNote : nil,
                group: app.url,
                blockedReason: refusal(of: app.url, needsAdmin: app.needsAdmin),
                needsAdmin: app.needsAdmin
            ))
            for leftover in leftovers.byApp[app.url] ?? [] {
                items.append(CleanupItem(
                    url: leftover.url,
                    category: .appLeftovers,
                    size: size(leftover.url),
                    lastModified: Self.modificationDate(of: leftover.url),
                    // The app's checkbox picks what is safe to take along; shared containers stay behind.
                    isSelectedByDefault: !leftover.location.isShared,
                    note: leftover.location.isShared ? Self.sharedContainerNote : nil,
                    group: app.url,
                    blockedReason: refusal(of: leftover.url, needsAdmin: leftover.needsAdmin),
                    needsAdmin: leftover.needsAdmin
                ))
            }
        }
        for orphan in leftovers.orphans {
            items.append(CleanupItem(
                url: orphan.url,
                category: .appLeftovers,
                size: size(orphan.url),
                lastModified: Self.modificationDate(of: orphan.url),
                isSelectedByDefault: false,
                note: Self.orphanNote
            ))
        }
        // Containers and Group Containers are not opened without Full Disk Access.
        return ScanResult(items: items, locationsNeedingAccess: fullDiskAccess ? 0 : 2)
    }

    // MARK: - Cleaning

    /// Quits the apps whose files are selected, stops their launchd services, moves what a normal user can move to
    /// the Trash, and then everything that needs a password in one request. An app that does not quit keeps all its
    /// files, since removing them under a running app can break it.
    func cleanApplications(
        _ items: [CleanupItem],
        source: String,
        options: CleanOptions,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> CleanupOutcome {
        let owners = await runningApps(owning: items)
        var stillRunning = Set<String>()
        if !owners.isEmpty, !options.dryRun {
            onUpdate(ScanUpdate(fraction: nil, currentPath: "Quitting \(owners.values.sorted().formatted(.list(type: .and)))…"))
            stillRunning = await quitApps(Array(owners.keys))
        }
        let stuckGroups = Set(items.compactMap(\.group).filter { group in
            InstalledApp.read(at: group).map { stillRunning.contains($0.bundleID) } ?? false
        })
        var live = items.filter { $0.group.map { !stuckGroups.contains($0) } ?? true }
        var problems = items.filter { $0.group.map(stuckGroups.contains) ?? false }.map {
            CleanupProblem(item: $0, reason: Self.stillRunningReason)
        }

        // Stop the services before their files go, or they keep running until the next login.
        var passwordDismissed = false
        if !options.dryRun {
            let stopped = try await stopServices(of: live, onUpdate: onUpdate)
            passwordDismissed = stopped.passwordDismissed
            problems += live.filter { stopped.failed[$0.url] != nil }.map {
                CleanupProblem(item: $0, reason: Self.serviceNotStoppedPrefix + (stopped.failed[$0.url] ?? ""))
            }
            live = live.filter { stopped.failed[$0.url] == nil }
        }

        let runID = UUID()
        let plain = live.filter { !$0.needsAdmin }
        let admin = live.filter(\.needsAdmin)
        var entries: [LogEntry] = []
        if !plain.isEmpty {
            entries += try await runEntries(
                plain, source: source, options: options, guardian: uninstallGuard(whitelist: options.whitelist),
                runID: runID, onUpdate: onUpdate
            )
        }
        entries += try await removeAsAdmin(
            admin, source: source, options: options, runID: runID, passwordDismissed: passwordDismissed, onUpdate: onUpdate
        )

        var outcome = Self.outcome(from: entries, items: items, source: source, runID: runID, dryRun: options.dryRun)
        outcome.skipped += problems
        let adminPaths = Set(admin.map(\.url.path))
        if !options.dryRun, entries.contains(where: { $0.outcome == .done && adminPaths.contains($0.path) }) {
            outcome.notice = options.moveToTrash ? Self.rootOwnedNotice : Self.alwaysTrashNotice + " " + Self.rootOwnedNotice
        }
        // macOS protects other apps' bundles under App Management; the plain error does not say so.
        outcome.failures = outcome.failures.map { failure in
            guard failure.item.category == .applications, failure.reason.localizedCaseInsensitiveContains("permission") else { return failure }
            return CleanupProblem(item: failure.item, reason: "\(failure.reason) \(Self.appManagementHint)")
        }
        return outcome
    }

    /// Stops the launchd job behind each launch plist among `items`. A job that was not loaded is not a failure.
    /// What the user's own session runs needs no password; a system daemon asks for it.
    private func stopServices(
        of items: [CleanupItem],
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> (failed: [URL: String], passwordDismissed: Bool) {
        let jobs = items.compactMap { item in launchTarget(for: item).map { (item: item, job: $0) } }
        guard let privileged, !jobs.isEmpty else { return ([:], false) }
        var failed: [URL: String] = [:]
        var dismissed = false

        func record(_ group: [(item: CleanupItem, job: LaunchJobTarget)], _ result: [String: String?]) {
            for (item, job) in group {
                if let message = result[job.specifier] ?? nil { failed[item.url] = message }
            }
        }

        let ownSession = jobs.filter { if case .user = $0.job.domain { true } else { false } }
        let system = jobs.filter { if case .system = $0.job.domain { true } else { false } }
        if !ownSession.isEmpty {
            onUpdate(ScanUpdate(fraction: nil, currentPath: "Stopping services…"))
            record(ownSession, try await privileged.bootout(ownSession.map(\.job)))
        }
        if !system.isEmpty {
            onUpdate(ScanUpdate(fraction: nil, currentPath: "Waiting for your password…"))
            do {
                record(system, try await privileged.bootout(system.map(\.job)))
            } catch PrivilegedError.cancelled {
                dismissed = true
            }
        }
        return (failed, dismissed)
    }

    /// The launchd job a launch plist defines, when `item` is one: the user's own agents and the ones in
    /// `/Library/LaunchAgents` run in the user's session; daemons run in the system domain.
    func launchTarget(for item: CleanupItem) -> LaunchJobTarget? {
        guard item.url.pathExtension.lowercased() == "plist" else { return nil }
        let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
        func path(_ url: URL) -> String { url.standardizedFileURL.path }
        let domain: LaunchJobTarget.Domain
        if parent == path(home.appending(path: "Library/LaunchAgents")) || parent == path(systemLibrary.appending(path: "LaunchAgents")) {
            domain = .user(uid: UInt32(getuid()))
        } else if parent == path(systemLibrary.appending(path: "LaunchDaemons")) {
            domain = .system
        } else {
            return nil
        }
        let label = LaunchJob.read(at: item.url)?.label ?? item.url.deletingPathExtension().lastPathComponent
        return LaunchJobTarget(label: label, domain: domain)
    }

    /// Moves what needs administrator rights to the user's Trash, as root, behind one password dialog. Each item is
    /// checked by `PrivilegedRemovalPolicy` here, right before the password is asked. Always the Trash, whatever the
    /// "Move to Trash" setting says: a permanent delete as root has no way back.
    private func removeAsAdmin(
        _ items: [CleanupItem],
        source: String,
        options: CleanOptions,
        runID: UUID,
        passwordDismissed: Bool,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> [LogEntry] {
        guard !items.isEmpty else { return [] }

        func entry(_ item: CleanupItem, _ outcome: LogEntry.Outcome, kind: LogEntry.Kind = .trash, detail: String? = nil, trashed: String? = nil) -> LogEntry {
            LogEntry(
                kind: kind, path: item.url.path, bytes: item.size.bytes, outcome: outcome,
                detail: detail, runID: runID, trashedPath: trashed, source: source
            )
        }

        if options.dryRun {
            let planned = items.map { entry($0, .planned, kind: .dryRun, detail: "Would move to the Trash as an administrator") }
            try await log.append(planned)
            return planned
        }

        var entries: [LogEntry] = []
        var allowed: [(item: CleanupItem, target: URL)] = []
        let policy = removalPolicy()
        for item in items {
            if let reason = item.blockedReason {
                entries.append(entry(item, .skipped, detail: reason))
                continue
            }
            do {
                allowed.append((item, try policy.validate(item.url)))
            } catch {
                entries.append(entry(item, .skipped, detail: error.description))
            }
        }

        if passwordDismissed {
            entries += allowed.map { entry($0.item, .skipped, detail: Self.adminCancelledReason) }
        } else if let privileged {
            if !allowed.isEmpty {
                onUpdate(ScanUpdate(fraction: nil, currentPath: "Waiting for your password…"))
                do {
                    let moved = try await privileged.moveToTrashAsRoot(
                        allowed.map(\.target), trash: home.appending(path: ".Trash", directoryHint: .isDirectory)
                    )
                    for (item, target) in allowed {
                        switch moved[target] {
                        case .success(let trashed)?:
                            entries.append(entry(item, .done, trashed: trashed.path))
                        case .failure(let error)?:
                            let reason = error.localizedDescription
                            entries.append(entry(item, reason == "No longer exists" ? .skipped : .failed, detail: reason))
                        case nil:
                            entries.append(entry(item, .failed, detail: "No answer from the administrator command."))
                        }
                    }
                } catch PrivilegedError.cancelled {
                    entries += allowed.map { entry($0.item, .skipped, detail: Self.adminCancelledReason) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    entries += allowed.map { entry($0.item, .failed, detail: error.localizedDescription) }
                }
            }
        } else {
            entries += allowed.map { entry($0.item, .skipped, detail: Self.adminUnavailableReason) }
        }
        try await log.append(entries)
        return entries
    }

    /// Bundle ID → name of the running apps that own any of `items`.
    func runningApps(owning items: [CleanupItem]) async -> [String: String] {
        let bundleIDs = Set(Set(items.compactMap(\.group)).compactMap { InstalledApp.read(at: $0)?.bundleID })
        guard !bundleIDs.isEmpty else { return [:] }
        return await runningApps().filter { bundleIDs.contains($0.key) }
    }

    /// Only app folders and the `~/Library` places apps leave files in; `/Library` stays protected for everything that
    /// does not go through `PrivilegedRemovalPolicy`.
    func uninstallGuard(whitelist: [URL]) -> SafetyGuard {
        SafetyGuard(home: home, allowedRoots: appFolders + LeftoverFinder.userRoots(home: home), whitelist: whitelist)
    }

    func removalPolicy() -> PrivilegedRemovalPolicy {
        PrivilegedRemovalPolicy(appFolders: appFolders, systemLibrary: systemLibrary)
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
