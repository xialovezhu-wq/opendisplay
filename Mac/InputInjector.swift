import CoreGraphics
import AppKit
import Darwin

/// System double-click thresholds. Interval is public API; distance is read from
/// AppKit's `NSDoubleClickDistance()` (same value the Window Server uses).
private enum SystemClickMetrics {
    static var interval: TimeInterval { NSEvent.doubleClickInterval }

    static var distance: CGFloat {
        doubleClickDistanceFn?() ?? 4
    }

    private typealias DoubleClickDistanceFn = @convention(c) () -> CGFloat
    private static let doubleClickDistanceFn: DoubleClickDistanceFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY),
              let sym = dlsym(handle, "NSDoubleClickDistance") else { return nil }
        return unsafeBitCast(sym, to: DoubleClickDistanceFn.self)
    }()
}

/// Turns normalized touch coordinates from the phone into mouse events on a
/// target display. Touch semantics: finger down = left button down, finger
/// move = drag, finger up = button up — i.e. the phone acts as a touchscreen.
final class InputInjector {

    private let displayID: CGDirectDisplayID
    private var isDown = false
    private var penDown = false
    private let inputLock = NSRecursiveLock()
    private var keyboard = RemoteKeyboardState()
    // A private source prevents borrowing another device's held-key ownership.
    private let keyboardSource = CGEventSource(stateID: .privateState)
    private var lastTouchPoint: CGPoint?
    private var lastPenPoint: CGPoint?

    var hasActiveStroke: Bool {
        inputLock.lock()
        defer { inputLock.unlock() }
        return penDown || isDown
    }
    // A real event source (vs nil) plus non-zero clickState on down/up: menu
    // tracking treats sourceless/zero-click synthetic clicks as malformed — menus
    // open but their tracking session breaks, leaving zombie menu windows
    // composited on the display (visible in the stream, unclickable).
    private let source = CGEventSource(stateID: .hidSystemState)
    // Synthetic OpenDisplay tablet — conspicuous in logs; not Wacom (0x056A) or
    // typical small driver IDs (1, 2, …).
    private let tabletVendorID: Int64 = 0x0D15       // "ODIS"
    private let tabletProductID: Int64 = 0x0101
    private let deviceID: Int64 = 424242
    private let pointerID: Int64 = 0x0D02              // pen tip
    private let vendorPointerType: Int64 = 0x0802    // Grip Pen (what apps expect)
    private let capabilityMask: Int64 = 0x05C7       // pressure + tilt + rotation + buttons
    private var inRange = false

    // Pencil-only synthetic click counting — tablet events don't get click
    // state from the Window Server, so we mirror macOS double-click prefs here.
    private struct PenClickSession {
        let downLocation: CGPoint
        let clickState: Int
    }

    private struct PenCompletedClick {
        let upTime: CFAbsoluteTime
        let downLocation: CGPoint
        let clickState: Int
    }

    private var penClickSession: PenClickSession?
    private var penLastClick: PenCompletedClick?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    static func ensureAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.info("Accessibility permission missing — prompt requested")
        }
        return trusted
    }

    /// x/y are normalized [0,1] in video space (origin top-left).
    func handleTouch(phase: String, x: Double, y: Double) {
        inputLock.lock()
        defer { inputLock.unlock() }
        let bounds = CGDisplayBounds(displayID)   // global CG coords, y-down
        let point = CGPoint(
            x: bounds.origin.x + x * bounds.width,
            y: bounds.origin.y + y * bounds.height
        )

        let type: CGEventType
        // Click count on the release. A cancel means "a second finger joined,
        // this was a scroll, not a tap" — but there is no CGEvent for undoing a
        // press, and a plain up over the press point is indistinguishable from a
        // click, so every two-finger scroll opened whatever was under finger one.
        // Releasing with clickCount 0 keeps the button state honest while telling
        // AppKit and WebKit not to synthesize a click. Only the cancel path gets
        // 0: a zero-click *down* is what breaks menu tracking (see above).
        var clickState = 1
        switch phase {
        case "began":
            type = .leftMouseDown
            isDown = true
        case "moved":
            type = isDown ? .leftMouseDragged : .mouseMoved
        case "ended":
            guard isDown else { return }   // spurious up without a down
            type = .leftMouseUp
            isDown = false
        case "cancelled":
            guard isDown else { return }
            type = .leftMouseUp
            isDown = false
            clickState = 0
        default:
            return
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        lastTouchPoint = point
        event.flags.formUnion(keyboard.flags)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }

    /// dx/dy in display pixels, natural-scrolling sign from the phone.
    /// Scroll events take points, so convert via the display's pixel scale.
    func handleScroll(dx: Double, dy: Double) {
        inputLock.lock()
        defer { inputLock.unlock() }
        let bounds = CGDisplayBounds(displayID)
        let scale = bounds.width > 0 ? Double(CGDisplayPixelsWide(displayID)) / bounds.width : 2
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32((dy / scale).rounded()),
                                  wheel2: Int32((dx / scale).rounded()),
                                  wheel3: 0) else { return }
        event.flags.formUnion(keyboard.flags)
        event.post(tap: .cghidEventTap)
    }

    func handleProximity(entering: Bool, x: Double, y: Double) {
        inputLock.lock()
        defer { inputLock.unlock() }
        setProximity(entering: entering, at: screenPoint(nx: x, ny: y))
    }

    func handlePencil(phase: String, x: Double, y: Double,
                      pressure: Double, azimuth: Double, altitude: Double,
                      rotation: Double) {
        inputLock.lock()
        defer { inputLock.unlock() }
        // TODO: Wire Apple Pencil Pro barrel roll (UIKit rollAngle) once hardware
        // is available for testing. rotation on the wire is always 0 for now.
        _ = rotation
        let p = screenPoint(nx: x, ny: y)
        lastPenPoint = p
        if phase == "down", !inRange {
            setProximity(entering: true, at: p)
        }
        let (tiltX, tiltY) = deriveTilt(azimuth: azimuth, altitude: altitude)

        switch phase {
        case "down":
            postTabletPoint(phase: .down, x: x, y: y, pressure: pressure,
                            tiltX: tiltX, tiltY: tiltY, rotation: 0)
            penDown = true
        case "move":
            if penDown {
                postTabletPoint(phase: .drag, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            } else {
                postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            }
        case "up":
            if penDown {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
                penDown = false
            }
        case "cancel", "cancelled":
            if penDown {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0, cancelled: true)
                penDown = false
            }
        case "hover":
            if penDown {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
                penDown = false
            }
            postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                            tiltX: tiltX, tiltY: tiltY, rotation: 0)
        default:
            return
        }
    }

    /// Returns false for an unsupported/stale event. No text is injected: the
    /// foreground Mac app's input method handles Chinese composition normally.
    @discardableResult
    func handleKey(_ event: RemoteKeyEvent) -> Bool {
        inputLock.lock()
        defer { inputLock.unlock() }
        guard AXIsProcessTrusted(), keyboardSource != nil else { return false }
        var next = keyboard
        guard let transition = next.consume(event), postKey(transition) else { return false }
        keyboard = next
        return true
    }

    /// Idempotent teardown for disconnect/background/stop. Only releases keys
    /// and a mouse press that this injector actually owns, at its last position.
    func resetInputs() {
        inputLock.lock()
        defer { inputLock.unlock() }
        for transition in keyboard.reset() { _ = postKey(transition) }
        if penDown, let point = lastPenPoint {
            let bounds = CGDisplayBounds(displayID)
            let nx = bounds.width > 0 ? (point.x - bounds.minX) / bounds.width : 0
            let ny = bounds.height > 0 ? (point.y - bounds.minY) / bounds.height : 0
            postTabletPoint(phase: .up, x: Double(nx), y: Double(ny), pressure: 0,
                            tiltX: 0, tiltY: 0, rotation: 0, cancelled: true)
        } else if isDown, let point = lastTouchPoint,
                  let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                      mouseCursorPosition: point, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventClickState, value: 0)
            event.post(tap: .cghidEventTap)
        }
        isDown = false
        penDown = false
        penClickSession = nil
        penLastClick = nil
        if inRange { setProximity(entering: false, at: lastPenPoint ?? .zero) }
        lastTouchPoint = nil
        lastPenPoint = nil
    }

    private func postKey(_ transition: RemoteKeyboardTransition) -> Bool {
        guard let event = CGEvent(keyboardEventSource: keyboardSource,
                                  virtualKey: transition.keyCode, keyDown: transition.isDown) else { return false }
        if transition.isModifier { event.type = .flagsChanged }
        event.flags = transition.flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: transition.isRepeat ? 1 : 0)
        event.post(tap: .cghidEventTap)
        if transition.usage == 0xE3 || transition.usage == 0xE7 {
            Log.info("remote Command \(transition.isDown ? "down" : "up") flags=\(transition.flags.rawValue)")
        }
        if transition.usage == RemoteInputProtocol.globeFnUsage {
            Log.info("remote Fn \(transition.isDown ? "down" : "up") flags=\(transition.flags.rawValue)")
        }
        return true
    }

    private func setProximity(entering: Bool, at p: CGPoint) {
        guard entering != inRange else { return }
        inRange = entering
        postProximityEvent(entering: entering, at: p)
    }

    private func postProximityEvent(entering: Bool, at p: CGPoint) {
        guard let ev = CGEvent(source: source) else { return }
        ev.type = .tabletProximity
        ev.location = p
        ev.setIntegerValueField(.tabletProximityEventVendorID, value: tabletVendorID)
        ev.setIntegerValueField(.tabletProximityEventTabletID, value: tabletProductID)
        ev.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
        ev.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        ev.setIntegerValueField(.tabletProximityEventPointerType, value: entering ? 1 : 0)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPointerType)
        ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
        ev.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        ev.flags = .maskNonCoalesced
        ev.post(tap: .cghidEventTap)
    }

    private enum PointPhase { case down, drag, up, hover }

    private func postTabletPoint(phase: PointPhase, x: Double?, y: Double?,
                                 pressure: Double, tiltX: Double, tiltY: Double,
                                 rotation: Double, cancelled: Bool = false) {
        let p: CGPoint
        if let nx = x, let ny = y { p = screenPoint(nx: nx, ny: ny) }
        else { p = currentCursor() }

        let type: CGEventType
        switch phase {
        case .down:  type = .leftMouseDown
        case .drag:  type = .leftMouseDragged
        case .up:    type = .leftMouseUp
        case .hover: type = .mouseMoved
        }

        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: p, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: 0)
        ev.setIntegerValueField(.mouseEventDeltaY, value: 0)
        ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        ev.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        ev.setDoubleValueField(.mouseEventPressure, value: pressure)
        ev.setIntegerValueField(.tabletEventPointPressure, value: Int64((pressure * 65535.0).rounded()))
        ev.setDoubleValueField(.tabletEventTiltX, value: tiltX)
        ev.setDoubleValueField(.tabletEventTiltY, value: tiltY)
        ev.setDoubleValueField(.tabletEventRotation, value: rotation)
        switch phase {
        case .down:
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(beginPenClickSession(at: p)))
        case .up:
            let count = finishPenClickSession(at: p)
            ev.setIntegerValueField(.mouseEventClickState, value: cancelled ? 0 : Int64(count))
            if cancelled { penLastClick = nil }
        case .drag, .hover:
            break
        }
        ev.flags.formUnion(keyboard.flags)
        ev.flags.insert(.maskNonCoalesced)
        ev.post(tap: .cghidEventTap)
    }

    private func penClickStateForMouseDown(at point: CGPoint) -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        guard let last = penLastClick,
              now - last.upTime <= SystemClickMetrics.interval else {
            return 1
        }
        let dx = point.x - last.downLocation.x
        let dy = point.y - last.downLocation.y
        guard hypot(dx, dy) <= SystemClickMetrics.distance else { return 1 }
        return last.clickState + 1
    }

    private func beginPenClickSession(at point: CGPoint) -> Int {
        let state = penClickStateForMouseDown(at: point)
        penClickSession = PenClickSession(downLocation: point, clickState: state)
        return state
    }

    /// Returns click state for the matching pen mouse-up. Extends the multi-click
    /// chain only when down→up displacement is within the system threshold.
    private func finishPenClickSession(at upLocation: CGPoint) -> Int {
        guard let session = penClickSession else { return 1 }
        penClickSession = nil

        let dx = upLocation.x - session.downLocation.x
        let dy = upLocation.y - session.downLocation.y
        if hypot(dx, dy) <= SystemClickMetrics.distance {
            penLastClick = PenCompletedClick(
                upTime: CFAbsoluteTimeGetCurrent(),
                downLocation: session.downLocation,
                clickState: session.clickState
            )
        } else {
            penLastClick = nil
        }
        return session.clickState
    }

    /// UIKit altitude is radians from the surface (pi/2 = upright); CGEvent tilt
    /// is a unit vector in -1...1, so normalize rather than pass radians through
    /// (unnormalized, a flat pen reads 1.57 and apps that scale tilt by 90 report
    /// impossible angles).
    private func deriveTilt(azimuth: Double, altitude: Double) -> (Double, Double) {
        let mag = min(max(0, Double.pi / 2 - altitude) / (Double.pi / 2), 1)
        return (sin(azimuth) * mag, cos(azimuth) * mag)
    }

    private func screenPoint(nx: Double, ny: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.minX + nx * bounds.width,
                       y: bounds.minY + ny * bounds.height)
    }

    private func currentCursor() -> CGPoint {
        CGEvent(source: source)?.location ?? .zero
    }
}
