import AppKit
import LivCore
import Observation

/// Whether the app has Full Disk Access, kept fresh whenever the app comes to the front
/// (the user usually grants it in System Settings and comes straight back).
@Observable
final class PermissionsModel {
    private(set) var status: FullDiskAccess.Status = .undetermined

    @ObservationIgnored private let provider: any PermissionProviding
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    init(
        provider: any PermissionProviding,
        settings: AppSettings,
        notificationCenter: NotificationCenter = .default,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.provider = provider
        self.settings = settings
        self.openURL = openURL
        refresh()
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        status = provider.fullDiskAccess()
    }

    /// Only a definite refusal asks the user; an undetermined state is not worth a prompt.
    var shouldShowOnboarding: Bool {
        status == .denied && !settings.hasCompletedOnboarding
    }

    var statusTitle: String {
        switch status {
        case .granted: String(localized: "Granted")
        case .denied: String(localized: "Not granted")
        case .undetermined: String(localized: "Unknown")
        }
    }

    var statusSymbol: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .undetermined: "questionmark.circle"
        }
    }

    func openSettings() {
        openURL(FullDiskAccess.settingsURL)
    }

    /// Where macOS lists the apps allowed to change other apps. There is no way to ask whether Liv Vitals is in it.
    static let appManagementURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!

    func openAppManagementSettings() {
        openURL(Self.appManagementURL)
    }

    func dismissOnboarding() {
        settings.hasCompletedOnboarding = true
    }
}
