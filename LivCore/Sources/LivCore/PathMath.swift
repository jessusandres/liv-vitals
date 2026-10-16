import Foundation

/// Path comparison used by `SafetyGuard`. Paths are compared by components, never by string prefix,
/// and without regard to case or Unicode normalization, as on a default APFS volume.
enum PathMath {
    /// The lowercased, normalized components of a path, without the leading "/". "/" itself is `[]`.
    typealias Components = [String]

    /// Lexically standardized (`.`, `..` and repeated slashes removed) with the symlinks of every
    /// parent folder resolved. The last component is kept as is, so a symlink is judged as the link itself.
    static func canonical(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let last = standardized.lastPathComponent
        guard !last.isEmpty, last != "/" else { return standardized }
        return standardized.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: last)
    }

    /// Every spelling a protected path or a user entry can take: lexical, parent-resolved and fully resolved.
    static func variants(of url: URL) -> [Components] {
        let spellings = [url.standardizedFileURL, canonical(url), url.resolvingSymlinksInPath()]
        var seen = Set<Components>()
        return spellings.map(components(of:)).filter { seen.insert($0).inserted }
    }

    static func components(of url: URL) -> Components {
        components(ofPath: url.standardizedFileURL.path)
    }

    static func components(ofPath path: String) -> Components {
        path.split(separator: "/").map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }

    /// True when `path` is the same as `other` or lies inside it.
    static func isSameOrInside(_ path: Components, of other: Components) -> Bool {
        path.count >= other.count && path.starts(with: other)
    }

    /// True when `path` lies inside `other` but is not `other` itself.
    static func isStrictlyInside(_ path: Components, of other: Components) -> Bool {
        path.count > other.count && path.starts(with: other)
    }
}
