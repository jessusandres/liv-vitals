import Foundation

/// What a launchd job plist says about itself.
public struct LaunchJob: Sendable, Hashable {
    public let label: String?
    /// The program it runs: `Program`, or the first of `ProgramArguments`.
    public let program: String?

    /// nil when the file is not a readable property list.
    public static func read(at url: URL) -> LaunchJob? {
        guard let data = try? Data(contentsOf: url),
              let job = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        let program = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first
        return LaunchJob(label: job["Label"] as? String, program: program)
    }
}

/// A launchd job that can be stopped: its label and where it lives (`system/<label>` or `gui/<uid>/<label>`).
public struct LaunchJobTarget: Sendable, Hashable {
    public enum Domain: Sendable, Hashable {
        case system
        case user(uid: UInt32)
    }

    public let label: String
    public let domain: Domain

    /// nil when the label has anything beyond letters, digits and `. _ + -`, or starts with `-`: it goes to
    /// `launchctl` as an argument and must never be read as an option or contain a separator.
    public init?(label: String, domain: Domain) {
        guard !label.isEmpty, !label.hasPrefix("-"), label.utf8.count <= 255,
              label.unicodeScalars.allSatisfy({ scalar in
                  ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                      || ".+_-".unicodeScalars.contains(scalar)
              })
        else { return nil }
        self.label = label
        self.domain = domain
    }

    /// The `launchctl` service target.
    public var specifier: String {
        switch domain {
        case .system: "system/\(label)"
        case .user(let uid): "gui/\(uid)/\(label)"
        }
    }
}
