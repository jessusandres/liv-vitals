import Foundation

/// The outcome of one scan: every item found, ready to be grouped and selected in the UI.
public struct ScanResult: Hashable, Sendable, Codable {
    public let items: [CleanupItem]
    public let scannedAt: Date
    /// Locations the scan did not look into because they need Full Disk Access, which was not granted.
    public let locationsNeedingAccess: Int
    /// Places the scan could not use, e.g. a project folder that does not exist or is protected.
    public let issues: [ScanIssue]

    public init(items: [CleanupItem], scannedAt: Date = .now, locationsNeedingAccess: Int = 0, issues: [ScanIssue] = []) {
        self.items = items
        self.scannedAt = scannedAt
        self.locationsNeedingAccess = locationsNeedingAccess
        self.issues = issues
    }

    public static let empty = ScanResult(items: [])

    public var totalSize: ByteSize { items.map(\.size).sum() }

    public var defaultSelection: Set<CleanupItem.ID> {
        Set(items.filter { $0.isSelectedByDefault && !$0.isBlocked }.map(\.id))
    }

    /// Categories that have items, largest first, each with its items sorted largest first.
    public var groups: [(category: CleanupCategory, items: [CleanupItem], size: ByteSize)] {
        Dictionary(grouping: items, by: \.category)
            .map { category, items in
                (category, items.sorted { $0.size > $1.size }, items.map(\.size).sum())
            }
            .sorted { $0.size > $1.size }
    }

    /// Groups that have items (projects in Dev Projects, apps in the Uninstaller), largest first, each with its items sorted largest first. Items without a
    /// project are left out.
    public var projectGroups: [(project: URL, items: [CleanupItem], size: ByteSize)] {
        Dictionary(grouping: items.filter { $0.group != nil }, by: { $0.group! })
            .map { project, items in
                (project, items.sorted { $0.size > $1.size }, items.map(\.size).sum())
            }
            .sorted { ($0.size, $1.project.path) > ($1.size, $0.project.path) }
    }

    public func size(of selection: Set<CleanupItem.ID>) -> ByteSize {
        items.filter { selection.contains($0.id) }.map(\.size).sum()
    }
}
