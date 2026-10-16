import AppKit
import Foundation
import Testing
@testable import LivVitals

/// The Dock icon follows the windows: hidden when the last one closes, only while the menu bar icon is the way back.
@MainActor
struct DockPresenceTests {
    @Test func theDecisionNeedsTheSettingTheMenuBarIconAndNoWindowsLeft() {
        #expect(DockPresence.shouldHide(hideSetting: true, menuBarShown: true, remainingWindows: 0))
        #expect(!DockPresence.shouldHide(hideSetting: false, menuBarShown: true, remainingWindows: 0))
        // Without the menu bar icon there would be no way back in.
        #expect(!DockPresence.shouldHide(hideSetting: true, menuBarShown: false, remainingWindows: 0))
        #expect(!DockPresence.shouldHide(hideSetting: true, menuBarShown: true, remainingWindows: 1))
    }

    private func window(visible: Bool = true) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 200, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        if visible { window.orderFrontRegardless() }
        return window
    }

    private final class Recorder {
        var policies: [NSApplication.ActivationPolicy] = []
    }

    private func presence(
        hide: Bool = true, menuBar: Bool = true, windows: @escaping () -> [NSWindow], recorder: Recorder, center: NotificationCenter
    ) -> DockPresence {
        DockPresence(
            hideFromDock: { hide }, menuBarShown: { menuBar },
            setPolicy: { recorder.policies.append($0) }, openWindows: windows, center: center
        )
    }

    @Test func closingTheLastWindowHidesTheDockIconAndAnotherOpenOneKeepsIt() {
        let recorder = Recorder()
        let center = NotificationCenter()
        let main = window()
        let about = window()
        defer { main.orderOut(nil); about.orderOut(nil) }
        let dock = presence(windows: { [main, about] }, recorder: recorder, center: center)

        dock.windowWillClose(about)
        #expect(recorder.policies.isEmpty, "The main window is still open.")
        dock.windowWillClose(main)
        // Both count as open until they are gone, so closing `main` still sees `about`.
        #expect(recorder.policies.isEmpty)

        about.orderOut(nil)
        dock.windowWillClose(main)
        #expect(recorder.policies == [.accessory])
    }

    @Test func theNotificationFromAClosingWindowDrivesIt() {
        let recorder = Recorder()
        let center = NotificationCenter()
        let main = window()
        defer { main.orderOut(nil) }
        let dock = presence(windows: { [main] }, recorder: recorder, center: center)

        center.post(name: NSWindow.willCloseNotification, object: main)
        #expect(recorder.policies == [.accessory])
        withExtendedLifetime(dock) {}
    }

    @Test func panelsAndHiddenWindowsDoNotCountAndNeverTriggerIt() {
        let recorder = Recorder()
        let center = NotificationCenter()
        let main = window()
        let panel = NSPanel(contentRect: CGRect(x: -10_000, y: -10_000, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        let hidden = window(visible: false)
        defer { main.orderOut(nil); panel.orderOut(nil) }
        let dock = presence(windows: { [main, panel, hidden] }, recorder: recorder, center: center)

        // The menu bar popover closing is not the user closing a window.
        dock.windowWillClose(panel)
        dock.windowWillClose(hidden)
        #expect(recorder.policies.isEmpty)
        // The panel and the hidden window are not counted as windows left behind.
        dock.windowWillClose(main)
        #expect(recorder.policies == [.accessory])
    }

    @Test func theSettingOffOrNoMenuBarIconLeavesTheDockIconAlone() {
        for (hide, menuBar) in [(false, true), (true, false)] {
            let recorder = Recorder()
            let main = window()
            defer { main.orderOut(nil) }
            let dock = presence(hide: hide, menuBar: menuBar, windows: { [main] }, recorder: recorder, center: NotificationCenter())
            dock.windowWillClose(main)
            #expect(recorder.policies.isEmpty)
        }
    }
}
