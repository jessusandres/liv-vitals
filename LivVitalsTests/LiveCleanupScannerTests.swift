import Foundation
import LivCore
import os
import Testing
@testable import LivVitals

/// The real cleaning service on a fake home inside the temporary folder, with a remover that removes nothing.
@MainActor
struct LiveCleanupScannerTests {
    private struct World {
        let home: URL
        let log: OperationLog
        let remover = RecordingRemover()
        let git = FakeGit()
        let scanner: LiveCleanupScanner

        init(
            _ tmp: TemporaryDirectory,
            fullDiskAccess: FullDiskAccess.Status = .denied,
            running: [String: String] = [:],
            hasGit: Bool = true
        ) throws {
            home = try tmp.directory("home")
            log = OperationLog(fileURL: tmp.path("Support/operations.jsonl"))
            scanner = LiveCleanupScanner(
                home: home,
                permissions: FakePermissions(fullDiskAccess),
                remover: remover,
                log: log,
                git: hasGit ? git : nil,
                runningApps: { running },
                // Never the real /Applications or /Library, even in tests that do not scan them.
                appFolders: [tmp.path("Applications")],
                systemLibrary: tmp.path("Library"),
                isKnownBundleID: { _ in false },
                quitApps: { _ in [] },
                mountedImages: { [] }
            )
        }

        func scan(whitelist: [URL] = []) async throws -> ScanResult {
            try await scanner.scan(module: .cleanup, options: ScanOptions(whitelist: whitelist), onUpdate: { _ in })
        }

        /// The project folder the Dev Projects tests search.
        var code: URL { home.appending(path: "code", directoryHint: .isDirectory) }

        func scanProjects(skipRecent: Bool = true, roots: [URL]? = nil) async throws -> ScanResult {
            let options = ScanOptions(projectRoots: roots ?? [code], skipRecentProjects: skipRecent)
            return try await scanner.scan(module: .devProjects, options: options, onUpdate: { _ in })
        }

        func options(moveToTrash: Bool = true, dryRun: Bool = false, whitelist: [URL] = [], projectRoots: [URL] = []) -> CleanOptions {
            CleanOptions(moveToTrash: moveToTrash, dryRun: dryRun, whitelist: whitelist, projectRoots: projectRoots)
        }
    }

    private func names(_ result: ScanResult) -> [String] {
        result.items.map(\.name).sorted()
    }

    // MARK: Scanning

    @Test func scanFindsWhatTheRulesDescribeAndLeavesAppleCachesAlone() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/Library/Caches/com.spotify.client/a.bin", bytes: 20_000)
            try tmp.file("home/Library/Caches/com.apple.Maps/a.bin", bytes: 20_000)
            try tmp.file("home/Library/Caches/com.apple.dt.Xcode/a.bin", bytes: 20_000)
            try tmp.file("home/Library/Logs/App/log.txt", bytes: 5_000)
            try tmp.file("home/.npm/_cacache/index/x", bytes: 8_000)
            try tmp.directory("home/Library/Caches/empty-one")

            let result = try await world.scan()
            #expect(names(result) == ["App", "_cacache", "com.apple.dt.Xcode", "com.spotify.client"])
            let byName = Dictionary(uniqueKeysWithValues: result.items.map { ($0.name, $0) })
            #expect(byName["com.spotify.client"]?.category == .userCaches)
            #expect(byName["com.spotify.client"]?.ruleID == "user-caches")
            #expect(byName["com.apple.dt.Xcode"]?.ruleID == "xcode-caches")
            #expect(byName["App"]?.category == .logs)
            #expect(byName["_cacache"]?.category == .developerTools)
            #expect(result.items.allSatisfy { $0.size.bytes > 0 && $0.url.hasDirectoryPath })
        }
    }

    @Test func withoutFullDiskAccessTheProtectedRulesAreReportedNotScanned() async throws {
        try await TemporaryDirectory.use { tmp in
            let denied = try World(tmp)
            try tmp.file("home/Library/Caches/com.apple.Safari/a.bin", bytes: 20_000)
            try tmp.file("home/.Trash/old.bin", bytes: 20_000)
            let result = try await denied.scan()
            #expect(result.items.isEmpty)
            #expect(result.locationsNeedingAccess == 2)

            let allowed = try World(tmp, fullDiskAccess: .granted)
            let full = try await allowed.scan()
            #expect(names(full) == ["com.apple.Safari", "old.bin"])
            #expect(full.locationsNeedingAccess == 0)
            // The Trash is never preselected: emptying it is permanent.
            #expect(full.items.first { $0.category == .trash }?.isSelectedByDefault == false)
            #expect(full.items.first { $0.name == "com.apple.Safari" }?.isSelectedByDefault == true)
        }
    }

    @Test func aRunningOwnerAppUnchecksItsItemsAndSaysWhy() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, running: ["com.google.Chrome": "Google Chrome"])
            try tmp.file("home/Library/Caches/Google/Chrome/Default/Cache/data_0", bytes: 30_000)
            try tmp.file("home/Library/Caches/com.example.app/a.bin", bytes: 30_000)

            let result = try await world.scan()
            let chrome = try #require(result.items.first { $0.ruleID == "chrome-cache" })
            #expect(!chrome.isSelectedByDefault)
            #expect(chrome.note == "Quit Google Chrome to clean this.")
            let other = try #require(result.items.first { $0.ruleID == "user-caches" })
            #expect(other.isSelectedByDefault && other.note == nil)

            #expect(await world.scanner.runningOwners(of: [chrome, other]) == ["Google Chrome"])
            #expect(await world.scanner.runningOwners(of: [other]).isEmpty)
        }
    }

    @Test func aMostlySharedItemStartsUncheckedWithANote() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let stored = try tmp.file("home/Library/pnpm/store/v3/files/ab/data.bin", bytes: 200_000)
            try tmp.file("home/Library/pnpm/store/v3/small.bin", bytes: 1_000)
            // A project elsewhere keeps its own name for the same data.
            try tmp.hardLink("projects/app/node_modules/data.bin", to: stored)

            let result = try await world.scan()
            let pnpm = try #require(result.items.first { $0.ruleID == "pnpm-store" })
            #expect(!pnpm.isSelectedByDefault)
            #expect(pnpm.note == LiveCleanupScanner.sharedNote)
        }
    }

    @Test func aWhitelistedFolderIsNeitherScannedNorMeasured() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/Library/Caches/keep/a.bin", bytes: 20_000)
            try tmp.file("home/Library/Caches/drop/a.bin", bytes: 20_000)
            let result = try await world.scan(whitelist: [tmp.path("home/Library/Caches/keep")])
            #expect(names(result) == ["drop"])
        }
    }

    @Test func scanReportsProgressAsRulesFinish() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            for index in 0..<4 { try tmp.file("home/Library/Caches/c\(index)/a.bin", bytes: 5_000) }
            let fractions = OSAllocatedUnfairLockBox<[Double]>([])
            _ = try await world.scanner.scan(module: .cleanup, options: ScanOptions()) { update in
                if let fraction = update.fraction { fractions.append(fraction) }
            }
            let seen = fractions.value
            #expect(seen.last == 1)
            #expect(seen.allSatisfy { (0...1).contains($0) })
        }
    }

    @Test func noModuleOfTheLiveAppIsLabelledAsSimulatedAnyMore() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let store = AppStore(services: .fake(cleanup: world.scanner, history: LiveHistory(log: world.log)))
            #expect(!store.showsPreviewData(for: .cleanup))
            #expect(!store.showsPreviewData(for: .history))
            #expect(!store.showsPreviewData(for: .smartCare))
            #expect(!store.showsPreviewData(for: .devProjects))
            #expect(!store.showsPreviewData(for: .installers))
            #expect(!store.showsPreviewData(for: .applications))
        }
    }

    @Test func everyModuleOfTheRealServiceIsReal() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            for module in AppModule.allCases { #expect(!world.scanner.isSimulated(module)) }
        }
    }

    // MARK: Dev Projects

    /// A project with a `package.json` and an installed `node_modules`, last edited a month ago.
    private func nodeProject(_ tmp: TemporaryDirectory, _ name: String, git: Bool = false) throws {
        try tmp.file("home/code/\(name)/package.json", bytes: 100)
        try tmp.file("home/code/\(name)/node_modules/dep/index.js", bytes: 20_000)
        if git { try tmp.directory("home/code/\(name)/.git") }
        try tmp.age("home/code/\(name)/package.json", days: 30)
    }

    @Test func devProjectsScansRealArtifactsGroupedByProject() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try nodeProject(tmp, "app")
            try tmp.file("home/code/loose/node_modules/dep/index.js", bytes: 20_000)

            let result = try await world.scanProjects()
            let found = try #require(result.items.first)
            #expect(result.items.count == 1)
            #expect(found.category == .projectArtifacts)
            #expect(found.ruleID == "node-modules")
            #expect(found.group?.lastPathComponent == "app")
            #expect(found.isSelectedByDefault)
            #expect(result.projectGroups.count == 1)
        }
    }

    @Test func devProjectsReportsRootsThatDoNotExistInsteadOfFailing() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let missing = tmp.path("home/Projects")

            let result = try await world.scanProjects(roots: [missing])
            #expect(result.items.isEmpty)
            #expect(result.issues.map(\.url) == [missing])
        }
    }

    @Test func devProjectsReportsProgressWhileSearchingAndMeasuring() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try nodeProject(tmp, "app")
            let fractions = OSAllocatedUnfairLockBox<[Double]>([])
            let searching = OSAllocatedUnfairLockBox<[Double]>([])

            _ = try await world.scanner.scan(module: .devProjects, options: ScanOptions(projectRoots: [world.code])) { update in
                if let fraction = update.fraction { fractions.append(fraction) } else { searching.append(0) }
            }
            #expect(!searching.value.isEmpty)
            #expect(fractions.value.last == 1)
        }
    }

    @Test func cleaningDevProjectsMovesTheFolderToTheTrashAndLogsItUnderDevProjects() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try nodeProject(tmp, "app")
            let result = try await world.scanProjects()

            let outcome = try await world.scanner.clean(
                module: .devProjects, result.items, source: "Dev Projects",
                options: world.options(projectRoots: [world.code]), onUpdate: { _ in }
            )

            #expect(world.remover.trashed.map(\.lastPathComponent) == ["node_modules"])
            #expect(outcome.record.itemCount == 1)
            #expect(outcome.record.source == "Dev Projects")
            #expect(outcome.skipped.isEmpty && outcome.failures.isEmpty)
            let logged = try await world.log.entries()
            #expect(logged.count == 1 && logged[0].source == "Dev Projects" && logged[0].outcome == .done)
        }
    }

    @Test func aSimulatedDevProjectsCleaningLogsAPlanAndMovesNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try nodeProject(tmp, "app")
            let result = try await world.scanProjects()

            let outcome = try await world.scanner.clean(
                module: .devProjects, result.items, source: "Dev Projects",
                options: world.options(dryRun: true, projectRoots: [world.code]), onUpdate: { _ in }
            )

            #expect(outcome.wasDryRun)
            #expect(world.remover.trashed.isEmpty && world.remover.deleted.isEmpty)
            let logged = try await world.log.entries()
            #expect(logged.map(\.kind) == [.dryRun])
        }
    }

    @Test func anItemThatBecameTrackedByGitIsSkippedAndNeverReachesTheRemover() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try nodeProject(tmp, "tracked-now", git: true)
            try nodeProject(tmp, "plain", git: true)
            let result = try await world.scanProjects()
            #expect(result.items.count == 2)
            let tracked = try #require(result.items.first { $0.group?.lastPathComponent == "tracked-now" })

            // Between the scan and the cleaning, the project starts tracking the folder.
            world.git.track(tracked.url.path)
            let outcome = try await world.scanner.clean(
                module: .devProjects, result.items, source: "Dev Projects",
                options: world.options(projectRoots: [world.code]), onUpdate: { _ in }
            )

            #expect(world.remover.trashed.map { $0.deletingLastPathComponent().lastPathComponent } == ["plain"])
            #expect(outcome.skipped.map(\.item.url) == [tracked.url])
            #expect(outcome.skipped.first?.reason == "Tracked by git")
            #expect(outcome.record.itemCount == 1)
        }
    }

    @Test func ifEverythingSelectedIsTrackedNothingRunsAndNothingIsLogged() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try nodeProject(tmp, "app", git: true)
            let result = try await world.scanProjects()
            world.git.track(try #require(result.items.first).url.path)

            let outcome = try await world.scanner.clean(
                module: .devProjects, result.items, source: "Dev Projects",
                options: world.options(projectRoots: [world.code]), onUpdate: { _ in }
            )
            #expect(outcome.isEmpty && outcome.skipped.count == 1)
            #expect(world.remover.trashed.isEmpty)
            #expect(try await world.log.entries().isEmpty)
        }
    }

    @Test func withoutGitARepositoryItemStartsUncheckedButTheUsersChoiceIsRespectedWhenCleaning() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, hasGit: false)
            try nodeProject(tmp, "repo", git: true)

            let result = try await world.scanProjects()
            let found = try #require(result.items.first)
            #expect(!found.isSelectedByDefault)
            #expect(found.note == DevProjectsScan.gitMissingNote)

            _ = try await world.scanner.clean(
                module: .devProjects, [found], source: "Dev Projects",
                options: world.options(projectRoots: [world.code]), onUpdate: { _ in }
            )
            #expect(world.remover.trashed.map(\.path) == [found.url.path])
        }
    }

    @Test func devProjectsRefusesToCleanOutsideTheProjectFolders() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/Library/Caches/com.example/a.bin", bytes: 20_000)
            let stray = CleanupItem(
                url: tmp.path("home/Library/Caches/com.example").appending(path: "", directoryHint: .isDirectory),
                category: .projectArtifacts, size: ByteSize(20_000), group: tmp.path("home/Library")
            )

            let outcome = try await world.scanner.clean(
                module: .devProjects, [stray], source: "Dev Projects",
                options: world.options(projectRoots: [world.code]), onUpdate: { _ in }
            )
            #expect(world.remover.trashed.isEmpty)
            #expect(outcome.record.itemCount == 0 && outcome.skipped.count == 1)
        }
    }

    // MARK: Cleaning

    @Test func cleaningMovesToTheTrashLogsTheRunAndBuildsTheOutcome() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/Library/Caches/com.one/a.bin", bytes: 20_000)
            try tmp.file("home/Library/Caches/com.two/a.bin", bytes: 30_000)
            let result = try await world.scan()

            let outcome = try await world.scanner.clean(module: .cleanup, result.items, source: "Cleanup", options: world.options(), onUpdate: { _ in })

            #expect(world.remover.trashed.map(\.lastPathComponent).sorted() == ["com.one", "com.two"])
            #expect(world.remover.deleted.isEmpty)
            #expect(outcome.record.itemCount == 2)
            #expect(outcome.trashedSize == result.totalSize)
            #expect(outcome.deletedSize == .zero)
            #expect(outcome.record.movedToTrash)
            #expect(outcome.failures.isEmpty && outcome.skipped.isEmpty && !outcome.wasDryRun)

            let logged = try await world.log.entries()
            #expect(logged.count == 2)
            #expect(logged.allSatisfy { $0.kind == .trash && $0.outcome == .done && $0.source == "Cleanup" })
            #expect(Set(logged.compactMap(\.runID)) == [outcome.record.id])
            #expect(logged.allSatisfy { $0.trashedPath?.hasPrefix("/fake/.Trash/") == true })
        }
    }

    @Test func permanentDeleteAndTheTrashCategoryUseDelete() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, fullDiskAccess: .granted)
            try tmp.file("home/Library/Caches/com.one/a.bin", bytes: 20_000)
            try tmp.file("home/.Trash/old.bin", bytes: 20_000)
            let result = try await world.scan()

            let outcome = try await world.scanner.clean(module: .cleanup, result.items, source: "Cleanup", options: world.options(moveToTrash: true), onUpdate: { _ in })
            // Even with "move to Trash" on, what is already in the Trash is deleted.
            #expect(world.remover.trashed.map(\.lastPathComponent) == ["com.one"])
            #expect(world.remover.deleted.map(\.lastPathComponent) == ["old.bin"])
            #expect(outcome.trashedSize.bytes > 0 && outcome.deletedSize.bytes > 0)
            #expect(!outcome.record.movedToTrash)

            let permanent = try await world.scanner.clean(module: .cleanup, result.items.filter { $0.category != .trash }, source: "Cleanup", options: world.options(moveToTrash: false), onUpdate: { _ in })
            #expect(world.remover.deleted.map(\.lastPathComponent).contains("com.one"))
            #expect(permanent.trashedSize == .zero)
        }
    }

    @Test func aDryRunLogsWhatWouldHappenAndChangesNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let file = try tmp.file("home/Library/Caches/com.one/a.bin", bytes: 20_000)
            let result = try await world.scan()

            let outcome = try await world.scanner.clean(module: .cleanup, result.items, source: "Cleanup", options: world.options(dryRun: true), onUpdate: { _ in })
            #expect(outcome.wasDryRun)
            #expect(outcome.record.itemCount == 0 && outcome.record.freed == .zero)
            #expect(world.remover.trashed.isEmpty && world.remover.deleted.isEmpty)
            #expect(FileManager.default.fileExists(atPath: file.path))
            let logged = try await world.log.entries()
            #expect(logged.map(\.kind) == [.dryRun])
            #expect(logged.map(\.outcome) == [.planned])
        }
    }

    @Test func nothingOutsideTheRulesFoldersCanBeCleaned() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let precious = try tmp.file("home/Documents/thesis.docx", bytes: 10_000)
            let sneaky = CleanupItem(url: precious, category: .userCaches, size: ByteSize(10_000))

            let outcome = try await world.scanner.clean(module: .cleanup, [sneaky], source: "Cleanup", options: world.options(), onUpdate: { _ in })
            #expect(outcome.record.itemCount == 0)
            #expect(outcome.skipped.count == 1)
            #expect(world.remover.trashed.isEmpty && world.remover.deleted.isEmpty)
        }
    }

    @Test func aPathWhitelistedAfterTheScanIsSkippedAtCleaningTime() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/Library/Caches/com.one/a.bin", bytes: 20_000)
            let result = try await world.scan()
            let whitelisted = tmp.path("home/Library/Caches/com.one")

            let outcome = try await world.scanner.clean(module: .cleanup, result.items, source: "Cleanup", options: world.options(whitelist: [whitelisted]), onUpdate: { _ in })
            #expect(outcome.skipped.count == 1)
            #expect(outcome.skipped[0].reason.hasPrefix("Excluded by the whitelist"))
            #expect(world.remover.trashed.isEmpty)
        }
    }

    @Test func smartCareLeavesItemsNoModuleFoundAloneAndNeverReachesTheRemoverWithThem() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            // An item built by hand has no module: Smart Care has no checks to clean it with.
            let made = try tmp.file("home/Library/Caches/com.one/a.bin", bytes: 20_000)
            let handmade = CleanupItem(url: made.deletingLastPathComponent(), category: .userCaches, size: ByteSize(5))
            let uninstaller = handmade.withModule("applications")
            let outcome = try await world.scanner.clean(module: .smartCare, [handmade, uninstaller], source: "Smart Care", options: world.options(), onUpdate: { _ in })
            #expect(outcome.record.itemCount == 0)
            #expect(outcome.skipped.count == 2)
            #expect(world.remover.trashed.isEmpty && world.remover.deleted.isEmpty)
        }
    }

    @Test func spaceLensCanRemoveFromTheHomeButNeverFromProtectedFolders() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let download = try tmp.file("home/Downloads/big.iso", bytes: 10_000)
            let document = try tmp.file("home/Documents/thesis.docx", bytes: 10_000)
            let items = [
                CleanupItem(url: download, category: .largeFiles, size: ByteSize(10_000)),
                CleanupItem(url: document, category: .largeFiles, size: ByteSize(10_000)),
            ]

            let outcome = try await world.scanner.clean(module: .spaceLens, items, source: "Space Lens", options: world.options(), onUpdate: { _ in })
            #expect(world.remover.trashed.map(\.lastPathComponent) == ["big.iso"])
            #expect(outcome.skipped.map(\.item.name) == ["thesis.docx"])
            #expect(outcome.skipped[0].reason.hasPrefix("Protected location"))
            #expect(try await world.log.entries().allSatisfy { $0.source == "Space Lens" })
        }
    }

    // MARK: Empty Trash

    @Test func emptyTrashNeedsFullDiskAccess() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, fullDiskAccess: .denied)
            try tmp.file("home/.Trash/old.bin", bytes: 20_000)
            await #expect(throws: CleanupServiceError.self) {
                try await world.scanner.emptyTrash(options: world.options(), onUpdate: { _ in })
            }
            #expect(world.remover.deleted.isEmpty)
        }
    }

    @Test func emptyTrashDeletesEverythingInItAndLogsItAsItsOwnRun() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, fullDiskAccess: .granted)
            try tmp.file("home/.Trash/one.bin", bytes: 20_000)
            try tmp.file("home/.Trash/folder/two.bin", bytes: 20_000)
            try tmp.file("home/Library/Caches/com.keep/a.bin", bytes: 20_000)

            let outcome = try await world.scanner.emptyTrash(options: world.options(), onUpdate: { _ in })
            #expect(world.remover.deleted.map(\.lastPathComponent).sorted() == ["folder", "one.bin"])
            #expect(world.remover.trashed.isEmpty)
            #expect(outcome.record.source == "Empty Trash")
            #expect(outcome.deletedSize.bytes > 0 && outcome.trashedSize == .zero)
            #expect(try await world.log.entries().allSatisfy { $0.kind == .delete && $0.source == "Empty Trash" })
        }
    }

    @Test func emptyTrashWithAnEmptyTrashDoesNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, fullDiskAccess: .granted)
            try tmp.directory("home/.Trash")
            let outcome = try await world.scanner.emptyTrash(options: world.options(), onUpdate: { _ in })
            #expect(outcome.record.itemCount == 0)
            #expect(world.remover.deleted.isEmpty)
        }
    }

    @Test func aSimulatedEmptyTrashChangesNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, fullDiskAccess: .granted)
            try tmp.file("home/.Trash/one.bin", bytes: 20_000)
            let outcome = try await world.scanner.emptyTrash(options: world.options(dryRun: true), onUpdate: { _ in })
            #expect(outcome.wasDryRun)
            #expect(world.remover.deleted.isEmpty)
        }
    }
}

/// A small lock-protected value a `@Sendable` callback can append to.
nonisolated final class OSAllocatedUnfairLockBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        lock = OSAllocatedUnfairLock(initialState: value)
    }

    var value: Value { lock.withLock { $0 } }
}

nonisolated extension OSAllocatedUnfairLockBox where Value == [Double] {
    func append(_ element: Double) { lock.withLock { $0.append(element) } }
}

struct LiveHistoryTests {
    @Test func runsAreReadFromTheRealLogFile() async throws {
        try await TemporaryDirectory.use { tmp in
            let log = OperationLog(fileURL: tmp.path("operations.jsonl"))
            let run = UUID()
            try await log.append([
                LogEntry(kind: .trash, path: "/x/a", bytes: 40, outcome: .done, runID: run, trashedPath: "/h/.Trash/a", source: "Cleanup"),
                LogEntry(kind: .dryRun, path: "/x/b", bytes: 40, outcome: .planned, runID: UUID()),
            ])
            let history = LiveHistory(log: log)
            let runs = await history.runs()
            #expect(runs.map(\.id) == [run])
            #expect(runs[0].items.map(\.trashedPath) == ["/h/.Trash/a"])
            #expect(!history.isSimulated)
        }
    }
}
