import AppKit
import LivCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Keep Awake: the switch, the default duration, what starts it by itself, and pausing while the Mac is locked.
struct KeepAwakeSettingsSection: View {
    let settings: AppSettings
    let model: KeepAwakeModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var options: KeepAwakeSettings { settings.keepAwake }
    private var hasCondition: Bool { options.externalDisplay || options.power || options.applications }

    var body: some View {
        @Bindable var settings = settings
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: Binding(get: { model.isOn }, set: { $0 ? model.turnOn() : model.turnOff() })) {
                    Label("Keep awake", systemImage: model.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                }
                Text(model.stateLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.stateLine)
                if let message = model.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red).padding(.leading, 28)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Default duration")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(KeepAwakeDuration.allCases) { duration in
                        DurationChip(title: duration.localizedTitle, isSelected: options.defaultDuration == duration) {
                            settings.keepAwake.defaultDuration = duration
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Start automatically")
                HStack(alignment: .top, spacing: 10) {
                    ConditionCard(title: "External display", symbol: "display.2", isOn: $settings.keepAwake.externalDisplay)
                    ConditionCard(title: "Power", symbol: "powerplug", isOn: $settings.keepAwake.power)
                    ConditionCard(title: "Applications", symbol: "app.badge.checkmark", isOn: Binding(
                        get: { options.applications },
                        set: { value in
                            settings.keepAwake.applications = value
                            if value, options.bundleIDs.isEmpty { pickApplications() }
                        }
                    ))
                }
                if options.applications { applicationList }
            }

            Toggle("Pause while the Mac is locked", isOn: $settings.keepAwake.pauseWhileLocked)
            Toggle("Show in the menu bar", isOn: $settings.keepAwake.showInMenuBar)
        } header: {
            Text("Keep Awake")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Starts when any selected condition is active.")
                if hasCondition, !settings.hasMenuBarContent {
                    Text("Closing the window quits Liv Vitals and ends keep awake. Show it in the menu bar to keep it running.")
                }
            }
        }
    }

    // MARK: - Applications

    @ViewBuilder private var applicationList: some View {
        ForEach(options.bundleIDs, id: \.self) { id in
            ApplicationRow(bundleID: id) { withMotion { settings.keepAwake.bundleIDs.removeAll { $0 == id } } }
        }
        Button("Add…", action: pickApplications)
    }

    /// Asks for apps and stores their bundle identifiers; an app without one, or already listed, is skipped.
    private func pickApplications() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else {
            if options.bundleIDs.isEmpty { settings.keepAwake.applications = false }
            return
        }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !options.bundleIDs.contains(id) { settings.keepAwake.bundleIDs.append(id) }
        }
        if options.bundleIDs.isEmpty { settings.keepAwake.applications = false }
    }
}

/// A capsule that picks one value; the chosen one is tinted and outlined in the accent color.
private struct DurationChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 1.5 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One automation condition as a card: icon and title, outlined in the accent color while it is on.
private struct ConditionCard: View {
    let title: LocalizedStringKey
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button { withMotion(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2).foregroundStyle(isOn ? Color.accentColor : .secondary)
                Text(title).font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.vertical, 6)
            .background(isOn ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isOn ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isOn ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}

/// A chosen app, with its icon and name; greyed out and marked when it is not installed any more.
private struct ApplicationRow: View {
    let bundleID: String
    let remove: () -> Void

    private var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    var body: some View {
        let url = url
        HStack(spacing: 8) {
            if let url { SystemIcon(url: url, size: 18) } else { Image(systemName: "questionmark.app").frame(width: 18, height: 18).accessibilityHidden(true) }
            Text(url.map { FileManager.default.displayName(atPath: $0.path).replacing(".app", with: "") } ?? bundleID)
            if url == nil { Text("Not installed").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(url?.deletingPathExtension().lastPathComponent ?? bundleID)")
        }
        .opacity(url == nil ? 0.55 : 1)
    }
}
