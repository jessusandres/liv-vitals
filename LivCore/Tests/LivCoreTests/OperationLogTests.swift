import Foundation
import Testing
@testable import LivCore

struct OperationLogTests {
    private func entry(_ path: String, _ outcome: LogEntry.Outcome = .planned, detail: String? = nil, at seconds: TimeInterval = 1_792_000_000) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: seconds), kind: .dryRun, path: path, bytes: 412_000_000, outcome: outcome, detail: detail)
    }

    @Test func appendAndReadBackKeepsOrderAndDates() async throws {
        try await TemporaryDirectory.use { tmp in
            // The parent folder does not exist yet; append creates it.
            let log = OperationLog(fileURL: tmp.path("Support/LivVitals/operations.jsonl"))
            #expect(try await log.entries().isEmpty)

            let first = [entry("/a", at: 1_792_000_000), entry("/b", .skipped, detail: "Protected location: /b", at: 1_792_000_005)]
            let second = [entry("/c", at: 1_792_000_010)]
            try await log.append(first)
            try await log.append(second)
            try await log.append([])

            #expect(try await log.entries() == first + second)
        }
    }

    @Test func fileIsOneSortedJSONObjectPerLineWithISODates() async throws {
        try await TemporaryDirectory.use { tmp in
            let file = tmp.path("operations.jsonl")
            try await OperationLog(fileURL: file).append([entry("/Users/example/Library/Caches/com.example.app", at: 1_792_000_000)])

            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text == """
                {"bytes":412000000,"date":"2026-10-14T17:46:40Z","detail":null,"kind":"dryRun","outcome":"planned","path":"/Users/example/Library/Caches/com.example.app","runID":null,"source":null,"trashedPath":null}

                """)
        }
    }

    @Test func dryRunLogsPlannedAndSkippedAndLeavesFilesAlone() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            let root = try tmp.directory("home/Library/Caches")
            let cacheFile = try tmp.file("home/Library/Caches/app/data.bin", bytes: 2_000)
            let keychain = try tmp.file("home/Library/Keychains/login.keychain", bytes: 100)
            let guardian = SafetyGuard(home: home, allowedRoots: [root])
            let plan = CleanupPlanner.plan(
                [
                    CleanupItem(url: cacheFile.deletingLastPathComponent(), category: .userCaches, size: ByteSize(2_000)),
                    CleanupItem(url: keychain, category: .userCaches, size: ByteSize(100)),
                ],
                action: .delete,
                guard: guardian
            )

            let log = OperationLog(fileURL: tmp.path("log/operations.jsonl"))
            let written = try await DryRunExecutor(log: log).execute(plan)

            #expect(written.map(\.outcome) == [.planned, .skipped])
            #expect(written.allSatisfy { $0.kind == .dryRun })
            #expect(written[0].detail == nil)
            #expect(written[1].detail?.hasPrefix("Protected location") == true)
            #expect(try await log.entries() == written)
            #expect(FileManager.default.fileExists(atPath: cacheFile.path))
            #expect(FileManager.default.fileExists(atPath: keychain.path))
        }
    }

    @Test func runIDAndTrashedPathSurviveARoundTrip() async throws {
        try await TemporaryDirectory.use { tmp in
            let log = OperationLog(fileURL: tmp.path("operations.jsonl"))
            let run = UUID()
            let entry = LogEntry(
                date: Date(timeIntervalSince1970: 1_792_000_000),
                kind: .trash,
                path: "/Users/example/Library/Caches/x",
                bytes: 5,
                outcome: .done,
                runID: run,
                trashedPath: "/Users/example/.Trash/x"
            )
            try await log.append([entry])
            let read = try await log.entries()
            #expect(read == [entry])
            #expect(read.first?.runID == run)
            #expect(read.first?.trashedPath == "/Users/example/.Trash/x")
        }
    }

    @Test func aMaintenanceLineRoundTripsAndOlderKindsStillRead() async throws {
        try await TemporaryDirectory.use { tmp in
            let file = tmp.path("operations.jsonl")
            let log = OperationLog(fileURL: file)
            let task = LogEntry(date: Date(timeIntervalSince1970: 1_792_000_000), kind: .maintenance, path: "task:dns", bytes: 0, outcome: .done, detail: "Done", source: "Performance")
            try await log.append([task])
            // A line from before Stage 7 sits in the same file.
            let old = #"{"bytes":5,"date":"2026-10-14T10:00:00Z","detail":null,"kind":"trash","outcome":"done","path":"/x/old","runID":null,"source":null,"trashedPath":null}"# + "\n"
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(old.utf8))
            try handle.close()

            let entries = try await log.entries()
            #expect(entries.count == 2)
            #expect(entries[0] == task)
            #expect(entries[0].kind == .maintenance && entries[0].path == "task:dns")
            #expect(entries[1].kind == .trash)
            #expect(try String(contentsOf: file, encoding: .utf8).contains("\"kind\":\"maintenance\""))
        }
    }

    @Test func aLineWrittenBeforeRunIDExistedStillReads() async throws {
        try await TemporaryDirectory.use { tmp in
            let file = tmp.path("operations.jsonl")
            let old = #"{"bytes":412000000,"date":"2026-10-14T17:46:40Z","detail":null,"kind":"dryRun","outcome":"planned","path":"/Users/example/Library/Caches/com.example.app"}"# + "\n"
            try Data(old.utf8).write(to: file)

            let log = OperationLog(fileURL: file)
            let read = try await log.entries()
            #expect(read.count == 1)
            #expect(read[0].runID == nil)
            #expect(read[0].trashedPath == nil)
            #expect(read[0].kind == .dryRun)

            // New lines are appended after the old one.
            try await log.append([LogEntry(kind: .delete, path: "/x", bytes: 1, outcome: .done, runID: UUID())])
            #expect(try await log.entries().count == 2)
        }
    }
}
