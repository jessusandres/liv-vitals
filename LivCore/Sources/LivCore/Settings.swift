import Foundation

/// What the user can configure. Paths are absolute and normalized.
public struct Settings: Codable, Equatable, Sendable {
    public var schemaVersion = SettingsStore.currentSchemaVersion
    public var moveToTrash = true
    /// Plan and log a cleanup without touching any file.
    public var dryRun = false
    public var previewBeforeCleaning = true
    public var skipRecentProjects = true
    public var showMenuBarExtra = true
    /// Closing the window (⌘W) also removes the Dock icon and leaves the app in the menu bar. Only applies while
    /// the menu bar icon is shown, since it is then the way back in.
    public var hideFromDockWhenClosed = true
    public var hasCompletedOnboarding = false
    /// Menu bar indicators (Stage 10): all seven metrics, each off until the user turns it on.
    public var indicators: [IndicatorSetting] = IndicatorSetting.defaults
    /// Seconds between readings while an indicator is showing; one of `IndicatorSetting.refreshChoices`.
    public var indicatorRefresh = IndicatorSetting.defaultRefresh
    /// Folders that cleaning never scans or removes.
    public var protectedPaths: [String]
    /// Folders where Dev Projects looks for build artifacts.
    public var projectRoots: [String]
    /// Folders where Installers looks for disk images and packages.
    public var installerFolders: [String]

    public init(protectedPaths: [String], projectRoots: [String], installerFolders: [String]) {
        self.protectedPaths = protectedPaths
        self.projectRoots = projectRoots
        self.installerFolders = installerFolders
    }

    public static func defaults(home: URL) -> Settings {
        func path(_ relative: String) -> String { home.appending(path: relative).standardizedFileURL.path }
        return Settings(
            protectedPaths: [path("Documents"), path("Library/Mobile Documents"), path("Library/Keychains")],
            projectRoots: [path("code"), path("Projects"), path("Developer")],
            installerFolders: [path("Downloads"), path("Desktop")]
        )
    }
}

public enum SettingsPathError: Error, Equatable, LocalizedError {
    case empty
    case notAbsolute
    case isRoot
    case invalid
    /// A folder Liv Vitals never cleans inside. Carries the path as the user should read it.
    case protected(String)
    /// The same, for the folders Installers searches.
    case protectedForInstallers(String)
    case doesNotExist

    public var errorDescription: String? {
        switch self {
        case .protected(let path): "\(path) is protected, so Dev Projects cannot clean inside it."
        case .protectedForInstallers(let path): "\(path) is protected, so Installers cannot remove anything inside it."
        case .doesNotExist: "That folder does not exist."
        case .empty: "Enter a folder path."
        case .notAbsolute: "Use an absolute path, or one starting with ~."
        case .isRoot: "The whole disk cannot be used here."
        case .invalid: "That path contains invalid characters."
        }
    }
}

public enum SettingsPath {
    /// Trims, expands a leading `~`, and standardizes (`..`, `//`). Rejects anything that is not a usable folder path.
    public static func normalize(_ input: String, home: URL) -> Result<String, SettingsPathError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed.contains("\0") { return .failure(.invalid) }

        var path = trimmed
        if path == "~" {
            path = home.path
        } else if path.hasPrefix("~/") {
            path = home.path + "/" + path.dropFirst(2)
        }
        guard path.hasPrefix("/") else { return .failure(.notAbsolute) }

        let standardized = URL(filePath: path).standardizedFileURL.path
        return standardized == "/" ? .failure(.isRoot) : .success(standardized)
    }
}
