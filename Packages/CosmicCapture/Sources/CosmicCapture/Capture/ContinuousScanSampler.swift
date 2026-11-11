import Foundation
import simd

struct ContinuousScanSample: Hashable, Sendable {
    let reason: String
    let poseDeltaM: Float
    let poseDeltaDeg: Float
    let linearSpeedMPS: Float
    let angularSpeedDPS: Float
}

struct ContinuousScanStats: Hashable, Sendable {
    let startedAt: Date
    let durationSeconds: TimeInterval
    let activeDurationSeconds: TimeInterval
    let frameCount: Int
    let pathLengthM: Float
    let maxDistanceFromOriginM: Float
    let translationSpanX: Float
    let translationSpanY: Float
    let translationSpanZ: Float
    let qualityHint: String
}

/// Keyframe sampler. ARKit-independent: only pose + timestamp +
/// tracking normality. Samples only while tracking is normal, rejects before any index is
/// assigned.
final class ContinuousScanSampler: @unchecked Sendable {
    private let minTranslationDeltaM: Float = 0.07
    private let minRotationDeltaDeg: Float = 10
    private let heartbeatInterval: TimeInterval = 0.35
    private let heartbeatMinTranslationDeltaM: Float = 0.01
    private let heartbeatMinRotationDeltaDeg: Float = 1.5
    private let minSampleInterval: TimeInterval = 0.12
    private let maxFrames: Int

    private var startedAt = Date()
    private var startTimestamp: TimeInterval?
    private var startTranslation: SIMD3<Float>?
    private var lastPoseTranslation: SIMD3<Float>?
    private var lastSampleTranslation: SIMD3<Float>?
    private var lastSampleForward: SIMD3<Float>?
    private var lastSampleTimestamp: TimeInterval?
    private var minX: Float = .greatestFiniteMagnitude
    private var maxX: Float = -.greatestFiniteMagnitude
    private var minY: Float = .greatestFiniteMagnitude
    private var maxY: Float = -.greatestFiniteMagnitude
    private var minZ: Float = .greatestFiniteMagnitude
    private var maxZ: Float = -.greatestFiniteMagnitude

    private(set) var frameCount = 0
    private(set) var activeDurationSeconds: TimeInterval = 0
    private(set) var pathLengthM: Float = 0
    private(set) var maxDistanceFromOriginM: Float = 0
    private(set) var latestQualityHint = "Move slowly"
    /// Frames already committed by earlier sessions of a resumed capture; they
    /// consume the same global budget so continuation cannot exceed `maxFrames`
    /// in total.
    private var priorFrameCount = 0

    var isAtFrameLimit: Bool { priorFrameCount + frameCount >= maxFrames }
    var isApproachingFrameLimit: Bool {
        let totalFrameCount = priorFrameCount + frameCount
        return totalFrameCount < maxFrames
            && totalFrameCount * 5 >= maxFrames * 4
    }

    init(maxFrames: Int = CapturePaths.maxFrames) {
        self.maxFrames = maxFrames
    }

    func reset(now: Date = Date(), priorFrameCount: Int = 0) {
        self.priorFrameCount = priorFrameCount
        startedAt = now
        startTimestamp = nil
        startTranslation = nil
        lastPoseTranslation = nil
        lastSampleTranslation = nil
        lastSampleForward = nil
        lastSampleTimestamp = nil
        minX = .greatestFiniteMagnitude
        maxX = -.greatestFiniteMagnitude
        minY = .greatestFiniteMagnitude
        maxY = -.greatestFiniteMagnitude
        minZ = .greatestFiniteMagnitude
        maxZ = -.greatestFiniteMagnitude
        frameCount = 0
        activeDurationSeconds = 0
        pathLengthM = 0
        maxDistanceFromOriginM = 0
        latestQualityHint = "Move slowly"
    }

    func observe(
        translation: SIMD3<Float>,
        forward: SIMD3<Float>,
        timestamp: TimeInterval,
        trackingNormal: Bool,
        canEmitSample: Bool = true
    ) -> ContinuousScanSample? {
        if startTimestamp == nil {
            startTimestamp = timestamp
            startTranslation = translation
        }

        updateMotionStats(translation: translation)

        guard priorFrameCount + frameCount < maxFrames else {
            latestQualityHint = "Scan limit reached"
            return nil
        }

        guard trackingNormal else {
            latestQualityHint = "Tracking lost. Hold still"
            return nil
        }
        guard canEmitSample else { return nil }

        let poseDelta = lastSampleTranslation.map { simd_distance(translation, $0) }
            ?? .greatestFiniteMagnitude
        let angleDelta = lastSampleForward.map { Self.angleDegrees($0, forward) }
            ?? .greatestFiniteMagnitude
        let hadPreviousSample = lastSampleTimestamp != nil
        let timeDelta = timestamp - (lastSampleTimestamp ?? 0)
        let hasHeartbeatMotion = poseDelta >= heartbeatMinTranslationDeltaM
            || angleDelta >= heartbeatMinRotationDeltaDeg

        guard timeDelta >= minSampleInterval else { return nil }

        let reason: String
        if !hadPreviousSample {
            reason = "initial"
        } else if poseDelta >= minTranslationDeltaM {
            reason = "translation"
        } else if angleDelta >= minRotationDeltaDeg {
            reason = "rotation"
        } else if timeDelta >= heartbeatInterval, hasHeartbeatMotion {
            reason = "heartbeat"
        } else {
            return nil
        }

        lastSampleTranslation = translation
        lastSampleForward = forward
        lastSampleTimestamp = timestamp
        frameCount += 1
        if hadPreviousSample, timeDelta > 0 {
            // Productive time advances only between accepted samples. Clamp a
            // long stationary/tracking gap so returning movement does not turn
            // idle wall-clock time into apparent capture progress.
            activeDurationSeconds += min(timeDelta, heartbeatInterval)
        }

        // Speeds must divide the delta since the last accepted sample by the same
        // time window, not the last AR-frame interval — mixing windows exaggerated
        // speed by up to the sample/frame interval ratio.
        let linearSpeed: Float
        let angularSpeed: Float
        if hadPreviousSample, timeDelta > 0 {
            linearSpeed = poseDelta / Float(timeDelta)
            angularSpeed = angleDelta / Float(timeDelta)
        } else {
            linearSpeed = 0
            angularSpeed = 0
        }
        latestQualityHint = hint(linearSpeed: linearSpeed, angularSpeed: angularSpeed)

        return ContinuousScanSample(
            reason: reason,
            poseDeltaM: hadPreviousSample ? poseDelta : 0,
            poseDeltaDeg: hadPreviousSample ? angleDelta : 0,
            linearSpeedMPS: linearSpeed,
            angularSpeedDPS: angularSpeed
        )
    }

    func stats(now: Date = Date()) -> ContinuousScanStats {
        ContinuousScanStats(
            startedAt: startedAt,
            durationSeconds: now.timeIntervalSince(startedAt),
            activeDurationSeconds: activeDurationSeconds,
            frameCount: frameCount,
            pathLengthM: pathLengthM,
            maxDistanceFromOriginM: maxDistanceFromOriginM,
            translationSpanX: span(min: minX, max: maxX),
            translationSpanY: span(min: minY, max: maxY),
            translationSpanZ: span(min: minZ, max: maxZ),
            qualityHint: latestQualityHint
        )
    }

    private func updateMotionStats(translation: SIMD3<Float>) {
        if let lastPoseTranslation {
            pathLengthM += simd_distance(translation, lastPoseTranslation)
        }
        lastPoseTranslation = translation
        minX = min(minX, translation.x)
        maxX = max(maxX, translation.x)
        minY = min(minY, translation.y)
        maxY = max(maxY, translation.y)
        minZ = min(minZ, translation.z)
        maxZ = max(maxZ, translation.z)
        if let startTranslation {
            maxDistanceFromOriginM = max(
                maxDistanceFromOriginM,
                simd_distance(translation, startTranslation)
            )
        }
    }

    private func hint(linearSpeed: Float, angularSpeed: Float) -> String {
        if linearSpeed > 0.8 || angularSpeed > 140 { return "Move slowly" }
        return "Move slowly"
    }

    private func span(min: Float, max: Float) -> Float {
        guard min.isFinite, max.isFinite, max >= min else { return 0 }
        return max - min
    }

    private static func angleDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let dot = simd_dot(simd_normalize(a), simd_normalize(b))
        return acos(simd_clamp(dot, -1, 1)) * 180 / .pi
    }
}

/// Advisory finish warnings only — never blocks finishing.
enum CaptureQualityAdvisor {
    struct Warning: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let message: String
    }

    static func warnings(
        frameCount: Int,
        pathLengthM: Float,
        durationSeconds: TimeInterval
    ) -> [Warning] {
        var result: [Warning] = []
        if frameCount < 30 {
            result.append(
                Warning(
                    id: "few_frames",
                    title: "This scan is short",
                    message: "\(formatDuration(durationSeconds)) scanned. Scan a little longer for more complete coverage."
                )
            )
        }
        if pathLengthM < 0.5 {
            result.append(
                Warning(
                    id: "limited_motion",
                    title: "Try moving around the space",
                    message: "\(formatDuration(durationSeconds)) scanned. Walk a bit farther so the camera sees each surface from more than one angle."
                )
            )
        }
        return result
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        CaptureFormatting.duration(seconds)
    }
}
