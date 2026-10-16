import Darwin
import Foundation

/// Detects the Full Disk Access permission by trying to open a file that only it unlocks.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// None of the probe files could settle the question (for example, none exists on this Mac).
        case undetermined
    }

    public enum ProbeResult: Sendable, Equatable {
        case readable
        /// `EPERM`: the privacy system refused, which is what a missing grant looks like.
        case notPermitted
        case missing
        /// Any other error, such as plain file permissions. It says nothing about Full Disk Access.
        case inconclusive
    }

    /// The Privacy & Security pane where the user turns the permission on.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Tries each protected file in turn; the first conclusive answer wins.
    public static func check(home: URL, probe: (URL) -> ProbeResult = openForReading) -> Status {
        let candidates = [
            URL(filePath: "/Library/Application Support/com.apple.TCC/TCC.db"),
            home.appending(path: "Library/Safari/Bookmarks.plist"),
        ]
        for url in candidates {
            switch probe(url) {
            case .readable: return .granted
            case .notPermitted: return .denied
            case .missing, .inconclusive: continue
            }
        }
        return .undetermined
    }

    /// Opens the file read-only and closes it at once. Its contents are never read.
    public static func openForReading(_ url: URL) -> ProbeResult {
        let descriptor = open(url.path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .readable
        }
        switch errno {
        case EPERM: return .notPermitted
        case ENOENT, ENOTDIR: return .missing
        default: return .inconclusive
        }
    }
}
