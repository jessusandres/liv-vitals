import Darwin
import Foundation
import os

public struct ScanProgress: Sendable {
    public let filesVisited: Int
    public let bytesCounted: ByteSize
    public let currentPath: String

    public init(filesVisited: Int, bytesCounted: ByteSize, currentPath: String) {
        self.filesVisited = filesVisited
        self.bytesCounted = bytesCounted
        self.currentPath = currentPath
    }
}

public struct ScanIssue: Sendable, Hashable, Codable {
    public let url: URL
    /// English, e.g. "Permission denied".
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct Measurement: Sendable {
    public let size: ByteSize
    /// Files, symlinks and other non-folder entries visited.
    public let fileCount: Int
    public let issues: [ScanIssue]
    /// Part of `size` that is files with other names outside what was measured (hard links). Moving them
    /// to the Trash frees little, because the other names keep the data alive. `size` already counts them.
    public let sharedSize: ByteSize

    public init(size: ByteSize, fileCount: Int, issues: [ScanIssue], sharedSize: ByteSize = .zero) {
        self.size = size
        self.fileCount = fileCount
        self.issues = issues
        self.sharedSize = sharedSize
    }
}

/// The scan root itself could not be measured.
public enum ScanError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(URL)
    case unreadable(URL, reason: String)

    public var description: String {
        switch self {
        case .notFound(let url): "Nothing exists at \(url.path)"
        case .unreadable(let url, let reason): "Cannot read \(url.path): \(reason)"
        }
    }

    var reason: String {
        switch self {
        case .notFound: Self.message(for: ENOENT)
        case .unreadable(_, let reason): reason
        }
    }

    static func message(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Reads the disk without changing it: sizes of files and folders, and folder trees for Space Lens.
///
/// Sizes are allocated space (`st_blocks`), like `du`. Symlinks are never followed, hard links count
/// once, and other volumes are not entered. The walk runs on the calling task's thread and checks for
/// cancellation as it goes.
public struct FileScanner: Sendable {
    private let safetyGuard: SafetyGuard?
    private let progressInterval: Duration

    /// - Parameter guard: When set, whitelisted folders are skipped entirely.
    public init(guard safetyGuard: SafetyGuard? = nil, progressInterval: Duration = .milliseconds(250)) {
        self.safetyGuard = safetyGuard
        self.progressInterval = progressInterval
    }

    /// Allocated size of a file or folder tree. Never follows symlinks; hard links count once.
    public func measure(_ url: URL, progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> Measurement {
        let run = ScanRun(progress: progress, interval: progressInterval)
        let walked = try walk(url, run: run, depth: 0)
        run.finish(path: url.path)
        return walked.measurement
    }

    /// Sizes of many independent paths (cleanup rules). Hard links are deduplicated across the whole call.
    ///
    /// `rootFinished` reports each path as it completes, so a caller can show a real fraction.
    ///
    /// The paths must not contain one another. A path that does not exist or cannot be read gets a
    /// zero-size measurement carrying the reason in its `issues`, so one missing app cache does not
    /// fail the whole batch.
    public func measureAll(
        _ urls: [URL],
        maxConcurrency: Int = 4,
        progress: (@Sendable (ScanProgress) -> Void)? = nil,
        rootFinished: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> [URL: Measurement] {
        let run = ScanRun(progress: progress, interval: progressInterval)
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        var pending = unique.makeIterator()
        let limit = max(1, min(maxConcurrency, ProcessInfo.processInfo.activeProcessorCount))
        var results: [URL: Measurement] = [:]

        var owners: [URL: Int] = [:]

        try await withThrowingTaskGroup(of: (URL, Measurement, Int?).self) { group in
            func startNext() {
                guard let url = pending.next() else { return }
                group.addTask {
                    let (measurement, owner) = try measureOrReport(url, run: run)
                    return (url, measurement, owner)
                }
            }
            for _ in 0..<limit { startNext() }
            while let (url, measurement, owner) = try await group.next() {
                results[url] = measurement
                owners[url] = owner
                rootFinished?(results.count, unique.count)
                startNext()
            }
        }
        run.finish(path: urls.last?.path ?? "")

        // Whether a name is "outside" depends on everything walked, so shared space is settled only now.
        for (url, owner) in owners {
            guard let measurement = results[url] else { continue }
            results[url] = Measurement(
                size: measurement.size,
                fileCount: measurement.fileCount,
                issues: measurement.issues,
                sharedSize: ByteSize(run.inodes.sharedBytes(owner: owner))
            )
        }
        return results
    }

    /// Tree for Space Lens: real children down to `depth`, deeper folders collapsed to one node with their total size.
    public func tree(
        at root: URL,
        depth: Int,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> (node: DiskNode, issues: [ScanIssue]) {
        let run = ScanRun(progress: progress, interval: progressInterval)
        let walked = try walk(root, run: run, depth: max(depth, 0))
        run.finish(path: root.path)
        return (walked.node, walked.measurement.issues)
    }

    private func measureOrReport(_ url: URL, run: ScanRun) throws -> (Measurement, owner: Int?) {
        do {
            let walked = try walk(url, run: run, depth: 0)
            return (walked.measurement, walked.owner)
        } catch let error as ScanError {
            return (Measurement(size: .zero, fileCount: 0, issues: [ScanIssue(url: url, reason: error.reason)]), nil)
        }
    }

    /// Walks one root. Folders deeper than `depth` levels below it are collapsed into a single node.
    private func walk(_ url: URL, run: ScanRun, depth: Int) throws -> (measurement: Measurement, node: DiskNode, owner: Int) {
        try Task.checkCancellation()
        let path = url.standardizedFileURL.path
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else {
            throw errno == ENOENT ? ScanError.notFound(url) : .unreadable(url, reason: ScanError.message(for: errno))
        }
        let root = EntryStat(rootStat)
        let owner = run.makeOwner()
        let traversal = Traversal(run: run, safetyGuard: safetyGuard, rootDevice: root.device, owner: owner)

        let node: DiskNode
        let total: Int64
        if root.isDirectory {
            let visit = try traversal.visitDirectory(path, own: root.allocatedBytes, level: 0, depth: depth)
            total = visit.bytes
            node = depth > 0 || !visit.hadEntries
                ? .directory(url, ownSize: ByteSize(root.allocatedBytes), children: visit.children)
                : .collapsedDirectory(url, size: ByteSize(total))
        } else {
            total = traversal.countFile(root)
            node = .file(url, size: ByteSize(total))
        }
        traversal.flush(path: path)
        let measurement = Measurement(
            size: ByteSize(total),
            fileCount: traversal.fileCount,
            issues: traversal.issues,
            sharedSize: ByteSize(run.inodes.sharedBytes(owner: owner))
        )
        return (measurement, node, owner)
    }
}

// MARK: - Walking

/// One `lstat` result, reduced to what the scanner needs.
private struct EntryStat {
    let isDirectory: Bool
    let device: dev_t
    let inode: ino_t
    let linkCount: nlink_t
    /// Space actually allocated on disk, which is what `du` reports.
    let allocatedBytes: Int64

    init(_ st: stat) {
        isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        device = st.st_dev
        inode = st.st_ino
        linkCount = st.st_nlink
        allocatedBytes = Int64(st.st_blocks) * 512
    }
}

/// Counters and hard-link bookkeeping shared by every walk of one scanner call.
private final class ScanRun: Sendable {
    let inodes = InodeSet()

    private struct Totals {
        var files = 0
        var bytes: Int64 = 0
        var lastEmit: ContinuousClock.Instant?
    }

    private let totals = OSAllocatedUnfairLock(initialState: Totals())
    private let ownerCounter = OSAllocatedUnfairLock(initialState: 0)
    private let progress: (@Sendable (ScanProgress) -> Void)?
    private let interval: Duration

    init(progress: (@Sendable (ScanProgress) -> Void)?, interval: Duration) {
        self.progress = progress
        self.interval = interval
    }

    /// A number for one walk, so shared space can be attributed to the walk that counted it.
    func makeOwner() -> Int {
        ownerCounter.withLock { counter in
            counter += 1
            return counter
        }
    }

    /// Adds counts from a walk and reports progress, at most once per interval.
    func record(files: Int, bytes: Int64, path: String) {
        let snapshot = totals.withLock { totals -> ScanProgress? in
            totals.files += files
            totals.bytes += bytes
            guard progress != nil else { return nil }
            let now = ContinuousClock.now
            if let last = totals.lastEmit, now - last < interval { return nil }
            totals.lastEmit = now
            return ScanProgress(filesVisited: totals.files, bytesCounted: ByteSize(totals.bytes), currentPath: path)
        }
        if let snapshot { progress?(snapshot) }
    }

    /// Always reports the final totals.
    func finish(path: String) {
        guard let progress else { return }
        progress(totals.withLock {
            ScanProgress(filesVisited: $0.files, bytesCounted: ByteSize($0.bytes), currentPath: path)
        })
    }
}

/// A sequential walk below one root. Not thread-safe: every root gets its own.
private final class Traversal {
    private static let entriesPerCheck = 500

    private let run: ScanRun
    private let safetyGuard: SafetyGuard?
    private let rootDevice: dev_t
    private let owner: Int

    private(set) var issues: [ScanIssue] = []
    private(set) var fileCount = 0
    private var pendingFiles = 0
    private var pendingBytes: Int64 = 0
    private var entriesSinceCheck = 0

    init(run: ScanRun, safetyGuard: SafetyGuard?, rootDevice: dev_t, owner: Int) {
        self.owner = owner
        self.run = run
        self.safetyGuard = safetyGuard
        self.rootDevice = rootDevice
    }

    /// Total bytes of the folder at `path` (its own entry included) and, when `level < depth`, its child nodes.
    /// `hadEntries` is false for an empty folder, which is never worth collapsing.
    func visitDirectory(
        _ path: String,
        own: Int64,
        level: Int,
        depth: Int
    ) throws -> (bytes: Int64, children: [DiskNode], hadEntries: Bool) {
        pendingBytes += own
        var total = own
        var children: [DiskNode] = []
        let expand = level < depth

        let listing = readEntries(of: path)
        if let failure = listing.failure {
            if level == 0 { throw ScanError.unreadable(URL(filePath: path), reason: ScanError.message(for: failure)) }
            issues.append(ScanIssue(url: URL(filePath: path, directoryHint: .isDirectory), reason: ScanError.message(for: failure)))
        }

        for entry in listing.entries {
            try tick(path)
            if entry.stat.device != rootDevice { continue }
            let childPath = path == "/" ? "/" + entry.name : path + "/" + entry.name
            if safetyGuard?.isExcludedFromScan(path: childPath) == true { continue }

            if entry.stat.isDirectory {
                let visit = try visitDirectory(childPath, own: entry.stat.allocatedBytes, level: level + 1, depth: depth)
                total += visit.bytes
                if expand {
                    let url = URL(filePath: childPath, directoryHint: .isDirectory)
                    children.append(
                        level + 1 < depth || !visit.hadEntries
                            ? .directory(url, ownSize: ByteSize(entry.stat.allocatedBytes), children: visit.children)
                            : .collapsedDirectory(url, size: ByteSize(visit.bytes))
                    )
                }
            } else {
                let bytes = countFile(entry.stat)
                total += bytes
                if expand {
                    children.append(.file(URL(filePath: childPath, directoryHint: .notDirectory), size: ByteSize(bytes)))
                }
            }
        }
        return (total, children, !listing.entries.isEmpty)
    }

    /// Counts a non-folder entry and returns the bytes it adds; a hard link already seen adds none.
    func countFile(_ stat: EntryStat) -> Int64 {
        fileCount += 1
        pendingFiles += 1
        let isNew = stat.linkCount <= 1 || run.inodes.record(
            FileID(device: stat.device, inode: stat.inode),
            linkCount: UInt32(stat.linkCount),
            bytes: stat.allocatedBytes,
            owner: owner
        )
        let bytes = isNew ? stat.allocatedBytes : 0
        pendingBytes += bytes
        return bytes
    }

    func flush(path: String) {
        run.record(files: pendingFiles, bytes: pendingBytes, path: path)
        pendingFiles = 0
        pendingBytes = 0
    }

    /// Every few hundred entries: stop if cancelled, and let the run report progress.
    private func tick(_ path: String) throws {
        entriesSinceCheck += 1
        guard entriesSinceCheck >= Self.entriesPerCheck else { return }
        entriesSinceCheck = 0
        try Task.checkCancellation()
        flush(path: path)
    }

    /// Lists a folder and stats every entry while the folder is open, so only one descriptor is held at a time.
    private func readEntries(of path: String) -> (entries: [(name: String, stat: EntryStat)], failure: Int32?) {
        guard let dir = opendir(path) else { return ([], errno) }
        defer { closedir(dir) }
        let descriptor = dirfd(dir)
        var entries: [(name: String, stat: EntryStat)] = []

        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            if fstatat(descriptor, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                entries.append((name, EntryStat(st)))
            } else {
                let url = URL(filePath: path + "/" + name, directoryHint: .notDirectory)
                issues.append(ScanIssue(url: url, reason: ScanError.message(for: errno)))
            }
        }
        return (entries, nil)
    }
}
