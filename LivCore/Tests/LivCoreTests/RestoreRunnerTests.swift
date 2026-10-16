import Foundation
import os
import Testing
@testable import LivCore

/// Records restores and moves nothing, so a test never touches a real Trash.
final class FakeRestorer: FileRestoring, Sendable {
    private let moves = OSAllocatedUnfairLock(initialState: [(from: URL, to: URL)]())
    private let failingNames: Set<String>

    init(failingNames: Set<String> = []) {
        self.failingNames = failingNames
    }

    var restored: [(from: URL, to: URL)] { moves.withLock { $0 } }

    func restore(_ trashed: URL, to original: URL) throws {
        if failingNames.contains(trashed.lastPathComponent) { throw FakeRemover.Refused() }
        moves.withLock { $0.append((trashed, original)) }
    }
}

struct RestoreRunnerTests {
    private struct World {
        let tmp: TemporaryDirectory
        let log: OperationLog
        let planner: RestorePlanner
        let runID = UUID()

        init(_ tmp: TemporaryDirectory) throws {
            self.tmp = tmp
            let home = try tmp.directory("home")
            try tmp.directory("home/.Trash")
            try tmp.directory("home/Library/Caches")
            log = OperationLog(fileURL: tmp.path("Support/operations.jsonl"))
            planner = RestorePlanner(home: home, appFolders: [tmp.path("Applications")], systemLibrary: tmp.path("Library"))
        }

        func item(_ name: String) -> HistoryItem {
            HistoryItem(originalPath: tmp.path("home/Library/Caches/\(name)").path, trashedPath: tmp.path("home/.Trash/\(name)").path, bytes: 7)
        }

        func runner(_ restorer: any FileRestoring) -> RestoreRunner {
            RestoreRunner(planner: planner, restorer: restorer, log: log, runID: runID, source: "Cleanup")
        }
    }

    @Test func putsItemsBackAndLogsEachStepUnderTheOriginalRun() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/a.bin")
            try tmp.file("home/.Trash/b.bin")
            let restorer = FakeRestorer()
            let runner = world.runner(restorer)

            let report = try await runner.execute(runner.plan([world.item("a.bin"), world.item("b.bin")]))

            #expect(restorer.restored.map(\.to.lastPathComponent) == ["a.bin", "b.bin"])
            #expect(report.entries.allSatisfy { $0.kind == .restore && $0.outcome == .done && $0.runID == world.runID })
            #expect(report.entries.map(\.path) == [world.item("a.bin").originalPath, world.item("b.bin").originalPath])
            #expect(report.entries[0].trashedPath == world.item("a.bin").trashedPath)
            #expect(report.entries[0].source == "Cleanup")
            #expect(try await world.log.entries() == report.entries)
            #expect(report.adminRestores.isEmpty)
        }
    }

    @Test func aFailureDoesNotStopTheOthers() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            for name in ["a.bin", "b.bin", "c.bin"] { try tmp.file("home/.Trash/\(name)") }
            let restorer = FakeRestorer(failingNames: ["b.bin"])
            let runner = world.runner(restorer)

            let report = try await runner.execute(runner.plan(["a.bin", "b.bin", "c.bin"].map(world.item)))

            #expect(report.entries.map(\.outcome) == [.done, .failed, .done])
            #expect(report.entries[1].detail == "Refused by the fake.")
            #expect(restorer.restored.count == 2)
        }
    }

    @Test func aSkippedPlanStepIsLoggedWithItsReasonAndNothingMoves() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let restorer = FakeRestorer()
            let runner = world.runner(restorer)

            let report = try await runner.execute(runner.plan([world.item("gone.bin")]))

            #expect(report.entries.map(\.outcome) == [.skipped])
            #expect(report.entries[0].detail == "No longer in the Trash.")
            #expect(restorer.restored.isEmpty)
        }
    }

    @Test func somethingThatAppearsAfterThePlanIsNotOverwritten() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/a.bin")
            let restorer = FakeRestorer()
            let runner = world.runner(restorer)
            let planned = runner.plan([world.item("a.bin")])
            guard case .asUser = planned[0].step else { Issue.record("expected a user step"); return }

            try tmp.file("home/Library/Caches/a.bin")
            let report = try await runner.execute(planned)

            #expect(report.entries.map(\.outcome) == [.skipped])
            #expect(report.entries[0].detail == "Something else is at the original location.")
            #expect(restorer.restored.isEmpty)
        }
    }

    @Test func cancellingStopsBeforeTheNextItem() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            for name in ["a.bin", "b.bin"] { try tmp.file("home/.Trash/\(name)") }
            let restorer = FakeRestorer()
            let runner = world.runner(restorer)
            let planned = runner.plan(["a.bin", "b.bin"].map(world.item))

            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await runner.execute(planned)
            }
            let report = try await task.value

            #expect(report.entries.isEmpty)
            #expect(restorer.restored.isEmpty)
        }
    }

    @Test func administratorStepsComeBackUntouchedAndCanBeLoggedAfterwards() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let item = HistoryItem(originalPath: "/Applications/Tool.app", trashedPath: "/home/.Trash/Tool.app", bytes: 9)
            let from = URL(filePath: "/home/.Trash/Tool.app")
            let to = URL(filePath: "/Applications/Tool.app")
            let restorer = FakeRestorer()
            let runner = world.runner(restorer)

            let report = try await runner.execute([(item, .asAdmin(from: from, to: to))])
            #expect(report.entries.isEmpty)
            #expect(report.adminRestores == [AdminRestore(item: item, from: from, to: to)])
            #expect(restorer.restored.isEmpty)

            let entry = try await runner.recordAdmin(report.adminRestores[0], outcome: .skipped, detail: "The password dialog was cancelled.")
            #expect(entry.kind == .restore && entry.outcome == .skipped && entry.runID == world.runID)
            #expect(try await world.log.entries() == [entry])
        }
    }

    @Test func theRealRestorerMovesAFileBackAndRefusesToOverwrite() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try Data("keep me".utf8).write(to: tmp.path("home/.Trash/a.bin"))
            let runner = world.runner(SystemFileRemover())

            let first = try await runner.execute(runner.plan([world.item("a.bin")]))
            #expect(first.entries.map(\.outcome) == [.done])
            #expect(try String(contentsOf: tmp.path("home/Library/Caches/a.bin"), encoding: .utf8) == "keep me")
            #expect(!FileManager.default.fileExists(atPath: tmp.path("home/.Trash/a.bin").path))

            // The destination is now taken: a direct restore throws instead of overwriting.
            try Data("other".utf8).write(to: tmp.path("home/.Trash/a.bin"))
            #expect(throws: (any Error).self) {
                try SystemFileRemover().restore(tmp.path("home/.Trash/a.bin"), to: tmp.path("home/Library/Caches/a.bin"))
            }
            #expect(try String(contentsOf: tmp.path("home/Library/Caches/a.bin"), encoding: .utf8) == "keep me")
        }
    }
}
