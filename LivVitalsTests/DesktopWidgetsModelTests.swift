import Foundation
import LivWidgetsUI
import Testing
@testable import LivVitals

/// A stand-in for `WidgetCenter`: it answers with a fixed set and counts the reloads. Never touches the real desktop.
private final class FakeWidgetInstallations: WidgetInstallationReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: Set<String>?
    private var reloadCount = 0

    init(kinds: Set<String>?) { self.kinds = kinds }

    var reloads: Int { lock.withLock { reloadCount } }
    func set(_ kinds: Set<String>?) { lock.withLock { self.kinds = kinds } }
    func installedKinds() async -> Set<String>? { lock.withLock { kinds } }
    func reloadAll() { lock.withLock { reloadCount += 1 } }
}

@MainActor
struct DesktopWidgetsModelTests {
    @Test func everyWidgetIsUnknownUntilMacOSAnswers() {
        let model = DesktopWidgetsModel(reporter: FakeWidgetInstallations(kinds: [WidgetKind.storage.widgetID]))
        #expect(WidgetKind.allCases.allSatisfy { model.placement(of: $0) == .unknown })
    }

    @Test func refreshingTheStatusMarksOnlyTheAddedWidgets() async {
        let model = DesktopWidgetsModel(reporter: FakeWidgetInstallations(kinds: [WidgetKind.storage.widgetID]))
        await model.refreshStatus()
        #expect(model.placement(of: .storage) == .added)
        #expect(model.placement(of: .batteryHealth) == .notAdded)
        #expect(model.placement(of: .device) == .notAdded)
    }

    @Test func aFailedAnswerGoesBackToUnknown() async {
        let fake = FakeWidgetInstallations(kinds: [WidgetKind.device.widgetID])
        let model = DesktopWidgetsModel(reporter: fake)
        await model.refreshStatus()
        #expect(model.placement(of: .device) == .added)
        fake.set(nil)
        await model.refreshStatus()
        #expect(model.placement(of: .device) == .unknown)
    }

    @Test func refreshWidgetsReloadsOnceAndReadsTheStatusAgain() async {
        let fake = FakeWidgetInstallations(kinds: [])
        let model = DesktopWidgetsModel(reporter: fake)
        await model.refreshStatus()
        fake.set([WidgetKind.batteryHealth.widgetID])
        await model.refreshWidgets()
        #expect(fake.reloads == 1)
        #expect(model.placement(of: .batteryHealth) == .added)
    }

    @Test func theMockServicesNeverAskTheRealWidgetCenter() async {
        let store = AppStore(services: .mock)
        await store.desktopWidgets.refreshWidgets()
        #expect(store.desktopWidgets.installed == nil)
    }
}
