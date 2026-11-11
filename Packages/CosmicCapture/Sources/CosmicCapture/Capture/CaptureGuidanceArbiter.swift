import Foundation

/// Tracking condition expressed without ARKit types.
enum CaptureTrackingSignal: Equatable, Sendable {
    case normal
    case initializing
    case relocalizing
    case excessiveMotion
    case insufficientFeatures
    case notAvailable
}

/// Session flow states that need a persistent informational message.
enum CaptureFlowMessage: Equatable, Sendable {
    case initializingTracking
    case reacquiringPosition
    case frameLimitApproaching
    case frameLimitReached
}

enum CaptureGuidanceSeverity: Int, Comparable, Sendable {
    case info = 0
    case coaching = 1
    case warning = 2
    case critical = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The single message the live HUD may show. Nil from the arbiter means the
/// instruction pill is hidden — a calm camera is the normal state.
struct CaptureGuidance: Equatable, Sendable {
    let id: String
    let severity: CaptureGuidanceSeverity
    let message: String
    /// Destructive pill styling (hold-mismatch continuity warnings).
    let isUrgentStyle: Bool
    /// True only on the evaluation where this guidance activated or escalated
    /// and the haptic budget allows one pulse.
    let wantsHaptic: Bool
}

/// A coaching cue contributed by an optional guidance add-on (see
/// `docs/guidance-setups.md`). Core capture never produces these; the arbiter
/// ranks them below every warning, after the motion and light coaching.
struct CaptureGuidanceAdvisory: Equatable, Sendable {
    /// Stable id across evaluations; dwell, cooldown and hysteresis key on it.
    let id: String
    let message: String
    /// Bounded display time for cues whose condition persists until the user
    /// acts. Nil means the cue lives exactly as long as it is supplied.
    var displayLimitSeconds: TimeInterval?
    /// Re-entry cooldown overriding the shared policy.
    var reentryCooldownSeconds: TimeInterval?
    /// Shown at most once per capture session.
    var isOncePerSession = false
}

/// Everything the arbiter may consider for one evaluation. ARKit-free so
/// timelines are unit-testable.
struct CaptureGuidanceInput {
    let timestamp: TimeInterval
    let holdMismatchMessage: String?
    let tracking: CaptureTrackingSignal
    /// Seconds tracking has been continuously degraded, for escalating
    /// insufficient-features copy from texture to lighting.
    let trackingLimitedSeconds: TimeInterval
    let flowMessage: CaptureFlowMessage?
    /// Motion/lighting coaching only applies while frames are being accepted.
    let isSampling: Bool
    let linearSpeedMPS: Float?
    let angularSpeedDPS: Float?
    let predictedBlurPx: Float?
    let meanLuma: Float?
    let advisories: [CaptureGuidanceAdvisory]

    init(
        timestamp: TimeInterval,
        holdMismatchMessage: String? = nil,
        tracking: CaptureTrackingSignal = .normal,
        trackingLimitedSeconds: TimeInterval = 0,
        flowMessage: CaptureFlowMessage? = nil,
        isSampling: Bool = true,
        linearSpeedMPS: Float? = nil,
        angularSpeedDPS: Float? = nil,
        predictedBlurPx: Float? = nil,
        meanLuma: Float? = nil,
        advisories: [CaptureGuidanceAdvisory] = []
    ) {
        self.timestamp = timestamp
        self.holdMismatchMessage = holdMismatchMessage
        self.tracking = tracking
        self.trackingLimitedSeconds = trackingLimitedSeconds
        self.flowMessage = flowMessage
        self.isSampling = isSampling
        self.linearSpeedMPS = linearSpeedMPS
        self.angularSpeedDPS = angularSpeedDPS
        self.predictedBlurPx = predictedBlurPx
        self.meanLuma = meanLuma
        self.advisories = advisories
    }
}

/// Pure priority/hysteresis state machine that turns raw capture conditions
/// into at most one coaching message. Owns debounce, minimum dwell, recovery
/// hysteresis, re-entry cooldown, and the haptic budget so views stay
/// presentation-only. Time comes from the input; no wall clock inside.
final class CaptureGuidanceArbiter {
    struct Policy: Sendable {
        var criticalEntrySeconds: TimeInterval = 0.25
        var warningEntrySeconds: TimeInterval = 0.7
        var coachingEntrySeconds: TimeInterval = 0.8
        var minimumDwellSeconds: TimeInterval = 1.5
        var reentryCooldownSeconds: TimeInterval = 5
        var hapticCooldownSeconds: TimeInterval = 20
        /// Insufficient features escalates from texture to lighting copy.
        var lowLightCopyAfterSeconds: TimeInterval = 10

        /// 0.8 m/s warned too early in practice, so the entry sits at 1.0 m/s.
        var linearWarnEntryMPS: Float = 1.0
        var linearWarnExitMPS: Float = 0.75
        var angularWarnEntryDPS: Float = 100
        var angularWarnExitDPS: Float = 70
        /// Predicted blur must not preempt the speed thresholds in normal
        /// light. The old 2.5 px entry fired at ~0.2 m/s lateral (2 m depth)
        /// or ~6°/s rotation at a 1/60 s indoor exposure — far below the
        /// advertised speed thresholds, which made the pacing warning feel wildly
        /// aggressive. 24 px only engages earlier than the speed thresholds
        /// when exposure is long (dim rooms), where frames genuinely smear.
        /// The hard frame-reject gate is 64 px (`CaptureFrameQualityGate`).
        var blurWarnEntryPx: Float = 24
        var blurWarnExitPx: Float = 16

        var lowLumaEntry: Float = 0.10
        var lowLumaExit: Float = 0.14

        init() {}
    }

    private struct Candidate: Equatable {
        let id: String
        let severity: CaptureGuidanceSeverity
        let message: String
        var isUrgentStyle = false
        /// Hold mismatch fires its own haptic at the source; flow and coaching
        /// never buzz.
        var isHapticEligible = false
        var isAdvisory = false
        var displayLimitSeconds: TimeInterval?
        var reentryCooldownSeconds: TimeInterval?
        var isOncePerSession = false
    }

    private struct Active {
        var candidate: Candidate
        let activatedAt: TimeInterval
    }

    private let policy: Policy

    private var pendingID: String?
    private var pendingSince: TimeInterval = 0
    private var active: Active?
    private var lastDismissedAt: [String: TimeInterval] = [:]
    private var lastHapticAt: TimeInterval?
    private var shownOnceIDs: Set<String> = []

    private(set) var currentGuidance: CaptureGuidance?

    init(policy: Policy = Policy()) {
        self.policy = policy
    }

    func reset() {
        pendingID = nil
        pendingSince = 0
        active = nil
        lastDismissedAt = [:]
        lastHapticAt = nil
        shownOnceIDs = []
        currentGuidance = nil
    }

    /// Drops any active or pending advisory immediately, ignoring minimum
    /// dwell, for when the add-on's context changes (a new scan pass).
    /// Warning state and the haptic budget are kept.
    func clearAdvisories() {
        if active?.candidate.isAdvisory == true {
            active = nil
            currentGuidance = nil
        }
        if let pendingID, pendingID.hasPrefix(Self.advisoryIDPrefix) {
            self.pendingID = nil
            pendingSince = 0
        }
    }

    @discardableResult
    func evaluate(_ input: CaptureGuidanceInput) -> CaptureGuidance? {
        let now = input.timestamp
        let satisfied = satisfiedCandidates(input)
        let top = satisfied.first

        if top?.id != pendingID {
            pendingID = top?.id
            pendingSince = now
        }

        let eligible: Candidate? = {
            guard let top else { return nil }
            guard now - pendingSince >= entryDelay(top.severity) else { return nil }
            guard !isInCooldown(top, at: now) else { return nil }
            return top
        }()

        if var current = active {
            // Advisories self-expire: their condition persists until the user
            // acts, so display time is bounded here rather than by the
            // condition clearing.
            let displayExpired = current.candidate.displayLimitSeconds.map {
                now - current.activatedAt >= $0
            } ?? false
            let stillHolds = !displayExpired
                && satisfied.contains { $0.id == current.candidate.id }

            if stillHolds {
                // Refresh copy in place (e.g. texture → light escalation of the
                // same insufficient-features condition).
                if let refreshed = satisfied.first(where: { $0.id == current.candidate.id }) {
                    current.candidate = refreshed
                    active = current
                }
                if let eligible, eligible.severity > current.candidate.severity {
                    dismiss(current, at: now)
                    return activate(eligible, at: now)
                }
                return publish(current.candidate, wantsHaptic: false)
            }

            // Condition cleared: honor minimum dwell unless something more
            // severe is ready to take over.
            let dwellSatisfied = now - current.activatedAt >= policy.minimumDwellSeconds
            if let eligible, eligible.severity > current.candidate.severity {
                dismiss(current, at: now)
                return activate(eligible, at: now)
            }
            guard dwellSatisfied else {
                return publish(current.candidate, wantsHaptic: false)
            }
            dismiss(current, at: now)
            // Re-check the cooldown: `eligible` was computed before this
            // dismissal, so a self-expiring advisory would otherwise
            // re-activate in the same evaluation instead of resting.
            if let eligible, !isInCooldown(eligible, at: now) {
                return activate(eligible, at: now)
            }
            currentGuidance = nil
            return nil
        }

        if let eligible {
            return activate(eligible, at: now)
        }
        currentGuidance = nil
        return nil
    }

    // MARK: - Candidate ladder

    /// All currently satisfied candidates, ordered by priority: hold →
    /// tracking → motion → lighting. Hysteresis consults the active id so an
    /// engaged message needs to drop below its exit threshold to clear.
    private func satisfiedCandidates(_ input: CaptureGuidanceInput) -> [Candidate] {
        var result: [Candidate] = []

        if let holdMessage = input.holdMismatchMessage {
            result.append(
                Candidate(
                    id: "hold-mismatch",
                    severity: .critical,
                    message: holdMessage,
                    isUrgentStyle: true
                )
            )
        }

        switch input.tracking {
        case .notAvailable, .relocalizing:
            result.append(
                Candidate(
                    id: "tracking-recovering",
                    severity: .critical,
                    message: "Hold still. Recovering tracking",
                    isHapticEligible: true
                )
            )
        case .excessiveMotion:
            result.append(
                Candidate(
                    id: "tracking-motion",
                    severity: .critical,
                    message: "Going too fast",
                    isHapticEligible: true
                )
            )
        case .insufficientFeatures:
            result.append(
                Candidate(
                    id: "tracking-features",
                    severity: .warning,
                    message: input.trackingLimitedSeconds > policy.lowLightCopyAfterSeconds
                        ? "Turn on more light"
                        : "Aim at a textured surface",
                    isHapticEligible: true
                )
            )
        case .initializing:
            result.append(
                Candidate(
                    id: "flow-initializing",
                    severity: .info,
                    message: "Starting tracking…"
                )
            )
        case .normal:
            break
        }

        if let flow = input.flowMessage {
            let candidate: Candidate
            switch flow {
            case .initializingTracking:
                candidate = Candidate(
                    id: "flow-initializing",
                    severity: .info,
                    message: "Starting tracking…"
                )
            case .reacquiringPosition:
                candidate = Candidate(
                    id: "flow-reacquiring",
                    severity: .info,
                    message: "Scan preserved. Resuming capture…"
                )
            case .frameLimitApproaching:
                candidate = Candidate(
                    id: "flow-frame-limit-approaching",
                    severity: .warning,
                    message: "You’re nearing the scan limit. Finish and save soon.",
                    isHapticEligible: true
                )
            case .frameLimitReached:
                candidate = Candidate(
                    id: "flow-frame-limit",
                    severity: .info,
                    message: "Scan limit reached"
                )
            }
            if !result.contains(where: { $0.id == candidate.id }) {
                result.append(candidate)
            }
        }

        if input.isSampling, input.tracking == .normal {
            // Fast movement is the only pacing callout: one unambiguous
            // "Going too fast", no graded coaching.
            if motionExceedsWarning(input) {
                result.append(
                    Candidate(
                        id: "motion-warning",
                        severity: .warning,
                        message: "Going too fast",
                        isHapticEligible: true
                    )
                )
            }
            if let luma = input.meanLuma {
                let threshold = active?.candidate.id == "low-light"
                    ? policy.lowLumaExit
                    : policy.lowLumaEntry
                if luma < threshold {
                    result.append(
                        Candidate(
                            id: "low-light",
                            severity: .coaching,
                            message: "Turn on more light"
                        )
                    )
                }
            }
        }

        if input.isSampling, input.tracking == .normal {
            for advisory in input.advisories
            where !(advisory.isOncePerSession && shownOnceIDs.contains(advisory.id)) {
                result.append(
                    Candidate(
                        id: Self.advisoryIDPrefix + advisory.id,
                        severity: .coaching,
                        message: advisory.message,
                        isAdvisory: true,
                        displayLimitSeconds: advisory.displayLimitSeconds,
                        reentryCooldownSeconds: advisory.reentryCooldownSeconds,
                        isOncePerSession: advisory.isOncePerSession
                    )
                )
            }
        }

        // Stable priority order: severity first, then the ladder order the
        // candidates were appended in (motion before light before advisories).
        return result.enumerated()
            .sorted { first, second in
                if first.element.severity != second.element.severity {
                    return first.element.severity > second.element.severity
                }
                return first.offset < second.offset
            }
            .map(\.element)
    }

    private func motionExceedsWarning(_ input: CaptureGuidanceInput) -> Bool {
        let engaged = active?.candidate.id == "motion-warning"
        let linear = engaged ? policy.linearWarnExitMPS : policy.linearWarnEntryMPS
        let angular = engaged ? policy.angularWarnExitDPS : policy.angularWarnEntryDPS
        let blur = engaged ? policy.blurWarnExitPx : policy.blurWarnEntryPx
        if let speed = input.linearSpeedMPS, speed > linear { return true }
        if let speed = input.angularSpeedDPS, speed > angular { return true }
        if let predicted = input.predictedBlurPx, predicted > blur { return true }
        return false
    }

    // MARK: - State transitions

    private func entryDelay(_ severity: CaptureGuidanceSeverity) -> TimeInterval {
        switch severity {
        case .info: return 0
        case .coaching: return policy.coachingEntrySeconds
        case .warning: return policy.warningEntrySeconds
        case .critical: return policy.criticalEntrySeconds
        }
    }

    private func isInCooldown(_ candidate: Candidate, at now: TimeInterval) -> Bool {
        guard candidate.severity == .warning || candidate.severity == .coaching else {
            return false
        }
        guard let dismissedAt = lastDismissedAt[candidate.id] else { return false }
        let cooldown = candidate.reentryCooldownSeconds ?? policy.reentryCooldownSeconds
        return now - dismissedAt < cooldown
    }

    private func activate(
        _ candidate: Candidate,
        at now: TimeInterval
    ) -> CaptureGuidance? {
        active = Active(candidate: candidate, activatedAt: now)
        if candidate.isOncePerSession {
            shownOnceIDs.insert(candidate.id.dropFirst(Self.advisoryIDPrefix.count).description)
        }

        var wantsHaptic = false
        if candidate.isHapticEligible, candidate.severity >= .warning {
            let budgetAvailable = lastHapticAt.map {
                now - $0 >= policy.hapticCooldownSeconds
            } ?? true
            if budgetAvailable {
                wantsHaptic = true
                lastHapticAt = now
            }
        }
        return publish(candidate, wantsHaptic: wantsHaptic)
    }

    private func dismiss(_ dismissed: Active, at now: TimeInterval) {
        active = nil
        lastDismissedAt[dismissed.candidate.id] = now
    }

    /// Published guidance ids for advisories are `advisory.<id>`.
    static let advisoryIDPrefix = "advisory."

    static func guidanceID(forAdvisory id: String) -> String {
        advisoryIDPrefix + id
    }

    private func publish(
        _ candidate: Candidate,
        wantsHaptic: Bool
    ) -> CaptureGuidance {
        let guidance = CaptureGuidance(
            id: candidate.id,
            severity: candidate.severity,
            message: candidate.message,
            isUrgentStyle: candidate.isUrgentStyle,
            wantsHaptic: wantsHaptic
        )
        currentGuidance = guidance
        return guidance
    }
}
