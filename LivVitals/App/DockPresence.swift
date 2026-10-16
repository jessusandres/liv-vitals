import AppKit
import Foundation

/// Takes the Dock icon away when the last window is closed (⌘W) and brings it back when a window is opened again,
/// so the app can live in the menu bar alone. It only hides while the menu bar icon is shown, because that icon is
/// the way back in: without it the app would be unreachable.
@MainActor
final class DockPresence {
    /// Whether closing the last window should hide the app from the Dock.
    static func shouldHide(hideSetting: Bool, menuBarShown: Bool, remainingWindows: Int) -> Bool {
        hideSetting && menuBarShown && remainingWindows == 0
    }

    /// A window the user can see and close: not the menu bar popover, a panel or a window of a lower level.
    static func isUserWindow(_ window: NSWindow) -> Bool {
        window.isVisible && !(window is NSPanel) && window.level == .normal && window.canBecomeMain
    }

    private let hideFromDock: () -> Bool
    private let menuBarShown: () -> Bool
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private let openWindows: () -> [NSWindow]

    init(
        hideFromDock: @escaping () -> Bool,
        menuBarShown: @escaping () -> Bool,
        setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
        openWindows: @escaping () -> [NSWindow] = { NSApp.windows },
        center: NotificationCenter = .default
    ) {
        self.hideFromDock = hideFromDock
        self.menuBarShown = menuBarShown
        self.setPolicy = setPolicy
        self.openWindows = openWindows
        // Lives as long as the app does, so the observer is never removed.
        _ = center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.windowWillClose(window) }
        }
    }

    /// Called while `window` is still on screen, so it is left out of the count.
    func windowWillClose(_ window: NSWindow) {
        guard Self.isUserWindow(window) else { return }
        let remaining = openWindows().filter { $0 !== window && Self.isUserWindow($0) }.count
        if Self.shouldHide(hideSetting: hideFromDock(), menuBarShown: menuBarShown(), remainingWindows: remaining) {
            setPolicy(.accessory)
        }
    }

    /// Puts the icon back in the Dock. Call before opening a window from the menu bar.
    static func showInDock() {
        NSApp.setActivationPolicy(.regular)
    }
}
