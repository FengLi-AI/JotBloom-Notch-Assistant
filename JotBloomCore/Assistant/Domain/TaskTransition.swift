import Foundation

public enum TaskTransitionEvent: CaseIterable, Sendable {
    case retryUnderstanding, adjustPlan, configurationReady
    case beginUnderstanding, requireConfiguration, understoodWithQuestions, understoodWithPlan
    case understoodReminder, userAnswered, userConfirmedWork, userConfirmedReminder
    case executionStarted, needsUser, userContinued, completed, failed, interrupted, cancelled
}

/// F4-01 / F15-04: receipt and understanding cannot directly start execution.
public enum TaskTransition {
    public static func next(from status: TaskStatus, event: TaskTransitionEvent) throws -> TaskStatus {
        if event == .cancelled, !status.isTerminal { return .cancelled }
        if event == .failed, !status.isTerminal { return .failed }
        switch (status, event) {
        case (.received, .beginUnderstanding), (.needsInfo, .userAnswered): return .understanding
        case (.failed, .retryUnderstanding), (.interrupted, .retryUnderstanding), (.planReady, .adjustPlan), (.waitingUser, .configurationReady): return .understanding
        case (.received, .requireConfiguration), (.understanding, .requireConfiguration): return .waitingUser
        case (.understanding, .understoodWithQuestions): return .needsInfo
        case (.understanding, .understoodWithPlan): return .planReady
        case (.understanding, .understoodReminder), (.planReady, .userConfirmedReminder): return .scheduled
        case (.planReady, .userConfirmedWork), (.interrupted, .userContinued), (.waitingUser, .userContinued): return .queued
        case (.queued, .executionStarted): return .running
        case (.running, .needsUser): return .waitingUser
        case (.running, .completed), (.scheduled, .completed): return .completed
        case (.waitingUser, .interrupted), (.running, .interrupted), (.queued, .interrupted), (.understanding, .interrupted): return .interrupted
        default: throw AssistantError.invalidTransition
        }
    }
}
