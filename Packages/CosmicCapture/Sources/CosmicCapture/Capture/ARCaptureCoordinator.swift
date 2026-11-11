import ARKit
import AVFoundation
import CoreVideo
import Foundation
import Observation
import simd
import UIKit

/// Keeps at most one pending delegate value while a consumer is scheduled.
///
/// ARKit can deliver camera frames faster than the MainActor can copy and enqueue
/// them. Replacing the pending value bounds retained `ARFrame`/pixel-buffer memory
/// instead of creating one MainActor task per 60 fps callback.
final class LatestValueInbox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var latestValue: Value?
    private var isConsumerScheduled = false

    func submit(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        latestValue = value
        guard !isConsumerScheduled else { return false }
        isConsumerScheduled = true
        return true
    }

    func takeLatest() -> Value? {
        lock.lock()
        defer { lock.unlock() }

        let value = latestValue
        latestValue = nil
        return value
    }

    /// Returns true when a newer value arrived while the consumer was working.
    func finishCurrent() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard latestValue == nil else { return true }
        isConsumerScheduled = false
        return false
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }

        latestValue = nil
        isConsumerScheduled = false
    }
}

/// Which lifecycle boundary is waiting for `CaptureTrackingSettleGate`
/// before sampling (re-)arms.
///
/// Resume deliberately does NOT require the camera to return near its prior
/// pose. Sampling pauses never end the AR epoch, so world coordinates stay
/// valid wherever the user stands, and after an interruption ARKit
/// relocalizes into the same epoch (tracking stays limited until it does,
/// which the gate waits out).
enum CapturePendingSamplingArm: Sendable, Equatable {
    case start
    case resume
}

/// Why sampling was paused or resumed. An interruption resume restarts the
/// settle gate with its own trigger; every other source uses `.resume`.
enum CaptureSamplingPauseSource: Sendable, Equatable {
    case finishReview
    case frameLimit
    case scenePhase
    case interruption
}

/// Owns the ARKit session and turns its frames into a contract bundle.
///
/// Pipeline per coalesced frame (see `docs/capture-pipeline.md`):
/// tracking/settle gate → blur gate → writer backpressure → motion sampler →
/// pixel-buffer copy → serial JPEG/record write on `writerQueue`.
@MainActor
@Observable
final class ARCaptureCoordinator: NSObject {
    private static let maxPendingFrameWrites = 4

    enum Status: Equatable {
        case idle
        case starting
        case running
        case finishing
        case failed(String)
    }

    var status: Status = .idle
    var capturedCount = 0
    var scanHint = "Move slowly"
    var holdMismatchHint: String?
    var trackingState: ARCamera.TrackingState = .notAvailable
    var pathLengthM: Float = 0
    var maxDistanceFromOriginM: Float = 0
    var durationSeconds: TimeInterval = 0
    var activeDurationSeconds: TimeInterval = 0
    private(set) var lastFrameCommittedAt: Date?
    var selectedFormatDescription: String?
    var selectedLens: String?
    var formatCandidates: [CaptureVideoFormatChoice] = []
    var actualPixelBufferSize: String?

    let session = ARSession()

    /// Optional add-on guidance (see `CaptureLiveGuide`). Nil runs core capture.
    @ObservationIgnored private(set) var liveGuide: (any CaptureLiveGuide)?

    /// The single arbitrated coaching message for the live HUD. Nil hides the
    /// instruction pill: a calm camera is the normal state.
    var guidance: CaptureGuidance?
    private(set) var scanAim: CaptureAim?

    /// Quality signals (~10 Hz) feeding guidance and the blur gate.
    @ObservationIgnored private(set) var latestQualitySignals: CaptureQualitySignals?

    @ObservationIgnored private let sampler = ContinuousScanSampler()
    @ObservationIgnored private let qualityMonitor = CaptureQualityMonitor()
    @ObservationIgnored private let guidanceArbiter = CaptureGuidanceArbiter()
    @ObservationIgnored private let frameQualityGate = CaptureFrameQualityGate()
    @ObservationIgnored private var aimTracker = CaptureAimTracker()
    @ObservationIgnored private(set) var blurRejectedFrameCount = 0
    @ObservationIgnored nonisolated private let frameInbox =
        LatestValueInbox<ARFrame>()
    @ObservationIgnored private var writer: CaptureBundleWriter?
    @ObservationIgnored private let writerQueue = DispatchQueue(
        label: "capture.writer",
        qos: .userInitiated
    )
    @ObservationIgnored private var pendingFrameWrites = 0
    @ObservationIgnored private var settleGate = CaptureTrackingSettleGate()
    @ObservationIgnored private var pendingSamplingArm: CapturePendingSamplingArm?
    @ObservationIgnored private var isSamplingEnabled = false
    @ObservationIgnored private var isSamplingPauseRequested = false
    @ObservationIgnored private var wasSamplingBeforeInterruption = false
    @ObservationIgnored private var trackingLostSince: Date?
    @ObservationIgnored private var chosenHoldMode: CaptureHoldMode = .portrait
    @ObservationIgnored private var hasWarnedForHoldMismatch = false
    /// Echo-3 needs one fixed hold per scan, so frames in the other hold are
    /// not saved.
    @ObservationIgnored private var isHoldClearlyMismatched = false
    @ObservationIgnored var onFrameCommitted: ((Int) -> Void)?
    @ObservationIgnored var onStorageFailure: ((CaptureBundleWriterError) -> Void)?
    @ObservationIgnored var onFatalError: ((String) -> Void)?
    @ObservationIgnored var onSamplingStateChanged: (() -> Void)?

    var currentWriterID: UUID? { writer?.id }
    var currentManifest: CaptureManifest? { writer?.currentManifest }
    /// Main-actor mirror of the writer's committed count, updated after each
    /// successful commit so UI reads never block on the writer queue.
    private(set) var committedFrameCount = 0
    var isActivelySampling: Bool { isSamplingEnabled && status == .running }

    init(liveGuide: (any CaptureLiveGuide)? = nil) {
        self.liveGuide = liveGuide
        super.init()
        session.delegate = self
    }

    private var freshSessionOptions: ARSession.RunOptions {
        let base: ARSession.RunOptions = [.resetTracking, .removeExistingAnchors]
        return base.union(liveGuide?.sessionResetOptions ?? [])
    }

    static var isWorldTrackingSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    func prepareReadiness() -> CaptureReadinessIssue? {
        guard Self.isWorldTrackingSupported else {
            return .arkitUnsupported
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            return .cameraDenied
        case .notDetermined:
            return .cameraNotDetermined
        case .authorized:
            break
        @unknown default:
            return .cameraDenied
        }

        let selection = CaptureVideoFormatSelector.selectExact1920x1440(
            from: ARWorldTrackingConfiguration.supportedVideoFormats
        )
        formatCandidates = selection.candidates
        if let selected = selection.selected {
            applySelectedFormat(selected)
        } else if let reason = selection.reason {
            return .unsupportedVideoFormat(reason)
        }

        if !CaptureStorageProbe.hasEnoughStorage() {
            return .insufficientStorage
        }

        return nil
    }

    func requestCameraAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startPreview() {
        switch status {
        case .idle, .failed:
            break
        default:
            return
        }
        guard let cfg = makeConfiguration() else {
            status = .failed("Camera format unavailable")
            return
        }
        session.run(cfg, options: freshSessionOptions)
        status = .starting
        setSamplingEnabled(false)
    }

    func beginCapture(
        name: String,
        startedAt: Date,
        chosenHoldMode: CaptureHoldMode,
        library: CaptureLibrary
    ) throws -> UUID {
        let selection = CaptureVideoFormatSelector.selectExact1920x1440(
            from: ARWorldTrackingConfiguration.supportedVideoFormats
        )
        guard let format = selection.selected else {
            let message = selection.reason ?? "Camera format unavailable"
            status = .failed(message)
            throw CaptureBundleWriterError.writeFailed(message)
        }
        formatCandidates = selection.candidates
        applySelectedFormat(format)

        let writer = try CaptureBundleWriter(
            name: name,
            startedAt: startedAt,
            videoFormatDescription: selectedFormatDescription,
            selectedLens: selectedLens,
            deviceModel: UIDevice.current.model
        )
        self.writer = writer
        library.markWriterActive(writer.id)

        resetSessionState(startedAt: startedAt, chosenHoldMode: chosenHoldMode)
        liveGuide?.captureWillBegin()
        pendingSamplingArm = .start
        restartSettleGate(.start)
        guard let cfg = makeConfiguration(forcedFormat: format) else {
            throw CaptureBundleWriterError.writeFailed("Camera format unavailable")
        }
        // Continue the readiness preview session instead of resetting it, so
        // tracking is warm. The fresh-origin reset already happened in
        // `startPreview`, and the settle gate drops any preview frame queued
        // before this boundary, so frame 1 is always in the capture's epoch.
        let hasWarmPreviewSession = session.currentFrame != nil
        session.run(
            cfg,
            options: hasWarmPreviewSession ? [] : freshSessionOptions
        )
        status = .starting
        return writer.id
    }

    private func resetSessionState(startedAt: Date, chosenHoldMode: CaptureHoldMode) {
        sampler.reset()
        qualityMonitor.reset()
        latestQualitySignals = nil
        blurRejectedFrameCount = 0
        aimTracker.reset()
        scanAim = nil
        guidanceArbiter.reset()
        guidance = nil
        capturedCount = 0
        committedFrameCount = 0
        pathLengthM = 0
        maxDistanceFromOriginM = 0
        durationSeconds = 0
        activeDurationSeconds = 0
        lastFrameCommittedAt = nil
        pendingFrameWrites = 0
        isSamplingPauseRequested = false
        wasSamplingBeforeInterruption = false
        trackingLostSince = nil
        self.chosenHoldMode = chosenHoldMode
        holdMismatchHint = nil
        hasWarnedForHoldMismatch = false
        scanHint = "Starting tracking…"
        setSamplingEnabled(false)
    }

    func pauseSampling(source: CaptureSamplingPauseSource) {
        isSamplingPauseRequested = true
        setSamplingEnabled(false)
        if pendingSamplingArm == .resume {
            pendingSamplingArm = nil
        }
        frameInbox.reset()
    }

    func resumeSampling(source: CaptureSamplingPauseSource) {
        guard writer != nil else { return }
        if let configuration = session.configuration {
            // Reapply the existing configuration without reset options. This
            // wakes an interrupted/inactive session without changing epochs.
            session.run(configuration, options: [])
        }
        let trigger: CaptureTrackingSettleGate.Trigger =
            source == .interruption ? .interruptionEnd : .resume
        if status == .starting {
            isSamplingPauseRequested = false
            restartSettleGate(trigger)
            scanHint = "Starting tracking…"
            return
        }
        // A full `pauseSession()` drops status to .idle while the writer
        // still exists. The session re-ran above without reset options (same
        // world epoch), so recover into .running and let the gate wait out tracking.
        if status == .idle, writer != nil {
            status = .running
        }
        guard status == .running else { return }
        guard pendingSamplingArm == nil, !isSamplingEnabled else { return }

        isSamplingPauseRequested = false
        pendingSamplingArm = .resume
        restartSettleGate(trigger)
        scanHint = "Resuming capture…"
    }

    func pauseSession() {
        setSamplingEnabled(false)
        isSamplingPauseRequested = true
        pendingSamplingArm = nil
        frameInbox.reset()
        session.pause()
        if status == .running || status == .starting {
            status = .idle
        }
    }

    func discard(library: CaptureLibrary) {
        let id = writer?.id
        setSamplingEnabled(false)
        isSamplingPauseRequested = true
        pendingSamplingArm = nil
        frameInbox.reset()
        writer?.stopAcceptingFrames()
        session.pause()
        if let id {
            library.markWriterInactive(id)
            try? library.delete(id: id)
        }
        writer = nil
        committedFrameCount = 0
        holdMismatchHint = nil
        liveGuide?.captureDidEnd()
        status = .idle
    }

    func finish(library: CaptureLibrary) async throws -> CaptureManifest {
        status = .finishing
        setSamplingEnabled(false)
        isSamplingPauseRequested = true
        pendingSamplingArm = nil
        frameInbox.reset()
        session.pause()

        guard let writer else {
            throw CaptureBundleWriterError.emptyCapture
        }

        let stats = sampler.stats()
        let finalized: CaptureManifest = try await withCheckedThrowingContinuation { continuation in
            writerQueue.async {
                do {
                    let result = try writer.finalize(
                        durationSeconds: stats.durationSeconds,
                        pathLengthM: stats.pathLengthM,
                        maxDistanceFromOriginM: stats.maxDistanceFromOriginM
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        library.markWriterInactive(writer.id)
        self.writer = nil
        committedFrameCount = 0
        holdMismatchHint = nil
        liveGuide?.captureDidEnd()
        status = .idle
        return finalized
    }

    // MARK: - Configuration

    private func applySelectedFormat(_ format: ARConfiguration.VideoFormat) {
        selectedFormatDescription =
            "\(Int(format.imageResolution.width))x\(Int(format.imageResolution.height))@\(format.framesPerSecond)"
        selectedLens = "wide"
    }

    /// Settings the Echo-3 capture contract requires: gravity-aligned world,
    /// autofocus on, exposure left to ARKit, native frame rate.
    private func makeConfiguration(
        forcedFormat: ARConfiguration.VideoFormat? = nil
    ) -> ARWorldTrackingConfiguration? {
        let cfg = ARWorldTrackingConfiguration()
        cfg.worldAlignment = .gravity
        cfg.environmentTexturing = .none
        cfg.planeDetection = []
        cfg.isAutoFocusEnabled = true
        liveGuide?.configure(cfg)

        if let forcedFormat {
            cfg.videoFormat = forcedFormat
            return cfg
        }

        let selection = CaptureVideoFormatSelector.selectExact1920x1440(
            from: ARWorldTrackingConfiguration.supportedVideoFormats
        )
        formatCandidates = selection.candidates
        guard let format = selection.selected else { return nil }
        cfg.videoFormat = format
        applySelectedFormat(format)
        return cfg
    }

    // MARK: - Frame pipeline

    private func handleFrame(_ frame: ARFrame) {
        trackingState = frame.camera.trackingState
        updateTrackingHint(frame.camera.trackingState)
        observeQualitySignals(frame)
        let isSettled = observeSettleGate(frame)
        armCaptureIfReady(frame, isSettled: isSettled)
        armResumeIfReady(isSettled: isSettled)
        updateHoldMismatch(arkitWorldFromCamera: frame.camera.transform)
        updateGuidance(frame)

        guard isSamplingEnabled, status == .running, writer != nil else { return }

        let translation = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        let forwardColumn = frame.camera.transform.columns.2
        let forward = simd_normalize(SIMD3(-forwardColumn.x, -forwardColumn.y, -forwardColumn.z))
        let trackingNormal = frame.camera.trackingState == .normal

        // Extreme predicted blur rejects the frame. Tracking loss is already
        // rejected inside the sampler.
        let blurVerdict = frameQualityGate.verdict(
            signals: latestQualitySignals,
            frameTimestamp: frame.timestamp
        )
        if blurVerdict == .rejectExtremeBlur {
            blurRejectedFrameCount += 1
        }
        let isBackpressured = pendingFrameWrites >= Self.maxPendingFrameWrites

        let observedSample = sampler.observe(
            translation: translation,
            forward: forward,
            timestamp: frame.timestamp,
            trackingNormal: trackingNormal,
            canEmitSample: isSettled && !isBackpressured && !isHoldClearlyMismatched
                && blurVerdict == .accept
        )
        guard let sample = observedSample else {
            publishStats(sampler.stats(), updateHint: trackingNormal && isSettled)
            return
        }

        enqueueSample(sample, from: frame)
    }

    private func publishStats(_ stats: ContinuousScanStats, updateHint: Bool) {
        capturedCount = stats.frameCount
        pathLengthM = stats.pathLengthM
        maxDistanceFromOriginM = stats.maxDistanceFromOriginM
        durationSeconds = stats.durationSeconds
        activeDurationSeconds = stats.activeDurationSeconds
        // The tracking-state hint carries the actionable reason and stays up
        // while tracking settles; only settled normal tracking may replace it.
        if updateHint {
            scanHint = stats.qualityHint
        }
    }

    /// Copies the frame on the main actor, then hands it to the serial writer
    /// queue so filenames stay ordered and contiguous.
    private func enqueueSample(_ sample: ContinuousScanSample, from frame: ARFrame) {
        let cameraTransform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let imageResolution = frame.camera.imageResolution

        guard let copied = copyPixelBuffer(frame.capturedImage) else {
            let error = CaptureBundleWriterError.frameBufferingFailed
            writer?.stopAcceptingFrames(because: error)
            setSamplingEnabled(false)
            onStorageFailure?(error)
            return
        }
        let pixelWidth = CVPixelBufferGetWidth(copied)
        let pixelHeight = CVPixelBufferGetHeight(copied)
        actualPixelBufferSize = "\(pixelWidth)x\(pixelHeight)"

        let scaled = CameraGeometry.scaleIntrinsics(
            fx: intrinsics.columns.0.x,
            fy: intrinsics.columns.1.y,
            cx: intrinsics.columns.2.x,
            cy: intrinsics.columns.2.y,
            fromWidth: Int(imageResolution.width),
            fromHeight: Int(imageResolution.height),
            toWidth: pixelWidth,
            toHeight: pixelHeight
        )

        // ARKit's EXIF carries DateTimeOriginal / SubSecTimeOriginal /
        // OffsetTimeOriginal, which Echo-3 requires on every image.
        let onCommitted = liveGuide?.prepareCommit(of: frame)
        let pending = PendingCaptureFrame(
            pixelBuffer: copied,
            arkitWorldFromCamera: cameraTransform,
            fx: scaled.fx,
            fy: scaled.fy,
            cx: scaled.cx,
            cy: scaled.cy,
            width: pixelWidth,
            height: pixelHeight,
            sampleReason: sample.reason,
            exifPropertyListData: captureEXIFPropertyList(frame.exifData)
        )

        let statsSnapshot = sampler.stats()
        publishStats(statsSnapshot, updateHint: true)

        // `writer` is main-actor state, so read it here rather than inside the
        // Sendable closure. CaptureBundleWriter is @unchecked Sendable.
        guard let writer else { return }
        pendingFrameWrites += 1

        writerQueue.async { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.pendingFrameWrites = max(0, self.pendingFrameWrites - 1)
                }
            }
            do {
                // Motion stats ride the same atomic manifest write as the frame count.
                let index = try writer.append(
                    pending,
                    motionStats: CaptureMotionStatsUpdate(
                        pathLengthM: statsSnapshot.pathLengthM,
                        maxDistanceFromOriginM: statsSnapshot.maxDistanceFromOriginM,
                        durationSeconds: statsSnapshot.durationSeconds
                    )
                )
                Task { @MainActor in
                    guard self.writer === writer else { return }
                    self.capturedCount = index
                    self.committedFrameCount = index
                    self.lastFrameCommittedAt = Date()
                    onCommitted?(index)
                    self.onFrameCommitted?(index)
                }
            } catch let error as CaptureBundleWriterError {
                Task { @MainActor in
                    guard self.writer === writer else { return }
                    self.setSamplingEnabled(false)
                    self.onStorageFailure?(error)
                }
            } catch {
                Task { @MainActor in
                    guard self.writer === writer else { return }
                    self.setSamplingEnabled(false)
                    self.onFatalError?(error.localizedDescription)
                }
            }
        }
    }

    private func armCaptureIfReady(_ frame: ARFrame, isSettled: Bool) {
        guard !isSamplingPauseRequested,
              status == .starting,
              writer != nil,
              pendingSamplingArm == .start
        else {
            return
        }
        guard isSettled else {
            if frame.camera.trackingState == .normal {
                scanHint = "Starting tracking…"
            }
            return
        }

        pendingSamplingArm = nil
        status = .running
        scanHint = "Move slowly"
        isSamplingPauseRequested = false
        setSamplingEnabled(true)
    }

    private func armResumeIfReady(isSettled: Bool) {
        guard status == .running,
              writer != nil,
              pendingSamplingArm == .resume
        else {
            return
        }
        guard isSettled else {
            scanHint = "Resuming capture…"
            return
        }

        pendingSamplingArm = nil
        scanHint = "Move slowly"
        setSamplingEnabled(true)
    }

    /// Feeds every processed frame to the settle gate while sampling is
    /// armed or waiting to arm, and returns whether commits may proceed.
    private func observeSettleGate(_ frame: ARFrame) -> Bool {
        guard writer != nil,
              !isSamplingPauseRequested,
              pendingSamplingArm != nil || isActivelySampling
        else {
            return false
        }
        let verdict = settleGate.observe(
            CaptureTrackingSettleGate.Frame(
                timestamp: frame.timestamp,
                isTrackingNormal: frame.camera.trackingState == .normal,
                worldFromCamera: frame.camera.transform
            )
        )
        return verdict.isSettled
    }

    /// Restarts settling at a lifecycle boundary (start, resume, interruption
    /// end). Frames queued before the boundary are dropped and ignored.
    private func restartSettleGate(_ trigger: CaptureTrackingSettleGate.Trigger) {
        let now = ProcessInfo.processInfo.systemUptime
        let boundaryTimestamp = session.currentFrame?.timestamp ?? now
        frameInbox.reset()
        _ = settleGate.restart(trigger, minimumTimestamp: boundaryTimestamp, at: now)
    }

    private func updateTrackingHint(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            trackingLostSince = nil
        case .notAvailable:
            scanHint = "Tracking lost. Hold still"
            trackingLostSince = trackingLostSince ?? Date()
        case .limited(let reason):
            let since = trackingLostSince ?? Date()
            trackingLostSince = since
            switch reason {
            case .initializing:
                scanHint = "Starting tracking…"
            case .relocalizing:
                scanHint = "Hold still. Recovering tracking"
            case .excessiveMotion:
                scanHint = "Going too fast"
            case .insufficientFeatures:
                scanHint = Date().timeIntervalSince(since) > 10
                    ? "Turn on more light"
                    : "Aim at a textured surface"
            @unknown default:
                scanHint = "Tracking lost. Hold still"
            }
        }
    }

    /// Drops add-on cues at once, e.g. when the user picks another scan pass.
    func clearAdvisories() {
        guidanceArbiter.clearAdvisories()
        if guidance?.id.hasPrefix(CaptureGuidanceArbiter.advisoryIDPrefix) == true {
            guidance = nil
        }
    }

    /// Runs the guidance arbiter on every coalesced frame and publishes the
    /// single message the HUD may show. Presentation policy only: frame
    /// acceptance is decided by the gates above.
    private func updateGuidance(_ frame: ARFrame) {
        if isActivelySampling, frame.camera.trackingState == .normal {
            let nextAim = aimTracker.update(
                worldFromCamera: frame.camera.transform, timestamp: frame.timestamp
            )
            if nextAim != scanAim { scanAim = nextAim }
        } else {
            aimTracker.reset()
            if scanAim != nil { scanAim = nil }
        }
        // Only feed motion signals that are fresh relative to this frame;
        // stale values from before a pause would misfire coaching.
        let signals = latestQualitySignals.flatMap {
            frame.timestamp - $0.timestamp < 0.3 ? $0 : nil
        }
        let input = CaptureGuidanceInput(
            timestamp: frame.timestamp,
            holdMismatchMessage: holdMismatchHint,
            tracking: Self.trackingSignal(frame.camera.trackingState),
            trackingLimitedSeconds: trackingLostSince.map {
                Date().timeIntervalSince($0)
            } ?? 0,
            flowMessage: currentFlowMessage,
            isSampling: isActivelySampling,
            linearSpeedMPS: signals?.linearSpeedMPS,
            angularSpeedDPS: signals?.angularSpeedDPS,
            predictedBlurPx: signals?.predictedBlurPx,
            meanLuma: signals?.meanLuma,
            advisories: liveGuide?.advisories() ?? []
        )
        let next = guidanceArbiter.evaluate(input)
        if next != guidance {
            guidance = next
        }
        liveGuide?.observe(
            frame,
            context: CaptureLiveGuideFrameContext(
                isActivelySampling: isActivelySampling,
                isTrackingNormal: frame.camera.trackingState == .normal,
                hasBlockingMessage: holdMismatchHint != nil || currentFlowMessage != nil,
                scanningSeconds: sampler.stats().durationSeconds,
                guidance: next
            )
        )
        if next?.wantsHaptic == true {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private var currentFlowMessage: CaptureFlowMessage? {
        if writer != nil, status == .starting {
            return .initializingTracking
        }
        if status == .running, pendingSamplingArm == .resume {
            return .reacquiringPosition
        }
        if status == .running, sampler.isApproachingFrameLimit {
            return .frameLimitApproaching
        }
        if status == .running, sampler.isAtFrameLimit {
            return .frameLimitReached
        }
        return nil
    }

    private static func trackingSignal(
        _ state: ARCamera.TrackingState
    ) -> CaptureTrackingSignal {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .initializing
            case .relocalizing: return .relocalizing
            case .excessiveMotion: return .excessiveMotion
            case .insufficientFeatures: return .insufficientFeatures
            @unknown default: return .notAvailable
            }
        }
    }

    /// Quality observation on every coalesced frame, independent of keyframe
    /// emission. Its signals feed guidance and the blur gate.
    private func observeQualitySignals(_ frame: ARFrame) {
        let transform = frame.camera.transform
        let rotationMatrix = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        let meanLuma = qualityMonitor.wantsLumaSample(at: frame.timestamp)
            ? CaptureCameraImageLuma.sampleMeanLuma(frame.capturedImage)
            : nil
        let input = CaptureQualityFrameInput(
            timestamp: frame.timestamp,
            translation: SIMD3(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            ),
            rotation: simd_quatf(rotationMatrix),
            exposureDurationSeconds: frame.camera.exposureDuration,
            focalLengthPx: frame.camera.intrinsics.columns.0.x,
            trackingNormal: frame.camera.trackingState == .normal,
            meanLuma: meanLuma,
            pendingFrameWrites: pendingFrameWrites,
            thermalState: ProcessInfo.processInfo.thermalState
        )
        if let signals = qualityMonitor.observe(input) {
            latestQualitySignals = signals
        }
    }

    private func updateHoldMismatch(arkitWorldFromCamera: simd_float4x4) {
        guard status == .running else {
            holdMismatchHint = nil
            isHoldClearlyMismatched = false
            return
        }

        let cameraFromWorld = CameraGeometry.opencvCameraFromWorld(
            arkitWorldFromCamera: arkitWorldFromCamera
        )
        isHoldClearlyMismatched = CameraGeometry.isClearHoldMismatch(
            opencvCameraFromWorld: cameraFromWorld,
            chosenMode: chosenHoldMode
        )
        let isMismatch = CameraGeometry.isHoldMismatch(
            opencvCameraFromWorld: cameraFromWorld,
            chosenMode: chosenHoldMode
        )
        guard isMismatch else {
            holdMismatchHint = nil
            return
        }

        holdMismatchHint =
            "Turn back to \(chosenHoldMode.rawValue). Frames in the other orientation aren't saved."
        guard !hasWarnedForHoldMismatch else { return }
        hasWarnedForHoldMismatch = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var copy: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            attrs as CFDictionary,
            &copy
        )
        guard status == kCVReturnSuccess, let copy else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane)
                else { continue }
                let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
                let height = CVPixelBufferGetHeightOfPlane(source, plane)
                let rowBytes = min(srcStride, dstStride)
                for row in 0..<height {
                    memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), rowBytes)
                }
            }
        } else if let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(copy)
        {
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(copy)
            let height = CVPixelBufferGetHeight(source)
            let rowBytes = min(srcStride, dstStride)
            for row in 0..<height {
                memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), rowBytes)
            }
        }

        CVBufferPropagateAttachments(source, copy)
        return copy
    }

    private func captureEXIFPropertyList(_ exif: [String: Any]) -> Data? {
        guard PropertyListSerialization.propertyList(exif, isValidFor: .binary) else {
            return nil
        }
        return try? PropertyListSerialization.data(
            fromPropertyList: exif,
            format: .binary,
            options: 0
        )
    }

    private func setSamplingEnabled(_ enabled: Bool) {
        guard isSamplingEnabled != enabled else { return }
        isSamplingEnabled = enabled
        onSamplingStateChanged?()
    }

    private func processLatestFrame() {
        if let frame = frameInbox.takeLatest() {
            handleFrame(frame)
        }
        guard frameInbox.finishCurrent() else { return }

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.processLatestFrame()
        }
    }
}

extension ARCaptureCoordinator: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frameInbox.submit(frame) else { return }
        Task { @MainActor [weak self] in
            self?.processLatestFrame()
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        forwardAnchorUpdate(anchors)
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        forwardAnchorUpdate(anchors)
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        Task { @MainActor in
            guard self.isActivelySampling else { return }
            self.liveGuide?.anchorsDidRemove(anchors)
        }
    }

    private nonisolated func forwardAnchorUpdate(_ anchors: [ARAnchor]) {
        Task { @MainActor in
            guard self.isActivelySampling else { return }
            self.liveGuide?.anchorsDidUpdate(anchors)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.setSamplingEnabled(false)
            self.status = .failed(error.localizedDescription)
            self.onFatalError?(error.localizedDescription)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.wasSamplingBeforeInterruption =
                self.writer != nil
                && (
                    (self.status == .starting && !self.isSamplingPauseRequested)
                        || self.isSamplingEnabled
                        || self.pendingSamplingArm == .resume
                )
            self.pauseSampling(source: .interruption)
        }
    }

    /// After an interruption, relocalize into the same world epoch instead of
    /// resetting tracking. Tracking stays `.limited(.relocalizing)` until
    /// alignment succeeds, which the settle gate waits out, so committed
    /// frames never mix coordinates from two epochs. Returning false would
    /// give every frame after an interruption a new world origin.
    nonisolated func sessionShouldAttemptRelocalization(
        _ session: ARSession
    ) -> Bool {
        true
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            guard self.writer != nil,
                  self.status == .running || self.status == .starting,
                  UIApplication.shared.applicationState == .active
            else {
                if self.status != .running && self.status != .starting {
                    self.wasSamplingBeforeInterruption = false
                }
                return
            }
            if let configuration = self.session.configuration {
                // Keep the current world origin. A reset here would mix
                // coordinates from two ARKit epochs in one capture.
                self.session.run(configuration, options: [])
            }
            if self.wasSamplingBeforeInterruption {
                self.wasSamplingBeforeInterruption = false
                self.resumeSampling(source: .interruption)
            }
        }
    }
}
