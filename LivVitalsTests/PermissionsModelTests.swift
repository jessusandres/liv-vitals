import AppKit
import Foundation
import LivCore
import Testing
@testable import LivVitals

@MainActor
struct PermissionsModelTests {
    private func makeSettings() -> AppSettings {
        let home = URL(filePath: "/tmp/home")
        return AppSettings(store: SettingsStore(fileURL: nil, home: home), home: home)
    }

    private func makeModel(
        _ provider: FakePermissions,
        settings: AppSettings? = nil,
        center: NotificationCenter = NotificationCenter(),
        opened: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> PermissionsModel {
        PermissionsModel(provider: provider, settings: settings ?? makeSettings(), notificationCenter: center, openURL: opened)
    }

    @Test func statusIsReadAtCreationAndOnRefresh() {
        let provider = FakePermissions(.denied)
        let model = makeModel(provider)
        #expect(model.status == .denied)

        provider.set(.granted)
        #expect(model.status == .denied)
        model.refresh()
        #expect(model.status == .granted)
    }

    @Test func onboardingAppearsOnlyForADefiniteRefusalThatWasNotDismissed() {
        let settings = makeSettings()
        let provider = FakePermissions(.denied)
        let model = makeModel(provider, settings: settings)
        #expect(model.shouldShowOnboarding)

        model.dismissOnboarding()
        #expect(!model.shouldShowOnboarding)
        #expect(settings.hasCompletedOnboarding)

        let fresh = makeModel(FakePermissions(.granted))
        #expect(!fresh.shouldShowOnboarding)
        let unknown = makeModel(FakePermissions(.undetermined))
        #expect(!unknown.shouldShowOnboarding)
    }

    @Test func comingBackToTheAppChecksAgain() async {
        let provider = FakePermissions(.denied)
        let center = NotificationCenter()
        let model = makeModel(provider, center: center)
        #expect(model.status == .denied)

        provider.set(.granted)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await waitUntil { model.status == .granted })
    }

    @Test func openSettingsOpensTheFullDiskAccessPane() {
        var opened: [URL] = []
        let model = makeModel(FakePermissions(.denied), opened: { opened.append($0) })
        model.openSettings()
        #expect(opened == [FullDiskAccess.settingsURL])
    }

    @Test func statusTextMatchesTheState() {
        #expect(makeModel(FakePermissions(.granted)).statusTitle == "Granted")
        #expect(makeModel(FakePermissions(.denied)).statusTitle == "Not granted")
        #expect(makeModel(FakePermissions(.undetermined)).statusTitle == "Unknown")
    }

    @Test func openAppManagementOpensItsPane() {
        var opened: [URL] = []
        let model = makeModel(FakePermissions(.denied), opened: { opened.append($0) })
        model.openAppManagementSettings()
        #expect(opened == [PermissionsModel.appManagementURL])
    }
}
