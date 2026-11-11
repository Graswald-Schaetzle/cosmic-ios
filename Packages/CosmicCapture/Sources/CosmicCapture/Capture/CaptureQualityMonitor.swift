import CoreVideo
import Foundation
import os
import simd

/// One coalesced camera frame's pose/exposure/tracking data, expressed without
/// ARKit types so the monitor stays unit-testable.
struct CaptureQualityFrameInput {
    let timestamp: TimeInterval
    let translation: SIMD3<Float>
    let rotation: simd_quatf
    /// Sensor exposure window for this frame, in seconds.
    let exposureDurationSeconds: TimeInterval
    /// Focal length in pixels (fx) of the capture image.
    let focalLengthPx: Float
    let trackingNormal: Bool
    /// Mean luma of the camera image in `0...1`, when sampled this frame.
    /// Sampling is throttled by `wantsLumaSample(at:)`; pass nil otherwise.
    let meanLuma: Float?
    let pendingFrameWrites: Int
    let thermalState: ProcessInfo.ThermalState
}

/// A ~10 Hz snapshot of capture quality. Shadow mode: these signals are
/// logged locally and surfaced for future guidance, but never alter frame
/// sampling or acceptance.
struct CaptureQualitySignals: Sendable {
    let timestamp: TimeInterval
    /// Camera speed over the emit window, m/s.
    let linearSpeedMPS: Float
    /// Full-rotation angular speed over the emit window (quaternion geodesic,
    /// not forward-axis only), deg/s.
    let angularSpeedDPS: Float
    /// Predicted motion blur from rotation: `fx × ω(rad/s) × exposure`, in px.
    let rotationalBlurPx: Float
    /// Predicted motion blur from lateral translation:
    /// `fx × v_lateral / 2.0 m × exposure`, in px. The depth is fixed by the
    /// capture contract, so every device rejects the same frames.
    let translationalBlurPx: Float
    var predictedBlurPx: Float { rotationalBlurPx + translationalBlurPx }
    let exposureDurationSeconds: TimeInterval
    /// Last sampled mean luma in `0...1`, carried forward between samples.
    let meanLuma: Float?
    let trackingNormal: Bool
    /// Fraction of recent frames with normal tracking, `0...1`.
    let trackingNormalDutyCycle: Float
    let pendingFrameWrites: Int
    let thermalState: ProcessInfo.ThermalState
}

/// Observes every coalesced AR frame — independent of keyframe emission — and
/// publishes a bounded-rate quality vector (speed, predicted blur, luma).
/// `CaptureGuidanceArbiter` turns it into coaching text and
/// `CaptureFrameQualityGate` uses predicted blur to drop smeared frames.
final class CaptureQualityMonitor {
    /// Fixed scene depth for the translational blur term, per the Echo-3
    /// capture contract.
    static let nominalSceneDepthM: Float = 2.0

    private let emitInterval: TimeInterval
    private let lumaSampleInterval: TimeInterval
    private let logInterval: TimeInterval
    /// Gaps larger than this (pause, interruption, tracking reset) are treated
    /// as discontinuities: the window restarts instead of producing a bogus
    /// velocity across the gap.
    private let maxWindowSeconds: TimeInterval
    private let trackingWindowCapacity: Int

    private var referenceTimestamp: TimeInterval?
    private var referenceTranslation: SIMD3<Float>?
    private var referenceRotation: simd_quatf?
    private var lastLumaSampleTimestamp: TimeInterval?
    private var lastKnownLuma: Float?
    private var lastLogTimestamp: TimeInterval?
    private var trackingWindow: [Bool] = []

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "capture",
        category: "CaptureQuality"
    )

    private(set) var latestSignals: CaptureQualitySignals?

    init(
        emitInterval: TimeInterval = 0.1,
        lumaSampleInterval: TimeInterval = 0.5,
        logInterval: TimeInterval = 1.0,
        maxWindowSeconds: TimeInterval = 0.5,
        trackingWindowCapacity: Int = 240
    ) {
        self.emitInterval = emitInterval
        self.lumaSampleInterval = lumaSampleInterval
        self.logInterval = logInterval
        self.maxWindowSeconds = maxWindowSeconds
        self.trackingWindowCapacity = trackingWindowCapacity
    }

    func reset() {
        referenceTimestamp = nil
        referenceTranslation = nil
        referenceRotation = nil
        lastLumaSampleTimestamp = nil
        lastKnownLuma = nil
        lastLogTimestamp = nil
        trackingWindow = []
        latestSignals = nil
    }

    /// Luma sampling reads the pixel buffer, so callers should only do it when
    /// the monitor asks (about every `lumaSampleInterval` seconds).
    func wantsLumaSample(at timestamp: TimeInterval) -> Bool {
        guard let lastLumaSampleTimestamp else { return true }
        return timestamp - lastLumaSampleTimestamp >= lumaSampleInterval
    }

    @discardableResult
    func observe(_ input: CaptureQualityFrameInput) -> CaptureQualitySignals? {
        trackingWindow.append(input.trackingNormal)
        if trackingWindow.count > trackingWindowCapacity {
            trackingWindow.removeFirst(trackingWindow.count - trackingWindowCapacity)
        }
        if let luma = input.meanLuma {
            lastKnownLuma = luma
            lastLumaSampleTimestamp = input.timestamp
        }

        guard let referenceTimestamp,
              let referenceTranslation,
              let referenceRotation
        else {
            setReference(input)
            return nil
        }

        let dt = input.timestamp - referenceTimestamp
        guard dt > 0 else { return nil }
        guard dt <= maxWindowSeconds else {
            setReference(input)
            return nil
        }
        guard dt >= emitInterval else { return nil }

        let linearSpeed = simd_distance(input.translation, referenceTranslation)
            / Float(dt)
        let angularSpeedRad = Self.rotationAngleRadians(
            from: referenceRotation,
            to: input.rotation
        ) / Float(dt)

        let exposure = Float(input.exposureDurationSeconds)
        let rotationalBlurPx = input.focalLengthPx * angularSpeedRad * exposure

        let velocity = (input.translation - referenceTranslation) / Float(dt)
        let forward = input.rotation.act(SIMD3<Float>(0, 0, -1))
        let lateralVelocity = velocity - simd_dot(velocity, forward) * forward
        let translationalBlurPx = input.focalLengthPx * simd_length(lateralVelocity)
            / Self.nominalSceneDepthM * exposure

        let dutyCycle = trackingWindow.isEmpty
            ? 0
            : Float(trackingWindow.filter { $0 }.count) / Float(trackingWindow.count)

        let signals = CaptureQualitySignals(
            timestamp: input.timestamp,
            linearSpeedMPS: linearSpeed,
            angularSpeedDPS: angularSpeedRad * 180 / .pi,
            rotationalBlurPx: rotationalBlurPx,
            translationalBlurPx: translationalBlurPx,
            exposureDurationSeconds: input.exposureDurationSeconds,
            meanLuma: lastKnownLuma,
            trackingNormal: input.trackingNormal,
            trackingNormalDutyCycle: dutyCycle,
            pendingFrameWrites: input.pendingFrameWrites,
            thermalState: input.thermalState
        )
        latestSignals = signals
        setReference(input)
        logIfDue(signals)
        return signals
    }

    private func setReference(_ input: CaptureQualityFrameInput) {
        referenceTimestamp = input.timestamp
        referenceTranslation = input.translation
        referenceRotation = input.rotation
    }

    private func logIfDue(_ signals: CaptureQualitySignals) {
        if let lastLogTimestamp,
           signals.timestamp - lastLogTimestamp < logInterval
        {
            return
        }
        lastLogTimestamp = signals.timestamp
        logger.debug(
            """
            v=\(signals.linearSpeedMPS, format: .fixed(precision: 2))m/s \
            w=\(signals.angularSpeedDPS, format: .fixed(precision: 0))°/s \
            blur=\(signals.predictedBlurPx, format: .fixed(precision: 1))px\
            (\(signals.rotationalBlurPx, format: .fixed(precision: 1))r+\
            \(signals.translationalBlurPx, format: .fixed(precision: 1))t) \
            exp=\(signals.exposureDurationSeconds * 1000, format: .fixed(precision: 1))ms \
            luma=\(signals.meanLuma.map { String(format: "%.2f", $0) } ?? "-") \
            track=\(signals.trackingNormalDutyCycle, format: .fixed(precision: 2)) \
            pend=\(signals.pendingFrameWrites) \
            thermal=\(signals.thermalState.rawValue)
            """
        )
    }

    /// Geodesic rotation angle between two orientations, in radians. Uses the
    /// full quaternion so roll is included — forward-vector comparison misses
    /// rotation about the view axis entirely.
    static func rotationAngleRadians(
        from first: simd_quatf,
        to second: simd_quatf
    ) -> Float {
        let dot = min(1, abs(simd_dot(first.vector, second.vector)))
        return 2 * acos(dot)
    }
}

/// Cheap sparse mean-luma estimate from the camera image's Y plane.
enum CaptureCameraImageLuma {
    /// Samples a `gridSize × gridSize` grid of luma bytes (plane 0 of ARKit's
    /// bi-planar YCbCr formats). ~1k reads, safe to call on the frame path at
    /// the monitor's throttled cadence.
    static func sampleMeanLuma(
        _ pixelBuffer: CVPixelBuffer,
        gridSize: Int = 32
    ) -> Float? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, gridSize > 0 else { return nil }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        for gridY in 0..<gridSize {
            let y = gridY * height / gridSize
            for gridX in 0..<gridSize {
                let x = gridX * width / gridSize
                total += Int(bytes[y * stride + x])
            }
        }
        return Float(total) / Float(gridSize * gridSize) / 255
    }
}
