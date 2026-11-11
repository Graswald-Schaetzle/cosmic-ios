import Foundation
import simd

/// Holds sampling back until ARKit tracking has been continuously `.normal`
/// for `settleSeconds`, with no pose discontinuity or frame gap inside that
/// window. One gate covers capture start, resume from any pause source,
/// interruption end and in-session tracking recovery.
///
/// ARKit can report `.normal` on the first frame after a gap while that
/// frame's pose is still wrong: in a real outdoor scan the first committed frame
/// after a 2.5 s and a 170 s gap sat 19.5 m and 28.7 m from the next frame,
/// which showed the same view and was correct again 0.15–0.3 s later.
///
/// Pure value type; all time comes from the caller in `ARFrame.timestamp`
/// seconds. Deliberately never compares against the last committed sample or
/// requires returning near a prior pose: movement across a pause is real.
struct CaptureTrackingSettleGate: Sendable {
    struct Policy: Sendable, Equatable {
        /// Continuous `.normal` tracking required before a frame may be
        /// sampled. Both incident bad poses were gone within 0.3 s.
        let settleSeconds: TimeInterval
        /// A longer interval between processed frames restarts the window;
        /// nothing is known about the pose while no frames arrive.
        let maxFrameGapSeconds: TimeInterval
        /// Implied speeds between consecutive processed frames above these
        /// limits are teleports, not handheld motion.
        let maxLinearSpeedMPS: Float
        let maxAngularSpeedDPS: Float

        static let standard = Policy(
            settleSeconds: 0.5,
            maxFrameGapSeconds: 0.5,
            maxLinearSpeedMPS: 5,
            maxAngularSpeedDPS: 720
        )
    }

    enum Trigger: String, Sendable, Equatable {
        case start
        case resume
        case interruptionEnd = "interruption_end"
        case tracking
        case poseDiscontinuity = "pose_discontinuity"
        case frameGap = "frame_gap"
    }

    struct Frame: Sendable {
        let timestamp: TimeInterval
        let isTrackingNormal: Bool
        let worldFromCamera: simd_float4x4
    }

    enum Event: Sendable, Equatable {
        case settleStarted(trigger: Trigger, timestamp: TimeInterval)
        case settleCompleted(elapsedSeconds: TimeInterval, timestamp: TimeInterval)
        case poseDiscontinuity(
            translationM: Float,
            rotationDeg: Float,
            dtSeconds: TimeInterval,
            timestamp: TimeInterval
        )
    }

    struct Verdict: Sendable, Equatable {
        let isSettled: Bool
        let events: [Event]
    }

    let policy: Policy
    private(set) var isSettled = false
    private var minimumTimestamp: TimeInterval = -.greatestFiniteMagnitude
    /// First frame of the current continuous `.normal` window.
    private var windowStart: TimeInterval?
    /// When the current settling episode began, for `settle_completed`.
    private var episodeStart: TimeInterval?
    private var lastFrame: (timestamp: TimeInterval, worldFromCamera: simd_float4x4)?

    init(policy: Policy = .standard) {
        self.policy = policy
    }

    /// Restarts settling for an explicit lifecycle boundary at `now`. Frames
    /// at or before `minimumTimestamp` (queued before the boundary) are
    /// ignored, and the pose history is cleared so a move across the
    /// boundary is not judged as a discontinuity.
    @discardableResult
    mutating func restart(
        _ trigger: Trigger,
        minimumTimestamp: TimeInterval,
        at now: TimeInterval
    ) -> Event {
        self.minimumTimestamp = minimumTimestamp
        lastFrame = nil
        episodeStart = nil
        return beginSettling(trigger, at: now)
    }

    mutating func observe(_ frame: Frame) -> Verdict {
        guard frame.timestamp > minimumTimestamp else {
            return Verdict(isSettled: false, events: [])
        }
        var events: [Event] = []
        let previous = lastFrame
        lastFrame = (frame.timestamp, frame.worldFromCamera)

        guard frame.isTrackingNormal else {
            if isMakingProgress {
                events.append(beginSettling(.tracking, at: frame.timestamp))
            }
            windowStart = nil
            return Verdict(isSettled: false, events: events)
        }

        if let previous {
            events += checkContinuity(previous: previous, frame: frame)
        }

        let start = windowStart ?? frame.timestamp
        windowStart = start
        if !isSettled {
            // ARKit can hand over a frame captured just before the restart call.
            episodeStart = min(episodeStart ?? start, start)
        }
        if !isSettled, frame.timestamp - start >= policy.settleSeconds {
            isSettled = true
            let elapsed = frame.timestamp - (episodeStart ?? start)
            episodeStart = nil
            events.append(.settleCompleted(elapsedSeconds: elapsed, timestamp: frame.timestamp))
        }
        return Verdict(isSettled: isSettled, events: events)
    }

    /// True when a restart would discard settled state or a running window.
    private var isMakingProgress: Bool {
        isSettled || windowStart != nil
    }

    private mutating func beginSettling(
        _ trigger: Trigger,
        at timestamp: TimeInterval
    ) -> Event {
        isSettled = false
        windowStart = nil
        episodeStart = episodeStart ?? timestamp
        return .settleStarted(trigger: trigger, timestamp: timestamp)
    }

    private mutating func checkContinuity(
        previous: (timestamp: TimeInterval, worldFromCamera: simd_float4x4),
        frame: Frame
    ) -> [Event] {
        let dt = frame.timestamp - previous.timestamp
        if dt > policy.maxFrameGapSeconds {
            return isMakingProgress ? [beginSettling(.frameGap, at: frame.timestamp)] : []
        }
        guard dt > 0 else { return [] }

        let translationM = simd_distance(
            Self.position(previous.worldFromCamera),
            Self.position(frame.worldFromCamera)
        )
        let rotationDeg = Self.rotationDegrees(
            from: previous.worldFromCamera,
            to: frame.worldFromCamera
        )
        let isTeleport = translationM / Float(dt) > policy.maxLinearSpeedMPS
            || rotationDeg / Float(dt) > policy.maxAngularSpeedDPS
        guard isTeleport else { return [] }
        return [
            .poseDiscontinuity(
                translationM: translationM,
                rotationDeg: rotationDeg,
                dtSeconds: dt,
                timestamp: frame.timestamp
            ),
            beginSettling(.poseDiscontinuity, at: frame.timestamp),
        ]
    }

    private static func position(_ transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    /// Angle of the relative rotation `R_a^T · R_b`.
    static func rotationDegrees(
        from a: simd_float4x4,
        to b: simd_float4x4
    ) -> Float {
        let rotationA = simd_float3x3(
            SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z),
            SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
            SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z)
        )
        let rotationB = simd_float3x3(
            SIMD3(b.columns.0.x, b.columns.0.y, b.columns.0.z),
            SIMD3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
            SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z)
        )
        let relative = rotationA.transpose * rotationB
        let trace = relative.columns.0.x + relative.columns.1.y + relative.columns.2.z
        let cosine = simd_clamp((trace - 1) / 2, -1, 1)
        return acos(cosine) * 180 / .pi
    }
}
