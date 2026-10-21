import Foundation
import CoreGraphics

private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

var tap = DirectTouchState()
check(tap.began(id: 1, point: p(20, 30)).isEmpty, "touch-down never sends a mouse-down or click")
check(tap.moved(id: 1, point: p(22, 32)).isEmpty, "small jitter remains a tap candidate")
check(tap.ended(id: 1, point: p(21, 31)) == [.click(point: p(20, 30))],
      "completed tap produces exactly one click at its original target")
check(tap.ended(id: 1, point: p(21, 31)).isEmpty, "late repeated end never clicks twice")
check(tap.moved(id: 1, point: p(90, 90)).isEmpty, "late movement after end does nothing")

var slowScroll = DirectTouchState()
_ = slowScroll.began(id: 2, point: p(10, 10))
check(slowScroll.moved(id: 2, point: p(12, 10)).isEmpty, "first subthreshold increment is held")
check(slowScroll.moved(id: 2, point: p(15, 10)).isEmpty, "second subthreshold increment is held")
check(slowScroll.moved(id: 2, point: p(19, 10)) == [
    .beginScroll(anchor: p(10, 10)), .scroll(delta: p(9, 0))
], "accumulated displacement crosses threshold and includes previously held movement")
check(slowScroll.isScrolling, "threshold crossing commits to scrolling")
check(slowScroll.moved(id: 2, point: p(21, 15)) == [.scroll(delta: p(2, 5))],
      "subsequent scroll is incremental and does not resend its anchor")
check(slowScroll.moved(id: 2, point: p(21, 15)).isEmpty, "unchanged position emits no scroll delta")
check(slowScroll.ended(id: 2, point: p(24, 13)) == [.scroll(delta: p(3, -2))],
      "end preserves final scroll delta and never appends a click")
check(!slowScroll.isScrolling, "scroll state clears after release")

var jitter = DirectTouchState()
_ = jitter.began(id: 3, point: .zero)
for _ in 0..<12 {
    check(jitter.moved(id: 3, point: p(2, 2)).isEmpty, "small outward jitter is not scrolling")
    check(jitter.moved(id: 3, point: p(-2, -2)).isEmpty, "small return jitter does not accumulate path length")
}
check(jitter.ended(id: 3, point: .zero) == [.click(point: .zero)], "repeated small jitter remains one tap")

var diagonal = DirectTouchState(scrollThreshold: 10)
_ = diagonal.began(id: 4, point: .zero)
check(diagonal.moved(id: 4, point: p(6, 8)) == [.beginScroll(anchor: .zero), .scroll(delta: p(6, 8))],
      "radial displacement, including diagonal movement, determines threshold")
check(diagonal.ended(id: 4, point: .zero) == [.scroll(delta: p(-6, -8))],
      "returning to origin after scrolling must not become a tap")

var endOnly = DirectTouchState()
_ = endOnly.began(id: 5, point: .zero)
check(endOnly.ended(id: 5, point: p(0, -15)) == [
    .beginScroll(anchor: .zero), .scroll(delta: p(0, -15))
], "a far-away end with no move callback is scrolling, not a click")

var cancelled = DirectTouchState()
_ = cancelled.began(id: 6, point: p(1, 1))
check(cancelled.cancel(id: 6).isEmpty, "cancel sends no synthetic click")
check(cancelled.ended(id: 6, point: p(1, 1)).isEmpty, "cancelled touch cannot click on a late end")
_ = cancelled.began(id: 7, point: .zero)
_ = cancelled.moved(id: 7, point: p(0, 12))
_ = cancelled.cancel(id: 7)
check(!cancelled.isScrolling && cancelled.ended(id: 7, point: p(0, 12)).isEmpty,
      "cancelled scrolling clears without a click")

var twoFingers = DirectTouchState()
_ = twoFingers.began(id: 8, point: .zero)
check(twoFingers.began(id: 9, point: p(5, 5)).isEmpty, "second finger suppresses the single-finger candidate")
check(twoFingers.ended(id: 9, point: p(5, 5)).isEmpty, "lifting second finger does not click")
check(twoFingers.moved(id: 8, point: p(0, 40)).isEmpty, "remaining finger stays suppressed until release")
check(twoFingers.ended(id: 8, point: .zero).isEmpty, "original candidate cannot revive after second finger")
_ = twoFingers.began(id: 10, point: p(3, 4))
check(twoFingers.ended(id: 10, point: p(3, 4)) == [.click(point: p(3, 4))],
      "a new gesture works after both fingers lift")

var palm = DirectTouchState()
_ = palm.began(id: 11, point: .zero)
_ = palm.cancel()
check(palm.moved(id: 11, point: p(0, 20)).isEmpty, "palm rejection suppresses further movement")
_ = palm.began(id: 12, point: p(10, 0))
check(palm.ended(id: 11, point: .zero).isEmpty && palm.ended(id: 12, point: p(10, 0)).isEmpty,
      "palm and additional contacts leave no delayed click")
_ = palm.began(id: 13, point: .zero)
_ = palm.cancel(id: 99)
check(palm.ended(id: 13, point: .zero) == [.click(point: .zero)],
      "a stale cancellation of an unrelated id cannot cancel a new valid tap")

var reset = DirectTouchState()
_ = reset.began(id: 14, point: .zero)
_ = reset.reset()
check(reset.ended(id: 14, point: .zero).isEmpty, "reset invalidates the pending click")
_ = reset.began(id: 15, point: p(6, 6))
check(reset.ended(id: 14, point: .zero).isEmpty, "old end cannot terminate a new contact")
check(reset.ended(id: 15, point: p(6, 6)) == [.click(point: p(6, 6))], "new tap after reset still works")

var duplicate = DirectTouchState()
_ = duplicate.began(id: 16, point: .zero)
_ = duplicate.began(id: 16, point: p(100, 100))
check(duplicate.ended(id: 16, point: .zero) == [.click(point: .zero)],
      "duplicate began does not move the anchor or invent a second finger")

print("PASS: \(checks) direct-touch state checks")
