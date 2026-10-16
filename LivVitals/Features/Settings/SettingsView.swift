import AppKit
import LivCore
import SwiftUI

struct SettingsView: View {
    let store: AppStore

    @State private var isConfirmingReset = false

    private var settings: AppSettings { store.settings }
    private var permissions: PermissionsModel { store.permissions }
    private var adminRule: AdminRuleModel { store.adminRule }
    private var loginItem: LoginItemModel { store.loginItem }

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 18) {
            ModuleHeader(module: .settings)

            Form {
                Section("Cleaning") {
                    Toggle("Move items to the Trash instead of deleting them", isOn: $settings.moveToTrash)
                    Toggle("Review items before cleaning", isOn: $settings.previewBeforeCleaning)
                    Toggle("Simulate cleaning (nothing is moved)", isOn: $settings.dryRun)
                    Toggle("Leave projects edited in the last 7 days unchecked", isOn: $settings.skipRecentProjects)
                }

                Section("Menu Bar") {
                    Toggle("Show Liv Vitals in the menu bar", isOn: $settings.showMenuBarExtra)
                    if settings.hasMenuBarContent {
                        Toggle("Hide from the Dock when the window is closed", isOn: $settings.hideFromDockWhenClosed)
                        Toggle("Open Liv Vitals at login", isOn: Binding(get: { loginItem.isOn }, set: loginItem.setEnabled))
                        if loginItem.needsApproval {
                            LabeledContent("macOS needs your approval before it opens at login.") {
                                Button("Open Login Items", action: loginItem.openSystemSettings)
                            }
                        }
                        if let message = loginItem.errorMessage {
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                IndicatorsSettingsSection(settings: settings, monitor: store.monitor)
                DesktopWidgetsSettingsSection(monitor: store.monitor, model: store.desktopWidgets)

                Section {
                    PathList(
                        paths: settings.protectedPaths,
                        placeholder: "~/path/to/protect",
                        add: settings.addProtectedPath,
                        remove: settings.removeProtectedPath
                    )
                } header: {
                    Text("Protected Paths")
                } footer: {
                    Text("Liv Vitals never removes anything inside these folders, and cleaning scans skip them.")
                }

                Section {
                    PathList(
                        paths: settings.projectRoots,
                        placeholder: "~/path/to/projects",
                        add: settings.addProjectRoot,
                        remove: settings.removeProjectRoot
                    )
                } header: {
                    Text("Dev Project Folders")
                } footer: {
                    Text("Dev Projects looks for build folders only inside these locations.")
                }

                Section {
                    PathList(
                        paths: settings.installerFolders,
                        placeholder: "~/path/to/installers",
                        add: settings.addInstallerFolder,
                        remove: settings.removeInstallerFolder
                    )
                } header: {
                    Text("Installer Folders")
                } footer: {
                    Text("Installers looks for disk images and packages here, three levels deep. On the Desktop it only looks at the files directly on it.")
                }

                Section("Permissions") {
                    LabeledContent("Full Disk Access") {
                        HStack(spacing: 10) {
                            Label(permissions.statusTitle, systemImage: permissions.statusSymbol)
                                .foregroundStyle(permissions.status == .granted ? .green : .secondary)
                            if permissions.status != .granted {
                                Button("Open System Settings", action: permissions.openSettings)
                            }
                        }
                    }
                    LabeledContent("App Management") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Lets Liv Vitals move other developers' apps to the Trash.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                            Text("Not listed there? Click + and add Liv Vitals from Applications.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                            Button("Open System Settings", action: permissions.openAppManagementSettings)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Admin tasks without a password")
                        AdminRuleControls(model: adminRule)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Show Welcome Guide", action: store.showWelcomeGuide)
                    Button("Reset to Defaults…", role: .destructive) { isConfirmingReset = true }
                } footer: {
                    Text("Puts every setting above back to its default. Your history and the administrator rule stay as they are.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear(perform: loginItem.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
        .padding(28)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset to Defaults", role: .destructive, action: settings.resetToDefaults)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Protected paths, project and installer folders and the cleaning options go back to how they were at the start.")
        }
    }
}

private struct PathList: View {
    let paths: [String]
    let placeholder: String
    /// Returns why the path was refused, or nil when it was accepted.
    let add: (String) -> SettingsPathError?
    let remove: (String) -> Void

    @State private var newPath = ""
    @State private var errorMessage: String?

    var body: some View {
        ForEach(paths, id: \.self) { path in
            HStack {
                SystemIcon(url: URL(fileURLWithPath: path), prefer: .file, size: 18)
                Text((path as NSString).abbreviatingWithTildeInPath)
                Spacer()
                Button {
                    withMotion { remove(path) }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(path)")
            }
        }
        HStack {
            TextField("New path", text: $newPath, prompt: Text(placeholder))
                .labelsHidden()
                .onSubmit(commit)
            Button("Add", action: commit)
                .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let errorMessage {
            Text(errorMessage).font(.caption).foregroundStyle(.red)
        }
    }

    private func commit() {
        if let error = add(newPath) {
            errorMessage = error.errorDescription
        } else {
            errorMessage = nil
            newPath = ""
        }
    }
}
