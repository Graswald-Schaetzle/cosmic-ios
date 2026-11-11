import Foundation
import simd
import Testing
@testable import CosmicCapture

/// Regression fixture from a real outdoor scan that committed two bad poses
/// after ARKit relocalized. ARKit `world_from_camera` is recovered from the
/// bundle's OpenCV trajectory; `t` is relative time from each image's EXIF
/// capture time. Image_001407 and Image_002052 are the bad poses: the first
/// frame committed after a 2.48 s and a 170.55 s gap, 19.5 m / 122° and
/// 28.7 m / 58° from the frame after them.
private struct IncidentFrame {
    let index: Int
    let t: TimeInterval
    let rowMajor: [Float]

    var worldFromCamera: simd_float4x4 {
        simd_float4x4(rows: [
            SIMD4(rowMajor[0], rowMajor[1], rowMajor[2], rowMajor[3]),
            SIMD4(rowMajor[4], rowMajor[5], rowMajor[6], rowMajor[7]),
            SIMD4(rowMajor[8], rowMajor[9], rowMajor[10], rowMajor[11]),
            SIMD4(rowMajor[12], rowMajor[13], rowMajor[14], rowMajor[15]),
        ])
    }
}

private struct IncidentWindow {
    let before: [IncidentFrame]
    let bad: IncidentFrame
    let after: [IncidentFrame]
}

private let shortGap = IncidentWindow(
    before: [
        IncidentFrame(index: 1404, t: 0.000, rowMajor: [0.648544, -0.044445, 0.759878, 2.727428, 0.018086, 0.998912, 0.042989, 0.140043, -0.760962, -0.014137, 0.648642, -19.757735, 0, 0, 0, 1]),
        IncidentFrame(index: 1405, t: 0.330, rowMajor: [0.606450, -0.042614, 0.793979, 2.713027, 0.011926, 0.998938, 0.044505, 0.117760, -0.795032, -0.017521, 0.606314, -19.824364, 0, 0, 0, 1]),
        IncidentFrame(index: 1406, t: 1.289, rowMajor: [0.552341, 0.008321, 0.833577, 2.718568, -0.025499, 0.999651, 0.006918, 0.173847, -0.833228, -0.025077, 0.552360, -19.841193, 0, 0, 0, 1]),
    ],
    bad: IncidentFrame(index: 1407, t: 3.766, rowMajor: [0.767704, 0.035146, -0.639840, -0.479483, 0.015984, 0.997134, 0.073949, -0.050790, 0.640605, -0.066998, 0.764942, -0.004073, 0, 0, 0, 1]),
    after: [
        IncidentFrame(index: 1408, t: 4.065, rowMajor: [0.138887, 0.027541, 0.989925, 2.954055, 0.019716, 0.999338, -0.030569, 0.130230, -0.990112, 0.023763, 0.138252, -19.170390, 0, 0, 0, 1]),
        IncidentFrame(index: 1409, t: 4.310, rowMajor: [-0.066419, 0.184104, 0.980660, 3.017769, 0.025671, 0.982820, -0.182771, 0.207198, -0.997461, 0.013035, -0.070004, -19.009578, 0, 0, 0, 1]),
    ]
)

private let longGap = IncidentWindow(
    before: [
        IncidentFrame(index: 2049, t: 0.000, rowMajor: [-0.960270, 0.107434, 0.257563, -9.288920, 0.097285, 0.993904, -0.051867, 0.397198, -0.261565, -0.024749, -0.964868, -31.226011, 0, 0, 0, 1]),
        IncidentFrame(index: 2050, t: 0.133, rowMajor: [-0.972510, 0.016000, 0.232309, -9.470793, 0.025296, 0.998992, 0.037091, 0.291170, -0.231482, 0.041947, -0.971935, -31.196498, 0, 0, 0, 1]),
        IncidentFrame(index: 2051, t: 0.279, rowMajor: [-0.976690, -0.055175, 0.207442, -9.674543, -0.028972, 0.991442, 0.127295, 0.157471, -0.212690, 0.118318, -0.969930, -31.164268, 0, 0, 0, 1]),
    ],
    bad: IncidentFrame(index: 2052, t: 170.829, rowMajor: [-0.985092, -0.022239, 0.170584, -26.912291, -0.085226, 0.924455, -0.371644, 0.208962, -0.149433, -0.380642, -0.912569, -15.383107, 0, 0, 0, 1]),
    after: [
        IncidentFrame(index: 2053, t: 170.979, rowMajor: [-0.406340, 0.387711, 0.827386, 1.758344, -0.064233, 0.891151, -0.449136, 0.775665, -0.911462, -0.235647, -0.337207, -16.581143, 0, 0, 0, 1]),
        IncidentFrame(index: 2054, t: 171.112, rowMajor: [-0.354677, 0.429583, 0.830459, 1.793620, -0.083632, 0.870066, -0.485789, 0.788460, -0.931241, -0.241752, -0.272666, -16.495960, 0, 0, 0, 1]),
    ]
)

/// What happened during the gap. The bundle cannot tell us, so every
/// plausible explanation must keep the bad frame out.
enum IncidentGapExplanation: String, CaseIterable, CustomTestStringConvertible {
    /// No processed frames at all (thermal or a stalled main actor).
    case framesStopped
    /// Frames kept arriving with limited tracking, then `.normal` returned.
    case trackingLimited
    /// Sampling was paused and resumed (scene phase / interruption / review).
    case pauseAndResume

    var testDescription: String { rawValue }
}

/// How long ARKit held the wrong pose. Only committed frames were saved, so
/// the true duration is unknown; it was at most the next committed frame.
enum IncidentBadPoseDuration: String, CaseIterable, CustomTestStringConvertible {
    case singleFrame
    case untilNextCommittedFrame

    var testDescription: String { rawValue }
}

private struct ProcessedFrame {
    let frame: CaptureTrackingSettleGate.Frame
    let isBadPose: Bool
}

private let processedFPS = 30.0

private func interpolate(
    _ a: simd_float4x4,
    _ b: simd_float4x4,
    fraction: Float
) -> simd_float4x4 {
    var result = simd_float4x4(
        simd_slerp(simd_quatf(a), simd_quatf(b), fraction)
    )
    result.columns.3 = a.columns.3 + (b.columns.3 - a.columns.3) * fraction
    result.columns.3.w = 1
    return result
}

private func frames(
    from a: IncidentFrame,
    to b: IncidentFrame,
    normal: Bool = true
) -> [ProcessedFrame] {
    let steps = max(1, Int((b.t - a.t) * processedFPS))
    return (0..<steps).map { step in
        let fraction = Float(step) / Float(steps)
        return ProcessedFrame(
            frame: .init(
                timestamp: a.t + (b.t - a.t) * Double(fraction),
                isTrackingNormal: normal,
                worldFromCamera: interpolate(a.worldFromCamera, b.worldFromCamera, fraction: fraction)
            ),
            isBadPose: false
        )
    }
}

private func runIncident(
    _ window: IncidentWindow,
    gap: IncidentGapExplanation,
    duration: IncidentBadPoseDuration
) -> (badFrameVerdicts: [Bool], events: [CaptureTrackingSettleGate.Event], settledAtEnd: Bool) {
    var gate = CaptureTrackingSettleGate()
    let first = window.before[0]
    gate.restart(.start, minimumTimestamp: first.t - 2, at: first.t - 2)

    // One second of steady tracking before the window so the gate is settled.
    var stream: [ProcessedFrame] = (0..<Int(processedFPS)).map { step in
        ProcessedFrame(
            frame: .init(
                timestamp: first.t - 1 + Double(step) / processedFPS,
                isTrackingNormal: true,
                worldFromCamera: first.worldFromCamera
            ),
            isBadPose: false
        )
    }
    for (a, b) in zip(window.before, window.before.dropFirst()) {
        stream += frames(from: a, to: b)
    }
    let lastBefore = window.before[window.before.count - 1]
    stream.append(ProcessedFrame(
        frame: .init(timestamp: lastBefore.t, isTrackingNormal: true, worldFromCamera: lastBefore.worldFromCamera),
        isBadPose: false
    ))
    if gap == .trackingLimited {
        let limitedSteps = Int((window.bad.t - lastBefore.t) * processedFPS) - 1
        stream += (1...limitedSteps).map { step in
            ProcessedFrame(
                frame: .init(
                    timestamp: lastBefore.t + Double(step) / processedFPS,
                    isTrackingNormal: false,
                    worldFromCamera: lastBefore.worldFromCamera
                ),
                isBadPose: false
            )
        }
    }

    let next = window.after[0]
    stream.append(ProcessedFrame(
        frame: .init(timestamp: window.bad.t, isTrackingNormal: true, worldFromCamera: window.bad.worldFromCamera),
        isBadPose: true
    ))
    var t = window.bad.t + 1 / processedFPS
    while t < next.t {
        let isBad = duration == .untilNextCommittedFrame
        stream.append(ProcessedFrame(
            frame: .init(
                timestamp: t,
                isTrackingNormal: true,
                worldFromCamera: isBad ? window.bad.worldFromCamera : next.worldFromCamera
            ),
            isBadPose: isBad
        ))
        t += 1 / processedFPS
    }
    for (a, b) in zip(window.after, window.after.dropFirst()) {
        stream += frames(from: a, to: b)
    }
    let last = window.after[window.after.count - 1]
    stream += (0..<Int(processedFPS)).map { step in
        ProcessedFrame(
            frame: .init(
                timestamp: last.t + Double(step) / processedFPS,
                isTrackingNormal: true,
                worldFromCamera: last.worldFromCamera
            ),
            isBadPose: false
        )
    }

    var badFrameVerdicts: [Bool] = []
    var events: [CaptureTrackingSettleGate.Event] = []
    var settled = false
    for processed in stream {
        if gap == .pauseAndResume, processed.frame.timestamp == window.bad.t {
            events.append(gate.restart(
                .resume,
                minimumTimestamp: lastBefore.t,
                at: window.bad.t - 0.01
            ))
        }
        let verdict = gate.observe(processed.frame)
        events += verdict.events
        settled = verdict.isSettled
        if processed.isBadPose {
            badFrameVerdicts.append(verdict.isSettled)
        }
    }
    return (badFrameVerdicts, events, settled)
}

@Suite("Settle gate relocalization regression")
struct CaptureTrackingSettleGateIncidentTests {
    @Test(
        "Never commits Image_001407 after the 2.48 s gap",
        arguments: IncidentGapExplanation.allCases, IncidentBadPoseDuration.allCases
    )
    func shortGapBadFrame(gap: IncidentGapExplanation, duration: IncidentBadPoseDuration) {
        let result = runIncident(shortGap, gap: gap, duration: duration)
        #expect(!result.badFrameVerdicts.isEmpty)
        #expect(!result.badFrameVerdicts.contains(true))
        #expect(result.events.contains { event in
            guard case .poseDiscontinuity(let translationM, _, _, _) = event else { return false }
            return translationM > 19
        })
        #expect(result.settledAtEnd)
    }

    @Test(
        "Never commits Image_002052 after the 170.5 s gap",
        arguments: IncidentGapExplanation.allCases, IncidentBadPoseDuration.allCases
    )
    func longGapBadFrame(gap: IncidentGapExplanation, duration: IncidentBadPoseDuration) {
        let result = runIncident(longGap, gap: gap, duration: duration)
        #expect(!result.badFrameVerdicts.isEmpty)
        #expect(!result.badFrameVerdicts.contains(true))
        #expect(result.events.contains { event in
            guard case .poseDiscontinuity(let translationM, _, _, _) = event else { return false }
            return translationM > 28
        })
        #expect(result.settledAtEnd)
    }

    @Test("The fixture reproduces the reported jumps")
    func fixtureMatchesIncident() {
        for (window, expectedM, expectedDeg) in [(shortGap, Float(19.47), Float(122.1)), (longGap, Float(28.70), Float(57.9))] {
            let bad = window.bad.worldFromCamera
            let next = window.after[0].worldFromCamera
            let distance = simd_distance(
                SIMD3(bad.columns.3.x, bad.columns.3.y, bad.columns.3.z),
                SIMD3(next.columns.3.x, next.columns.3.y, next.columns.3.z)
            )
            #expect(abs(distance - expectedM) < 0.05)
            #expect(abs(CaptureTrackingSettleGate.rotationDegrees(from: bad, to: next) - expectedDeg) < 0.5)
        }
    }
}
