import Foundation
import LivCore

// The only file that asks for administrator rights. Everything here runs a closed list of fixed programs:
// no path, label or text ever becomes part of a script's code. What a script needs is passed as parameters of
// its handler and quoted inside it (`quoted form of`).

nonisolated enum PrivilegedError: Error, Equatable, LocalizedError {
    /// The user dismissed the password dialog.
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: String(localized: "The password was not entered.")
        case .failed(let reason): reason
        }
    }
}

nonisolated protocol PrivilegedRunning: Sendable {
    /// Runs the steps as root: with `sudo -n` when the rule allows them, otherwise through one password dialog.
    /// One result per step, in order.
    @concurrent func runAsRoot(_ steps: [CommandStep], reason: String) async throws -> [CommandResult]

    /// Moves each item to the user's Trash as root and returns where each ended up. One dialog for all.
    @concurrent func moveToTrashAsRoot(_ urls: [URL], trash: URL) async throws -> [URL: Result<URL, PrivilegedError>]

    /// Moves each item back from the user's Trash as root. One dialog for all. The result is keyed by `from`.
    @concurrent func restoreAsRoot(_ moves: [(from: URL, to: URL)]) async throws -> [URL: Result<Void, PrivilegedError>]

    /// Stops launchd jobs: `system/<label>` as root, `gui/<uid>/<label>` as the user. The value for each
    /// target is nil when it is stopped or was not loaded, or why it could not be stopped.
    @concurrent func bootout(_ jobs: [LaunchJobTarget]) async throws -> [String: String?]

    @concurrent func installRule(_ contents: String) async throws
    @concurrent func removeRule() async throws

    /// The rule file exists and `sudo` accepts one of its commands without a password.
    @concurrent func isRuleInstalled() async -> Bool
}

/// Runs commands as root behind one password dialog. A seam, so nothing else in the app touches AppleScript.
nonisolated protocol AdminDialogRunning: Sendable {
    /// Each command is a program followed by its arguments. One result per command, in order.
    @concurrent func runAsRoot(_ commands: [[String]], reason: String) async throws -> [CommandResult]
}

// MARK: - The dialog

/// Asks macOS for the password with AppleScript running inside this process. Inside one process macOS does not
/// ask again for a few minutes, so a run with several steps shows a single dialog.
nonisolated struct AppleScriptAdminDialog: AdminDialogRunning {
    /// A fixed script. Its handler takes a list of commands, each a list of strings, and runs each one with every
    /// word quoted. Nothing is concatenated into the code; cancelling the dialog (error -128) is passed on.
    static let source = """
    on runsteps(commands)
        set outcomes to {}
        repeat with commandParts in commands
            set shellLine to ""
            repeat with part in (contents of commandParts)
                set shellLine to shellLine & (quoted form of (contents of part)) & " "
            end repeat
            try
                set output to do shell script shellLine with administrator privileges
                set end of outcomes to {0, output}
            on error errText number errCode
                if errCode is -128 then error number -128
                set end of outcomes to {errCode, errText}
            end try
        end repeat
        return outcomes
    end runsteps
    """

    /// The script text. Always `source` in the app; a check of the Apple event plumbing can run a variant that asks
    /// for no rights.
    let scriptSource: String

    init(scriptSource: String = AppleScriptAdminDialog.source) {
        self.scriptSource = scriptSource
    }

    @concurrent func runAsRoot(_ commands: [[String]], reason: String) async throws -> [CommandResult] {
        guard !commands.isEmpty else { return [] }
        // NSAppleScript is used on the main thread.
        let source = scriptSource
        return try await MainActor.run { try Self.execute(commands, source: source) }
    }

    @MainActor
    private static func execute(_ commands: [[String]], source: String) throws -> [CommandResult] {
        guard let script = NSAppleScript(source: source) else { throw PrivilegedError.failed("The script could not be prepared.") }

        let list = NSAppleEventDescriptor.list()
        for (index, command) in commands.enumerated() {
            let parts = NSAppleEventDescriptor.list()
            for (partIndex, part) in command.enumerated() {
                parts.insert(NSAppleEventDescriptor(string: part), at: partIndex + 1)
            }
            list.insert(parts, at: index + 1)
        }
        let parameters = NSAppleEventDescriptor.list()
        parameters.insert(list, at: 1)

        // A call to the handler `runsteps` of the script, with the commands as its only parameter.
        let event = NSAppleEventDescriptor(
            eventClass: code("ascr"), eventID: code("psbr"),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: -1, transactionID: 0
        )
        event.setParam(NSAppleEventDescriptor(string: "runsteps"), forKeyword: code("snam"))
        event.setParam(parameters, forKeyword: code("----"))

        var errorInfo: NSDictionary?
        let result = script.executeAppleEvent(event, error: &errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -128 { throw PrivilegedError.cancelled }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "The administrator command failed."
            throw PrivilegedError.failed(message)
        }

        var results: [CommandResult] = []
        for index in 1...max(result.numberOfItems, 1) where index <= result.numberOfItems {
            guard let item = result.atIndex(index) else { continue }
            let status = item.atIndex(1)?.int32Value ?? 1
            let text = item.atIndex(2)?.stringValue ?? ""
            results.append(status == 0 ? CommandResult(status: 0, output: text) : CommandResult(status: status, errorOutput: text))
        }
        return results
    }

    /// A four-character code as the number Apple events use.
    private static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

// MARK: - The runner

nonisolated struct SystemPrivilegedRunner: PrivilegedRunning {
    /// Chooses a free name inside the Trash (adding " 2", " 3"…), refuses a symlink, and prints where the item went.
    /// `$1` is the item and `$2` the Trash folder; both arrive as parameters.
    static let moveToTrashScript = """
    [ -L "$1" ] && exit 3
    [ -e "$1" ] || exit 4
    b=$(/usr/bin/basename "$1"); d="$2/$b"; n=2
    while [ -e "$d" ]; do d="$2/$b $n"; n=$((n+1)); done
    /bin/mv -n -- "$1" "$d" || exit 5
    printf '%s' "$d"
    """

    /// Puts an item back: refuses a symlink, a missing source and an occupied destination, and never overwrites.
    /// `$1` is the item in the Trash and `$2` where it goes; both arrive as parameters.
    static let restoreScript = """
    [ -L "$1" ] && exit 3
    [ -e "$1" ] || exit 4
    [ -e "$2" ] && exit 5
    /bin/mv -n -- "$1" "$2" || exit 6
    """

    /// Checks the rule with `visudo` before installing it. `$1` is the temporary file with the rule.
    static let installRuleScript = "/usr/sbin/visudo -cf \"$1\" && /usr/bin/install -m 0440 -o root -g wheel \"$1\" \(SudoersRule.path)"

    static let rulePath = SudoersRule.path
    /// A command of the rule, used to ask `sudo` whether it works without a password.
    static let probeCommand = "/usr/sbin/purge"

    let commands: any CommandRunning
    let dialog: any AdminDialogRunning
    let remover: any FileRemoving
    /// Whether the rule file exists. `stat` works even though the file itself cannot be read.
    let ruleFileExists: @Sendable () -> Bool
    let tempFolder: URL

    init(
        commands: any CommandRunning = ProcessCommandRunner(),
        dialog: any AdminDialogRunning = AppleScriptAdminDialog(),
        remover: any FileRemoving = SystemFileRemover(),
        ruleFileExists: @escaping @Sendable () -> Bool = {
            var status = stat()
            return stat(SystemPrivilegedRunner.rulePath, &status) == 0
        },
        tempFolder: URL = FileManager.default.temporaryDirectory
    ) {
        self.commands = commands
        self.dialog = dialog
        self.remover = remover
        self.ruleFileExists = ruleFileExists
        self.tempFolder = tempFolder
    }

    // MARK: Rule

    @concurrent func isRuleInstalled() async -> Bool {
        guard ruleFileExists() else { return false }
        let probe = try? await commands.run("/usr/bin/sudo", ["-n", "-l", Self.probeCommand], timeout: .seconds(10))
        return probe?.status == 0
    }

    @concurrent func installRule(_ contents: String) async throws {
        let file = tempFolder.appending(path: "livvitals-sudoers-\(UUID().uuidString)", directoryHint: .notDirectory)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        defer { try? remover.delete(file) }

        let results = try await dialog.runAsRoot(
            [["/bin/sh", "-c", Self.installRuleScript, "sh", file.path]],
            reason: "Liv Vitals wants to allow its maintenance tasks without asking for your password."
        )
        guard results.first?.status == 0 else {
            throw PrivilegedError.failed(Self.firstLine(of: results.first?.errorOutput) ?? "The rule could not be installed.")
        }
        guard await isRuleInstalled() else {
            throw PrivilegedError.failed("The rule was installed, but sudo still asks for a password.")
        }
    }

    @concurrent func removeRule() async throws {
        let results = try await dialog.runAsRoot(
            [["/bin/rm", "-f", Self.rulePath]],
            reason: "Liv Vitals wants to remove the rule that allows its tasks without a password."
        )
        guard results.first?.status == 0 else {
            throw PrivilegedError.failed(Self.firstLine(of: results.first?.errorOutput) ?? "The rule could not be removed.")
        }
    }

    // MARK: Running

    @concurrent func runAsRoot(_ steps: [CommandStep], reason: String) async throws -> [CommandResult] {
        guard !steps.isEmpty else { return [] }
        guard await isRuleInstalled() else {
            return try await dialog.runAsRoot(steps.map(Self.argv), reason: reason)
        }

        // The rule allows exactly these commands; anything sudo still refuses goes through the dialog.
        var results: [CommandResult] = []
        var refused: [Int] = []
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            let result = try await commands.run("/usr/bin/sudo", ["-n"] + Self.argv(step), timeout: .seconds(600))
            if result.status != 0, result.errorOutput.hasPrefix("sudo:") { refused.append(index) }
            results.append(result)
        }
        guard !refused.isEmpty else { return results }
        let again = try await dialog.runAsRoot(refused.map { Self.argv(steps[$0]) }, reason: reason)
        for (offset, index) in refused.enumerated() where offset < again.count { results[index] = again[offset] }
        return results
    }

    @concurrent func moveToTrashAsRoot(_ urls: [URL], trash: URL) async throws -> [URL: Result<URL, PrivilegedError>] {
        guard !urls.isEmpty else { return [:] }
        let results = try await dialog.runAsRoot(
            urls.map { ["/bin/sh", "-c", Self.moveToTrashScript, "sh", $0.path, trash.path] },
            reason: "Liv Vitals wants to move apps and their system files to the Trash."
        )
        var outcome: [URL: Result<URL, PrivilegedError>] = [:]
        for (index, url) in urls.enumerated() {
            guard index < results.count else {
                outcome[url] = .failure(.failed("No answer from the administrator command."))
                continue
            }
            let result = results[index]
            if result.status == 0 {
                outcome[url] = .success(URL(filePath: result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else {
                outcome[url] = .failure(.failed(Self.moveFailure(status: result.status, text: result.errorOutput)))
            }
        }
        return outcome
    }

    @concurrent func restoreAsRoot(_ moves: [(from: URL, to: URL)]) async throws -> [URL: Result<Void, PrivilegedError>] {
        guard !moves.isEmpty else { return [:] }
        let results = try await dialog.runAsRoot(
            moves.map { ["/bin/sh", "-c", Self.restoreScript, "sh", $0.from.path, $0.to.path] },
            reason: "Liv Vitals wants to put apps and their system files back."
        )
        var outcome: [URL: Result<Void, PrivilegedError>] = [:]
        for (index, move) in moves.enumerated() {
            guard index < results.count else {
                outcome[move.from] = .failure(.failed("No answer from the administrator command."))
                continue
            }
            let result = results[index]
            outcome[move.from] = result.status == 0
                ? .success(())
                : .failure(.failed(Self.restoreFailure(status: result.status, text: result.errorOutput)))
        }
        return outcome
    }

    @concurrent func bootout(_ jobs: [LaunchJobTarget]) async throws -> [String: String?] {
        var outcome: [String: String?] = [:]
        var system: [LaunchJobTarget] = []
        for job in jobs {
            switch job.domain {
            case .user:
                try Task.checkCancellation()
                let result = try await commands.run("/bin/launchctl", ["bootout", job.specifier], timeout: .seconds(30))
                outcome[job.specifier] = Self.bootoutFailure(result)
            case .system:
                system.append(job)
            }
        }
        guard !system.isEmpty else { return outcome }
        let results = try await dialog.runAsRoot(
            system.map { ["/bin/launchctl", "bootout", $0.specifier] },
            reason: "Liv Vitals wants to stop the services of the apps it removes."
        )
        for (index, job) in system.enumerated() {
            outcome[job.specifier] = index < results.count ? Self.bootoutFailure(results[index]) : "No answer from the administrator command."
        }
        return outcome
    }

    // MARK: Helpers

    private static func argv(_ step: CommandStep) -> [String] { [step.executable] + step.arguments }

    private static func firstLine(of text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// nil when the job is stopped or was not loaded in the first place, which is not an error.
    static func bootoutFailure(_ result: CommandResult) -> String? {
        if result.status == 0 { return nil }
        let text = result.errorOutput + result.output
        if result.status == 3 || result.status == 113 || text.localizedCaseInsensitiveContains("No such process")
            || text.localizedCaseInsensitiveContains("Could not find service") { return nil }
        return firstLine(of: text) ?? "launchctl failed with status \(result.status)."
    }

    static func restoreFailure(status: Int32, text: String) -> String {
        switch status {
        case 3: "It is a symlink, so it was not put back."
        case 4: "No longer in the Trash."
        case 5: "Something else is at the original location."
        default: firstLine(of: text) ?? "It could not be put back."
        }
    }

    static func moveFailure(status: Int32, text: String) -> String {
        switch status {
        case 3: "It is a symlink, so it was not moved."
        case 4: "No longer exists"
        default: firstLine(of: text) ?? "It could not be moved to the Trash."
        }
    }
}
