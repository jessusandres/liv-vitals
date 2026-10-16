import Observation

/// The steps of the welcome guide and where the user is in them. Finishing and skipping both end the guide; the
/// caller decides what that means (the first run marks it as seen, "Show Welcome Guide" does not need to).
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case welcome, fullDiskAccess, appManagement, adminRule
    }

    private(set) var step: Step
    @ObservationIgnored private let onFinish: () -> Void

    init(step: Step = .welcome, onFinish: @escaping () -> Void) {
        self.step = step
        self.onFinish = onFinish
    }

    var isFirst: Bool { step == .welcome }
    var isLast: Bool { step == Step.allCases.last }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Moves on, or finishes after the last step.
    func next() {
        if let following = Step(rawValue: step.rawValue + 1) {
            step = following
        } else {
            onFinish()
        }
    }

    func skip() {
        onFinish()
    }
}
