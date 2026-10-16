import Darwin
import Foundation

/// A build or dependency folder that sits next to the file proving it can be rebuilt.
public struct ArtifactMatch: Sendable, Hashable {
    public let kind: ArtifactKind.ID
    /// The artifact folder, built with a directory hint.
    public let url: URL
    /// The folder with the marker: the artifact's parent.
    public let markerFolder: URL
    /// The project folder the walk started from, which contains the artifact.
    public let root: URL

    public init(kind: ArtifactKind.ID, url: URL, markerFolder: URL, root: URL) {
        self.kind = kind
        self.url = url
        self.markerFolder = markerFolder
        self.root = root
    }
}

/// Finds artifacts below the configured project folders. Read-only: it only lists folders.
///
/// A folder is an artifact only when a marker of its kind is in the same parent folder, so a loose `dist`
/// is never offered. The walk does not enter artifacts it found, `.git`, symlinks, packages, other volumes
/// or whitelisted folders.
public struct ProjectArtifactFinder: Sendable {
    /// Bundles and packages are single items for macOS, and nothing in them is a project.
    private static let packageExtensions: Set<String> = [
        "app", "xcodeproj", "xcworkspace", "photoslibrary", "framework", "xcframework", "bundle", "plugin",
        "appex", "playground", "xcassets", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
    ]

    /// Never entered when no marker proves them an artifact: an installed dependency tree holds thousands of
    /// folders, none of them a project of the user.
    private static let neverEntered: Set<String> = ["node_modules", ".venv"]

    private let roots: [URL]
    private let safetyGuard: SafetyGuard
    private let kinds: [ArtifactKind]
    private let maxDepth: Int

    /// - Parameters:
    ///   - roots: The project folders to search.
    ///   - guard: Whitelisted and protected places are not searched, and matches it refuses are dropped.
    ///   - maxDepth: How many levels below a root an artifact may be, counting the artifact itself.
    public init(roots: [URL], guard safetyGuard: SafetyGuard, kinds: [ArtifactKind] = ArtifactKind.builtIn, maxDepth: Int = 6) {
        self.roots = roots
        self.safetyGuard = safetyGuard
        self.kinds = kinds
        self.maxDepth = max(maxDepth, 1)
    }

    /// - Parameter progress: Called with each folder as it is listed.
    public func find(progress: (@Sendable (String) -> Void)? = nil) throws -> (matches: [ArtifactMatch], issues: [ScanIssue]) {
        var issues: [ScanIssue] = []
        var matches: [ArtifactMatch] = []
        for root in usableRoots(issues: &issues) {
            try walk(root, matches: &matches, issues: &issues, progress: progress)
        }
        return (matches, issues)
    }

    // MARK: - Roots

    /// The roots that can be searched, with symlinks resolved and roots inside another root dropped. The ones
    /// that cannot be searched come back as issues with the reason.
    private func usableRoots(issues: inout [ScanIssue]) -> [URL] {
        var usable: [(url: URL, key: PathMath.Components)] = []
        for root in roots {
            let resolved = root.resolvingSymlinksInPath()
            var status = stat()
            guard lstat(resolved.path, &status) == 0 else {
                let reason = errno == ENOENT ? "That folder does not exist." : ScanError.message(for: errno)
                issues.append(ScanIssue(url: root, reason: reason))
                continue
            }
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                issues.append(ScanIssue(url: root, reason: "That is not a folder."))
                continue
            }
            if let violation = protection(of: resolved) {
                issues.append(ScanIssue(url: root, reason: violation.description))
                continue
            }
            if safetyGuard.isExcludedFromScan(resolved) {
                issues.append(ScanIssue(url: root, reason: "Excluded by the whitelist: \(resolved.path)"))
                continue
            }
            usable.append((resolved, PathMath.components(of: resolved)))
        }

        // Shallowest first, so a root inside an earlier one is the one dropped.
        var kept: [(url: URL, key: PathMath.Components)] = []
        for candidate in usable.sorted(by: { $0.key.count < $1.key.count }) {
            if kept.contains(where: { PathMath.isSameOrInside(candidate.key, of: $0.key) }) { continue }
            kept.append(candidate)
        }
        return kept.map(\.url)
    }

    /// Why a root can never be searched: it is protected, or holds something protected. The other refusals
    /// of the guard do not apply to a root, which is allowed by definition.
    private func protection(of root: URL) -> SafetyViolation? {
        do {
            _ = try safetyGuard.validate(root)
            return nil
        } catch {
            switch error {
            case .protected, .containsProtected, .notAbsolute: return error
            default: return nil
            }
        }
    }

    // MARK: - Walking

    private struct Entry {
        let name: String
        let isDirectory: Bool
    }

    private func walk(
        _ root: URL,
        matches: inout [ArtifactMatch],
        issues: inout [ScanIssue],
        progress: (@Sendable (String) -> Void)?
    ) throws {
        var rootStatus = stat()
        guard lstat(root.path, &rootStatus) == 0 else { return }
        let rootDevice = rootStatus.st_dev

        // Breadth first; a folder is listed only when it is above `maxDepth`, so an artifact is at most that deep.
        var queue: [(path: String, depth: Int)] = [(root.path, 0)]
        var next = 0
        while next < queue.count {
            try Task.checkCancellation()
            let (path, depth) = queue[next]
            next += 1
            progress?(path)

            let listing = Self.list(path)
            if let failure = listing.failure {
                issues.append(ScanIssue(url: URL(filePath: path, directoryHint: .isDirectory), reason: ScanError.message(for: failure)))
            }
            let names = listing.entries.map(\.name)

            for entry in listing.entries where entry.isDirectory {
                let name = entry.name
                if name == ".git" { continue }
                if Self.packageExtensions.contains((name as NSString).pathExtension) { continue }
                let childPath = path == "/" ? "/" + name : path + "/" + name
                if safetyGuard.isExcludedFromScan(path: childPath) { continue }

                if let kind = kinds.first(where: {
                    $0.folderNames.contains(name) && $0.isProven(by: names) && Self.holds($0.requiredInside, at: childPath)
                }) {
                    let url = URL(filePath: childPath, directoryHint: .isDirectory)
                    if (try? safetyGuard.validate(url)) != nil {
                        matches.append(ArtifactMatch(
                            kind: kind.id,
                            url: url,
                            markerFolder: URL(filePath: path, directoryHint: .isDirectory),
                            root: root
                        ))
                    }
                    continue
                }

                if Self.neverEntered.contains(name) { continue }
                guard depth + 1 < maxDepth else { continue }
                var status = stat()
                guard lstat(childPath, &status) == 0, status.st_dev == rootDevice else { continue }
                queue.append((childPath, depth + 1))
            }
        }
    }

    /// True when no file is required, or the folder at `path` holds it (one `lstat`).
    private static func holds(_ required: String?, at path: String) -> Bool {
        guard let required else { return true }
        var status = stat()
        return lstat(path + "/" + required, &status) == 0
    }

    /// The entries of a folder, with whether each is a real folder (a symlink to one is not).
    private static func list(_ path: String) -> (entries: [Entry], failure: Int32?) {
        guard let dir = opendir(path) else { return ([], errno) }
        defer { closedir(dir) }
        let descriptor = dirfd(dir)
        var entries: [Entry] = []

        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let isDirectory: Bool
            switch Int32(entry.pointee.d_type) {
            case Int32(DT_DIR):
                isDirectory = true
            case Int32(DT_UNKNOWN):
                var status = stat()
                isDirectory = fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
            default:
                isDirectory = false
            }
            entries.append(Entry(name: name, isDirectory: isDirectory))
        }
        return (entries, nil)
    }
}
