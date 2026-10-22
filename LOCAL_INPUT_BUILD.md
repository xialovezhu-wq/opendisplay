# OpenDisplay input development build

Local changes based on upstream v1.25.0, commit
`f71def4e68403f83fcc42baffd0cd3ffa9330fde`. The upstream GPL-3.0 LICENSE is retained.
This is a paired development build, not an official OpenDisplay release.

## Behavior

- Physical iPad keyboard input reaches the Mac over the existing USB channel.
  Select the text language/input method on the Mac.
- Modifier events include left/right flags for existing global shortcuts.
  The paired Magic Keyboard's observed Globe event is forwarded as Mac Fn.
- Double-tap Pencil toggles the current brush and eraser in Mac MarginNote 4.
- Hold Pencil Pro squeeze for temporary lasso; releasing it restores the exact
  prior tool, including the eraser. Repeated begin/release messages are safe.
- Tool changes wait for pen-up. Release remains queued for a long lasso stroke;
  it is never replaced by a later gesture or dropped by the normal wait timeout.
- Background/disconnect releases input and attempts to restore the temporary
  tool only while the same MarginNote window remains foreground on that display.
  If focus/display changed or a new stroke started, restoration is stopped and
  reported in the Mac log; no old restoration is replayed into another session.
- Trackpad two-finger scrolling is enabled through UIKit continuous scroll input.
- A direct finger taps to click and swipes to scroll. It never starts a mouse
  drag merely because it is held on the screen. Small tap jitter is tolerated;
  a cancelled or multi-finger contact cannot emit a leftover click.
- Physical mouse/trackpad pointer dragging and Pencil handwriting retain their
  separate paths, with no new sidebar.
- Fast finger swipes continue after release with a bounded, decelerating tail.
  Touching again stops it without activating the item under that braking tap.
  A paused/slow release does not fling; new input, background, disconnect,
  viewport changes and host-cursor movement cancel the tail.

## Build and installation

Requires Xcode with the iPhoneOS SDK and XcodeGen. Generate with `./generate.sh`.
For signing, keep `DEVELOPMENT_TEAM` in the ignored `.env`; do not distribute
accounts, certificates, profiles or private keys with source packages.

The Debug sender identity remains `com.peetzweg.opensidecar.mac.debug`.
The paired iPad Debug identity is `local.xiazhibin.opendisplay.input.ios`.
Both display as **OpenDisplay Dev**; the official apps are not replaced.
Only Debug is configured for this personal build. Do not sign the upstream
Release bundle IDs with a personal team. Debug builds do not follow the public
app-update feed; maintain the two paired input builds together.

Build the Mac sender into `build/Build/Products/Debug/OpenDisplay Dev.app` as
required by AGENTS.md. Grant its own Screen Recording and Accessibility
permissions through macOS. Keep the signed binary unchanged during a test run.
Install the paired iPad app using the user's development signing and enabled
Developer Mode. Debug uses receiver port 9001 (the official app uses 9000), so
the two iPad listeners cannot collide. Run one display pair at a time to avoid
creating an unnecessary second virtual display.

## Verification

Automated checks cover physical HID mapping and modifier state, repeated keys,
release/reset, malformed protocol packets, tool selection and ambiguity, plus
the existing project tests. The iOS pure state test is
`tools/tests/ios-input-state/run.sh`.

Real-device acceptance is separate: pointer and handwriting, English/Chinese,
copy/paste/undo and held modifiers, double-tap pen→eraser→pen,
hold-squeeze pen→lasso→release→pen and eraser→lasso→release→eraser,
release during a lasso stroke, repeated squeeze, cancellation while holding,
focus/background/disconnect/reconnect, and a sustained handwriting session.
A successful compilation is not a claim that these hardware checks passed.
In Apple Pencil settings choose a tool action for Squeeze; Run Shortcut and Off
may prevent the app from receiving it. iPadOS-reserved system shortcuts may stay
on iPad. Free Personal Team provisioning expires and must be renewed using Xcode.

## Local renewal tooling

`tools/renew_ipad.py` checks a private, machine-specific configuration and renews
only the already-installed paired iPad development app. It validates the frozen
source manifest, target device, signing identity, a strictly extended profile
expiry, and an installation receipt read back from the device. Pending installs
are recovered before retrying; another installed feature build is never silently
replaced with older frozen source.

`tools/launch_renewal.py` is the native macOS launchd entry point. Normal renewal
uses a three-day cadence and a four-day expiry window. A daily local-date gate
and login trigger allow missed work to resume after sleep. Credentials and the
private host configuration belong outside this checkout. A future feature update
must also update the verified renewal snapshot and installed-build baseline.

Run the renewal checks with
`python3 -m unittest discover -s tools/tests -p test_renew_ipad.py`.
