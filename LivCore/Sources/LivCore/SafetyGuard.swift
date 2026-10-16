import Foundation

/// Why a path may not be acted on.
public enum SafetyViolation: Error, Equatable, Sendable, CustomStringConvertible {
    case notAbsolute(String)
    /// Matches or is inside a protected path.
    case protected(URL)
    /// Matches, is inside, or contains an entry of the user whitelist.
    case whitelisted(URL)
    case outsideAllowedRoots(URL)
    /// The allowed root itself can never be a target.
    case isAllowedRoot(URL)
    /// The target is "/", the home folder, or an ancestor of home or of a protected path.
    case containsProtected(URL)
    /// The scan marked the item as not removable for now, e.g. it needs administrator rights.
    case blocked(URL, reason: String)

    public var description: String {
        switch self {
        case .notAbsolute(let path): "Path is not absolute: \(path)"
        case .protected(let url): "Protected location: \(url.path)"
        case .whitelisted(let url): "Excluded by the whitelist: \(url.path)"
        case .outsideAllowedRoots(let url): "Outside the folders this cleanup may touch: \(url.path)"
        case .isAllowedRoot(let url): "The cleanup folder itself cannot be removed: \(url.path)"
        case .containsProtected(let url): "Contains protected locations: \(url.path)"
        case .blocked(_, let reason): reason
        }
    }
}

/// Decides which paths a cleanup may act on. Protections always win over allowed roots.
public struct SafetyGuard: Sendable {
    /// Lets files with some extensions, directly inside one protected folder, be acted on: Installers may
    /// remove `~/Desktop/Foo.dmg` while the rest of the Desktop stays protected.
    public struct FileException: Sendable {
        public let folder: URL
        /// Lowercased, without the dot.
        public let extensions: Set<String>

        public init(folder: URL, extensions: Set<String>) {
            self.folder = folder
            self.extensions = Set(extensions.map { $0.lowercased() })
        }
    }

    private let homeKeys: [PathMath.Components]
    private let rootKeys: [PathMath.Components]
    private let whitelistKeys: [PathMath.Components]
    private let protectedKeys: [PathMath.Components]
    private let exceptionKeys: [(folder: PathMath.Components, extensions: Set<String>)]

    /// - Parameters:
    ///   - home: The user's home folder. It and its ancestors can never be targets.
    ///   - allowedRoots: Folders whose contents may be acted on; the folders themselves may not.
    ///   - whitelist: User folders to never scan or remove, including everything inside them.
    ///   - protectedPaths: Absolute denials. `nil` uses `defaultProtectedPaths(home:)`.
    ///   - exceptions: Files a protection does not cover. The whitelist and the allowed roots still apply.
    public init(home: URL, allowedRoots: [URL], whitelist: [URL] = [], protectedPaths: [URL]? = nil, exceptions: [FileException] = []) {
        homeKeys = PathMath.variants(of: home)
        rootKeys = allowedRoots.map { PathMath.components(of: $0.resolvingSymlinksInPath()) }
        whitelistKeys = whitelist.flatMap(PathMath.variants(of:))
        protectedKeys = (protectedPaths ?? Self.defaultProtectedPaths(home: home)).flatMap(PathMath.variants(of:))
        exceptionKeys = exceptions.flatMap { exception in
            PathMath.variants(of: exception.folder).map { ($0, exception.extensions) }
        }
    }

    /// Default absolute denials for `home`; used when `protectedPaths` is nil.
    ///
    /// `/Applications` is deliberately absent: the app-uninstall stage allows it as an explicit root.
    public static func defaultProtectedPaths(home: URL) -> [URL] {
        let system = [
            "/System", "/bin", "/sbin", "/usr", "/private/var/db", "/Library", "/Volumes",
        ].map { URL(filePath: $0) }
        // Personal data and credentials; cleanup has no business here.
        let user = [
            "Library/Keychains", "Library/Mobile Documents", "Library/Mail", "Library/Messages",
            "Library/Calendars", "Library/Application Support/AddressBook",
            "Library/Group Containers/group.com.apple.notes", ".ssh", ".gnupg", "Documents", "Desktop",
        ].map { home.appending(path: $0) }
        return system + user
    }

    /// Returns the normalized URL when the path may be acted on, or throws why not.
    ///
    /// The result has the symlinks of its parent folders resolved; act on it, not on the input.
    /// A folder that contains a whitelisted entry is refused too, since removing it would remove the entry.
    public func validate(_ url: URL) throws(SafetyViolation) -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw .notAbsolute(url.path) }
        let target = PathMath.canonical(url)
        let key = PathMath.components(of: target)

        let containsHomeOrProtected = key.isEmpty
            || homeKeys.contains { PathMath.isSameOrInside($0, of: key) }
            || protectedKeys.contains { PathMath.isStrictlyInside($0, of: key) }
        if containsHomeOrProtected { throw .containsProtected(target) }
        if protectedKeys.contains(where: { PathMath.isSameOrInside(key, of: $0) }), !isException(key) { throw .protected(target) }
        if whitelistKeys.contains(where: { PathMath.isSameOrInside(key, of: $0) || PathMath.isStrictlyInside($0, of: key) }) {
            throw .whitelisted(target)
        }
        if rootKeys.contains(key) { throw .isAllowedRoot(target) }
        if !rootKeys.contains(where: { PathMath.isStrictlyInside(key, of: $0) }) { throw .outsideAllowedRoots(target) }
        return target
    }

    /// A file directly inside an exception folder, with one of its extensions. Nothing deeper qualifies.
    private func isException(_ key: PathMath.Components) -> Bool {
        guard let last = key.last, let dot = last.lastIndex(of: "."), dot != last.startIndex else { return false }
        let fileExtension = String(last[last.index(after: dot)...])
        let parent = Array(key.dropLast())
        return exceptionKeys.contains { $0.folder == parent && $0.extensions.contains(fileExtension) }
    }

    /// True when a scanner must not descend into `url`. Only whitelist entries qualify: protected
    /// paths may still be measured, they just cannot be acted on.
    public func isExcludedFromScan(_ url: URL) -> Bool {
        isExcludedFromScan(path: url.path)
    }

    func isExcludedFromScan(path: String) -> Bool {
        guard !whitelistKeys.isEmpty else { return false }
        let key = PathMath.components(ofPath: path)
        return whitelistKeys.contains { PathMath.isSameOrInside(key, of: $0) }
    }
}
