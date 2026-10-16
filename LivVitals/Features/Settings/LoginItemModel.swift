import Observation

/// The "Open Liv Vitals at login" switch. The truth is what macOS reports, read again whenever it may have changed.
@Observable
final class LoginItemModel {
    private(set) var status: LoginItemStatus
    private(set) var errorMessage: String?

    @ObservationIgnored private let controller: any LoginItemControlling

    init(controller: any LoginItemControlling) {
        self.controller = controller
        status = controller.status
    }

    /// On means registered; waiting for approval counts as on, so the switch does not jump back.
    var isOn: Bool { status != .disabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = controller.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            try controller.setEnabled(enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        controller.openSystemSettings()
    }
}
