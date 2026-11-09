import Foundation
import LivCore
import Testing
@testable import LivVitals

/// Keep awake with a fake assertion holder and a fake clock: nothing here holds a real assertion.
@MainActor
struct KeepAwakeModelTests {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000_000)
    }

    private func make(
        _ settings: KeepAwakeSettings = KeepAwakeSettings(),
        failure: String? = nil
    ) -> (model: KeepAwakeModel, holder: MockPowerAssertions, conditions: MockKeepAwakeConditions, clock: Clock) {
        let holder = MockPowerAssertions(failure: failure)
        let conditions = MockKeepAwakeConditions()
        let clock = Clock()
        let model = KeepAwakeModel(holder: holder, conditions: conditions, settings: settings, now: { clock.date })
        return (model, holder, conditions, clock)
    }

    @Test func turnOnAcquiresTheAssertionsAndTurnOffReleasesThem() {
        let (model, holder, _, _) = make()
        #expect(!holder.isHeld)
        model.turnOn()
        #expect(holder.isHeld)
        #expect(model.isOn)
        model.turnOff()
        #expect(!holder.isHeld)
        #expect(!model.isOn)
    }

    @Test func turnOnUsesTheDefaultDuration() {
        var settings = KeepAwakeSettings()
        settings.defaultDuration = .thirtyMinutes
        let (model, _, _, _) = make(settings)
        model.turnOn()
        #expect(model.labelText == "30m")
        #expect(model.sessionDuration == .thirtyMinutes)
    }

    @Test func aFailedAcquireSetsTheErrorAndLeavesKeepAwakeOff() {
        let (model, holder, _, _) = make(failure: "No power")
        model.turnOn()
        #expect(model.errorMessage == "No power")
        #expect(!model.isOn)
        #expect(!holder.isHeld)
    }

    @Test func aTimedSessionEndsWhenItsTimeIsUp() {
        let (model, holder, _, clock) = make()
        model.start(.fifteenMinutes)
        clock.date.addTimeInterval(15 * 60)
        model.refresh()
        #expect(!holder.isHeld)
        #expect(model.sessionDuration == nil)
    }

    @Test func lockingWithThePauseOptionReleasesAndUnlockingAcquiresAgain() {
        var settings = KeepAwakeSettings()
        settings.pauseWhileLocked = true
        let (model, holder, conditions, clock) = make(settings)
        #expect(conditions.attached.lock)
        model.start(.oneHour)
        conditions.isLocked = true
        conditions.fire()
        #expect(!holder.isHeld)
        #expect(model.isOn)
        clock.date.addTimeInterval(7_200)
        conditions.isLocked = false
        conditions.fire()
        #expect(holder.isHeld)
        #expect(model.labelText == "1h")
    }

    @Test func automationStartsAndStopsWithItsCondition() {
        var settings = KeepAwakeSettings()
        settings.power = true
        let (model, holder, conditions, _) = make(settings)
        #expect(conditions.attached.power)
        #expect(!holder.isHeld)
        conditions.isOnPowerAdapter = true
        conditions.fire()
        #expect(holder.isHeld)
        conditions.isOnPowerAdapter = false
        conditions.fire()
        #expect(!holder.isHeld)
        _ = model
    }

    @Test func turningOffWhileAutomationHoldsStaysOffUntilTheConditionClears() {
        var settings = KeepAwakeSettings()
        settings.power = true
        let (model, holder, conditions, _) = make(settings)
        conditions.isOnPowerAdapter = true
        conditions.fire()
        model.turnOff()
        #expect(!holder.isHeld)
        #expect(model.stateLine == String(localized: "Off until the condition clears"))
        conditions.fire()
        #expect(!holder.isHeld)
        conditions.isOnPowerAdapter = false
        conditions.fire()
        conditions.isOnPowerAdapter = true
        conditions.fire()
        #expect(holder.isHeld)
    }

    @Test func changingTheOptionsAttachesOnlyTheSourcesNeeded() {
        let (model, _, conditions, _) = make()
        #expect(conditions.attached == (false, false, false, false))
        var settings = KeepAwakeSettings()
        settings.externalDisplay = true
        settings.applications = true
        settings.bundleIDs = ["a.b"]
        settings.pauseWhileLocked = true
        model.apply(settings)
        #expect(conditions.attached == (true, false, true, true))
        // Applications with an empty list needs no running-app watcher.
        settings.bundleIDs = []
        model.apply(settings)
        #expect(conditions.attached.applications == false)
    }

    @Test func quittingReleasesTheAssertions() {
        let (model, holder, _, _) = make()
        model.start(.indefinite)
        model.shutdown()
        #expect(!holder.isHeld)
    }
}
