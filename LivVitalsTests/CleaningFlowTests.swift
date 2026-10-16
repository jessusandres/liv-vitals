import Foundation
import LivCore
import Testing
@testable import LivVitals

/// The confirmation, outcome and Empty Trash behavior of `ScanFlowModel`, with a scripted scanner.
@MainActor
struct CleaningFlowTests {
    private func item(_ name: String, _ bytes: Int64, category: CleanupCategory = .userCaches, selected: Bool = true) -> CleanupItem {
        CleanupItem(url: URL(filePath: "/tmp/home/Library/Caches/\(name)"), category: category, size: ByteSize(bytes), isSelectedByDefault: selected, ruleID: "user-caches")
    }

    /// A model that already scanned `items` and is showing results.
    private func readyModel(
        _ items: [CleanupItem],
        scanner: FakeCleanupScanner? = nil,
        options: CleanOptions = CleanOptions(),
        preview: Bool = true,
        fullDiskAccess: Bool = false
    ) async -> (ScanFlowModel, FakeCleanupScanner) {
        var configured = scanner ?? FakeCleanupScanner()
        configured.result = ScanResult(items: items)
        let model = ScanFlowModel(module: .cleanup, scanner: configured)
        model.options = { options }
        model.previewBeforeCleaning = { preview }
        model.hasFullDiskAccess = { fullDiskAccess }
        model.startScan()
        _ = await waitUntil { model.phase == .results }
        return (model, configured)
    }

    // MARK: Confirmation

    @Test func withReviewOnTheCleanButtonAsksFirstAndOnlyConfirmingCleans() async {
        let (model, fake) = await readyModel([item("a", 100), item("b", 50)])
        model.requestClean()
        #expect(await waitUntil { model.confirmation != nil })

        let confirmation = model.confirmation!
        #expect(confirmation.itemCount == 2)
        #expect(confirmation.totalSize == ByteSize(150))
        #expect(confirmation.trashCount == 2 && confirmation.permanentCount == 0)
        #expect(!confirmation.isPermanent)
        #expect(model.phase == .results)
        #expect(fake.calls.withLock { $0.cleaned }.isEmpty)

        model.confirmClean()
        #expect(model.confirmation == nil)
        #expect(await waitUntil { model.phase == .done })
        #expect(fake.calls.withLock { $0.cleaned.count } == 1)
    }

    @Test func cancellingTheConfirmationCleansNothing() async {
        let (model, fake) = await readyModel([item("a", 100)])
        model.requestClean()
        #expect(await waitUntil { model.confirmation != nil })
        model.cancelConfirmation()
        #expect(model.confirmation == nil)
        #expect(model.phase == .results)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fake.calls.withLock { $0.cleaned }.isEmpty)
    }

    @Test func withReviewOffCleaningToTheTrashStartsRightAway() async {
        let (model, fake) = await readyModel([item("a", 100)], preview: false)
        model.requestClean()
        #expect(await waitUntil { model.phase == .done })
        #expect(model.confirmation == nil)
        #expect(fake.calls.withLock { $0.cleaned.count } == 1)
    }

    @Test func aPermanentDeleteAlwaysAsksEvenWithReviewOff() async {
        let (model, fake) = await readyModel([item("a", 100)], options: CleanOptions(moveToTrash: false), preview: false)
        model.requestClean()
        #expect(await waitUntil { model.confirmation != nil })
        #expect(model.confirmation?.isPermanent == true)
        #expect(model.confirmation?.permanentCount == 1)
        #expect(fake.calls.withLock { $0.cleaned }.isEmpty)
    }

    @Test func whatIsAlreadyInTheTrashIsAlwaysDeletedForGoodAndAsksToo() async {
        let items = [item("cache", 100), item("old-file", 40, category: .trash)]
        let (model, _) = await readyModel(items, options: CleanOptions(moveToTrash: true), preview: false)
        model.requestClean()
        #expect(await waitUntil { model.confirmation != nil })
        let confirmation = model.confirmation!
        #expect(confirmation.trashCount == 1 && confirmation.trashSize == ByteSize(100))
        #expect(confirmation.permanentCount == 1 && confirmation.permanentSize == ByteSize(40))
        #expect(confirmation.isPermanent)
        #expect(model.selectionSummary == "Some items go to the Trash; the Trash itself is emptied for good.")
    }

    @Test func runningOwnerAppsAreListedAndForceTheQuestion() async {
        var scanner = FakeCleanupScanner()
        scanner.owners = ["Google Chrome"]
        let (model, _) = await readyModel([item("a", 100)], scanner: scanner, preview: false)
        model.requestClean()
        #expect(await waitUntil { model.confirmation != nil })
        #expect(model.confirmation?.appsToQuit == ["Google Chrome"])
    }

    @Test func nothingHappensWithoutASelectionOrOutsideTheResults() async {
        let (model, fake) = await readyModel([item("a", 100, selected: false)])
        model.requestClean()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.confirmation == nil)
        #expect(fake.calls.withLock { $0.cleaned }.isEmpty)
        #expect(model.selectionSummary == "Select items to clean.")
    }

    @Test func theFooterTellsWhatWillReallyHappen() async {
        let (trash, _) = await readyModel([item("a", 1)])
        #expect(trash.selectionSummary == "Selected items go to the Trash.")
        let (permanent, _) = await readyModel([item("a", 1)], options: CleanOptions(moveToTrash: false))
        #expect(permanent.selectionSummary == "Selected items are deleted permanently.")
        let (dry, _) = await readyModel([item("a", 1)], options: CleanOptions(dryRun: true))
        #expect(dry.selectionSummary == "Simulation: nothing will be moved or deleted.")
    }

    // MARK: Outcome

    @Test func theOutcomeWithProblemsReachesTheEndScreenAndOnlyDoneItemsAreHistory() async {
        let problem = CleanupProblem(item: item("busy", 10), reason: "The file is in use.")
        var scanner = FakeCleanupScanner()
        scanner.cleanOutcome = CleanupOutcome(
            record: CleanupRecord(date: .now, source: "Cleanup", itemCount: 1, freed: ByteSize(90), movedToTrash: true),
            trashedSize: ByteSize(90), deletedSize: .zero,
            failures: [problem], skipped: [CleanupProblem(item: item("gone", 5), reason: "No longer exists")],
            wasDryRun: false
        )
        let (model, _) = await readyModel([item("a", 90), item("busy", 10), item("gone", 5)], scanner: scanner, preview: false)
        var reported: [CleanupRecord] = []
        model.onCleaned = { reported.append($0) }

        model.requestClean()
        #expect(await waitUntil { model.phase == .done })
        #expect(model.lastOutcome?.failures == [problem])
        #expect(model.lastOutcome?.skipped.map(\.reason) == ["No longer exists"])
        #expect(reported.map(\.itemCount) == [1])
    }

    @Test func aDryRunIsNotReportedAsHistory() async {
        let (model, fake) = await readyModel([item("a", 100)], options: CleanOptions(dryRun: true), preview: false)
        var reported = 0
        model.onCleaned = { _ in reported += 1 }

        model.requestClean()
        // Simulating still asks, so the user knows nothing will happen.
        #expect(await waitUntil { model.confirmation != nil || model.phase == .done })
        if model.confirmation != nil { model.confirmClean() }
        #expect(await waitUntil { model.phase == .done })
        #expect(model.lastOutcome?.wasDryRun == true)
        #expect(model.lastOutcome?.record.itemCount == 0)
        #expect(reported == 0)
        #expect(fake.calls.withLock { $0.options.first?.dryRun } == true)
    }

    @Test func theTitleNamesWhatHappened() {
        func outcome(trashed: Int64, deleted: Int64, dry: Bool = false) -> CleanupOutcome {
            CleanupOutcome(
                record: CleanupRecord(date: .now, source: "Cleanup", itemCount: 1, freed: ByteSize(trashed + deleted), movedToTrash: deleted == 0),
                trashedSize: ByteSize(trashed), deletedSize: ByteSize(deleted), failures: [], skipped: [], wasDryRun: dry
            )
        }
        #expect(ScanFlowView.title(for: outcome(trashed: 4_200_000_000, deleted: 0)) == "4.2 GB moved to Trash")
        #expect(ScanFlowView.title(for: outcome(trashed: 0, deleted: 1_100_000_000)) == "1.1 GB deleted")
        #expect(ScanFlowView.title(for: outcome(trashed: 4_200_000_000, deleted: 1_100_000_000)) == "4.2 GB moved to Trash · 1.1 GB deleted")
        #expect(ScanFlowView.title(for: outcome(trashed: 0, deleted: 0)) == "Nothing was cleaned")
        #expect(ScanFlowView.title(for: outcome(trashed: 5, deleted: 0, dry: true)) == "Dry run: nothing was moved")
    }

    // MARK: Empty Trash

    @Test func emptyTrashIsOfferedAfterATrashMoveAndNeedsFullDiskAccess() async {
        let (model, fake) = await readyModel([item("a", 100)], preview: false, fullDiskAccess: false)
        model.requestClean()
        #expect(await waitUntil { model.phase == .done })
        #expect(model.offersEmptyTrash)
        #expect(!model.canEmptyTrash)

        model.requestEmptyTrash()
        #expect(!model.isConfirmingEmptyTrash)
        #expect(fake.calls.withLock { $0.emptied } == 0)
    }

    @Test func emptyingTheTrashAsksThenDeletesAndIsReportedOnce() async {
        let (model, fake) = await readyModel([item("a", 100)], preview: false, fullDiskAccess: true)
        var reported: [CleanupRecord] = []
        model.onCleaned = { reported.append($0) }
        model.requestClean()
        #expect(await waitUntil { model.phase == .done })
        #expect(model.canEmptyTrash)

        model.requestEmptyTrash()
        #expect(model.isConfirmingEmptyTrash)
        model.confirmEmptyTrash()
        #expect(await waitUntil { model.trashOutcome != nil })
        #expect(fake.calls.withLock { $0.emptied } == 1)
        #expect(model.trashOutcome?.deletedSize == ByteSize(2_000))
        #expect(!model.offersEmptyTrash)
        #expect(reported.map(\.source) == ["Cleanup", "Empty Trash"])
    }

    @Test func aFailureEmptyingTheTrashShowsTheReason() async {
        var scanner = FakeCleanupScanner()
        scanner.trashFailure = FakeFailure()
        let (model, _) = await readyModel([item("a", 100)], scanner: scanner, preview: false, fullDiskAccess: true)
        model.requestClean()
        #expect(await waitUntil { model.phase == .done })
        model.requestEmptyTrash()
        model.confirmEmptyTrash()
        #expect(await waitUntil { model.errorMessage != nil && !model.isEmptyingTrash })
        #expect(model.trashOutcome == nil)
    }

    @Test func simulatedModulesNeverOfferEmptyTrash() async {
        var scanner = FakeCleanupScanner()
        scanner.isSimulated = true
        let (model, _) = await readyModel([item("a", 100)], scanner: scanner, preview: false)
        model.requestClean()
        #expect(await waitUntil { model.phase == .done })
        #expect(!model.offersEmptyTrash)
    }

    // MARK: Search

    @Test func searchMatchesNameOrPathIgnoringCaseAndKeepsTheSelection() async {
        let items = [item("com.spotify.client", 100), item("Homebrew", 50)]
        let (model, _) = await readyModel(items)
        #expect(model.selection.count == 2)

        model.searchText = "SPOT"
        #expect(model.matchesSearch(items[0]) && !model.matchesSearch(items[1]))
        model.searchText = "library/caches/home"
        #expect(!model.matchesSearch(items[0]) && model.matchesSearch(items[1]))
        model.searchText = "  "
        #expect(items.allSatisfy(model.matchesSearch))
        // Filtering never changes what is checked.
        #expect(model.selection.count == 2)
    }

    @Test func searchAlsoFindsAnItemByTheNameOfItsProject() async {
        let artifact = CleanupItem(
            url: URL(filePath: "/tmp/elsewhere/x/dist", directoryHint: .isDirectory),
            category: .projectArtifacts, size: ByteSize(10), group: URL(filePath: "/tmp/home/code/alpha-service", directoryHint: .isDirectory)
        )
        let (model, _) = await readyModel([artifact])
        model.searchText = "ALPHA"
        #expect(model.matchesSearch(artifact))
        model.searchText = "zzz"
        #expect(!model.matchesSearch(artifact))
    }

    // MARK: Dev Projects

    @Test func startScanHandsTheScannerWhatSettingsSaid() async {
        let options = ScanOptions(
            whitelist: [URL(filePath: "/tmp/home/secret")],
            projectRoots: [URL(filePath: "/tmp/home/code", directoryHint: .isDirectory)],
            skipRecentProjects: false
        )
        let fake = FakeCleanupScanner()
        let model = ScanFlowModel(module: .devProjects, scanner: fake)
        model.scanOptions = { options }
        model.startScan()
        #expect(await waitUntil { model.phase == .results })

        let seen = fake.calls.withLock { $0.scans }
        #expect(seen.count == 1)
        #expect(seen[0].projectRoots == options.projectRoots)
        #expect(seen[0].whitelist == options.whitelist)
        #expect(!seen[0].skipRecentProjects)
    }

    @Test func devProjectsAsksForAFolderOnlyWhenARealScanHasNoneThatExists() async throws {
        try await TemporaryDirectory.use { tmp in
            let missing = tmp.path("Projects")
            let real = ScanFlowModel(module: .devProjects, scanner: FakeCleanupScanner())
            real.projectRoots = { [missing] }
            #expect(real.needsProjectFolder)

            // A simulated scan needs no folder, and neither do the other modules.
            let simulated = ScanFlowModel(module: .devProjects, scanner: FakeCleanupScanner(isSimulated: true))
            simulated.projectRoots = { [missing] }
            #expect(!simulated.needsProjectFolder)
            let cleanup = ScanFlowModel(module: .cleanup, scanner: FakeCleanupScanner())
            #expect(!cleanup.needsProjectFolder)

            let existing = try tmp.directory("code")
            real.projectRoots = { [missing, existing] }
            #expect(!real.needsProjectFolder)
        }
    }

    @Test func choosingFoldersAddsThemAndExplainsTheFirstRefusal() {
        let model = ScanFlowModel(module: .devProjects, scanner: FakeCleanupScanner())
        var added: [String] = []
        model.addProjectRoot = { folder in
            added.append(folder.path)
            return folder.lastPathComponent == "Documents" ? "~/Documents is protected, so Dev Projects cannot clean inside it." : nil
        }

        model.addProjectFolders([URL(filePath: "/tmp/home/code"), URL(filePath: "/tmp/home/Documents")])
        #expect(added == ["/tmp/home/code", "/tmp/home/Documents"])
        #expect(model.errorMessage == "~/Documents is protected, so Dev Projects cannot clean inside it.")

        model.addProjectFolders([URL(filePath: "/tmp/home/lab")])
        #expect(model.errorMessage == nil)
    }

    // MARK: Admin

    private func adminItem(_ name: String) -> CleanupItem {
        CleanupItem(
            url: URL(filePath: "/Library/LaunchDaemons/\(name).plist"), category: .appLeftovers, size: ByteSize(40),
            group: URL(filePath: "/Applications/Tool.app"), needsAdmin: true
        )
    }

    @Test func theConfirmationCountsWhatNeedsThePasswordAndListsTheServicesItStops() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "LivVitalsTests-\(UUID().uuidString)/LaunchDaemons", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let plist = folder.appending(path: "com.example.helper.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.helper.label"], format: .xml, options: 0).write(to: plist)

        let service = CleanupItem(url: plist, category: .appLeftovers, size: ByteSize(40), needsAdmin: true)
        let bundle = CleanupItem(url: URL(filePath: "/Applications/Tool.app", directoryHint: .isDirectory), category: .applications, size: ByteSize(500), needsAdmin: true)
        let cache = item("c", 10)

        let summary = ScanFlowModel.confirmation(for: [service, bundle, cache], options: CleanOptions(), appsToQuit: [])
        #expect(summary.adminCount == 2)
        // The label comes from the plist, not the file name.
        #expect(summary.servicesToStop == ["com.example.helper.label"])
        #expect(summary.itemCount == 3 && summary.trashCount == 3)
    }

    @Test func whatNeedsAdminCountsAsTrashEvenWithMoveToTrashOff() {
        let items = [adminItem("com.example.a"), item("plain", 100)]
        let summary = ScanFlowModel.confirmation(for: items, options: CleanOptions(moveToTrash: false), appsToQuit: [])
        #expect(summary.trashCount == 1 && summary.trashSize == ByteSize(40))
        #expect(summary.permanentCount == 1 && summary.permanentSize == ByteSize(100))
        #expect(summary.adminCount == 1)
    }

    @Test func aSelectionThatNeedsThePasswordAsksToConfirmEvenWithReviewOff() async {
        let (model, fake) = await readyModel([adminItem("com.example.a")], preview: false)
        #expect(model.selection.count == 1)
        model.requestClean()
        #expect(await waitUntil { model.confirmation != nil })
        #expect(model.confirmation?.adminCount == 1)
        #expect(fake.calls.withLock { $0.cleaned }.isEmpty)
    }

    @Test func aPlainSelectionWithReviewOffStillCleansWithoutAsking() async {
        let (model, fake) = await readyModel([item("plain", 100)], preview: false)
        model.requestClean()
        #expect(await waitUntil { model.phase == .done })
        #expect(model.confirmation == nil)
        #expect(fake.calls.withLock { $0.cleaned.count } == 1)
    }

    @Test func startingOverClearsTheSearchAndTheOutcome() async {
        let (model, _) = await readyModel([item("a", 1)], preview: false)
        model.searchText = "a"
        model.requestClean()
        #expect(await waitUntil { model.phase == .done })
        model.reset()
        #expect(model.searchText.isEmpty && model.lastOutcome == nil && model.phase == .idle)
    }
}
