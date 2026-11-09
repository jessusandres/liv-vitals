// Keep awake: sessions, automation and pause-while-locked, as pure logic.
// Adapted from coffe-awake (AwakeController, SessionDuration) and Vorssaint (KeepAwakeManager), GPL-3, same author.
import Foundation

/// How long a manual session lasts. The raw value is minutes; 0 means until the user stops it.
public enum KeepAwakeDuration: Int, Codable, CaseIterable, Sendable, Identifiable {
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case twoHours = 120
    case fourHours = 240
    case eightHours = 480
    case indefinite = 0

    public var id: Int { rawValue }

    public var seconds: TimeInterval? { self == .indefinite ? nil : TimeInterval(rawValue * 60) }
}

public struct KeepAwakeSettings: Codable, Equatable, Sendable {
    public var defaultDuration = KeepAwakeDuration.oneHour
    public var externalDisplay = false
    public var power = false
    public var applications = false
    /// Apps that count for the Applications condition, by bundle identifier.
    public var bundleIDs: [String] = []
    public var pauseWhileLocked = false
    public var showInMenuBar = true

    public init() {}

    // Lossy: one unreadable or missing field keeps its default and the rest survive.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        defaultDuration = value(.defaultDuration, defaultDuration)
        externalDisplay = value(.externalDisplay, externalDisplay)
        power = value(.power, power)
        applications = value(.applications, applications)
        bundleIDs = value(.bundleIDs, bundleIDs)
        pauseWhileLocked = value(.pauseWhileLocked, pauseWhileLocked)
        showInMenuBar = value(.showInMenuBar, showInMenuBar)
    }
}

public enum KeepAwakeAutomation {
    /// True when any selected condition is met.
    public static func holds(_ settings: KeepAwakeSettings, externalDisplay: Bool, onAC: Bool, runningBundleIDs: Set<String>) -> Bool {
        (settings.externalDisplay && externalDisplay)
            || (settings.power && onAC)
            || (settings.applications && !runningBundleIDs.isDisjoint(with: settings.bundleIDs))
    }
}

/// What should hold the assertions right now. Times are wall-clock dates, so a sleeping Mac still uses up a timed session.
public struct KeepAwakeState: Equatable, Sendable {
    public enum Manual: Equatable, Sendable {
        case off
        case indefinite
        case until(Date)
    }

    public private(set) var manual = Manual.off
    /// Time left on a timed session while the lock pause freezes it.
    public private(set) var pausedRemaining: TimeInterval?
    public private(set) var automationHolds = false
    /// The user turned keep awake off while automation held; automation stays quiet until its conditions clear.
    public private(set) var isSuppressed = false
    public private(set) var locked = false
    public private(set) var pauseWhileLocked: Bool

    public init(pauseWhileLocked: Bool = false) {
        self.pauseWhileLocked = pauseWhileLocked
    }

    public var isPaused: Bool { locked && pauseWhileLocked }

    /// The switch: a session is running or automation is on, even while paused.
    public var isOn: Bool { manual != .off || (automationHolds && !isSuppressed) }

    public var wantsAssertions: Bool { isOn && !isPaused }

    public mutating func start(_ duration: KeepAwakeDuration, now: Date) {
        manual = duration.seconds.map { .until(now.addingTimeInterval($0)) } ?? .indefinite
        pausedRemaining = nil
        isSuppressed = false
        syncPause(now: now)
    }

    public mutating func stop() {
        manual = .off
        pausedRemaining = nil
        if automationHolds { isSuppressed = true }
    }

    public mutating func setAutomation(holds: Bool) {
        automationHolds = holds
        if !holds { isSuppressed = false }
    }

    public mutating func setLocked(_ locked: Bool, now: Date) {
        self.locked = locked
        syncPause(now: now)
    }

    public mutating func setPauseWhileLocked(_ value: Bool, now: Date) {
        pauseWhileLocked = value
        syncPause(now: now)
    }

    /// Ends a timed session whose time is up. A paused one does not run out.
    public mutating func tick(now: Date) {
        if !isPaused, case .until(let end) = manual, now >= end { manual = .off }
    }

    /// Time left on a timed session; nil when there is none or it has no end.
    public func remaining(now: Date) -> TimeInterval? {
        if let pausedRemaining { return pausedRemaining }
        guard case .until(let end) = manual else { return nil }
        return max(0, end.timeIntervalSince(now))
    }

    /// When the label or the session next changes: the next minute boundary of the time left, or the end. Nil with nothing to schedule.
    public func nextDeadline(now: Date) -> Date? {
        guard !isPaused, case .until(let end) = manual else { return nil }
        let left = end.timeIntervalSince(now)
        guard left > 0 else { return now }
        let minutes = (left / 60).rounded(.up)
        return end.addingTimeInterval(-(minutes - 1) * 60)
    }

    /// The text beside the menu bar cup: time left, "∞", or nothing.
    public func label(now: Date) -> String? {
        guard wantsAssertions else { return nil }
        if let left = remaining(now: now) { return Self.compactRemaining(left) }
        return manual == .indefinite ? "∞" : nil
    }

    /// "15m" or "2h", rounded up and never below "1m".
    public static func compactRemaining(_ seconds: TimeInterval) -> String {
        if seconds >= 3_600 { return "\(Int((seconds / 3_600).rounded(.up)))h" }
        return "\(max(1, Int((seconds / 60).rounded(.up))))m"
    }

    private mutating func syncPause(now: Date) {
        if isPaused, pausedRemaining == nil, case .until(let end) = manual {
            pausedRemaining = max(0, end.timeIntervalSince(now))
        } else if !isPaused, let remaining = pausedRemaining {
            if case .until = manual { manual = .until(now.addingTimeInterval(remaining)) }
            pausedRemaining = nil
        }
    }
}
