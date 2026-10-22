import Foundation
import CoreGraphics

/// Samples one direct-finger gesture and integrates its optional inertial tail.
/// The caller must authorize momentum only after a successful direct scroll;
/// taps, cancelled gestures, Pencil input, and multiple fingers cannot opt in.
/// Points and velocity use view coordinates; timestamps are monotonic seconds.
struct FingerScrollMomentum {
    private struct Sample {
        let point: CGPoint
        let timestamp: TimeInterval
    }

    private let sampleWindow: TimeInterval = 0.100
    private let maximumReleasePause: TimeInterval = 0.080
    private let maximumSampleGap: TimeInterval = 0.150
    private let minimumSampleDuration: TimeInterval = 0.010
    private let minimumStartSpeed: CGFloat = 80
    private let maximumSpeed: CGFloat = 4_000
    private let stopSpeed: CGFloat = 10
    private let maximumDuration: TimeInterval = 2.75
    private let maximumFrameInterval: TimeInterval = 0.120
    // An exponential curve similar to a 0.998-per-millisecond decay. This is
    // deliberately not a claim of identical UIKit/native scroll physics.
    private let decay = -1_000.0 * log(0.998)

    private var trackingID: Int?
    private var samples: [Sample] = []
    private var lastMovementTime: TimeInterval?
    private var previousMovement: CGPoint?
    private var elapsed: TimeInterval = 0
    private(set) var velocity = CGPoint.zero

    var isActive: Bool { velocity != .zero }

    /// A new finger interrupts an existing inertial tail immediately.
    mutating func begin(id: Int, point: CGPoint, timestamp: TimeInterval) {
        reset()
        guard Self.valid(point, timestamp: timestamp) else { return }
        trackingID = id
        samples = [Sample(point: point, timestamp: timestamp)]
    }

    mutating func sample(id: Int, point: CGPoint, timestamp: TimeInterval) {
        guard trackingID == id else { return }
        guard Self.valid(point, timestamp: timestamp) else { reset(); return }
        guard let last = samples.last, timestamp > last.timestamp else { return }
        let delta = CGPoint(x: point.x - last.point.x, y: point.y - last.point.y)
        if timestamp - last.timestamp > maximumSampleGap {
            // A long delivery gap provides no reliable release velocity.
            samples.removeAll(keepingCapacity: true)
            lastMovementTime = nil
            previousMovement = nil
        } else if hypot(delta.x, delta.y) >= 0.25 {
            if let previousMovement,
               delta.x * previousMovement.x + delta.y * previousMovement.y < 0 {
                // A final direction reversal takes precedence over the older
                // trajectory, rather than flinging in the previous direction.
                samples = [last]
            }
            previousMovement = delta
            lastMovementTime = timestamp
        }
        samples.append(Sample(point: point, timestamp: timestamp))
        let cutoff = timestamp - sampleWindow
        // Keep one boundary sample for interpolation at the 100 ms cutoff.
        while samples.count > 2 && samples[1].timestamp <= cutoff { samples.removeFirst() }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
    }

    /// Feed the release location/time, then explicitly opt in only if the
    /// direct-touch state finished scrolling successfully. Returns activation.
    @discardableResult
    mutating func end(id: Int, point: CGPoint, timestamp: TimeInterval,
                      allowMomentum: Bool) -> Bool {
        guard trackingID == id else { return false }
        sample(id: id, point: point, timestamp: timestamp)
        guard trackingID == id else { return false }
        let estimate = allowMomentum ? releaseVelocity(at: timestamp) : nil
        clearTracking()
        elapsed = 0
        velocity = estimate ?? .zero
        return isActive
    }

    /// Analytic integration is independent of whether frames arrive at 60 or
    /// 120 Hz. Zero/negative dt does nothing; invalid or stalled frames stop
    /// the tail instead of making a large jump when the app resumes.
    mutating func step(deltaTime: TimeInterval) -> CGPoint {
        guard isActive else { return .zero }
        guard deltaTime.isFinite, deltaTime <= maximumFrameInterval else {
            cancel()
            return .zero
        }
        guard deltaTime > 0 else { return .zero }
        let speed = hypot(velocity.x, velocity.y)
        guard speed > stopSpeed else { cancel(); return .zero }
        let timeToStop = log(Double(speed / stopSpeed)) / decay
        let interval = min(deltaTime, maximumDuration - elapsed, timeToStop)
        guard interval > 0 else { cancel(); return .zero }
        let factor = exp(-decay * interval)
        let integral = -expm1(-decay * interval) / decay
        let displacement = CGPoint(x: velocity.x * integral, y: velocity.y * integral)
        velocity = CGPoint(x: velocity.x * factor, y: velocity.y * factor)
        elapsed += interval
        if interval >= timeToStop || elapsed >= maximumDuration {
            velocity = .zero
        }
        return displacement
    }

    /// Use for a second finger, Pencil/palm rejection, a cancelled gesture,
    /// loss of focus, background entry, and view/session teardown.
    mutating func cancel() { reset() }

    mutating func reset() {
        clearTracking()
        velocity = .zero
        elapsed = 0
    }

    private mutating func clearTracking() {
        trackingID = nil
        samples.removeAll(keepingCapacity: true)
        lastMovementTime = nil
        previousMovement = nil
    }

    private func releaseVelocity(at timestamp: TimeInterval) -> CGPoint? {
        guard let lastMovementTime,
              timestamp >= lastMovementTime,
              timestamp - lastMovementTime < maximumReleasePause,
              let last = samples.last, var first = samples.first, samples.count >= 2
        else { return nil }
        let cutoff = last.timestamp - sampleWindow
        if first.timestamp < cutoff, samples.count >= 2 {
            let next = samples[1]
            let fraction = (cutoff - first.timestamp) / (next.timestamp - first.timestamp)
            first = Sample(point: CGPoint(x: first.point.x + (next.point.x - first.point.x) * fraction,
                                          y: first.point.y + (next.point.y - first.point.y) * fraction),
                           timestamp: cutoff)
        }
        let duration = last.timestamp - first.timestamp
        guard duration >= minimumSampleDuration else { return nil }
        var candidate = CGPoint(x: (last.point.x - first.point.x) / duration,
                                y: (last.point.y - first.point.y) / duration)
        let speed = hypot(candidate.x, candidate.y)
        guard speed.isFinite, speed >= minimumStartSpeed else { return nil }
        if speed > maximumSpeed {
            candidate.x *= maximumSpeed / speed
            candidate.y *= maximumSpeed / speed
        }
        return candidate
    }

    private static func valid(_ point: CGPoint, timestamp: TimeInterval) -> Bool {
        point.x.isFinite && point.y.isFinite && timestamp.isFinite && timestamp >= 0
    }
}
