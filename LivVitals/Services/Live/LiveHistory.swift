import Foundation
import LivCore

/// History read from the operations log, which is the single record of what was removed, and "Put Back".
/// Only finished Trash moves and deletes count; dry runs, skipped and failed items do not.
nonisolated struct LiveHistory: HistoryProviding {
    static let adminCancelledReason = "The password dialog was cancelled."
    static let servicesNotice = "Restored services start again after you log out or restart."

    let isSimulated = false
    let log: OperationLog
    let home: URL
    let appFolders: [URL]
    let systemLibrary: URL
    let restorer: any FileRestoring
    let privileged: any PrivilegedRunning

    init(
        log: OperationLog,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        appFolders: [URL]? = nil,
        systemLibrary: URL = URL(filePath: "/Library", directoryHint: .isDirectory),
        restorer: any FileRestoring = SystemFileRemover(),
        privileged: any PrivilegedRunning = SystemPrivilegedRunner()
    ) {
        self.log = log
        self.home = home
        self.appFolders = appFolders ?? AppInventory.standardFolders(home: home)
        self.systemLibrary = systemLibrary
        self.restorer = restorer
        self.privileged = privileged
    }

    @concurrent func runs() async -> [HistoryRun] {
        guard let entries = try? await log.entries() else { return [] }
        return HistoryBuilder.runs(from: entries)
    }

    /// The log already has the record, so there is nothing to store.
    @concurrent func record(_ record: CleanupRecord) async {}

    private var planner: RestorePlanner { RestorePlanner(home: home, appFolders: appFolders, systemLibrary: systemLibrary) }

    @concurrent func preview(_ items: [HistoryItem]) async -> RestorePreview {
        var preview = RestorePreview()
        for item in items {
            switch planner.plan(item) {
            case .asUser: preview.restorable += 1
            case .asAdmin:
                preview.restorable += 1
                preview.needsPassword += 1
            case .skip(let reason): preview.skipped.append(RestoreProblem(originalPath: item.originalPath, reason: reason))
            }
        }
        return preview
    }

    @concurrent func putBack(
        _ items: [HistoryItem],
        of run: UUID,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> RestoreOutcome {
        let source = await runs().first { $0.id == run }?.record.source
        let runner = RestoreRunner(planner: planner, restorer: restorer, log: log, runID: run, source: source)

        onUpdate(ScanUpdate(fraction: 0, currentPath: ""))
        let report = try await runner.execute(runner.plan(items)) { done, total in
            onUpdate(ScanUpdate(fraction: Double(done) / Double(max(total, 1)), currentPath: ""))
        }
        var entries = report.entries
        try Task.checkCancellation()

        if !report.adminRestores.isEmpty {
            entries += try await restoreAsAdmin(report.adminRestores, with: runner, onUpdate: onUpdate)
        }
        return Self.outcome(from: entries)
    }

    /// Checks every item again, then moves what is still allowed with a single password dialog.
    private func restoreAsAdmin(
        _ pending: [AdminRestore],
        with runner: RestoreRunner,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> [LogEntry] {
        var entries: [LogEntry] = []
        var approved: [AdminRestore] = []
        for restore in pending {
            // Planned again right before the password is asked: the Trash or the folder may have changed.
            switch planner.plan(restore.item) {
            case .asAdmin(let from, let to):
                approved.append(AdminRestore(item: restore.item, from: from, to: to))
            case .skip(let reason):
                entries.append(try await runner.recordAdmin(restore, outcome: .skipped, detail: reason))
            case .asUser:
                entries.append(try await runner.recordAdmin(restore, outcome: .skipped, detail: "It no longer needs the administrator."))
            }
        }
        guard !approved.isEmpty else { return entries }

        onUpdate(ScanUpdate(fraction: nil, currentPath: "Waiting for your password…"))
        do {
            let moved = try await privileged.restoreAsRoot(approved.map { ($0.from, $0.to) })
            for restore in approved {
                switch moved[restore.from] {
                case .success?: entries.append(try await runner.recordAdmin(restore, outcome: .done))
                case .failure(let error)?:
                    let reason = error.localizedDescription
                    let skipped = reason == "No longer in the Trash." || reason == "Something else is at the original location."
                    entries.append(try await runner.recordAdmin(restore, outcome: skipped ? .skipped : .failed, detail: reason))
                case nil:
                    entries.append(try await runner.recordAdmin(restore, outcome: .failed, detail: "No answer from the administrator command."))
                }
            }
        } catch PrivilegedError.cancelled {
            for restore in approved {
                entries.append(try await runner.recordAdmin(restore, outcome: .skipped, detail: Self.adminCancelledReason))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            for restore in approved {
                entries.append(try await runner.recordAdmin(restore, outcome: .failed, detail: error.localizedDescription))
            }
        }
        return entries
    }

    static func outcome(from entries: [LogEntry]) -> RestoreOutcome {
        var outcome = RestoreOutcome()
        for entry in entries {
            switch entry.outcome {
            case .done:
                outcome.restored += 1
                if entry.path.contains("/LaunchDaemons/") || entry.path.contains("/LaunchAgents/") {
                    outcome.notice = servicesNotice
                }
            case .skipped: outcome.skipped.append(RestoreProblem(originalPath: entry.path, reason: entry.detail ?? "Skipped"))
            case .failed: outcome.failed.append(RestoreProblem(originalPath: entry.path, reason: entry.detail ?? "Unknown error"))
            case .planned: break
            }
        }
        return outcome
    }
}
