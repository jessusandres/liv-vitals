import Foundation
import LivCore
import Observation

/// The optional rule that lets Liv Vitals's fixed admin commands run without a password. One model for the two
/// screens that show it (Performance and Settings), so both always agree.
@Observable
final class AdminRuleModel {
    enum State: Equatable {
        /// Not asked yet.
        case unknown
        case installed
        case notInstalled
    }

    private(set) var state: State = .unknown
    /// A dialog or a check is under way.
    private(set) var isWorking = false
    /// Why the last attempt did not work. A dismissed password dialog is not an error.
    private(set) var errorMessage: String?
    let user: String

    @ObservationIgnored private let privileged: any PrivilegedRunning

    init(privileged: any PrivilegedRunning, user: String = NSUserName()) {
        self.privileged = privileged
        self.user = user
    }

    var isInstalled: Bool { state == .installed }

    /// The exact text that would be installed; nil when the account name is not a plain one.
    var ruleText: String? { SudoersRule.contents(for: user) }

    /// The commands the rule allows, as typed.
    var allowedCommands: [String] { MaintenanceCommand.adminSteps.map(\.display) }

    func refresh() async {
        isWorking = true
        defer { isWorking = false }
        state = await privileged.isRuleInstalled() ? .installed : .notInstalled
    }

    func install() async {
        errorMessage = nil
        guard let text = ruleText else {
            errorMessage = "“\(user)” is not a plain account name, so the rule cannot be written for it."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await privileged.installRule(text)
        } catch PrivilegedError.cancelled {
            // The user changed their mind.
        } catch {
            errorMessage = error.localizedDescription
        }
        state = await privileged.isRuleInstalled() ? .installed : .notInstalled
    }

    func remove() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await privileged.removeRule()
        } catch PrivilegedError.cancelled {
            // The user changed their mind.
        } catch {
            errorMessage = error.localizedDescription
        }
        state = await privileged.isRuleInstalled() ? .installed : .notInstalled
    }
}
