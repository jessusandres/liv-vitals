/// Groups of cleanable items shown together in a results list.
public enum CleanupCategory: String, CaseIterable, Hashable, Sendable, Codable {
    case userCaches
    case logs
    case trash
    case browserData
    case developerTools
    case applications
    case appLeftovers
    case installers
    case projectArtifacts
    case largeFiles

    public var title: String {
        switch self {
        case .userCaches: "User Caches"
        case .logs: "Logs"
        case .trash: "Trash"
        case .browserData: "Browser Data"
        case .developerTools: "Developer Tools"
        case .applications: "Applications"
        case .appLeftovers: "App Leftovers"
        case .installers: "Installers"
        case .projectArtifacts: "Project Artifacts"
        case .largeFiles: "Large Files"
        }
    }
}
