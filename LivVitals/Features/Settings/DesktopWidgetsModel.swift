import Foundation
import LivWidgetsUI
import Observation

/// Settings › Desktop Widgets: which of the kept widgets the user has added, and the "Refresh widgets" button.
/// A widget cannot be added from the app; the user does it from Edit Widgets, so this only reports and refreshes.
@MainActor
@Observable
final class DesktopWidgetsModel {
    /// The widget kinds macOS reports as added; nil until it answers, or when it cannot say.
    private(set) var installed: Set<String>?

    @ObservationIgnored private let reporter: any WidgetInstallationReporting

    init(reporter: any WidgetInstallationReporting) {
        self.reporter = reporter
    }

    func placement(of kind: WidgetKind) -> WidgetPlacement {
        WidgetPlacement.of(kind, installed: installed)
    }

    /// Asks macOS which widgets are added right now.
    func refreshStatus() async {
        installed = await reporter.installedKinds()
    }

    /// Asks macOS to reload every widget's timeline, then reads the status again.
    func refreshWidgets() async {
        reporter.reloadAll()
        await refreshStatus()
    }
}
