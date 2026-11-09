import AppKit
import LivCore
import SwiftUI

/// The cup in the menu bar: a menu to start, change or stop keep awake, with the time left beside the icon. It is inserted by
/// its own setting; dragging it out of the bar with ⌘ turns the setting off.
struct KeepAwakeScene: Scene {
    let store: AppStore

    var body: some Scene {
        MenuBarExtra(
            isInserted: Binding(
                get: { store.settings.keepAwake.showInMenuBar },
                // Only when it changed: an in-place write notifies observers even with an equal value, and the menu bar writes back what it read.
                set: { value in if store.settings.keepAwake.showInMenuBar != value { store.settings.keepAwake.showInMenuBar = value } }
            )
        ) {
            KeepAwakeMenu(store: store)
        } label: {
            KeepAwakeLabel(model: store.keepAwake)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct KeepAwakeLabel: View {
    let model: KeepAwakeModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
            if let text = model.labelText { Text(text) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.spokenState)
    }
}

private struct KeepAwakeMenu: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    private var model: KeepAwakeModel { store.keepAwake }

    var body: some View {
        Text(model.stateLine)
        if let message = model.errorMessage { Text(message) }
        Button(model.isOn ? "Turn Off" : "Turn On") { model.isOn ? model.turnOff() : model.turnOn() }
        Divider()
        ForEach(KeepAwakeDuration.allCases) { duration in
            Toggle(duration.localizedTitle, isOn: Binding(
                get: { model.sessionDuration == duration },
                set: { _ in model.start(duration) }
            ))
        }
        Divider()
        Button("Keep Awake Settings…") {
            store.requestedModule = .settings
            DockPresence.showInDock()
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
