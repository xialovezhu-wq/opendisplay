import Carbon
import CoreGraphics
import IOKit.hid
import IOKit.hidsystem

/// Physical keys, not characters: macOS owns layout selection and IME composition.
/// Names come from the SDK's IOHIDUsageTables.h (usage page 0x07) and
/// HIToolbox/Events.h. A USB usage must never be cast directly to CGKeyCode.
enum RemoteKeyboardMapping {
    static func keyCode(for usage: Int) -> CGKeyCode? { codes[usage].map(CGKeyCode.init) }

    static func isModifier(_ usage: Int) -> Bool {
        (Int(kHIDUsage_KeyboardLeftControl)...Int(kHIDUsage_KeyboardRightGUI)).contains(usage)
            || usage == Int(kHIDUsage_KeyboardCapsLock)
            || usage == RemoteInputProtocol.globeFnUsage
    }

    static func modifierBit(for usage: Int) -> Int {
        switch usage {
        case Int(kHIDUsage_KeyboardLeftShift), Int(kHIDUsage_KeyboardRightShift): return 1
        case Int(kHIDUsage_KeyboardLeftControl), Int(kHIDUsage_KeyboardRightControl): return 2
        case Int(kHIDUsage_KeyboardLeftAlt), Int(kHIDUsage_KeyboardRightAlt): return 4
        case Int(kHIDUsage_KeyboardLeftGUI), Int(kHIDUsage_KeyboardRightGUI): return 8
        case RemoteInputProtocol.globeFnUsage: return 32
        default: return 0 // Caps Lock is a toggle, not a held modifier.
        }
    }

    static func flags(for modifiers: Int, heldUsages: Set<Int> = []) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & 1 != 0 { flags.insert(.maskShift) }
        if modifiers & 2 != 0 { flags.insert(.maskControl) }
        if modifiers & 4 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 8 != 0 { flags.insert(.maskCommand) }
        if modifiers & 16 != 0 { flags.insert(.maskAlphaShift) }
        if modifiers & 32 != 0 { flags.insert(.maskSecondaryFn) }
        // Global shortcut listeners can distinguish left/right modifiers via
        // these public IOKit bits, just as they do for a physical Mac keyboard.
        for usage in heldUsages {
            let mask: Int32
            switch usage {
            case 0xE0: mask = NX_DEVICELCTLKEYMASK
            case 0xE1: mask = NX_DEVICELSHIFTKEYMASK
            case 0xE2: mask = NX_DEVICELALTKEYMASK
            case 0xE3: mask = NX_DEVICELCMDKEYMASK
            case 0xE4: mask = NX_DEVICERCTLKEYMASK
            case 0xE5: mask = NX_DEVICERSHIFTKEYMASK
            case 0xE6: mask = NX_DEVICERALTKEYMASK
            case 0xE7: mask = NX_DEVICERCMDKEYMASK
            default: continue
            }
            flags.formUnion(CGEventFlags(rawValue: UInt64(mask)))
        }
        return flags
    }

    private static let codes: [Int: Int] = {
        var result: [Int: Int] = [:]
        result[RemoteInputProtocol.globeFnUsage] = kVK_Function
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D,
                       kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
                       kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
                       kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
                       kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
                       kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
                       kVK_ANSI_Y, kVK_ANSI_Z]
        for (offset, code) in letters.enumerated() {
            result[Int(kHIDUsage_KeyboardA) + offset] = code
        }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0]
        for (offset, code) in digits.enumerated() {
            result[Int(kHIDUsage_Keyboard1) + offset] = code
        }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (offset, code) in functionKeys.enumerated() {
            result[Int(kHIDUsage_KeyboardF1) + offset] = code
        }
        for (offset, code) in [kVK_F13, kVK_F14, kVK_F15, kVK_F16,
                               kVK_F17, kVK_F18, kVK_F19, kVK_F20].enumerated() {
            result[Int(kHIDUsage_KeyboardF13) + offset] = code
        }
        let other: [(Int, Int)] = [
            (kHIDUsage_KeyboardReturnOrEnter, kVK_Return),
            (kHIDUsage_KeyboardEscape, kVK_Escape),
            (kHIDUsage_KeyboardDeleteOrBackspace, kVK_Delete),
            (kHIDUsage_KeyboardTab, kVK_Tab), (kHIDUsage_KeyboardSpacebar, kVK_Space),
            (kHIDUsage_KeyboardHyphen, kVK_ANSI_Minus),
            (kHIDUsage_KeyboardEqualSign, kVK_ANSI_Equal),
            (kHIDUsage_KeyboardOpenBracket, kVK_ANSI_LeftBracket),
            (kHIDUsage_KeyboardCloseBracket, kVK_ANSI_RightBracket),
            (kHIDUsage_KeyboardBackslash, kVK_ANSI_Backslash),
            (kHIDUsage_KeyboardNonUSPound, kVK_ANSI_Backslash),
            (kHIDUsage_KeyboardSemicolon, kVK_ANSI_Semicolon),
            (kHIDUsage_KeyboardQuote, kVK_ANSI_Quote),
            (kHIDUsage_KeyboardGraveAccentAndTilde, kVK_ANSI_Grave),
            (kHIDUsage_KeyboardComma, kVK_ANSI_Comma),
            (kHIDUsage_KeyboardPeriod, kVK_ANSI_Period),
            (kHIDUsage_KeyboardSlash, kVK_ANSI_Slash),
            (kHIDUsage_KeyboardCapsLock, kVK_CapsLock),
            (kHIDUsage_KeyboardInsert, kVK_Help),
            (kHIDUsage_KeyboardHome, kVK_Home), (kHIDUsage_KeyboardEnd, kVK_End),
            (kHIDUsage_KeyboardPageUp, kVK_PageUp),
            (kHIDUsage_KeyboardPageDown, kVK_PageDown),
            (kHIDUsage_KeyboardDeleteForward, kVK_ForwardDelete),
            (kHIDUsage_KeyboardLeftArrow, kVK_LeftArrow),
            (kHIDUsage_KeyboardRightArrow, kVK_RightArrow),
            (kHIDUsage_KeyboardUpArrow, kVK_UpArrow),
            (kHIDUsage_KeyboardDownArrow, kVK_DownArrow),
            (kHIDUsage_KeypadNumLock, kVK_ANSI_KeypadClear),
            (kHIDUsage_KeypadSlash, kVK_ANSI_KeypadDivide),
            (kHIDUsage_KeypadAsterisk, kVK_ANSI_KeypadMultiply),
            (kHIDUsage_KeypadHyphen, kVK_ANSI_KeypadMinus),
            (kHIDUsage_KeypadPlus, kVK_ANSI_KeypadPlus),
            (kHIDUsage_KeypadEnter, kVK_ANSI_KeypadEnter),
            (kHIDUsage_Keypad0, kVK_ANSI_Keypad0),
            (kHIDUsage_Keypad1, kVK_ANSI_Keypad1),
            (kHIDUsage_Keypad2, kVK_ANSI_Keypad2),
            (kHIDUsage_Keypad3, kVK_ANSI_Keypad3),
            (kHIDUsage_Keypad4, kVK_ANSI_Keypad4),
            (kHIDUsage_Keypad5, kVK_ANSI_Keypad5),
            (kHIDUsage_Keypad6, kVK_ANSI_Keypad6),
            (kHIDUsage_Keypad7, kVK_ANSI_Keypad7),
            (kHIDUsage_Keypad8, kVK_ANSI_Keypad8),
            (kHIDUsage_Keypad9, kVK_ANSI_Keypad9),
            (kHIDUsage_KeypadPeriod, kVK_ANSI_KeypadDecimal),
            (kHIDUsage_KeypadEqualSign, kVK_ANSI_KeypadEquals),
            (kHIDUsage_KeyboardNonUSBackslash, kVK_ISO_Section),
            (kHIDUsage_KeyboardLeftControl, kVK_Control),
            (kHIDUsage_KeyboardLeftShift, kVK_Shift),
            (kHIDUsage_KeyboardLeftAlt, kVK_Option),
            (kHIDUsage_KeyboardLeftGUI, kVK_Command),
            (kHIDUsage_KeyboardRightControl, kVK_RightControl),
            (kHIDUsage_KeyboardRightShift, kVK_RightShift),
            (kHIDUsage_KeyboardRightAlt, kVK_RightOption),
            (kHIDUsage_KeyboardRightGUI, kVK_RightCommand)
        ]
        for (usage, code) in other { result[usage] = code }
        return result
    }()
}

struct RemoteKeyboardTransition {
    let usage: Int
    let keyCode: CGKeyCode
    let isDown: Bool
    let isRepeat: Bool
    let flags: CGEventFlags
    var isModifier: Bool { RemoteKeyboardMapping.isModifier(usage) }
}

/// Session-local ownership. Reset never emits a global release-all sequence.
struct RemoteKeyboardState {
    private(set) var heldUsages: Set<Int> = []
    private(set) var modifiers = 0
    var flags: CGEventFlags { RemoteKeyboardMapping.flags(for: modifiers, heldUsages: heldUsages) }

    mutating func consume(_ event: RemoteKeyEvent) -> RemoteKeyboardTransition? {
        guard let code = RemoteKeyboardMapping.keyCode(for: event.usage),
              event.modifiers >= 0, event.modifiers & ~63 == 0,
              event.phase == "down" || event.phase == "up" else { return nil }
        let isDown = event.phase == "down"
        if isDown {
            if heldUsages.contains(event.usage) {
                guard event.isRepeat, !RemoteKeyboardMapping.isModifier(event.usage) else { return nil }
            } else {
                // A repeat after a reset is stale; it must not start a new press.
                guard !event.isRepeat else { return nil }
                heldUsages.insert(event.usage)
            }
        } else {
            guard !event.isRepeat, heldUsages.remove(event.usage) != nil else { return nil }
        }
        modifiers = event.modifiers
        // UIKit reports modifiers after the transition. Keep the same semantics,
        // including a remaining right/left modifier of the same kind.
        let bit = RemoteKeyboardMapping.modifierBit(for: event.usage)
        if bit != 0 {
            if isDown || heldUsages.contains(where: { RemoteKeyboardMapping.modifierBit(for: $0) == bit }) {
                modifiers |= bit
            } else {
                modifiers &= ~bit
            }
        }
        return RemoteKeyboardTransition(usage: event.usage, keyCode: code,
                                        isDown: isDown, isRepeat: event.isRepeat, flags: flags)
    }

    mutating func reset() -> [RemoteKeyboardTransition] {
        // Release ordinary keys with their current chord, then release modifiers.
        let ordered = heldUsages.sorted {
            let lm = RemoteKeyboardMapping.isModifier($0), rm = RemoteKeyboardMapping.isModifier($1)
            return lm == rm ? $0 < $1 : !lm
        }
        var result: [RemoteKeyboardTransition] = []
        for usage in ordered {
            heldUsages.remove(usage)
            let bit = RemoteKeyboardMapping.modifierBit(for: usage)
            if bit != 0 && !heldUsages.contains(where: { RemoteKeyboardMapping.modifierBit(for: $0) == bit }) {
                modifiers &= ~bit
            }
            if let code = RemoteKeyboardMapping.keyCode(for: usage) {
                result.append(RemoteKeyboardTransition(usage: usage, keyCode: code,
                                                       isDown: false, isRepeat: false, flags: flags))
            }
        }
        modifiers = 0
        return result
    }
}
