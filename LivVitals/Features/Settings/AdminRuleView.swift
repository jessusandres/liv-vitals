import SwiftUI

/// The state of the admin rule and the button that changes it. Shown in Performance and in Settings.
struct AdminRuleControls: View {
    let model: AdminRuleModel

    @State private var isShowingSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label {
                    Text(statusText)
                } icon: {
                    Image(systemName: model.isInstalled ? "lock.open.fill" : "lock.shield")
                        .foregroundStyle(model.isInstalled ? Color.green : Color.secondary)
                }
                Spacer()
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                switch model.state {
                case .installed:
                    Button("Remove") { Task { await model.remove() } }
                        .disabled(model.isWorking)
                case .notInstalled:
                    Button("Enable admin tasks…") { isShowingSheet = true }
                        .disabled(model.isWorking)
                case .unknown:
                    EmptyView()
                }
            }
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await model.refresh() }
        .sheet(isPresented: $isShowingSheet) {
            AdminRuleSheet(model: model) { isShowingSheet = false }
        }
    }

    private var statusText: String {
        switch model.state {
        case .unknown: String(localized: "Checking admin access…")
        case .installed: String(localized: "Admin tasks run without a password.")
        case .notInstalled: String(localized: "Admin tasks ask for your password once per run.")
        }
    }
}

/// What the rule allows, in full, before the user agrees to install it.
struct AdminRuleSheet: View {
    let model: AdminRuleModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable admin tasks").font(.title2.bold())
                    Text("Run maintenance without typing your password.").foregroundStyle(.secondary)
                }
            }

            Text("Liv Vitals adds one rule to sudo. It allows exactly these commands as root for \(model.user), and nothing else:")
                .font(.callout)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.allowedCommands, id: \.self) { command in
                    Text(command).font(.caption.monospaced())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if let rule = model.ruleText {
                DisclosureGroup("Show the rule file") {
                    Text(rule)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.callout)
            }

            Text("macOS asks for your password once to install it. You can remove the rule at any time, here or in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Enable") {
                    close()
                    Task { await model.install() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.ruleText == nil)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
    }
}
