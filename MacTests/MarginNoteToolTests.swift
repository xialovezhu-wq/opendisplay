import XCTest
import CoreGraphics

final class MarginNoteToolTests: XCTestCase {
    private func toolbar(selected: MarginNoteDrawingTool?) -> [MarginNoteToolDescriptor] {
        MarginNoteDrawingTool.allCases.map { tool in
            MarginNoteToolDescriptor(tool: tool, selected: selected.map { $0 == tool },
                                     enabled: true)
        }
    }

    func testDrawingGroupMustContainUniquePenEraserAndLasso() {
        let edit = MarginNoteToolDescriptor(tool: .pencil, selected: true, enabled: true)
        XCTAssertFalse(MarginNoteToolSelection.isDrawingGroup([edit]))
        let tools = toolbar(selected: .pen)
        XCTAssertTrue(MarginNoteToolSelection.isDrawingGroup(tools))
        XCTAssertFalse(MarginNoteToolSelection.isDrawingGroup(tools.filter { $0.tool != .lasso }))
        XCTAssertFalse(MarginNoteToolSelection.isDrawingGroup(tools + [tools[0]]))
    }

    func testDoubleTapGoesToEraserThenRestoresTheActualBrush() {
        XCTAssertEqual(MarginNoteToolSelection.target(for: .toggleEraser, tools: toolbar(selected: .pencil),
                                                     lastBrush: nil), .eraser)
        XCTAssertEqual(MarginNoteToolSelection.target(for: .toggleEraser, tools: toolbar(selected: .eraser),
                                                     lastBrush: .pencil), .pencil)
        XCTAssertEqual(MarginNoteToolSelection.target(for: .toggleEraser, tools: toolbar(selected: .eraser),
                                                     lastBrush: .highlighter), .highlighter)
        XCTAssertEqual(MarginNoteToolSelection.target(for: .toggleEraser, tools: toolbar(selected: .eraser),
                                                     lastBrush: nil), .pen)
    }

    func testSqueezeSelectsLassoAndUnknownStateDoesNotGuessToggleDirection() {
        XCTAssertEqual(MarginNoteToolSelection.target(for: .selectLasso, tools: toolbar(selected: .eraser),
                                                     lastBrush: .pen), .lasso)
        XCTAssertNil(MarginNoteToolSelection.target(for: .toggleEraser, tools: toolbar(selected: nil),
                                                   lastBrush: .pen))
        let ambiguous = toolbar(selected: .pen).map {
            MarginNoteToolDescriptor(tool: $0.tool, selected: $0.tool == .eraser || $0.selected == true,
                                     enabled: true)
        }
        XCTAssertNil(MarginNoteToolSelection.target(for: .toggleEraser, tools: ambiguous, lastBrush: nil))
    }

    func testDisabledToolIsNeverTargeted() {
        let tools = toolbar(selected: .pen).map {
            MarginNoteToolDescriptor(tool: $0.tool, selected: $0.selected, enabled: $0.tool != .eraser)
        }
        XCTAssertNil(MarginNoteToolSelection.target(for: .toggleEraser, tools: tools, lastBrush: nil))
    }

    func testExactLabelsAndFilledSuffixSupportObservedMarginNoteButtons() {
        XCTAssertEqual(MarginNoteDrawingTool.identify(label: "Apple Pencil笔尖"), .pen)
        XCTAssertEqual(MarginNoteDrawingTool.identify(label: "橡皮擦，实心"), .eraser)
        XCTAssertEqual(MarginNoteDrawingTool.identify(label: "套索选择"), .lasso)
        XCTAssertEqual(MarginNoteDrawingTool.identify(label: "编辑"), .pencil)
        XCTAssertNil(MarginNoteDrawingTool.identify(label: "编辑文档"))
        XCTAssertNil(MarginNoteDrawingTool.identify(label: "打开橡皮擦设置"))
        XCTAssertTrue(MarginNoteDrawingTool.labelIndicatesSelected("橡皮擦，实心"))
        XCTAssertFalse(MarginNoteDrawingTool.labelIndicatesSelected("橡皮擦"))
    }

    func testTemporaryLassoRestoresEraserAndEveryDrawingToolExactly() {
        let target = MarginNoteToolTarget(pid: 42, windowID: 100)
        for original in MarginNoteDrawingTool.allCases {
            let saved = MarginNoteTemporaryLassoSnapshot.beginning(existing: nil, target: target,
                displayID: 7, tools: toolbar(selected: original))
            XCTAssertEqual(saved?.originalTool, original)
            XCTAssertEqual(saved?.restorationTool(in: toolbar(selected: .lasso)), original)
        }
        XCTAssertNil(MarginNoteToolSelection.target(for: .endTemporaryLasso,
            tools: toolbar(selected: .eraser), lastBrush: .pen))
    }

    func testRepeatedTemporaryBeginNeverSavesTheLassoOverTheOriginalEraser() {
        let target = MarginNoteToolTarget(pid: 42, windowID: 100)
        let first = MarginNoteTemporaryLassoSnapshot.beginning(existing: nil, target: target,
            displayID: 7, tools: toolbar(selected: .eraser))
        let repeated = MarginNoteTemporaryLassoSnapshot.beginning(existing: first, target: target,
            displayID: 7, tools: toolbar(selected: .lasso))
        XCTAssertEqual(repeated, first)
        XCTAssertEqual(repeated?.originalTool, .eraser)
    }

    func testTemporaryToolCannotMoveToAnotherWindowOrDisplay() {
        let target = MarginNoteToolTarget(pid: 42, windowID: 100)
        let first = MarginNoteTemporaryLassoSnapshot.beginning(existing: nil, target: target,
            displayID: 7, tools: toolbar(selected: .pen))
        XCTAssertNil(MarginNoteTemporaryLassoSnapshot.beginning(existing: first,
            target: MarginNoteToolTarget(pid: 42, windowID: 101), displayID: 7, tools: toolbar(selected: .lasso)))
        XCTAssertNil(MarginNoteTemporaryLassoSnapshot.beginning(existing: first,
            target: target, displayID: 8, tools: toolbar(selected: .lasso)))
        XCTAssertNil(MarginNoteTemporaryLassoSnapshot.beginning(existing: nil,
            target: target, displayID: 7, tools: toolbar(selected: nil)))
    }

    func testRestorationDoesNotSubstitutePenForAnUnavailableOriginalTool() {
        let saved = MarginNoteTemporaryLassoSnapshot(target: MarginNoteToolTarget(pid: 42, windowID: 100),
                                                    displayID: 7, originalTool: .eraser)
        let disabled = toolbar(selected: .lasso).map {
            MarginNoteToolDescriptor(tool: $0.tool, selected: $0.selected, enabled: $0.tool != .eraser)
        }
        XCTAssertNil(saved.restorationTool(in: disabled))
    }

    func testQueuedBeginAndEndAreNeverReplacedByTheNextGesture() {
        var buffer = MarginNoteToolRequestBuffer()
        let begin = bound(.beginTemporaryLasso)
        let end = bound(.endTemporaryLasso)
        let toggle = bound(.toggleEraser)
        XCTAssertTrue(buffer.append(begin))
        XCTAssertTrue(buffer.append(end))
        XCTAssertTrue(buffer.append(toggle))
        XCTAssertEqual(buffer.popFirst(), begin)
        XCTAssertEqual(buffer.popFirst(), end)
        XCTAssertEqual(buffer.popFirst(), toggle)
        XCTAssertNil(buffer.popFirst())
    }

    func testReleaseSurvivesLongStrokeTimeoutButObsoleteBeginCanExpire() {
        var buffer = MarginNoteToolRequestBuffer()
        let begin = bound(.beginTemporaryLasso)
        let end = bound(.endTemporaryLasso)
        _ = buffer.append(begin)
        _ = buffer.append(end)
        XCTAssertNil(buffer.expire(end.request.id))
        XCTAssertEqual(buffer.expire(begin.request.id), begin)
        XCTAssertEqual(buffer.popFirst(), end)
    }

    func testReleaseBindingIncludesInFlightBeginAndKeepsDocumentIdentity() {
        var buffer = MarginNoteToolRequestBuffer()
        let begin = bound(.beginTemporaryLasso, windowID: 100)
        XCTAssertEqual(buffer.projectedTemporaryTarget(active: nil, inFlight: begin), begin.target)
        let end = bound(.endTemporaryLasso, windowID: 100)
        _ = buffer.append(end)
        XCTAssertNil(buffer.projectedTemporaryTarget(active: nil, inFlight: begin))
        let nextBegin = bound(.beginTemporaryLasso, windowID: 101)
        _ = buffer.append(nextBegin)
        XCTAssertEqual(buffer.projectedTemporaryTarget(active: begin.target, inFlight: begin), nextBegin.target)
        XCTAssertEqual(buffer.removeAll(), [end, nextBegin])
        XCTAssertTrue(buffer.pending.isEmpty)
    }

    func testTemporaryQueueIsBoundedWithoutReplacingExistingEntries() {
        var buffer = MarginNoteToolRequestBuffer()
        let entries = (0..<MarginNoteToolRequestBuffer.capacity).map { _ in bound(.beginTemporaryLasso) }
        for item in entries { XCTAssertTrue(buffer.append(item)) }
        XCTAssertFalse(buffer.append(bound(.endTemporaryLasso)))
        // The sender handles this explicit full result with guarded restoration.
        XCTAssertEqual(buffer.pending, entries)
    }

    private func bound(_ action: PencilToolAction, windowID: CGWindowID = 100) -> MarginNoteBoundToolRequest {
        MarginNoteBoundToolRequest(request: PencilToolRequest(id: UUID().uuidString, action: action),
                                  target: MarginNoteToolTarget(pid: 42, windowID: windowID))
    }

    func testQueuedTargetDoesNotFollowAnotherWindowInTheSameApp() {
        let first = window(pid: 42, id: 100)
        let second = window(pid: 42, id: 101)
        let received = MarginNoteToolTarget.capture(frontPID: 42, windows: [first, second])
        let afterFocusChange = MarginNoteToolTarget.capture(frontPID: 42, windows: [second, first])
        XCTAssertEqual(received, MarginNoteToolTarget(pid: 42, windowID: 100))
        XCTAssertNotEqual(received, afterFocusChange)
        XCTAssertNotEqual(received, MarginNoteToolTarget(pid: 43, windowID: 100))
    }

    func testTargetCaptureIgnoresOtherAppsOnOtherDisplaysAndNonWindowOverlays() {
        let document = window(pid: 42, id: 100)
        XCTAssertEqual(MarginNoteToolTarget.capture(frontPID: 42,
                         windows: [window(pid: 43, id: 200), document]),
                       MarginNoteToolTarget(pid: 42, windowID: 100))
        XCTAssertEqual(MarginNoteToolTarget.capture(frontPID: 42,
                         windows: [window(pid: 43, id: 200, layer: 25),
                                   window(pid: 43, id: 201, alpha: 0), document]),
                       MarginNoteToolTarget(pid: 42, windowID: 100))
        XCTAssertNil(MarginNoteToolTarget.capture(frontPID: 42, windows: []))
        XCTAssertNil(MarginNoteToolTarget.capture(frontPID: 42, windows: [window(pid: 42, id: 0)]))
    }

    private func window(pid: Int, id: Int, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowNumber as String: NSNumber(value: id),
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowAlpha as String: NSNumber(value: alpha)]
    }
}
