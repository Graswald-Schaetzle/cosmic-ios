import Foundation
import simd
import Testing
@testable import CosmicCapture

@Suite("ContinuousScanSampler")
struct ContinuousScanSamplerTests {
    @Test("Rejects non-normal tracking before counting a frame")
    func rejectsNonNormal() {
        let sampler = ContinuousScanSampler(maxFrames: 10)
        let sample = sampler.observe(
            translation: SIMD3(0, 0, 0),
            forward: SIMD3(0, 0, -1),
            timestamp: 1,
            trackingNormal: false
        )
        #expect(sample == nil)
        #expect(sampler.frameCount == 0)
    }

    @Test("Accepts initial sample and translation threshold")
    func samplesOnTranslation() {
        let sampler = ContinuousScanSampler(maxFrames: 10)
        let first = sampler.observe(
            translation: .zero,
            forward: SIMD3(0, 0, -1),
            timestamp: 1,
            trackingNormal: true
        )
        #expect(first?.reason == "initial")
        #expect(sampler.frameCount == 1)

        let tooClose = sampler.observe(
            translation: SIMD3(0.02, 0, 0),
            forward: SIMD3(0, 0, -1),
            timestamp: 1.2,
            trackingNormal: true
        )
        #expect(tooClose == nil)

        let moved = sampler.observe(
            translation: SIMD3(0.1, 0, 0),
            forward: SIMD3(0, 0, -1),
            timestamp: 1.4,
            trackingNormal: true
        )
        #expect(moved?.reason == "translation")
        #expect(sampler.frameCount == 2)
    }

    @Test("Stationary pose noise does not emit heartbeat samples")
    func stationaryPoseNoiseDoesNotSample() {
        let sampler = ContinuousScanSampler(maxFrames: 100)
        var acceptedReasons: [String] = []

        for frameIndex in 0...50 {
            let jitterSign: Float = frameIndex.isMultiple(of: 2) ? 1 : -1
            let sample = sampler.observe(
                translation: SIMD3(jitterSign * 0.002, 0, 0),
                forward: forward(yawDegrees: jitterSign * 0.25),
                timestamp: 1 + Double(frameIndex) * 0.1,
                trackingNormal: true
            )
            if let sample {
                acceptedReasons.append(sample.reason)
            }
        }

        #expect(acceptedReasons == ["initial"])
        #expect(sampler.frameCount == 1)
    }

    @Test("Slow sub-threshold pan accumulates into heartbeat samples")
    func slowPanAccumulates() {
        let sampler = ContinuousScanSampler(maxFrames: 10)
        let initial = sampler.observe(
            translation: .zero,
            forward: forward(yawDegrees: 0),
            timestamp: 1,
            trackingNormal: true
        )
        #expect(initial?.reason == "initial")

        for step in 1...3 {
            let sample = sampler.observe(
                translation: .zero,
                forward: forward(yawDegrees: Float(step) * 0.4),
                timestamp: 1 + Double(step) * 0.1,
                trackingNormal: true
            )
            #expect(sample == nil)
        }

        let accumulated = sampler.observe(
            translation: .zero,
            forward: forward(yawDegrees: 1.6),
            timestamp: 1.4,
            trackingNormal: true
        )
        #expect(accumulated?.reason == "heartbeat")
        #expect((accumulated?.poseDeltaDeg ?? 0) >= 1.5)
        #expect((accumulated?.poseDeltaDeg ?? 10) < 10)
        #expect(sampler.frameCount == 2)
    }

    @Test("Writer backpressure preserves motion for the next emitted sample")
    func backpressurePreservesMotion() {
        let sampler = ContinuousScanSampler(maxFrames: 10)
        _ = sampler.observe(
            translation: .zero,
            forward: forward(yawDegrees: 0),
            timestamp: 1,
            trackingNormal: true
        )

        let blocked = sampler.observe(
            translation: SIMD3(0.08, 0, 0),
            forward: forward(yawDegrees: 0),
            timestamp: 1.2,
            trackingNormal: true,
            canEmitSample: false
        )
        let resumed = sampler.observe(
            translation: SIMD3(0.08, 0, 0),
            forward: forward(yawDegrees: 0),
            timestamp: 1.4,
            trackingNormal: true
        )

        #expect(blocked == nil)
        #expect(resumed?.reason == "translation")
        #expect(sampler.frameCount == 2)
    }

    @Test("Sample speed divides displacement by the sample window, not the frame interval")
    func speedUsesSampleWindow() {
        let sampler = ContinuousScanSampler(maxFrames: 10)
        let initial = sampler.observe(
            translation: .zero,
            forward: SIMD3(0, 0, -1),
            timestamp: 1,
            trackingNormal: true
        )
        #expect(initial?.linearSpeedMPS == 0)
        #expect(initial?.angularSpeedDPS == 0)

        // Sub-heartbeat frames in between must not shrink the speed window.
        for step in 1...3 {
            let quiet = sampler.observe(
                translation: SIMD3(Float(step) * 0.002, 0, 0),
                forward: SIMD3(0, 0, -1),
                timestamp: 1 + Double(step) * 0.25,
                trackingNormal: true
            )
            #expect(quiet == nil)
        }

        // 0.1 m since the last accepted sample, over a 1.0 s window: 0.1 m/s.
        // The old math divided by the previous frame interval (0.25 s) and
        // reported 0.4 m/s.
        let sample = sampler.observe(
            translation: SIMD3(0.1, 0, 0),
            forward: SIMD3(0, 0, -1),
            timestamp: 2,
            trackingNormal: true
        )
        #expect(sample?.reason == "translation")
        #expect(abs((sample?.linearSpeedMPS ?? 0) - 0.1) < 0.001)
    }

    @Test("Respects max frame cap")
    func maxFrames() {
        let sampler = ContinuousScanSampler(maxFrames: 2)
        _ = sampler.observe(
            translation: .zero,
            forward: SIMD3(0, 0, -1),
            timestamp: 1,
            trackingNormal: true
        )
        _ = sampler.observe(
            translation: SIMD3(1, 0, 0),
            forward: SIMD3(0, 0, -1),
            timestamp: 2,
            trackingNormal: true
        )
        let third = sampler.observe(
            translation: SIMD3(2, 0, 0),
            forward: SIMD3(0, 0, -1),
            timestamp: 3,
            trackingNormal: true
        )
        #expect(third == nil)
        #expect(sampler.frameCount == 2)
    }

    @Test("Frame limit is five thousand frames")
    func frameLimit() {
        #expect(CapturePaths.maxFrames == 5_000)
    }

    @Test("Approaching limit starts at eighty percent without exposing count")
    func approachingFrameLimit() {
        let sampler = ContinuousScanSampler(maxFrames: 5)
        for index in 0..<4 {
            _ = sampler.observe(
                translation: SIMD3(Float(index), 0, 0),
                forward: SIMD3(0, 0, -1),
                timestamp: Double(index + 1),
                trackingNormal: true
            )
        }

        #expect(sampler.isApproachingFrameLimit)
        _ = sampler.observe(
            translation: SIMD3(4, 0, 0),
            forward: SIMD3(0, 0, -1),
            timestamp: 5,
            trackingNormal: true
        )
        #expect(!sampler.isApproachingFrameLimit)
        #expect(sampler.isAtFrameLimit)
    }

    @Test("Active duration excludes long stationary gaps")
    func activeDurationExcludesIdleTime() {
        let sampler = ContinuousScanSampler(maxFrames: 10)
        let startedAt = Date(timeIntervalSince1970: 0)
        sampler.reset(now: startedAt)
        _ = sampler.observe(
            translation: .zero,
            forward: SIMD3(0, 0, -1),
            timestamp: 1,
            trackingNormal: true
        )
        _ = sampler.observe(
            translation: SIMD3(0.1, 0, 0),
            forward: SIMD3(0, 0, -1),
            timestamp: 1.2,
            trackingNormal: true
        )
        _ = sampler.observe(
            translation: SIMD3(0.2, 0, 0),
            forward: SIMD3(0, 0, -1),
            timestamp: 61.2,
            trackingNormal: true
        )

        #expect(abs(sampler.activeDurationSeconds - 0.55) < 0.001)
        let elapsed = sampler.stats(
            now: startedAt.addingTimeInterval(61.2)
        ).durationSeconds
        #expect(abs(elapsed - 61.2) < 0.001)
    }

    private func forward(yawDegrees: Float) -> SIMD3<Float> {
        let yawRadians = yawDegrees * .pi / 180
        return SIMD3(sin(yawRadians), 0, -cos(yawRadians))
    }
}

@Suite("Latest value inbox")
struct LatestValueInboxTests {
    @Test("Coalesces queued values while one consumer is scheduled")
    func coalescesPendingValues() {
        let inbox = LatestValueInbox<Int>()

        #expect(inbox.submit(1))
        #expect(!inbox.submit(2))
        #expect(inbox.takeLatest() == 2)

        #expect(!inbox.submit(3))
        #expect(inbox.finishCurrent())
        #expect(inbox.takeLatest() == 3)
        #expect(!inbox.finishCurrent())

        #expect(inbox.submit(4))
        #expect(inbox.takeLatest() == 4)
    }

    @Test("Reset drops preview values and permits a capture consumer")
    func resetAtCaptureBoundary() {
        let inbox = LatestValueInbox<Int>()

        #expect(inbox.submit(1))
        inbox.reset()

        #expect(inbox.takeLatest() == nil)
        #expect(inbox.submit(2))
        #expect(inbox.takeLatest() == 2)
    }
}

@Suite("Capture scene phase policy")
struct CaptureScenePhasePolicyTests {
    @Test("Transient inactivity pauses and foregrounding resumes")
    func pausesAndResumes() {
        var policy = CaptureScenePhasePolicy()

        let inactiveAction = policy.action(
            for: .inactive,
            isCapturing: true,
            isFinishReviewPresented: false
        )
        let activeAction = policy.action(
            for: .active,
            isCapturing: true,
            isFinishReviewPresented: false
        )

        #expect(inactiveAction == .pause)
        #expect(activeAction == .resume)
    }

    @Test("Background saves instead of resuming another AR epoch")
    func backgroundSaves() {
        var policy = CaptureScenePhasePolicy()

        let inactiveAction = policy.action(
            for: .inactive,
            isCapturing: true,
            isFinishReviewPresented: false
        )
        let backgroundAction = policy.action(
            for: .background,
            isCapturing: true,
            isFinishReviewPresented: false
        )
        let activeAction = policy.action(
            for: .active,
            isCapturing: false,
            isFinishReviewPresented: false
        )

        #expect(inactiveAction == .pause)
        #expect(backgroundAction == .save)
        #expect(activeAction == .none)
    }

    @Test("Finish review owns its existing pause")
    func finishReviewDoesNotSceneResume() {
        var policy = CaptureScenePhasePolicy()

        let inactiveAction = policy.action(
            for: .inactive,
            isCapturing: true,
            isFinishReviewPresented: true
        )
        let activeAction = policy.action(
            for: .active,
            isCapturing: true,
            isFinishReviewPresented: true
        )

        #expect(inactiveAction == .none)
        #expect(activeAction == .none)
    }
}

@Suite("CaptureQualityAdvisor")
struct CaptureQualityAdvisorTests {
    @Test("Emits advisory warnings without blocking")
    func advisories() {
        let warnings = CaptureQualityAdvisor.warnings(
            frameCount: 10,
            pathLengthM: 0.1,
            durationSeconds: 12
        )
        #expect(warnings.contains(where: { $0.id == "few_frames" }))
        #expect(warnings.contains(where: { $0.id == "limited_motion" }))
    }
}
