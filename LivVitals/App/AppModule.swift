import SwiftUI

enum AppModule: String, CaseIterable, Identifiable {
    case smartCare
    case cleanup
    case devProjects
    case installers
    case applications
    case performance
    case spaceLens
    case monitor
    case history
    case settings

    var id: Self { self }

    enum Section: String, CaseIterable {
        case overview = ""
        case cleanup = "Cleanup"
        case apps = "Applications"
        case speed = "Speed"
        case files = "Files"
        case activity = "Activity"
    }

    var section: Section? {
        switch self {
        case .smartCare: .overview
        case .cleanup, .devProjects, .installers: .cleanup
        case .applications: .apps
        case .performance: .speed
        case .spaceLens: .files
        case .monitor, .history: .activity
        case .settings: nil
        }
    }

    var title: String {
        switch self {
        case .smartCare: String(localized: "Smart Care")
        case .cleanup: String(localized: "Cleanup")
        case .devProjects: String(localized: "Dev Projects")
        case .installers: String(localized: "Installers")
        case .applications: String(localized: "Uninstaller")
        case .performance: String(localized: "Performance")
        case .spaceLens: String(localized: "Space Lens")
        case .monitor: String(localized: "Monitor")
        case .history: String(localized: "History")
        case .settings: String(localized: "Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .smartCare: "sparkles"
        case .cleanup: "trash.circle"
        case .devProjects: "hammer"
        case .installers: "shippingbox"
        case .applications: "square.grid.2x2"
        case .performance: "gauge.with.dots.needle.67percent"
        case .spaceLens: "circle.circle"
        case .monitor: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    var tagline: String {
        switch self {
        case .smartCare: String(localized: "Scan your whole Mac in one pass and clean it with a single click.")
        case .cleanup: String(localized: "Remove caches, logs and developer junk your Mac no longer needs.")
        case .devProjects: String(localized: "Reclaim space from build folders and dependencies in old projects.")
        case .installers: String(localized: "Find disk images and installers you already used.")
        case .applications: String(localized: "Remove apps completely, including the files they leave behind.")
        case .performance: String(localized: "Run maintenance tasks that keep macOS responsive.")
        case .spaceLens: String(localized: "See what takes up space and drill into any folder.")
        case .monitor: String(localized: "Live view of CPU, memory, disk, network and battery.")
        case .history: String(localized: "Every cleanup you ran and how much space it freed.")
        case .settings: String(localized: "Protected paths, scan locations and cleaning behavior.")
        }
    }

    var highlights: [String] {
        switch self {
        case .smartCare: [String(localized: "Cleanup, installers and dev projects together"), String(localized: "Nothing is removed until you review it")]
        case .cleanup: [String(localized: "User caches and logs"), String(localized: "Xcode, npm and pnpm caches"), String(localized: "Leftovers of deleted apps")]
        case .devProjects: [String(localized: "node_modules, target, .build and dist"), String(localized: "Projects edited this week stay unchecked")]
        case .installers: [String(localized: "DMG, PKG, ISO and XIP files"), String(localized: "Downloads, Desktop and Homebrew cache")]
        case .applications: [String(localized: "Apps sorted by size and last use"), String(localized: "Preferences, caches and containers included")]
        default: []
        }
    }
}
