import CoreServices
import Darwin
import Foundation

/// An app bundle found in an applications folder, with what its `Info.plist` says about it.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: URL { url }

    /// The bundle, built with a directory hint.
    public let url: URL
    public let bundleID: String
    /// What the user sees: `CFBundleDisplayName`, `CFBundleName`, or the bundle's file name.
    public let name: String
    public let version: String?
    public let executableName: String?
    /// Installed by the App Store (it has a receipt).
    public let isAppStore: Bool
    /// Made by Apple (`com.apple.*`).
    public let isApple: Bool
    /// The bundle or its folder is not writable by the user, so moving it to the Trash needs administrator rights.
    public let needsAdmin: Bool

    public init(
        url: URL, bundleID: String, name: String, version: String? = nil, executableName: String? = nil,
        isAppStore: Bool = false, isApple: Bool = false, needsAdmin: Bool = false
    ) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.executableName = executableName
        self.isAppStore = isAppStore
        self.isApple = isApple
        self.needsAdmin = needsAdmin
    }

    /// Reads the bundle at `url`. nil when it is not an app bundle or has no bundle identifier.
    public static func read(at url: URL) -> InstalledApp? {
        let bundle = URL(filePath: url.path, directoryHint: .isDirectory)
        let plistURL = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let bundleID = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespaces),
              !bundleID.isEmpty
        else { return nil }

        let fileName = bundle.deletingPathExtension().lastPathComponent
        let name = [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? fileName
        let receipt = bundle.appending(path: "Contents/_MASReceipt").path
        let parent = bundle.deletingLastPathComponent().path
        return InstalledApp(
            url: bundle,
            bundleID: bundleID,
            name: name,
            version: info["CFBundleShortVersionString"] as? String,
            executableName: info["CFBundleExecutable"] as? String,
            isAppStore: FileManager.default.fileExists(atPath: receipt),
            isApple: bundleID.lowercased().hasPrefix("com.apple."),
            // Moving a folder rewrites its own entry for "..", so the bundle must be writable, not just its folder.
            needsAdmin: access(bundle.path, W_OK) != 0 || access(parent, W_OK) != 0
        )
    }

    /// The names a leftover folder may carry instead of the bundle ID: the visible name, the executable and
    /// the bundle's file name. Lowercased, at least three characters.
    public var nameKeys: Set<String> {
        Set([name, executableName, url.deletingPathExtension().lastPathComponent].compactMap { $0?.lowercased() })
            .filter { $0.count >= 3 }
    }

    /// When Spotlight last saw the app opened. nil when it does not know.
    public static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Lists the apps in applications folders. Read-only.
///
/// Looks at the `.app` bundles of each folder and of its plain subfolders (`/Applications/Utilities`), never
/// following symlinks and never looking inside a bundle.
public struct AppInventory: Sendable {
    private let folders: [URL]

    public init(folders: [URL]) {
        self.folders = folders
    }

    /// The standard places: `/Applications` and `~/Applications`.
    public static func standardFolders(home: URL) -> [URL] {
        [URL(filePath: "/Applications", directoryHint: .isDirectory), home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    public func apps() -> [InstalledApp] {
        var seen = Set<String>()
        var found: [InstalledApp] = []
        func add(_ bundle: URL) {
            if let app = InstalledApp.read(at: bundle), seen.insert(bundle.path).inserted { found.append(app) }
        }
        for folder in folders {
            for entry in Self.folders(in: folder) {
                if entry.pathExtension.lowercased() == "app" {
                    add(entry)
                } else if Self.isInstallFolder(entry) {
                    Self.folders(in: entry).filter { $0.pathExtension.lowercased() == "app" }.forEach(add)
                }
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A plain folder that groups apps, like `Utilities`. Hidden folders, packages and the temporary
    /// "(A Document Being Saved By …)" folders updaters leave behind hold no installed apps.
    private static func isInstallFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return !name.hasPrefix(".") && !name.hasPrefix("(") && url.pathExtension.isEmpty
    }

    /// The real folders directly inside `folder`; symlinks and files are left out.
    private static func folders(in folder: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().compactMap { name in
            let url = folder.appending(path: name, directoryHint: .isDirectory)
            var status = stat()
            guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return url
        }
    }
}
