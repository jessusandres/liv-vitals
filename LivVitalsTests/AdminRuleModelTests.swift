import Foundation
import LivCore
import Testing
@testable import LivVitals

@MainActor
struct AdminRuleModelTests {
    @Test func theStateIsUnknownUntilItIsChecked() async {
        let model = AdminRuleModel(privileged: FakePrivileged(ruleInstalled: true), user: "asger")
        #expect(model.state == .unknown && !model.isInstalled)
        await model.refresh()
        #expect(model.state == .installed && model.isInstalled)

        let without = AdminRuleModel(privileged: FakePrivileged(), user: "asger")
        await without.refresh()
        #expect(without.state == .notInstalled)
    }

    @Test func installingSendsTheExactRuleForTheUserAndRefreshesTheState() async {
        let fake = FakePrivileged()
        let model = AdminRuleModel(privileged: fake, user: "asger")
        await model.refresh()

        await model.install()
        #expect(fake.installedRules == [SudoersRule.contents(for: "asger")!])
        #expect(model.state == .installed)
        #expect(model.errorMessage == nil && !model.isWorking)
    }

    @Test func anAccountNameThatIsNotPlainIsRefusedWithoutAskingForAnything() async {
        let fake = FakePrivileged()
        let model = AdminRuleModel(privileged: fake, user: "root;")
        #expect(model.ruleText == nil)

        await model.install()
        #expect(fake.installedRules.isEmpty && fake.order.isEmpty)
        #expect(model.errorMessage?.contains("not a plain account name") == true)
        #expect(!model.isInstalled)
    }

    @Test func aDismissedPasswordDialogIsNotAnError() async {
        let fake = FakePrivileged(cancels: true)
        let model = AdminRuleModel(privileged: fake, user: "asger")
        await model.install()
        #expect(model.errorMessage == nil)
        #expect(model.state == .notInstalled)
    }

    @Test func aFailedInstallShowsWhy() async {
        let fake = FakePrivileged(installFailure: .failed("The rule was installed, but sudo still asks for a password."))
        let model = AdminRuleModel(privileged: fake, user: "asger")
        await model.install()
        #expect(model.errorMessage == "The rule was installed, but sudo still asks for a password.")
        #expect(model.state == .notInstalled)
    }

    @Test func removingAsksTheRunnerAndRefreshesTheState() async {
        let fake = FakePrivileged(ruleInstalled: true)
        let model = AdminRuleModel(privileged: fake, user: "asger")
        await model.refresh()
        #expect(model.isInstalled)

        await model.remove()
        #expect(fake.removals == 1)
        #expect(model.state == .notInstalled)
    }

    @Test func theSheetListsTheCommandsTheRuleAllows() {
        let model = AdminRuleModel(privileged: FakePrivileged(), user: "asger")
        #expect(model.allowedCommands == [
            "/usr/bin/dscacheutil -flushcache",
            "/usr/bin/killall -HUP mDNSResponder",
            "/usr/bin/mdutil -E /",
            "/bin/rm -rf /Library/Caches/com.apple.iconservices.store",
            "/usr/sbin/purge",
        ])
    }

    @Test func theAppStoreSharesOneModelWithTheServiceItWasGiven() async {
        let fake = FakePrivileged(ruleInstalled: true)
        let store = AppStore(services: .fake(privileged: fake))
        await store.adminRule.refresh()
        #expect(store.adminRule.isInstalled)
        #expect(store.adminRule.user == NSUserName())
    }
}
