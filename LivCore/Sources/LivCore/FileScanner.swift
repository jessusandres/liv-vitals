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
    private let legacyEnumeration: Bool
    private let batchObserver: (@Sendable (Int) -> Void)?
    private let treeWorkers: Int

    /// - Parameter guard: When set, whitelisted folders are skipped entirely.
    public init(guard safetyGuard: SafetyGuard? = nil, progressInterval: Duration = .milliseconds(250)) {
        self.init(guard: safetyGuard, progressInterval: progressInterval, legacyEnumeration: false, batchObserver: nil)
    }

    /// Tests only: `legacyEnumeration` forces the `readdir` + `fstatat` path, `batchObserver` hears about
    /// every batch of folder entries just before it is processed (its argument is the batch's entry count), and
    /// `treeWorkers` sets how many threads `tree` walks with.
    init(
        guard safetyGuard: SafetyGuard? = nil,
        progressInterval: Duration = .milliseconds(250),
        legacyEnumeration: Bool,
        batchObserver: (@Sendable (Int) -> Void)? = nil,
        treeWorkers: Int = min(8, ProcessInfo.processInfo.activeProcessorCount)
    ) {
        self.safetyGuard = safetyGuard
        self.progressInterval = progressInterval
        self.legacyEnumeration = legacyEnumeration
        self.batchObserver = batchObserver
        self.treeWorkers = max(1, treeWorkers)
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
        let shared = run.inodes.sharedBytesByOwner()
        for (url, owner) in owners {
            guard let measurement = results[url] else { continue }
            results[url] = Measurement(
                size: measurement.size,
                fileCount: measurement.fileCount,
                issues: measurement.issues,
                sharedSize: ByteSize(shared[owner] ?? 0)
            )
        }
        return results
    }

    /// Tree for Space Lens: real children down to `depth`, deeper folders collapsed to one node with their total size.
    ///
    /// Folders are walked by several threads. The result does not depend on their timing: a file with several
    /// names is counted once, in the node of its smallest path (component by component), and `issues` are sorted
    /// by path.
    public func tree(
        at root: URL,
        depth: Int,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> (node: DiskNode, issues: [ScanIssue]) {
        try Task.checkCancellation()
        let run = ScanRun(progress: progress, interval: progressInterval)
        let path = root.standardizedFileURL.path
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else {
            throw errno == ENOENT ? ScanError.notFound(root) : .unreadable(root, reason: ScanError.message(for: errno))
        }
        let entry = EntryStat(rootStat)
        guard entry.isDirectory else {
            let walked = try walk(root, run: run, depth: 0)
            run.finish(path: root.path)
            return (walked.node, walked.measurement.issues)
        }

        let walk = ParallelTreeWalk(
            run: run, safetyGuard: safetyGuard, rootDevice: entry.device, depth: max(depth, 0),
            legacyEnumeration: legacyEnumeration, batchObserver: batchObserver
        )
        let result = try await walk.run(root: root, path: path, own: entry.allocatedBytes, workers: treeWorkers)
        run.finish(path: root.path)
        return result
    }

    /// Path order component by component: "/" sorts before every other byte, so "a/b" comes before "a-b".
    static func pathPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8) { ($0 == 0x2F ? 0 : $0) < ($1 == 0x2F ? 0 : $1) }
    }

    private func measureOrReport(_ url: URL, run: ScanRun) throws -> (Measurement, owner: Int?) {
        do {
            let walked = try walk(url, run: run, depth: 0, settleSharedSize: false)
            return (walked.measurement, walked.owner)
        } catch let error as ScanError {
            return (Measurement(size: .zero, fileCount: 0, issues: [ScanIssue(url: url, reason: error.reason)]), nil)
        }
    }

    /// Walks one root. Folders deeper than `depth` levels below it are collapsed into a single node.
    /// `settleSharedSize` is false when the caller settles shared space itself once everything is walked.
    private func walk(
        _ url: URL,
        run: ScanRun,
        depth: Int,
        settleSharedSize: Bool = true
    ) throws -> (measurement: Measurement, node: DiskNode, owner: Int) {
        try Task.checkCancellation()
        let path = url.standardizedFileURL.path
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else {
            throw errno == ENOENT ? ScanError.notFound(url) : .unreadable(url, reason: ScanError.message(for: errno))
        }
        let root = EntryStat(rootStat)
        let owner = run.makeOwner()
        let traversal = Traversal(
            run: run, safetyGuard: safetyGuard, rootDevice: root.device, owner: owner,
            legacyEnumeration: legacyEnumeration, batchObserver: batchObserver
        )

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
            sharedSize: settleSharedSize ? ByteSize(run.inodes.sharedBytes(owner: owner)) : .zero
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

    /// A non-folder entry as `getattrlistbulk` reports it.
    init(device: dev_t, inode: ino_t, linkCount: nlink_t, allocatedBytes: Int64) {
        isDirectory = false
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.allocatedBytes = allocatedBytes
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
    private let reader: DirectoryReader

    var issues: [ScanIssue] { reader.issues }
    private(set) var fileCount = 0
    private var pendingFiles = 0
    private var pendingBytes: Int64 = 0
    private var entriesSinceCheck = 0

    init(
        run: ScanRun,
        safetyGuard: SafetyGuard?,
        rootDevice: dev_t,
        owner: Int,
        legacyEnumeration: Bool,
        batchObserver: (@Sendable (Int) -> Void)?
    ) {
        self.reader = DirectoryReader(legacyEnumeration: legacyEnumeration, batchObserver: batchObserver)
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

        let listing = try reader.readEntries(of: path)
        if let failure = listing.failure {
            if level == 0 { throw ScanError.unreadable(URL(filePath: path), reason: ScanError.message(for: failure)) }
            reader.issues.append(ScanIssue(url: URL(filePath: path, directoryHint: .isDirectory), reason: ScanError.message(for: failure)))
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
}

/// Lists folders with their entries' stats, and keeps the per-entry problems it met. Not thread-safe: every walker
/// (or worker) gets its own, which also owns one reusable `getattrlistbulk` buffer.
private final class DirectoryReader {
    private static let entriesPerCheck = 500

    private let legacyEnumeration: Bool
    private let batchObserver: (@Sendable (Int) -> Void)?
    /// Worker threads of the parallel tree walk have no current task, so they ask the walk instead.
    private let isCancelled: () -> Bool
    private var bulkBuffer: UnsafeMutableRawPointer?

    var issues: [ScanIssue] = []

    init(
        legacyEnumeration: Bool,
        batchObserver: (@Sendable (Int) -> Void)?,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) {
        self.legacyEnumeration = legacyEnumeration
        self.batchObserver = batchObserver
        self.isCancelled = isCancelled
    }

    deinit { bulkBuffer?.deallocate() }

    private func checkCancellation() throws {
        if isCancelled() { throw CancellationError() }
    }

    /// Lists a folder with its entries' stats. Uses `getattrlistbulk`, which returns names, types, link counts and
    /// sizes for hundreds of entries per call; falls back to `readdir` + `fstatat` for a folder (or volume) that
    /// does not support it. Both paths check for cancellation between batches of entries.
    func readEntries(of path: String) throws -> (entries: [(name: String, stat: EntryStat)], failure: Int32?) {
        if !legacyEnumeration {
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return ([], errno) }
            defer { close(descriptor) }
            if let listing = try readEntriesInBulk(descriptor, path: path) { return listing }
        }
        return try readEntriesWithReaddir(of: path)
    }

    private static let bulkBufferSize = 128 * 1024

    private struct BulkRecordHeader {
        var length: UInt32
        var returned: attribute_set_t
    }

    /// Nil when the folder does not support `getattrlistbulk` (nothing was consumed, so the caller starts over).
    private func readEntriesInBulk(
        _ descriptor: Int32,
        path: String
    ) throws -> (entries: [(name: String, stat: EntryStat)], failure: Int32?)? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(bitPattern: Int32(bitPattern: ATTR_CMN_RETURNED_ATTRS))
            | attrgroup_t(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)

        if bulkBuffer == nil { bulkBuffer = .allocate(byteCount: Self.bulkBufferSize, alignment: 8) }
        let buffer = bulkBuffer!
        var entries: [(name: String, stat: EntryStat)] = []
        var firstCall = true

        while true {
            try checkCancellation()
            let count = getattrlistbulk(descriptor, &list, buffer, Self.bulkBufferSize, 0)
            if count < 0 {
                if firstCall, errno == ENOTSUP || errno == EINVAL || errno == ENOSYS { return nil }
                return (entries, errno)
            }
            if count == 0 { return (entries, nil) }
            firstCall = false
            batchObserver?(Int(count))

            var record = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                if let parsed = parseBulkRecord(record) {
                    switch parsed {
                    case .entry(let name, let stat): entries.append((name, stat))
                    case .failure(let name, let code):
                        let url = URL(filePath: path + "/" + name, directoryHint: .notDirectory)
                        issues.append(ScanIssue(url: url, reason: ScanError.message(for: code)))
                    case .needsStat(let name):
                        var st = stat()
                        if fstatat(descriptor, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                            entries.append((name, EntryStat(st)))
                        } else {
                            let url = URL(filePath: path + "/" + name, directoryHint: .notDirectory)
                            issues.append(ScanIssue(url: url, reason: ScanError.message(for: errno)))
                        }
                    }
                }
                record += length
            }
        }
    }

    private enum BulkRecord {
        case entry(String, EntryStat)
        case failure(String, Int32)
        /// Folders (their own size and device must match `lstat` exactly) and anything the volume left out.
        case needsStat(String)
    }

    /// One packed record: length, returned-attributes set, then, in order, the error, name, device, object type,
    /// file id and, for files, the link count and allocated size. Only the attributes the set says are present.
    private func parseBulkRecord(_ record: UnsafeRawPointer) -> BulkRecord? {
        let returned = record.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: attribute_set_t.self)
        var offset = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
        func next<T>(_: T.Type) -> T {
            defer { offset += MemoryLayout<T>.size }
            return record.loadUnaligned(fromByteOffset: offset, as: T.self)
        }

        let common = returned.commonattr
        var code: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 { code = next(UInt32.self) }
        guard common & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let nameFieldOffset = offset
        let reference = next(attrreference_t.self)
        let namePointer = record.advanced(by: nameFieldOffset + Int(reference.attr_dataoffset))
        let name = String(cString: namePointer.assumingMemoryBound(to: CChar.self))
        if name == "." || name == ".." { return nil }
        if code != 0 { return .failure(name, Int32(code)) }

        let wanted = attrgroup_t(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
        guard common & wanted == wanted else { return .needsStat(name) }
        let device = next(dev_t.self)
        let type = next(UInt32.self)
        let inode = next(UInt64.self)
        if type == VDIR.rawValue { return .needsStat(name) }

        let fileAttrs = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
        guard returned.fileattr & fileAttrs == fileAttrs else { return .needsStat(name) }
        let linkCount = next(UInt32.self)
        let allocated = next(Int64.self)
        return .entry(name, EntryStat(device: device, inode: ino_t(inode), linkCount: nlink_t(linkCount), allocatedBytes: allocated))
    }

    /// The pre-`getattrlistbulk` path: lists a folder and stats every entry while the folder is open.
    private func readEntriesWithReaddir(of path: String) throws -> (entries: [(name: String, stat: EntryStat)], failure: Int32?) {
        guard let dir = opendir(path) else { return ([], errno) }
        defer { closedir(dir) }
        let descriptor = dirfd(dir)
        var entries: [(name: String, stat: EntryStat)] = []
        var sinceCheck = 0

        while let entry = readdir(dir) {
            sinceCheck += 1
            if sinceCheck >= Self.entriesPerCheck {
                sinceCheck = 0
                try checkCancellation()
                batchObserver?(Self.entriesPerCheck)
            }
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

// MARK: - Parallel tree walk

/// A file or folder of the tree being built, down to the requested depth. Folders below that add their bytes to
/// the collapsed folder that contains them.
private final class TreeSlot: @unchecked Sendable {
    let path: String
    let isDirectory: Bool
    /// Above the depth limit: its entries become child nodes.
    let expanded: Bool
    let own: Int64
    // Written only by the one job that lists this folder, and read after every worker has finished.
    var hadEntries = false
    var children: [TreeSlot] = []
    private let bytes = OSAllocatedUnfairLock(initialState: Int64(0))

    init(path: String, isDirectory: Bool, expanded: Bool, own: Int64) {
        self.path = path
        self.isDirectory = isDirectory
        self.expanded = expanded
        self.own = own
    }

    func add(_ amount: Int64) {
        bytes.withLock { $0 += amount }
    }

    /// The finished node; `url` replaces the one built from `path` (the root keeps the caller's URL).
    func node(url: URL? = nil) -> DiskNode {
        let total = bytes.withLock { $0 }
        guard isDirectory else { return .file(url ?? URL(filePath: path, directoryHint: .notDirectory), size: ByteSize(total)) }
        let url = url ?? URL(filePath: path, directoryHint: .isDirectory)
        if expanded || !hadEntries {
            return .directory(url, ownSize: ByteSize(own), children: children.map { $0.node() })
        }
        return .collapsedDirectory(url, size: ByteSize(total))
    }
}

private struct TreeJob: @unchecked Sendable {
    let path: String
    let level: Int
    let own: Int64
    /// The folder's own slot when it is within the depth, otherwise the collapsed folder that takes its bytes.
    let slot: TreeSlot
}

/// One name of a file that has several. Its bytes are added once every name has been met.
private struct LinkSighting {
    let id: FileID
    let bytes: Int64
    let path: String
    let slot: TreeSlot
}

/// Folders waiting to be listed, shared by the workers. Last in, first out keeps the waiting list short.
private final class TreeJobQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [TreeJob]
    private var busy = 0
    private var failure: (any Error)?
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    init(_ first: TreeJob) {
        jobs = [first]
    }

    var isStopped: Bool { stopped.withLock { $0 } }

    var error: (any Error)? {
        condition.lock()
        defer { condition.unlock() }
        return failure
    }

    /// The next folder, or nil once nothing is left or the walk stopped. Waits while busy workers may add more.
    func next() -> TreeJob? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty, busy > 0, failure == nil { condition.wait() }
        guard failure == nil, let job = jobs.popLast() else { return nil }
        busy += 1
        return job
    }

    /// Ends a job taken with `next()`, queueing the folders it found.
    func finished(adding found: [TreeJob]) {
        condition.lock()
        defer { condition.unlock() }
        jobs.append(contentsOf: found.reversed())
        busy -= 1
        if !found.isEmpty || busy == 0 { condition.broadcast() }
    }

    /// Stops every worker; the first error is the one the walk throws.
    func stop(_ error: any Error) {
        stopped.withLock { $0 = true }
        condition.lock()
        defer { condition.unlock() }
        if failure == nil { failure = error }
        condition.broadcast()
    }
}

/// What one worker collected; only that worker writes it.
private final class TreeWorkerResult: @unchecked Sendable {
    var sightings: [LinkSighting] = []
    var issues: [ScanIssue] = []
}

/// `FileScanner.tree` on several threads. Sums do not depend on which thread adds them, and files with several
/// names are settled at the end by path, so every run gives the same tree.
private final class ParallelTreeWalk: @unchecked Sendable {
    private let run: ScanRun
    private let safetyGuard: SafetyGuard?
    private let rootDevice: dev_t
    private let depth: Int
    private let legacyEnumeration: Bool
    private let batchObserver: (@Sendable (Int) -> Void)?

    init(
        run: ScanRun,
        safetyGuard: SafetyGuard?,
        rootDevice: dev_t,
        depth: Int,
        legacyEnumeration: Bool,
        batchObserver: (@Sendable (Int) -> Void)?
    ) {
        self.run = run
        self.safetyGuard = safetyGuard
        self.rootDevice = rootDevice
        self.depth = depth
        self.legacyEnumeration = legacyEnumeration
        self.batchObserver = batchObserver
    }

    func run(root: URL, path: String, own: Int64, workers: Int) async throws -> (node: DiskNode, issues: [ScanIssue]) {
        let top = TreeSlot(path: path, isDirectory: true, expanded: depth > 0, own: own)
        let queue = TreeJobQueue(TreeJob(path: path, level: 0, own: own, slot: top))
        let results = (0..<workers).map { _ in TreeWorkerResult() }

        await withTaskCancellationHandler {
            DispatchQueue.concurrentPerform(iterations: workers) { index in
                let reader = DirectoryReader(
                    legacyEnumeration: legacyEnumeration, batchObserver: batchObserver, isCancelled: { queue.isStopped }
                )
                let result = results[index]
                while let job = queue.next() {
                    do {
                        queue.finished(adding: try visit(job, reader: reader, sightings: &result.sightings))
                    } catch {
                        queue.stop(error)
                        queue.finished(adding: [])
                    }
                }
                result.issues = reader.issues
            }
        } onCancel: {
            queue.stop(CancellationError())
        }
        if let error = queue.error { throw error }

        var owners: [FileID: LinkSighting] = [:]
        for sighting in results.flatMap(\.sightings) {
            if let current = owners[sighting.id], !FileScanner.pathPrecedes(sighting.path, current.path) { continue }
            owners[sighting.id] = sighting
        }
        var linkedBytes: Int64 = 0
        for owner in owners.values {
            owner.slot.add(owner.bytes)
            linkedBytes += owner.bytes
        }
        run.record(files: 0, bytes: linkedBytes, path: path)

        let issues = results.flatMap(\.issues).sorted {
            $0.url.path == $1.url.path ? $0.reason < $1.reason : FileScanner.pathPrecedes($0.url.path, $1.url.path)
        }
        return (top.node(url: root), issues)
    }

    /// Lists one folder, adds what it holds to its slot and returns its subfolders as new jobs.
    private func visit(_ job: TreeJob, reader: DirectoryReader, sightings: inout [LinkSighting]) throws -> [TreeJob] {
        let listing = try reader.readEntries(of: job.path)
        if let failure = listing.failure {
            if job.level == 0 { throw ScanError.unreadable(URL(filePath: job.path), reason: ScanError.message(for: failure)) }
            reader.issues.append(
                ScanIssue(url: URL(filePath: job.path, directoryHint: .isDirectory), reason: ScanError.message(for: failure))
            )
        }
        let expand = job.level < depth
        if job.level <= depth { job.slot.hadEntries = !listing.entries.isEmpty }

        var slotBytes = job.own
        var counted = job.own
        var files = 0
        var found: [TreeJob] = []
        for (name, stat) in listing.entries {
            if stat.device != rootDevice { continue }
            let childPath = job.path == "/" ? "/" + name : job.path + "/" + name
            if safetyGuard?.isExcludedFromScan(path: childPath) == true { continue }

            if stat.isDirectory {
                var slot = job.slot
                if expand {
                    slot = TreeSlot(path: childPath, isDirectory: true, expanded: job.level + 1 < depth, own: stat.allocatedBytes)
                    job.slot.children.append(slot)
                }
                found.append(TreeJob(path: childPath, level: job.level + 1, own: stat.allocatedBytes, slot: slot))
                continue
            }

            files += 1
            var slot = job.slot
            if expand {
                slot = TreeSlot(path: childPath, isDirectory: false, expanded: false, own: 0)
                job.slot.children.append(slot)
            }
            if stat.linkCount > 1 {
                sightings.append(LinkSighting(
                    id: FileID(device: stat.device, inode: stat.inode), bytes: stat.allocatedBytes, path: childPath, slot: slot
                ))
                continue
            }
            counted += stat.allocatedBytes
            if expand { slot.add(stat.allocatedBytes) } else { slotBytes += stat.allocatedBytes }
        }
        job.slot.add(slotBytes)
        run.record(files: files, bytes: counted, path: job.path)
        return found
    }
}
