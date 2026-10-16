import Foundation

/// The one door through which anything is removed from disk.
public protocol FileRemoving: Sendable {
    /// Moves the item to the Trash and returns where it ended up, when the system says.
    func trash(_ url: URL) throws -> URL?
    /// Removes the item for good. Folders go with everything inside them.
    func delete(_ url: URL) throws
}

/// Puts something that went to the Trash back where it was.
public protocol FileRestoring: Sendable {
    /// Moves `trashed` to `original`. Fails when something is already at `original`; it never overwrites.
    func restore(_ trashed: URL, to original: URL) throws
}

/// The real remover. This is the only file in the project allowed to call the system's trash, delete and
/// move APIs. `CleanupRunner` calls it after `SafetyGuard` has approved the exact path, and `RestoreRunner`
/// after `RestorePlanner` has.
public struct SystemFileRemover: FileRemoving {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    public func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

extension SystemFileRemover: FileRestoring {
    public func restore(_ trashed: URL, to original: URL) throws {
        // `moveItem` fails when the destination exists, so a restore cannot overwrite anything.
        try FileManager.default.moveItem(at: trashed, to: original)
    }
}
