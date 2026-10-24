import Foundation

/// A bounded, coalescing plan. UIKit ownership checks and main-queue execution
/// stay in RemoteInputView; this type never reads keys or changes a responder.
struct RemoteInputFocusRecovery {
    struct Attempt: Equatable {
        let generation: UInt64
        let index: Int
        let delay: TimeInterval
    }

    enum Preparation: Equatable {
        case stale
        case disabled
        case blockedByLocalUI
        case alreadyFocused
        case acquire
    }

    private let delays: [TimeInterval] = [0, 0.05, 0.20]
    private var generation: UInt64 = 0
    private(set) var pending: Attempt?

    /// Only explicit lifecycle events or an eligibility edge call request.
    /// Repeated requests while pending share the existing retry budget.
    mutating func request() -> Attempt? {
        guard pending == nil else { return nil }
        generation &+= 1
        let attempt = Attempt(generation: generation, index: 0, delay: delays[0])
        pending = attempt
        return attempt
    }

    func isCurrent(_ attempt: Attempt) -> Bool { pending == attempt }

    mutating func prepare(_ attempt: Attempt, eligible: Bool,
                          blockedByLocalUI: Bool, focused: Bool) -> Preparation {
        guard isCurrent(attempt) else { return .stale }
        if !eligible { invalidate(); return .disabled }
        if blockedByLocalUI { invalidate(); return .blockedByLocalUI }
        if focused { invalidate(); return .alreadyFocused }
        return .acquire
    }

    mutating func complete(_ attempt: Attempt, succeeded: Bool) -> Attempt? {
        guard isCurrent(attempt) else { return nil }
        guard !succeeded, attempt.index + 1 < delays.count else {
            invalidate()
            return nil
        }
        let next = Attempt(generation: generation, index: attempt.index + 1,
                           delay: delays[attempt.index + 1])
        pending = next
        return next
    }

    mutating func invalidate() {
        generation &+= 1
        pending = nil
    }
}
