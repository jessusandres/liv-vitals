import Darwin
import Foundation

/// A folder or file that a rule found.
public struct RuleMatch: Sendable {
    public let rule: CleanupRule
    /// Built with a directory hint, so a later check can tell a folder from a file.
    public let url: URL

    public init(rule: CleanupRule, url: URL) {
        self.rule = rule
        self.url = url
    }
}

/// Finds what the rules describe on this Mac. Read-only: it only lists folders and reads their dates.
public struct CleanupRuleEngine: Sendable {
    private let home: URL
    private let fullDiskAccess: Bool
    private let safetyGuard: SafetyGuard

    public init(home: URL, fullDiskAccess: Bool, guard safetyGuard: SafetyGuard) {
        self.home = home
        self.fullDiskAccess = fullDiskAccess
        self.safetyGuard = safetyGuard
    }

    /// Expands the rules, in order, into the items that exist.
    ///
    /// - Rules that need Full Disk Access are not evaluated without it, so their folders are never even
    ///   opened (and macOS has no reason to ask the user anything). They come back in `skippedRules`.
    /// - Symlinks are never followed: a link can be an item itself, but nothing is looked up through it.
    /// - A match the guard refuses (protected, whitelisted, outside the rules' folders) is dropped.
    /// - When two rules reach the same folder the earlier one wins. A later rule also steps around a folder
    ///   that holds a match of an earlier rule, so `Library/Caches/*` does not swallow `Google` when Chrome's
    ///   own cache folders inside it have a rule.
    /// - Inside one rule, a folder that contains another match replaces it: the outer one wins.
    public func matches(for rules: [CleanupRule]) -> (matches: [RuleMatch], skippedRules: [CleanupRule]) {
        var found: [(match: RuleMatch, key: PathMath.Components)] = []
        var skipped: [CleanupRule] = []
        let now = Date()

        for rule in rules {
            if rule.requiresFullDiskAccess && !fullDiskAccess {
                skipped.append(rule)
                continue
            }
            for pattern in rule.patterns {
                for url in expand(pattern) where isWanted(url, by: rule, now: now) {
                    let key = PathMath.components(of: url)
                    if found.contains(where: { $0.match.rule.id != rule.id && PathMath.isStrictlyInside($0.key, of: key) }) { continue }
                    if found.contains(where: { PathMath.isSameOrInside(key, of: $0.key) }) { continue }
                    found.removeAll { $0.match.rule.id == rule.id && PathMath.isStrictlyInside($0.key, of: key) }
                    found.append((RuleMatch(rule: rule, url: url), key))
                }
            }
        }
        return (found.map(\.match), skipped)
    }

    /// The folders `SafetyGuard` should treat as allowed roots for these rules: for each pattern, the deepest
    /// folder before its first `*`, or the parent of the target when there is no `*`. Matches are always
    /// strictly inside one of them, never the root itself.
    public static func roots(for rules: [CleanupRule], home: URL) -> [URL] {
        var seen = Set<String>()
        var roots: [URL] = []
        for pattern in rules.flatMap(\.patterns) {
            let parts = pattern.split(separator: "/").map(String.init)
            let literal = parts.prefix { $0 != "*" }
            let rootParts = literal.count == parts.count ? Array(literal.dropLast()) : Array(literal)
            let root = rootParts.reduce(home) { $0.appending(path: $1, directoryHint: .isDirectory) }
            if seen.insert(root.standardizedFileURL.path).inserted { roots.append(root) }
        }
        return roots
    }

    // MARK: - Expansion

    private func expand(_ pattern: String) -> [URL] {
        let parts = pattern.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [] }
        var results: [URL] = []

        func walk(_ base: URL, _ index: Int) {
            let part = parts[index]
            let names: [String]
            if part == "*" {
                guard let listing = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
                names = listing.sorted()
            } else {
                names = [part]
            }
            for name in names {
                let path = base.path + "/" + name
                var status = stat()
                guard lstat(path, &status) == 0 else { continue }
                let isFolder = (status.st_mode & S_IFMT) == S_IFDIR
                let url = URL(filePath: path, directoryHint: isFolder ? .isDirectory : .notDirectory)
                if index == parts.count - 1 {
                    results.append(url)
                } else if isFolder {
                    // A real folder only: a symlink reports as not a folder, so it is never entered.
                    walk(url, index + 1)
                }
            }
        }
        walk(home, 0)
        return results
    }

    private func isWanted(_ url: URL, by rule: CleanupRule, now: Date) -> Bool {
        let name = url.lastPathComponent
        if rule.excluding.contains(where: { fnmatch($0, name, FNM_CASEFOLD) == 0 }) { return false }
        if let minAge = rule.minAge {
            var status = stat()
            guard lstat(url.path, &status) == 0 else { return false }
            let modified = Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
            let seconds = Double(minAge.components.seconds)
            if now.timeIntervalSince(modified) < seconds { return false }
        }
        return (try? safetyGuard.validate(url)) != nil
    }
}
