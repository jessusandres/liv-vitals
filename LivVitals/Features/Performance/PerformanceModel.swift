import LivCore
import Observation
import SwiftUI

/// Runs the selected maintenance tasks through a `MaintenanceRunning` service and follows them as they go.
@Observable
final class PerformanceModel {
    enum Phase { case ready, running, done }

    enum Status: Equatable {
        case waiting, running, finished
        case failed(String)
        /// Did not run; the reason says why (the password dialog was cancelled).
        case skipped(String)
    }

    let tasks: [MaintenanceTask]
    private(set) var phase: Phase = .ready
    private(set) var selection: Set<String>
    private(set) var status: [String: Status] = [:]

    /// Read when the user runs the tasks, so a change in Settings applies to the next run.
    @ObservationIgnored var options: () -> MaintenanceOptions = { MaintenanceOptions() }
    @ObservationIgnored private let runner: any MaintenanceRunning
    @ObservationIgnored private var work: Task<Void, Never>?

    init(runner: any MaintenanceRunning) {
        self.runner = runner
        tasks = runner.tasks
        selection = Set(runner.tasks.filter(\.isSelectedByDefault).map(\.id))
    }

    var selectedTasks: [MaintenanceTask] { tasks.filter { selection.contains($0.id) } }

    /// How many of the selected tasks will ask for the password.
    var adminTaskCount: Int { selectedTasks.filter(\.requiresAdmin).count }

    func toggle(_ task: MaintenanceTask) {
        guard phase == .ready else { return }
        if selection.contains(task.id) { selection.remove(task.id) } else { selection.insert(task.id) }
    }

    func run() {
        let queue = selectedTasks
        guard !queue.isEmpty, phase == .ready else { return }
        status = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, Status.waiting) })
        withMotion { phase = .running }
        let options = options()
        // Events arrive in order, from whatever thread the service runs on.
        let (events, continuation) = AsyncStream.makeStream(of: MaintenanceEvent.self)
        work = Task {
            let follower = Task { for await event in events { apply(event) } }
            do {
                let outcomes = try await runner.run(queue, options: options, onEvent: { continuation.yield($0) })
                continuation.finish()
                await follower.value
                // The result is the record; the events were only the live view of it.
                for (id, outcome) in outcomes { apply(.finished(id, outcome)) }
            } catch is CancellationError {
                continuation.finish()
                return
            } catch {
                continuation.finish()
                await follower.value
                for task in queue where status[task.id] == .waiting || status[task.id] == .running {
                    withMotion { status[task.id] = .failed(error.localizedDescription) }
                }
            }
            withMotion(.spring) { phase = .done }
        }
    }

    func reset() {
        work?.cancel()
        status = [:]
        withMotion { phase = .ready }
    }

    private func apply(_ event: MaintenanceEvent) {
        withMotion {
            switch event {
            case .started(let id):
                status[id] = .running
            case .finished(let id, .done):
                status[id] = .finished
            case .finished(let id, .failed(let reason)):
                status[id] = .failed(reason)
            case .finished(let id, .skipped(let reason)):
                status[id] = .skipped(reason)
            }
        }
    }
}
