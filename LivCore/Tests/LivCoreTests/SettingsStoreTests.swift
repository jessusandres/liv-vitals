import Foundation
import Testing
@testable import LivCore

struct SettingsStoreTests {
    private func makeStore(_ tmp: TemporaryDirectory) throws -> (store: SettingsStore, file: URL, home: URL) {
        let home = try tmp.directory("home")
        let file = tmp.path("Support/LivVitals/settings.json")
        return (SettingsStore(fileURL: file, home: home), file, home)
    }

    @Test func missingFileGivesDefaultsWithAbsolutePaths() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, home) = try makeStore(tmp)
            let settings = store.load()
            #expect(settings == Settings.defaults(home: home))
            #expect(settings.protectedPaths.allSatisfy { $0.hasPrefix("/") })
            #expect(settings.projectRoots.contains(home.appending(path: "code").standardizedFileURL.path))
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func saveThenLoadRoundTripsAndCreatesTheFolder() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, home) = try makeStore(tmp)
            var settings = Settings.defaults(home: home)
            settings.moveToTrash = false
            settings.showMenuBarExtra = false
            settings.hasCompletedOnboarding = true
            settings.protectedPaths.append("/Volumes/Backup/Keep")
            settings.projectRoots = ["/Users/example/work"]

            try store.save(settings)
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(store.load() == settings)
        }
    }

    @Test func fieldsMissingFromTheFileTakeTheirDefaults() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, home) = try makeStore(tmp)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"schemaVersion":1,"moveToTrash":false}"#.utf8).write(to: file)

            var expected = Settings.defaults(home: home)
            expected.moveToTrash = false
            #expect(store.load() == expected)
        }
    }

    @Test func corruptFileGivesDefaultsAndIsLeftAloneUntilTheNextSave() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, home) = try makeStore(tmp)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not json {".utf8).write(to: file)

            #expect(store.load() == Settings.defaults(home: home))
            #expect(try String(contentsOf: file, encoding: .utf8) == "not json {")

            try store.save(Settings.defaults(home: home))
            #expect(store.load() == Settings.defaults(home: home))
            #expect(try String(contentsOf: file, encoding: .utf8).contains("schemaVersion"))
        }
    }

    @Test func newerSchemaVersionIsIgnored() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, home) = try makeStore(tmp)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"schemaVersion":99,"moveToTrash":false}"#.utf8).write(to: file)
            #expect(store.load() == Settings.defaults(home: home))
        }
    }

    @Test func storeWithoutAFileKeepsNothingOnDisk() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            let store = SettingsStore(fileURL: nil, home: home)
            var settings = Settings.defaults(home: home)
            settings.moveToTrash = false
            try store.save(settings)
            // Nothing is remembered and nothing is written next to the home folder.
            #expect(store.load() == Settings.defaults(home: home))
            #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["home"])
        }
    }

    @Test func pathNormalizationExpandsAndStandardizes() {
        let home = URL(filePath: "/Users/example")
        func normalized(_ input: String) -> String? { try? SettingsPath.normalize(input, home: home).get() }

        #expect(normalized("~/code") == "/Users/example/code")
        #expect(normalized("~") == "/Users/example")
        #expect(normalized("  /Users/example/Projects/  ") == "/Users/example/Projects")
        #expect(normalized("/Users/example/a/../b//c") == "/Users/example/b/c")
    }

    @Test func pathNormalizationRejectsUnusableInput() {
        let home = URL(filePath: "/Users/example")
        func error(_ input: String) -> SettingsPathError? {
            if case .failure(let error) = SettingsPath.normalize(input, home: home) { return error }
            return nil
        }

        #expect(error("") == .empty)
        #expect(error("   ") == .empty)
        #expect(error("relative/path") == .notAbsolute)
        #expect(error("~other/code") == .notAbsolute)
        #expect(error("/") == .isRoot)
        #expect(error("/Users/..") == .isRoot)
        #expect(error("/Users/example/a\0b") == .invalid)
    }

    @Test func aVersionOneFileGainsTheDryRunDefault() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, home) = try makeStore(tmp)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"schemaVersion":1,"moveToTrash":false,"showMenuBarExtra":false}"#.utf8).write(to: file)

            var expected = Settings.defaults(home: home)
            expected.moveToTrash = false
            expected.showMenuBarExtra = false
            #expect(store.load() == expected)
            #expect(!store.load().dryRun)

            var saved = store.load()
            saved.dryRun = true
            try store.save(saved)
            #expect(store.load().dryRun)
            #expect(Settings.defaults(home: home).schemaVersion == 4)
        }
    }

    @Test func aVersionTwoFileGainsTheDefaultInstallerFolders() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, home) = try makeStore(tmp)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"schemaVersion":2,"dryRun":true}"#.utf8).write(to: file)

            var expected = Settings.defaults(home: home)
            expected.dryRun = true
            #expect(store.load() == expected)
            #expect(store.load().installerFolders == [
                home.appending(path: "Downloads").standardizedFileURL.path,
                home.appending(path: "Desktop").standardizedFileURL.path,
            ])

            var saved = store.load()
            saved.installerFolders = ["/Users/example/Installers"]
            try store.save(saved)
            #expect(store.load().installerFolders == ["/Users/example/Installers"])
        }
    }

    @Test func hidingFromTheDockDefaultsToOnForOlderFilesAndRoundTrips() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, home) = try makeStore(tmp)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"schemaVersion":3,"dryRun":true}"#.utf8).write(to: file)
            #expect(store.load().hideFromDockWhenClosed)

            var settings = Settings.defaults(home: home)
            settings.hideFromDockWhenClosed = false
            try store.save(settings)
            #expect(!store.load().hideFromDockWhenClosed)
        }
    }
}
