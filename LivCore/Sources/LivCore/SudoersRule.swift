import Foundation

/// The optional `sudoers` rule that lets Liv Vitals run its fixed administrator commands without a password.
///
/// This type only builds text; installing it is the job of the privileged runner in the app. The rule lists the
/// steps of `MaintenanceCommand` that need administrator rights, each with its exact arguments, so `sudo`
/// accepts nothing else. A command with no arguments ends in `""`: without it `sudo` would run it with any.
/// There are no wildcards anywhere.
public enum SudoersRule {
    public static let path = "/etc/sudoers.d/livvitals"

    /// A plain account name: lowercase letters, digits, `_` and `-`, starting with a letter or `_`.
    public static func isValidUser(_ user: String) -> Bool {
        guard user.utf8.count <= 32, let first = user.unicodeScalars.first else { return false }
        func isLower(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) }
        guard isLower(first) || first == "_" else { return false }
        return user.unicodeScalars.allSatisfy { isLower($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
    }

    /// nil when `user` is not a plain account name.
    public static func contents(for user: String) -> String? {
        guard isValidUser(user) else { return nil }
        var lines = [
            "# Installed by Liv Vitals. Remove it from Liv Vitals › Settings or delete this file.",
            "# It lets \(user) run these fixed commands as root without a password, and nothing else.",
        ]
        lines += rules(for: user)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The rule lines alone, one per administrator step.
    public static func rules(for user: String) -> [String] {
        MaintenanceCommand.adminSteps.map { step in
            let arguments = step.arguments.isEmpty ? "\"\"" : step.arguments.joined(separator: " ")
            return "\(user) ALL=(root) NOPASSWD: \(step.executable) \(arguments)"
        }
    }
}
