import Darwin
import Foundation

/// Carries out a cleanup plan: moves items to the Trash or deletes them, and logs every step.
///
/// Every operation is checked again right before it runs, with the same `SafetyGuard` that planned it,
/// and the action is taken on the path `validate` returns. Whatever happens to one item, the others
/// are still tried; cancelling stops cleanly between items.
///
/// A small gap remains between the last check and the system call: another process of the same user
/// could change the path in that instant. Path-based file APIs cannot close it. The aim is to protect
/// the user from mistakes, not from a hostile program that already has the user's permissions.
public struct CleanupRunner: CleanupExecutor {
    private let safetyGuard: SafetyGuard
    private let remover: any FileRemoving
    private let log: OperationLog
    private let runID: UUID
    private let source: String?
    private let progress: (@Sendable (_ done: Int, _ total: Int, _ current: URL) -> Void)?

    /// - Parameters:
    ///   - runID: Written on every log line of this run, so History can group them.
    ///   - source: The module running it, written on every log line too.
    ///   - progress: Called before each operation with how many were handled so far.
    public init(
        guard safetyGuard: SafetyGuard,
        remover: any FileRemoving,
        log: OperationLog,
        runID: UUID = UUID(),
        source: String? = nil,
        progress: (@Sendable (_ done: Int, _ total: Int, _ current: URL) -> Void)? = nil
    ) {
        self.safetyGuard = safetyGuard
        self.remover = remover
        self.log = log
        self.runID = runID
        self.source = source
        self.progress = progress
    }

    public func execute(_ plan: CleanupPlan) async throws -> [LogEntry] {
        var entries: [LogEntry] = []
        let total = plan.operations.count

        for (index, operation) in plan.operations.enumerated() {
            progress?(index, total, operation.item.url)
            // Stop between items: what is done stays logged, what is pending is not touched.
            if Task.isCancelled { break }
            let entry = run(operation)
            // Written at once, so a crash never leaves a removed item without its record.
            try await log.append([entry])
            entries.append(entry)
        }
        return entries
    }

    private func run(_ operation: PlannedOperation) -> LogEntry {
        let item = operation.item
        let kind: LogEntry.Kind = operation.action == .moveToTrash ? .trash : .delete
        func entry(_ outcome: LogEntry.Outcome, detail: String? = nil, trashedPath: String? = nil) -> LogEntry {
            LogEntry(
                kind: kind,
                path: item.url.path,
                bytes: item.size.bytes,
                outcome: outcome,
                detail: detail,
                runID: runID,
                trashedPath: trashedPath,
                source: source
            )
        }

        if let violation = operation.violation { return entry(.skipped, detail: violation.description) }

        let target: URL
        do {
            target = try safetyGuard.validate(item.url)
        } catch {
            return entry(.skipped, detail: error.description)
        }

        var status = stat()
        guard lstat(target.path, &status) == 0 else { return entry(.skipped, detail: "No longer exists") }
        // A folder that became a link (or the other way round) is not what the user reviewed.
        let isFolderNow = (status.st_mode & S_IFMT) == S_IFDIR
        if isFolderNow != item.url.hasDirectoryPath { return entry(.skipped, detail: "Changed since the scan") }

        do {
            switch operation.action {
            case .moveToTrash:
                return entry(.done, trashedPath: try remover.trash(target)?.path)
            case .delete:
                try remover.delete(target)
                return entry(.done)
            }
        } catch {
            return entry(.failed, detail: error.localizedDescription)
        }
    }
}
