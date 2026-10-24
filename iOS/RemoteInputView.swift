import UIKit
import GameController

/// First-responder input for the existing video view. It has no text-input
/// traits or hidden text field, so UIKit cannot also send composed characters.
class RemoteInputView: UIView, UIPencilInteractionDelegate {
    weak var receiver: StreamReceiver?
    var remoteInputEnabled = false

    private var keyboard = RemoteKeyboardState()
    private var pencilActions = DeferredPencilActions<PencilToolAction>()
    private var keyboardAvailable = false
    private var pencilAvailable = false
    private var lifecycleSuspended = false
    private var repeatTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var focusRecovery = RemoteInputFocusRecovery()
    private var focusWork: DispatchWorkItem?
    private var didLogFirstKeyboardEvent = false
    private lazy var pencilInteraction: UIPencilInteraction = {
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        interaction.isEnabled = false
        return interaction
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addInteraction(pencilInteraction)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.lifecycleSuspended = true
            self?.synchronizeRemoteInput()
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.lifecycleSuspended = false
            self?.synchronizeRemoteInput()
            self?.requestFocusRecovery(reason: "app-active")
        })
        observers.append(center.addObserver(forName: UIScene.willDeactivateNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            guard let self, let scene = notification.object as? UIScene,
                  scene === self.window?.windowScene else { return }
            self.lifecycleSuspended = true
            self.synchronizeRemoteInput()
        })
        observers.append(center.addObserver(forName: UIScene.didActivateNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            guard let self, let scene = notification.object as? UIScene,
                  scene === self.window?.windowScene else { return }
            self.lifecycleSuspended = false
            self.synchronizeRemoteInput()
            self.requestFocusRecovery(reason: "scene-active")
        })
        observers.append(center.addObserver(forName: UIWindow.didResignKeyNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            guard let self, let window = notification.object as? UIWindow,
                  window === self.window else { return }
            self.cancelFocusRecovery(reason: "window-resigned-key")
            self.releaseRemoteInput()
            self.synchronizeRemoteInput()
        })
        observers.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            guard let self, let window = notification.object as? UIWindow,
                  window === self.window else { return }
            self.synchronizeRemoteInput()
            self.requestFocusRecovery(reason: "window-key")
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.synchronizeRemoteInput()
            self?.requestFocusRecovery(reason: "keyboard-connected")
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        repeatTimer?.invalidate()
        focusWork?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override var canBecomeFirstResponder: Bool { keyboardAvailable || pencilAvailable }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window?.windowScene?.activationState == .foregroundActive { lifecycleSuspended = false }
        synchronizeRemoteInput()
        requestFocusRecovery(reason: "view-attached")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window {
            cancelFocusRecovery(reason: "view-moving")
            releaseRemoteInput()
        }
        super.willMove(toWindow: newWindow)
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            releaseRemoteInput()
            // UIKit may still be assigning the new responder. Inspect local
            // editors only on the queued turn, never steal focus synchronously.
            requestFocusRecovery(reason: "resigned")
        }
        return didResign
    }

    /// Called on capability, connection, scene, and presentation changes.
    func synchronizeRemoteInput() {
        let active = isRemoteInputEligible
        let nextKeyboard = active && receiver?.supportsKeyboardInput == true
        let nextPencil = active && receiver?.supportsPencilToolInput == true
        let becameEligible = nextKeyboard && !keyboardAvailable || nextPencil && !pencilAvailable
        if keyboardAvailable && !nextKeyboard || pencilAvailable && !nextPencil {
            releaseRemoteInput()
        }
        keyboardAvailable = nextKeyboard
        pencilAvailable = nextPencil
        pencilInteraction.isEnabled = nextPencil
        if nextKeyboard || nextPencil {
            // Network/performance updates must not replenish an exhausted
            // budget. Only a false-to-true eligibility edge starts one here.
            if becameEligible { requestFocusRecovery(reason: "eligible") }
        } else if isFirstResponder {
            cancelFocusRecovery(reason: "disabled")
            resignFirstResponder()
        } else {
            cancelFocusRecovery(reason: "disabled")
        }
    }

    private var isRemoteInputEligible: Bool {
        remoteInputEnabled && !lifecycleSuspended && window?.isKeyWindow == true
            && window?.windowScene?.activationState == .foregroundActive
            && receiver?.connected == true
    }

    /// SwiftUI calls this after an actual local-sheet dismissal, not merely
    /// when its binding changes before UIKit finishes dismissing its editor.
    func localPresentationDidDismiss() {
        synchronizeRemoteInput()
        requestFocusRecovery(reason: "local-dismissed")
    }

    private func requestFocusRecovery(reason: String) {
        guard isRemoteInputEligible,
              receiver?.supportsKeyboardInput == true || receiver?.supportsPencilToolInput == true,
              let attempt = focusRecovery.request() else { return }
        enqueueFocusAttempt(attempt, reason: reason)
    }

    private func enqueueFocusAttempt(_ attempt: RemoteInputFocusRecovery.Attempt, reason: String) {
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restoreFocus(attempt, reason: reason) }
        focusWork = work
        // Even attempt zero is asynchronous, after UIKit/SwiftUI hierarchy
        // and responder changes finish on the current main-queue turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + attempt.delay, execute: work)
    }

    private func restoreFocus(_ attempt: RemoteInputFocusRecovery.Attempt, reason: String) {
        guard focusRecovery.isCurrent(attempt) else { return }
        focusWork = nil
        let eligible = isRemoteInputEligible
            && (receiver?.supportsKeyboardInput == true || receiver?.supportsPencilToolInput == true)
        let blocked = eligible && isLocalUIUsingFocus
        let preparation = focusRecovery.prepare(attempt, eligible: eligible,
                                                blockedByLocalUI: blocked, focused: isFirstResponder)
        let source = reason == "touch" ? "touch" : "automatic/\(reason)"
        switch preparation {
        case .acquire:
            // Recompute capability flags immediately before UIKit reads
            // canBecomeFirstResponder, rather than trusting an old snapshot.
            keyboardAvailable = receiver?.supportsKeyboardInput == true
            pencilAvailable = receiver?.supportsPencilToolInput == true
            let acquired = becomeFirstResponder() && isFirstResponder
            Log.info("Input focus: source=\(source) attempt=\(attempt.index + 1) success=\(acquired)")
            if acquired { didLogFirstKeyboardEvent = false }
            if let next = focusRecovery.complete(attempt, succeeded: acquired) {
                enqueueFocusAttempt(next, reason: reason)
            }
        case .alreadyFocused:
            Log.info("Input focus: source=\(source) already-focused=true")
        case .blockedByLocalUI:
            Log.info("Input focus: source=\(source) blocked=local-editor-or-modal")
        case .disabled:
            Log.info("Input focus: source=\(source) cancelled=inactive-or-disconnected")
        case .stale:
            break
        }
    }

    private var isLocalUIUsingFocus: Bool {
        guard let window else { return false }
        if window.rootViewController?.presentedViewController != nil { return true }
        func editingResponder(in view: UIView) -> Bool {
            if view !== self && view.isFirstResponder && (view is UITextInput || view is UIKeyInput) {
                return true
            }
            return view.subviews.contains(where: editingResponder)
        }
        return editingResponder(in: window)
    }

    private func cancelFocusRecovery(reason: String) {
        if focusRecovery.pending != nil { Log.info("Input focus: cancelled=\(reason)") }
        focusWork?.cancel()
        focusWork = nil
        focusRecovery.invalidate()
    }

    /// Cancels queued gestures and always resets the peer while this view
    /// owns a negotiated input session, even if no local key remains down.
    func releaseRemoteInput() {
        didLogFirstKeyboardEvent = false
        repeatTimer?.invalidate()
        repeatTimer = nil
        for event in keyboard.reset() { send(event) }
        if keyboardAvailable || pencilAvailable {
            remoteInputWillReset()
            receiver?.sendInputReset()
        }
        pencilActions.reset()
    }

    /// The peer's reset also releases a pointer drag. Subclasses must forget
    /// matching local stroke state before subsequent motion begins a new one.
    func remoteInputWillReset() {}

    func focusRemoteInput() {
        if !isFirstResponder { requestFocusRecovery(reason: "touch") }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        diagnoseSpecialPresses(presses, event: event, callback: "began")
        guard keyboardAvailable, isFirstResponder else {
            super.pressesBegan(presses, with: event)
            return
        }
        if !didLogFirstKeyboardEvent, presses.contains(where: { $0.key != nil }) {
            Log.info("Keyboard first event after focus: count=\(presses.count)")
            didLogFirstKeyboardEvent = true
        }
        var unhandled: Set<UIPress> = []
        let ordered = presses.sorted {
            RemoteKeyboardState.modifierBit(for: $0.key.map { Int($0.keyCode.rawValue) } ?? 0)
                > RemoteKeyboardState.modifierBit(for: $1.key.map { Int($0.keyCode.rawValue) } ?? 0)
        }
        for press in ordered {
            guard let key = press.key,
                  RemoteKeyboardState.accepts(Int(key.keyCode.rawValue)) else {
                unhandled.insert(press)
                continue
            }
            let previousRepeat = keyboard.repeatUsage
            if let outgoing = keyboard.down(usage: Int(key.keyCode.rawValue),
                                            modifiers: Self.modifiers(for: key, event: event)) {
                send(outgoing)
                if keyboard.repeatUsage != previousRepeat { restartRepeatTimer() }
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        diagnoseSpecialPresses(presses, event: event, callback: "ended")
        guard keyboardAvailable, isFirstResponder else {
            super.pressesEnded(presses, with: event)
            return
        }
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key,
                  RemoteKeyboardState.accepts(Int(key.keyCode.rawValue)) else {
                unhandled.insert(press)
                continue
            }
            if let outgoing = keyboard.up(usage: Int(key.keyCode.rawValue),
                                          modifiers: Self.modifiers(for: key, event: event)) {
                send(outgoing)
            }
        }
        if keyboard.repeatUsage == nil {
            repeatTimer?.invalidate()
            repeatTimer = nil
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        diagnoseSpecialPresses(presses, event: event, callback: "cancelled")
        releaseRemoteInput()
        super.pressesCancelled(presses, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Observe delivery without inventing a down/up transition from flags:
        // UIKit defines changed for a moving/analog button, not a key release.
        diagnoseSpecialPresses(presses, event: event, callback: "changed")
        super.pressesChanged(presses, with: event)
    }

    private func diagnoseSpecialPresses(_ presses: Set<UIPress>, event: UIPressesEvent?,
                                       callback: String) {
        #if DEBUG
        for press in presses {
            if let key = press.key {
                let usage = Int(key.keyCode.rawValue)
                guard RemoteKeyboardState.shouldDiagnose(usage) else { continue }
                Log.info("Keyboard special in: callback=\(callback) phase=\(press.phase.rawValue)"
                         + " usage=\(usage) keyFlags=\(key.modifierFlags.rawValue)"
                         + " eventFlags=\(event?.modifierFlags.rawValue ?? 0)"
                         + " available=\(keyboardAvailable) focused=\(isFirstResponder)")
            } else {
                Log.info("Keyboard noUIKey in: callback=\(callback) phase=\(press.phase.rawValue)"
                         + " pressType=\(press.type.rawValue) eventFlags=\(event?.modifierFlags.rawValue ?? 0)"
                         + " available=\(keyboardAvailable) focused=\(isFirstResponder)")
            }
        }
        #endif
    }

    private func restartRepeatTimer() {
        repeatTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.keyboardAvailable, self.isFirstResponder,
                  let event = self.keyboard.repeatedEvent() else { return }
            self.send(event)
        }
        timer.fireDate = Date(timeIntervalSinceNow: 0.45)
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func send(_ event: RemoteKeyboardState.Event) {
        #if DEBUG
        if RemoteKeyboardState.isCommandUsage(event.usage) {
            Log.info("Keyboard Command out: usage=\(event.usage) phase=\(event.phase)"
                     + " modifiers=\(event.modifiers) repeat=\(event.isRepeat)")
        } else if event.usage == RemoteKeyboardState.observedFunctionUsage {
            Log.info("Keyboard Function out: usage=\(event.usage) phase=\(event.phase)"
                     + " modifiers=\(event.modifiers) repeat=\(event.isRepeat)")
        }
        #endif
        receiver?.sendKey(usage: event.usage, phase: event.phase,
                          modifiers: event.modifiers, isRepeat: event.isRepeat)
    }

    private static func modifiers(for key: UIKey, event: UIPressesEvent?) -> Int {
        let raw = RemoteKeyboardState.modifierSnapshot(keyFlags: key.modifierFlags.rawValue,
                                                       eventFlags: event?.modifierFlags.rawValue)
        let flags = UIKeyModifierFlags(rawValue: raw)
        var value = 0
        if flags.contains(.shift) { value |= 1 }
        if flags.contains(.control) { value |= 2 }
        if flags.contains(.alternate) { value |= 4 }
        if flags.contains(.command) { value |= 8 }
        if flags.contains(.alphaShift) { value |= 16 }
        // The physical Globe/Fn test on this iPad delivered raw flag 1 << 23.
        // This uses public OptionSet access, not a claimed named SDK constant.
        if flags.contains(UIKeyModifierFlags(rawValue: 1 << 23)) { value |= 32 }
        return value
    }

    func pencilContactsBegan(_ touches: Set<UITouch>) {
        for touch in touches where touch.type == .pencil {
            pencilActions.began(contact: ObjectIdentifier(touch).hashValue)
        }
    }

    /// Invoke only AFTER the existing stroke engine sends its up/cancel packet.
    func pencilContactsEnded(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches where touch.type == .pencil {
            emit(pencilActions.ended(contact: ObjectIdentifier(touch).hashValue,
                                     cancelled: cancelled))
        }
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        // New UIKit invokes the richer delegate. Handling only that callback
        // on 17.5+ avoids a double toggle should both methods be called.
        if #available(iOS 17.5, *) { return }
        request(.toggleEraser)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveTap tap: UIPencilInteraction.Tap) {
        request(.toggleEraser)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard pencilAvailable, isFirstResponder else { return }
        switch squeeze.phase {
        case .began:
            Log.info("Pencil squeeze: began")
            emit(pencilActions.beginTemporaryAction(begin: .beginTemporaryLasso,
                                                    end: .endTemporaryLasso))
        case .ended, .cancelled:
            Log.info("Pencil squeeze: \(squeeze.phase == .ended ? "ended" : "cancelled")")
            emit(pencilActions.endTemporaryAction())
        case .changed:
            break
        @unknown default:
            // An unknown terminal phase must not leave a temporary tool held.
            emit(pencilActions.endTemporaryAction())
        }
    }

    private func request(_ action: PencilToolAction) {
        guard pencilAvailable, isFirstResponder else { return }
        emit(pencilActions.request(action))
    }

    private func emit(_ actions: [PencilToolAction]) {
        guard pencilAvailable, isFirstResponder else { return }
        for action in actions { receiver?.sendToolAction(action) }
    }
}
