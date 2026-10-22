import Foundation
import CoreGraphics

private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
private func speed(_ p: CGPoint) -> CGFloat { hypot(p.x, p.y) }

private func flick() -> FingerScrollMomentum {
    var state = FingerScrollMomentum()
    state.begin(id: 1, point: .zero, timestamp: 1)
    state.sample(id: 1, point: p(0, 25), timestamp: 1.025)
    state.sample(id: 1, point: p(0, 50), timestamp: 1.050)
    state.sample(id: 1, point: p(0, 75), timestamp: 1.075)
    _ = state.end(id: 1, point: p(0, 100), timestamp: 1.100, allowMomentum: true)
    return state
}

var fast = flick()
check(fast.isActive, "a successful fast direct scroll starts momentum")
check(abs(fast.velocity.y - 1_000) < 0.000001, "velocity reflects the recent 100 ms trajectory")
let firstStep = fast.step(deltaTime: 1.0 / 60)
let secondStep = fast.step(deltaTime: 1.0 / 60)
check(firstStep.y > secondStep.y && secondStep.y > 0, "inertia moves in the flick direction and decays")

var paused = FingerScrollMomentum()
paused.begin(id: 2, point: .zero, timestamp: 2)
paused.sample(id: 2, point: p(0, 50), timestamp: 2.050)
check(!paused.end(id: 2, point: p(0, 50), timestamp: 2.140, allowMomentum: true),
      "release after stopping for 90 ms does not fling")
check(paused.step(deltaTime: 1.0 / 60) == .zero, "stopped release produces no residual movement")

var slow = FingerScrollMomentum()
slow.begin(id: 3, point: .zero, timestamp: 3)
slow.sample(id: 3, point: p(0, 1), timestamp: 3.025)
check(!slow.end(id: 3, point: p(0, 3), timestamp: 3.075, allowMomentum: true),
      "slow drag below 80 points per second has no inertia")

var reverse = FingerScrollMomentum()
reverse.begin(id: 4, point: .zero, timestamp: 4)
reverse.sample(id: 4, point: p(0, 80), timestamp: 4.040)
reverse.sample(id: 4, point: p(0, 100), timestamp: 4.060)
reverse.sample(id: 4, point: p(0, 90), timestamp: 4.080)
check(reverse.end(id: 4, point: p(0, 80), timestamp: 4.100, allowMomentum: true)
      && reverse.velocity.y < 0, "a final reversal uses the recent reversed direction")

private func runToRest(_ frame: TimeInterval) -> (CGPoint, Int) {
    var state = flick()
    var distance = CGPoint.zero
    var count = 0
    while state.isActive && count < 1_000 {
        let step = state.step(deltaTime: frame)
        distance.x += step.x
        distance.y += step.y
        count += 1
    }
    check(!state.isActive, "momentum comes to rest within the time bound")
    return (distance, count)
}
let sixty = runToRest(1.0 / 60)
let oneTwenty = runToRest(1.0 / 120)
check(abs(sixty.0.y - oneTwenty.0.y) < 0.000001,
      "60 Hz and 120 Hz integrate the same total distance including the final partial frame")
check(sixty.1 <= 166 && oneTwenty.1 <= 331, "tail never exceeds about 2.75 seconds")

var cancel = flick()
cancel.cancel()
check(!cancel.isActive && cancel.step(deltaTime: 1.0 / 60) == .zero, "cancel stops immediately")
var reset = flick()
reset.reset()
check(!reset.isActive && reset.velocity == .zero, "reset clears active velocity")
var noOptIn = FingerScrollMomentum()
noOptIn.begin(id: 5, point: .zero, timestamp: 5)
noOptIn.sample(id: 5, point: p(0, 80), timestamp: 5.040)
check(!noOptIn.end(id: 5, point: p(0, 160), timestamp: 5.080, allowMomentum: false),
      "tap/cancel/multifinger caller cannot start momentum without explicit successful-scroll opt-in")

var interrupted = flick()
interrupted.begin(id: 6, point: p(7, 7), timestamp: 6)
check(!interrupted.isActive && interrupted.step(deltaTime: 1.0 / 60) == .zero,
      "new finger gesture immediately clears old momentum")
check(!interrupted.end(id: 1, point: .zero, timestamp: 6.010, allowMomentum: true),
      "late release from old contact cannot start momentum")
check(!interrupted.end(id: 6, point: p(7, 7), timestamp: 6.020, allowMomentum: true),
      "new stationary contact cannot reuse old velocity")

var invalidFrame = flick()
let savedVelocity = invalidFrame.velocity
check(invalidFrame.step(deltaTime: 0) == .zero && invalidFrame.step(deltaTime: -0.1) == .zero
      && invalidFrame.velocity == savedVelocity, "zero and negative frame times produce no reverse or extra movement")
check(invalidFrame.step(deltaTime: .nan) == .zero && !invalidFrame.isActive,
      "NaN frame interval cancels safely")
invalidFrame = flick()
check(invalidFrame.step(deltaTime: .infinity) == .zero && !invalidFrame.isActive,
      "infinite frame interval cancels safely")
invalidFrame = flick()
check(invalidFrame.step(deltaTime: 0.5) == .zero && !invalidFrame.isActive,
      "long frame gap stops instead of jumping after background/stall")

var clipped = FingerScrollMomentum()
clipped.begin(id: 7, point: .zero, timestamp: 7)
clipped.sample(id: 7, point: p(150, 200), timestamp: 7.025)
check(clipped.end(id: 7, point: p(300, 400), timestamp: 7.050, allowMomentum: true),
      "large measured flick can start")
check(abs(speed(clipped.velocity) - 4_000) < 0.000001,
      "speed cap applies to vector magnitude, not independently to axes")
check(abs(clipped.velocity.x / clipped.velocity.y - 0.75) < 0.000001,
      "speed clipping preserves direction")
var clippedFrames = 0
while clipped.isActive && clippedFrames < 400 {
    _ = clipped.step(deltaTime: 1.0 / 120)
    clippedFrames += 1
}
check(!clipped.isActive && clippedFrames <= 331, "maximum-speed flick still obeys duration limit")

var badSample = FingerScrollMomentum()
badSample.begin(id: 8, point: .zero, timestamp: 8)
badSample.sample(id: 8, point: p(.nan, 3), timestamp: 8.020)
check(!badSample.end(id: 8, point: p(0, 80), timestamp: 8.040, allowMomentum: true),
      "invalid samples cannot poison later momentum")
badSample.begin(id: 9, point: .zero, timestamp: 9)
badSample.sample(id: 9, point: p(0, 90), timestamp: 9.030)
check(!badSample.end(id: 9, point: p(0, 90), timestamp: 8.9, allowMomentum: true),
      "backwards release timestamps cannot activate")
badSample.begin(id: 10, point: .zero, timestamp: 10)
check(!badSample.end(id: 10, point: p(0, 500), timestamp: 10.5, allowMomentum: true),
      "long sampling gap alone does not invent release velocity")

print("PASS: \(checks) finger-scroll momentum checks")
