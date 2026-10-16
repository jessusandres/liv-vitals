import Foundation

/// Brings the data of the app's former name, Liv Cleaner, into the Liv Vitals folder on first launch.
///
/// It only copies: the old folder and its files are never moved, changed or deleted, so the old app keeps working
/// and the user can remove them by hand. It does nothing once the new folder exists, so it runs at most once.
public enum DataFolderMigration {
    /// The files worth keeping: the settings and the operation log behind History.
    public static let fileNames = ["settings.json", "operations.jsonl"]

    public enum Outcome: Equatable, Sendable {
        /// The old folder is missing, or has none of the files.
        case nothingToCopy
        /// The new folder already exists, so nothing was touched.
        case alreadyMigrated
        case copied([String])
    }

    public static func applicationSupport(in home: URL) -> URL {
        home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }

    /// Copies the files from `<support>/LivCleaner` to `<support>/LivVitals` when only the old folder exists.
    @discardableResult
    public static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Outcome {
        let support = applicationSupport(in: home)
        let old = support.appending(path: "LivCleaner", directoryHint: .isDirectory)
        let new = support.appending(path: "LivVitals", directoryHint: .isDirectory)
        let manager = FileManager.default
        if manager.fileExists(atPath: new.path) { return .alreadyMigrated }
        let present = fileNames.filter { manager.fileExists(atPath: old.appending(path: $0).path) }
        guard !present.isEmpty else { return .nothingToCopy }
        try manager.createDirectory(at: new, withIntermediateDirectories: true)
        for name in present {
            try manager.copyItem(at: old.appending(path: name), to: new.appending(path: name))
        }
        return .copied(present)
    }
}
