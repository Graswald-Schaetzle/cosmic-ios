import Foundation
import simd

enum CaptureAim: Equatable, Sendable {
    case level, up, down
}

/// Gravity-relative optical-axis tilt, independent of portrait/landscape roll.
/// This is aiming feedback, not evidence that a surface was captured.
struct CaptureAimTracker {
    private(set) var aim: CaptureAim?
    private var pending: CaptureAim?
    private var pendingSince: TimeInterval = 0

    mutating func reset() {
        self = Self()
    }

    mutating func update(worldFromCamera: simd_float4x4, timestamp: TimeInterval) -> CaptureAim? {
        let vertical = -worldFromCamera.columns.2.y
        guard vertical.isFinite, timestamp.isFinite else {
            reset()
            return nil
        }
        // Enter at ~25°, exit at ~15°. A sustained 0.6 s change prevents
        // handheld jitter and brief sweeps from flickering the instruction.
        let candidate: CaptureAim
        if vertical > (aim == .up ? 0.26 : 0.42) {
            candidate = .up
        } else if vertical < (aim == .down ? -0.26 : -0.42) {
            candidate = .down
        } else {
            candidate = .level
        }
        if pending != candidate || timestamp < pendingSince {
            pending = candidate
            pendingSince = timestamp
        }
        if timestamp - pendingSince >= 0.6 {
            aim = candidate
        }
        return aim
    }
}
