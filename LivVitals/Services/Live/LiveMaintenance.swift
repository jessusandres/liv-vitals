import Foundation
import LivCore

/// Runs the Performance tasks for real: the steps of `MaintenanceCommand`, nothing else.
///
/// Tasks without a password go first, one after another. The steps that need administrator rights from all the
/// remaining tasks then go to `PrivilegedRunning` in a single call, so the user sees one dialog (or none, with the
/// sudoers rule). A step of a task that does not need rights, such as restarting the Dock after the icon cache
/// is deleted, runs after its task's administrator steps, so each task keeps its own order. Every result is
/// written to the log as soon as it is known.
nonisolated struct LiveMaintenance: MaintenanceRunning {
    static let source = "Performance"
    static let cancelledReason = "The password was not entered, so this task did not run."
    /// Rebuilding the Launch Services database can take a couple of minutes.
    static let stepTimeout = Duration.seconds(600)

    let isSimulated = false
    let commands: any CommandRunning
    let privileged: any PrivilegedRunning
    let log: OperationLog

    var tasks: [MaintenanceTask] { MaintenanceCommand.allCases.map(\.task) }

    @concurrent func run(
        _ tasks: [MaintenanceTask],
        options: MaintenanceOptions,
        onEvent: @escaping @Sendable (MaintenanceEvent) -> Void
    ) async throws -> [String: MaintenanceOutcome] {
        var seen = Set<String>()
        let selected = tasks.compactMap { MaintenanceCommand(rawValue: $0.id) }.filter { seen.insert($0.rawValue).inserted }
        let runID = UUID()
        var outcomes: [String: MaintenanceOutcome] = [:]

        func finish(_ command: MaintenanceCommand, _ outcome: MaintenanceOutcome) async throws {
            outcomes[command.rawValue] = outcome
            try await log.append([Self.entry(for: command, outcome: outcome, runID: runID)])
            onEvent(.finished(command.rawValue, outcome))
        }

        if options.dryRun {
            for command in selected {
                onEvent(.started(command.rawValue))
                outcomes[command.rawValue] = .done
                let detail = "Would run: " + command.steps.map(\.display).joined(separator: "; ")
                try await log.append([LogEntry(
                    kind: .maintenance, path: "task:\(command.rawValue)", bytes: 0, outcome: .planned,
                    detail: detail, runID: runID, source: Self.source
                )])
                onEvent(.finished(command.rawValue, .done))
            }
            return outcomes
        }

        // Without a password: nothing to wait for.
        for command in selected where !command.requiresAdmin {
            try Task.checkCancellation()
            onEvent(.started(command.rawValue))
            try await finish(command, try await runPlain(command.steps))
        }

        // With one: a single request for all of them.
        let admin = selected.filter(\.requiresAdmin)
        guard !admin.isEmpty else { return outcomes }
        try Task.checkCancellation()
        for command in admin { onEvent(.started(command.rawValue)) }

        let steps = admin.flatMap { command in command.steps.filter(\.needsAdmin).map { (command: command, step: $0) } }
        let reason = "Liv Vitals wants to run: " + admin.map { $0.task.title }.joined(separator: ", ") + "."
        do {
            let results = try await privileged.runAsRoot(steps.map(\.step), reason: reason)
            var failures: [String: String] = [:]
            for (index, pair) in steps.enumerated() {
                let result = index < results.count ? results[index] : CommandResult(status: 1, errorOutput: "No answer from the administrator command.")
                if result.status != 0, failures[pair.command.rawValue] == nil {
                    failures[pair.command.rawValue] = Self.describe(result, step: pair.step)
                }
            }
            for command in admin {
                try Task.checkCancellation()
                if let failure = failures[command.rawValue] {
                    try await finish(command, .failed(failure))
                } else {
                    let rest = command.steps.filter { !$0.needsAdmin }
                    try await finish(command, rest.isEmpty ? .done : try await runPlain(rest))
                }
            }
        } catch PrivilegedError.cancelled {
            for command in admin { try await finish(command, .skipped(Self.cancelledReason)) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            for command in admin { try await finish(command, .failed(error.localizedDescription)) }
        }
        return outcomes
    }

    /// Runs steps that need no password. The first one that fails ends the task.
    private func runPlain(_ steps: [CommandStep]) async throws -> MaintenanceOutcome {
        for step in steps {
            let result: CommandResult
            do {
                result = try await commands.run(step.executable, step.arguments, timeout: Self.stepTimeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .failed(error.localizedDescription)
            }
            if result.status != 0 { return .failed(Self.describe(result, step: step)) }
        }
        return .done
    }

    /// The first line the program printed to its error output, or what it said otherwise.
    static func describe(_ result: CommandResult, step: CommandStep) -> String {
        for text in [result.errorOutput, result.output] {
            if let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
                return line
            }
        }
        return "\(URL(filePath: step.executable).lastPathComponent) failed with status \(result.status)."
    }

    private static func entry(for command: MaintenanceCommand, outcome: MaintenanceOutcome, runID: UUID) -> LogEntry {
        let (result, detail): (LogEntry.Outcome, String) = switch outcome {
        case .done: (.done, "Done")
        case .failed(let reason): (.failed, reason)
        case .skipped(let reason): (.skipped, reason)
        }
        return LogEntry(
            kind: .maintenance, path: "task:\(command.rawValue)", bytes: 0, outcome: result,
            detail: detail, runID: runID, source: source
        )
    }
}
