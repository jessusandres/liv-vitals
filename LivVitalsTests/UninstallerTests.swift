import Foundation
import LivCore
import os
import Testing
@testable import LivVitals

extension TemporaryDirectory {
    /// A minimal app bundle with an `Info.plist`.
    @discardableResult
    func app(_ relative: String, id: String, name: String? = nil) throws -> URL {
        let bundle = try directory(relative)
        var info: [String: Any] = ["CFBundleIdentifier": id]
        if let name { info["CFBundleName"] = name }
        try file("\(relative)/Contents/MacOS/app", bytes: 4_096)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        return bundle
    }

    /// A launchd job plist with a `Label`.
    @discardableResult
    func launchPlist(_ relative: String, label: String) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": "/bin/ls"], format: .xml, options: 0).write(to: target)
        return target
    }
}

/// The real Uninstaller and Installers on a fake home, fake applications folder and fake `/Library`, with a
/// remover that removes nothing and app quitting that is scripted.
@MainActor
struct UninstallerTests {
    private struct World {
        let home: URL
        let applications: URL
        let remover = RecordingRemover()
        let quitAsked = OSAllocatedUnfairLock(initialState: [[String]]())
        let privileged: FakePrivileged
        let log: OperationLog
        let scanner: LiveCleanupScanner

        init(
            _ tmp: TemporaryDirectory,
            fullDiskAccess: FullDiskAccess.Status = .denied,
            running: [String: String] = [:],
            refusesToQuit: Set<String> = [],
            mounted: Set<String> = [],
            privileged: FakePrivileged = FakePrivileged(),
            hasPrivileged: Bool = true
        ) throws {
            home = try tmp.directory("home")
            applications = try tmp.directory("Applications")
            let asked = quitAsked
            self.privileged = privileged
            log = OperationLog(fileURL: tmp.path("Support/operations.jsonl"))
            scanner = LiveCleanupScanner(
                home: home,
                permissions: FakePermissions(fullDiskAccess),
                remover: remover,
                log: log,
                git: nil,
                privileged: hasPrivileged ? privileged : nil,
                runningApps: { running },
                appFolders: [applications],
                systemLibrary: try tmp.directory("Library"),
                ownBundleID: "dev.asger.LivVitals",
                isKnownBundleID: { _ in false },
                quitApps: { ids in
                    asked.withLock { $0.append(ids.sorted()) }
                    return refusesToQuit.intersection(ids)
                },
                mountedImages: { mounted }
            )
        }

        func scan(_ module: AppModule) async throws -> ScanResult {
            try await scanner.scan(module: module, options: ScanOptions(), onUpdate: { _ in })
        }

        func clean(_ module: AppModule, _ items: [CleanupItem], dryRun: Bool = false, moveToTrash: Bool = true) async throws -> CleanupOutcome {
            try await scanner.clean(
                module: module, items, source: module.title,
                options: CleanOptions(moveToTrash: moveToTrash, dryRun: dryRun), onUpdate: { _ in }
            )
        }
    }

    // MARK: Uninstaller

    @Test func listsAppsWithTheirLeftoversAndOrphansApart() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let postman = try tmp.app("Applications/Postman.app", id: "com.postmanlabs.mac", name: "Postman")
            try tmp.app("Applications/Pages.app", id: "com.apple.iWork.Pages")
            try tmp.app("Applications/LivVitals.app", id: "dev.asger.LivVitals")
            try tmp.file("home/Library/Caches/com.postmanlabs.mac/c.bin", bytes: 3_000)
            try tmp.file("home/Library/Preferences/com.postmanlabs.mac.plist", bytes: 100)
            try tmp.file("home/Library/Application Support/Postman/data", bytes: 2_000)
            try tmp.file("home/Library/Caches/com.gone.App/c.bin", bytes: 1_000)

            let result = try await world.scan(.applications)
            // Apple's own apps and Liv Vitals itself are never offered.
            #expect(result.items.filter { $0.category == .applications }.map(\.name) == ["Postman.app"])

            let group = try #require(result.projectGroups.first)
            #expect(group.project.path == postman.path)
            #expect(group.items.map(\.name).sorted() == ["Postman", "Postman.app", "com.postmanlabs.mac", "com.postmanlabs.mac.plist"])
            #expect(group.items.allSatisfy { !$0.isBlocked && $0.isSelectedByDefault })

            let orphan = try #require(result.items.first { $0.group == nil })
            #expect(orphan.name == "com.gone.App")
            #expect(orphan.isSelectedByDefault == false)
            #expect(orphan.note == LiveCleanupScanner.orphanNote)
            // Containers and Group Containers wait for Full Disk Access.
            #expect(result.locationsNeedingAccess == 2)
        }
    }

    /// An app a normal user cannot move (read-only, like one owned by root), with a cache of its own and a launch
    /// daemon in the fake `/Library`.
    private func lockedApp(_ tmp: TemporaryDirectory, daemon: Bool = true) throws -> URL {
        let locked = try tmp.app("Applications/Locked.app", id: "com.example.locked")
        try tmp.file("home/Library/Caches/com.example.locked/c.bin", bytes: 1_000)
        if daemon { try tmp.launchPlist("Library/LaunchDaemons/com.example.locked.helper.plist", label: "com.example.locked.helper") }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        return locked
    }

    private func unlock(_ app: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
    }

    @Test func appsThatNeedAdminAreMarkedAndCanBeChecked() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let locked = try lockedApp(tmp)
            defer { unlock(locked) }

            let items = try await world.scan(.applications).items
            let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
            #expect(byName["Locked.app"]?.needsAdmin == true && byName["Locked.app"]?.blockedReason == nil)
            #expect(byName["com.example.locked.helper.plist"]?.needsAdmin == true && byName["com.example.locked.helper.plist"]?.blockedReason == nil)
            // The cache is the user's own, so it needs no password.
            #expect(byName["com.example.locked"]?.needsAdmin == false)
            #expect(items.allSatisfy { !$0.isBlocked })
        }
    }

    @Test func whatNeedsAdminGoesToOneRootCallAndTheRestToTheNormalRemover() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let locked = try lockedApp(tmp)
            defer { unlock(locked) }

            let items = try await world.scan(.applications).items
            let outcome = try await world.clean(.applications, items)

            #expect(world.privileged.trashed.count == 1)
            #expect(world.privileged.trashed[0].map(\.lastPathComponent).sorted() == ["Locked.app", "com.example.locked.helper.plist"])
            #expect(world.remover.trashed.map(\.lastPathComponent) == ["com.example.locked"])
            #expect(outcome.record.source == "Uninstaller" && outcome.record.itemCount == 3)
            #expect(outcome.failures.isEmpty && outcome.skipped.isEmpty)
            #expect(outcome.notice == LiveCleanupScanner.rootOwnedNotice)

            // One run in the log: the normal move and both root moves, the root ones with where they went.
            let logged = try await world.log.entries()
            #expect(logged.count == 3 && Set(logged.compactMap(\.runID)) == [outcome.record.id])
            #expect(logged.allSatisfy { $0.kind == .trash && $0.outcome == .done && $0.source == "Uninstaller" })
            let rootLines = logged.filter { $0.path.hasSuffix("Locked.app") || $0.path.hasSuffix(".helper.plist") }
            #expect(rootLines.count == 2 && rootLines.allSatisfy { $0.trashedPath?.contains("/.Trash/") == true })
        }
    }

    @Test func aLaunchAgentIsStoppedAsTheUserBeforeItsPlistIsMoved() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.app("Applications/Tool.app", id: "com.example.tool")
            try tmp.launchPlist("home/Library/LaunchAgents/com.example.tool.agent.plist", label: "com.example.tool.agent")
            try tmp.launchPlist("Library/LaunchAgents/com.example.tool.shared.plist", label: "com.example.tool.shared")

            let items = try await world.scan(.applications).items
            _ = try await world.clean(.applications, items)

            let uid = getuid()
            #expect(world.privileged.bootouts == [["gui/\(uid)/com.example.tool.agent", "gui/\(uid)/com.example.tool.shared"]])
            // Both agents run in the user's session, so stopping them needs no password. Moving the one that lives in
            // `/Library` does, and only that one goes to the root call.
            #expect(world.privileged.trashed.map { $0.map(\.lastPathComponent) } == [["com.example.tool.shared.plist"]])
            #expect(world.remover.trashed.map(\.lastPathComponent).contains("com.example.tool.agent.plist"))
        }
    }

    @Test func aLaunchDaemonIsStoppedInTheSystemDomainBeforeItIsMovedAsRoot() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let locked = try lockedApp(tmp)
            defer { unlock(locked) }

            let items = try await world.scan(.applications).items
            _ = try await world.clean(.applications, items)

            #expect(world.privileged.bootouts == [["system/com.example.locked.helper"]])
            #expect(world.privileged.order == ["bootout", "trash"])
        }
    }

    @Test func aServiceThatCannotBeStoppedKeepsItsFile() async throws {
        try await TemporaryDirectory.use { tmp in
            let uid = getuid()
            let privileged = FakePrivileged(bootoutFailures: ["gui/\(uid)/com.example.tool.agent": "Boot-out failed: 5: Input/output error"])
            let world = try World(tmp, privileged: privileged)
            try tmp.app("Applications/Tool.app", id: "com.example.tool")
            try tmp.launchPlist("home/Library/LaunchAgents/com.example.tool.agent.plist", label: "com.example.tool.agent")

            let items = try await world.scan(.applications).items
            let outcome = try await world.clean(.applications, items)
            #expect(outcome.skipped.map(\.item.name) == ["com.example.tool.agent.plist"])
            #expect(outcome.skipped.first?.reason == LiveCleanupScanner.serviceNotStoppedPrefix + "Boot-out failed: 5: Input/output error")
            #expect(world.remover.trashed.map(\.lastPathComponent) == ["Tool.app"])
        }
    }

    @Test func aDismissedPasswordSkipsWhatNeedsItAndStillRemovesTheRest() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, privileged: FakePrivileged(cancels: true))
            let locked = try lockedApp(tmp, daemon: false)
            defer { unlock(locked) }

            let items = try await world.scan(.applications).items
            let outcome = try await world.clean(.applications, items)
            #expect(outcome.skipped.map(\.item.name) == ["Locked.app"])
            #expect(outcome.skipped.first?.reason == LiveCleanupScanner.adminCancelledReason)
            #expect(world.remover.trashed.map(\.lastPathComponent) == ["com.example.locked"])
            #expect(outcome.record.itemCount == 1 && outcome.failures.isEmpty)
        }
    }

    @Test func aDismissedPasswordOnTheServiceStepDoesNotAskAgain() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, privileged: FakePrivileged(cancels: true))
            let locked = try lockedApp(tmp)
            defer { unlock(locked) }

            let items = try await world.scan(.applications).items
            let outcome = try await world.clean(.applications, items)
            #expect(world.privileged.order == ["bootout"])
            #expect(Set(outcome.skipped.map(\.item.name)) == ["Locked.app", "com.example.locked.helper.plist"])
            #expect(outcome.skipped.allSatisfy { $0.reason == LiveCleanupScanner.adminCancelledReason })
        }
    }

    @Test func aMoveThatFailsAsRootIsReportedWithItsReason() async throws {
        try await TemporaryDirectory.use { tmp in
            let lockedPath = tmp.resolved.appending(path: "Applications/Locked.app").path
            let privileged = FakePrivileged(trashFailures: [lockedPath: "mv: Operation not permitted"])
            let world = try World(tmp, privileged: privileged)
            let locked = try lockedApp(tmp, daemon: false)
            defer { unlock(locked) }

            let items = try await world.scan(.applications).items
            let outcome = try await world.clean(.applications, items.filter { $0.name == "Locked.app" })
            #expect(outcome.failures.map(\.item.name) == ["Locked.app"])
            #expect(outcome.failures.first?.reason == "mv: Operation not permitted")
            #expect(outcome.record.itemCount == 0)
        }
    }

    @Test func thePolicyRefusesAnAppleAppEvenIfItIsHandedOver() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let safari = try tmp.app("Applications/Safari.app", id: "com.apple.Safari")
            let sneaky = CleanupItem(url: safari, category: .applications, size: ByteSize(100), group: safari, needsAdmin: true)

            let outcome = try await world.clean(.applications, [sneaky])
            #expect(world.privileged.order.isEmpty)
            #expect(world.remover.trashed.isEmpty)
            #expect(outcome.skipped.map(\.reason) == ["Apple's own apps are never removed."])
        }
    }

    @Test func withMoveToTrashOffWhatNeedsAdminStillGoesToTheTrashAndTheScreenSaysSo() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let locked = try lockedApp(tmp, daemon: false)
            defer { unlock(locked) }

            let items = try await world.scan(.applications).items
            let outcome = try await world.clean(.applications, items, moveToTrash: false)
            // The user's own cache is deleted as the setting says; the root-owned app is only moved.
            #expect(world.remover.deleted.map(\.lastPathComponent) == ["com.example.locked"])
            #expect(world.privileged.trashed.count == 1)
            #expect(outcome.notice?.hasPrefix(LiveCleanupScanner.alwaysTrashNotice) == true)
            #expect(outcome.notice?.hasSuffix(LiveCleanupScanner.rootOwnedNotice) == true)
        }
    }

    @Test func aSimulatedUninstallOfAnAdminAppAsksForNothingAndLogsAPlan() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let locked = try lockedApp(tmp)
            defer { unlock(locked) }

            let items = try await world.scan(.applications).items
            let outcome = try await world.clean(.applications, items, dryRun: true)
            #expect(world.privileged.order.isEmpty)
            #expect(world.remover.trashed.isEmpty && world.remover.deleted.isEmpty)
            #expect(outcome.wasDryRun && outcome.notice == nil)
            let logged = try await world.log.entries()
            #expect(logged.count == 3 && logged.allSatisfy { $0.kind == .dryRun && $0.outcome == .planned })
        }
    }

    @Test func withoutAPrivilegedRunnerWhatNeedsAdminIsLeftAlone() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, hasPrivileged: false)
            let locked = try lockedApp(tmp, daemon: false)
            defer { unlock(locked) }

            let items = try await world.scan(.applications).items
            let outcome = try await world.clean(.applications, items)
            #expect(outcome.skipped.map(\.reason) == [LiveCleanupScanner.adminUnavailableReason])
            #expect(world.privileged.order.isEmpty)
            #expect(world.remover.trashed.map(\.lastPathComponent) == ["com.example.locked"])
        }
    }

    @Test func anItemTheScanBlockedNeverReachesTheRootCall() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let app = try tmp.app("Applications/Tool.app", id: "com.example.tool")
            let blocked = CleanupItem(url: app, category: .applications, size: ByteSize(1), group: app, blockedReason: "Not today.", needsAdmin: true)
            let outcome = try await world.clean(.applications, [blocked])
            #expect(world.privileged.order.isEmpty)
            #expect(outcome.skipped.map(\.reason) == ["Not today."])
        }
    }

    @Test func uninstallQuitsTheAppThenMovesItAndItsFilesToTheTrash() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, running: ["com.postmanlabs.mac": "Postman"])
            try tmp.app("Applications/Postman.app", id: "com.postmanlabs.mac", name: "Postman")
            try tmp.file("home/Library/Caches/com.postmanlabs.mac/c.bin", bytes: 3_000)

            let items = try await world.scan(.applications).items
            #expect(items.first { $0.category == .applications }?.note == LiveCleanupScanner.runningNote)
            #expect(await world.scanner.runningOwners(of: items) == ["Postman"])

            let outcome = try await world.clean(.applications, items)
            #expect(world.quitAsked.withLock { $0 } == [["com.postmanlabs.mac"]])
            #expect(world.remover.trashed.map(\.lastPathComponent).sorted() == ["Postman.app", "com.postmanlabs.mac"])
            #expect(outcome.record.source == "Uninstaller")
            #expect(outcome.record.itemCount == 2)
        }
    }

    @Test func anAppThatDoesNotQuitKeepsAllItsFiles() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, running: ["com.postmanlabs.mac": "Postman"], refusesToQuit: ["com.postmanlabs.mac"])
            try tmp.app("Applications/Postman.app", id: "com.postmanlabs.mac", name: "Postman")
            try tmp.app("Applications/Zed.app", id: "dev.zed.Zed", name: "Zed")
            try tmp.file("home/Library/Caches/com.postmanlabs.mac/c.bin", bytes: 3_000)

            let items = try await world.scan(.applications).items
            let outcome = try await world.clean(.applications, items)
            #expect(world.remover.trashed.map(\.lastPathComponent) == ["Zed.app"])
            #expect(outcome.skipped.map(\.reason) == [LiveCleanupScanner.stillRunningReason, LiveCleanupScanner.stillRunningReason])
        }
    }

    @Test func aSimulatedUninstallQuitsNothingAndMovesNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, running: ["com.postmanlabs.mac": "Postman"])
            try tmp.app("Applications/Postman.app", id: "com.postmanlabs.mac", name: "Postman")
            let items = try await world.scan(.applications).items
            let outcome = try await world.clean(.applications, items, dryRun: true)
            #expect(world.quitAsked.withLock { $0 }.isEmpty)
            #expect(world.remover.trashed.isEmpty)
            #expect(outcome.wasDryRun)
        }
    }

    @Test func uninstallerAndInstallersAreReal() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            #expect(!world.scanner.isSimulated(.applications))
            #expect(!world.scanner.isSimulated(.installers))
            #expect(!world.scanner.isSimulated(.smartCare))
        }
    }

    // MARK: Installers

    @Test func installersAreFoundInDownloadsAndOnTheDesktopOnly() async throws {
        try await TemporaryDirectory.use { tmp in
            let mounted = tmp.path("home/Downloads/Mounted.dmg")
            let world = try World(tmp, mounted: [mounted.path])
            try tmp.app("Applications/Raycast.app", id: "com.raycast.macos", name: "Raycast")
            try tmp.file("home/Downloads/Raycast.dmg", bytes: 5_000)
            try tmp.file("home/Downloads/Old/ubuntu-24.04.iso", bytes: 9_000)
            try tmp.file("home/Downloads/Mounted.dmg", bytes: 2_000)
            try tmp.file("home/Desktop/Tool.pkg", bytes: 1_000)
            try tmp.file("home/Desktop/Notes.txt", bytes: 1_000)
            try tmp.file("home/Desktop/Folder/Deep.dmg", bytes: 1_000)
            try tmp.file("home/Library/Caches/Homebrew/downloads/abc--wget.tar.gz", bytes: 3_000)

            let result = try await world.scan(.installers)
            let byName = Dictionary(uniqueKeysWithValues: result.items.map { ($0.name, $0) })
            #expect(byName.keys.sorted() == ["Mounted.dmg", "Raycast.dmg", "Tool.pkg", "downloads", "ubuntu-24.04.iso"])
            #expect(byName["Raycast.dmg"]?.isSelectedByDefault == true)
            #expect(byName["Raycast.dmg"]?.note == "Raycast is installed.")
            #expect(byName["ubuntu-24.04.iso"]?.isSelectedByDefault == false)
            #expect(byName["Mounted.dmg"]?.blockedReason == LiveCleanupScanner.mountedReason)
            #expect(byName["downloads"]?.isSelectedByDefault == true)

            // The Desktop exception lets the installer go, nothing else there.
            let desktopItem = try #require(byName["Tool.pkg"])
            let outcome = try await world.clean(.installers, [desktopItem, try #require(byName["Mounted.dmg"])])
            #expect(world.remover.trashed.map(\.lastPathComponent) == ["Tool.pkg"])
            #expect(outcome.skipped.map(\.item.name) == ["Mounted.dmg"])

            let notes = CleanupItem(url: tmp.path("home/Desktop/Notes.txt"), category: .installers, size: ByteSize(1_000))
            _ = try await world.clean(.installers, [notes])
            #expect(world.remover.trashed.map(\.lastPathComponent) == ["Tool.pkg"])
        }
    }

    @Test func installerFoldersFromSettingsReplaceTheDefaultsAndTheDesktopStaysOneLevelDeep() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/Downloads/Ignored.dmg", bytes: 2_000)
            try tmp.file("home/Stash/Tool.dmg", bytes: 3_000)
            try tmp.file("home/Stash/Deep/Er/Est/TooDeep.dmg", bytes: 3_000)
            try tmp.file("home/Stash/A/B/Three.pkg", bytes: 3_000)
            try tmp.file("home/Desktop/Top.pkg", bytes: 1_000)
            try tmp.file("home/Desktop/Folder/Nested.dmg", bytes: 1_000)

            let folders = [tmp.path("home/Stash"), tmp.path("home/Desktop")]
            let result = try await world.scanner.scan(module: .installers, options: ScanOptions(installerFolders: folders), onUpdate: { _ in })
            #expect(result.items.map(\.name).sorted() == ["Three.pkg", "Tool.dmg", "Top.pkg"])

            // Cleaning follows the same folders: the old default folder is no longer a root.
            let ignored = CleanupItem(url: tmp.path("home/Downloads/Ignored.dmg"), category: .installers, size: ByteSize(2_000))
            let outcome = try await world.scanner.clean(
                module: .installers, [ignored] + result.items, source: "Installers",
                options: CleanOptions(installerFolders: folders), onUpdate: { _ in }
            )
            #expect(world.remover.trashed.map(\.lastPathComponent).sorted() == ["Three.pkg", "Tool.dmg", "Top.pkg"])
            #expect(outcome.skipped.map(\.item.name) == ["Ignored.dmg"])
        }
    }

    // MARK: Selection

    private func readyModel(_ items: [CleanupItem], module: AppModule = .applications) async -> ScanFlowModel {
        var scanner = FakeCleanupScanner()
        scanner.result = ScanResult(items: items)
        let model = ScanFlowModel(module: module, scanner: scanner)
        model.startScan()
        _ = await waitUntil { model.phase == .results }
        return model
    }

    private func appItems(blocked: Bool = false) -> [CleanupItem] {
        let bundle = URL(filePath: "/Applications/Zed.app", directoryHint: .isDirectory)
        return [
            CleanupItem(url: bundle, category: .applications, size: ByteSize(500), group: bundle, blockedReason: blocked ? "No." : nil),
            CleanupItem(url: URL(filePath: "/tmp/home/Library/Caches/dev.zed.Zed"), category: .appLeftovers, size: ByteSize(50), group: bundle),
            CleanupItem(
                url: URL(filePath: "/tmp/home/Library/Group Containers/group.dev.zed.Zed"), category: .appLeftovers, size: ByteSize(10),
                isSelectedByDefault: false, group: bundle
            ),
        ]
    }

    @Test func nothingIsSelectedAfterTheScanAndTheAppCheckboxPicksTheSafeLeftovers() async {
        let items = appItems()
        let model = await readyModel(items)
        #expect(model.selection.isEmpty)

        model.toggleAll(items)
        #expect(model.selection == Set(items.prefix(2).map(\.id)))
        #expect(model.checkState(of: items) == .some)

        model.toggleAll(items)
        #expect(model.selection.isEmpty)
    }

    @Test func blockedItemsCannotBeChecked() async {
        let items = appItems(blocked: true)
        let model = await readyModel(items)
        model.toggle(items[0])
        #expect(model.selection.isEmpty)
        model.toggleAll(items)
        #expect(!model.selection.contains(items[0].id))
    }

    @Test func otherModulesStillStartWithTheirDefaults() async {
        let items = appItems()
        let model = await readyModel(items, module: .installers)
        #expect(model.selection == Set(items.prefix(2).map(\.id)))
    }
}
