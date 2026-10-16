import Darwin
import Foundation

/// A launch agent or daemon: a program macOS starts for the user or for everyone.
public struct LaunchItem: Sendable, Hashable, Identifiable {
    public enum Scope: Sendable, Hashable {
        case user, systemAgent, systemDaemon
    }

    public var id: URL { url }

    public let url: URL
    public let scope: Scope
    public let label: String
    public let program: String?
    /// False when the program it runs is gone, which usually means its app was removed.
    public let programExists: Bool
    /// The installed app it belongs to, found by bundle ID or because its program is inside the bundle.
    public let owner: InstalledApp?

    public init(url: URL, scope: Scope, label: String, program: String?, programExists: Bool, owner: InstalledApp?) {
        self.url = url
        self.scope = scope
        self.label = label
        self.program = program
        self.programExists = programExists
        self.owner = owner
    }
}

/// Lists what starts by itself on this Mac: `~/Library/LaunchAgents`, `/Library/LaunchAgents` and
/// `/Library/LaunchDaemons`. Read-only. Apple's own (`com.apple.*`) are left out.
public struct LaunchItemInventory: Sendable {
    private let home: URL
    private let systemLibrary: URL
    private let installed: [InstalledApp]

    public init(home: URL, systemLibrary: URL = URL(filePath: "/Library", directoryHint: .isDirectory), installed: [InstalledApp]) {
        self.home = home
        self.systemLibrary = systemLibrary
        self.installed = installed
    }

    public func items() -> [LaunchItem] {
        let byID = installed.sorted { $0.bundleID.count > $1.bundleID.count }
        let places: [(URL, LaunchItem.Scope)] = [
            (home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory), .user),
            (systemLibrary.appending(path: "LaunchAgents", directoryHint: .isDirectory), .systemAgent),
            (systemLibrary.appending(path: "LaunchDaemons", directoryHint: .isDirectory), .systemDaemon),
        ]

        var found: [LaunchItem] = []
        for (folder, scope) in places {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where name.lowercased().hasSuffix(".plist") && !name.hasPrefix(".") {
                let url = folder.appending(path: name, directoryHint: .notDirectory)
                var status = stat()
                guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { continue }
                guard let job = LaunchJob.read(at: url) else { continue }

                let fileKey = String(name.dropLast(".plist".count))
                let label = job.label ?? fileKey
                if label.lowercased().hasPrefix("com.apple.") || fileKey.lowercased().hasPrefix("com.apple.") { continue }

                var owner = LeftoverFinder.owner(of: label, among: byID) ?? LeftoverFinder.owner(of: fileKey, among: byID)
                if owner == nil, let program = job.program {
                    owner = installed.first { program.hasPrefix($0.url.path.hasSuffix("/") ? $0.url.path : $0.url.path + "/") }
                }
                found.append(LaunchItem(
                    url: url,
                    scope: scope,
                    label: label,
                    program: job.program,
                    programExists: job.program.map { FileManager.default.fileExists(atPath: $0) } ?? true,
                    owner: owner
                ))
            }
        }
        return found.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}
