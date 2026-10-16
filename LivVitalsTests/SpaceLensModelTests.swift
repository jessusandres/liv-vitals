import Foundation
import LivCore
import os
import Testing
@testable import LivVitals

@MainActor
struct SpaceLensModelTests {
    private static let home = URL(filePath: "/tmp/home")
    private static let library = home.appending(path: "Library", directoryHint: .isDirectory)
    private static let documents = home.appending(path: "Documents", directoryHint: .isDirectory)
    private static let empty = home.appending(path: "empty", directoryHint: .isDirectory)
    private static let notes = home.appending(path: "notes.txt")

    /// Home with one folder not read yet (`Library`), one read (`Documents`), one empty, and a file.
    private static var rootNode: DiskNode {
        .directory(home, ownSize: ByteSize(4), children: [
            .collapsedDirectory(library, size: ByteSize(900)),
            .directory(documents, ownSize: ByteSize(1), children: [.file(documents.appending(path: "Taxes.pdf"), size: ByteSize(50))]),
            .directory(empty, children: []),
            .file(notes, size: ByteSize(7)),
        ])
    }

    /// What reading `Library` returns: the same total, now with children.
    private static var libraryNode: DiskNode {
        .directory(library, ownSize: ByteSize(10), children: [
            .collapsedDirectory(library.appending(path: "Caches", directoryHint: .isDirectory), size: ByteSize(500)),
            .collapsedDirectory(library.appending(path: "Application Support", directoryHint: .isDirectory), size: ByteSize(390)),
        ])
    }

    private func makeModel(
        _ tree: FakeDiskTree? = nil,
        makeGuard: @escaping () -> SafetyGuard? = { nil },
        reveal: @escaping (URL) -> Void = { _ in },
        cleaner: FakeCleanupScanner? = nil,
        options: CleanOptions = CleanOptions()
    ) -> (SpaceLensModel, FakeDiskTree) {
        let fake = tree ?? FakeDiskTree(tree: Self.rootNode, subtrees: [Self.library: Self.libraryNode])
        let model = SpaceLensModel(service: fake, home: Self.home, makeGuard: makeGuard, reveal: reveal, cleaner: cleaner, cleanOptions: { options })
        return (model, fake)
    }

    /// The guard Space Lens uses: everything in the home, minus protected and whitelisted folders.
    private static func homeGuard() -> () -> SafetyGuard? {
        { SafetyGuard(home: home, allowedRoots: [home], whitelist: []) }
    }

    private func scanned(_ model: SpaceLensModel) async -> Bool {
        model.scan()
        return await waitUntil { model.phase == .ready }
    }

    // MARK: Scanning

    @Test func scanLoadsTheHomeAndFocusesIt() async {
        let (model, fake) = makeModel()
        #expect(model.phase == .idle)
        model.scan()
        #expect(model.phase == .scanning)
        #expect(await waitUntil { model.phase == .ready })

        #expect(model.root?.size == Self.rootNode.size)
        #expect(model.focused?.url == Self.home)
        #expect(model.scannedAt != nil)
        #expect(model.breadcrumb.map(\.url) == [Self.home])
        #expect(fake.requests.withLock { $0 } == [Self.home])
        #expect(await waitUntil { model.scanProgress != nil })
    }

    @Test func aFailedScanGoesBackToIdleWithTheReason() async {
        var fake = FakeDiskTree(tree: Self.rootNode)
        fake.failure = FakeFailure()
        let (model, _) = makeModel(fake)
        model.scan()
        #expect(await waitUntil { model.errorMessage != nil })
        #expect(model.phase == .idle)
        #expect(model.root == nil)
    }

    @Test func cancellingAScanDropsItsResult() async {
        var fake = FakeDiskTree(tree: Self.rootNode)
        fake.delay = .seconds(30)
        let (model, _) = makeModel(fake)
        model.scan()
        model.cancelScan()
        #expect(model.phase == .idle)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .idle)
        #expect(model.root == nil)
    }

    // MARK: Navigation and lazy loading

    @Test func openingAReadFolderFocusesItAndFilesAreIgnored() async {
        let (model, fake) = makeModel()
        #expect(await scanned(model))
        let root = model.root!

        model.open(root.children.first { $0.url == Self.notes }!)
        #expect(model.focused?.url == Self.home)

        model.open(root.children.first { $0.url == Self.documents }!)
        #expect(model.focused?.url == Self.documents)
        #expect(model.breadcrumb.map(\.name) == ["home", "Documents"])
        // Nothing needed reading.
        #expect(fake.requests.withLock { $0 } == [Self.home])

        model.goUp()
        #expect(model.focused?.url == Self.home)
        model.goUp()
        #expect(model.focused?.url == Self.home)
    }

    @Test func anEmptyFolderIsNotLoadedOrFocused() async {
        let (model, fake) = makeModel()
        #expect(await scanned(model))
        model.open(model.root!.children.first { $0.url == Self.empty }!)
        #expect(model.focused?.url == Self.home)
        #expect(fake.requests.withLock { $0 } == [Self.home])
    }

    @Test func openingAnUnreadFolderLoadsItReplacesTheNodeAndFocusesIt() async {
        let (model, fake) = makeModel()
        #expect(await scanned(model))
        let totalBefore = model.root!.size
        let collapsed = model.root!.children.first { $0.url == Self.library }!
        #expect(collapsed.isCollapsed)

        model.open(collapsed)
        #expect(await waitUntil { model.focused?.url == Self.library })
        #expect(fake.requests.withLock { $0 } == [Self.home, Self.library])
        #expect(model.focused?.isCollapsed == false)
        #expect(model.focused?.children.map(\.name) == ["Caches", "Application Support"])
        #expect(model.root?.size == totalBefore)
        #expect(await waitUntil { model.loading.isEmpty })

        // Already read: opening it again does not ask the service again.
        model.goUp()
        model.open(model.root!.children.first { $0.url == Self.library }!)
        #expect(model.focused?.url == Self.library)
        #expect(fake.requests.withLock { $0 }.count == 2)
    }

    @Test func theFolderShowsAsLoadingWhileItIsBeingRead() async {
        var fake = FakeDiskTree(tree: Self.rootNode, subtrees: [Self.library: Self.libraryNode])
        fake.delay = .milliseconds(150)
        let (model, _) = makeModel(fake)
        #expect(await scanned(model))

        model.open(model.root!.children.first { $0.url == Self.library }!)
        #expect(model.loading == [Self.library])
        // A second double-click while it loads does not start another read.
        model.open(model.root!.children.first { $0.url == Self.library }!)
        #expect(await waitUntil { model.loading.isEmpty })
        #expect(fake.requests.withLock { $0 }.filter { $0 == Self.library }.count == 1)
    }

    @Test func aFailedLoadKeepsTheFolderAndExplainsWhy() async {
        var fake = FakeDiskTree(tree: Self.rootNode)
        fake.subtreeFailure = FakeFailure()
        let (model, _) = makeModel(fake)
        #expect(await scanned(model))

        model.open(model.root!.children.first { $0.url == Self.library }!)
        #expect(await waitUntil { model.loadError != nil })
        #expect(model.loadError?.contains("Library") == true)
        #expect(model.focused?.url == Self.home)
        #expect(model.root?.node(at: Self.library)?.isCollapsed == true)
        #expect(await waitUntil { model.loading.isEmpty })
    }

    // MARK: Issues

    @Test func unreadableItemsAreCollectedOnceAcrossScanAndLoads() async {
        var fake = FakeDiskTree(tree: Self.rootNode, subtrees: [Self.library: Self.libraryNode])
        let mail = ScanIssue(url: Self.home.appending(path: "Library/Mail"), reason: "Operation not permitted")
        let safari = ScanIssue(url: Self.home.appending(path: "Library/Safari"), reason: "Operation not permitted")
        fake.issues = [mail]
        fake.subtreeIssues = [mail, safari]
        let (model, _) = makeModel(fake)
        #expect(await scanned(model))
        #expect(model.issues == [mail])

        model.open(model.root!.children.first { $0.url == Self.library }!)
        #expect(await waitUntil { model.issues.count == 2 })
        #expect(model.issues == [mail, safari])

        // A rescan starts the list over.
        model.scan()
        #expect(model.issues.isEmpty)
        #expect(await waitUntil { model.phase == .ready })
        #expect(model.issues == [mail])
    }

    // MARK: Filter, Finder, protection

    @Test func theFilterMatchesNamesIgnoringCaseAndLeavesWhenYouNavigate() async {
        let (model, _) = makeModel()
        #expect(await scanned(model))
        let root = model.root!
        #expect(model.visibleChildren(of: root).count == 4)

        model.filterText = "  DOC "
        #expect(model.visibleChildren(of: root).map(\.name) == ["Documents"])
        model.filterText = "zzz"
        #expect(model.visibleChildren(of: root).isEmpty)

        model.filterText = "doc"
        model.open(root.children.first { $0.url == Self.documents }!)
        #expect(model.filterText.isEmpty)
    }

    @Test func revealHandsTheNodesURLToFinder() async {
        var revealed: [URL] = []
        let (model, _) = makeModel(reveal: { revealed.append($0) })
        #expect(await scanned(model))
        model.reveal(model.root!.children.first { $0.url == Self.notes }!)
        #expect(revealed == [Self.notes])
    }

    @Test func protectedWhitelistedAndContainingFoldersGetALock() async {
        let guardian = SafetyGuard(home: Self.home, allowedRoots: [Self.home], whitelist: [Self.documents])
        let (model, _) = makeModel(makeGuard: { guardian })
        #expect(!model.isProtected(Self.rootNode))
        #expect(await scanned(model))
        let children = model.root!.children

        #expect(model.isProtected(children.first { $0.url == Self.documents }!))   // whitelisted by the user
        #expect(model.isProtected(children.first { $0.url == Self.library }!))     // holds ~/Library/Keychains
        #expect(!model.isProtected(children.first { $0.url == Self.notes }!))
        #expect(!model.isProtected(children.first { $0.url == Self.empty }!))
    }
}

@MainActor
struct SpaceLensActionsTests {
    private static let home = URL(filePath: "/tmp/home")
    private static let documents = home.appending(path: "Documents", directoryHint: .isDirectory)
    private static let downloads = home.appending(path: "Downloads", directoryHint: .isDirectory)
    private static let iso = downloads.appending(path: "big.iso")
    private static let notes = home.appending(path: "notes.txt")

    /// Home → Downloads (big.iso 500, small.txt 20), Documents (protected by default), notes.txt.
    private static var rootNode: DiskNode {
        .directory(home, ownSize: ByteSize(4), children: [
            .directory(downloads, ownSize: ByteSize(1), children: [
                .file(iso, size: ByteSize(500)),
                .file(downloads.appending(path: "small.txt"), size: ByteSize(20)),
            ]),
            .directory(documents, ownSize: ByteSize(1), children: [.file(documents.appending(path: "thesis.docx"), size: ByteSize(300))]),
            .file(notes, size: ByteSize(7)),
        ])
    }

    private func makeModel(
        _ fake: FakeDiskTree? = nil,
        cleaner: FakeCleanupScanner? = FakeCleanupScanner(),
        options: CleanOptions = CleanOptions(),
        onCleaned: ((CleanupRecord) -> Void)? = nil
    ) async -> (SpaceLensModel, FakeDiskTree) {
        let service = fake ?? FakeDiskTree(tree: Self.rootNode)
        let model = SpaceLensModel(
            service: service,
            home: Self.home,
            makeGuard: { SafetyGuard(home: Self.home, allowedRoots: [Self.home], whitelist: []) },
            cleaner: cleaner,
            cleanOptions: { options }
        )
        model.onCleaned = onCleaned
        model.scan()
        _ = await waitUntil { model.phase == .ready }
        return (model, service)
    }

    private func node(_ model: SpaceLensModel, _ url: URL) -> DiskNode { model.root!.node(at: url)! }

    // MARK: Moving to the Trash

    @Test func confirmingRemovesTheNodeUpdatesSizesAndReportsHistory() async {
        let cleaner = FakeCleanupScanner()
        var reported: [CleanupRecord] = []
        let (model, _) = await makeModel(cleaner: cleaner, onCleaned: { reported.append($0) })
        let totalBefore = model.root!.size
        let downloadsBefore = node(model, Self.downloads).size

        model.requestRemoval(node(model, Self.iso))
        #expect(model.pendingRemoval?.url == Self.iso)
        #expect(cleaner.calls.withLock { $0.cleaned }.isEmpty)   // nothing happens until confirmed

        model.confirmRemoval()
        #expect(await waitUntil { model.root?.node(at: Self.iso) == nil })
        let calls = cleaner.calls.withLock { $0 }
        #expect(calls.cleaned.count == 1)
        #expect(calls.cleaned[0].map(\.url) == [Self.iso])
        #expect(calls.cleaned[0].map(\.size) == [ByteSize(500)])
        // Parents shrink without a rescan.
        #expect(model.root!.size.bytes == totalBefore.bytes - 500)
        #expect(node(model, Self.downloads).size.bytes == downloadsBefore.bytes - 500)
        #expect(model.pendingRemoval == nil)
        #expect(await waitUntil { !model.isRemoving })
        #expect(reported.map(\.source) == ["Space Lens"])
    }

    @Test func aProtectedFolderCannotBeRemovedOrEvenAsked() async {
        let cleaner = FakeCleanupScanner()
        let (model, _) = await makeModel(cleaner: cleaner)
        let documents = node(model, Self.documents)
        #expect(!model.canRemove(documents))
        model.requestRemoval(documents)
        #expect(model.pendingRemoval == nil)
        model.confirmRemoval()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(cleaner.calls.withLock { $0.cleaned }.isEmpty)
        #expect(model.root?.node(at: Self.documents) != nil)
        // An ordinary file is allowed.
        #expect(model.canRemove(node(model, Self.notes)))
    }

    @Test func withoutACleanerNothingCanBeRemoved() async {
        let (model, _) = await makeModel(cleaner: nil)
        #expect(!model.canRemove(node(model, Self.notes)))
    }

    @Test func cancellingTheConfirmationKeepsEverything() async {
        let cleaner = FakeCleanupScanner()
        let (model, _) = await makeModel(cleaner: cleaner)
        model.requestRemoval(node(model, Self.notes))
        model.cancelRemoval()
        #expect(model.pendingRemoval == nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(cleaner.calls.withLock { $0.cleaned }.isEmpty)
    }

    @Test func aRefusedRemovalKeepsTheNodeAndSaysWhy() async {
        var cleaner = FakeCleanupScanner()
        let item = CleanupItem(url: Self.notes, category: .largeFiles, size: ByteSize(7))
        cleaner.cleanOutcome = CleanupOutcome(
            record: CleanupRecord(date: .now, source: "Space Lens", itemCount: 0, freed: .zero, movedToTrash: true),
            trashedSize: .zero, deletedSize: .zero,
            failures: [CleanupProblem(item: item, reason: "The file is in use.")], skipped: [], wasDryRun: false
        )
        var reported = 0
        let (model, _) = await makeModel(cleaner: cleaner, onCleaned: { _ in reported += 1 })
        model.requestRemoval(node(model, Self.notes))
        model.confirmRemoval()
        #expect(await waitUntil { model.removalMessage != nil })
        #expect(model.removalMessage == "notes.txt was not removed: The file is in use.")
        #expect(model.root?.node(at: Self.notes) != nil)
        #expect(reported == 0)
    }

    @Test func aFailingCleanerIsReportedAndChangesNothing() async {
        var cleaner = FakeCleanupScanner()
        cleaner.failure = FakeFailure()
        let (model, _) = await makeModel(cleaner: cleaner)
        model.requestRemoval(node(model, Self.notes))
        model.confirmRemoval()
        #expect(await waitUntil { model.removalMessage != nil && !model.isRemoving })
        #expect(model.removalMessage?.hasPrefix("Could not remove notes.txt") == true)
        #expect(model.root?.node(at: Self.notes) != nil)
    }

    @Test func aSimulationLeavesTheTreeAloneAndIsNotHistory() async {
        var reported = 0
        let (model, _) = await makeModel(options: CleanOptions(dryRun: true), onCleaned: { _ in reported += 1 })
        model.requestRemoval(node(model, Self.notes))
        model.confirmRemoval()
        #expect(await waitUntil { model.removalMessage != nil })
        #expect(model.removalMessage == "Simulation: notes.txt was not moved.")
        #expect(model.root?.node(at: Self.notes) != nil)
        #expect(reported == 0)
    }

    @Test func theConfirmationKnowsWhenTheRemovalIsPermanent() async {
        let (trash, _) = await makeModel(options: CleanOptions(moveToTrash: true))
        #expect(!trash.pendingRemovalIsPermanent)
        let (permanent, _) = await makeModel(options: CleanOptions(moveToTrash: false))
        #expect(permanent.pendingRemovalIsPermanent)
        let (simulated, _) = await makeModel(options: CleanOptions(moveToTrash: false, dryRun: true))
        #expect(!simulated.pendingRemovalIsPermanent)
    }

    // MARK: Rescan of the current folder

    @Test func rescanInASubfolderMeasuresOnlyThatFolderAndKeepsTheView() async {
        var fake = FakeDiskTree(tree: Self.rootNode)
        // Downloads grew: a new 80-byte file appeared.
        let grown = DiskNode.directory(Self.downloads, ownSize: ByteSize(1), children: [
            .file(Self.iso, size: ByteSize(500)),
            .file(Self.downloads.appending(path: "small.txt"), size: ByteSize(20)),
            .file(Self.downloads.appending(path: "new.zip"), size: ByteSize(80)),
        ])
        fake.subtrees = [Self.downloads: grown]
        let (model, service) = await makeModel(fake)
        model.open(node(model, Self.downloads))
        #expect(model.focused?.url == Self.downloads)
        let totalBefore = model.root!.size.bytes

        model.rescanFocused()
        #expect(model.phase == .ready)   // the previous view stays on screen
        #expect(model.rescanningURL == Self.downloads)
        #expect(await waitUntil { model.rescanningURL == nil })

        #expect(service.requests.withLock { $0 } == [Self.home, Self.downloads])
        #expect(model.focused?.url == Self.downloads)
        #expect(model.breadcrumb.map(\.name) == ["home", "Downloads"])
        #expect(node(model, Self.downloads).children.count == 3)
        #expect(model.root!.size.bytes == totalBefore + 80)
    }

    @Test func rescanAtTheTopIsAFullScan() async {
        let (model, service) = await makeModel()
        model.rescanFocused()
        #expect(model.phase == .scanning)
        #expect(await waitUntil { model.phase == .ready })
        #expect(service.requests.withLock { $0 } == [Self.home, Self.home])
    }

    @Test func rescanReplacesTheUnreadableItemsOfThatFolderOnly() async {
        var fake = FakeDiskTree(tree: Self.rootNode)
        let inDownloads = ScanIssue(url: Self.downloads.appending(path: "locked"), reason: "Permission denied")
        let elsewhere = ScanIssue(url: Self.documents.appending(path: "private"), reason: "Operation not permitted")
        let stillThere = ScanIssue(url: Self.downloads.appending(path: "other"), reason: "Permission denied")
        fake.issues = [inDownloads, elsewhere]
        fake.subtreeIssues = [stillThere]
        fake.subtrees = [Self.downloads: Self.rootNode.node(at: Self.downloads)!]
        let (model, _) = await makeModel(fake)
        #expect(model.issues == [inDownloads, elsewhere])

        model.open(node(model, Self.downloads))
        model.rescanFocused()
        #expect(await waitUntil { model.rescanningURL == nil })
        // The old one inside Downloads is gone, the new one is in, the other folder's is untouched.
        #expect(Set(model.issues.map(\.url)) == [elsewhere.url, stillThere.url])
    }

    @Test func aFolderThatNoLongerExistsIsDroppedAndTheViewMovesUp() async {
        var fake = FakeDiskTree(tree: Self.rootNode)
        fake.subtreeNotFound = true
        let (model, _) = await makeModel(fake)
        model.open(node(model, Self.downloads))
        let totalBefore = model.root!.size.bytes
        let downloadsSize = node(model, Self.downloads).size.bytes

        model.rescanFocused()
        #expect(await waitUntil { model.focused?.url == Self.home })
        #expect(model.loadError == "Downloads no longer exists.")
        #expect(model.root?.node(at: Self.downloads) == nil)
        #expect(model.root!.size.bytes == totalBefore - downloadsSize)
        #expect(await waitUntil { model.rescanningURL == nil })
    }

    @Test func cancellingARescanLeavesTheTreeAsItWas() async {
        var fake = FakeDiskTree(tree: Self.rootNode)
        fake.delay = .seconds(30)
        fake.delayOnly = [Self.downloads]
        let (model, _) = await makeModel(fake)
        model.open(node(model, Self.downloads))
        let before = model.root

        model.rescanFocused()
        #expect(model.rescanningURL == Self.downloads)
        model.cancelRescan()
        #expect(model.rescanningURL == nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.root == before)
        #expect(model.focused?.url == Self.downloads)
    }

    @Test func aFailedRescanKeepsTheFolderAndExplainsWhy() async {
        var fake = FakeDiskTree(tree: Self.rootNode)
        fake.subtreeFailure = FakeFailure()
        let (model, _) = await makeModel(fake)
        model.open(node(model, Self.downloads))
        let before = model.root
        model.rescanFocused()
        #expect(await waitUntil { model.loadError != nil })
        #expect(model.loadError?.hasPrefix("Could not rescan Downloads") == true)
        #expect(model.root == before)
        #expect(await waitUntil { model.rescanningURL == nil })
    }
}

struct ServiceThreadingTests {
    @Test func theRealDiskServiceReportsProgressOffTheMainThread() async throws {
        try await TemporaryDirectory.use { tmp in
            for index in 0..<40 {
                let file = tmp.path("root/d\(index % 4)/f\(index).bin")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(count: 2_000).write(to: file)
            }
            let onMainThread = OSAllocatedUnfairLock(initialState: [Bool]())

            let result = try await LiveDiskTree().tree(at: tmp.path("root"), depth: 1) { _ in
                onMainThread.withLock { $0.append(Thread.isMainThread) }
            }
            let calls = onMainThread.withLock { $0 }
            #expect(!calls.isEmpty)
            #expect(calls.allSatisfy { !$0 })
            #expect(result.node.children.count == 4)
            #expect(result.node.children.allSatisfy { $0.isCollapsed })
        }
    }

    @MainActor
    @Test func onlyTheLiveContainerUsesTheRealDisk() {
        #expect(!ServiceContainer.live.diskTree.isSimulated)
        #expect(ServiceContainer.mock.diskTree.isSimulated)
        #expect(!ServiceContainer.live.metrics.isSimulated)
        // Every module of the live app is real.
        #expect(!ServiceContainer.live.cleanup.isSimulated(.cleanup))
        #expect(!ServiceContainer.live.cleanup.isSimulated(.smartCare))
        #expect(!ServiceContainer.live.history.isSimulated)
        #expect(ServiceContainer.mock.cleanup.isSimulated(.cleanup))
    }
}
