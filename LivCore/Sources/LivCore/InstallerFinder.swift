import Darwin
import Foundation

/// A folder to search for installers, and how deep.
public struct InstallerLocation: Sendable {
    public let url: URL
    /// 1 means the folder's own entries only.
    public let maxDepth: Int

    public init(url: URL, maxDepth: Int) {
        self.url = url
        self.maxDepth = max(maxDepth, 1)
    }
}

/// A disk image or installer package found on disk.
public struct InstallerFile: Sendable, Hashable {
    /// Package folders (`.pkg` bundles) carry a directory hint.
    public let url: URL
    /// The installed app this installer seems to be for.
    public let matchedApp: String?
    /// A disk image that is attached right now.
    public let isMounted: Bool
}

/// Finds `.dmg`, `.pkg`, `.mpkg`, `.iso` and `.xip` files. Read-only: it only lists folders.
///
/// It does not follow symlinks, enter hidden folders or packages, or look into whitelisted folders, and it
/// leaves out what the guard refuses.
public struct InstallerFinder: Sendable {
    public static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    /// Folders macOS treats as one item; an installer inside one is not the user's download.
    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "musiclibrary", "xcodeproj", "xcworkspace", "plugin",
    ]

    private let locations: [InstallerLocation]
    private let safetyGuard: SafetyGuard
    private let appKeys: [(key: String, name: String)]
    private let mountedImages: Set<String>

    /// - Parameters:
    ///   - installedAppNames: Names of the installed apps, to tell which installers were already used.
    ///   - mountedImages: Paths of the disk images attached right now.
    public init(locations: [InstallerLocation], guard safetyGuard: SafetyGuard, installedAppNames: [String], mountedImages: Set<String>) {
        self.locations = locations
        self.safetyGuard = safetyGuard
        // Longest first, so "Google Chrome" wins over a shorter name that is also a prefix.
        appKeys = installedAppNames.map { (Self.key($0), $0) }.filter { $0.key.count >= 3 }.sorted { $0.key.count > $1.key.count }
        self.mountedImages = Set(mountedImages.map { URL(filePath: $0).resolvingSymlinksInPath().path })
    }

    public func find() throws -> [InstallerFile] {
        var found: [InstallerFile] = []
        var seen = Set<String>()
        for location in locations {
            try walk(location.url, depth: 1, maxDepth: location.maxDepth, found: &found, seen: &seen)
        }
        return found
    }

    private func walk(_ folder: URL, depth: Int, maxDepth: Int, found: inout [InstallerFile], seen: inout Set<String>) throws {
        try Task.checkCancellation()
        guard !safetyGuard.isExcludedFromScan(folder),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = folder.appending(path: name).path
            var status = stat()
            guard lstat(path, &status) == 0 else { continue }
            let type = status.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { continue }
            let isFolder = type == S_IFDIR
            let url = URL(filePath: path, directoryHint: isFolder ? .isDirectory : .notDirectory)
            let fileExtension = url.pathExtension.lowercased()

            if Self.extensions.contains(fileExtension) {
                // Only packages may be folders; a folder called "x.dmg" is not an image.
                guard !isFolder || fileExtension == "pkg" || fileExtension == "mpkg" else { continue }
                guard (try? safetyGuard.validate(url)) != nil, seen.insert(path).inserted else { continue }
                found.append(InstallerFile(
                    url: url,
                    matchedApp: matchedApp(for: name),
                    isMounted: mountedImages.contains(url.resolvingSymlinksInPath().path)
                ))
            } else if isFolder, depth < maxDepth, !Self.packageExtensions.contains(fileExtension) {
                try walk(url, depth: depth + 1, maxDepth: maxDepth, found: &found, seen: &seen)
            }
        }
    }

    private func matchedApp(for fileName: String) -> String? {
        let fileKey = Self.key(fileName)
        return appKeys.first { fileKey.hasPrefix($0.key) }?.name
    }

    /// The letters a name starts with, lowercased: the extension, a Homebrew `<hash>--` prefix, and
    /// everything from the first digit on are dropped. "dbeaver-ce-26.2.2-macos.dmg" gives "dbeaverce".
    public static func key(_ name: String) -> String {
        var base = name
        let lowered = base.lowercased()
        if let dot = lowered.lastIndex(of: "."), extensions.contains(String(lowered[lowered.index(after: dot)...])) {
            base = String(base[..<dot])
        }
        if let range = base.range(of: "--"), base[..<range.lowerBound].allSatisfy(\.isHexDigit), base.distance(from: base.startIndex, to: range.lowerBound) >= 16 {
            base = String(base[range.upperBound...])
        }
        let beforeDigit = base.prefix { !$0.isNumber }
        return String(beforeDigit.filter(\.isLetter)).lowercased()
    }
}
