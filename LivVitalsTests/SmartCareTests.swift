import Foundation
import LivCore
import Testing
@testable import LivVitals

/// Smart Care on a fake home: Cleanup, Installers and Dev Projects scanned together and cleaned as one run, with
/// a remover that removes nothing.
@MainActor
struct SmartCareTests {
    private struct World {
        let home: URL
        let log: OperationLog
        let remover = RecordingRemover()
        let scanner: LiveCleanupScanner

        init(_ tmp: TemporaryDirectory) throws {
            home = try tmp.directory("home")
            log = OperationLog(fileURL: tmp.path("Support/operations.jsonl"))
            scanner = LiveCleanupScanner(
                home: home,
                permissions: FakePermissions(.denied),
                remover: remover,
                log: log,
                git: nil,
                runningApps: { [:] },
                appFolders: [tmp.path("Applications")],
                systemLibrary: tmp.path("Library"),
                isKnownBundleID: { _ in false },
                quitApps: { _ in [] },
                mountedImages: { [] }
            )
        }

        var code: URL { home.appending(path: "code", directoryHint: .isDirectory) }

        func scan(roots: [URL]? = nil) async throws -> ScanResult {
            try await scanner.scan(module: .smartCare, options: ScanOptions(projectRoots: roots ?? [code]), onUpdate: { _ in })
        }
    }

    /// A cache, an installer of an installed app, one of an app that is not installed, a Homebrew download and a
    /// project with `node_modules`.
    private func fill(_ tmp: TemporaryDirectory) throws {
        try tmp.file("home/Library/Caches/com.spotify.client/a.bin", bytes: 20_000)
        try tmp.app("Applications/Raycast.app", id: "com.raycast.macos", name: "Raycast")
        try tmp.file("home/Downloads/Raycast.dmg", bytes: 5_000)
        try tmp.file("home/Downloads/ubuntu-24.04.iso", bytes: 9_000)
        try tmp.file("home/Library/Caches/Homebrew/downloads/abc--wget.tar.gz", bytes: 3_000)
        try tmp.file("home/code/app/package.json", bytes: 100)
        try tmp.file("home/code/app/node_modules/dep/index.js", bytes: 20_000)
        try tmp.age("home/code/app/package.json", days: 30)
    }

    @Test func theCombinedScanListsEachThingOnceAndOnlyTheInstallersMarkedByDefault() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try fill(tmp)

            let result = try await world.scan()
            let byName = Dictionary(uniqueKeysWithValues: result.items.map { ($0.name, $0) })
            #expect(byName.keys.sorted() == ["Raycast.dmg", "com.spotify.client", "downloads", "node_modules"])
            // The unmatched installer is for the user to pick in Installers.
            #expect(byName["ubuntu-24.04.iso"] == nil)
            #expect(Set(result.items.map(\.url)).count == result.items.count)

            #expect(byName["com.spotify.client"]?.module == "cleanup")
            #expect(byName["Raycast.dmg"]?.module == "installers")
            #expect(byName["downloads"]?.module == "installers")
            #expect(byName["node_modules"]?.module == "devProjects")
            // Smart Care never offers uninstalling, leftovers or Space Lens items.
            #expect(result.items.allSatisfy { !["applications", "spaceLens"].contains($0.module ?? "") })
            #expect(!result.items.contains { $0.category == .applications || $0.category == .appLeftovers })
        }
    }

    @Test func aFolderFoundByCleanupSwallowsWhatDevProjectsFoundInsideIt() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            // A project inside a cache folder: Cleanup lists the whole folder and Dev Projects the folder inside it.
            try tmp.file("home/Library/Caches/proj/package.json", bytes: 100)
            try tmp.file("home/Library/Caches/proj/node_modules/dep/index.js", bytes: 20_000)
            try tmp.age("home/Library/Caches/proj/package.json", days: 30)

            let result = try await world.scan(roots: [tmp.path("home/Library/Caches")])
            #expect(result.items.map(\.name) == ["proj"])
            #expect(result.items.first?.module == "cleanup")
        }
    }

    @Test func projectFoldersThatDoNotExistAreNotReportedAndAScanThatFailsDoesNotStopTheOthers() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try fill(tmp)

            let missing = try await world.scan(roots: [tmp.path("home/Projects")])
            #expect(missing.issues.isEmpty)
            #expect(missing.items.map(\.name).contains("com.spotify.client"))

            struct Broken: Error, LocalizedError { var errorDescription: String? { "boom" } }
            let failed = try await world.scanner.attempt(.installers) { throw Broken() }
            #expect(failed.items.isEmpty)
            #expect(failed.issues.map(\.reason) == ["Installers could not be scanned: boom"])
            await #expect(throws: CancellationError.self) {
                _ = try await world.scanner.attempt(.cleanup) { throw CancellationError() }
            }
        }
    }

    @Test func cleaningRunsEachModulesItemsUnderOneRunAndHistoryShowsOneSmartCareRow() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try fill(tmp)
            let result = try await world.scan()

            let outcome = try await world.scanner.clean(
                module: .smartCare, result.items, source: "Smart Care",
                options: CleanOptions(projectRoots: [world.code]), onUpdate: { _ in }
            )

            #expect(Set(world.remover.trashed.map(\.lastPathComponent)) == ["com.spotify.client", "Raycast.dmg", "downloads", "node_modules"])
            #expect(outcome.record.itemCount == 4)
            #expect(outcome.record.source == "Smart Care")

            let entries = try await world.log.entries().filter { $0.kind == .trash }
            #expect(entries.count == 4)
            #expect(Set(entries.map(\.runID)) == [outcome.record.id])
            #expect(Set(entries.compactMap(\.source)) == ["Smart Care"])

            let runs = HistoryBuilder.runs(from: try await world.log.entries())
            #expect(runs.count == 1)
            #expect(runs[0].record.source == "Smart Care" && runs[0].record.itemCount == 4)
        }
    }

    @Test func eachModulesOwnGuardStillApplies() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try fill(tmp)
            let result = try await world.scan()
            // Dev Projects may only clean inside the project folders: with none configured the project item is refused.
            let outcome = try await world.scanner.clean(
                module: .smartCare, result.items, source: "Smart Care", options: CleanOptions(), onUpdate: { _ in }
            )
            #expect(!world.remover.trashed.contains { $0.lastPathComponent == "node_modules" })
            #expect(outcome.skipped.map(\.item.name).contains("node_modules"))
            #expect(world.remover.trashed.map(\.lastPathComponent).contains("com.spotify.client"))
        }
    }

    // MARK: The screen's model

    private func smartCareModel(
        items: [CleanupItem] = [CleanupItem(url: URL(filePath: "/tmp/home/Library/Caches/a"), category: .userCaches, size: ByteSize(100), module: "cleanup")],
        maintenance: FakeMaintenance = FakeMaintenance(),
        ruleInstalled: Bool = false,
        scanner: FakeCleanupScanner? = nil
    ) async -> (ScanFlowModel, FakeCleanupScanner, FakeMaintenance) {
        var configured = scanner ?? FakeCleanupScanner()
        configured.result = ScanResult(items: items)
        let model = ScanFlowModel(module: .smartCare, scanner: configured)
        model.maintenance = maintenance
        model.isRuleInstalled = { ruleInstalled }
        model.readHealth = { MetricsSnapshot.sample(health: 91) }
        model.previewBeforeCleaning = { false }
        model.startScan()
        _ = await waitUntil { model.phase == .results }
        return (model, configured, maintenance)
    }

    @Test func tasksThatAskForAPasswordStartCheckedOnlyWithTheRuleInstalled() async {
        let (without, _, _) = await smartCareModel(ruleInstalled: false)
        #expect(without.maintenanceSelection == ["a"])
        #expect(without.isAdminRuleInstalled == false)

        let (with, _, _) = await smartCareModel(ruleInstalled: true)
        #expect(with.maintenanceSelection == ["a", "b"])
        // "c" is not checked by default in Performance either.
        #expect(!with.maintenanceSelection.contains("c"))
    }

    @Test func theHealthReadingArrivesWithoutHoldingBackTheResults() async {
        let (model, _, _) = await smartCareModel()
        _ = await waitUntil { model.health != nil }
        #expect(model.health?.health == 91)
    }

    @Test func runningCleansFirstAndThenRunsTheSelectedTasksAndReportsBoth() async {
        var maintenance = FakeMaintenance()
        maintenance.outcomes = ["a": .failed("nope")]
        let (model, scanner, fake) = await smartCareModel(maintenance: maintenance, ruleInstalled: true)
        model.toggleMaintenance(maintenance.tasks[2])

        model.requestClean()
        #expect(await waitUntil { model.phase == .done })

        #expect(scanner.calls.withLock { $0.cleaned.count } == 1)
        #expect(fake.calls.withLock { $0.map(\.ids) } == [["a", "b", "c"]])
        let report = model.maintenanceReport
        #expect(report?.done.map(\.id) == ["b", "c"])
        #expect(report?.failed.map(\.task.id) == ["a"])
        #expect(report?.failed.first?.reason == "nope")
        #expect(model.lastCleanup?.itemCount == 1)
        #expect(!model.isMaintenanceOnly)
    }

    @Test func withNothingSelectedToCleanTheTasksStillRunAndTheCleanerIsNotCalled() async {
        let (model, scanner, fake) = await smartCareModel()
        for item in model.selectedItems { model.toggle(item) }
        #expect(model.selection.isEmpty && model.hasWork)

        model.requestClean()
        #expect(await waitUntil { model.phase == .done })

        #expect(scanner.calls.withLock { $0.cleaned }.isEmpty)
        #expect(fake.calls.withLock { $0.count } == 1)
        #expect(model.isMaintenanceOnly)
    }

    @Test func aDryRunSimulatesTheTasksToo() async {
        let (model, _, fake) = await smartCareModel()
        model.options = { CleanOptions(dryRun: true) }
        model.requestClean()
        #expect(await waitUntil { model.phase == .done })
        #expect(fake.calls.withLock { $0.map(\.dryRun) } == [true])
    }

    @Test func theConfirmationCountsTheTasksAndThoseThatNeedThePassword() async {
        let (model, _, _) = await smartCareModel(ruleInstalled: false)
        model.toggleMaintenance(model.maintenanceTasks[1])
        model.previewBeforeCleaning = { true }
        model.requestClean()
        #expect(await waitUntil { model.confirmation != nil })
        #expect(model.confirmation?.maintenanceCount == 2)
        #expect(model.confirmation?.maintenanceAdminCount == 1)
    }

    @Test func otherModulesNeverShowOrRunMaintenance() async {
        var scanner = FakeCleanupScanner()
        scanner.result = ScanResult(items: [CleanupItem(url: URL(filePath: "/tmp/home/Library/Caches/a"), category: .userCaches, size: ByteSize(1))])
        let model = ScanFlowModel(module: .cleanup, scanner: scanner)
        model.maintenance = FakeMaintenance()
        model.previewBeforeCleaning = { false }
        model.startScan()
        _ = await waitUntil { model.phase == .results }
        #expect(model.maintenanceTasks.isEmpty && model.maintenanceSelection.isEmpty)
        model.requestClean()
        _ = await waitUntil { model.phase == .done }
        #expect(model.maintenanceReport == nil)
    }
}
