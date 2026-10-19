import Darwin
import os

/// A (device, inode) pair identifying one file on disk, whatever name it is reached by.
struct FileID: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
}

/// Remembers the files that have more than one name, so each adds its size only once, and how many of
/// their names were actually met. A file with names that were never met is shared with something outside.
final class InodeSet: Sendable {
    private struct Entry {
        var linkCount: UInt32
        var seen: Int
        var bytes: Int64
        /// The walk that met it first, which is the one that counted its size.
        var owner: Int
    }

    private let entries = OSAllocatedUnfairLock(initialState: [FileID: Entry]())

    /// Notes one sighting. True the first time `id` is seen, false for every later one.
    func record(_ id: FileID, linkCount: UInt32, bytes: Int64, owner: Int) -> Bool {
        entries.withLock { entries in
            if entries[id] != nil {
                entries[id]?.seen += 1
                return false
            }
            entries[id] = Entry(linkCount: linkCount, seen: 1, bytes: bytes, owner: owner)
            return true
        }
    }

    /// Bytes of the files `owner` counted that also have names outside everything walked so far.
    func sharedBytes(owner: Int) -> Int64 {
        entries.withLock { entries in
            entries.values.reduce(into: Int64(0)) { total, entry in
                if entry.owner == owner, Int(entry.linkCount) > entry.seen { total += entry.bytes }
            }
        }
    }

    /// `sharedBytes(owner:)` for every owner at once, in one pass under one lock.
    func sharedBytesByOwner() -> [Int: Int64] {
        entries.withLock { entries in
            var totals: [Int: Int64] = [:]
            for entry in entries.values where Int(entry.linkCount) > entry.seen {
                totals[entry.owner, default: 0] += entry.bytes
            }
            return totals
        }
    }
}
