import AppKit
import ApplicationServices

enum MarginNoteDrawingTool: String, CaseIterable {
    case pen, pencil, highlighter, eraser, lasso

    var isBrush: Bool { self == .pen || self == .pencil || self == .highlighter }

    /// Deliberately exact names. In particular, “编辑” is meaningful only after
    /// the containing sibling group has both an eraser and a lasso.
    static func identify(label: String) -> Self? {
        let base = label.components(separatedBy: CharacterSet(charactersIn: "，,"))[0]
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch base {
        case "apple pencil笔尖", "apple pencil 笔尖", "apple pencil tip", "pen tip": return .pen
        case "编辑", "edit", "pencil": return .pencil
        case "高亮标记", "highlighter": return .highlighter
        case "橡皮擦", "eraser": return .eraser
        case "套索选择", "lasso selection", "lasso": return .lasso
        default: return nil
        }
    }

    static func labelIndicatesSelected(_ label: String) -> Bool {
        let suffixes = label.components(separatedBy: CharacterSet(charactersIn: "，,"))
            .dropFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return suffixes.contains("实心") || suffixes.contains("filled")
    }
}

struct MarginNoteToolDescriptor {
    let tool: MarginNoteDrawingTool
    let selected: Bool?
    let enabled: Bool
}

/// Pure selection policy, independently tested without sending AX actions.
enum MarginNoteToolSelection {
    static func isDrawingGroup(_ tools: [MarginNoteToolDescriptor]) -> Bool {
        // A generic Edit button, PDF text controls, and menus cannot qualify.
        guard tools.count >= 3, tools.count <= 8 else { return false }
        for kind in [MarginNoteDrawingTool.pen, .eraser, .lasso] {
            guard tools.filter({ $0.tool == kind }).count == 1 else { return false }
        }
        return Set(tools.map(\.tool)).count == tools.count
    }

    static func target(for action: PencilToolAction, tools: [MarginNoteToolDescriptor],
                       lastBrush: MarginNoteDrawingTool?) -> MarginNoteDrawingTool? {
        guard isDrawingGroup(tools) else { return nil }
        if action == .selectLasso || action == .beginTemporaryLasso {
            return tools.first(where: { $0.tool == .lasso && $0.enabled })?.tool
        }
        // An end must restore its saved tool, never follow toggle-eraser logic.
        guard action == .toggleEraser else { return nil }
        let selected = tools.filter { $0.selected == true }
        guard selected.count == 1 else { return nil }
        if selected[0].tool == .eraser {
            if let lastBrush, lastBrush.isBrush,
               tools.contains(where: { $0.tool == lastBrush && $0.enabled }) { return lastBrush }
            return tools.first(where: { $0.tool == .pen && $0.enabled })?.tool
        }
        return tools.first(where: { $0.tool == .eraser && $0.enabled })?.tool
    }
}

/// The WindowServer identity captured when the gesture arrives. Reading this
/// list does not send AX IPC to MarginNote, so a busy app cannot block the
/// transport queue while its request is being bound to a window.
struct MarginNoteToolTarget: Equatable {
    let pid: pid_t
    let windowID: CGWindowID

    static func capture(frontPID: pid_t, windows: [[String: Any]]) -> Self? {
        // WindowServer ordering spans every display. Bind the foremost normal
        // window belonging to the known foreground app, not an unrelated
        // window on another display. Execution still validates AXFocusedWindow
        // and requires the document and tools to be on the iPad display.
        guard let front = windows.first(where: { window in
            (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontPID
                && (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
        }), let pid = front[kCGWindowOwnerPID as String] as? NSNumber,
              pid.int32Value == frontPID,
              let number = front[kCGWindowNumber as String] as? NSNumber,
              number.uint32Value != kCGNullWindowID else { return nil }
        return Self(pid: frontPID, windowID: number.uint32Value)
    }
}

/// The original tool belongs to one exact document window and display. A
/// repeated begin cannot replace an eraser/brush with the temporary lasso.
struct MarginNoteTemporaryLassoSnapshot: Equatable {
    let target: MarginNoteToolTarget
    let displayID: CGDirectDisplayID
    let originalTool: MarginNoteDrawingTool

    static func beginning(existing: Self?, target: MarginNoteToolTarget,
                          displayID: CGDirectDisplayID,
                          tools: [MarginNoteToolDescriptor]) -> Self? {
        guard MarginNoteToolSelection.isDrawingGroup(tools) else { return nil }
        if let existing {
            return existing.target == target && existing.displayID == displayID ? existing : nil
        }
        let selected = tools.filter { $0.selected == true }
        guard selected.count == 1 else { return nil }
        return Self(target: target, displayID: displayID, originalTool: selected[0].tool)
    }

    func restorationTool(in tools: [MarginNoteToolDescriptor]) -> MarginNoteDrawingTool? {
        guard MarginNoteToolSelection.isDrawingGroup(tools),
              tools.contains(where: { $0.tool == originalTool && $0.enabled }) else { return nil }
        return originalTool
    }
}

struct MarginNoteBoundToolRequest: Equatable {
    let request: PencilToolRequest
    let target: MarginNoteToolTarget
}

/// A bounded FIFO preserves press/release ordering. End has no stroke timeout:
/// dropping it after three seconds would strand a long lasso stroke in lasso.
struct MarginNoteToolRequestBuffer {
    static let capacity = 16
    private(set) var pending: [MarginNoteBoundToolRequest] = []

    mutating func append(_ request: MarginNoteBoundToolRequest) -> Bool {
        guard pending.count < Self.capacity else { return false }
        pending.append(request)
        return true
    }

    mutating func popFirst() -> MarginNoteBoundToolRequest? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    mutating func expire(_ id: String) -> MarginNoteBoundToolRequest? {
        guard let index = pending.firstIndex(where: { $0.request.id == id }),
              pending[index].request.action != .endTemporaryLasso else { return nil }
        return pending.remove(at: index)
    }

    mutating func removeAll() -> [MarginNoteBoundToolRequest] {
        let removed = pending
        pending.removeAll()
        return removed
    }

    /// Determine which begin an arriving end belongs to, including work still
    /// waiting for AX or pen-up. Never rebind that end to a newly focused window.
    func projectedTemporaryTarget(active: MarginNoteToolTarget?,
                                  inFlight: MarginNoteBoundToolRequest?) -> MarginNoteToolTarget? {
        var target = active
        for entry in (inFlight.map { [$0] } ?? []) + pending {
            if entry.request.action == .beginTemporaryLasso { target = target ?? entry.target }
            if entry.request.action == .endTemporaryLasso { target = nil }
        }
        return target
    }
}

/// MarginNote's accessible drawing tools, not guessed keyboard shortcuts or
/// screen coordinates. AX work runs off the network/main queue with both an
/// IPC timeout and a whole-request deadline. Completion is always on main.
final class MarginNoteToolController {
    private let queue = DispatchQueue(label: "OpenDisplay.MarginNoteTools", qos: .userInitiated)
    private let generationLock = NSLock()
    private var generation: UInt64 = 0
    private let bundleID = "QReader.MarginStudy.easy"
    private let requestLifetime: TimeInterval = 2.5
    private let axTimeout: Float = 0.12

    private struct BrushMemory {
        let window: AXUIElement
        let tool: MarginNoteDrawingTool
    }
    private var brushes: [BrushMemory] = [] // accessed only on queue
    private struct TemporaryLassoSession {
        let snapshot: MarginNoteTemporaryLassoSnapshot
        let window: AXUIElement
    }
    private let temporaryLock = NSLock()
    private var temporarySession: TemporaryLassoSession?

    var activeTemporaryTarget: MarginNoteToolTarget? {
        currentTemporarySession()?.snapshot.target
    }

    /// Cancel queued gestures first, then make one guarded restoration attempt
    /// on the same AX queue. A disconnected/hidden/moved window is never clicked
    /// later when it happens to regain focus.
    func cancelPendingActions(canPerformAction: @escaping () -> Bool = { true },
                              completion: ((Bool, String) -> Void)? = nil) {
        generationLock.lock()
        generation &+= 1
        let token = generation
        generationLock.unlock()
        queue.async {
            guard self.isCurrent(token) else {
                DispatchQueue.main.async { completion?(false, "连接再次重置，旧的恢复请求已取消。") }
                return
            }
            guard let session = self.currentTemporarySession() else {
                DispatchQueue.main.async { completion?(true, "临时套索已结束。") }
                return
            }
            let result = self.execute(.endTemporaryLasso, target: session.snapshot.target,
                                      displayID: session.snapshot.displayID, token: token,
                                      deadline: ProcessInfo.processInfo.systemUptime + self.requestLifetime,
                                      canPerformAction: canPerformAction)
            if self.isCurrent(token) {
                // Cleanup is bounded: a failed safe restoration is reported,
                // not replayed into a future window/session.
                self.setTemporarySession(nil)
                Log.info("Temporary lasso cleanup: \(result.0 ? "restored" : "not restored") — \(result.1)")
            }
            DispatchQueue.main.async { completion?(result.0, result.1) }
        }
    }

    func captureTarget() -> MarginNoteToolTarget? {
        guard let running = NSWorkspace.shared.frontmostApplication,
              running.bundleIdentifier == bundleID, !running.isHidden else {
            Log.info("Pencil target unavailable: foreground=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
            return nil
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        let target = MarginNoteToolTarget.capture(frontPID: running.processIdentifier, windows: windows)
        if target == nil {
            let normal = windows.filter { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
            let owners = normal.prefix(5).map { "\($0[kCGWindowOwnerName as String] ?? "?") alpha=\($0[kCGWindowAlpha as String] ?? "?")" }
            Log.info("Pencil target unavailable: foreground MarginNote; normal window owners=\(owners.joined(separator: "; "))")
        }
        return target
    }

    func perform(_ action: PencilToolAction, target: MarginNoteToolTarget, for displayID: CGDirectDisplayID,
                 canPerformAction: @escaping () -> Bool = { true },
                 completion: @escaping (Bool, String) -> Void) {
        generationLock.lock()
        let token = generation
        generationLock.unlock()
        let deadline = ProcessInfo.processInfo.systemUptime + requestLifetime
        queue.async {
            let result = self.execute(action, target: target, displayID: displayID, token: token, deadline: deadline,
                                      canPerformAction: canPerformAction)
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
    }

    private struct ToolButton {
        let element: AXUIElement
        let descriptor: MarginNoteToolDescriptor
    }
    private struct DrawingGroup {
        let element: AXUIElement
        let buttons: [ToolButton]
    }
    private struct Context {
        let app: AXUIElement
        let target: MarginNoteToolTarget
        let window: AXUIElement
        let displayID: CGDirectDisplayID
    }
    private struct Failure: Error { let message: String }

    private func execute(_ action: PencilToolAction, target: MarginNoteToolTarget, displayID: CGDirectDisplayID,
                         token: UInt64, deadline: TimeInterval,
                         canPerformAction: () -> Bool) -> (Bool, String) {
        do {
            try check(token, deadline)
            let savedSession = currentTemporarySession()
            if action == .endTemporaryLasso, savedSession == nil {
                return (true, "临时套索已结束。") // repeated release is a no-op
            }
            if let savedSession {
                guard action == .beginTemporaryLasso || action == .endTemporaryLasso else {
                    throw Failure(message: "正在临时使用套索，请先松开轻捏再切换其他工具。")
                }
                guard savedSession.snapshot.target == target, savedSession.snapshot.displayID == displayID else {
                    throw Failure(message: "临时套索属于另一个窗口或显示屏，未执行切换。")
                }
            }
            guard AXIsProcessTrusted() else { throw Failure(message: "OpenDisplay 尚无辅助功能权限，无法切换工具。") }
            guard captureTarget() == target else {
                throw Failure(message: "前台窗口已改变，已取消笔身操作。")
            }
            let app = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(app, axTimeout)
            guard let window = elementAttribute(app, kAXFocusedWindowAttribute) else {
                throw Failure(message: "MarginNote 当前没有可操作的前台窗口。")
            }
            if let savedSession, !CFEqual(savedSession.window, window) {
                throw Failure(message: "原来的 MarginNote 文档窗口已改变，未执行临时工具恢复。")
            }
            let context = Context(app: app, target: target, window: window, displayID: displayID)
            try validate(context, token: token, deadline: deadline)
            let group = try findGroup(in: window, token: token, deadline: deadline)
            let descriptors = group.buttons.map(\.descriptor)
            let lastBrush = brushes.first(where: { CFEqual($0.window, window) })?.tool
            let destination: MarginNoteDrawingTool?
            var beginningSession: TemporaryLassoSession?
            if action == .beginTemporaryLasso {
                guard let snapshot = MarginNoteTemporaryLassoSnapshot.beginning(existing: savedSession?.snapshot,
                    target: target, displayID: displayID, tools: descriptors) else {
                    throw Failure(message: "无法确认轻捏前使用的工具，未进入临时套索。")
                }
                beginningSession = savedSession ?? TemporaryLassoSession(snapshot: snapshot, window: window)
                destination = MarginNoteToolSelection.target(for: .beginTemporaryLasso,
                                                            tools: descriptors, lastBrush: lastBrush)
            } else if action == .endTemporaryLasso {
                destination = savedSession?.snapshot.restorationTool(in: descriptors)
            } else {
                destination = MarginNoteToolSelection.target(for: action, tools: descriptors, lastBrush: lastBrush)
            }
            guard let destination,
                  let button = group.buttons.first(where: { $0.descriptor.tool == destination }) else {
                throw Failure(message: "无法确认 MarginNote 当前选中的手写工具；请打开手写工具栏并选一次画笔。")
            }
            let selectedBrush = descriptors.first(where: { $0.selected == true && $0.tool.isBrush })?.tool
            if button.descriptor.selected == true {
                try validate(context, token: token, deadline: deadline)
                try requireIdle(canPerformAction)
                if let beginningSession { setTemporarySession(beginningSession) }
                if action == .endTemporaryLasso { setTemporarySession(nil) }
                return (true, successMessage(for: action, destination: destination))
            }
            // Re-read the exact button and window just before pressing. A toolbar
            // replaced by navigation cannot become an unrelated click target.
            try validate(context, token: token, deadline: deadline)
            guard let current = toolButton(button.element), current.descriptor.tool == destination,
                  current.descriptor.enabled, buttonIsVisible(button.element, in: window, displayID: displayID) else {
                throw Failure(message: "MarginNote 工具栏已隐藏或改变，未执行切换。")
            }
            try validate(context, token: token, deadline: deadline)
            // Cancellation and issuing the action are ordered under this lock.
            // An AXPress already accepted by the app cannot be undone.
            generationLock.lock()
            guard generation == token else {
                generationLock.unlock()
                throw Failure(message: "连接已重置，已取消旧的笔身操作。")
            }
            guard canPerformAction() else {
                generationLock.unlock()
                throw Failure(message: "笔尖已重新落下，已取消本次工具切换；请抬笔后再试。")
            }
            // Save before AXPress, not after readback: if cancellation occurs
            // after the app accepts the press, cleanup still knows what to undo.
            if let beginningSession { setTemporarySession(beginningSession) }
            let pressResult = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
            generationLock.unlock()
            guard pressResult == .success else {
                throw Failure(message: "MarginNote 未接受工具切换（辅助功能错误 \(pressResult.rawValue)）。")
            }
            // Readback may lag one UI turn. Poll only this bounded group; do not
            // rescan another window or repeat AXPress after an unknown result.
            for attempt in 0..<4 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.045) }
                try validate(context, token: token, deadline: deadline)
                try requireIdle(canPerformAction)
                if let updated = readGroup(group.element),
                   updated.buttons.filter({ $0.descriptor.selected == true }).count == 1,
                   updated.buttons.contains(where: { $0.descriptor.tool == destination && $0.descriptor.selected == true }) {
                    if let selectedBrush { remember(selectedBrush, for: window) }
                    if destination.isBrush { remember(destination, for: window) }
                    if action == .endTemporaryLasso { setTemporarySession(nil) }
                    return (true, successMessage(for: action, destination: destination))
                }
            }
            throw Failure(message: "已请求切换，但未能读回选中状态；请检查 MarginNote 手写工具栏。")
        } catch let failure as Failure {
            return (false, failure.message)
        } catch {
            return (false, "无法读取 MarginNote 工具栏：\(error.localizedDescription)")
        }
    }

    private func successMessage(for action: PencilToolAction, destination: MarginNoteDrawingTool) -> String {
        if action == .beginTemporaryLasso { return "按住轻捏：临时套索。松开后恢复先前工具。" }
        if action == .endTemporaryLasso {
            return destination == .eraser ? "已恢复轻捏前的橡皮擦。" : "已恢复轻捏前的工具。"
        }
        switch destination {
        case .eraser: return "已切换到橡皮擦。"
        case .lasso: return "已切换到套索。"
        default: return "已切回画笔。"
        }
    }

    private func currentTemporarySession() -> TemporaryLassoSession? {
        temporaryLock.lock()
        defer { temporaryLock.unlock() }
        return temporarySession
    }

    private func setTemporarySession(_ value: TemporaryLassoSession?) {
        temporaryLock.lock()
        temporarySession = value
        temporaryLock.unlock()
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == token
    }

    private func requireIdle(_ canPerformAction: () -> Bool) throws {
        guard canPerformAction() else {
            throw Failure(message: "笔尖已重新落下，已停止本次工具切换检查；请抬笔后确认工具状态。")
        }
    }

    private func check(_ token: UInt64, _ deadline: TimeInterval) throws {
        generationLock.lock()
        let valid = generation == token
        generationLock.unlock()
        guard valid else { throw Failure(message: "连接已重置，已取消旧的笔身操作。") }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw Failure(message: "读取 MarginNote 工具栏超时；请确认窗口在 iPad 上并已打开手写工具栏。")
        }
    }

    private func validate(_ context: Context, token: UInt64, deadline: TimeInterval) throws {
        try check(token, deadline)
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == context.target.pid, front.bundleIdentifier == bundleID, !front.isHidden,
              captureTarget() == context.target,
              let focused = elementAttribute(context.app, kAXFocusedWindowAttribute), CFEqual(focused, context.window) else {
            throw Failure(message: "前台窗口已改变，已取消笔身操作。")
        }
        guard boolAttribute(context.window, kAXMinimizedAttribute) != true,
              let rect = frame(context.window), rect.width > 0, rect.height > 0,
              CGDisplayIsActive(context.displayID) != 0,
              CGDisplayBounds(context.displayID).contains(CGPoint(x: rect.midX, y: rect.midY)) else {
            throw Failure(message: "MarginNote 当前窗口不在 iPad 显示屏上，未执行切换。")
        }
        try check(token, deadline)
    }

    private func findGroup(in window: AXUIElement, token: UInt64, deadline: TimeInterval) throws -> DrawingGroup {
        var pending: [(AXUIElement, Int)] = [(window, 0)]
        var offset = 0
        var visited: Set<CFHashCode> = []
        var candidates: [DrawingGroup] = []
        let prunedRoles: Set<String> = [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole,
                                        kAXImageRole, "AXWebArea", kAXMenuRole, kAXMenuBarRole,
                                        kAXTableRole, kAXOutlineRole]
        while offset < pending.count {
            try check(token, deadline)
            guard offset < 500 else { throw Failure(message: "MarginNote 界面过于复杂，无法唯一定位手写工具栏。") }
            let (node, depth) = pending[offset]
            offset += 1
            guard visited.insert(CFHash(node)).inserted, depth <= 24 else { continue }
            AXUIElementSetMessagingTimeout(node, axTimeout)
            if boolAttribute(node, kAXHiddenAttribute) == true { continue }
            let role = stringAttribute(node, kAXRoleAttribute) ?? ""
            if prunedRoles.contains(role) { continue }
            if role == kAXButtonRole || role == kAXCheckBoxRole || role == kAXRadioButtonRole { continue }
            let children = childElements(node)
            if let group = readGroup(node, children: children),
               group.buttons.allSatisfy({ buttonIsVisible($0.element, in: window, displayID: nil) }) {
                candidates.append(group)
                guard candidates.count == 1 else {
                    throw Failure(message: "当前窗口有多组手写工具，无法确定目标；请保留一个正在使用的手写工具栏。")
                }
                continue
            }
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        guard let group = candidates.first else {
            throw Failure(message: "未找到 MarginNote 的画笔、橡皮擦和套索工具组；请先打开手写工具栏。")
        }
        return group
    }

    private func readGroup(_ element: AXUIElement, children supplied: [AXUIElement]? = nil) -> DrawingGroup? {
        let children = supplied ?? childElements(element)
        // MarginNote's Catalyst AX tree may flatten the drawing toolbar into
        // the document container beside navigation and stroke elements. Bound
        // the scan, then qualify the exact tool subset instead of requiring a
        // small parent. Duplicated/ambiguous tool sets are still rejected.
        guard (3...500).contains(children.count) else { return nil }
        let buttons = children.compactMap { toolButton($0) }
        guard MarginNoteToolSelection.isDrawingGroup(buttons.map(\.descriptor)) else { return nil }
        return DrawingGroup(element: element, buttons: buttons)
    }

    private func toolButton(_ element: AXUIElement) -> ToolButton? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        let attributes = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute,
                          kAXSelectedAttribute, kAXValueAttribute, kAXEnabledAttribute, kAXHiddenAttribute]
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &raw) == .success,
              let values = raw as? [Any], values.count == attributes.count,
              let role = values[0] as? String,
              [kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole].contains(role),
              (values[6] as? NSNumber)?.boolValue != true else { return nil }
        let label = (values[1] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (values[2] as? String) ?? ""
        guard let tool = MarginNoteDrawingTool.identify(label: label) else { return nil }
        var selected: Bool? = (values[3] as? NSNumber)?.boolValue
        if selected == nil, let value = values[4] as? NSNumber, value == 0 || value == 1 {
            selected = value.boolValue
        }
        if MarginNoteDrawingTool.labelIndicatesSelected(label) { selected = true }
        return ToolButton(element: element,
                          descriptor: MarginNoteToolDescriptor(tool: tool, selected: selected,
                                                              enabled: (values[5] as? NSNumber)?.boolValue == true))
    }

    private func buttonIsVisible(_ button: AXUIElement, in window: AXUIElement,
                                 displayID: CGDirectDisplayID?) -> Bool {
        guard boolAttribute(button, kAXHiddenAttribute) != true,
              let rect = frame(button), rect.width > 0, rect.height > 0,
              let windowRect = frame(window), windowRect.intersects(rect) else { return false }
        return displayID.map { CGDisplayBounds($0).contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? true
    }

    private func remember(_ tool: MarginNoteDrawingTool, for window: AXUIElement) {
        brushes.removeAll { CFEqual($0.window, window) }
        brushes.insert(BrushMemory(window: window, tool: tool), at: 0)
        if brushes.count > 8 { brushes.removeLast() }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }
    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }
    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func childElements(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
