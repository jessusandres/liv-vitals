import Foundation
import Testing
@testable import LivCore

struct DataFolderMigrationTests {
    private func support(_ tmp: TemporaryDirectory) throws -> URL {
        try tmp.directory("home/Library/Application Support")
    }

    private func home(_ tmp: TemporaryDirectory) -> URL { tmp.path("home") }

    @Test func copiesTheOldFilesAndLeavesTheOnesInPlace() async throws {
        try await TemporaryDirectory.use { tmp in
            let old = try support(tmp).appending(path: "LivCleaner")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try Data("settings".utf8).write(to: old.appending(path: "settings.json"))
            try Data("log".utf8).write(to: old.appending(path: "operations.jsonl"))
            try Data("other".utf8).write(to: old.appending(path: "notes.txt"))

            let outcome = try DataFolderMigration.run(home: home(tmp))

            let new = try support(tmp).appending(path: "LivVitals")
            #expect(outcome == .copied(["settings.json", "operations.jsonl"]))
            #expect(try String(contentsOf: new.appending(path: "settings.json"), encoding: .utf8) == "settings")
            #expect(try String(contentsOf: new.appending(path: "operations.jsonl"), encoding: .utf8) == "log")
            #expect(!FileManager.default.fileExists(atPath: new.appending(path: "notes.txt").path))
            // The old folder is untouched.
            #expect(try String(contentsOf: old.appending(path: "settings.json"), encoding: .utf8) == "settings")
            #expect(FileManager.default.fileExists(atPath: old.appending(path: "operations.jsonl").path))
        }
    }

    @Test func copiesJustTheFileThatExists() async throws {
        try await TemporaryDirectory.use { tmp in
            let old = try support(tmp).appending(path: "LivCleaner")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try Data("settings".utf8).write(to: old.appending(path: "settings.json"))
            #expect(try DataFolderMigration.run(home: home(tmp)) == .copied(["settings.json"]))
        }
    }

    @Test func anExistingNewFolderIsNeverTouched() async throws {
        try await TemporaryDirectory.use { tmp in
            let base = try support(tmp)
            let old = base.appending(path: "LivCleaner")
            let new = base.appending(path: "LivVitals")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: old.appending(path: "settings.json"))

            #expect(try DataFolderMigration.run(home: home(tmp)) == .alreadyMigrated)
            #expect(!FileManager.default.fileExists(atPath: new.appending(path: "settings.json").path))
        }
    }

    @Test func noOldFolderMeansNothingToCopyAndNoNewFolder() async throws {
        try await TemporaryDirectory.use { tmp in
            let base = try support(tmp)
            #expect(try DataFolderMigration.run(home: home(tmp)) == .nothingToCopy)
            #expect(!FileManager.default.fileExists(atPath: base.appending(path: "LivVitals").path))
        }
    }

    @Test func runningTwiceCopiesOnlyOnce() async throws {
        try await TemporaryDirectory.use { tmp in
            let old = try support(tmp).appending(path: "LivCleaner")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try Data("a".utf8).write(to: old.appending(path: "settings.json"))
            _ = try DataFolderMigration.run(home: home(tmp))
            #expect(try DataFolderMigration.run(home: home(tmp)) == .alreadyMigrated)
        }
    }
}
