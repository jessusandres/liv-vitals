import Foundation
import Testing
@testable import LivCore

/// Only harmless programs: no test ever runs sudo, launchctl, killall, purge or mdutil.
struct CommandRunnerTests {
    private let runner = ProcessCommandRunner()

    @Test func outputIsCaptured() async throws {
        let result = try await runner.run("/bin/echo", ["hello", "world"], timeout: .seconds(5))
        #expect(result.status == 0)
        #expect(result.output == "hello world\n")
        #expect(result.errorOutput.isEmpty)
    }

    @Test func aFailingProgramReturnsItsStatusInsteadOfThrowing() async throws {
        let result = try await runner.run("/usr/bin/false", [], timeout: .seconds(5))
        #expect(result.status == 1)
    }

    @Test func errorOutputIsCapturedSeparately() async throws {
        let result = try await runner.run("/bin/ls", ["/definitely/not/here"], timeout: .seconds(5))
        #expect(result.status != 0)
        #expect(result.output.isEmpty)
        #expect(!result.errorOutput.isEmpty)
    }

    @Test func outputIsCappedAtSixtyFourKilobytes() async throws {
        let result = try await runner.run("/usr/bin/head", ["-c", "300000", "/dev/zero"], timeout: .seconds(10))
        #expect(result.status == 0)
        #expect(result.output.utf8.count == 64 * 1024)
    }

    @Test func aProgramThatTakesTooLongIsStopped() async throws {
        let started = ContinuousClock.now
        await #expect(throws: CommandError.timedOut("sleep")) {
            _ = try await runner.run("/bin/sleep", ["30"], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func cancellingTheTaskStopsTheProgram() async throws {
        let runner = self.runner
        let task = Task { try await runner.run("/bin/sleep", ["30"], timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aRelativeOrMissingProgramIsRefused() async throws {
        await #expect(throws: CommandError.notAbsolute("echo")) {
            _ = try await runner.run("echo", ["x"], timeout: .seconds(5))
        }
        await #expect(throws: CommandError.couldNotStart("nothing-here")) {
            _ = try await runner.run("/usr/bin/nothing-here", [], timeout: .seconds(5))
        }
    }

    @Test func theEnvironmentIsMinimal() async throws {
        let result = try await runner.run("/usr/bin/env", [], timeout: .seconds(5))
        let names = Set(result.output.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        #expect(names.isSuperset(of: ["PATH", "HOME", "LANG"]))
        #expect(names.count <= 6)
        #expect(result.output.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
    }

    @Test func aFinishedCommandReleasesItsTimeoutAndControl() async throws {
        final class Weak: @unchecked Sendable { weak var object: AnyObject? }
        let seen = Weak()
        // A long deadline: if the timeout work kept the control alive, it would still exist afterwards.
        _ = try await runner.run("/bin/echo", ["x"], timeout: .seconds(600), observing: { seen.object = $0 })
        for _ in 0..<50 where seen.object != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(seen.object == nil)
    }

    @Test func manyConcurrentCommandsWithLargeOutputOnBothPipesComplete() async throws {
        let runner = self.runner
        let script = "head -c 300000 /dev/zero; head -c 300000 /dev/zero >&2"
        let results = try await withThrowingTaskGroup(of: CommandResult.self) { group in
            for _ in 0..<40 { group.addTask { try await runner.run("/bin/sh", ["-c", script], timeout: .seconds(60)) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 40)
        #expect(results.allSatisfy { $0.status == 0 && $0.output.utf8.count == 64 * 1024 && $0.errorOutput.utf8.count == 64 * 1024 })
    }
}
