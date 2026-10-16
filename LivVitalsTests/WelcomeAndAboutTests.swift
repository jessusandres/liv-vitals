import Foundation
import LivCore
import Testing
@testable import LivVitals

@MainActor
struct OnboardingModelTests {
    @Test func movesForwardAndBackAndStaysInsideTheSteps() {
        var finished = 0
        let model = OnboardingModel { finished += 1 }
        #expect(model.step == .welcome && model.isFirst)

        model.back()
        #expect(model.step == .welcome)

        model.next()
        model.next()
        #expect(model.step == .appManagement)
        model.back()
        #expect(model.step == .fullDiskAccess)
        #expect(finished == 0)
    }

    @Test func nextOnTheLastStepFinishes() {
        var finished = 0
        let model = OnboardingModel(step: .adminRule) { finished += 1 }
        #expect(model.isLast)
        model.next()
        #expect(finished == 1)
    }

    @Test func skipFinishesFromAnyStep() {
        var finished = 0
        let model = OnboardingModel(step: .appManagement) { finished += 1 }
        model.skip()
        #expect(finished == 1)
    }
}

@MainActor
struct WelcomeGuideTests {
    @Test func theFirstRunMarksTheGuideAsSeenOnlyWhenItEnds() {
        let store = AppStore(services: .fake(permissions: FakePermissions(.denied)))
        #expect(store.isWelcomeGuideVisible)
        #expect(!store.settings.hasCompletedOnboarding)

        store.closeWelcomeGuide()
        #expect(!store.isWelcomeGuideVisible)
        #expect(store.settings.hasCompletedOnboarding)
    }

    @Test func showWelcomeGuideReopensItWithoutTouchingTheFlag() {
        let store = AppStore(services: .fake(permissions: FakePermissions(.granted)))
        store.settings.hasCompletedOnboarding = true
        #expect(!store.isWelcomeGuideVisible)

        store.showWelcomeGuide()
        #expect(store.isWelcomeGuideVisible)
        #expect(store.settings.hasCompletedOnboarding)

        store.closeWelcomeGuide()
        #expect(!store.isWelcomeGuideVisible)
    }

    @Test func theAdminStepUsesTheSameModelAsSettings() async {
        let fake = FakePrivileged()
        let store = AppStore(services: .fake(privileged: fake))
        await store.adminRule.refresh()
        await store.adminRule.install()
        #expect(fake.installedRules.count == 1)
        #expect(store.adminRule.isInstalled)
    }
}

@MainActor
struct LoginItemModelTests {
    @Test func switchingOnAndOffFollowsTheSystem() {
        let item = MockLoginItem(.disabled)
        let model = LoginItemModel(controller: item)
        #expect(!model.isOn)

        model.setEnabled(true)
        #expect(model.isOn && item.status == .enabled)
        model.setEnabled(false)
        #expect(!model.isOn && item.status == .disabled)
    }

    @Test func waitingForApprovalCountsAsOnAndOffersLoginItems() {
        let item = MockLoginItem(.requiresApproval)
        let model = LoginItemModel(controller: item)
        #expect(model.isOn && model.needsApproval)

        model.openSystemSettings()
        #expect(item.settingsOpened == 1)
    }

    @Test func aChangeMadeInSystemSettingsIsPickedUpOnRefresh() {
        let item = MockLoginItem(.disabled)
        let model = LoginItemModel(controller: item)
        item.setStatus(.enabled)
        #expect(!model.isOn)
        model.refresh()
        #expect(model.isOn)
    }

    @Test func aFailureIsShownAndTheStateStaysAsMacOSReportsIt() {
        let model = LoginItemModel(controller: MockLoginItem(.disabled, failure: "Not allowed."))
        model.setEnabled(true)
        #expect(model.errorMessage == "Not allowed.")
        #expect(!model.isOn)
    }
}

struct AboutInfoTests {
    private func bundle(_ values: [String: Any]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appending(path: "liv-about-\(UUID().uuidString).bundle")
        let contents = root.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return try #require(Bundle(url: root))
    }

    @Test func versionAndBuildComeFromTheInjectedBundle() throws {
        let info = AboutInfo(bundle: try bundle([
            "CFBundleIdentifier": "test.about",
            "CFBundleDisplayName": "Liv Vitals",
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "42",
            "NSHumanReadableCopyright": "© Someone",
        ]))
        #expect(info.name == "Liv Vitals")
        #expect(info.versionLine == "Version 1.2 (42)")
        #expect(info.copyright == "© Someone")
    }

    @Test func missingValuesFallBackToReadableDefaults() throws {
        let info = AboutInfo(bundle: try bundle(["CFBundleIdentifier": "test.about"]))
        #expect(info.versionLine == "Version ? (?)")
        #expect(!info.copyright.isEmpty)
    }

    @Test func theLicenceListSaysThereAreNoThirdPartyLibraries() {
        #expect(AboutInfo.licenses.contains { $0.contains("no third-party") })
        #expect(AboutInfo.licenses.contains { $0.contains("Device Monitor") && $0.contains("author's own") })
    }
}
