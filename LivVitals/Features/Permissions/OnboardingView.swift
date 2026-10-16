import SwiftUI

/// The welcome guide: what the app does and the three things macOS or the user has to allow. Every step can be skipped.
struct OnboardingView: View {
    let permissions: PermissionsModel
    let adminRule: AdminRuleModel
    @State private var model: OnboardingModel
    @State private var isShowingRuleSheet = false

    init(
        permissions: PermissionsModel,
        adminRule: AdminRuleModel,
        initialStep: OnboardingModel.Step = .welcome,
        onFinish: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.adminRule = adminRule
        _model = State(initialValue: OnboardingModel(step: initialStep, onFinish: onFinish))
    }

    var body: some View {
        VStack(spacing: 18) {
            Group {
                switch model.step {
                case .welcome: welcome
                case .fullDiskAccess: fullDiskAccess
                case .appManagement: appManagement
                case .adminRule: adminRuleStep
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)

            progressDots

            HStack(spacing: 12) {
                Button("Skip", action: model.skip)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !model.isFirst {
                    Button("Back", action: model.back)
                }
                Button(model.isLast ? "Done" : "Continue", action: model.next)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 500)
        .task { permissions.refresh() }
    }

    private var welcome: some View {
        page(
            symbol: "sparkles",
            title: "Welcome to Liv Vitals",
            text: "It finds caches, logs, build folders and unused apps, and shows you how much space they take. It only reads and measures until you review and confirm a cleanup, and everything it removes can be put back from History."
        )
    }

    private var fullDiskAccess: some View {
        page(
            symbol: "externaldrive.badge.checkmark",
            title: "Allow Full Disk Access",
            text: "Liv Vitals needs it to measure and clean caches, logs and app data that macOS protects. Turn on Liv Vitals under Full Disk Access, then come back here. If it still shows as not granted, quit and reopen Liv Vitals."
        ) {
            Label(permissions.statusTitle, systemImage: permissions.statusSymbol)
                .foregroundStyle(permissions.status == .granted ? .green : .secondary)
            Button("Open System Settings", action: permissions.openSettings)
        }
    }

    private var appManagement: some View {
        page(
            symbol: "app.badge.checkmark",
            title: "Allow App Management",
            text: "Lets Liv Vitals move other developers' apps to the Trash. macOS does not tell apps whether this is on, so check that Liv Vitals is listed and switched on. If it is not listed yet, click + and add Liv Vitals from Applications."
        ) {
            Button("Open System Settings", action: permissions.openAppManagementSettings)
        }
    }

    private var adminRuleStep: some View {
        page(
            symbol: "lock.shield",
            title: "Admin tasks (optional)",
            text: "A few maintenance tasks need administrator rights and ask for your password each time. You can add one sudo rule that allows exactly those commands without a password. Nothing is installed unless you choose it, and you can remove the rule at any time in Settings."
        ) {
            if adminRule.isInstalled {
                Label("Admin tasks run without a password.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Enable admin tasks…") { isShowingRuleSheet = true }
                    .disabled(adminRule.isWorking)
            }
        }
        .task { await adminRule.refresh() }
        .sheet(isPresented: $isShowingRuleSheet) {
            AdminRuleSheet(model: adminRule) { isShowingRuleSheet = false }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
    }

    private func page<Actions: View>(
        symbol: String,
        title: LocalizedStringKey,
        text: LocalizedStringKey,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 54))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title).font(.title.bold())
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            actions()
        }
    }

    private func page(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        page(symbol: symbol, title: title, text: text) { EmptyView() }
    }
}
