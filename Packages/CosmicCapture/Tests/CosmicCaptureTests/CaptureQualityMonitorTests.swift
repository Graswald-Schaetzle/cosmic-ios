import Foundation
import simd
import Testing
@testable import CosmicCapture

@Suite("CaptureQualityMonitor")
struct CaptureQualityMonitorTests {
    private let identity = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))

    private func input(
        timestamp: TimeInterval,
        translation: SIMD3<Float> = .zero,
        rotation: simd_quatf? = nil,
        exposure: TimeInterval = 1.0 / 60,
        focalLengthPx: Float = 1500,
        trackingNormal: Bool = true,
        meanLuma: Float? = nil,
        pendingFrameWrites: Int = 0
    ) -> CaptureQualityFrameInput {
        CaptureQualityFrameInput(
            timestamp: timestamp,
            translation: translation,
            rotation: rotation ?? identity,
            exposureDurationSeconds: exposure,
            focalLengthPx: focalLengthPx,
            trackingNormal: trackingNormal,
            meanLuma: meanLuma,
            pendingFrameWrites: pendingFrameWrites,
            thermalState: .nominal
        )
    }

    @Test("Linear speed divides displacement by the same emit window")
    func linearSpeedWindowMatches() {
        let monitor = CaptureQualityMonitor()
        #expect(monitor.observe(input(timestamp: 0)) == nil)

        let signals = monitor.observe(
            input(timestamp: 0.1, translation: SIMD3(0.05, 0, 0))
        )
        #expect(signals != nil)
        #expect(abs((signals?.linearSpeedMPS ?? 0) - 0.5) < 0.01)
    }

    @Test("Angular speed uses the full rotation, including roll")
    func angularSpeedIncludesRoll() {
        let monitor = CaptureQualityMonitor()
        _ = monitor.observe(input(timestamp: 0))

        // Roll about the view axis leaves the forward vector unchanged; the
        // quaternion geodesic must still see it.
        let rolled = simd_quatf(
            angle: 9 * .pi / 180,
            axis: SIMD3(0, 0, -1)
        )
        let signals = monitor.observe(input(timestamp: 0.1, rotation: rolled))
        #expect(abs((signals?.angularSpeedDPS ?? 0) - 90) < 1)
    }

    @Test("Rotational blur is fx times angular velocity times exposure")
    func rotationalBlur() {
        let monitor = CaptureQualityMonitor()
        _ = monitor.observe(input(timestamp: 0))

        // 0.1 rad over 0.1 s = 1 rad/s; 1500 px × 1 rad/s × (1/60) s = 25 px.
        let rotated = simd_quatf(angle: 0.1, axis: SIMD3(0, 1, 0))
        let signals = monitor.observe(input(timestamp: 0.1, rotation: rotated))
        #expect(abs((signals?.rotationalBlurPx ?? 0) - 25) < 0.5)
    }

    @Test("Translational blur uses lateral velocity over the nominal 2 m depth")
    func translationalBlur() {
        let monitor = CaptureQualityMonitor()
        _ = monitor.observe(input(timestamp: 0))

        // Camera faces -z, moves along x: fully lateral. 0.05 m over 0.1 s =
        // 0.5 m/s; at the contract's 2 m depth: 1500 × 0.5 / 2 × (1/60) = 6.25 px.
        let signals = monitor.observe(
            input(timestamp: 0.1, translation: SIMD3(0.05, 0, 0))
        )
        #expect(abs((signals?.translationalBlurPx ?? 0) - 6.25) < 0.25)
    }

    @Test("Forward motion produces no translational blur")
    func forwardMotionNoLateralBlur() {
        let monitor = CaptureQualityMonitor()
        _ = monitor.observe(input(timestamp: 0))

        // Camera faces -z and moves along -z: zero lateral component.
        let signals = monitor.observe(
            input(timestamp: 0.1, translation: SIMD3(0, 0, -0.05))
        )
        #expect((signals?.translationalBlurPx ?? 1) < 0.01)
    }

    @Test("Emission is throttled to the emit interval")
    func emitThrottle() {
        let monitor = CaptureQualityMonitor()
        _ = monitor.observe(input(timestamp: 0))

        #expect(monitor.observe(input(timestamp: 0.033)) == nil)
        #expect(monitor.observe(input(timestamp: 0.066)) == nil)
        #expect(monitor.observe(input(timestamp: 0.1)) != nil)
    }

    @Test("A time gap restarts the window instead of emitting bogus velocity")
    func gapDiscontinuity() {
        let monitor = CaptureQualityMonitor()
        _ = monitor.observe(input(timestamp: 0))

        // Pause/interruption gap: 5 m displacement over 1 s window would be
        // 5 m/s if naively divided — must emit nothing and re-reference.
        let afterGap = monitor.observe(
            input(timestamp: 1.0, translation: SIMD3(5, 0, 0))
        )
        #expect(afterGap == nil)

        let next = monitor.observe(
            input(timestamp: 1.1, translation: SIMD3(5.05, 0, 0))
        )
        #expect(abs((next?.linearSpeedMPS ?? 0) - 0.5) < 0.01)
    }

    @Test("Tracking duty cycle reflects the recent window")
    func trackingDutyCycle() {
        let monitor = CaptureQualityMonitor()
        _ = monitor.observe(input(timestamp: 0))
        _ = monitor.observe(input(timestamp: 0.05, trackingNormal: false))
        let signals = monitor.observe(input(timestamp: 0.1))

        // Three frames observed, one limited.
        #expect(abs((signals?.trackingNormalDutyCycle ?? 0) - 2.0 / 3.0) < 0.01)
    }

    @Test("Luma sampling cadence and carry-forward")
    func lumaCadence() {
        let monitor = CaptureQualityMonitor()
        #expect(monitor.wantsLumaSample(at: 0))

        _ = monitor.observe(input(timestamp: 0, meanLuma: 0.4))
        #expect(!monitor.wantsLumaSample(at: 0.1))
        #expect(monitor.wantsLumaSample(at: 0.6))

        // Carried forward on frames without a fresh sample.
        let signals = monitor.observe(input(timestamp: 0.1))
        #expect(signals?.meanLuma == 0.4)
    }

    @Test("Reset clears state and signals")
    func resetClears() {
        let monitor = CaptureQualityMonitor()
        _ = monitor.observe(input(timestamp: 0))
        _ = monitor.observe(input(timestamp: 0.1, translation: SIMD3(0.05, 0, 0)))
        #expect(monitor.latestSignals != nil)

        monitor.reset()
        #expect(monitor.latestSignals == nil)
        #expect(monitor.wantsLumaSample(at: 0.2))
        // First frame after reset only establishes the reference.
        #expect(monitor.observe(input(timestamp: 0.2)) == nil)
    }

    @Test("Rotation angle helper handles quaternion double cover")
    func rotationAngleDoubleCover() {
        let quarterTurn = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        let angle = CaptureQualityMonitor.rotationAngleRadians(
            from: quarterTurn,
            to: -quarterTurn
        )
        #expect(abs(angle) < 0.001)
    }
}
