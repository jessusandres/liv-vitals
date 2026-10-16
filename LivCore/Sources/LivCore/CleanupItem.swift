import Foundation

/// A single file or folder that a module proposes to remove.
///
/// For a folder, build `url` with a directory hint (`URL(filePath:directoryHint: .isDirectory)`): the
/// cleanup run compares it with what is on disk to notice a folder swapped for something else.
public struct CleanupItem: Identifiable, Hashable, Sendable, Codable {
    public var id: URL { url }

    public let url: URL
    public let category: CleanupCategory
    public let size: ByteSize
    public let lastModified: Date?
    /// Whether the item starts checked in the results list.
    public let isSelectedByDefault: Bool
    /// Why the item deserves a second look, shown under its path (an open app, shared disk space).
    public let note: String?
    /// The cleanup rule that found it, when one did.
    public let ruleID: String?
    /// The project folder this item belongs to (Dev Projects), so the list can group by project.
    public let group: URL?
    /// Why the item cannot be removed right now (it needs administrator rights, it is in use). Such an item
    /// is shown but cannot be checked, and a cleanup skips it even if it is handed one.
    public let blockedReason: String?
    /// Removing it takes the administrator's password: a bundle owned by root, a file in `/Library`. It can be
    /// checked like any other item; the cleaning service asks for the password once.
    public let needsAdmin: Bool
    /// The module that found it (its raw name, e.g. "cleanup"), so a combined scan like Smart Care can hand it
    /// back to the module whose safety checks apply to it. Nil for items built by hand.
    public let module: String?

    /// Shown when most of an item's size is hard-linked to files outside it: moving it frees little.
    public static let sharedSpaceNote = "Mostly shared with other files; moving it frees little space."

    public init(
        url: URL,
        category: CleanupCategory,
        size: ByteSize,
        lastModified: Date? = nil,
        isSelectedByDefault: Bool = true,
        note: String? = nil,
        ruleID: String? = nil,
        group: URL? = nil,
        blockedReason: String? = nil,
        needsAdmin: Bool = false,
        module: String? = nil
    ) {
        self.url = url
        self.category = category
        self.size = size
        self.lastModified = lastModified
        self.isSelectedByDefault = isSelectedByDefault
        self.note = note
        self.ruleID = ruleID
        self.group = group
        self.blockedReason = blockedReason
        self.needsAdmin = needsAdmin
        self.module = module
    }

    /// The same item, marked as found by `module`.
    public func withModule(_ module: String) -> CleanupItem {
        CleanupItem(
            url: url, category: category, size: size, lastModified: lastModified,
            isSelectedByDefault: isSelectedByDefault, note: note, ruleID: ruleID, group: group,
            blockedReason: blockedReason, needsAdmin: needsAdmin, module: module
        )
    }

    public var name: String { url.lastPathComponent }

    public var isBlocked: Bool { blockedReason != nil }
}
