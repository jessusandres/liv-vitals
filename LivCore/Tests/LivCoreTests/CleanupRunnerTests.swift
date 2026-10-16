import Foundation
import os
import Testing
@testable import LivCore

/// A remover that records what it was asked and removes nothing, so tests never touch a real Trash.
final class FakeRemover: FileRemoving, Sendable {
    private struct State {
        var trashed: [URL] = []
        var deleted: [URL] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let failingNames: Set<String>

    init(failingNames: Set<String> = []) {
        self.failingNames = failingNames
    }

    var trashed: [URL] { state.withLock { $0.trashed } }
    var deleted: [URL] { state.withLock { $0.deleted } }

    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "Refused by the fake." }
    }

    func trash(_ url: URL) throws -> URL? {
        if failingNames.contains(url.lastPathComponent) { throw Refused() }
        state.withLock { $0.trashed.append(url) }
        return URL(filePath: "/fake/.Trash/\(url.lastPathComponent)")
    }

    func delete(_ url: URL) throws {
        if failingNames.contains(url.lastPathComponent) { throw Refused() }
        state.withLock { $0.deleted.append(url) }
    }
}

struct CleanupRunnerTests {
    /// A fake home with `Library/Caches` as the only allowed root.
    private struct World {
        let home: URL
        let root: URL
        let guardian: SafetyGuard
        let log: OperationLog

        init(_ tmp: TemporaryDirectory, whitelist: [URL] = []) throws {
            home = try tmp.directory("home")
            root = try tmp.directory("home/Library/Caches")
            guardian = SafetyGuard(home: home, allowedRoots: [root], whitelist: whitelist)
            log = OperationLog(fileURL: tmp.path("Support/operations.jsonl"))
        }

        /// A cleanup item whose URL says whether it is a folder, like the ones the scanner produces.
        func item(_ name: String, bytes: Int64 = 100, folder: Bool = false) -> CleanupItem {
            let url = root.appending(path: name, directoryHint: folder ? .isDirectory : .notDirectory)
            return CleanupItem(url: url, category: .userCaches, size: ByteSize(bytes))
        }
    }

    @Test func trashesAndDeletesAndLogsEveryStepUnderOneRunID() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/Library/Caches/a.bin", bytes: 10)
            try tmp.directory("home/Library/Caches/folder")
            let remover = FakeRemover()
            let runID = UUID()
            let items = [world.item("a.bin", bytes: 10), world.item("folder", bytes: 20, folder: true)]
            let plan = CleanupPlanner.plan(items, action: { $0.url.lastPathComponent == "a.bin" ? .moveToTrash : .delete }, guard: world.guardian)

            let runner = CleanupRunner(guard: world.guardian, remover: remover, log: world.log, runID: runID)
            let entries = try await runner.execute(plan)

            #expect(entries.map(\.outcome) == [.done, .done])
            #expect(entries.map(\.kind) == [.trash, .delete])
            #expect(entries[0].trashedPath == "/fake/.Trash/a.bin")
            #expect(entries[1].trashedPath == nil)
            #expect(entries.map(\.bytes) == [10, 20])
            #expect(entries.allSatisfy { $0.runID == runID })
            #expect(remover.trashed.map(\.lastPathComponent) == ["a.bin"])
            #expect(remover.deleted.map(\.lastPathComponent) == ["folder"])
            #expect(try await world.log.entries() == entries)
        }
    }

    @Test func itemsBlockedInThePlanAreSkippedWithTheReason() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let outside = CleanupItem(url: tmp.path("elsewhere/file"), category: .userCaches, size: ByteSize(5))
            let plan = CleanupPlanner.plan([outside], action: .moveToTrash, guard: world.guardian)
            let remover = FakeRemover()

            let entries = try await CleanupRunner(guard: world.guardian, remover: remover, log: world.log).execute(plan)
            #expect(entries.map(\.outcome) == [.skipped])
            #expect(entries[0].detail?.hasPrefix("Outside the folders") == true)
            #expect(remover.trashed.isEmpty)
        }
    }

    @Test func aPathWhitelistedAfterThePlanIsCheckedAgainAndSkipped() async throws {
        try await TemporaryDirectory.use { tmp in
            let planner = try World(tmp)
            try tmp.file("home/Library/Caches/keep.bin", bytes: 10)
            let plan = CleanupPlanner.plan([planner.item("keep.bin")], action: .moveToTrash, guard: planner.guardian)
            #expect(plan.blocked.isEmpty)

            // The user whitelists it before the run starts.
            let stricter = SafetyGuard(home: planner.home, allowedRoots: [planner.root], whitelist: [planner.root.appending(path: "keep.bin")])
            let remover = FakeRemover()
            let entries = try await CleanupRunner(guard: stricter, remover: remover, log: planner.log).execute(plan)

            #expect(entries.map(\.outcome) == [.skipped])
            #expect(entries[0].detail?.hasPrefix("Excluded by the whitelist") == true)
            #expect(remover.trashed.isEmpty)
        }
    }

    @Test func anItemThatVanishedIsSkipped() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let plan = CleanupPlanner.plan([world.item("gone.bin")], action: .moveToTrash, guard: world.guardian)
            let remover = FakeRemover()
            let entries = try await CleanupRunner(guard: world.guardian, remover: remover, log: world.log).execute(plan)
            #expect(entries.map(\.outcome) == [.skipped])
            #expect(entries[0].detail == "No longer exists")
            #expect(remover.trashed.isEmpty)
        }
    }

    @Test func aFolderReplacedByASymlinkIsNeverTouched() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            // It was a folder when scanned; now the same path is a link pointing somewhere precious.
            let precious = try tmp.directory("precious")
            try tmp.symlink("home/Library/Caches/swapped", to: precious)
            let plan = CleanupPlanner.plan([world.item("swapped", folder: true)], action: .delete, guard: world.guardian)
            let remover = FakeRemover()

            let entries = try await CleanupRunner(guard: world.guardian, remover: remover, log: world.log).execute(plan)
            #expect(entries.map(\.outcome) == [.skipped])
            #expect(entries[0].detail == "Changed since the scan")
            #expect(remover.trashed.isEmpty && remover.deleted.isEmpty)
            #expect(FileManager.default.fileExists(atPath: precious.path))
        }
    }

    @Test func aFileTurnedIntoAFolderIsSkippedToo() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.directory("home/Library/Caches/was-a-file")
            let plan = CleanupPlanner.plan([world.item("was-a-file", folder: false)], action: .delete, guard: world.guardian)
            let remover = FakeRemover()
            let entries = try await CleanupRunner(guard: world.guardian, remover: remover, log: world.log).execute(plan)
            #expect(entries.map(\.detail) == ["Changed since the scan"])
            #expect(remover.deleted.isEmpty)
        }
    }

    @Test func oneFailureDoesNotStopTheOthers() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            for name in ["one.bin", "two.bin", "three.bin"] { try tmp.file("home/Library/Caches/\(name)", bytes: 1) }
            let items = ["one.bin", "two.bin", "three.bin"].map { world.item($0) }
            let plan = CleanupPlanner.plan(items, action: .moveToTrash, guard: world.guardian)
            let remover = FakeRemover(failingNames: ["two.bin"])

            let entries = try await CleanupRunner(guard: world.guardian, remover: remover, log: world.log).execute(plan)
            #expect(entries.map(\.outcome) == [.done, .failed, .done])
            #expect(entries[1].detail == "Refused by the fake.")
            #expect(remover.trashed.map(\.lastPathComponent) == ["one.bin", "three.bin"])
        }
    }

    @Test func cancellingStopsBetweenItemsAndKeepsTheLog() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            for name in ["one.bin", "two.bin", "three.bin"] { try tmp.file("home/Library/Caches/\(name)", bytes: 1) }
            let items = ["one.bin", "two.bin", "three.bin"].map { world.item($0) }
            let plan = CleanupPlanner.plan(items, action: .moveToTrash, guard: world.guardian)
            let remover = FakeRemover()
            // The progress report before the second item cancels the run.
            let runner = CleanupRunner(guard: world.guardian, remover: remover, log: world.log) { done, _, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }

            let task = Task { try await runner.execute(plan) }
            let entries = try await task.value
            #expect(entries.count == 1)
            #expect(remover.trashed.map(\.lastPathComponent) == ["one.bin"])
            #expect(try await world.log.entries().count == 1)
        }
    }

    @Test func progressReportsHowManyWereHandled() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            for name in ["a.bin", "b.bin"] { try tmp.file("home/Library/Caches/\(name)", bytes: 1) }
            let plan = CleanupPlanner.plan([world.item("a.bin"), world.item("b.bin")], action: .moveToTrash, guard: world.guardian)
            let seen = OSAllocatedUnfairLock(initialState: [String]())
            let runner = CleanupRunner(guard: world.guardian, remover: FakeRemover(), log: world.log) { done, total, url in
                seen.withLock { $0.append("\(done)/\(total) \(url.lastPathComponent)") }
            }
            _ = try await runner.execute(plan)
            #expect(seen.withLock { $0 } == ["0/2 a.bin", "1/2 b.bin"])
        }
    }
}

struct SystemFileRemoverTests {
    @Test func deleteRemovesAFileAndAFolderTreeInsideTheTemporaryFolder() async throws {
        try await TemporaryDirectory.use { tmp in
            let file = try tmp.file("one.bin", bytes: 10)
            try tmp.file("tree/a/b/c.bin", bytes: 10)
            let remover = SystemFileRemover()

            try remover.delete(file)
            try remover.delete(tmp.path("tree"))
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!FileManager.default.fileExists(atPath: tmp.path("tree").path))
        }
    }

    @Test func deleteOfAMissingPathThrows() async throws {
        try await TemporaryDirectory.use { tmp in
            #expect(throws: (any Error).self) { try SystemFileRemover().delete(tmp.path("missing")) }
        }
    }

    @Test func deleteRemovesASymlinkWithoutTouchingItsTarget() async throws {
        try await TemporaryDirectory.use { tmp in
            let target = try tmp.file("target.bin", bytes: 10)
            let link = try tmp.symlink("link", to: target)
            try SystemFileRemover().delete(link)
            #expect(!FileManager.default.fileExists(atPath: link.path))
            #expect(FileManager.default.fileExists(atPath: target.path))
        }
    }
}
