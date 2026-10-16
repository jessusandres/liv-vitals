import Foundation

/// Carries out a cleanup plan and reports what happened, one log entry per operation.
public protocol CleanupExecutor: Sendable {
    func execute(_ plan: CleanupPlan) async throws -> [LogEntry]
}

/// Records what would happen without touching any file.
public struct DryRunExecutor: CleanupExecutor {
    private let log: OperationLog
    private let runID: UUID?
    private let source: String?

    /// - Parameters:
    ///   - runID: Written on every line, like a real run, so the log can show which lines belong together.
    ///   - source: The module running it.
    public init(log: OperationLog, runID: UUID? = nil, source: String? = nil) {
        self.log = log
        self.runID = runID
        self.source = source
    }

    public func execute(_ plan: CleanupPlan) async throws -> [LogEntry] {
        let entries = plan.operations.map { operation in
            LogEntry(
                kind: .dryRun,
                path: operation.item.url.path,
                bytes: operation.item.size.bytes,
                outcome: operation.violation == nil ? .planned : .skipped,
                detail: operation.violation?.description,
                runID: runID,
                source: source
            )
        }
        try await log.append(entries)
        return entries
    }
}
