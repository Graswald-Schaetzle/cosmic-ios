import Foundation
import Testing
@testable import CosmicCapture

@Suite("CaptureFrameQualityGate")
struct CaptureFrameQualityGateTests {
    private func signals(
        timestamp: TimeInterval,
        rotationalBlurPx: Float,
        translationalBlurPx: Float = 0
    ) -> CaptureQualitySignals {
        CaptureQualitySignals(
            timestamp: timestamp,
            linearSpeedMPS: 0,
            angularSpeedDPS: 0,
            rotationalBlurPx: rotationalBlurPx,
            translationalBlurPx: translationalBlurPx,
            exposureDurationSeconds: 1.0 / 60,
            meanLuma: 0.5,
            trackingNormal: true,
            trackingNormalDutyCycle: 1,
            pendingFrameWrites: 0,
            thermalState: .nominal
        )
    }

    @Test("No signals means no gating — evidence is required to reject")
    func acceptsWithoutSignals() {
        let gate = CaptureFrameQualityGate()
        #expect(gate.verdict(signals: nil, frameTimestamp: 10) == .accept)
    }

    @Test("Blur below the extreme threshold accepts")
    func acceptsModerateBlur() {
        let gate = CaptureFrameQualityGate()
        let verdict = gate.verdict(
            signals: signals(timestamp: 10, rotationalBlurPx: 40),
            frameTimestamp: 10.05
        )
        #expect(verdict == .accept)
    }

    @Test("Fresh extreme blur rejects the frame")
    func rejectsExtremeBlur() {
        let gate = CaptureFrameQualityGate()
        let verdict = gate.verdict(
            signals: signals(timestamp: 10, rotationalBlurPx: 80),
            frameTimestamp: 10.05
        )
        #expect(verdict == .rejectExtremeBlur)
    }

    @Test("Rotational and translational blur combine for the verdict")
    func combinedBlurTerms() {
        let gate = CaptureFrameQualityGate()
        let verdict = gate.verdict(
            signals: signals(
                timestamp: 10,
                rotationalBlurPx: 40,
                translationalBlurPx: 30
            ),
            frameTimestamp: 10.05
        )
        #expect(verdict == .rejectExtremeBlur)
    }

    @Test("Stale extreme blur never rejects a calm later frame")
    func staleSignalsAccept() {
        let gate = CaptureFrameQualityGate()
        // A pause/discontinuity left an old spike behind; the frame 2 s later
        // must not pay for it.
        let verdict = gate.verdict(
            signals: signals(timestamp: 10, rotationalBlurPx: 200),
            frameTimestamp: 12
        )
        #expect(verdict == .accept)
    }

    @Test("Blur exactly at the threshold still accepts (strict inequality)")
    func thresholdBoundary() {
        let gate = CaptureFrameQualityGate()
        let verdict = gate.verdict(
            signals: signals(
                timestamp: 10,
                rotationalBlurPx: gate.maxPredictedBlurPx
            ),
            frameTimestamp: 10.05
        )
        #expect(verdict == .accept)
    }
}
