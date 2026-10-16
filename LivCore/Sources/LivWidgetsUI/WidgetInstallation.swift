import Foundation
import WidgetKit

/// Whether a widget is on a desktop or in Notification Center right now.
public enum WidgetPlacement: Equatable, Sendable {
    case added
    case notAdded
    /// macOS did not say (the call failed or has not answered yet).
    case unknown

    /// `installed` is the set of widget kinds macOS reports; nil when it could not say.
    public static func of(_ kind: WidgetKind, installed: Set<String>?) -> WidgetPlacement {
        guard let installed else { return .unknown }
        return installed.contains(kind.widgetID) ? .added : .notAdded
    }
}

/// What the app can ask WidgetKit. `WidgetCenter` answers only on the app side, so the extension never uses this. A protocol so
/// tests use a fake and never reach the real desktop.
public protocol WidgetInstallationReporting: Sendable {
    /// The `kind` of every widget of this app that is currently added; nil when macOS could not say.
    func installedKinds() async -> Set<String>?
    /// Asks macOS to refresh every widget of this app now (it still decides when).
    func reloadAll()
}

/// The real WidgetKit.
public struct SystemWidgetInstallations: WidgetInstallationReporting {
    public init() {}

    public func installedKinds() async -> Set<String>? {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                continuation.resume(returning: (try? result.get()).map { Set($0.map(\.kind)) })
            }
        }
    }

    public func reloadAll() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Stands in where WidgetKit must not be asked (previews, snapshots, hosted tests): it reports nothing and reloads nothing.
public struct UnavailableWidgetInstallations: WidgetInstallationReporting {
    public init() {}
    public func installedKinds() async -> Set<String>? { nil }
    public func reloadAll() {}
}
