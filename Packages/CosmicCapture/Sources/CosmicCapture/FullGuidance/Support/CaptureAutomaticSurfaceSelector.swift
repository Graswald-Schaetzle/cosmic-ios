import Foundation
import simd

/// Picks the scan pass (walls, floor, ceiling) from where the camera points,
/// preferring the classified surface it is looking at. A new pass needs
/// 0.8 s of agreement before it replaces the current one.
struct CaptureAutomaticSurfaceSelector {
    private var pending: CaptureStructuralCategory?
    private var pendingSince: TimeInterval = 0
    private var lastTimestamp: TimeInterval?

    mutating func reset() { self = Self() }

    mutating func update(vertical: Float, detected: CaptureStructuralCategory?,
                         current: CaptureStructuralCategory, timestamp: TimeInterval,
                         eligible: Bool) -> CaptureStructuralCategory? {
        guard eligible, vertical.isFinite, timestamp.isFinite else { reset(); return nil }
        if let lastTimestamp, timestamp < lastTimestamp || timestamp - lastTimestamp > 0.5 {
            reset()
        }
        lastTimestamp = timestamp
        let candidate: CaptureStructuralCategory
        if let detected, detected == .wall || (detected == .ceiling && vertical > 0.15)
            || (detected == .floor && vertical < -0.15) {
            candidate = detected
        } else if vertical > (current == .ceiling ? 0.26 : 0.50) {
            candidate = .ceiling
        } else if vertical < (current == .floor ? -0.26 : -0.50) {
            candidate = .floor
        } else {
            candidate = .wall
        }
        guard candidate != current else { pending = nil; return nil }
        if pending != candidate { pending = candidate; pendingSince = timestamp }
        guard timestamp - pendingSince >= 0.8 else { return nil }
        pending = nil
        return candidate
    }

    static func lookedAtCategory(faces: [CaptureClassifiedFace], pose: simd_float4x4) -> CaptureStructuralCategory? {
        let camera = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let forward = -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        var nearest: Float = 6
        var result: CaptureStructuralCategory?
        for face in faces {
            let delta = face.center - camera
            let distance = simd_length(delta)
            guard distance > 0.3, distance < nearest,
                  simd_dot(delta / distance, forward) > 0.99 else { continue }
            nearest = distance
            result = face.category
        }
        return result
    }
}
