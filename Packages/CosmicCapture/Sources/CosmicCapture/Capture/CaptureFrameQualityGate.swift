import Foundation

/// Conservative client-side frame-quality gate.
///
/// Only one high-confidence rejection is enabled: extreme predicted motion
/// blur, where the saved JPEG is near-certainly smeared and costs more than a
/// briefly lower keyframe rate. Everything else
/// stays advisory:
///
/// - Tracking loss already rejects frames in `ContinuousScanSampler`
///   (`trackingNormal` gate); this gate does not duplicate it.
/// - Writer backpressure remains a separate mechanism
///   (`maxPendingFrameWrites` in the coordinator), never mixed in here.
/// - Coaching thresholds in `CaptureGuidanceArbiter` fire far earlier; by the
///   time this gate rejects, the user has long been told to slow down.
///
/// Thresholds are deliberately loose, hand-tuned from real scans, and
/// versioned in code.
struct CaptureFrameQualityGate: Sendable {
    /// Bump when hand-tuning thresholds so notes can reference the exact
    /// gate behavior a scan ran with.
    static let thresholdsVersion = 1

    /// Predicted blur (rotational + translational) above this rejects the
    /// frame. ~64 px at fx≈1500 px and 1/60 s exposure corresponds to about
    /// 2.5 rad/s (~145°/s) of rotation — violent motion, well past any
    /// deliberate scanning pace. The arbiter's coaching
    /// threshold is an order of magnitude lower.
    var maxPredictedBlurPx: Float = 64
    /// Signals older than this (pauses, discontinuities) never gate — a stale
    /// spike must not reject a calm frame.
    var maxSignalAgeSeconds: TimeInterval = 0.3

    enum Verdict: Equatable, Sendable {
        case accept
        case rejectExtremeBlur
    }

    /// No signals, stale signals, or non-extreme blur all accept: the gate
    /// only acts on fresh, high-confidence evidence.
    func verdict(
        signals: CaptureQualitySignals?,
        frameTimestamp: TimeInterval
    ) -> Verdict {
        guard let signals,
              frameTimestamp - signals.timestamp <= maxSignalAgeSeconds,
              signals.predictedBlurPx > maxPredictedBlurPx
        else {
            return .accept
        }
        return .rejectExtremeBlur
    }
}
