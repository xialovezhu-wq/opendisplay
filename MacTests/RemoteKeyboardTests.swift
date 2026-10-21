import Carbon
import CoreGraphics
import IOKit.hidsystem
import XCTest

final class RemoteKeyboardTests: XCTestCase {
    private func key(_ usage: Int, _ phase: String = "down", modifiers: Int = 0,
                     repeated: Bool = false) -> RemoteKeyEvent {
        RemoteKeyEvent(usage: usage, phase: phase, modifiers: modifiers, isRepeat: repeated)
    }

    func testPhysicalHIDIsNotTreatedAsMacVirtualCode() {
        XCTAssertEqual(RemoteKeyboardMapping.keyCode(for: 0x04), CGKeyCode(kVK_ANSI_A))
        XCTAssertEqual(RemoteKeyboardMapping.keyCode(for: 0x1D), CGKeyCode(kVK_ANSI_Z))
        XCTAssertEqual(RemoteKeyboardMapping.keyCode(for: 0x2C), CGKeyCode(kVK_Space))
        XCTAssertEqual(RemoteKeyboardMapping.keyCode(for: 0x2A), CGKeyCode(kVK_Delete))
        XCTAssertEqual(RemoteKeyboardMapping.keyCode(for: 0x4C), CGKeyCode(kVK_ForwardDelete))
        XCTAssertEqual(RemoteKeyboardMapping.keyCode(for: 0x58), CGKeyCode(kVK_ANSI_KeypadEnter))
        XCTAssertEqual(RemoteKeyboardMapping.keyCode(for: 0xE7), CGKeyCode(kVK_RightCommand))
        XCTAssertNil(RemoteKeyboardMapping.keyCode(for: 0))
        XCTAssertNil(RemoteKeyboardMapping.keyCode(for: 0x66)) // power is not a text key
        XCTAssertNil(RemoteKeyboardMapping.keyCode(for: 0xFFFF))
    }

    func testCommandCUsesPhysicalEventsAndPreservesFlagsUntilCommandUp() {
        var state = RemoteKeyboardState()
        let command = state.consume(key(0xE3, modifiers: 8))
        XCTAssertTrue(command?.isModifier == true)
        XCTAssertEqual(command?.flags, [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))])
        let copyDown = state.consume(key(0x06, modifiers: 8))
        XCTAssertEqual(copyDown?.keyCode, CGKeyCode(kVK_ANSI_C))
        XCTAssertEqual(copyDown?.flags, command?.flags)
        XCTAssertEqual(state.consume(key(0x06, "up", modifiers: 8))?.flags, command?.flags)
        XCTAssertEqual(state.consume(key(0xE3, "up"))?.flags, [])
        XCTAssertTrue(state.heldUsages.isEmpty)
    }

    func testDoubleCommandProducesTwoCompleteModifierTransitions() {
        for usage in [0xE3, 0xE7] {
            var state = RemoteKeyboardState()
            let events = [state.consume(key(usage, modifiers: 8)),
                          state.consume(key(usage, "up")),
                          state.consume(key(usage, modifiers: 8)),
                          state.consume(key(usage, "up"))].compactMap { $0 }
            XCTAssertEqual(events.count, 4)
            XCTAssertEqual(events.map(\.isDown), [true, false, true, false])
            XCTAssertTrue(events.allSatisfy { $0.isModifier })
            let side = CGEventFlags(rawValue: UInt64(usage == 0xE3 ? NX_DEVICELCMDKEYMASK : NX_DEVICERCMDKEYMASK))
            XCTAssertEqual(events.map(\.flags), [[.maskCommand, side], [], [.maskCommand, side], []])
        }
    }

    func testGlobeMapsToFunctionAndReleasesWithoutRepeatingOrSticking() {
        var state = RemoteKeyboardState()
        let fn = RemoteInputProtocol.globeFnUsage
        let down = state.consume(key(fn, modifiers: 32))
        XCTAssertEqual(down?.keyCode, CGKeyCode(kVK_Function))
        XCTAssertEqual(down?.flags, .maskSecondaryFn)
        XCTAssertTrue(down?.isModifier == true)
        XCTAssertNil(state.consume(key(fn, modifiers: 32, repeated: true)))
        XCTAssertEqual(state.consume(key(0x04, modifiers: 32))?.flags, .maskSecondaryFn)
        _ = state.consume(key(0x04, "up", modifiers: 32))
        XCTAssertEqual(state.consume(key(fn, "up", modifiers: 32))?.flags, [])
        _ = state.consume(key(fn, modifiers: 32))
        XCTAssertEqual(state.reset().map(\.flags), [[]])
        XCTAssertNil(state.consume(key(fn, "up")))
    }

    func testRepeatRequiresHeldKeyAndNeverDuplicatesRelease() {
        var state = RemoteKeyboardState()
        XCTAssertNil(state.consume(key(0x04, repeated: true)))
        XCTAssertNotNil(state.consume(key(0x04)))
        XCTAssertNil(state.consume(key(0x04)))
        XCTAssertTrue(state.consume(key(0x04, repeated: true))?.isRepeat == true)
        XCTAssertNotNil(state.consume(key(0x04, "up")))
        XCTAssertNil(state.consume(key(0x04, "up")))
        XCTAssertNil(state.consume(key(0x04, repeated: true)))
    }

    func testModifierDoesNotRepeatAndOppositeShiftRemainsHeld() {
        var state = RemoteKeyboardState()
        _ = state.consume(key(0xE1, modifiers: 1))
        XCTAssertNil(state.consume(key(0xE1, modifiers: 1, repeated: true)))
        _ = state.consume(key(0xE5, modifiers: 1))
        XCTAssertEqual(state.consume(key(0xE1, "up", modifiers: 1))?.flags, [.maskShift, CGEventFlags(rawValue: UInt64(NX_DEVICERSHIFTKEYMASK))])
        XCTAssertEqual(state.consume(key(0xE5, "up"))?.flags, [])
    }

    func testResetReleasesOnlyOwnedKeysOnceAndOrdinaryKeysBeforeModifiers() {
        var state = RemoteKeyboardState()
        _ = state.consume(key(0xE0, modifiers: 2))
        _ = state.consume(key(0x2C, modifiers: 2)) // Mac input-source switch chord
        let releases = state.reset()
        XCTAssertEqual(releases.map(\.usage), [0x2C, 0xE0])
        XCTAssertEqual(releases.map(\.flags), [[.maskControl, CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK))], []])
        XCTAssertTrue(releases.allSatisfy { !$0.isDown && !$0.isRepeat })
        XCTAssertEqual(state.flags, [])
        XCTAssertTrue(state.reset().isEmpty)
        XCTAssertNil(state.consume(key(0xE0, "up")))
        XCTAssertNil(state.consume(key(0x2C, "up")))
    }

    func testInvalidPacketCannotChangeHeldStateOrModifiers() {
        var state = RemoteKeyboardState()
        _ = state.consume(key(0x04))
        XCTAssertNil(state.consume(key(0x04, "up", modifiers: 64)))
        XCTAssertNil(state.consume(key(0xE3, "other", modifiers: 8)))
        XCTAssertNil(state.consume(key(0xE3, modifiers: -1)))
        XCTAssertNil(state.consume(key(0x66, modifiers: 8)))
        XCTAssertEqual(state.heldUsages, [0x04])
        XCTAssertEqual(state.modifiers, 0)
    }

    func testCapsLockSnapshotDoesNotBecomeHeldShift() {
        var state = RemoteKeyboardState()
        XCTAssertEqual(state.consume(key(0x39, modifiers: 16))?.flags, .maskAlphaShift)
        _ = state.consume(key(0x39, "up", modifiers: 16))
        XCTAssertEqual(state.consume(key(0x04, modifiers: 16))?.flags, .maskAlphaShift)
        XCTAssertFalse(state.flags.contains(.maskShift))
    }
}
