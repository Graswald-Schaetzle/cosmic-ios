import Foundation
import simd
import Testing
@testable import CosmicCapture

private typealias Gate = CaptureTrackingSettleGate

private func pose(
    x: Float = 0,
    y: Float = 0,
    z: Float = 0,
    yawDeg: Float = 0
) -> simd_float4x4 {
    var transform = simd_float4x4(
        simd_quatf(angle: yawDeg * .pi / 180, axis: SIMD3(0, 1, 0))
    )
    transform.columns.3 = SIMD4(x, y, z, 1)
    return transform
}

private func frame(
    _ timestamp: TimeInterval,
    normal: Bool = true,
    pose worldFromCamera: simd_float4x4 = pose()
) -> Gate.Frame {
    Gate.Frame(
        timestamp: timestamp,
        isTrackingNormal: normal,
        worldFromCamera: worldFromCamera
    )
}

/// Feeds stationary normal frames at `fps` over `[start, end]`, returning the
/// last verdict and the timestamp at which the gate first settled.
@discardableResult
private func feed(
    _ gate: inout Gate,
    from start: TimeInterval,
    to end: TimeInterval,
    fps: Double = 60,
    pose worldFromCamera: simd_float4x4 = pose()
) -> (verdict: Gate.Verdict?, settledAt: TimeInterval?) {
    var verdict: Gate.Verdict?
    var settledAt: TimeInterval?
    var index = 0
    while true {
        let timestamp = start + Double(index) / fps
        guard timestamp <= end + 1e-9 else { break }
        let current = gate.observe(frame(timestamp, pose: worldFromCamera))
        if current.isSettled, settledAt == nil { settledAt = timestamp }
        verdict = current
        index += 1
    }
    return (verdict, settledAt)
}

private func settledGate(at end: TimeInterval = 1) -> Gate {
    var gate = Gate()
    gate.restart(.start, minimumTimestamp: 0, at: 0)
    feed(&gate, from: 0.01, to: end)
    return gate
}

@Suite("Capture tracking settle gate")
struct CaptureTrackingSettleGateTests {
    @Test("Settles only after settleSeconds of continuous normal tracking")
    func settlesAfterWindow() throws {
        var gate = Gate()
        let started = gate.restart(.start, minimumTimestamp: 10, at: 10)
        #expect(started == .settleStarted(trigger: .start, timestamp: 10))

        let stale = gate.observe(frame(10))
        #expect(!stale.isSettled)

        let (_, settledAt) = feed(&gate, from: 10.1, to: 11)
        let settled = try #require(settledAt)
        #expect(settled >= 10.1 + Gate.Policy.standard.settleSeconds - 1e-9)
        #expect(settled < 10.1 + Gate.Policy.standard.settleSeconds + 1.0 / 60 + 1e-9)
    }

    @Test("Reports settle completion once, with elapsed time since settling began")
    func reportsCompletion() {
        var gate = Gate()
        gate.restart(.resume, minimumTimestamp: 5, at: 5)
        var completions: [Gate.Event] = []
        for index in 1...60 {
            let verdict = gate.observe(frame(5 + Double(index) / 60))
            completions += verdict.events.filter {
                if case .settleCompleted = $0 { return true }
                return false
            }
        }
        #expect(completions.count == 1)
        guard case .settleCompleted(let elapsed, _) = completions.first else {
            Issue.record("missing settle_completed")
            return
        }
        // The window opens on the first frame, 1/60 s after the restart.
        #expect(elapsed >= 0.5 + 1.0 / 60 - 1e-6)
        #expect(elapsed <= 0.5 + 2.0 / 60 + 1e-6)
    }

    @Test("Elapsed time never undercuts the window when a frame predates the restart call")
    func elapsedCoversEarlyFrames() {
        var gate = Gate()
        gate.restart(.resume, minimumTimestamp: 10, at: 10.05)
        var elapsed: TimeInterval?
        for index in 1...40 {
            let verdict = gate.observe(frame(10 + Double(index) / 60))
            for case .settleCompleted(let value, _) in verdict.events {
                elapsed = value
            }
        }
        #expect((elapsed ?? 0) >= 0.5 - 1e-9)
    }

    enum RestartCase: String, CaseIterable, CustomTestStringConvertible {
        case start, resume, interruptionEnd, tracking, poseDiscontinuity, rotationDiscontinuity,
             frameGap

        var testDescription: String { rawValue }

        var expectedTrigger: CaptureTrackingSettleGate.Trigger {
            switch self {
            case .start: .start
            case .resume: .resume
            case .interruptionEnd: .interruptionEnd
            case .tracking: .tracking
            case .poseDiscontinuity, .rotationDiscontinuity: .poseDiscontinuity
            case .frameGap: .frameGap
            }
        }
    }

    @Test("Each trigger restarts the settle window", arguments: RestartCase.allCases)
    func restartsOnTrigger(_ restartCase: RestartCase) {
        var gate = settledGate(at: 1)
        #expect(gate.isSettled)

        let restartTime: TimeInterval
        var events: [Gate.Event] = []
        switch restartCase {
        case .start, .resume, .interruptionEnd:
            restartTime = 1.01
            events.append(
                gate.restart(restartCase.expectedTrigger, minimumTimestamp: 1, at: 1.01)
            )
            events += gate.observe(frame(1.02)).events
        case .tracking:
            restartTime = 1.02
            events += gate.observe(frame(1.02, normal: false)).events
        case .poseDiscontinuity:
            restartTime = 1.02
            events += gate.observe(frame(1.02, pose: pose(x: 1))).events
        case .rotationDiscontinuity:
            restartTime = 1.02
            events += gate.observe(frame(1.02, pose: pose(yawDeg: 30))).events
        case .frameGap:
            restartTime = 1.7
            events += gate.observe(frame(1.7)).events
        }

        #expect(!gate.isSettled)
        #expect(events.contains(.settleStarted(trigger: restartCase.expectedTrigger, timestamp: restartTime)))

        let resumePose: simd_float4x4 = switch restartCase {
        case .poseDiscontinuity: pose(x: 1)
        case .rotationDiscontinuity: pose(yawDeg: 30)
        default: pose()
        }
        let (_, settledAt) = feed(
            &gate,
            from: restartTime + 1.0 / 60,
            to: restartTime + 1,
            pose: resumePose
        )
        #expect(settledAt.map { $0 >= restartTime + 0.5 - 1e-9 } == true)
    }

    @Test("Pose discontinuity reports the implied jump and actual dt")
    func reportsDiscontinuity() {
        var gate = settledGate(at: 1)
        let verdict = gate.observe(frame(1.1, pose: pose(x: 2)))
        let discontinuity = verdict.events.first {
            if case .poseDiscontinuity = $0 { return true }
            return false
        }
        guard case .poseDiscontinuity(let translationM, _, let dtSeconds, _) = discontinuity else {
            Issue.record("missing pose_discontinuity")
            return
        }
        #expect(abs(translationM - 2) < 1e-4)
        #expect(abs(dtSeconds - (1.1 - (0.01 + 59.0 / 60))) < 1e-6)
    }

    @Test("Settling is measured in time, not frames", arguments: [60.0, 30.0, 5.0])
    func settlesByTime(fps: Double) {
        var gate = Gate()
        gate.restart(.start, minimumTimestamp: 0, at: 0)
        let (_, settledAt) = feed(&gate, from: 1, to: 3, fps: fps)
        let settled = settledAt ?? .infinity
        #expect(settled >= 1.5 - 1e-9)
        #expect(settled <= 1.5 + 1 / fps + 1e-9)
    }

    @Test("Speed limits use dt, so the same motion passes at any frame rate", arguments: [60.0, 30.0, 5.0])
    func discontinuityUsesDt(fps: Double) {
        let dt = 1 / fps
        var walking = settledGate(at: 1)
        var fastTurn = settledGate(at: 1)
        var teleport = settledGate(at: 1)
        for index in 1...10 {
            let t = 1 + Double(index) * dt
            _ = walking.observe(frame(t, pose: pose(x: Float(Double(index) * dt * 3))))
            _ = fastTurn.observe(frame(t, pose: pose(yawDeg: Float(Double(index) * dt * 400))))
            _ = teleport.observe(frame(t, pose: pose(x: Float(Double(index) * dt * 8))))
        }
        #expect(walking.isSettled)
        #expect(fastTurn.isSettled)
        #expect(!teleport.isSettled)
    }

    @Test("A legitimate 18 m move across a pause is not a discontinuity")
    func movementAcrossPauseIsLegitimate() {
        var gate = settledGate(at: 1)
        gate.restart(.resume, minimumTimestamp: 1, at: 171)
        var events: [Gate.Event] = []
        var settledAt: TimeInterval?
        for index in 1...60 {
            let t = 171 + Double(index) / 60
            let verdict = gate.observe(frame(t, pose: pose(x: 18, yawDeg: 40)))
            events += verdict.events
            if verdict.isSettled, settledAt == nil { settledAt = t }
        }
        #expect(!events.contains { if case .poseDiscontinuity = $0 { true } else { false } })
        #expect(settledAt != nil)
    }

    @Test("Frames queued before a restart are ignored and keep no pose history")
    func ignoresStaleFrames() {
        var gate = settledGate(at: 1)
        gate.restart(.resume, minimumTimestamp: 1, at: 1.5)
        let stale = gate.observe(frame(0.9, pose: pose(x: 50)))
        #expect(stale.events.isEmpty)
        #expect(!stale.isSettled)
        let first = gate.observe(frame(1.6))
        #expect(!first.events.contains { if case .poseDiscontinuity = $0 { true } else { false } })
    }

    @Test("Repeated limited frames restart once, not per frame")
    func trackingLossLogsOnce() {
        var gate = settledGate(at: 1)
        var starts = 0
        for index in 1...30 {
            let verdict = gate.observe(frame(1 + Double(index) / 60, normal: false))
            starts += verdict.events.filter {
                if case .settleStarted = $0 { return true }
                return false
            }.count
        }
        #expect(starts == 1)
    }
}
