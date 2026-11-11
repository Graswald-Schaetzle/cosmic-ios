import Testing
import simd
@testable import CosmicCapture

struct CaptureAimTrackerTests {
    private func pose(_ degrees: Float, roll: Float = 0) -> simd_float4x4 {
        let tilt = simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(1, 0, 0))
        let rotation = simd_quatf(angle: roll * .pi / 180, axis: SIMD3(0, 0, 1))
        return simd_float4x4(tilt * rotation)
    }

    @Test func requiresSustainedTiltAndUsesHysteresis() {
        var tracker = CaptureAimTracker()
        let initial = tracker.update(worldFromCamera: pose(35), timestamp: 0)
        #expect(initial == nil)
        let up = tracker.update(worldFromCamera: pose(35), timestamp: 0.7)
        #expect(up == .up)
        let jitter = tracker.update(worldFromCamera: pose(20), timestamp: 1)
        #expect(jitter == .up)
        _ = tracker.update(worldFromCamera: pose(0), timestamp: 2)
        let brief = tracker.update(worldFromCamera: pose(35), timestamp: 2.2)
        #expect(brief == .up)
        _ = tracker.update(worldFromCamera: pose(0), timestamp: 3)
        let level = tracker.update(worldFromCamera: pose(0), timestamp: 3.7)
        #expect(level == .level)
    }

    @Test(arguments: [Float(-90), 0, 90, 180])
    func deviceRollDoesNotChangeAim(roll: Float) {
        var tracker = CaptureAimTracker()
        _ = tracker.update(worldFromCamera: pose(-35, roll: roll), timestamp: 0)
        let down = tracker.update(worldFromCamera: pose(-35, roll: roll), timestamp: 1)
        #expect(down == .down)
    }

    @Test func resetRequiresFreshEvidence() {
        var tracker = CaptureAimTracker()
        _ = tracker.update(worldFromCamera: pose(35), timestamp: 0)
        _ = tracker.update(worldFromCamera: pose(35), timestamp: 1)
        tracker.reset()
        #expect(tracker.aim == nil)
        let fresh = tracker.update(worldFromCamera: pose(-35), timestamp: 100)
        #expect(fresh == nil)
    }

    @Test func instructionChangesFromTiltToMovementWithoutClaimingCompletion() {
        #expect(CaptureScanPass.ceiling.instruction(aim: .level) == "Tilt up and sweep the ceiling")
        #expect(CaptureScanPass.ceiling.instruction(aim: .up) == "Move along the ceiling")
        #expect(CaptureScanPass.floor.symbol(aim: .down) == "arrow.left.and.right")
        #expect(CaptureScanPass.walls.symbol(aim: .up) == "arrow.down")
        #expect(CaptureScanPass.walls.symbol(aim: .down) == "arrow.up")
    }

    @Test func correctionSurvivesNeutralBridgeAndConfirmsOnlyOnce() {
        var feedback = CaptureAimFeedback()
        let opposite = feedback.update(pass: .ceiling, aim: .down, eligible: true)
        let bridge = feedback.update(pass: .ceiling, aim: .level, eligible: true)
        let corrected = feedback.update(pass: .ceiling, aim: .up, eligible: true)
        let steady = feedback.update(pass: .ceiling, aim: .up, eligible: true)
        #expect(opposite == .correcting)
        #expect(bridge == .correcting)
        #expect(corrected == .corrected)
        #expect(steady == .neutral)
    }

    @Test func changingPassDoesNotCelebrateChangingTheGoal() {
        var feedback = CaptureAimFeedback()
        _ = feedback.update(pass: .ceiling, aim: .down, eligible: true)
        let changed = feedback.update(pass: .floor, aim: .down, eligible: true)
        #expect(changed == .neutral)
    }

    @Test func interruptionOrUnknownAimClearsCorrectionHistory() {
        for unknown in [false, true] {
            var feedback = CaptureAimFeedback()
            _ = feedback.update(pass: .floor, aim: .up, eligible: true)
            _ = feedback.update(pass: .floor, aim: unknown ? nil : .up, eligible: unknown)
            let recovered = feedback.update(pass: .floor, aim: .down, eligible: true)
            #expect(recovered == .neutral)
        }
    }

    @Test func normalScanningIsQuietAndWallsRecoverAtLevel() {
        var feedback = CaptureAimFeedback()
        let level = feedback.update(pass: .ceiling, aim: .level, eligible: true)
        let up = feedback.update(pass: .ceiling, aim: .up, eligible: true)
        let wallMismatch = feedback.update(pass: .walls, aim: .up, eligible: true)
        let wallCorrected = feedback.update(pass: .walls, aim: .level, eligible: true)
        #expect(level == .neutral)
        #expect(up == .neutral)
        #expect(wallMismatch == .correcting)
        #expect(wallCorrected == .corrected)
    }
}
