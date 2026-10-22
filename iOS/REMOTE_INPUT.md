# iPad keyboard and Pencil gestures

This receiver supports physical keys from an iPad keyboard (including the
Smart Connector Magic Keyboard), Apple Pencil double-tap to toggle pen/eraser,
and Apple Pencil Pro squeeze-and-hold for a temporary lasso. Releasing the
squeeze restores the pen or eraser selected before the hold. A compatible custom Mac
sender must advertise each capability before the receiver sends it. Existing
USB video, touch, and Pencil stroke messages are unchanged.

The full-screen video view becomes the hardware-keyboard first responder. It
sends USB HID key-down/key-up events and Shift/Control/Option/Command/Caps Lock/Function
flags; it never separately forwards locally composed text. Select the input
source on the Mac for Chinese or other IME composition. This avoids receiving
both raw letters and an iPad-composed version of the same text.

Keyboard input is released on focus loss, settings presentation, inactive app,
window removal, or capability loss. Repeats use one 450 ms delay / 50 ms timer;
duplicate UIKit key-down callbacks are suppressed. Command/Control shortcuts,
Escape, and modifier keys do not auto-repeat. The newest repeatable held key
wins; releasing it stops repeat until the next physical press.

Some shortcuts are reserved by iPadOS (for example Home/app switching or
Spotlight combinations, depending on the OS/settings) and may never reach an
app. The receiver cannot promise to transfer those combinations. iPad keyboard
layout/remapping and Mac input-source configuration should agree for punctuation
and international-layout keys. System text input on the iPad is not used.

The public UIKit SDK supports modifier-only `UIKey` events and standard left/
right Command HID usages (`keyboardLeftGUI` / `keyboardRightGUI`). A bare Command
tap is forwarded as its own down/up pair; two taps must arrive as four events.
Debug builds log only Command and Function incoming phases/flags and outgoing transitions,
plus unsupported special-key raw usages. Ordinary key codes and text are never
logged. The `pressesChanged` callback is observed but is not guessed to mean a
key release. These logs distinguish missing iPad callbacks from downstream Mac
shortcut recognition failures.

The iPhoneOS 27.1 public UIKit modifier flags and key-usage enums have no named
Globe/Fn constant. However, a controlled test of the paired iPad Magic Keyboard
on 2026-10-21 confirmed repeated physical Globe presses through public `UIKey`
callbacks: `keyCode.rawValue == 669 (0x29D)` and modifier raw flag `1 << 23`.
The client explicitly accepts this measured usage and maps its modifier to
wire bit 32. It does not guess any other unsupported key or use private APIs.
Function itself never auto-repeats and is released on reset like other modifiers.

The same test showed that `UIKey.modifierFlags` retained the down-time Function
flag during release while `UIEvent.modifierFlags` correctly returned zero.
The current event's snapshot therefore takes precedence, with the key snapshot
used only if no event is supplied. Actual down/up state still corrects the
changed modifier, including either side of Shift or Command. This measured
device behavior does not establish Globe support for every keyboard/iPadOS
version. GameController is not added as a second input source.

Pencil double-tap uses only the modern delegate on iPadOS 17.5 and later;
older devices use only the legacy callback. A continuous squeeze begins the
temporary lasso at `.began` and restores the previous tool at `.ended` or
`.cancelled`; `.changed` never reselects a tool. The tip remains usable for
drawing the lasso while the squeeze is held. A tool transition during a stroke
waits until after its pen-up message. If the squeeze begins and ends before
pen-up, its unsent activation is discarded. If the lasso is already active,
releasing the squeeze during a lasso stroke restores the previous tool after
that stroke ends. Cancelling a stroke also restores the tool; losing focus uses
the peer's input-reset cleanup. No additional sidebar or drawing surface is installed.

The installed iPhoneOS 27.1 SDK's public `UIPencilInteraction.h` declares all four
squeeze phases (available since iPadOS 17.5), but also says that a discrete
gesture reports only `.ended`. The client does not synthesize a press from such
an event: actual press-and-release support must be confirmed with the Pencil
and iPadOS version in use. The connection log records began/ended/cancelled
phases for that check, without recording drawing content.

In iPad Settings > Apple Pencil, enable double-tap and select a tool action for
Squeeze. Do not choose Run Shortcut or Off: Apple states that running a system
shortcut prevents apps from receiving the squeeze event. The custom client's
gesture mappings are intentionally pen/eraser and a temporary lasso, as requested.

Sources:
- https://developer.apple.com/videos/play/wwdc2020/10109/
- https://developer.apple.com/videos/play/wwdc2024/10214/
- https://developer.apple.com/documentation/uikit/uipencilinteractiondelegate
- https://developer.apple.com/documentation/uikit/uikey
- https://developer.apple.com/documentation/uikit/uikeymodifierflags
- https://developer.apple.com/documentation/gamecontroller/gckeyboardinput

Run the platform-independent state checks with:

```
sh tools/tests/ios-input-state/run.sh
```

Those checks do not establish hardware behavior. Before considering the feature
complete, build against an iOS SDK, install the signed client, and verify English
and Chinese typing, Backspace/repeat, modifiers, reconnect/background release,
ordinary Pencil writing, double-tap in both directions, and squeeze-and-hold
while drawing a lasso in MarginNote 4. Check restoration from both an initial
pen and an initial eraser, a quick press/release during a stroke, release while
the tip still touches the glass, cancellation, and background/focus-loss cleanup.

## Direct finger input

Direct screen touches now use a separate state machine. A completed tap sends
one mouse click; movement of at least 9 view points from touch-down starts
scrolling. Scroll anchoring happens once at the initial contact, then real
finger deltas become the existing scroll messages. No predicted points or
mouse-down timer are used for direct fingers, and lifting after a swipe never
adds a click. Multiple fingers, cancellation, Pencil palm rejection and session
reset discard the pending tap. Mouse/trackpad pointer dragging retains its
existing path; Pencil strokes and the two-finger trackpad scroll path are separate.

Run `sh tools/tests/direct-touch-state/run.sh` for the direct-touch state checks.
The local iPad build 184 was compiled, signed, installed and read back. The user
confirmed tap, single-finger scrolling without text selection, mouse text dragging
and Pencil handwriting on the device.

## Finger scroll momentum

`FingerScrollMomentum` samples actual touch positions/timestamps over the latest
100 ms. Only a completed direct scroll may start a tail. Release after an 80 ms
pause, a tap, cancellation, or multiple fingers does not fling. Starting velocity
is bounded; analytic exponential integration keeps total travel consistent
across frame rates. This approximates the interaction of native scrolling, not
an assertion of identical UIKit physics.

The view uses a weak-target CADisplayLink at 60 Hz only while coasting. Sub-point
deltas accumulate before sending wheel updates, including the final partial
step. A new touch brakes immediately; a stationary braking tap does not click
the underlying control, while a fresh swipe still works. Pencil/pointer input,
keyboard presses, two-finger trackpad scroll, host-cursor movement, view changes,
background and session reset also stop momentum. A stalled display callback
cannot cause a large catch-up jump.

Run `sh tools/tests/finger-scroll-momentum/run.sh` for the momentum checks;
`sh tools/tests/direct-touch-state/run.sh` verifies tap/scroll separation.
