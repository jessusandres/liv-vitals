import Darwin
import Foundation

/// A place in `~/Library` (or `/Library`) where apps leave files, and how an entry there names its app.
public enum LeftoverLocation: String, CaseIterable, Sendable {
    case applicationSupport, caches, httpStorages, webKit, logs, savedState, preferences, byHostPreferences
    case cookies, applicationScripts, containers, groupContainers, launchAgents
    case systemLaunchAgents, systemLaunchDaemons, privilegedHelpers

    /// Relative to `~/Library`, or to `/Library` for the system ones.
    var relativePath: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .httpStorages: "HTTPStorages"
        case .webKit: "WebKit"
        case .logs: "Logs"
        case .savedState: "Saved Application State"
        case .preferences: "Preferences"
        case .byHostPreferences: "Preferences/ByHost"
        case .cookies: "Cookies"
        case .applicationScripts: "Application Scripts"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .launchAgents, .systemLaunchAgents: "LaunchAgents"
        case .systemLaunchDaemons: "LaunchDaemons"
        case .privilegedHelpers: "PrivilegedHelperTools"
        }
    }

    /// Lives in `/Library`: removing it needs administrator rights.
    public var isSystem: Bool { [.systemLaunchAgents, .systemLaunchDaemons, .privilegedHelpers].contains(self) }

    /// macOS keeps these behind Full Disk Access; listing them without it shows a privacy prompt.
    var needsFullDiskAccess: Bool { self == .containers || self == .groupContainers }

    /// Folders named after the app rather than its bundle ID are common only here.
    var matchesByName: Bool { self == .applicationSupport || self == .caches || self == .logs }

    /// Launch jobs say which program they run, which ties them to an app even under another name.
    var isLaunchJob: Bool { self == .launchAgents || self == .systemLaunchAgents || self == .systemLaunchDaemons }

    /// Places where a leftover of an app that is gone can be recognized by its name alone.
    var findsOrphans: Bool {
        [.applicationSupport, .caches, .httpStorages, .webKit, .savedState, .preferences, .containers, .launchAgents].contains(self)
    }

    /// The bundle-ID-like part of an entry's name, or nil when the entry does not have this place's shape.
    func key(for name: String) -> String? {
        func dropping(_ suffix: String) -> String? {
            name.lowercased().hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : nil
        }
        switch self {
        case .applicationSupport, .caches, .webKit, .logs, .applicationScripts, .containers, .privilegedHelpers:
            return name
        case .httpStorages: return dropping(".binarycookies") ?? name
        case .savedState: return dropping(".savedstate")
        case .preferences, .launchAgents, .systemLaunchAgents, .systemLaunchDaemons: return dropping(".plist")
        case .cookies: return dropping(".binarycookies")
        case .byHostPreferences:
            // com.example.App.<host UUID>.plist
            guard let base = dropping(".plist"), let dot = base.lastIndex(of: ".") else { return nil }
            return String(base[..<dot])
        case .groupContainers:
            // group.com.example.App, or <TEAMID>.com.example.App
            if name.lowercased().hasPrefix("group.") { return String(name.dropFirst("group.".count)) }
            let parts = name.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) else { return nil }
            return String(parts[1])
        }
    }

    /// Group containers may be shared by several apps of the same developer.
    public var isShared: Bool { self == .groupContainers }
}

/// A file or folder an app left in a Library folder.
public struct Leftover: Sendable, Hashable {
    /// Folders carry a directory hint.
    public let url: URL
    public let location: LeftoverLocation
    /// The bundle-ID-like name the entry carries, for orphans; nil when it was matched another way.
    public let key: String?

    public var needsAdmin: Bool { location.isSystem }
}

/// Finds the files apps leave in `~/Library` and `/Library`. Read-only: it lists folders and reads launch
/// job plists.
///
/// An entry belongs to an app only when its name identifies the app: its bundle ID, its bundle ID followed by
/// `.something`, or (in a few places) the app's name when no other installed app shares it. When the bundle ID
/// of another installed app matches more closely, the entry is that app's.
public struct LeftoverFinder: Sendable {
    private let home: URL
    private let systemLibrary: URL
    private let fullDiskAccess: Bool
    private let installed: [InstalledApp]
    private let safetyGuard: SafetyGuard

    /// - Parameters:
    ///   - installed: Every app on the Mac, Apple's included, so that nothing of theirs is ever taken for
    ///     another app's leftover or an orphan.
    ///   - guard: Entries it refuses are dropped, except the `/Library` ones, which come back as needing admin.
    public init(
        home: URL,
        systemLibrary: URL = URL(filePath: "/Library", directoryHint: .isDirectory),
        fullDiskAccess: Bool,
        installed: [InstalledApp],
        guard safetyGuard: SafetyGuard
    ) {
        self.home = home
        self.systemLibrary = systemLibrary
        self.fullDiskAccess = fullDiskAccess
        self.installed = installed
        self.safetyGuard = safetyGuard
    }

    /// The `~/Library` folders a cleanup of leftovers reaches into: the allowed roots of its guard.
    public static func userRoots(home: URL) -> [URL] {
        LeftoverLocation.allCases.filter { !$0.isSystem }.map {
            home.appending(path: "Library/\($0.relativePath)", directoryHint: .isDirectory)
        }
    }

    public struct Result: Sendable {
        /// Leftovers by the bundle URL of their app.
        public var byApp: [URL: [Leftover]]
        /// Leftovers of apps that are no longer installed.
        public var orphans: [Leftover]
    }

    /// - Parameter isKnownBundleID: Whether macOS knows an app with that bundle ID anywhere (LaunchServices).
    ///   An entry named after a known app is never an orphan.
    public func find(isKnownBundleID: (String) -> Bool = { _ in false }) -> Result {
        let byID = installed.sorted { $0.bundleID.count > $1.bundleID.count }
        var byName: [String: [InstalledApp]] = [:]
        for app in installed {
            for key in app.nameKeys { byName[key, default: []].append(app) }
        }

        let vendors = Set(installed.compactMap { Self.vendor(of: $0.bundleID) })
        var result = Result(byApp: [:], orphans: [])
        for location in LeftoverLocation.allCases {
            if location.needsFullDiskAccess && !fullDiskAccess { continue }
            let folder = (location.isSystem ? systemLibrary : home.appending(path: "Library"))
                .appending(path: location.relativePath, directoryHint: .isDirectory)
            for (name, url) in Self.entries(of: folder) {
                guard let key = location.key(for: name) else { continue }
                let program = location.isLaunchJob ? LaunchJob.read(at: url)?.program : nil

                var owner = Self.owner(of: key, among: byID)
                if owner == nil, let program {
                    owner = installed.first { program.hasPrefix($0.url.path.hasSuffix("/") ? $0.url.path : $0.url.path + "/") }
                }
                if owner == nil, location.matchesByName, let apps = byName[key.lowercased()], apps.count == 1 {
                    owner = apps[0]
                }

                if let owner {
                    guard location.isSystem || (try? safetyGuard.validate(url)) != nil else { continue }
                    result.byApp[owner.url, default: []].append(Leftover(url: url, location: location, key: nil))
                } else if location.findsOrphans,
                          Self.isOrphan(key: key, program: program, location: location, vendors: vendors, isKnown: isKnownBundleID),
                          (try? safetyGuard.validate(url)) != nil {
                    result.orphans.append(Leftover(url: url, location: location, key: key))
                }
            }
        }
        return result
    }

    // MARK: - Matching

    /// The installed app whose bundle ID is `key` or a dotted prefix of it, preferring the longest bundle ID.
    static func owner(of key: String, among appsByLongestID: [InstalledApp]) -> InstalledApp? {
        let lowered = key.lowercased()
        return appsByLongestID.first {
            let id = $0.bundleID.lowercased()
            return lowered == id || lowered.hasPrefix(id + ".")
        }
    }

    /// Reverse-DNS names with at least three parts, e.g. `com.example.App`.
    static func looksLikeBundleID(_ key: String) -> Bool {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    /// The developer part of a bundle ID: `com.raycast` for `com.raycast.macos`.
    static func vendor(of bundleID: String) -> String? {
        let parts = bundleID.lowercased().split(separator: ".")
        return parts.count >= 2 ? parts.prefix(2).joined(separator: ".") : nil
    }

    private static func isOrphan(key: String, program: String?, location: LeftoverLocation, vendors: Set<String>, isKnown: (String) -> Bool) -> Bool {
        guard looksLikeBundleID(key), !key.lowercased().hasPrefix("com.apple.") else { return false }
        // `com.raycast.shared` is data a still-installed Raycast shares; a developer with an app installed
        // keeps all its files.
        if let vendor = vendor(of: key), vendors.contains(vendor) { return false }
        // A launch agent whose program is still there belongs to something installed outside an app folder.
        if location == .launchAgents, let program, FileManager.default.fileExists(atPath: program) { return false }
        // com.example.App.helper is known if com.example.App is.
        var parts = key.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            if isKnown(parts.joined(separator: ".")) { return false }
            parts.removeLast()
        }
        return true
    }

    // MARK: - Reading

    /// The entries of `folder` with their URLs (folders with a directory hint). Hidden entries are left out.
    private static func entries(of folder: URL) -> [(name: String, url: URL)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().filter { !$0.hasPrefix(".") }.compactMap { name in
            var status = stat()
            let path = folder.appending(path: name).path
            guard lstat(path, &status) == 0 else { return nil }
            let isFolder = (status.st_mode & S_IFMT) == S_IFDIR
            return (name, URL(filePath: path, directoryHint: isFolder ? .isDirectory : .notDirectory))
        }
    }
}
