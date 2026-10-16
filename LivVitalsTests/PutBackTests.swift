import Foundation
import LivCore
import Testing
@testable import LivVitals

/// "Put Back" on a fake home, a fake applications folder and a fake `/Library`, with the restorer and the
/// administrator replaced by recorders.
@MainActor
struct PutBackTests {
    private struct World {
        let tmp: TemporaryDirectory
        let home: URL
        let apps: URL
        let log: OperationLog
        let restorer = RecordingRestorer()
        let privileged: FakePrivileged
        let history: LiveHistory
        let runID = UUID()

        init(_ tmp: TemporaryDirectory, cancels: Bool = false, restoreFailures: [String: String] = [:]) throws {
            self.tmp = tmp
            home = try tmp.directory("home")
            try tmp.directory("home/.Trash")
            try tmp.directory("home/Library/Caches")
            apps = try tmp.directory("Applications")
            try tmp.directory("Library/LaunchDaemons")
            log = OperationLog(fileURL: tmp.path("Support/operations.jsonl"))
            privileged = FakePrivileged(cancels: cancels, restoreFailures: restoreFailures)
            history = LiveHistory(
                log: log, home: home, appFolders: [apps], systemLibrary: tmp.path("Library"),
                restorer: restorer, privileged: privileged
            )
        }

        func lock(_ relative: String) throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmp.path(relative).path)
        }

        func unlock(_ relative: String) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path(relative).path)
        }

        /// A finished run in the log whose items sit in the fake Trash.
        @discardableResult
        func removed(_ originals: [String]) async throws -> [HistoryItem] {
            var entries: [LogEntry] = []
            for original in originals {
                let name = URL(filePath: original).lastPathComponent
                entries.append(LogEntry(
                    kind: .trash, path: tmp.path(original).path, bytes: 10, outcome: .done,
                    runID: runID, trashedPath: tmp.path("home/.Trash/\(name)").path, source: "Cleanup"
                ))
            }
            try await log.append(entries)
            return await history.runs().first { $0.id == runID }?.items ?? []
        }
    }

    @Test func userItemsGoBackThroughTheRestorerAndAdminItemsInOneDialog() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/a.bin")
            try tmp.app("home/.Trash/Tool.app", id: "com.example.tool")
            try tmp.app("home/.Trash/Other.app", id: "com.example.other")
            try world.lock("Applications")
            defer { world.unlock("Applications") }

            let items = try await world.removed(["home/Library/Caches/a.bin", "Applications/Tool.app", "Applications/Other.app"])
            let outcome = try await world.history.putBack(items, of: world.runID) { _ in }

            #expect(world.restorer.restored.map(\.to.lastPathComponent) == ["a.bin"])
            #expect(world.privileged.restored.count == 1)
            #expect(world.privileged.restored[0].map(\.to.lastPathComponent) == ["Tool.app", "Other.app"])
            #expect(outcome.restored == 3)
            #expect(outcome.skipped.isEmpty && outcome.failed.isEmpty)
        }
    }

    @Test func everyStepIsLoggedUnderTheOriginalRunAndHistoryShowsWhatWasRestored() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/a.bin")
            try tmp.app("home/.Trash/Tool.app", id: "com.example.tool")
            try world.lock("Applications")
            defer { world.unlock("Applications") }

            let items = try await world.removed(["home/Library/Caches/a.bin", "Applications/Tool.app"])
            _ = try await world.history.putBack(items, of: world.runID) { _ in }

            let restores = try await world.log.entries().filter { $0.kind == .restore }
            #expect(restores.count == 2)
            #expect(restores.allSatisfy { $0.runID == world.runID && $0.outcome == .done && $0.source == "Cleanup" })

            let run = try #require(await world.history.runs().first)
            #expect(run.restoredCount == 2 && run.restorableCount == 0)
            // The totals of the cleanup do not change when something is put back.
            #expect(run.record.itemCount == 2 && run.record.freed == ByteSize(20))
        }
    }

    @Test func aCancelledPasswordDialogSkipsTheAdminItemsAndKeepsTheOthers() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp, cancels: true)
            try tmp.file("home/.Trash/a.bin")
            try tmp.app("home/.Trash/Tool.app", id: "com.example.tool")
            try world.lock("Applications")
            defer { world.unlock("Applications") }

            let items = try await world.removed(["home/Library/Caches/a.bin", "Applications/Tool.app"])
            let outcome = try await world.history.putBack(items, of: world.runID) { _ in }

            #expect(outcome.restored == 1)
            #expect(outcome.skipped.map(\.reason) == ["The password dialog was cancelled."])
            let run = try #require(await world.history.runs().first)
            #expect(run.restorableCount == 1)
        }
    }

    @Test func anAdminFailureIsReportedWithItsReason() async throws {
        try await TemporaryDirectory.use { tmp in
            let from = tmp.path("home/.Trash/Tool.app").path
            let world = try World(tmp, restoreFailures: [from: "mv: Operation not permitted"])
            try tmp.app("home/.Trash/Tool.app", id: "com.example.tool")
            try world.lock("Applications")
            defer { world.unlock("Applications") }

            let items = try await world.removed(["Applications/Tool.app"])
            let outcome = try await world.history.putBack(items, of: world.runID) { _ in }

            #expect(outcome.restored == 0)
            #expect(outcome.failed.map(\.reason) == ["mv: Operation not permitted"])
        }
    }

    @Test func nothingIsOverwrittenAndItemsGoneFromTheTrashAreSkipped() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/taken.bin")
            try tmp.file("home/Library/Caches/taken.bin")

            let items = try await world.removed(["home/Library/Caches/taken.bin", "home/Library/Caches/gone.bin"])
            let outcome = try await world.history.putBack(items, of: world.runID) { _ in }

            #expect(world.restorer.restored.isEmpty)
            #expect(world.privileged.restored.isEmpty)
            #expect(Set(outcome.skipped.map(\.reason)) == ["Something else is at the original location.", "No longer in the Trash."])
        }
    }

    @Test func thePreviewCountsWhatGoesBackAndWhatAsksForThePassword() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/a.bin")
            try tmp.app("home/.Trash/Tool.app", id: "com.example.tool")
            try world.lock("Applications")
            defer { world.unlock("Applications") }

            let items = try await world.removed(["home/Library/Caches/a.bin", "Applications/Tool.app", "home/Library/Caches/gone.bin"])
            let preview = await world.history.preview(items)

            #expect(preview.restorable == 2)
            #expect(preview.needsPassword == 1)
            #expect(preview.skipped.map(\.reason) == ["No longer in the Trash."])
            #expect(world.restorer.restored.isEmpty && world.privileged.restored.isEmpty)
        }
    }

    @Test func restoredServicesComeWithTheRestartNotice() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/com.example.helper.plist")
            try world.lock("Library/LaunchDaemons")
            defer { world.unlock("Library/LaunchDaemons") }

            let items = try await world.removed(["Library/LaunchDaemons/com.example.helper.plist"])
            let outcome = try await world.history.putBack(items, of: world.runID) { _ in }

            #expect(outcome.restored == 1)
            #expect(outcome.notice == "Restored services start again after you log out or restart.")
            #expect(world.privileged.rootRuns.isEmpty, "A restored service is never loaded again.")
        }
    }

    @Test func aRealRestoreBringsAFileBackAndLeavesAnOccupiedPlaceAlone() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let history = LiveHistory(
                log: world.log, home: world.home, appFolders: [world.apps], systemLibrary: tmp.path("Library"),
                restorer: SystemFileRemover(), privileged: world.privileged
            )
            try Data("keep".utf8).write(to: tmp.path("home/.Trash/a.bin"))
            try Data("new".utf8).write(to: tmp.path("home/.Trash/b.bin"))
            try Data("mine".utf8).write(to: tmp.path("home/Library/Caches/b.bin"))

            let items = try await world.removed(["home/Library/Caches/a.bin", "home/Library/Caches/b.bin"])
            let outcome = try await history.putBack(items, of: world.runID) { _ in }

            #expect(outcome.restored == 1)
            #expect(try String(contentsOf: tmp.path("home/Library/Caches/a.bin"), encoding: .utf8) == "keep")
            #expect(try String(contentsOf: tmp.path("home/Library/Caches/b.bin"), encoding: .utf8) == "mine")
            #expect(FileManager.default.fileExists(atPath: tmp.path("home/.Trash/b.bin").path))
        }
    }
}

@MainActor
struct HistoryModelTests {
    private func makeModel(_ history: FakeHistory) -> HistoryModel {
        HistoryModel(service: history)
    }

    @Test func askingShowsTheConfirmationWithTheCounts() async {
        let run = HistoryRun.sample(count: 3)
        let history = FakeHistory(stored: [run])
        await history.scripted(preview: RestorePreview(restorable: 3, needsPassword: 1))
        let model = makeModel(history)
        await model.load()

        await model.askPutBack(model.restorable(in: model.runs[0]), of: run.id)

        #expect(model.request?.preview.restorable == 3)
        #expect(model.request?.preview.needsPassword == 1)
        #expect(await history.putBacks.isEmpty, "Nothing moves until the user confirms.")
    }

    @Test func confirmingRunsThePutBackAndReloadsHistory() async {
        let run = HistoryRun.sample(count: 2)
        let history = FakeHistory(stored: [run])
        await history.scripted(preview: RestorePreview(restorable: 2), putBack: RestoreOutcome(restored: 2))
        let model = makeModel(history)
        await model.load()
        await model.askPutBack(model.restorable(in: run), of: run.id)

        model.confirmPutBack()
        await model.finishPuttingBack()

        #expect(model.result?.restored == 2)
        #expect(!model.isPuttingBack && model.request == nil)
        #expect(await history.putBacks.first?.run == run.id)
        #expect(await history.putBacks.first?.items.count == 2)
    }

    @Test func cancellingTheConfirmationMovesNothing() async {
        let run = HistoryRun.sample()
        let history = FakeHistory(stored: [run])
        await history.scripted(preview: RestorePreview(restorable: 2))
        let model = makeModel(history)
        await model.load()
        await model.askPutBack(model.restorable(in: run), of: run.id)

        model.cancelRequest()
        model.confirmPutBack()
        await model.finishPuttingBack()

        #expect(model.request == nil && model.result == nil)
        #expect(await history.putBacks.isEmpty)
    }

    @Test func whenNothingCanGoBackTheReasonsAreShownWithoutAsking() async {
        let run = HistoryRun.sample(count: 1)
        let history = FakeHistory(stored: [run])
        let reason = RestoreProblem(originalPath: "/tmp/home/Library/Caches/item0", reason: "No longer in the Trash.")
        await history.scripted(preview: RestorePreview(restorable: 0, skipped: [reason]))
        let model = makeModel(history)
        await model.load()

        await model.askPutBack(model.restorable(in: run), of: run.id)

        #expect(model.request == nil)
        #expect(model.result?.skipped == [reason])
    }

    @Test func deletedRunsOfferNothingToPutBackAndShowTheirStatus() async {
        let run = HistoryRun.sample(trashed: false)
        let model = makeModel(FakeHistory(stored: [run]))
        await model.load()

        #expect(model.restorable(in: model.runs[0]).isEmpty)
        #expect(model.status(of: run.items[0]) == .deleted)
    }

    @Test func anItemWhoseTrashCopyIsGoneIsSaidToBeGone() async {
        let run = HistoryRun.sample(count: 1)
        let model = makeModel(FakeHistory(stored: [run]))
        await model.load()
        #expect(model.status(of: run.items[0]) == .goneFromTheTrash)
    }

    @Test func aNewCleanupAppearsAtOnceAndIsReadAgainFromTheService() async {
        let model = makeModel(FakeHistory())
        let record = CleanupRecord(date: .now, source: "Cleanup", itemCount: 1, freed: ByteSize(5), movedToTrash: true)
        model.insert(record)
        #expect(model.runs.first?.record == record)
    }
}
