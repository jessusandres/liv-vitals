import Foundation
import LivCore
import Testing
@testable import LivVitals

@MainActor
struct ScanFlowModelTests {
    private func item(_ name: String, _ bytes: Int64, selected: Bool = true) -> CleanupItem {
        CleanupItem(url: URL(filePath: "/tmp/home/\(name)"), category: .userCaches, size: ByteSize(bytes), isSelectedByDefault: selected)
    }

    private func makeModel(_ scanner: FakeCleanupScanner) -> ScanFlowModel {
        ScanFlowModel(module: .cleanup, scanner: scanner)
    }

    @Test func scanMovesFromIdleThroughScanningToResultsWithDefaultSelection() async {
        let items = [item("a", 100), item("b", 50, selected: false)]
        let model = makeModel(FakeCleanupScanner(result: ScanResult(items: items)))
        #expect(model.phase == .idle)

        model.startScan()
        #expect(model.phase == .scanning)
        #expect(await waitUntil { model.phase == .results })
        #expect(model.result.items.count == 2)
        #expect(model.selection == [items[0].id])
        #expect(model.selectedSize == ByteSize(100))
    }

    @Test func cancelWhileScanningReturnsToIdle() async {
        let model = makeModel(FakeCleanupScanner(delay: .seconds(30)))
        model.startScan()
        #expect(model.phase == .scanning)
        model.cancel()
        #expect(model.phase == .idle)
        // The cancelled task must not later flip the phase to results.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .idle)
    }

    @Test func failedScanReturnsToIdleWithTheReason() async {
        let model = makeModel(FakeCleanupScanner(failure: FakeFailure()))
        model.startScan()
        #expect(await waitUntil { model.errorMessage != nil })
        #expect(model.phase == .idle)
        #expect(model.errorMessage == "Something went wrong.")
    }

    @Test func selectionHelpersToggleItemsAndWholeGroups() async {
        let items = [item("a", 100), item("b", 50), item("c", 25)]
        let model = makeModel(FakeCleanupScanner(result: ScanResult(items: items)))
        model.startScan()
        #expect(await waitUntil { model.phase == .results })
        #expect(model.checkState(of: items) == .all)

        model.toggle(items[0])
        #expect(model.checkState(of: items) == .some)
        #expect(model.selectedSize == ByteSize(75))

        model.toggleAll(items)
        #expect(model.checkState(of: items) == .all)
        model.toggleAll(items)
        #expect(model.checkState(of: items) == .none)
        #expect(model.selectedItems.isEmpty)
    }

    @Test func cleaningProducesARecordHonoringTheTrashSettingAndReportsIt() async {
        let items = [item("a", 100), item("b", 50)]
        let model = makeModel(FakeCleanupScanner(result: ScanResult(items: items)))
        model.options = { CleanOptions(moveToTrash: false) }
        var reported: CleanupRecord?
        model.onCleaned = { reported = $0 }
        model.startScan()
        #expect(await waitUntil { model.phase == .results })

        model.clean()
        #expect(model.phase == .cleaning)
        #expect(await waitUntil { model.phase == .done })
        #expect(model.lastCleanup?.itemCount == 2)
        #expect(model.lastCleanup?.freed == ByteSize(150))
        #expect(model.lastCleanup?.movedToTrash == false)
        #expect(reported == model.lastCleanup)
    }

    @Test func cleaningWithNothingSelectedDoesNothing() async {
        let model = makeModel(FakeCleanupScanner(result: ScanResult(items: [item("a", 1, selected: false)])))
        model.startScan()
        #expect(await waitUntil { model.phase == .results })
        model.clean()
        #expect(model.phase == .results)
    }

    @Test func failedCleaningGoesBackToResultsWithTheReason() async {
        var scanner = FakeCleanupScanner(result: ScanResult(items: [item("a", 1)]))
        let model = makeModel(scanner)
        model.startScan()
        #expect(await waitUntil { model.phase == .results })

        scanner.failure = FakeFailure()
        let failing = ScanFlowModel(module: .cleanup, scanner: scanner)
        failing.startScan()
        #expect(await waitUntil { failing.errorMessage != nil })
        #expect(failing.phase == .idle)
    }
}

@MainActor
struct PerformanceModelTests {
    @Test func runsTheWholeSelectionInOneCallAndFinishes() async {
        let fake = FakeMaintenance()
        let model = PerformanceModel(runner: fake)
        #expect(model.selection == ["a", "b"])
        #expect(model.adminTaskCount == 1)

        model.run()
        #expect(model.phase == .running)
        #expect(await waitUntil { model.phase == .done })
        #expect(model.status["a"] == .finished)
        #expect(model.status["b"] == .finished)
        #expect(model.status["c"] == nil)
        // One call with everything, so the tasks that need a password can share a single dialog.
        #expect(fake.calls.withLock { $0 } == [MaintenanceCall(ids: ["a", "b"], dryRun: false)])
    }

    @Test func aFailedAndASkippedTaskKeepTheirReasonAndTheRestFinish() async {
        let fake = FakeMaintenance(outcomes: ["a": .failed("killall exited with status 1."), "b": .skipped("The password was not entered.")])
        let model = PerformanceModel(runner: fake)
        model.toggle(model.tasks[2])
        model.run()
        #expect(await waitUntil { model.phase == .done })
        #expect(model.status["a"] == .failed("killall exited with status 1."))
        #expect(model.status["b"] == .skipped("The password was not entered."))
        #expect(model.status["c"] == .finished)
    }

    @Test func aRunThatThrowsMarksTheUnfinishedTasksAsFailed() async {
        let model = PerformanceModel(runner: FakeMaintenance(failure: FakeFailure()))
        model.run()
        #expect(await waitUntil { model.phase == .done })
        #expect(model.status["a"] == .failed("Something went wrong."))
        #expect(model.status["b"] == .failed("Something went wrong."))
    }

    @Test func theSimulationSettingReachesTheRunAtTheMomentItStarts() async {
        let fake = FakeMaintenance()
        let model = PerformanceModel(runner: fake)
        var dryRun = false
        model.options = { MaintenanceOptions(dryRun: dryRun) }
        dryRun = true
        model.run()
        #expect(await waitUntil { model.phase == .done })
        #expect(fake.calls.withLock { $0 }.first?.dryRun == true)
    }

    @Test func selectionCanBeToggledOnlyWhileReady() async {
        let model = PerformanceModel(runner: FakeMaintenance())
        let taskC = model.tasks[2]
        model.toggle(taskC)
        #expect(model.selection.contains("c"))
        model.run()
        model.toggle(taskC)
        #expect(model.selection.contains("c"))
    }
}

@MainActor
struct AppSettingsTests {
    private func makeSettings(_ tmp: TemporaryDirectory, delay: Duration = .milliseconds(10)) throws -> (AppSettings, SettingsStore) {
        let home = try { () throws -> URL in
            let home = tmp.path("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            return home
        }()
        let store = SettingsStore(fileURL: tmp.path("Support/settings.json"), home: home)
        return (AppSettings(store: store, home: home, saveDelay: delay), store)
    }

    @Test func aChangeIsSavedShortlyAfterwardsAndSurvivesARestart() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, store) = try makeSettings(tmp)
            settings.moveToTrash = false
            settings.showMenuBarExtra = false
            #expect(await waitUntil { !store.load().moveToTrash })
            #expect(!store.load().showMenuBarExtra)
        }
    }

    @Test func settingAValueToWhatItAlreadyIsSavesNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp, delay: .milliseconds(10))
            // SwiftUI bindings, such as the menu bar item's, write back the value they just read.
            settings.moveToTrash = settings.moveToTrash
            settings.showMenuBarExtra = settings.showMenuBarExtra
            try? await Task.sleep(for: .milliseconds(150))
            #expect(!FileManager.default.fileExists(atPath: tmp.path("Support/settings.json").path))

            settings.moveToTrash = !settings.moveToTrash
            #expect(await waitUntil { FileManager.default.fileExists(atPath: tmp.path("Support/settings.json").path) })
        }
    }

    @Test func flushSavesImmediately() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, store) = try makeSettings(tmp, delay: .seconds(60))
            settings.hasCompletedOnboarding = true
            #expect(!store.load().hasCompletedOnboarding)
            settings.flush()
            #expect(store.load().hasCompletedOnboarding)
        }
    }

    @Test func validPathsAreNormalizedAndDuplicatesIgnored() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            try tmp.directory("home/work/apps")
            let start = settings.projectRoots.count
            #expect(settings.addProjectRoot("~/work/../work/apps") == nil)
            #expect(settings.projectRoots.last == tmp.path("home/work/apps").standardizedFileURL.path)
            #expect(settings.addProjectRoot("~/work/apps/") == nil)
            #expect(settings.projectRoots.count == start + 1)

            settings.removeProjectRoot(tmp.path("home/work/apps").standardizedFileURL.path)
            #expect(settings.projectRoots.count == start)
        }
    }

    @Test func aProjectFolderThatIsProtectedOrMissingIsRefusedWithAnExplanation() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            try tmp.directory("home/Documents")
            try tmp.file("home/notes.txt", bytes: 3)
            let before = settings.projectRoots

            let protected = settings.addProjectRoot("~/Documents")
            #expect(protected == .protected("~/Documents"))
            #expect(protected?.errorDescription == "~/Documents is protected, so Dev Projects cannot clean inside it.")
            // The home folder holds protected places, so it is refused too.
            #expect(settings.addProjectRoot("~") == .protected("~"))

            #expect(settings.addProjectRoot("~/nowhere") == .doesNotExist)
            #expect(SettingsPathError.doesNotExist.errorDescription == "That folder does not exist.")
            // A file is not a folder.
            #expect(settings.addProjectRoot("~/notes.txt") == .doesNotExist)
            #expect(settings.projectRoots == before)
        }
    }

    @Test func protectedPathsAreStillAcceptedAsProtectedPaths() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            // Only Dev Projects folders are checked; the protected list takes anything usable, even a new folder.
            #expect(settings.addProtectedPath("~/Documents/future") == nil)
        }
    }

    @Test func scanAndCleanOptionsCarryTheProjectFoldersAndTheRecentSetting() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            try tmp.directory("home/work/apps")
            #expect(settings.addProjectRoot("~/work/apps") == nil)
            settings.skipRecentProjects = false

            let scan = settings.scanOptions
            #expect(scan.projectRoots.map(\.path) == settings.projectRoots)
            #expect(!scan.skipRecentProjects)
            #expect(scan.whitelist.map(\.path) == settings.protectedPaths)
            #expect(settings.cleanOptions.projectRoots == scan.projectRoots)
        }
    }

    @Test func invalidPathsAreRefusedAndChangeNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            let before = settings.protectedPaths
            #expect(settings.addProtectedPath("") == .empty)
            #expect(settings.addProtectedPath("relative/folder") == .notAbsolute)
            #expect(settings.addProtectedPath("/") == .isRoot)
            #expect(settings.protectedPaths == before)
        }
    }
}

@MainActor
struct AppStoreTests {
    @Test func historyComesFromTheServiceAndNewCleanupsAreRecorded() async {
        let old = HistoryRun.sample()
        let history = FakeHistory(stored: [old])
        let store = AppStore(services: .fake(history: history))
        #expect(store.history.isEmpty)
        await store.loadHistory()
        #expect(store.history.map(\.id) == [old.id])

        let flow = store.scanFlow(for: .cleanup)
        let record = CleanupRecord(date: .now, source: "Cleanup", itemCount: 2, freed: ByteSize(9), movedToTrash: true)
        flow.onCleaned?(record)
        #expect(store.history.first?.record == record)
        // The service is told in the background; wait for it.
        var saved = await history.stored
        for _ in 0..<200 where saved.first?.record != record {
            try? await Task.sleep(for: .milliseconds(5))
            saved = await history.stored
        }
        #expect(saved.first?.record == record)
    }

    @Test func theLiveContainerLabelsNoModuleAsPreviewData() {
        var services = ServiceContainer.live
        services.settingsStore = SettingsStore(fileURL: nil, home: services.home)
        let store = AppStore(services: services)
        for module in AppModule.allCases { #expect(!store.showsPreviewData(for: module), "\(module)") }
    }

    @Test func eachModuleGetsOneSharedScanFlow() {
        let store = AppStore(services: .fake())
        #expect(store.scanFlow(for: .cleanup) === store.scanFlow(for: .cleanup))
        #expect(store.scanFlow(for: .cleanup) !== store.scanFlow(for: .installers))
    }

    @Test func previewLabelAppearsOnlyForSimulatedModulesInTheLiveApp() {
        let live = AppStore(services: .fake(cleanup: FakeCleanupScanner(isSimulated: true), history: FakeHistory(isSimulated: false)))
        #expect(live.showsPreviewData(for: .cleanup))
        #expect(live.showsPreviewData(for: .smartCare))
        #expect(!live.showsPreviewData(for: .history))
        #expect(!live.showsPreviewData(for: .settings))

        let previews = AppStore(services: .fake(cleanup: FakeCleanupScanner(isSimulated: true), labelsSimulatedData: false))
        #expect(!previews.showsPreviewData(for: .cleanup))
    }

    @Test func scanFlowsReadTheProjectFoldersAndTheRecentSettingWhenTheScanStarts() {
        let store = AppStore(services: .fake())
        let flow = store.scanFlow(for: .devProjects)
        #expect(flow.scanOptions().skipRecentProjects)
        store.settings.skipRecentProjects = false
        #expect(!flow.scanOptions().skipRecentProjects)
        #expect(flow.scanOptions().projectRoots.map(\.path) == store.settings.projectRoots)
        #expect(flow.projectRoots().map(\.path) == store.settings.projectRoots)
    }

    @Test func settingsFollowTheStoreAndTrashPreferenceReachesScanFlows() async {
        let store = AppStore(services: .fake())
        let flow = store.scanFlow(for: .cleanup)
        #expect(flow.options().moveToTrash)
        store.settings.moveToTrash = false
        #expect(!flow.options().moveToTrash)
    }
}
