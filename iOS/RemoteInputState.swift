import Foundation

/// Platform-independent physical-key bookkeeping. The wire uses USB HID
/// usages, never locally composed text: the Mac owns its layout and IME.
struct RemoteKeyboardState {
    struct Event: Equatable {
        let usage: Int
        let phase: String
        let modifiers: Int
        let isRepeat: Bool
    }

    private(set) var held: Set<Int> = []
    private(set) var modifiers = 0
    private(set) var repeatUsage: Int?

    /// Public UIKey.keyCode.rawValue observed repeatedly for Globe/Fn on the
    /// paired iPad Magic Keyboard (2026-10-21). UIKit has no named constant.
    static let observedFunctionUsage = 0x29D

    static func modifierBit(for usage: Int) -> Int {
        switch usage {
        case 0xE1, 0xE5: return 1 // Shift
        case 0xE0, 0xE4: return 2 // Control
        case 0xE2, 0xE6: return 4 // Option
        case 0xE3, 0xE7: return 8 // Command
        case observedFunctionUsage: return 32 // Function, measured on this keyboard
        default: return 0
        }
    }

    static func accepts(_ usage: Int) -> Bool {
        (0x04...0xA4).contains(usage) || (0xE0...0xE7).contains(usage)
            || usage == observedFunctionUsage
    }

    static func isCommandUsage(_ usage: Int) -> Bool {
        usage == 0xE3 || usage == 0xE7
    }

    /// Deliberately excludes letters, digits, punctuation, and other ordinary
    /// keys. Special-key diagnosis must never become a typed-content log.
    static func shouldDiagnose(_ usage: Int) -> Bool {
        isCommandUsage(usage) || usage == observedFunctionUsage || !accepts(usage)
    }

    /// UIKey can retain its down-time flags in an ended callback. The current
    /// event's flags (including zero) are authoritative when UIKit supplies it.
    static func modifierSnapshot(keyFlags: Int, eventFlags: Int?) -> Int {
        eventFlags ?? keyFlags
    }

    mutating func down(usage: Int, modifiers reported: Int) -> Event? {
        guard Self.accepts(usage) else { return nil }
        let inserted = held.insert(usage).inserted
        updateModifiers(reported: reported, changedUsage: usage)
        // UIKit can deliver repeated pressesBegan. A single local timer owns
        // repeats so those callbacks cannot produce double-rate characters.
        guard inserted else { return nil }
        if Self.canRepeat(usage) { repeatUsage = usage }
        return Event(usage: usage, phase: "down", modifiers: modifiers, isRepeat: false)
    }

    mutating func up(usage: Int, modifiers reported: Int) -> Event? {
        guard held.remove(usage) != nil else { return nil }
        updateModifiers(reported: reported, changedUsage: usage)
        if repeatUsage == usage { repeatUsage = nil }
        return Event(usage: usage, phase: "up", modifiers: modifiers, isRepeat: false)
    }

    func repeatedEvent() -> Event? {
        guard let usage = repeatUsage, held.contains(usage),
              modifiers & (2 | 8) == 0 else { return nil }
        return Event(usage: usage, phase: "down", modifiers: modifiers, isRepeat: true)
    }

    mutating func reset() -> [Event] {
        // Release ordinary keys first, then modifiers. Send a final reset on
        // the wire as well, so a missing key-up cannot leave a modifier stuck.
        let usages = held.sorted {
            let l = Self.modifierBit(for: $0), r = Self.modifierBit(for: $1)
            return l == 0 && r != 0 || (l == 0) == (r == 0) && $0 < $1
        }
        let releases = usages.compactMap { up(usage: $0, modifiers: modifiers) }
        held.removeAll()
        modifiers = 0
        repeatUsage = nil
        return releases
    }

    private mutating func updateModifiers(reported: Int, changedUsage: Int) {
        modifiers = reported & 63
        let changedBit = Self.modifierBit(for: changedUsage)
        if changedBit != 0 {
            // Releasing one Shift while its counterpart is held must keep
            // Shift set, even when the callback's flags describe the old state.
            if held.contains(where: { Self.modifierBit(for: $0) == changedBit }) {
                modifiers |= changedBit
            } else {
                modifiers &= ~changedBit
            }
        }
    }

    private static func canRepeat(_ usage: Int) -> Bool {
        // Printable keys, Backspace, Tab, Return, and navigation; never Caps
        // Lock, Escape, function keys, or a standalone modifier.
        ((0x04...0x38).contains(usage) && usage != 0x29)
            || (0x49...0x52).contains(usage)
    }
}

/// Keeps tool changes behind the pen-up packet. A temporary tool follows the
/// current hold state, so a press released before pen-up never leaves a stale
/// queued activation. Cancellation restores an already activated tool.
struct DeferredPencilActions<Action> {
    private var contacts: Set<Int> = []
    private var pending: [Action] = []
    private var temporaryBegin: Action?
    private var temporaryEnd: Action?
    private var temporaryHeld = false
    private var temporaryActive = false
    var hasActiveContact: Bool { !contacts.isEmpty }

    mutating func began(contact: Int) { contacts.insert(contact) }

    mutating func request(_ action: Action) -> [Action] {
        guard hasActiveContact else { return [action] }
        // Bound a pathological event flood without delaying the video path.
        if pending.count < 8 { pending.append(action) }
        return []
    }

    mutating func ended(contact: Int, cancelled: Bool) -> [Action] {
        contacts.remove(contact)
        if cancelled {
            pending.removeAll()
            temporaryHeld = false
        }
        return drainAtPenUp()
    }

    mutating func beginTemporaryAction(begin: Action, end: Action) -> [Action] {
        guard !temporaryHeld else { return [] }
        temporaryHeld = true
        if !temporaryActive {
            temporaryBegin = begin
            temporaryEnd = end
        }
        return drainAtPenUp()
    }

    mutating func endTemporaryAction() -> [Action] {
        temporaryHeld = false
        // No begin has reached the peer: discard it immediately, even if the
        // tip is still down. A later pen-up must not turn a short squeeze into
        // a permanent lasso selection.
        if !temporaryActive {
            temporaryBegin = nil
            temporaryEnd = nil
        }
        return drainAtPenUp()
    }

    mutating func reset() {
        contacts.removeAll()
        pending.removeAll()
        temporaryBegin = nil
        temporaryEnd = nil
        temporaryHeld = false
        temporaryActive = false
        // The caller sends the peer's input-reset packet, which restores any
        // active temporary tool even when focus loss interrupted a stroke.
    }

    private mutating func drainAtPenUp() -> [Action] {
        guard contacts.isEmpty else { return [] }
        var actions: [Action] = []
        if temporaryActive && !temporaryHeld {
            if let temporaryEnd { actions.append(temporaryEnd) }
            temporaryActive = false
        }
        // Apply discrete tool choices to the restored/base tool before a new
        // hold captures it, instead of changing the temporary lasso snapshot.
        actions.append(contentsOf: pending)
        pending.removeAll()
        if temporaryHeld && !temporaryActive, let temporaryBegin {
            actions.append(temporaryBegin)
            temporaryActive = true
        }
        if !temporaryHeld && !temporaryActive {
            temporaryBegin = nil
            temporaryEnd = nil
        }
        return actions
    }
}
