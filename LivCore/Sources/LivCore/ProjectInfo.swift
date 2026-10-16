import Darwin
import Foundation

/// A project that holds artifacts: the repository root if there is one, else the folder with the marker.
public struct ProjectInfo: Sendable, Hashable {
    public let url: URL
    public let isGitRepository: Bool
    /// The most recent edit: the later of the last commit and the newest file date. nil: could not be worked out.
    public let lastActivity: Date?

    public init(url: URL, isGitRepository: Bool, lastActivity: Date?) {
        self.url = url
        self.isGitRepository = isGitRepository
        self.lastActivity = lastActivity
    }
}

/// Works out which project an artifact belongs to and when the project was last edited. Read-only.
public enum ProjectInspector {
    /// Files read per project before the date is taken from what was seen so far.
    public static let defaultEntryLimit = 20_000

    /// Never read for dates: dependencies and git's own files change without anyone editing the project.
    private static let ignoredFolders: Set<String> = [".git", "node_modules"]
    private static let ignoredFiles: Set<String> = [".DS_Store"]

    /// The repository root holding the artifact (looking up to the folder the search started from), or the
    /// folder with the marker when there is no repository.
    public static func project(for match: ArtifactMatch) -> (url: URL, isGitRepository: Bool) {
        if let repository = gitRepositoryRoot(containing: match.url, stopAt: match.root) {
            return (repository, true)
        }
        return (match.markerFolder, false)
    }

    /// - Parameters:
    ///   - artifacts: The artifact folders of the project. Nothing inside them counts as an edit.
    ///   - git: nil when git is not available; the date then comes from the files alone.
    ///   - entryLimit: How many entries to look at before stopping.
    public static func info(
        for project: URL,
        isGitRepository: Bool,
        artifacts: [URL],
        git: (any GitInspecting)?,
        entryLimit: Int = defaultEntryLimit
    ) async throws -> ProjectInfo {
        var dates: [Date] = []
        if isGitRepository, let git {
            do {
                if let commit = try await git.lastCommitDate(touching: project, in: project) { dates.append(commit) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The files still tell when the project was edited.
            }
        }
        if let newest = try newestFileDate(in: project, skipping: artifacts, entryLimit: entryLimit) { dates.append(newest) }
        return ProjectInfo(url: project, isGitRepository: isGitRepository, lastActivity: dates.max())
    }

    /// The newest modification date among regular files below `folder`, breadth first, without entering
    /// symlinks, git's folder, installed dependencies or `skipping`.
    static func newestFileDate(in folder: URL, skipping artifacts: [URL], entryLimit: Int) throws -> Date? {
        let skipped = Set(artifacts.map { $0.standardizedFileURL.path })
        var newest: timespec?
        var seen = 0
        var queue = [folder.standardizedFileURL.path]
        var next = 0

        while next < queue.count, seen < entryLimit {
            try Task.checkCancellation()
            let path = queue[next]
            next += 1
            guard let dir = opendir(path) else { continue }
            defer { closedir(dir) }
            let descriptor = dirfd(dir)

            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                seen += 1
                if seen > entryLimit { break }
                var status = stat()
                guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    let childPath = path + "/" + name
                    if !ignoredFolders.contains(name), !skipped.contains(childPath) { queue.append(childPath) }
                case S_IFREG:
                    guard !ignoredFiles.contains(name) else { continue }
                    let modified = status.st_mtimespec
                    if newest == nil || (modified.tv_sec, modified.tv_nsec) > (newest!.tv_sec, newest!.tv_nsec) { newest = modified }
                default:
                    break
                }
            }
        }
        return newest.map { Date(timeIntervalSince1970: TimeInterval($0.tv_sec)) }
    }
}
