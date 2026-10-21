import Foundation
import CoreFoundation

/// Additive, namespaced extension used by the paired development builds.
/// No capability is inferred from a marketing/protocol version.
enum RemoteInputProtocol {
    /// Separate the paired development receiver from the installed App Store app.
    static var receiverPort: UInt16 {
        #if DEBUG
        return 9001
        #else
        return 9000
        #endif
    }
    static let keyboardCapability = "study.keyboard-hid.v2"
    // Public UIKey.keyCode.rawValue observed for Globe on the paired M4
    // Magic Keyboard/iPadOS 27. No private HID API is used.
    static let globeFnUsage = 0x29D
    static let legacyToolsCapability = "study.pencil-tools.v1"
    static let toolsCapability = "study.pencil-tools.v2"
    static let capabilities = [keyboardCapability, toolsCapability, legacyToolsCapability]
    static let keyMessage = "studyKey"
    static let resetMessage = "studyInputReset"
    static let toolMessage = "studyTool"
    static let resultMessage = "studyInputResult"

    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite,
              n.doubleValue.rounded(.towardZero) == n.doubleValue,
              n.doubleValue >= Double(Int32.min), n.doubleValue <= Double(Int32.max)
        else { return nil }
        return n.intValue
    }
}

struct RemoteKeyEvent: Equatable {
    let usage: Int
    let phase: String
    /// shift=1, control=2, option=4, command=8, capsLock=16, function=32.
    let modifiers: Int
    let isRepeat: Bool

    static func parse(_ object: [String: Any]) -> RemoteKeyEvent? {
        guard let usage = RemoteInputProtocol.integer(object["usage"]),
              ((4...0xE7).contains(usage) || usage == RemoteInputProtocol.globeFnUsage),
              let phase = object["phase"] as? String, ["down", "up"].contains(phase),
              let modifiers = RemoteInputProtocol.integer(object["modifiers"]),
              (0...63).contains(modifiers) else { return nil }
        var repeated = false
        if let value = object["repeat"] {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID()
            else { return nil }
            repeated = n.boolValue
        }
        guard phase == "down" || !repeated else { return nil }
        return RemoteKeyEvent(usage: usage, phase: phase, modifiers: modifiers, isRepeat: repeated)
    }

    var json: [String: Any] {
        ["type": RemoteInputProtocol.keyMessage, "usage": usage, "phase": phase,
         "modifiers": modifiers, "repeat": isRepeat]
    }
}

enum PencilToolAction: String, CaseIterable {
    case toggleEraser
    case selectLasso
    case beginTemporaryLasso
    case endTemporaryLasso

    var requiresTemporaryToolsCapability: Bool {
        self == .beginTemporaryLasso || self == .endTemporaryLasso
    }
}

struct PencilToolRequest: Equatable {
    let id: String
    let action: PencilToolAction

    static func parse(_ object: [String: Any]) -> PencilToolRequest? {
        guard let id = object["id"] as? String, UUID(uuidString: id) != nil,
              let raw = object["action"] as? String,
              let action = PencilToolAction(rawValue: raw) else { return nil }
        return PencilToolRequest(id: id, action: action)
    }
}
