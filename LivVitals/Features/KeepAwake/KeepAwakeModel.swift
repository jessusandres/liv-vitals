// Adapted from coffe-awake (AwakeController), GPL-3, same author.
import Foundation
import LivCore
import Observation

/// Keeps the Mac awake: owns the state machine, takes and drops the power assertions as it flips, and wakes up only when
/// the label, a session or a condition needs it to.
@Observable
final class KeepAwakeModel {
    private(set) var state: KeepAwakeState
    private(set) var errorMessage: String?
    /// The length of the manual session that is running, for the check mark in the menu.
    private(set) var sessionDuration: KeepAwakeDuration?
    /// The time the label and the state line were last computed for; the observable that makes them refresh.
    private(set) var currentDate: Date

    @ObservationIgnored private var settings: KeepAwakeSettings
    @ObservationIgnored private let holder: any PowerAssertionHolding
    @ObservationIgnored private let conditions: any KeepAwakeConditionSource
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var deadline: Task<Void, Never>?

    init(
        holder: any PowerAssertionHolding,
        conditions: any KeepAwakeConditionSource,
        settings: KeepAwakeSettings,
        now: @escaping () -> Date = Date.init
    ) {
        self.holder = holder
        self.conditions = conditions
        self.settings = settings
        self.now = now
        currentDate = now()
        state = KeepAwakeState(pauseWhileLocked: settings.pauseWhileLocked)
        conditions.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    var isOn: Bool { state.isOn }
    var isPaused: Bool { state.isPaused }
    var showsInMenuBar: Bool { settings.showInMenuBar }

    /// The time beside the cup: "45m", "2h", "∞" or nothing.
    var labelText: String? { state.label(now: currentDate) }

    var stateLine: String {
        if state.isSuppressed { return String(localized: "Off until the condition clears") }
        guard state.isOn else { return String(localized: "Off") }
        if state.isPaused { return String(localized: "Paused while the Mac is locked") }
        switch state.manual {
        case .indefinite: return String(localized: "Active until you turn it off")
        case .until:
            let minutes = (state.remaining(now: currentDate) ?? 0) / 60
            let left = Duration.seconds(minutes.rounded(.up) * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            return String(localized: "Active for \(left) more")
        case .off: return String(localized: "Active while a condition is met")
        }
    }

    /// For VoiceOver on the menu bar cup.
    var spokenState: String { "\(String(localized: "Keep Awake")), \(stateLine)" }

    func turnOn() { start(settings.defaultDuration) }

    func start(_ duration: KeepAwakeDuration) {
        errorMessage = nil
        state.start(duration, now: now())
        sessionDuration = duration
        update()
    }

    func turnOff() {
        errorMessage = nil
        state.stop()
        update()
    }

    /// Settings changed: follow the options, attach only the sources they need, and look at the world again.
    func apply(_ settings: KeepAwakeSettings) {
        self.settings = settings
        state.setPauseWhileLocked(settings.pauseWhileLocked, now: now())
        refresh()
    }

    /// Releases the assertions before the app quits.
    func shutdown() {
        deadline?.cancel()
        holder.release()
    }

    /// Reads the conditions and the clock again. Runs on every event and when a session's deadline passes.
    func refresh() {
        conditions.attach(
            externalDisplay: settings.externalDisplay,
            power: settings.power,
            applications: settings.applications && !settings.bundleIDs.isEmpty,
            lock: settings.pauseWhileLocked
        )
        let t = now()
        state.setLocked(conditions.isLocked, now: t)
        state.setAutomation(holds: KeepAwakeAutomation.holds(
            settings,
            externalDisplay: conditions.hasExternalDisplay,
            onAC: conditions.isOnPowerAdapter,
            runningBundleIDs: conditions.runningBundleIDs
        ))
        state.tick(now: t)
        update()
    }

    private func update() {
        let t = now()
        if state.manual == .off { sessionDuration = nil }
        if state.wantsAssertions {
            do {
                try holder.acquire(reason: "Liv Vitals keeps the Mac and its display awake.")
            } catch {
                // Not holding means off: stop the session, and keep automation from retrying until its conditions clear.
                errorMessage = error.localizedDescription
                state.stop()
                sessionDuration = nil
            }
        } else {
            holder.release()
        }
        currentDate = t
        deadline?.cancel()
        deadline = nil
        if let next = state.nextDeadline(now: t) {
            let wait = max(0, next.timeIntervalSince(t))
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
}
