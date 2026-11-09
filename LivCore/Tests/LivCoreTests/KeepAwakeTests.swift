import Foundation
import Testing
@testable import LivCore

struct KeepAwakeTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func state(pause: Bool = false) -> KeepAwakeState {
        KeepAwakeState(pauseWhileLocked: pause)
    }

    // MARK: Sessions

    @Test func aTimedSessionExpiresExactlyAtItsEnd() {
        var s = state()
        s.start(.fifteenMinutes, now: t0)
        #expect(s.wantsAssertions)
        s.tick(now: t0.addingTimeInterval(15 * 60 - 1))
        #expect(s.wantsAssertions)
        s.tick(now: t0.addingTimeInterval(15 * 60))
        #expect(!s.wantsAssertions)
        #expect(!s.isOn)
    }

    @Test func anIndefiniteSessionNeverExpires() {
        var s = state()
        s.start(.indefinite, now: t0)
        s.tick(now: t0.addingTimeInterval(10 * 365 * 86_400))
        #expect(s.wantsAssertions)
        #expect(s.remaining(now: t0) == nil)
        #expect(s.nextDeadline(now: t0) == nil)
    }

    @Test func stopClearsTheSession() {
        var s = state()
        s.start(.oneHour, now: t0)
        s.stop()
        #expect(!s.wantsAssertions)
        #expect(s.remaining(now: t0) == nil)
    }

    @Test func durationsMapToSeconds() {
        #expect(KeepAwakeDuration.oneHour.seconds == 3_600)
        #expect(KeepAwakeDuration.eightHours.seconds == 28_800)
        #expect(KeepAwakeDuration.indefinite.seconds == nil)
    }

    // MARK: Automation

    @Test func noConditionSelectedNeverHolds() {
        let settings = KeepAwakeSettings()
        #expect(!KeepAwakeAutomation.holds(settings, externalDisplay: true, onAC: true, runningBundleIDs: ["a"]))
    }

    @Test func applicationsOnWithAnEmptyListNeverHolds() {
        var settings = KeepAwakeSettings()
        settings.applications = true
        #expect(!KeepAwakeAutomation.holds(settings, externalDisplay: false, onAC: false, runningBundleIDs: ["a"]))
    }

    @Test func anyOneConditionHolds() {
        var settings = KeepAwakeSettings()
        settings.externalDisplay = true
        settings.power = true
        settings.applications = true
        settings.bundleIDs = ["com.apple.dt.Xcode"]
        #expect(!KeepAwakeAutomation.holds(settings, externalDisplay: false, onAC: false, runningBundleIDs: ["x"]))
        #expect(KeepAwakeAutomation.holds(settings, externalDisplay: true, onAC: false, runningBundleIDs: []))
        #expect(KeepAwakeAutomation.holds(settings, externalDisplay: false, onAC: true, runningBundleIDs: []))
        #expect(KeepAwakeAutomation.holds(settings, externalDisplay: false, onAC: false, runningBundleIDs: ["com.apple.dt.Xcode"]))
    }

    @Test func aConditionThatIsNotSelectedIsIgnored() {
        var settings = KeepAwakeSettings()
        settings.power = true
        #expect(!KeepAwakeAutomation.holds(settings, externalDisplay: true, onAC: false, runningBundleIDs: []))
    }

    @Test func aManualSessionOverlappingAutomationLastsUntilBothAreOff() {
        var s = state()
        s.setAutomation(holds: true)
        s.start(.fifteenMinutes, now: t0)
        s.tick(now: t0.addingTimeInterval(15 * 60))
        #expect(s.wantsAssertions)
        s.setAutomation(holds: false)
        #expect(!s.wantsAssertions)

        var t = state()
        t.start(.oneHour, now: t0)
        t.setAutomation(holds: true)
        t.setAutomation(holds: false)
        #expect(t.wantsAssertions)
    }

    @Test func stoppingWhileAutomationHoldsSuppressesItUntilTheConditionsClear() {
        var s = state()
        s.setAutomation(holds: true)
        #expect(s.wantsAssertions)
        s.stop()
        #expect(!s.wantsAssertions)
        #expect(s.isSuppressed)
        s.setAutomation(holds: true)
        #expect(!s.wantsAssertions)
        s.setAutomation(holds: false)
        #expect(!s.isSuppressed)
        s.setAutomation(holds: true)
        #expect(s.wantsAssertions)
    }

    @Test func startingAgainLiftsTheSuppression() {
        var s = state()
        s.setAutomation(holds: true)
        s.stop()
        s.start(.indefinite, now: t0)
        #expect(s.wantsAssertions)
        #expect(!s.isSuppressed)
    }

    // MARK: Pause while locked

    @Test func lockingFreezesTheRemainingTimeAndUnlockingResumesIt() {
        var s = state(pause: true)
        s.start(.oneHour, now: t0)
        let lockedAt = t0.addingTimeInterval(20 * 60)
        s.setLocked(true, now: lockedAt)
        #expect(!s.wantsAssertions)
        #expect(s.isOn)
        #expect(abs(s.remaining(now: lockedAt.addingTimeInterval(5 * 3_600))! - 40 * 60) < 0.001)
        s.tick(now: lockedAt.addingTimeInterval(5 * 3_600))
        #expect(s.isOn)
        let unlockedAt = lockedAt.addingTimeInterval(2 * 3_600)
        s.setLocked(false, now: unlockedAt)
        #expect(s.wantsAssertions)
        #expect(abs(s.remaining(now: unlockedAt)! - 40 * 60) < 0.001)
        s.tick(now: unlockedAt.addingTimeInterval(40 * 60))
        #expect(!s.isOn)
    }

    @Test func lockingWithoutTheOptionChangesNothing() {
        var s = state(pause: false)
        s.start(.oneHour, now: t0)
        s.setLocked(true, now: t0.addingTimeInterval(60))
        #expect(s.wantsAssertions)
        #expect(abs(s.remaining(now: t0.addingTimeInterval(120))! - 3_480) < 0.001)
    }

    @Test func theLockPauseAppliesToAutomationToo() {
        var s = state(pause: true)
        s.setAutomation(holds: true)
        s.setLocked(true, now: t0)
        #expect(!s.wantsAssertions)
        s.setLocked(false, now: t0)
        #expect(s.wantsAssertions)
    }

    @Test func turningTheOptionOnWhileLockedPausesAtOnce() {
        var s = state(pause: false)
        s.start(.oneHour, now: t0)
        s.setLocked(true, now: t0)
        s.setPauseWhileLocked(true, now: t0.addingTimeInterval(600))
        #expect(!s.wantsAssertions)
        #expect(abs(s.remaining(now: t0.addingTimeInterval(9_000))! - 3_000) < 0.001)
    }

    // MARK: Scheduling and label

    @Test func nextDeadlineIsTheMinuteBoundaryOrTheEnd() {
        var s = state()
        #expect(s.nextDeadline(now: t0) == nil)
        s.start(.fifteenMinutes, now: t0)
        // 14:59 left shows "15m" until it drops to 14:00.
        let now = t0.addingTimeInterval(1)
        #expect(s.nextDeadline(now: now) == t0.addingTimeInterval(60))
        // On an exact minute the next change is one minute later.
        #expect(s.nextDeadline(now: t0) == t0.addingTimeInterval(60))
        // In the last minute the end is the deadline.
        #expect(s.nextDeadline(now: t0.addingTimeInterval(15 * 60 - 30)) == t0.addingTimeInterval(15 * 60))
    }

    @Test func nextDeadlineIsNilWhilePaused() {
        var s = state(pause: true)
        s.start(.oneHour, now: t0)
        s.setLocked(true, now: t0)
        #expect(s.nextDeadline(now: t0) == nil)
    }

    @Test func compactRemainingRoundsUp() {
        #expect(KeepAwakeState.compactRemaining(14 * 60 + 59) == "15m")
        #expect(KeepAwakeState.compactRemaining(61 * 60) == "2h")
        #expect(KeepAwakeState.compactRemaining(10) == "1m")
        #expect(KeepAwakeState.compactRemaining(3_600) == "1h")
        #expect(KeepAwakeState.compactRemaining(0) == "1m")
    }

    @Test func labelShowsTimeForTimedAndInfinityForIndefinite() {
        var s = state()
        #expect(s.label(now: t0) == nil)
        s.start(.thirtyMinutes, now: t0)
        #expect(s.label(now: t0) == "30m")
        s.start(.indefinite, now: t0)
        #expect(s.label(now: t0) == "∞")
        s.stop()
        s.setAutomation(holds: true)
        #expect(s.label(now: t0) == nil)
    }

    // MARK: Settings decoding

    @Test func settingsDecodeLeniently() throws {
        let json = #"{"defaultDuration":7,"power":true,"bundleIDs":["a"]}"#
        let settings = try JSONDecoder().decode(KeepAwakeSettings.self, from: Data(json.utf8))
        #expect(settings.defaultDuration == .oneHour)
        #expect(settings.power)
        #expect(settings.bundleIDs == ["a"])
        #expect(settings.showInMenuBar)
        #expect(!settings.pauseWhileLocked)
    }
}
