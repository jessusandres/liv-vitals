import Foundation

/// Reads and writes `Settings` as JSON. With no file URL it keeps nothing on disk, which previews and snapshots rely on.
public struct SettingsStore: Sendable {
    /// 2 added `dryRun`, 3 `installerFolders` and 4 the menu bar `indicators`; an older file simply lacks them and gets the defaults.
    public static let currentSchemaVersion = 4

    private let fileURL: URL?
    private let home: URL

    public init(fileURL: URL?, home: URL) {
        self.fileURL = fileURL
        self.home = home
    }

    /// The app's file: `~/Library/Application Support/LivVitals/settings.json`.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SettingsStore {
        SettingsStore(
            fileURL: home.appending(path: "Library/Application Support/LivVitals/settings.json"),
            home: home
        )
    }

    /// The saved settings, with defaults for anything missing. A missing, unreadable or newer-format file
    /// gives the defaults and is left untouched until the next `save`.
    public func load() -> Settings {
        let defaults = Settings.defaults(home: home)
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              (stored.schemaVersion ?? 1) <= Self.currentSchemaVersion
        else { return defaults }

        var settings = defaults
        settings.moveToTrash = stored.moveToTrash ?? defaults.moveToTrash
        settings.dryRun = stored.dryRun ?? defaults.dryRun
        settings.previewBeforeCleaning = stored.previewBeforeCleaning ?? defaults.previewBeforeCleaning
        settings.skipRecentProjects = stored.skipRecentProjects ?? defaults.skipRecentProjects
        settings.showMenuBarExtra = stored.showMenuBarExtra ?? defaults.showMenuBarExtra
        settings.hideFromDockWhenClosed = stored.hideFromDockWhenClosed ?? defaults.hideFromDockWhenClosed
        settings.hasCompletedOnboarding = stored.hasCompletedOnboarding ?? defaults.hasCompletedOnboarding
        settings.protectedPaths = stored.protectedPaths ?? defaults.protectedPaths
        settings.projectRoots = stored.projectRoots ?? defaults.projectRoots
        settings.installerFolders = stored.installerFolders ?? defaults.installerFolders
        settings.indicators = IndicatorSetting.normalized(stored.indicators?.compactMap(\.value))
        settings.indicatorRefresh = stored.indicatorRefresh.flatMap { IndicatorSetting.refreshChoices.contains($0) ? $0 : nil } ?? defaults.indicatorRefresh
        return settings
    }

    public func save(_ settings: Settings) throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }

    private struct Lossy: Decodable {
        var value: IndicatorSetting?
        init(from decoder: Decoder) throws { value = try? IndicatorSetting(from: decoder) }
    }

    /// Every field optional, so a file from an older version still loads.
    private struct Stored: Decodable {
        var schemaVersion: Int?
        var moveToTrash: Bool?
        var dryRun: Bool?
        var previewBeforeCleaning: Bool?
        var skipRecentProjects: Bool?
        var showMenuBarExtra: Bool?
        var hideFromDockWhenClosed: Bool?
        var hasCompletedOnboarding: Bool?
        var protectedPaths: [String]?
        var projectRoots: [String]?
        var installerFolders: [String]?
        /// One unreadable entry (a metric from a future version) must not discard the whole file.
        var indicators: [Lossy]?
        var indicatorRefresh: Int?
    }
}
