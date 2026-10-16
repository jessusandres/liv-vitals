import Foundation
import LivCore
import Testing
@testable import LivVitals

/// Settings on a fake home with a real settings file in the temporary folder.
@MainActor
struct SettingsFoldersAndResetTests {
    private func makeSettings(_ tmp: TemporaryDirectory) throws -> (AppSettings, SettingsStore, URL) {
        let home = try tmp.directory("home")
        let store = SettingsStore(fileURL: tmp.path("Support/settings.json"), home: home)
        return (AppSettings(store: store, home: home, saveDelay: .milliseconds(1)), store, home)
    }

    @Test func installerFoldersStartAsDownloadsAndTheDesktop() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _, home) = try makeSettings(tmp)
            #expect(settings.installerFolders == [home.appending(path: "Downloads").path, home.appending(path: "Desktop").path])
            #expect(settings.scanOptions.installerFolders?.map(\.lastPathComponent) == ["Downloads", "Desktop"])
            #expect(settings.cleanOptions.installerFolders?.map(\.lastPathComponent) == ["Downloads", "Desktop"])
        }
    }

    @Test func aFolderIsAddedAndRemovedAndTheRefusalsSayWhy() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _, home) = try makeSettings(tmp)
            try tmp.directory("home/Installers")
            try tmp.directory("home/Documents")
            try tmp.file("home/notes.txt")

            #expect(settings.addInstallerFolder("~/Installers") == nil)
            #expect(settings.installerFolders.last == home.appending(path: "Installers").path)
            // Adding it again changes nothing.
            #expect(settings.addInstallerFolder("~/Installers") == nil)
            #expect(settings.installerFolders.filter { $0.hasSuffix("/Installers") }.count == 1)

            #expect(settings.addInstallerFolder("~/Documents") == .protectedForInstallers("~/Documents"))
            #expect(settings.addInstallerFolder("~/Documents")?.errorDescription == "~/Documents is protected, so Installers cannot remove anything inside it.")
            #expect(settings.addInstallerFolder("~/Missing") == .doesNotExist)
            #expect(settings.addInstallerFolder("~/notes.txt") == .doesNotExist)
            #expect(settings.addInstallerFolder("") == .empty)
            #expect(settings.addInstallerFolder("/") == .isRoot)

            settings.removeInstallerFolder(home.appending(path: "Installers").path)
            #expect(!settings.installerFolders.contains { $0.hasSuffix("/Installers") })
        }
    }

    @Test func theDesktopIsAllowedEvenThoughItIsProtected() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _, home) = try makeSettings(tmp)
            try tmp.directory("home/Desktop")
            settings.removeInstallerFolder(home.appending(path: "Desktop").path)
            #expect(settings.addInstallerFolder("~/Desktop") == nil)
            #expect(settings.installerFolders.contains(home.appending(path: "Desktop").path))
        }
    }

    @Test func resetRestoresEveryPreferenceButKeepsTheOnboardingFlag() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _, home) = try makeSettings(tmp)
            try tmp.directory("home/Installers")
            try tmp.directory("home/code")
            settings.moveToTrash = false
            settings.dryRun = true
            settings.previewBeforeCleaning = false
            settings.skipRecentProjects = false
            settings.showMenuBarExtra = false
            settings.hasCompletedOnboarding = true
            _ = settings.addProtectedPath("/Volumes/Backup/Keep")
            _ = settings.addProjectRoot("~/code")
            _ = settings.addInstallerFolder("~/Installers")
            settings.removeInstallerFolder(home.appending(path: "Downloads").path)

            settings.resetToDefaults()

            var expected = Settings.defaults(home: home)
            expected.hasCompletedOnboarding = true
            #expect(settings.values == expected)
        }
    }

    @Test func settingsAreReadTheSameAfterTheAppRestarts() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, store, home) = try makeSettings(tmp)
            try tmp.directory("home/Installers")
            settings.dryRun = true
            settings.moveToTrash = false
            _ = settings.addProtectedPath("/Volumes/Backup/Keep")
            _ = settings.addInstallerFolder("~/Installers")
            settings.flush()

            let restarted = AppSettings(store: store, home: home)
            #expect(restarted.values == settings.values)
            #expect(restarted.dryRun && !restarted.moveToTrash)
            #expect(restarted.protectedPaths.contains("/Volumes/Backup/Keep"))
            #expect(restarted.installerFolders.last == home.appending(path: "Installers").path)

            restarted.resetToDefaults()
            restarted.flush()
            #expect(AppSettings(store: store, home: home).values == restarted.values)
        }
    }

    @Test func hidingFromTheDockIsOnByDefaultIsSavedAndReset() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, store, home) = try makeSettings(tmp)
            #expect(settings.hideFromDockWhenClosed)

            settings.hideFromDockWhenClosed = false
            settings.flush()
            let restarted = AppSettings(store: store, home: home)
            #expect(!restarted.hideFromDockWhenClosed)

            restarted.resetToDefaults()
            #expect(restarted.hideFromDockWhenClosed)
            #expect(restarted.values == Settings.defaults(home: home))
        }
    }

    @Test func historySurvivesRestartingTheModels() async throws {
        try await TemporaryDirectory.use { tmp in
            let log = OperationLog(fileURL: tmp.path("Support/operations.jsonl"))
            let run = UUID()
            try await log.append([
                LogEntry(kind: .trash, path: "/h/a", bytes: 10, outcome: .done, runID: run, trashedPath: "/h/.Trash/a", source: "Cleanup"),
                LogEntry(kind: .restore, path: "/h/a", bytes: 10, outcome: .done, runID: run),
            ])
            let first = HistoryModel(service: LiveHistory(log: log))
            await first.load()
            let restarted = HistoryModel(service: LiveHistory(log: log))
            await restarted.load()
            #expect(restarted.runs.map(\.id) == [run])
            #expect(restarted.runs.first?.restoredCount == 1)
            #expect(restarted.runs.first?.record == first.runs.first?.record)
        }
    }
}
