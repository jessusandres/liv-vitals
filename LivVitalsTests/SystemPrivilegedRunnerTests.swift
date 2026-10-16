import Foundation
import LivCore
import Testing
@testable import LivVitals

/// The runner that decides between `sudo -n` and the password dialog, with both replaced by recorders.
@MainActor
struct SystemPrivilegedRunnerTests {
    private struct World {
        let commands: FakeCommands
        let dialog: FakeAdminDialog
        let remover = RecordingRemover()
        let runner: SystemPrivilegedRunner

        init(
            _ tmp: TemporaryDirectory,
            ruleFileExists: Bool = false,
            commands: FakeCommands = FakeCommands(),
            dialog: FakeAdminDialog = FakeAdminDialog()
        ) {
            self.commands = commands
            self.dialog = dialog
            runner = SystemPrivilegedRunner(
                commands: commands, dialog: dialog, remover: remover,
                ruleFileExists: { ruleFileExists }, tempFolder: tmp.url
            )
        }
    }

    private let purge = CommandStep("/usr/sbin/purge", needsAdmin: true)
    private let flush = CommandStep("/usr/bin/dscacheutil", ["-flushcache"], needsAdmin: true)

    // MARK: The scripts

    @Test func theDialogScriptCompilesAndHoldsNoDataOfItsOwn() {
        let script = NSAppleScript(source: AppleScriptAdminDialog.source)
        var error: NSDictionary?
        // Compiling runs nothing and asks for nothing.
        #expect(script?.compileAndReturnError(&error) == true)
        #expect(error == nil)
        // Every word goes through `quoted form of`, and the only place that asks for rights is this one line.
        #expect(AppleScriptAdminDialog.source.contains("quoted form of"))
        #expect(AppleScriptAdminDialog.source.components(separatedBy: "administrator privileges").count == 2)
    }

    @Test func theTrashScriptRefusesSymlinksAndTakesItsPathsAsParameters() {
        let script = SystemPrivilegedRunner.moveToTrashScript
        #expect(script.contains("[ -L \"$1\" ] && exit 3"))
        #expect(script.contains("/bin/mv -n -- \"$1\" \"$d\""))
        #expect(script.contains("\"$2/$b $n\""))
        #expect(!script.contains("/Users") && !script.contains("/Applications"))
    }

    @Test func theRuleIsCheckedWithVisudoBeforeItIsInstalled() {
        let script = SystemPrivilegedRunner.installRuleScript
        #expect(script == "/usr/sbin/visudo -cf \"$1\" && /usr/bin/install -m 0440 -o root -g wheel \"$1\" /etc/sudoers.d/livvitals")
    }

    // MARK: Whether the rule works

    @Test func theRuleCountsOnlyWhenTheFileExistsAndSudoAcceptsItWithoutAPassword() async throws {
        try await TemporaryDirectory.use { tmp in
            let missing = World(tmp, ruleFileExists: false)
            #expect(await !missing.runner.isRuleInstalled())
            #expect(missing.commands.calls.isEmpty)

            let working = World(tmp, ruleFileExists: true)
            #expect(await working.runner.isRuleInstalled())
            #expect(working.commands.calls == ["/usr/bin/sudo -n -l /usr/sbin/purge"])

            let broken = World(tmp, ruleFileExists: true, commands: FakeCommands(results: ["/usr/bin/sudo": CommandResult(status: 1, errorOutput: "sudo: a password is required\n")]))
            #expect(await !broken.runner.isRuleInstalled())
        }
    }

    // MARK: Running as root

    @Test func withoutTheRuleAllStepsShareOneDialog() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            let results = try await world.runner.runAsRoot([flush, purge], reason: "x")

            #expect(results.map(\.status) == [0, 0])
            #expect(world.dialog.dialogs == [[["/usr/bin/dscacheutil", "-flushcache"], ["/usr/sbin/purge"]]])
            #expect(world.commands.calls.isEmpty)
        }
    }

    @Test func withTheRuleEachStepRunsThroughSudoWithoutADialog() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp, ruleFileExists: true)
            let results = try await world.runner.runAsRoot([flush, purge], reason: "x")

            #expect(results.map(\.status) == [0, 0])
            #expect(world.commands.calls == [
                "/usr/bin/sudo -n -l /usr/sbin/purge",
                "/usr/bin/sudo -n /usr/bin/dscacheutil -flushcache",
                "/usr/bin/sudo -n /usr/sbin/purge",
            ])
            #expect(world.dialog.dialogs.isEmpty)
        }
    }

    @Test func aStepSudoStillRefusesFallsBackToTheDialogAndTheRestStayAsTheyWere() async throws {
        try await TemporaryDirectory.use { tmp in
            // sudo answers the probe and the first step, but refuses the second.
            let dialog = FakeAdminDialog()
            let runner = SystemPrivilegedRunner(
                commands: SelectiveCommands(base: FakeCommands(), refuse: ["/usr/sbin/purge"]),
                dialog: dialog, remover: RecordingRemover(), ruleFileExists: { true }, tempFolder: tmp.url
            )
            let results = try await runner.runAsRoot([flush, purge], reason: "x")
            #expect(results.map(\.status) == [0, 0])
            #expect(dialog.dialogs == [[["/usr/sbin/purge"]]])
        }
    }

    @Test func aDismissedDialogIsPassedOn() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp, dialog: FakeAdminDialog(cancels: true))
            await #expect(throws: PrivilegedError.cancelled) {
                _ = try await world.runner.runAsRoot([purge], reason: "x")
            }
        }
    }

    // MARK: Trash

    @Test func theTrashMoveIsOneDialogWithTheScriptAndTheTwoPathsAsParameters() async throws {
        try await TemporaryDirectory.use { tmp in
            let dialog = FakeAdminDialog(answer: { command in
                CommandResult(status: 0, output: "/Users/x/.Trash/" + URL(filePath: command[4]).lastPathComponent)
            })
            let world = World(tmp, dialog: dialog)
            let one = URL(filePath: "/Applications/One.app")
            let two = URL(filePath: "/Library/LaunchDaemons/two.plist")
            let trash = URL(filePath: "/Users/x/.Trash", directoryHint: .isDirectory)

            let moved = try await world.runner.moveToTrashAsRoot([one, two], trash: trash)

            #expect(dialog.dialogs.count == 1)
            let commands = dialog.dialogs[0]
            #expect(commands == [
                ["/bin/sh", "-c", SystemPrivilegedRunner.moveToTrashScript, "sh", "/Applications/One.app", "/Users/x/.Trash"],
                ["/bin/sh", "-c", SystemPrivilegedRunner.moveToTrashScript, "sh", "/Library/LaunchDaemons/two.plist", "/Users/x/.Trash"],
            ])
            #expect(try moved[one]?.get().path == "/Users/x/.Trash/One.app")
            #expect(try moved[two]?.get().path == "/Users/x/.Trash/two.plist")
        }
    }

    @Test func eachFailedMoveCarriesItsOwnReason() async throws {
        try await TemporaryDirectory.use { tmp in
            let dialog = FakeAdminDialog(answer: { command in
                switch command[4] {
                case "/a": CommandResult(status: 3)
                case "/b": CommandResult(status: 4)
                case "/c": CommandResult(status: 5, errorOutput: "mv: Operation not permitted\nmore")
                default: CommandResult(status: 0, output: "/t/ok")
                }
            })
            let world = World(tmp, dialog: dialog)
            let urls = ["/a", "/b", "/c", "/d"].map { URL(filePath: $0) }
            let moved = try await world.runner.moveToTrashAsRoot(urls, trash: URL(filePath: "/t", directoryHint: .isDirectory))

            func failure(_ url: URL) -> PrivilegedError? {
                if case .failure(let error)? = moved[url] { return error }
                return nil
            }
            #expect(failure(urls[0]) == .failed("It is a symlink, so it was not moved."))
            #expect(failure(urls[1]) == .failed("No longer exists"))
            #expect(failure(urls[2]) == .failed("mv: Operation not permitted"))
            #expect(failure(urls[3]) == nil)
        }
    }

    @Test func thePutBackIsOneDialogWithTheScriptAndTheTwoPathsAsParameters() async throws {
        try await TemporaryDirectory.use { tmp in
            let dialog = FakeAdminDialog(answer: { command in
                switch command[4] {
                case "/t/gone": CommandResult(status: 4)
                case "/t/link": CommandResult(status: 3)
                case "/t/taken": CommandResult(status: 5)
                case "/t/odd": CommandResult(status: 6, errorOutput: "mv: Operation not permitted\nmore")
                default: CommandResult(status: 0)
                }
            })
            let world = World(tmp, dialog: dialog)
            let moves = ["ok", "gone", "link", "taken", "odd"].map {
                (from: URL(filePath: "/t/\($0)"), to: URL(filePath: "/Applications/\($0).app"))
            }

            let outcome = try await world.runner.restoreAsRoot(moves)

            #expect(dialog.dialogs.count == 1)
            #expect(dialog.dialogs[0].first == ["/bin/sh", "-c", SystemPrivilegedRunner.restoreScript, "sh", "/t/ok", "/Applications/ok.app"])
            func failure(_ name: String) -> PrivilegedError? {
                if case .failure(let error)? = outcome[URL(filePath: "/t/\(name)")] { return error }
                return nil
            }
            #expect(failure("ok") == nil)
            #expect(failure("gone") == .failed("No longer in the Trash."))
            #expect(failure("link") == .failed("It is a symlink, so it was not put back."))
            #expect(failure("taken") == .failed("Something else is at the original location."))
            #expect(failure("odd") == .failed("mv: Operation not permitted"))
        }
    }

    @Test func theRestoreScriptNeverOverwritesOrFollowsASymlink() {
        let script = SystemPrivilegedRunner.restoreScript
        #expect(script.contains("[ -L \"$1\" ] && exit 3"))
        #expect(script.contains("[ -e \"$2\" ] && exit 5"))
        #expect(script.contains("/bin/mv -n -- \"$1\" \"$2\""))
        #expect(!script.contains("/Users") && !script.contains("/Applications"))
    }

    @Test func aRealRestoreScriptMovesAFileAndRefusesToOverwrite() async throws {
        try await TemporaryDirectory.use { tmp in
            let source = try tmp.file("trash/a.bin", bytes: 3)
            let taken = try tmp.file("home/taken.bin", bytes: 1)
            let free = tmp.path("home/a.bin")

            func run(_ from: URL, _ to: URL) throws -> Int32 {
                let process = Process()
                process.executableURL = URL(filePath: "/bin/sh")
                process.arguments = ["-c", SystemPrivilegedRunner.restoreScript, "sh", from.path, to.path]
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }
            #expect(try run(source, taken) == 5)
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(try run(source, free) == 0)
            #expect(FileManager.default.fileExists(atPath: free.path) && !FileManager.default.fileExists(atPath: source.path))
            #expect(try run(source, free) == 4)
        }
    }

    @Test func nothingToMoveShowsNoDialog() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            let moved = try await world.runner.moveToTrashAsRoot([], trash: URL(filePath: "/t"))
            #expect(moved.isEmpty)
            #expect(world.dialog.dialogs.isEmpty)
        }
    }

    // MARK: Services

    @Test func userServicesAreStoppedAsTheUserAndSystemOnesInTheDialog() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            let jobs = [
                LaunchJobTarget(label: "com.example.agent", domain: .user(uid: 501))!,
                LaunchJobTarget(label: "com.example.daemon", domain: .system)!,
            ]
            let result = try await world.runner.bootout(jobs)

            #expect(world.commands.calls == ["/bin/launchctl bootout gui/501/com.example.agent"])
            #expect(world.dialog.dialogs == [[["/bin/launchctl", "bootout", "system/com.example.daemon"]]])
            #expect(result.count == 2)
            #expect(result["gui/501/com.example.agent"] == .some(nil))
            #expect(result["system/com.example.daemon"] == .some(nil))
        }
    }

    @Test func aServiceThatWasNotLoadedIsNotAnErrorButARealFailureIs() async throws {
        #expect(SystemPrivilegedRunner.bootoutFailure(CommandResult(status: 0)) == nil)
        #expect(SystemPrivilegedRunner.bootoutFailure(CommandResult(status: 3, errorOutput: "Boot-out failed: 3: No such process")) == nil)
        #expect(SystemPrivilegedRunner.bootoutFailure(CommandResult(status: 113, errorOutput: "Could not find service")) == nil)
        #expect(SystemPrivilegedRunner.bootoutFailure(CommandResult(status: 5, errorOutput: "Boot-out failed: 5: Input/output error\nx")) == "Boot-out failed: 5: Input/output error")
        #expect(SystemPrivilegedRunner.bootoutFailure(CommandResult(status: 9)) == "launchctl failed with status 9.")
    }

    @Test func withOnlyUserServicesNoDialogAppears() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            _ = try await world.runner.bootout([LaunchJobTarget(label: "com.example.agent", domain: .user(uid: 501))!])
            #expect(world.dialog.dialogs.isEmpty)
        }
    }

    // MARK: The rule

    @Test func installingWritesTheRuleToATemporaryFileChecksItAndDeletesTheFile() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp, ruleFileExists: true)
            try await world.runner.installRule("rule text\n")

            let command = try #require(world.dialog.dialogs.first?.first)
            #expect(world.dialog.dialogs.count == 1)
            #expect(Array(command.prefix(4)) == ["/bin/sh", "-c", SystemPrivilegedRunner.installRuleScript, "sh"])
            let temporary = try #require(command.last)
            #expect(temporary.hasPrefix(tmp.url.path) && URL(filePath: temporary).lastPathComponent.hasPrefix("livvitals-sudoers-"))
            // The file held the rule while the dialog ran, and is removed afterwards.
            #expect(world.remover.deleted.map(\.path) == [temporary])
        }
    }

    @Test func theTemporaryFileHoldsExactlyTheRule() async throws {
        try await TemporaryDirectory.use { tmp in
            final class Seen: @unchecked Sendable { var text: String? }
            let seen = Seen()
            let dialog = FakeAdminDialog(answer: { command in
                seen.text = try? String(contentsOfFile: command.last ?? "", encoding: .utf8)
                return CommandResult(status: 0)
            })
            let world = World(tmp, ruleFileExists: true, dialog: dialog)
            try await world.runner.installRule("asger ALL=(root) NOPASSWD: /usr/sbin/purge \"\"\n")
            #expect(seen.text == "asger ALL=(root) NOPASSWD: /usr/sbin/purge \"\"\n")
        }
    }

    @Test func aRuleThatSudoDoesNotAcceptAfterwardsIsReported() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp, ruleFileExists: false)
            await #expect(throws: PrivilegedError.failed("The rule was installed, but sudo still asks for a password.")) {
                try await world.runner.installRule("rule\n")
            }
        }
    }

    @Test func aFailedInstallCarriesTheFirstLineOfTheError() async throws {
        try await TemporaryDirectory.use { tmp in
            let dialog = FakeAdminDialog(answer: { _ in CommandResult(status: 1, errorOutput: "visudo: syntax error near line 3\nmore") })
            let world = World(tmp, dialog: dialog)
            await #expect(throws: PrivilegedError.failed("visudo: syntax error near line 3")) {
                try await world.runner.installRule("rule\n")
            }
            #expect(world.remover.deleted.count == 1)
        }
    }

    @Test func removingTheRuleIsOneFixedCommandInOneDialog() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = World(tmp)
            try await world.runner.removeRule()
            #expect(world.dialog.dialogs == [[["/bin/rm", "-f", "/etc/sudoers.d/livvitals"]]])
        }
    }
}

/// Answers like `sudo -n` that refuses some programs: its own error, with the `sudo:` prefix.
nonisolated struct SelectiveCommands: CommandRunning {
    let base: FakeCommands
    let refuse: Set<String>

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        let result = try await base.run(executable, arguments, timeout: timeout)
        guard executable == "/usr/bin/sudo", let program = arguments.first(where: { $0.hasPrefix("/") && $0 != "-n" }) else { return result }
        if arguments.contains("-l") { return result }
        return refuse.contains(program) ? CommandResult(status: 1, errorOutput: "sudo: a password is required\n") : result
    }
}
