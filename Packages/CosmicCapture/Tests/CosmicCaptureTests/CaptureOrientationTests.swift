import Testing
import UIKit
@testable import CosmicCapture

@Suite("Capture orientation")
@MainActor
struct CaptureOrientationTests {
    @Test("Normal UI and readiness follow device orientation")
    func unlockedLifecycleStages() {
        var policy = CaptureOrientationLifecyclePolicy()

        #expect(policy.supportedMask == .allButUpsideDown)

        policy.beginCapturePresentation()

        #expect(policy.stage == .readiness)
        #expect(policy.supportedMask == .allButUpsideDown)
    }

    @Test(
        "Starting capture locks the current interface orientation",
        arguments: [
            (
                UIInterfaceOrientation.portrait,
                UIInterfaceOrientationMask.portrait,
                CaptureHoldMode.portrait
            ),
            (
                UIInterfaceOrientation.landscapeLeft,
                UIInterfaceOrientationMask.landscapeLeft,
                CaptureHoldMode.landscape
            ),
            (
                UIInterfaceOrientation.landscapeRight,
                UIInterfaceOrientationMask.landscapeRight,
                CaptureHoldMode.landscape
            ),
        ]
    )
    func captureLock(
        interfaceOrientation: UIInterfaceOrientation,
        expectedMask: UIInterfaceOrientationMask,
        expectedHoldMode: CaptureHoldMode
    ) {
        let lock = CaptureOrientationLifecyclePolicy.lock(
            for: interfaceOrientation
        )

        #expect(lock.mask == expectedMask)
        #expect(lock.holdMode == expectedHoldMode)
    }

    @Test("Capture lock survives review and saving, then releases")
    func captureLifecycle() {
        var policy = CaptureOrientationLifecyclePolicy()
        policy.beginCapturePresentation()
        policy.lockForCapture(.landscapeRight)

        let lockedStages: [CaptureOrientationLifecycleStage] = [
            .live,
            .finish,
            .saving,
            .saved,
            .background,
            .foreground,
        ]
        for stage in lockedStages {
            policy.transition(to: stage)
            #expect(policy.supportedMask == .landscapeRight)
        }

        policy.endCapturePresentation()

        #expect(policy.stage == nil)
        #expect(policy.supportedMask == .allButUpsideDown)
    }

    @Test("iPad rotates freely until capture locks")
    func padRotatesFreelyOutsideCapture() {
        var policy = CaptureOrientationLifecyclePolicy(deviceClass: .pad)
        #expect(policy.supportedMask == .all)

        policy.beginCapturePresentation()
        #expect(policy.supportedMask == .all)
        policy.lockForCapture(.portraitUpsideDown)
        #expect(policy.supportedMask == .portraitUpsideDown)

        policy.endCapturePresentation()
        #expect(policy.supportedMask == .all)
    }

    @Test("Upside-down portrait locks in place with a portrait hold")
    func upsideDownCaptureLock() {
        let lock = CaptureOrientationLifecyclePolicy.lock(
            for: .portraitUpsideDown
        )

        #expect(lock.mask == .portraitUpsideDown)
        #expect(lock.holdMode == .portrait)
    }

    @Test("Orientation lock tracks the capture lifecycle")
    func orientationLockTracksLifecycle() {
        CaptureOrientationLock.beginCapturePresentation()
        defer { CaptureOrientationLock.endCapturePresentation() }

        let holdMode = CaptureOrientationLock.lockForCapture(
            interfaceOrientation: .landscapeRight
        )

        #expect(CaptureOrientationLock.currentMask == .landscapeRight)
        #expect(holdMode == .landscape)
    }

    @Test("App delegate reports the active lifecycle mask")
    func appDelegateReportsActiveMask() {
        let delegate = CaptureAppDelegate()
        CaptureOrientationLock.beginCapturePresentation()
        _ = CaptureOrientationLock.lockForCapture(
            interfaceOrientation: .landscapeLeft
        )
        defer { CaptureOrientationLock.endCapturePresentation() }

        let mask = delegate.application(
            UIApplication.shared,
            supportedInterfaceOrientationsFor: nil
        )

        #expect(mask == .landscapeLeft)
    }
}
