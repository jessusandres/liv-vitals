import Foundation

/// An item that needs the administrator's password to be put back. The app moves these together, in one dialog.
public struct AdminRestore: Sendable, Equatable {
    public let item: HistoryItem
    public let from: URL
    public let to: URL

    public init(item: HistoryItem, from: URL, to: URL) {
        self.item = item
        self.from = from
        self.to = to
    }
}

/// What a "Put Back" run did on its own.
public struct RestoreReport: Sendable {
    /// One line per item handled here, already in the log.
    public let entries: [LogEntry]
    /// Items left for the administrator step, untouched and not yet logged.
    public let adminRestores: [AdminRestore]
}

/// Puts items back from the Trash and logs every step, like `CleanupRunner` does for removing.
///
/// The steps come from `RestorePlanner`; each one is planned again right before it runs, because the
/// Trash or the destination may have changed since the user looked. Whatever happens to one item, the
/// others are still tried; cancelling stops cleanly between items.
public struct RestoreRunner: Sendable {
    private let planner: RestorePlanner
    private let restorer: any FileRestoring
    private let log: OperationLog
    private let runID: UUID
    private let source: String?

    /// - Parameters:
    ///   - runID: The cleanup being put back, written on every line so History ties them together.
    ///   - source: The module of that cleanup.
    public init(planner: RestorePlanner, restorer: any FileRestoring, log: OperationLog, runID: UUID, source: String? = nil) {
        self.planner = planner
        self.restorer = restorer
        self.log = log
        self.runID = runID
        self.source = source
    }

    /// Plans every item. Used for the confirmation and as the input of `execute`.
    public func plan(_ items: [HistoryItem]) -> [(item: HistoryItem, step: RestoreStep)] {
        items.map { ($0, planner.plan($0)) }
    }

    public func execute(
        _ planned: [(item: HistoryItem, step: RestoreStep)],
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> RestoreReport {
        var entries: [LogEntry] = []
        var admin: [AdminRestore] = []

        for (index, (item, step)) in planned.enumerated() {
            progress?(index, planned.count)
            if Task.isCancelled { break }
            switch step {
            case .skip(let reason):
                entries.append(try await write(entry(item, .skipped, detail: reason)))
            case .asAdmin(let from, let to):
                admin.append(AdminRestore(item: item, from: from, to: to))
            case .asUser:
                entries.append(try await write(run(item)))
            }
        }
        return RestoreReport(entries: entries, adminRestores: admin)
    }

    /// Logs how the administrator step ended for one item.
    public func recordAdmin(_ restore: AdminRestore, outcome: LogEntry.Outcome, detail: String? = nil) async throws -> LogEntry {
        try await write(entry(restore.item, outcome, detail: detail))
    }

    private func run(_ item: HistoryItem) -> LogEntry {
        // Planned again: what was true when the user chose may not be true now.
        switch planner.plan(item) {
        case .skip(let reason):
            return entry(item, .skipped, detail: reason)
        case .asAdmin:
            return entry(item, .skipped, detail: "It now needs the administrator's password.")
        case .asUser(let from, let to):
            do {
                try restorer.restore(from, to: to)
                return entry(item, .done)
            } catch {
                return entry(item, .failed, detail: error.localizedDescription)
            }
        }
    }

    private func entry(_ item: HistoryItem, _ outcome: LogEntry.Outcome, detail: String? = nil) -> LogEntry {
        LogEntry(
            kind: .restore,
            path: item.originalPath,
            bytes: item.bytes,
            outcome: outcome,
            detail: detail,
            runID: runID,
            trashedPath: item.trashedPath,
            source: source
        )
    }

    /// Written at once, so a crash never leaves a restored item without its record.
    private func write(_ entry: LogEntry) async throws -> LogEntry {
        try await log.append([entry])
        return entry
    }
}
