import Foundation

/// One thing a past cleanup removed.
public struct HistoryItem: Sendable, Hashable, Identifiable {
    public var id: String { originalPath }

    public let originalPath: String
    /// Where it is in the Trash; `nil` when it was deleted for good.
    public let trashedPath: String?
    public let bytes: Int64
    /// Set when a later "Put Back" moved it home again.
    public let restoredAt: Date?

    public init(originalPath: String, trashedPath: String?, bytes: Int64, restoredAt: Date? = nil) {
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.bytes = bytes
        self.restoredAt = restoredAt
    }
}

/// A finished cleanup with the items it removed.
public struct HistoryRun: Sendable, Identifiable {
    public var id: UUID { record.id }

    public let record: CleanupRecord
    public let items: [HistoryItem]

    public init(record: CleanupRecord, items: [HistoryItem]) {
        self.record = record
        self.items = items
    }

    /// Items that went to the Trash and have not been put back.
    public var restorableCount: Int { items.filter { $0.trashedPath != nil && $0.restoredAt == nil }.count }
    public var restoredCount: Int { items.filter { $0.restoredAt != nil }.count }
}

public enum HistoryBuilder {
    /// One run per `runID`, newest first. Only finished Trash moves and deletes count; dry runs, skipped and
    /// failed items do not. Lines written before runs had an ID cannot be grouped and are left out.
    public static func runs(from entries: [LogEntry]) -> [HistoryRun] {
        var restoredAt: [UUID: [String: Date]] = [:]
        for entry in entries where entry.kind == .restore && entry.outcome == .done {
            guard let runID = entry.runID else { continue }
            restoredAt[runID, default: [:]][entry.path] = max(entry.date, restoredAt[runID]?[entry.path] ?? .distantPast)
        }

        var order: [UUID] = []
        var removed: [UUID: [LogEntry]] = [:]
        for entry in entries where entry.outcome == .done && (entry.kind == .trash || entry.kind == .delete) {
            guard let runID = entry.runID else { continue }
            if removed[runID] == nil { order.append(runID) }
            removed[runID, default: []].append(entry)
        }

        return order.compactMap { runID -> HistoryRun? in
            guard let lines = removed[runID] else { return nil }
            let record = CleanupRecord(
                id: runID,
                date: lines.map(\.date).max() ?? .now,
                source: lines.compactMap(\.source).first ?? "Cleanup",
                itemCount: lines.count,
                freed: ByteSize(lines.map(\.bytes).reduce(0, +)),
                movedToTrash: lines.allSatisfy { $0.kind == .trash }
            )
            let items = lines.map { line in
                HistoryItem(
                    originalPath: line.path,
                    trashedPath: line.kind == .trash ? line.trashedPath : nil,
                    bytes: line.bytes,
                    restoredAt: restoredAt[runID]?[line.path]
                )
            }
            return HistoryRun(record: record, items: items)
        }
        .sorted { $0.record.date > $1.record.date }
    }
}
