import Foundation
import simd
import Testing
@testable import CosmicCapture

@Suite("CaptureGuidanceArbiter")
struct CaptureGuidanceArbiterTests {
    /// Steps a condition through the arbiter at a fixed cadence and returns the
    /// last guidance. Timelines are fully deterministic — time only comes from
    /// the inputs.
    private func run(
        _ arbiter: CaptureGuidanceArbiter,
        from start: TimeInterval,
        to end: TimeInterval,
        step: TimeInterval = 0.05,
        input: (TimeInterval) -> CaptureGuidanceInput
    ) -> CaptureGuidance? {
        var last: CaptureGuidance?
        var t = start
        while t <= end + 1e-9 {
            last = arbiter.evaluate(input(t))
            t += step
        }
        return last
    }

    @Test("Calm capture shows no message")
    func calmShowsNothing() {
        let arbiter = CaptureGuidanceArbiter()
        let guidance = run(arbiter, from: 0, to: 2) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 0.2)
        }
        #expect(guidance == nil)
    }

    @Test("Critical tracking enters only after its debounce")
    func criticalDebounce() {
        let arbiter = CaptureGuidanceArbiter()

        let immediate = arbiter.evaluate(
            CaptureGuidanceInput(timestamp: 0, tracking: .relocalizing)
        )
        #expect(immediate == nil)

        let after = run(arbiter, from: 0.05, to: 0.3) {
            CaptureGuidanceInput(timestamp: $0, tracking: .relocalizing)
        }
        #expect(after?.id == "tracking-recovering")
        #expect(after?.message == "Hold still. Recovering tracking")
        #expect(after?.severity == .critical)
    }

    @Test("Haptic fires once on escalation, then respects the budget")
    func hapticBudget() {
        let arbiter = CaptureGuidanceArbiter()

        var hapticCount = 0
        var t: TimeInterval = 0
        while t <= 3 {
            let guidance = arbiter.evaluate(
                CaptureGuidanceInput(timestamp: t, tracking: .relocalizing)
            )
            if guidance?.wantsHaptic == true { hapticCount += 1 }
            t += 0.05
        }
        #expect(hapticCount == 1)
    }

    @Test("Second escalation within the haptic cooldown stays silent")
    func hapticCooldownAcrossMessages() {
        let arbiter = CaptureGuidanceArbiter()

        // First: tracking loss with a haptic.
        var sawHaptic = false
        var t: TimeInterval = 0
        while t <= 1 {
            let guidance = arbiter.evaluate(
                CaptureGuidanceInput(timestamp: t, tracking: .relocalizing)
            )
            if guidance?.wantsHaptic == true { sawHaptic = true }
            t += 0.05
        }
        #expect(sawHaptic)

        // Recover, then trigger a motion warning 5 s later — inside the 20 s
        // haptic budget, so it must be silent.
        _ = run(arbiter, from: 1.05, to: 4) {
            CaptureGuidanceInput(timestamp: $0)
        }
        var motionHaptic = false
        t = 4.05
        while t <= 6 {
            let guidance = arbiter.evaluate(
                CaptureGuidanceInput(timestamp: t, linearSpeedMPS: 1.2)
            )
            if guidance?.wantsHaptic == true { motionHaptic = true }
            t += 0.05
        }
        #expect(arbiter.currentGuidance?.id == "motion-warning")
        #expect(!motionHaptic)
    }

    @Test("Only fast movement warns; a brisk-but-fine pace shows nothing")
    func fastCalloutOnly() {
        let arbiter = CaptureGuidanceArbiter()

        // 0.6 m/s used to trigger the removed "Steady…" coaching. With the
        // single fast callout it must stay silent.
        let moderate = run(arbiter, from: 0, to: 1.5) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 0.6)
        }
        #expect(moderate == nil)

        // Past the 1.0 m/s warning entry: the one pacing message.
        let warning = run(arbiter, from: 1.55, to: 2.5) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 1.2)
        }
        #expect(warning?.id == "motion-warning")
        #expect(warning?.message == "Going too fast")
    }

    @Test("Hysteresis: engaged warning does not clear until below exit threshold")
    func motionHysteresis() {
        let arbiter = CaptureGuidanceArbiter()
        _ = run(arbiter, from: 0, to: 1.0) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 1.2)
        }
        #expect(arbiter.currentGuidance?.id == "motion-warning")

        // 0.85 m/s is below the 1.0 entry but above the 0.75 exit: stays engaged.
        let held = run(arbiter, from: 1.05, to: 4.0) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 0.85)
        }
        #expect(held?.id == "motion-warning")

        // Dropping below exit clears it (dwell already satisfied).
        _ = run(arbiter, from: 4.05, to: 6.0) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 0.2)
        }
        #expect(arbiter.currentGuidance?.id != "motion-warning")
    }

    @Test("Recovery from a pacing warning clears the pill with no follow-up")
    func recoveryShowsNothing() {
        let arbiter = CaptureGuidanceArbiter()
        _ = run(arbiter, from: 0, to: 2.0) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 1.2)
        }
        #expect(arbiter.currentGuidance?.id == "motion-warning")

        // Past the warning's minimum dwell, recovery goes straight to calm —
        // no "Good pace" confirmation.
        let recovered = arbiter.evaluate(
            CaptureGuidanceInput(timestamp: 2.5, linearSpeedMPS: 0.1)
        )
        #expect(recovered == nil)
        #expect(arbiter.currentGuidance == nil)
    }

    @Test("Minimum dwell holds a message even when the condition clears fast")
    func minimumDwell() {
        let arbiter = CaptureGuidanceArbiter()
        _ = run(arbiter, from: 0, to: 0.8) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 1.2)
        }
        #expect(arbiter.currentGuidance?.id == "motion-warning")

        // Condition clears immediately; message must persist through dwell.
        let during = arbiter.evaluate(
            CaptureGuidanceInput(timestamp: 1.0, linearSpeedMPS: 0.1)
        )
        #expect(during?.id == "motion-warning")

        let afterDwell = arbiter.evaluate(
            CaptureGuidanceInput(timestamp: 2.5, linearSpeedMPS: 0.1)
        )
        #expect(afterDwell?.id != "motion-warning")
    }

    @Test("Critical tracking preempts an active coaching message immediately")
    func criticalPreemptsCoaching() {
        let arbiter = CaptureGuidanceArbiter()
        // Low light is the remaining coaching-severity message.
        _ = run(arbiter, from: 0, to: 1.0) {
            CaptureGuidanceInput(timestamp: $0, meanLuma: 0.05)
        }
        #expect(arbiter.currentGuidance?.id == "low-light")

        // Tracking loss must take over after only the critical debounce, well
        // inside the coaching message's dwell.
        let preempted = run(arbiter, from: 1.05, to: 1.4) {
            CaptureGuidanceInput(timestamp: $0, tracking: .relocalizing)
        }
        #expect(preempted?.id == "tracking-recovering")
    }

    @Test("Dismissed warning cannot re-enter during its cooldown")
    func reentryCooldown() {
        let arbiter = CaptureGuidanceArbiter()
        _ = run(arbiter, from: 0, to: 2.0) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 1.2)
        }
        _ = run(arbiter, from: 2.05, to: 3.0) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 0.1)
        }
        #expect(arbiter.currentGuidance?.id != "motion-warning")
        // The warning activated at ~0.7 and dwell releases it at ~2.2.
        let dismissedAt: TimeInterval = 2.2

        // Immediately speeding again: blocked by the 5 s re-entry cooldown.
        let blocked = run(arbiter, from: 3.05, to: dismissedAt + 4.9) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 1.2)
        }
        #expect(blocked?.id != "motion-warning")

        // After the cooldown it may coach again.
        let allowed = run(arbiter, from: dismissedAt + 5.0, to: dismissedAt + 7.0) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 1.2)
        }
        #expect(allowed?.id == "motion-warning")
    }

    @Test("Hold mismatch outranks everything and keeps urgent styling")
    func holdMismatchTop() {
        let arbiter = CaptureGuidanceArbiter()
        let guidance = run(arbiter, from: 0, to: 0.5) {
            CaptureGuidanceInput(
                timestamp: $0,
                holdMismatchMessage: "Turn back to portrait. Frames in the other orientation aren't saved.",
                tracking: .relocalizing,
                linearSpeedMPS: 2.0
            )
        }
        #expect(guidance?.id == "hold-mismatch")
        #expect(guidance?.isUrgentStyle == true)
        #expect(guidance?.wantsHaptic == false)
    }

    @Test("Insufficient features escalates copy from texture to light in place")
    func featureCopyEscalation() {
        let arbiter = CaptureGuidanceArbiter()
        let early = run(arbiter, from: 0, to: 1.0) {
            CaptureGuidanceInput(
                timestamp: $0,
                tracking: .insufficientFeatures,
                trackingLimitedSeconds: $0
            )
        }
        #expect(early?.id == "tracking-features")
        #expect(early?.message == "Aim at a textured surface")

        let late = run(arbiter, from: 1.05, to: 12.0) {
            CaptureGuidanceInput(
                timestamp: $0,
                tracking: .insufficientFeatures,
                trackingLimitedSeconds: $0
            )
        }
        #expect(late?.id == "tracking-features")
        #expect(late?.message == "Turn on more light")
    }

    @Test("Flow messages show immediately and never buzz")
    func flowMessages() {
        let arbiter = CaptureGuidanceArbiter()
        let guidance = arbiter.evaluate(
            CaptureGuidanceInput(
                timestamp: 0,
                tracking: .initializing,
                flowMessage: .initializingTracking,
                isSampling: false
            )
        )
        #expect(guidance?.id == "flow-initializing")
        #expect(guidance?.message == "Starting tracking…")
        #expect(guidance?.wantsHaptic == false)

        arbiter.reset()
        let reacquiring = arbiter.evaluate(
            CaptureGuidanceInput(
                timestamp: 0,
                flowMessage: .reacquiringPosition,
                isSampling: false
            )
        )
        #expect(reacquiring?.message == "Scan preserved. Resuming capture…")

        arbiter.reset()
        let nearlyFull = run(arbiter, from: 0, to: 1) {
            CaptureGuidanceInput(
                timestamp: $0,
                flowMessage: .frameLimitApproaching
            )
        }
        #expect(nearlyFull?.severity == .warning)
        #expect(nearlyFull?.message == "You’re nearing the scan limit. Finish and save soon.")
    }

    @Test("Motion coaching is suppressed while not sampling")
    func noMotionCoachingWhilePaused() {
        let arbiter = CaptureGuidanceArbiter()
        let guidance = run(arbiter, from: 0, to: 2.0) {
            CaptureGuidanceInput(
                timestamp: $0,
                isSampling: false,
                linearSpeedMPS: 2.0
            )
        }
        #expect(guidance == nil)
    }

    @Test("Low light coaches with hysteresis")
    func lowLightCoaching() {
        let arbiter = CaptureGuidanceArbiter()
        let dark = run(arbiter, from: 0, to: 1.0) {
            CaptureGuidanceInput(timestamp: $0, meanLuma: 0.05)
        }
        #expect(dark?.id == "low-light")
        #expect(dark?.message == "Turn on more light")

        // 0.12 sits between entry (0.10) and exit (0.14): stays engaged.
        let dim = run(arbiter, from: 1.05, to: 3.0) {
            CaptureGuidanceInput(timestamp: $0, meanLuma: 0.12)
        }
        #expect(dim?.id == "low-light")

        _ = run(arbiter, from: 3.05, to: 5.0) {
            CaptureGuidanceInput(timestamp: $0, meanLuma: 0.4)
        }
        #expect(arbiter.currentGuidance?.id != "low-light")
    }

    @Test("Predicted blur alone can trigger the pacing warning")
    func blurTriggersWarning() {
        let arbiter = CaptureGuidanceArbiter()
        // Above the 24 px entry (dim-room smear); moderate blur from normal
        // indoor motion must no longer preempt the speed thresholds.
        let guidance = run(arbiter, from: 0, to: 1.0) {
            CaptureGuidanceInput(timestamp: $0, predictedBlurPx: 30)
        }
        #expect(guidance?.id == "motion-warning")

        let calmArbiter = CaptureGuidanceArbiter()
        let calm = run(calmArbiter, from: 0, to: 1.5) {
            CaptureGuidanceInput(timestamp: $0, predictedBlurPx: 10)
        }
        #expect(calm == nil)
    }

    // MARK: - Add-on advisories

    private func advisory(
        id: String = "tip",
        displayLimit: TimeInterval? = nil,
        cooldown: TimeInterval? = nil,
        oncePerSession: Bool = false
    ) -> CaptureGuidanceAdvisory {
        CaptureGuidanceAdvisory(
            id: id,
            message: "Scan the ceiling",
            displayLimitSeconds: displayLimit,
            reentryCooldownSeconds: cooldown,
            isOncePerSession: oncePerSession
        )
    }

    @Test("Advisories coach after the coaching debounce with a prefixed id")
    func advisoryShowsAsCoaching() {
        let arbiter = CaptureGuidanceArbiter()
        let guidance = run(arbiter, from: 0, to: 1.5) {
            CaptureGuidanceInput(timestamp: $0, advisories: [advisory()])
        }
        #expect(guidance?.id == CaptureGuidanceArbiter.guidanceID(forAdvisory: "tip"))
        #expect(guidance?.severity == .coaching)
        #expect(guidance?.wantsHaptic == false)
    }

    @Test("Warnings outrank advisories")
    func warningsBeatAdvisories() {
        let arbiter = CaptureGuidanceArbiter()
        let guidance = run(arbiter, from: 0, to: 2) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 1.5, advisories: [advisory()])
        }
        #expect(guidance?.id == "motion-warning")
    }

    @Test("Advisories are quiet while not sampling")
    func advisoriesNeedSampling() {
        let arbiter = CaptureGuidanceArbiter()
        let guidance = run(arbiter, from: 0, to: 2) {
            CaptureGuidanceInput(timestamp: $0, isSampling: false, advisories: [advisory()])
        }
        #expect(guidance == nil)
    }

    @Test("A display limit expires a persisting advisory, then its cooldown rests it")
    func advisoryDisplayLimitAndCooldown() {
        let arbiter = CaptureGuidanceArbiter()
        let cue = advisory(displayLimit: 4, cooldown: 30)
        let shown = run(arbiter, from: 0, to: 2) {
            CaptureGuidanceInput(timestamp: $0, advisories: [cue])
        }
        #expect(shown != nil)
        let expired = run(arbiter, from: 2.05, to: 6) {
            CaptureGuidanceInput(timestamp: $0, advisories: [cue])
        }
        #expect(expired == nil)
        let resting = run(arbiter, from: 6.05, to: 30) {
            CaptureGuidanceInput(timestamp: $0, advisories: [cue])
        }
        #expect(resting == nil)
        let back = run(arbiter, from: 30.05, to: 36) {
            CaptureGuidanceInput(timestamp: $0, advisories: [cue])
        }
        #expect(back != nil)
    }

    @Test("Once-per-session advisories never return until reset")
    func advisoryOncePerSession() {
        let arbiter = CaptureGuidanceArbiter()
        let cue = advisory(displayLimit: 4, cooldown: 0, oncePerSession: true)
        _ = run(arbiter, from: 0, to: 6) { CaptureGuidanceInput(timestamp: $0, advisories: [cue]) }
        let later = run(arbiter, from: 6.05, to: 60) {
            CaptureGuidanceInput(timestamp: $0, advisories: [cue])
        }
        #expect(later == nil)
        arbiter.reset()
        let afterReset = run(arbiter, from: 0, to: 2) {
            CaptureGuidanceInput(timestamp: $0, advisories: [cue])
        }
        #expect(afterReset != nil)
    }

    @Test("clearAdvisories drops an active advisory but keeps a warning")
    func clearAdvisoriesKeepsWarnings() {
        let arbiter = CaptureGuidanceArbiter()
        _ = run(arbiter, from: 0, to: 2) { CaptureGuidanceInput(timestamp: $0, advisories: [advisory()]) }
        arbiter.clearAdvisories()
        #expect(arbiter.currentGuidance == nil)

        _ = run(arbiter, from: 2.05, to: 4) {
            CaptureGuidanceInput(timestamp: $0, linearSpeedMPS: 1.5)
        }
        arbiter.clearAdvisories()
        #expect(arbiter.currentGuidance?.id == "motion-warning")
    }
}
