import XCTest

final class RemoteInputProtocolTests: XCTestCase {
    func testValidPhysicalKeyAndModifierSnapshot() {
        let key = RemoteKeyEvent.parse(["usage": 4, "phase": "down", "modifiers": 9, "repeat": false])
        XCTAssertEqual(key, RemoteKeyEvent(usage: 4, phase: "down", modifiers: 9, isRepeat: false))
        XCTAssertEqual(key?.json["type"] as? String, RemoteInputProtocol.keyMessage)
    }

    func testObservedGlobeUsageIsExplicitlySupportedWithoutOpeningOtherSpecialCodes() {
        XCTAssertEqual(RemoteInputProtocol.keyboardCapability, "study.keyboard-hid.v2")
        XCTAssertNotNil(RemoteKeyEvent.parse(["usage": 0x29D, "phase": "down", "modifiers": 32]))
        XCTAssertNotNil(RemoteKeyEvent.parse(["usage": 0x29D, "phase": "up", "modifiers": 0]))
        XCTAssertNil(RemoteKeyEvent.parse(["usage": 0x29C, "phase": "down", "modifiers": 32]))
        XCTAssertNil(RemoteKeyEvent.parse(["usage": 0x29E, "phase": "down", "modifiers": 32]))
    }

    func testMalformedInputCannotBecomeAKey() {
        for usage in [true, 4.5, "4", 0, 232, Double.infinity] as [Any] {
            XCTAssertNil(RemoteKeyEvent.parse(["usage": usage, "phase": "down", "modifiers": 0]))
        }
        XCTAssertNil(RemoteKeyEvent.parse(["usage": 4, "phase": "down", "modifiers": true]))
        XCTAssertNil(RemoteKeyEvent.parse(["usage": 4, "phase": "down", "modifiers": 64]))
        XCTAssertNil(RemoteKeyEvent.parse(["usage": 4, "phase": "unknown", "modifiers": 0]))
        XCTAssertNil(RemoteKeyEvent.parse(["usage": 4, "phase": "up", "modifiers": 0, "repeat": true]))
        XCTAssertNil(RemoteKeyEvent.parse(["usage": 4, "phase": "down", "modifiers": 0, "repeat": 1]))
    }

    func testOnlyExplicitToolCommandsWithRequestIdentityAreAccepted() {
        let id = UUID().uuidString
        XCTAssertEqual(PencilToolRequest.parse(["id": id, "action": "selectLasso"]),
                       PencilToolRequest(id: id, action: .selectLasso))
        XCTAssertNil(PencilToolRequest.parse(["id": "", "action": "selectLasso"]))
        XCTAssertNil(PencilToolRequest.parse(["id": id, "action": "delete"]))
        XCTAssertNil(PencilToolRequest.parse(["action": "toggleEraser"]))
    }

    func testTemporaryLassoRequiresExplicitV2CapabilityAndRetainsV1Actions() {
        XCTAssertEqual(RemoteInputProtocol.toolsCapability, "study.pencil-tools.v2")
        XCTAssertTrue(RemoteInputProtocol.capabilities.contains(RemoteInputProtocol.legacyToolsCapability))
        XCTAssertTrue(PencilToolAction.beginTemporaryLasso.requiresTemporaryToolsCapability)
        XCTAssertTrue(PencilToolAction.endTemporaryLasso.requiresTemporaryToolsCapability)
        XCTAssertFalse(PencilToolAction.selectLasso.requiresTemporaryToolsCapability)
        XCTAssertFalse(PencilToolAction.toggleEraser.requiresTemporaryToolsCapability)
        for action in [PencilToolAction.beginTemporaryLasso, .endTemporaryLasso] {
            let id = UUID().uuidString
            XCTAssertEqual(PencilToolRequest.parse(["id": id, "action": action.rawValue]),
                           PencilToolRequest(id: id, action: action))
        }
    }
}
