import Foundation
import CoreGraphics

/// A direct finger is either a completed tap or a scroll, never a mouse drag.
/// UIKit routing must feed only `.direct` touches here; Pencil and physical
/// mouse/trackpad pointer input retain their existing paths.
struct DirectTouchState {
    enum Action: Equatable {
        /// Move the remote pointer to this anchor once before scrolling.
        case beginScroll(anchor: CGPoint)
        /// Finger displacement in view points (current minus previous), before
        /// video scaling or any desired natural-scrolling conversion.
        case scroll(delta: CGPoint)
        /// Emit one complete mouse click only after a successful tap ends.
        case click(point: CGPoint)
    }

    private struct Contact {
        let id: Int
        let origin: CGPoint
        var previous: CGPoint
        var scrolling = false
    }

    let scrollThreshold: CGFloat
    private var contacts: Set<Int> = []
    private var active: Contact?
    private var suppressedUntilLift = false

    var isScrolling: Bool { active?.scrolling == true }

    init(scrollThreshold: CGFloat = 9) {
        precondition(scrollThreshold.isFinite && scrollThreshold > 0)
        self.scrollThreshold = scrollThreshold
    }

    mutating func began(id: Int, point: CGPoint) -> [Action] {
        guard Self.isFinite(point), contacts.insert(id).inserted else { return [] }
        guard contacts.count == 1, !suppressedUntilLift else {
            // A second finger hands the gesture to the existing two-finger
            // path. Lifting one must not resurrect the other's candidate tap.
            active = nil
            suppressedUntilLift = true
            return []
        }
        active = Contact(id: id, origin: point, previous: point)
        return []
    }

    mutating func moved(id: Int, point: CGPoint) -> [Action] {
        guard Self.isFinite(point), !suppressedUntilLift,
              var contact = active, contact.id == id else { return [] }
        let delta: CGPoint
        var actions: [Action] = []
        if contact.scrolling {
            delta = CGPoint(x: point.x - contact.previous.x, y: point.y - contact.previous.y)
        } else {
            // Measure from touch-down, not per-callback movement. Small moves
            // in one direction accumulate; small back-and-forth jitter does
            // not become a scroll just because its path length grows.
            delta = CGPoint(x: point.x - contact.origin.x, y: point.y - contact.origin.y)
            guard hypot(delta.x, delta.y) >= scrollThreshold else {
                contact.previous = point
                active = contact
                return []
            }
            contact.scrolling = true
            actions.append(.beginScroll(anchor: contact.origin))
        }
        contact.previous = point
        active = contact
        if delta != .zero { actions.append(.scroll(delta: delta)) }
        return actions
    }

    mutating func ended(id: Int, point: CGPoint) -> [Action] {
        guard contacts.contains(id) else { return [] }
        // Check the final position too: UIKit may coalesce away a last move.
        // An end beyond the threshold must not unexpectedly select text.
        var actions = moved(id: id, point: point)
        if let contact = active, contact.id == id, !suppressedUntilLift {
            if !contact.scrolling, Self.isFinite(point) {
                // Anchor tiny tap jitter at the original touched location.
                actions.append(.click(point: contact.origin))
            }
            active = nil
        }
        contacts.remove(id)
        if contacts.isEmpty { suppressedUntilLift = false }
        return actions
    }

    /// A cancelled touch ends the entire single-finger candidate. Omit `id`
    /// when Pencil palm rejection or a competing recognizer suppresses all
    /// currently held fingers; their later endings can only retire contacts.
    @discardableResult
    mutating func cancel(id: Int? = nil) -> [Action] {
        if let id {
            guard contacts.remove(id) != nil else { return [] }
        }
        active = nil
        suppressedUntilLift = !contacts.isEmpty
        return []
    }

    /// Use when the view/session leaves. Late moves/endings are ignored until
    /// a new, explicit began establishes a new gesture.
    @discardableResult
    mutating func reset() -> [Action] {
        active = nil
        contacts.removeAll()
        suppressedUntilLift = false
        return []
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}
