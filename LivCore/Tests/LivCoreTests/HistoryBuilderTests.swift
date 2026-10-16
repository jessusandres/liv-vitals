import Foundation
import Testing
@testable import LivCore

struct HistoryBuilderTests {
    private let first = UUID()
    private let second = UUID()
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func removal(
        _ path: String, run: UUID?, kind: LogEntry.Kind = .trash, outcome: LogEntry.Outcome = .done,
        bytes: Int64 = 100, trashed: String? = nil, at offset: TimeInterval = 0, source: String? = "Cleanup"
    ) -> LogEntry {
        LogEntry(
            date: base.addingTimeInterval(offset), kind: kind, path: path, bytes: bytes, outcome: outcome,
            runID: run, trashedPath: trashed ?? (kind == .trash ? "/home/.Trash/\(URL(filePath: path).lastPathComponent)" : nil),
            source: source
        )
    }

    private func restore(_ path: String, run: UUID, outcome: LogEntry.Outcome, at offset: TimeInterval) -> LogEntry {
        LogEntry(date: base.addingTimeInterval(offset), kind: .restore, path: path, bytes: 100, outcome: outcome, runID: run)
    }

    @Test func groupsFinishedRemovalsByRunNewestFirst() {
        let runs = HistoryBuilder.runs(from: [
            removal("/home/a", run: first, at: 0),
            removal("/home/b", run: first, bytes: 50, at: 5),
            removal("/home/c", run: second, kind: .delete, at: 100, source: "Space Lens"),
        ])
        #expect(runs.map(\.id) == [second, first])
        #expect(runs[1].record.itemCount == 2)
        #expect(runs[1].record.freed == ByteSize(150))
        #expect(runs[1].record.movedToTrash)
        #expect(!runs[0].record.movedToTrash)
        #expect(runs[0].record.source == "Space Lens")
        #expect(runs[1].items.map(\.originalPath) == ["/home/a", "/home/b"])
    }

    @Test func dryRunsSkippedFailedAndLinesWithoutARunAreLeftOut() {
        let runs = HistoryBuilder.runs(from: [
            removal("/home/a", run: first, kind: .dryRun),
            removal("/home/b", run: first, outcome: .skipped),
            removal("/home/c", run: first, outcome: .failed),
            removal("/home/d", run: nil),
        ])
        #expect(runs.isEmpty)
    }

    @Test func aDeletedItemHasNoTrashPathAndCannotBePutBack() {
        let run = HistoryBuilder.runs(from: [removal("/home/a", run: first, kind: .delete)])[0]
        #expect(run.items[0].trashedPath == nil)
        #expect(run.restorableCount == 0)
    }

    @Test func aFinishedRestoreMarksTheItemAndOnlyThatOne() {
        let run = HistoryBuilder.runs(from: [
            removal("/home/a", run: first), removal("/home/b", run: first), removal("/home/a", run: second),
            restore("/home/a", run: first, outcome: .done, at: 10),
        ])
        let target = run.first { $0.id == first }!
        #expect(target.items.first { $0.originalPath == "/home/a" }?.restoredAt == base.addingTimeInterval(10))
        #expect(target.items.first { $0.originalPath == "/home/b" }?.restoredAt == nil)
        #expect(target.restorableCount == 1)
        #expect(target.restoredCount == 1)
        // The same path in another run is a different item.
        #expect(run.first { $0.id == second }?.restorableCount == 1)
    }

    @Test func aSkippedOrFailedRestoreChangesNothingAndTotalsStayTheSame() {
        let before = HistoryBuilder.runs(from: [removal("/home/a", run: first)])
        let after = HistoryBuilder.runs(from: [
            removal("/home/a", run: first),
            restore("/home/a", run: first, outcome: .skipped, at: 1),
            restore("/home/a", run: first, outcome: .failed, at: 2),
        ])
        #expect(after[0].restorableCount == 1)
        #expect(after[0].record == before[0].record)

        let restored = HistoryBuilder.runs(from: [removal("/home/a", run: first), restore("/home/a", run: first, outcome: .done, at: 3)])
        #expect(restored[0].record == before[0].record)
    }

    @Test func logsWrittenBeforeRestoreExistedStillRead() async throws {
        try await TemporaryDirectory.use { tmp in
            let file = tmp.path("operations.jsonl")
            let line = #"{"bytes":10,"date":"2026-01-01T10:00:00Z","detail":null,"kind":"trash","outcome":"done","path":"/home/a","runID":"\#(first.uuidString)","source":"Cleanup","trashedPath":"/home/.Trash/a"}"#
            try Data((line + "\n").utf8).write(to: file)
            let entries = try await OperationLog(fileURL: file).entries()
            let runs = HistoryBuilder.runs(from: entries)
            #expect(runs.count == 1)
            #expect(runs[0].restorableCount == 1)
        }
    }

    @Test func aRestoreEntryRoundTripsThroughTheLog() async throws {
        try await TemporaryDirectory.use { tmp in
            let log = OperationLog(fileURL: tmp.path("operations.jsonl"))
            let entry = restore("/home/a", run: first, outcome: .done, at: 0)
            try await log.append([entry])
            #expect(try await log.entries() == [entry])
        }
    }
}
