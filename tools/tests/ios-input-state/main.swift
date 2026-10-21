import Foundation

private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

var keys = RemoteKeyboardState()
let a = keys.down(usage: 0x04, modifiers: 0)
check(a?.phase == "down" && a?.isRepeat == false, "physical press emits exactly one initial down")
check(keys.down(usage: 0x04, modifiers: 0) == nil, "duplicate UIKit began is not a second character")
check(keys.repeatedEvent()?.isRepeat == true, "held printable key can repeat")
check(keys.up(usage: 0x04, modifiers: 0)?.phase == "up", "physical release is forwarded")
check(keys.repeatedEvent() == nil, "released key never repeats")
check(keys.up(usage: 0x04, modifiers: 0) == nil, "late release after reset/release is ignored")
check(keys.down(usage: 0, modifiers: 0) == nil, "non-key HID usage is rejected")

_ = keys.down(usage: 0xE1, modifiers: 0)
check(keys.modifiers == 1, "Shift press corrects pre-event modifier snapshot")
_ = keys.down(usage: 0xE5, modifiers: 1)
_ = keys.up(usage: 0xE1, modifiers: 1)
check(keys.modifiers == 1, "releasing left Shift preserves held right Shift")
_ = keys.up(usage: 0xE5, modifiers: 1)
check(keys.modifiers == 0, "last Shift release corrects stale flags")

_ = keys.down(usage: 0xE3, modifiers: 8)
_ = keys.down(usage: 0x06, modifiers: 8)
check(keys.repeatedEvent() == nil, "Command shortcut never repeats")
let released = keys.reset()
check(released.map(\.usage) == [0x06, 0xE3], "reset releases character before modifier")
check(keys.held.isEmpty && keys.modifiers == 0 && keys.repeatUsage == nil, "reset clears held state")
check(keys.up(usage: 0x06, modifiers: 8) == nil, "old-session key-up cannot mutate new-session state")

_ = keys.down(usage: 0x2A, modifiers: 0)
check(keys.repeatedEvent()?.usage == 0x2A, "Backspace repeats")
_ = keys.down(usage: 0xE0, modifiers: 2)
check(keys.repeatedEvent() == nil, "holding Control suppresses repeat")
_ = keys.reset()
_ = keys.down(usage: 0x29, modifiers: 0)
check(keys.repeatedEvent() == nil, "Escape never repeats")

var command = RemoteKeyboardState()
let doubleCommand = [
    command.down(usage: 0xE3, modifiers: 0),
    command.up(usage: 0xE3, modifiers: 8),
    command.down(usage: 0xE3, modifiers: 0),
    command.up(usage: 0xE3, modifiers: 8)
].compactMap { $0 }
check(doubleCommand.map(\.phase) == ["down", "up", "down", "up"],
      "two bare Command taps preserve all four physical transitions")
check(doubleCommand.map(\.modifiers) == [8, 0, 8, 0],
      "bare Command corrects flags that exclude the current modifier or describe pre-release state")
check(command.held.isEmpty && command.modifiers == 0 && command.repeatedEvent() == nil,
      "double Command cannot leave a held key or autorepeat")
_ = command.down(usage: 0xE3, modifiers: 0)
_ = command.down(usage: 0xE7, modifiers: 8)
check(command.up(usage: 0xE3, modifiers: 8)?.modifiers == 8,
      "left Command release preserves held right Command")
check(command.up(usage: 0xE7, modifiers: 8)?.modifiers == 0,
      "final right Command release clears Command flags")
check(RemoteKeyboardState.shouldDiagnose(0xE3) && RemoteKeyboardState.shouldDiagnose(0xE7),
      "diagnostics allow the two standard Command keys")
check((0x04...0xA4).allSatisfy { !RemoteKeyboardState.shouldDiagnose($0) },
      "diagnostics never log regular letters, digits, punctuation or normal HID keys")
check(RemoteKeyboardState.shouldDiagnose(0) && RemoteKeyboardState.shouldDiagnose(0xFFFF),
      "unknown special usages are observable without assigning a private Fn code")

let functionUsage = RemoteKeyboardState.observedFunctionUsage
check(functionUsage == 669 && RemoteKeyboardState.accepts(functionUsage),
      "only the measured Globe/Fn usage is added to accepted keys")
check(!RemoteKeyboardState.accepts(668) && !RemoteKeyboardState.accepts(670),
      "neighboring unmeasured usages remain unsupported")
check(RemoteKeyboardState.shouldDiagnose(functionUsage), "accepted Function events remain diagnosable")
check(RemoteKeyboardState.modifierSnapshot(keyFlags: 1 << 23, eventFlags: 0) == 0,
      "current event zero overrides stale Function key flags on release")
check(RemoteKeyboardState.modifierSnapshot(keyFlags: 0, eventFlags: 1 << 23) == 1 << 23,
      "current event flags describe Function during another key's event")
check(RemoteKeyboardState.modifierSnapshot(keyFlags: 1 << 23, eventFlags: nil) == 1 << 23,
      "missing UIEvent falls back to the available UIKey snapshot")

var function = RemoteKeyboardState()
let functionTaps = [
    function.down(usage: functionUsage, modifiers: 32),
    function.up(usage: functionUsage, modifiers: 0),
    function.down(usage: functionUsage, modifiers: 32),
    function.up(usage: functionUsage, modifiers: 32)
].compactMap { $0 }
check(functionTaps.map(\.phase) == ["down", "up", "down", "up"],
      "successive Globe/Fn taps preserve all physical transitions")
check(functionTaps.map(\.modifiers) == [32, 0, 32, 0],
      "Function release clears its bit even with fallback stale flags")
check(functionTaps.allSatisfy { !$0.isRepeat }, "Function transitions are never autorepeats")
_ = function.down(usage: functionUsage, modifiers: 0)
check(function.repeatedEvent() == nil, "holding Function alone creates no repeat")
check(function.down(usage: functionUsage, modifiers: 32) == nil,
      "duplicate Function began is suppressed")
check(function.down(usage: 0x04, modifiers: 32)?.modifiers == 32,
      "letter combined with Function carries the Function modifier")
check(function.up(usage: 0x04, modifiers: 32)?.modifiers == 32,
      "letter release preserves a physically held Function key")
check(function.up(usage: functionUsage, modifiers: 0)?.modifiers == 0,
      "releasing Function after a letter clears all modifiers")

_ = function.down(usage: functionUsage, modifiers: 32)
_ = function.down(usage: 0x05, modifiers: 32)
check(function.up(usage: functionUsage, modifiers: 0)?.modifiers == 0,
      "Function can be released while a letter remains held")
check(function.repeatedEvent()?.modifiers == 0,
      "subsequent repeat uses current flags after Function release")
_ = function.reset()
_ = function.down(usage: functionUsage, modifiers: 32)
_ = function.down(usage: 0xE3, modifiers: 40)
_ = function.down(usage: 0x04, modifiers: 40)
let functionReset = function.reset()
check(functionReset.map(\.usage) == [0x04, 0xE3, functionUsage],
      "reset releases a letter then Command and Function modifiers")
check(functionReset.map(\.modifiers) == [40, 32, 0],
      "reset clears Command and Function in order")
check(function.held.isEmpty && function.modifiers == 0 && function.repeatUsage == nil,
      "Function reset leaves no held input state")
check(function.up(usage: functionUsage, modifiers: 32) == nil,
      "late Function release after reset is ignored")

var pencil = DeferredPencilActions<String>()
check(pencil.request("eraser") == ["eraser"], "idle gesture dispatches immediately")
pencil.began(contact: 1)
check(pencil.request("eraser").isEmpty, "gesture during pen-down is deferred")
check(pencil.request("lasso").isEmpty, "later tool action is also deferred")
check(pencil.ended(contact: 1, cancelled: false) == ["eraser", "lasso"], "pen-up dispatches actions in order")
check(pencil.ended(contact: 1, cancelled: false).isEmpty, "duplicate pen-up cannot repeat a gesture")
pencil.began(contact: 2)
_ = pencil.request("eraser")
check(pencil.ended(contact: 2, cancelled: true).isEmpty, "cancelled stroke discards pending tool change")
pencil.began(contact: 3)
_ = pencil.request("lasso")
pencil.reset()
check(!pencil.hasActiveContact && pencil.ended(contact: 3, cancelled: false).isEmpty,
      "focus loss drops pending actions and contacts")
pencil.began(contact: 4)
pencil.began(contact: 5)
_ = pencil.request("eraser")
check(pencil.ended(contact: 4, cancelled: false).isEmpty, "remaining contact prevents premature tool switch")
check(pencil.ended(contact: 5, cancelled: false) == ["eraser"], "last pen-up flushes once")

var heldLasso = DeferredPencilActions<String>()
check(heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp") == ["lassoDown"],
      "squeeze began with the tip up selects temporary lasso")
check(heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp").isEmpty,
      "duplicate squeeze began does not replace the saved tool")
heldLasso.began(contact: 10)
check(heldLasso.ended(contact: 10, cancelled: false).isEmpty,
      "a lasso stroke can finish while squeeze remains held")
check(heldLasso.endTemporaryAction() == ["lassoUp"], "release restores the previous tool once")
check(heldLasso.endTemporaryAction().isEmpty, "duplicate release does not restore twice")

heldLasso.began(contact: 11)
check(heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp").isEmpty,
      "squeeze began during a pen stroke waits for pen-up")
check(heldLasso.ended(contact: 11, cancelled: false) == ["lassoDown"],
      "pen-up selects temporary lasso only while still held")
heldLasso.began(contact: 12)
check(heldLasso.endTemporaryAction().isEmpty, "release during lasso stroke waits for pen-up")
check(heldLasso.ended(contact: 12, cancelled: false) == ["lassoUp"],
      "lasso stroke finishes before restoring original tool")

heldLasso.began(contact: 13)
_ = heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp")
check(heldLasso.endTemporaryAction().isEmpty, "fast press/release never sends an unused activation")
check(heldLasso.ended(contact: 13, cancelled: false).isEmpty,
      "no stale begin survives a fast press/release during a stroke")

heldLasso.began(contact: 14)
_ = heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp")
check(heldLasso.ended(contact: 14, cancelled: true).isEmpty,
      "cancelled pen stroke discards a pending activation")
check(heldLasso.endTemporaryAction().isEmpty, "release after cancelled pending hold is a no-op")
_ = heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp")
heldLasso.began(contact: 15)
check(heldLasso.ended(contact: 15, cancelled: true) == ["lassoUp"],
      "cancelled lasso stroke restores already activated temporary tool")
check(heldLasso.endTemporaryAction().isEmpty, "late squeeze cancelled/ended cannot restore twice")

_ = heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp")
check(heldLasso.endTemporaryAction() == ["lassoUp"],
      "squeeze cancellation with tip up uses the same restore transition as release")
_ = heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp")
heldLasso.began(contact: 16)
_ = heldLasso.endTemporaryAction()
check(heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp").isEmpty,
      "re-squeeze before pen-up cancels pending restoration without a second begin")
check(heldLasso.ended(contact: 16, cancelled: false).isEmpty,
      "re-squeezed temporary lasso remains active through pen-up")
check(heldLasso.endTemporaryAction() == ["lassoUp"], "final release restores re-squeezed hold")

heldLasso.began(contact: 17)
_ = heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp")
heldLasso.reset()
check(heldLasso.ended(contact: 17, cancelled: false).isEmpty
      && heldLasso.endTemporaryAction().isEmpty, "reset drops an unsent activation and late callbacks")
_ = heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp")
heldLasso.began(contact: 18)
_ = heldLasso.endTemporaryAction()
heldLasso.reset()
check(heldLasso.ended(contact: 18, cancelled: false).isEmpty,
      "peer input-reset owns restoration, with no late queued action after local reset")
check(heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp") == ["lassoDown"],
      "new hold works normally after focus reset")
_ = heldLasso.endTemporaryAction()

heldLasso.began(contact: 19)
_ = heldLasso.request("eraser")
_ = heldLasso.beginTemporaryAction(begin: "lassoDown", end: "lassoUp")
check(heldLasso.ended(contact: 19, cancelled: false) == ["eraser", "lassoDown"],
      "queued discrete choice is applied before temporary tool captures its base")
heldLasso.began(contact: 20)
_ = heldLasso.request("eraser")
_ = heldLasso.endTemporaryAction()
check(heldLasso.ended(contact: 20, cancelled: false) == ["lassoUp", "eraser"],
      "restore precedes a queued discrete choice made during the lasso stroke")

print("PASS: \(checks) iOS remote-input state checks")
