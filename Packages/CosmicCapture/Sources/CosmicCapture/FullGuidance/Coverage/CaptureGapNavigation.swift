import Foundation
import simd

enum CaptureGapDirection: Equatable, Sendable {
    case left, right, up, down, inView

    var symbol: String {
        switch self {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .inView: "viewfinder"
        }
    }
}

struct CaptureGapNavigation: Equatable, Sendable {
    let target: CaptureCoverageGap
    let direction: CaptureGapDirection

    var message: String {
        switch direction {
        case .left: "Turn left toward the missing area"
        case .right: "Turn right toward the missing area"
        case .up: "Look up toward the missing area"
        case .down: "Look down toward the missing area"
        case .inView: "Scan the highlighted \(target.category.rawValue) area"
        }
    }

    var compactMessage: String {
        let surface = target.category.rawValue
        switch direction {
        case .left: return "Turn left to the \(surface)"
        case .right: return "Turn right to the \(surface)"
        case .up: return "Look up at the \(surface)"
        case .down: return "Look down at the \(surface)"
        case .inView: return "Scan the marked \(surface)"
        }
    }

    var detail: String {
        direction == .inView
            ? "Keep the highlighted area in view as you move to another angle."
            : "Turn the phone to find the \(target.category.rawValue) area that needs another view."
    }
}

/// Projects through the same orientation-aware ARKit matrices as the live
/// viewport. Behind-camera targets never use mirrored screen projections.
struct CaptureGapNavigator {
    private var target: CaptureCoverageGap?
    private var direction: CaptureGapDirection?
    private var pending: CaptureGapDirection?
    private var pendingSince: TimeInterval = 0

    mutating func reset() { self = Self() }

    mutating func update(
        target: CaptureCoverageGap, viewMatrix: simd_float4x4,
        projection: simd_float4x4, timestamp: TimeInterval
    ) -> CaptureGapNavigation? {
        if self.target?.category != target.category
            || self.target.map({ simd_distance($0.center, target.center) > 0.75 }) == true {
            reset()
        }
        self.target = target
        let local = viewMatrix * SIMD4(target.center, 1)
        let distance = simd_length(SIMD3(local.x, local.y, local.z))
        guard timestamp.isFinite, distance.isFinite, distance > 0.25 else {
            reset()
            return nil
        }

        let candidate: CaptureGapDirection
        if local.z >= -0.05 {
            if abs(local.y) > max(abs(local.x), abs(local.z)) * 2 {
                // A ceiling/floor target nearly in the camera plane needs
                // pitch, not an endless lateral turn around its vertical axis.
                candidate = local.y > 0 ? .up : .down
            } else {
                // Choose a stable turn for a target directly behind. Never ask
                // someone to walk backward or invert x by dividing by negative w.
                if abs(local.x) < distance * 0.12 {
                    candidate = direction == .left ? .left : .right
                } else {
                    candidate = local.x < 0 ? .left : .right
                }
            }
        } else {
            let clip = projection * local
            guard clip.w > 0, clip.x.isFinite, clip.y.isFinite else {
                reset()
                return nil
            }
            let x = clip.x / clip.w
            let y = clip.y / clip.w
            // Acquire inside the inner 80%; retain until the inner 92% edge.
            // These are screen bounds, not a coverage or visibility claim.
            let limit: Float = direction == .inView ? 0.92 : 0.8
            if abs(x) < limit, abs(y) < limit {
                candidate = .inView
            } else {
                let wasHorizontal = direction == .left || direction == .right
                let horizontal = abs(x) > abs(y) * (wasHorizontal ? 0.85 : 1.15)
                candidate = horizontal ? (x < 0 ? .left : .right) : (y < 0 ? .down : .up)
            }
        }
        if pending != candidate || timestamp < pendingSince {
            pending = candidate
            pendingSince = timestamp
        }
        // The first cue appears immediately; direction changes require dwell.
        if direction == nil || timestamp - pendingSince >= 0.25 {
            direction = candidate
        }
        return direction.map { CaptureGapNavigation(target: target, direction: $0) }
    }
}
