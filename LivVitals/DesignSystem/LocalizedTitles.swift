import LivCore

// LivCore has no String Catalog, so the app names its categories and health levels itself.
extension CleanupCategory {
    var localizedTitle: String {
        switch self {
        case .userCaches: String(localized: "User Caches")
        case .logs: String(localized: "Logs")
        case .trash: String(localized: "Trash")
        case .browserData: String(localized: "Browser Data")
        case .developerTools: String(localized: "Developer Tools")
        case .applications: String(localized: "Applications")
        case .appLeftovers: String(localized: "App Leftovers")
        case .installers: String(localized: "Installers")
        case .projectArtifacts: String(localized: "Project Artifacts")
        case .largeFiles: String(localized: "Large Files")
        }
    }
}

extension HealthScore.Level {
    var localizedTitle: String {
        switch self {
        case .good: String(localized: "Good")
        case .fair: String(localized: "Fair")
        case .busy: String(localized: "Busy")
        }
    }
}

extension MetricKind {
    var localizedTitle: String {
        switch self {
        case .cpu: String(localized: "Processor")
        case .memory: String(localized: "Memory")
        case .gpu: String(localized: "GPU")
        case .disk: String(localized: "Disk")
        case .diskActivity: String(localized: "Disk Activity")
        case .network: String(localized: "Network")
        case .battery: String(localized: "Battery")
        case .temperature: String(localized: "Temperature")
        }
    }
}

extension IndicatorStyle {
    var localizedTitle: String {
        switch self {
        case .icon: String(localized: "Icon")
        case .number: String(localized: "Number")
        case .chart: String(localized: "Chart")
        case .bars: String(localized: "Bars")
        case .gauge: String(localized: "Gauge")
        case .speed: String(localized: "Speed")
        }
    }
}

extension IndicatorTint {
    var localizedTitle: String {
        switch self {
        case .system: String(localized: "Automatic")
        case .metric: String(localized: "Metric color")
        case .purple: String(localized: "Purple")
        case .blue: String(localized: "Blue")
        case .teal: String(localized: "Teal")
        case .pink: String(localized: "Pink")
        case .orange: String(localized: "Orange")
        }
    }
}
