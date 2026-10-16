import Foundation
import LivCore
import os
import Testing
@testable import LivVitals

/// The events of a run, collected from a `@Sendable` callback.
nonisolated final class EventLog: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [MaintenanceEvent]())

    var all: [MaintenanceEvent] { lock.withLock { $0 } }

    func add(_ event: MaintenanceEvent) {
        lock.withLock { $0.append(event) }
    }
}

/// The real maintenance service with a command runner and a privileged runner that only record.
@MainActor
struct LiveMaintenanceTests {
    private struct World {
        let commands: FakeCommands
        let privileged: FakePrivileged
        let log: OperationLog
        let service: LiveMaintenance
        let events = EventLog()

        init(
            _ tmp: TemporaryDirectory,
            commands: FakeCommands = FakeCommands(),
            privileged: FakePrivileged = FakePrivileged()
        ) {
            self.commands = commands
            self.privileged = privileged
            log = OperationLog(fileURL: tmp.path("Support/operations.jsonl"))
            service = LiveMaintenance(commands: commands, privileged: privileged, log: log)
        }

        func run(_ ids: String..., dryRun: Bool = false) async throws -> [String: MaintenanceOutcome] {
            let events = events
            return try await service.run(
                ids.compactMap { MaintenanceCommand(rawValue: $0)?.task },
                options: MaintenanceOptions(dryRun: dryRun),
                onEvent: { events.add($0) }
            )
        }
    }

    // MARK: Without a password

    @Test func tasksWithoutAdminOnlyUseTheCommandRunner() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            let outcomes = try await world.run("quicklook", "launchservices")

            #expect(outcomes == ["quicklook": .done, "launchservices": .done])
            #expect(world.commands.calls == [
                "/usr/bin/qlmanage -r cache",
                "/usr/bin/qlmanage -r",
                "\(MaintenanceCommand.lsregister) -gc",
                "\(MaintenanceCommand.lsregister) -r -all local,system,user",
            ])
            #expect(world.privileged.rootRuns.isEmpty)
        }
    }

    @Test func everyResultIsLoggedAsAMaintenanceLineWithItsSource() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            _ = try await world.run("quicklook")

            let entries = try await world.log.entries()
            #expect(entries.count == 1)
            #expect(entries[0].kind == .maintenance && entries[0].path == "task:quicklook")
            #expect(entries[0].outcome == .done && entries[0].detail == "Done")
            #expect(entries[0].source == "Performance" && entries[0].runID != nil)
        }
    }

    @Test func aFailingStepFailsItsTaskWithTheFirstLineOfItsErrorAndTheOthersStillRun() async throws {
        try await TemporaryDirectory.use { tmp in
            let commands = FakeCommands(results: ["/usr/bin/qlmanage": CommandResult(status: 1, errorOutput: "boom\nmore details\n")])
            let world = World(tmp, commands: commands)
            let outcomes = try await world.run("quicklook", "launchservices")

            #expect(outcomes["quicklook"] == .failed("boom"))
            #expect(outcomes["launchservices"] == .done)
            // The first failing step ends its task: the second qlmanage step never ran.
            #expect(commands.calls.filter { $0.hasPrefix("/usr/bin/qlmanage") } == ["/usr/bin/qlmanage -r cache"])
            let entries = try await world.log.entries()
            #expect(entries.first { $0.path == "task:quicklook" }?.outcome == .failed)
            #expect(entries.first { $0.path == "task:quicklook" }?.detail == "boom")
        }
    }

    @Test func aProgramThatCannotRunFailsItsTaskInsteadOfTheWholeRun() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp, commands: FakeCommands(throwing: ["/usr/bin/qlmanage"]))
            let outcomes = try await world.run("quicklook", "launchservices")
            #expect(outcomes["quicklook"] == .failed("Something went wrong."))
            #expect(outcomes["launchservices"] == .done)
        }
    }

    @Test func aFailureWithNoOutputNamesTheProgramAndTheStatus() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp, commands: FakeCommands(results: ["/usr/bin/qlmanage": CommandResult(status: 7)]))
            let outcomes = try await world.run("quicklook")
            #expect(outcomes["quicklook"] == .failed("qlmanage failed with status 7."))
        }
    }

    // MARK: With a password

    @Test func allAdminStepsGoToOneCallAndTheOthersToTheCommandRunner() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            let outcomes = try await world.run("dns", "quicklook", "purge")

            #expect(outcomes == ["dns": .done, "quicklook": .done, "purge": .done])
            #expect(world.privileged.rootRuns.count == 1)
            #expect(world.privileged.rootRuns[0] == [
                CommandStep("/usr/bin/dscacheutil", ["-flushcache"], needsAdmin: true),
                CommandStep("/usr/bin/killall", ["-HUP", "mDNSResponder"], needsAdmin: true),
                CommandStep("/usr/sbin/purge", needsAdmin: true),
            ])
            #expect(world.commands.calls == ["/usr/bin/qlmanage -r cache", "/usr/bin/qlmanage -r"])
        }
    }

    @Test func aDismissedPasswordDialogSkipsTheAdminTasksAndNothingElse() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp, privileged: FakePrivileged(cancels: true))
            let outcomes = try await world.run("dns", "quicklook", "icons")

            #expect(outcomes["dns"] == .skipped(LiveMaintenance.cancelledReason))
            #expect(outcomes["icons"] == .skipped(LiveMaintenance.cancelledReason))
            #expect(outcomes["quicklook"] == .done)
            // Cancelled means skipped, not failed, and the Dock was not restarted without its cache step.
            #expect(!world.commands.calls.contains("/usr/bin/killall Dock"))
            let entries = try await world.log.entries()
            #expect(entries.first { $0.path == "task:dns" }?.outcome == .skipped)
            #expect(entries.first { $0.path == "task:quicklook" }?.outcome == .done)
        }
    }

    @Test func aFailingAdminStepFailsOnlyItsOwnTask() async throws {
        try await TemporaryDirectory.use { tmp in
            let privileged = FakePrivileged(stepResults: ["/usr/sbin/purge": CommandResult(status: 1, errorOutput: "purge: not permitted\n")])
            let world = World(tmp, privileged: privileged)
            let outcomes = try await world.run("dns", "purge")
            #expect(outcomes["dns"] == .done)
            #expect(outcomes["purge"] == .failed("purge: not permitted"))
        }
    }

    @Test func anErrorFromThePrivilegedRunnerFailsTheAdminTasksWithItsMessage() async throws {
        struct Broken: PrivilegedRunning {
            func runAsRoot(_ steps: [CommandStep], reason: String) async throws -> [CommandResult] { throw PrivilegedError.failed("The script could not be prepared.") }
            func moveToTrashAsRoot(_ urls: [URL], trash: URL) async throws -> [URL: Result<URL, PrivilegedError>] { [:] }
            func restoreAsRoot(_ moves: [(from: URL, to: URL)]) async throws -> [URL: Result<Void, PrivilegedError>] { [:] }
            func bootout(_ jobs: [LaunchJobTarget]) async throws -> [String: String?] { [:] }
            func installRule(_ contents: String) async throws {}
            func removeRule() async throws {}
            func isRuleInstalled() async -> Bool { false }
        }
        try await TemporaryDirectory.use { tmp in
            let log = OperationLog(fileURL: tmp.path("Support/operations.jsonl"))
            let service = LiveMaintenance(commands: FakeCommands(), privileged: Broken(), log: log)
            let outcomes = try await service.run([MaintenanceCommand.dns.task], options: MaintenanceOptions(), onEvent: { _ in })
            #expect(outcomes["dns"] == .failed("The script could not be prepared."))
        }
    }

    @Test func theDockRestartRunsAfterItsTasksCacheIsGone() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            let outcomes = try await world.run("icons")
            #expect(outcomes["icons"] == .done)
            #expect(world.privileged.rootRuns == [[CommandStep("/bin/rm", ["-rf", "/Library/Caches/com.apple.iconservices.store"], needsAdmin: true)]])
            #expect(world.commands.calls == ["/usr/bin/killall Dock"])
        }
    }

    @Test func ifTheCacheStepFailsTheDockIsLeftAlone() async throws {
        try await TemporaryDirectory.use { tmp in
            let privileged = FakePrivileged(stepResults: ["/bin/rm": CommandResult(status: 1, errorOutput: "rm: Operation not permitted\n")])
            let world = World(tmp, privileged: privileged)
            let outcomes = try await world.run("icons")
            #expect(outcomes["icons"] == .failed("rm: Operation not permitted"))
            #expect(world.commands.calls.isEmpty)
        }
    }

    // MARK: Simulation, events, selection

    @Test func aSimulatedRunLogsWhatWouldRunAndRunsNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            let outcomes = try await world.run("dns", "quicklook", dryRun: true)

            #expect(outcomes == ["dns": .done, "quicklook": .done])
            #expect(world.commands.calls.isEmpty)
            #expect(world.privileged.rootRuns.isEmpty && world.privileged.order.isEmpty)
            let entries = try await world.log.entries()
            #expect(entries.count == 2)
            #expect(entries.allSatisfy { $0.kind == .maintenance && $0.outcome == .planned })
            #expect(entries.first { $0.path == "task:quicklook" }?.detail == "Would run: /usr/bin/qlmanage -r cache; /usr/bin/qlmanage -r")
        }
    }

    @Test func eventsReportEachTaskStartingAndFinishingInOrder() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            _ = try await world.run("quicklook", "dns")
            #expect(world.events.all == [
                .started("quicklook"), .finished("quicklook", .done),
                .started("dns"), .finished("dns", .done),
            ])
        }
    }

    @Test func theServiceListsTheSixTasksAndIsNotSimulated() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            #expect(world.service.tasks.map(\.id) == ["dns", "launchservices", "quicklook", "spotlight", "icons", "purge"])
            #expect(!world.service.isSimulated)
        }
    }

    @Test func anUnknownTaskIsIgnoredAndATaskListedTwiceRunsOnce() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            let unknown = MaintenanceTask(id: "rm-everything", title: "x", summary: "", requiresAdmin: false)
            let outcomes = try await world.service.run(
                [unknown, MaintenanceCommand.quicklook.task, MaintenanceCommand.quicklook.task],
                options: MaintenanceOptions(), onEvent: { _ in }
            )
            #expect(outcomes == ["quicklook": .done])
            #expect(world.commands.calls == ["/usr/bin/qlmanage -r cache", "/usr/bin/qlmanage -r"])
        }
    }
}
