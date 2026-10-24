import Foundation

private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

/// Fake main queue and responder; no UIKit, app launch, or real focus changes.
struct Harness {
    var policy = RemoteInputFocusRecovery()
    var queue: [RemoteInputFocusRecovery.Attempt] = []
    var eligible = true
    var localEditor = false
    var focused = false
    var results: [Bool] = []
    var acquireCount = 0
    var delays: [TimeInterval] = []
    var preparations: [RemoteInputFocusRecovery.Preparation] = []

    mutating func request() {
        if let attempt = policy.request() { queue.append(attempt) }
    }

    mutating func tick() {
        guard !queue.isEmpty else { return }
        let attempt = queue.removeFirst()
        delays.append(attempt.delay)
        let preparation = policy.prepare(attempt, eligible: eligible,
                                         blockedByLocalUI: localEditor, focused: focused)
        preparations.append(preparation)
        guard preparation == .acquire else { return }
        acquireCount += 1
        let succeeded = !results.isEmpty && results.removeFirst()
        focused = succeeded
        if let retry = policy.complete(attempt, succeeded: succeeded) { queue.append(retry) }
    }
}

var recovery = Harness(results: [false, true])
recovery.request()
check(recovery.acquireCount == 0, "request never changes focus synchronously")
recovery.tick()
check(!recovery.focused && recovery.queue.count == 1, "initial UIKit failure schedules a retry")
recovery.tick()
check(recovery.focused && recovery.acquireCount == 2 && recovery.queue.isEmpty,
      "subsequent success finishes the bounded recovery")
check(recovery.policy.pending == nil && recovery.delays == [0, 0.05],
      "successful recovery clears pending state and uses the delayed retry")

var coalesced = Harness(results: [false, true])
coalesced.request()
let original = coalesced.policy.pending
coalesced.request()
coalesced.request()
check(coalesced.queue.count == 1 && coalesced.policy.pending == original,
      "same-turn requests coalesce without changing generation or adding work")
coalesced.tick()
let retry = coalesced.policy.pending
coalesced.request()
check(coalesced.queue.count == 1 && coalesced.policy.pending == retry,
      "a lifecycle request during retry keeps the existing budget")
coalesced.tick()
check(coalesced.acquireCount == 2, "coalescing never duplicates focus acquisition")

var exhausted = Harness(results: [false, false, false, true])
exhausted.request()
for _ in 0..<10 { exhausted.tick() }
check(exhausted.acquireCount == 3 && exhausted.queue.isEmpty && exhausted.policy.pending == nil,
      "persistent failure stops after three attempts")
check(exhausted.delays == [0, 0.05, 0.20], "retry delays are finite and bounded")
exhausted.request()
exhausted.tick()
check(exhausted.focused && exhausted.acquireCount == 4,
      "a later explicit lifecycle event can start a fresh budget")

var invalidated = Harness(results: [true])
invalidated.request()
invalidated.policy.invalidate()
invalidated.tick()
check(invalidated.acquireCount == 0 && invalidated.preparations == [.stale],
      "cancelled queued work cannot steal focus after teardown")
invalidated.request()
invalidated.eligible = false
invalidated.tick()
check(invalidated.acquireCount == 0 && invalidated.policy.pending == nil,
      "disabled or disconnected input is checked again when queued work executes")
invalidated.eligible = true
invalidated.request()
invalidated.tick()
check(invalidated.focused, "explicit reactivation works after invalidation")

var localEditing = Harness(results: [true])
localEditing.request()
localEditing.localEditor = true
localEditing.tick()
check(localEditing.acquireCount == 0 && localEditing.queue.isEmpty
      && localEditing.preparations == [.blockedByLocalUI],
      "an editor acquiring focus during the deferred turn blocks without retry")
localEditing.localEditor = false
localEditing.tick()
check(localEditing.acquireCount == 0, "editor exit alone cannot revive abandoned callbacks")
localEditing.request() // actual sheet onDismiss or another explicit lifecycle event
localEditing.tick()
check(localEditing.focused && localEditing.acquireCount == 1,
      "actual dismissal explicitly restores remote focus")

var editorDuringRetry = Harness(results: [false, true])
editorDuringRetry.request()
editorDuringRetry.tick()
editorDuringRetry.localEditor = true
editorDuringRetry.tick()
check(editorDuringRetry.acquireCount == 1 && editorDuringRetry.queue.isEmpty,
      "a new local editor between retries cancels the remaining budget")

var already = Harness(focused: true, results: [false])
already.request()
already.tick()
check(already.acquireCount == 0 && already.preparations == [.alreadyFocused],
      "an existing remote first responder needs no new focus request")

var staleCompletion = RemoteInputFocusRecovery()
let old = staleCompletion.request()!
staleCompletion.invalidate()
let current = staleCompletion.request()!
check(staleCompletion.complete(old, succeeded: false) == nil && staleCompletion.pending == current,
      "old completion cannot add retries to a new focus generation")
check(staleCompletion.prepare(old, eligible: true, blockedByLocalUI: false, focused: false) == .stale,
      "old queued callback cannot acquire focus in a new generation")

print("PASS: \(checks) remote-input focus recovery checks")
