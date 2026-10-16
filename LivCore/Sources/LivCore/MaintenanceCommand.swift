import Foundation

/// One program run with fixed arguments. Nothing in a step depends on data: the whole list is closed.
public struct CommandStep: Sendable, Hashable {
    /// Absolute path of the program.
    public let executable: String
    public let arguments: [String]
    public let needsAdmin: Bool

    public init(_ executable: String, _ arguments: [String] = [], needsAdmin: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.needsAdmin = needsAdmin
    }

    /// The command as a person would type it, for the log and the confirmation sheet.
    public var display: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// The maintenance tasks of the Performance module and the exact commands each one runs.
///
/// This enum is the only source of commands: the sudoers rule is generated from the steps that need
/// administrator rights, so the rule allows exactly what the app runs and nothing else.
public enum MaintenanceCommand: String, CaseIterable, Sendable {
    case dns, launchservices, quicklook, spotlight, icons, purge

    /// `lsregister` lives inside a framework; its path is fixed.
    public static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    public var task: MaintenanceTask {
        switch self {
        case .dns:
            MaintenanceTask(
                id: rawValue, title: "Flush DNS Cache",
                summary: "Fixes websites that fail to load after network changes.",
                requiresAdmin: requiresAdmin, isSelectedByDefault: true
            )
        case .launchservices:
            MaintenanceTask(
                id: rawValue, title: "Rebuild Launch Services",
                summary: "Repairs duplicate entries in the Open With menu.",
                requiresAdmin: requiresAdmin, isSelectedByDefault: false
            )
        case .quicklook:
            MaintenanceTask(
                id: rawValue, title: "Reset Quick Look Cache",
                summary: "Fixes missing or outdated file previews.",
                requiresAdmin: requiresAdmin, isSelectedByDefault: true
            )
        case .spotlight:
            MaintenanceTask(
                id: rawValue, title: "Reindex Spotlight",
                summary: "Rebuilds search results. Takes a while to finish in the background.",
                requiresAdmin: requiresAdmin, isSelectedByDefault: false
            )
        case .icons:
            MaintenanceTask(
                id: rawValue, title: "Rebuild Icon Cache",
                summary: "Fixes blank or wrong app icons. Restarts the Dock.",
                requiresAdmin: requiresAdmin, isSelectedByDefault: false
            )
        case .purge:
            MaintenanceTask(
                id: rawValue, title: "Free Inactive Memory",
                summary: "Releases cached memory that apps no longer use.",
                requiresAdmin: requiresAdmin, isSelectedByDefault: false
            )
        }
    }

    public var steps: [CommandStep] {
        switch self {
        case .dns:
            [
                CommandStep("/usr/bin/dscacheutil", ["-flushcache"], needsAdmin: true),
                CommandStep("/usr/bin/killall", ["-HUP", "mDNSResponder"], needsAdmin: true),
            ]
        case .launchservices:
            // `-kill` no longer exists; `-gc` compacts the database and `-r` registers every domain again.
            [
                CommandStep(Self.lsregister, ["-gc"]),
                CommandStep(Self.lsregister, ["-r", "-all", "local,system,user"]),
            ]
        case .quicklook:
            [
                CommandStep("/usr/bin/qlmanage", ["-r", "cache"]),
                CommandStep("/usr/bin/qlmanage", ["-r"]),
            ]
        case .spotlight:
            [CommandStep("/usr/bin/mdutil", ["-E", "/"], needsAdmin: true)]
        case .icons:
            // The folder is fixed and owned by `_iconservices`; the Dock redraws every icon after it restarts.
            [
                CommandStep("/bin/rm", ["-rf", "/Library/Caches/com.apple.iconservices.store"], needsAdmin: true),
                CommandStep("/usr/bin/killall", ["Dock"]),
            ]
        case .purge:
            [CommandStep("/usr/sbin/purge", needsAdmin: true)]
        }
    }

    /// True when any step needs administrator rights.
    public var requiresAdmin: Bool { steps.contains(where: \.needsAdmin) }

    /// Every step that needs administrator rights, in the order the tasks are listed.
    public static var adminSteps: [CommandStep] {
        allCases.flatMap(\.steps).filter(\.needsAdmin)
    }
}
