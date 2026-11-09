// The automation sources, adapted from Vorssaint (KeepAwakeManager), GPL-3, same author.
import AppKit
import CoreGraphics
import Foundation
import IOKit.ps

/// What keep awake's automation reads, and the event that says it changed. Each source is attached only while its option is on,
/// and nothing polls.
@MainActor
protocol KeepAwakeConditionSource: AnyObject {
    /// Called (debounced) when anything attached changed, and after the Mac wakes.
    var onChange: (() -> Void)? { get set }
    func attach(externalDisplay: Bool, power: Bool, applications: Bool, lock: Bool)
    var hasExternalDisplay: Bool { get }
    var isOnPowerAdapter: Bool { get }
    var runningBundleIDs: Set<String> { get }
    var isLocked: Bool { get }
}

/// Inert source for previews, snapshots and tests that fire events by hand.
@MainActor
final class MockKeepAwakeConditions: KeepAwakeConditionSource {
    var onChange: (() -> Void)?
    var hasExternalDisplay = false
    var isOnPowerAdapter = false
    var runningBundleIDs: Set<String> = []
    var isLocked = false
    private(set) var attached = (externalDisplay: false, power: false, applications: false, lock: false)

    func attach(externalDisplay: Bool, power: Bool, applications: Bool, lock: Bool) {
        attached = (externalDisplay, power, applications, lock)
    }

    /// What the real source would do: report the change.
    func fire() { onChange?() }
}

/// Lives as long as the app, so it removes nothing on deinit; `attach` detaches whatever an option no longer needs.
@MainActor
final class LiveKeepAwakeConditions: KeepAwakeConditionSource {
    var onChange: (() -> Void)?
    private(set) var isLocked = false

    private var displayObserver: NSObjectProtocol?
    private var powerSource: CFRunLoopSource?
    private var appsObservation: NSKeyValueObservation?
    private var lockObservers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var watchesDisplays = false
    private var watchesPower = false
    private var watchesApps = false

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    func attach(externalDisplay: Bool, power: Bool, applications: Bool, lock: Bool) {
        watchesDisplays = externalDisplay
        watchesPower = power
        watchesApps = applications

        if externalDisplay, displayObserver == nil {
            displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        } else if !externalDisplay, let observer = displayObserver {
            NotificationCenter.default.removeObserver(observer)
            displayObserver = nil
        }

        if power, powerSource == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOPowerSourceCallbackType = { context in
                guard let context else { return }
                let conditions = Unmanaged<LiveKeepAwakeConditions>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { conditions.schedule() }
            }
            if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                powerSource = source
            }
        } else if !power, let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = nil
        }

        // KVO on the running list: helper apps post no launch notifications.
        if applications, appsObservation == nil {
            appsObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
                Task { @MainActor in self?.schedule() }
            }
        } else if !applications {
            appsObservation = nil
        }

        if lock, lockObservers.isEmpty {
            let center = DistributedNotificationCenter.default()
            lockObservers = [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)].map { name, locked in
                center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isLocked = locked
                        self?.schedule()
                    }
                }
            }
        } else if !lock, !lockObservers.isEmpty {
            lockObservers.forEach(DistributedNotificationCenter.default().removeObserver)
            lockObservers = []
            isLocked = false
        }
    }

    var hasExternalDisplay: Bool {
        guard watchesDisplays else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Also right on desktop Macs, which have no battery for `IOPSCopyPowerSourcesInfo` to describe.
    var isOnPowerAdapter: Bool {
        watchesPower && IOPSGetProvidingPowerSourceType(nil).takeUnretainedValue() as String == kIOPMACPowerKey
    }

    var runningBundleIDs: Set<String> {
        watchesApps ? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) : []
    }

    /// Events arrive in bursts (a display change fires several); one refresh after they settle.
    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
