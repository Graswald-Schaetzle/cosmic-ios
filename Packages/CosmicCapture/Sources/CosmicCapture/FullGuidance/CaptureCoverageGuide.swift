import ARKit
import Observation
import simd
import UIKit

/// LiDAR coverage guidance: paints what saved frames have seen, coaches the
/// one missing region worth fixing, and powers the finish review with repair.
///
/// Plugs into `ARCaptureCoordinator` as a `CaptureLiveGuide`. Depth and mesh
/// are read live only; nothing here is written to the capture bundle. On
/// devices without LiDAR it degrades to a sparse feature-point preview.
@MainActor
@Observable
final class CaptureCoverageGuide: CaptureLiveGuide {
    var meshRevision = 0
    var overlayRevision = 0
    /// One quiet line like `Walls 3/4 · Floor ✓ · Ceiling —`; nil until the
    /// mesh has classified structure.
    var structuralReadout: String?

    let roomOverview = CaptureRoomOverview()

    private(set) var guidanceCategory: CaptureStructuralCategory = .wall
    var surfaceSelectionSuspended = false {
        didSet { automaticSurfaceSelector.reset() }
    }

    /// The one review gap the user chose to repair.
    private(set) var activeRepairTarget: CaptureCoverageGap?
    /// The single confirmed missing region coached during capture, or nil.
    /// Exists only with mesh classification, and only from saved coverage.
    private(set) var liveCoverageGap: CaptureCoverageGap?
    private(set) var gapNavigation: CaptureGapNavigation?

    /// The view the camera feed fills; gap arrows project into its bounds.
    @ObservationIgnored weak var navigationViewport: UIView?

    @ObservationIgnored private weak var coordinator: ARCaptureCoordinator?
    /// Writes each committed frame's LiDAR depth next to the bundle.
    @ObservationIgnored let depthRecorder = CaptureDepthRecorder()
    @ObservationIgnored private(set) var coverageTracker: CaptureCoverageTracker?
    @ObservationIgnored private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    @ObservationIgnored private var meshAnchorRevisions: [UUID: Int] = [:]
    @ObservationIgnored private var previewMeshArchive = CaptureMeshPreviewArchive()
    @ObservationIgnored private var sparsePointCloud = CaptureSparsePointCloudAccumulator()
    @ObservationIgnored private var committedTrajectory: [Int: simd_float4x4] = [:]

    @ObservationIgnored private var automaticSurfaceSelector = CaptureAutomaticSurfaceSelector()
    @ObservationIgnored private var lookedAtSurface: (
        category: CaptureStructuralCategory, timestamp: TimeInterval, forward: SIMD3<Float>
    )?
    @ObservationIgnored private var gapNavigator = CaptureGapNavigator()
    @ObservationIgnored private var lastGapNavigationAt: TimeInterval = 0
    @ObservationIgnored private var lastContext: CaptureLiveGuideFrameContext?

    @ObservationIgnored private var lastStructuralUpdateAt: TimeInterval = 0
    @ObservationIgnored private var overlayRenderTask: Task<Void, Never>?
    @ObservationIgnored private var lastOverlayRenderAt = -TimeInterval.greatestFiniteMagnitude
    @ObservationIgnored private var overlayCameraHeightCell: Int32?

    @ObservationIgnored private var repairTargets: [CaptureCoverageGap] = []
    @ObservationIgnored private var repairBaselineVoxelCount = 0
    @ObservationIgnored private var liveGapBaselineVoxelCount = 0
    @ObservationIgnored private var liveGapScheduler = CaptureLiveCoverageGapScheduler()
    @ObservationIgnored private var liveGapTask: Task<Void, Never>?

    static let structuralNudgeAfterSeconds: TimeInterval = 60
    static let nudgeDisplaySeconds: TimeInterval = 4
    static let directionalGapDisplaySeconds: TimeInterval = 15
    static let coverageGapCooldownSeconds: TimeInterval = 30

    static var isSceneReconstructionSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    static var hasMeshClassification: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    /// Binds the guide to the coordinator it observes. Call once, right
    /// after creating the coordinator with this guide.
    func attach(to coordinator: ARCaptureCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - CaptureLiveGuide

    var sessionResetOptions: ARSession.RunOptions { [.resetSceneReconstruction] }

    func configure(_ configuration: ARWorldTrackingConfiguration) {
        if Self.hasMeshClassification {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
    }

    func captureWillBegin() {
        automaticSurfaceSelector.reset()
        lookedAtSurface = nil
        roomOverview.resetRoom()
        coverageTracker = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            ? CaptureCoverageTracker()
            : nil
        resetOverlayRendering()
        structuralReadout = nil
        lastStructuralUpdateAt = 0
        clearRepair()
        meshRevision = 0
        meshAnchors = [:]
        meshAnchorRevisions = [:]
        previewMeshArchive = CaptureMeshPreviewArchive()
        sparsePointCloud.reset()
        committedTrajectory = [:]
        lastContext = nil
    }

    func captureDidEnd() {
        clearRepair()
    }

    func advisories() -> [CaptureGuidanceAdvisory] {
        var result: [CaptureGuidanceAdvisory] = []
        // Structural dwell nudge: sustained scanning, a category that exists
        // in the mesh with no saved coverage, at most once per category.
        if let scanningSeconds = lastContext?.scanningSeconds,
           scanningSeconds >= Self.structuralNudgeAfterSeconds,
           let category = coverageTracker?.structuralSummary.nudgeCandidates()
               .first(where: { $0 == guidanceCategory })
        {
            result.append(
                CaptureGuidanceAdvisory(
                    id: Self.nudgeAdvisoryID(for: category),
                    message: Self.nudgeMessage(for: category),
                    displayLimitSeconds: Self.nudgeDisplaySeconds,
                    isOncePerSession: true
                )
            )
        }
        // One confirmed missing region, never two. Appended last so the
        // once-per-session nudge wins a same-severity tie.
        if let gap = activeRepairTarget ?? liveCoverageGap {
            let isRepairing = activeRepairTarget != nil
            result.append(
                CaptureGuidanceAdvisory(
                    id: Self.gapAdvisoryID(for: gap.category),
                    message: gap.label,
                    displayLimitSeconds: isRepairing ? nil : Self.directionalGapDisplaySeconds,
                    reentryCooldownSeconds: isRepairing ? 0 : Self.coverageGapCooldownSeconds
                )
            )
        }
        return result
    }

    func observe(_ frame: ARFrame, context: CaptureLiveGuideFrameContext) {
        lastContext = context
        observeOverlayCameraHeight(frame)
        updateAutomaticSurfaceSelection(frame, context: context)
        updateGapNavigation(frame)

        let coverageIsPaused = !context.isActivelySampling || !context.isTrackingNormal
            || ProcessInfo.processInfo.thermalState == .critical
        if roomOverview.coverageIsPaused != coverageIsPaused {
            roomOverview.coverageIsPaused = coverageIsPaused
        }
        let previewTarget = eligibleNavigationTarget
        if roomOverview.highlightedGap != previewTarget {
            roomOverview.highlightedGap = previewTarget
        }

        guard context.isActivelySampling else { return }
        updateStructuralSummaryIfDue(frame)
        collectSparseTrackingPoints(from: frame, trackingNormal: context.isTrackingNormal)
    }

    func prepareCommit(of frame: ARFrame) -> (@MainActor (Int) -> Void)? {
        let pose = frame.camera.transform
        // Unproject now; integrate only after the frame commits, so painted
        // means "a saved frame observed this surface".
        var observation: CaptureCoverageObservation?
        if coverageTracker != nil, let sceneDepth = frame.sceneDepth {
            observation = CaptureDepthUnprojector.observation(
                depthMap: sceneDepth.depthMap,
                confidenceMap: sceneDepth.confidenceMap,
                worldFromCamera: pose,
                intrinsics: frame.camera.intrinsics,
                imageWidth: Int(frame.camera.imageResolution.width),
                imageHeight: Int(frame.camera.imageResolution.height),
                timestamp: frame.timestamp
            )
        }
        let depthSample = frame.sceneDepth.flatMap(CaptureDepthSample.init(sceneDepth:))
        let captureID = coordinator?.currentWriterID
        return { [weak self] index in
            guard let self else { return }
            self.committedTrajectory[index] = pose
            self.integrateCoverage(observation)
            if let depthSample, let captureID {
                self.depthRecorder.record(depthSample, captureID: captureID, frameIndex: index)
            }
        }
    }

    func anchorsDidUpdate(_ anchors: [ARAnchor]) {
        let updated = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !updated.isEmpty else { return }
        meshRevision &+= 1
        for anchor in updated {
            previewMeshArchive.remove(id: anchor.identifier)
            meshAnchors[anchor.identifier] = anchor
            meshAnchorRevisions[anchor.identifier] = meshRevision
        }
        requestOverlayRender()
    }

    func anchorsDidRemove(_ anchors: [ARAnchor]) {
        let ids = anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier }
        guard !ids.isEmpty else { return }
        for id in ids {
            // ARKit merges and drops anchors as it refines the mesh; keep
            // their points so the preview never loses scanned surfaces.
            if let removed = meshAnchors.removeValue(forKey: id) {
                previewMeshArchive.retain(
                    id: id,
                    points: CapturePointCloudStore.makePreviewPoints(from: [removed])
                )
            }
            meshAnchorRevisions.removeValue(forKey: id)
        }
        meshRevision &+= 1
        requestOverlayRender()
    }

    // MARK: - Snapshots for the views

    func meshAnchorsSnapshot() -> [UUID: ARMeshAnchor] { meshAnchors }

    func meshAnchorRevisionsSnapshot() -> [UUID: Int] { meshAnchorRevisions }

    var hasPointCloudPreview: Bool {
        if Self.isSceneReconstructionSupported {
            return !previewMeshArchive.chunks.isEmpty
                || meshAnchors.values.contains { $0.geometry.vertices.count > 0 }
        }
        return sparsePointCloud.pointCloud != nil
    }

    var hasTrajectoryPreview: Bool { !committedTrajectory.isEmpty }

    func liveCameraPoseSnapshot() -> simd_float4x4? {
        guard let frame = coordinator?.session.currentFrame,
              frame.camera.trackingState == .normal else { return nil }
        return frame.camera.transform
    }

    func pointCloudPreviewSnapshot() -> CapturePointCloud? {
        if Self.isSceneReconstructionSupported {
            let positions = CapturePointCloudStore.makePreviewPoints(from: Array(meshAnchors.values))
            let retained = previewMeshArchive.previewPoints(active: positions)
            return retained.isEmpty ? nil : CapturePointCloud(positions: retained, source: .lidarMesh)
        }
        return sparsePointCloud.pointCloud
    }

    /// Built directly at the live budget; the finish review uses the denser
    /// `pointCloudPreviewSnapshot()`.
    func livePointCloudSnapshot() -> CapturePointCloud? {
        if Self.isSceneReconstructionSupported {
            let positions = CapturePointCloudStore.makeLivePreviewPoints(
                from: Array(meshAnchors.values),
                archive: previewMeshArchive
            )
            return positions.isEmpty ? nil : CapturePointCloud(positions: positions, source: .lidarMesh)
        }
        return sparsePointCloud.pointCloud?.livePreviewSample(
            limit: CapturePointCloudStore.maxLivePointCount
        )
    }

    func trajectoryPreviewSnapshot() -> CaptureTrajectory {
        CaptureTrajectory(
            arkitWorldFromCamera: committedTrajectory.keys.sorted().compactMap { committedTrajectory[$0] }
        )
    }

    func capturePreviewSnapshot() -> CapturePreview {
        let trajectory = trajectoryPreviewSnapshot()
        var coverage: CaptureCoverageReviewData?
        if let gaps = coverageReviewGaps(), !gaps.isEmpty {
            coverage = CaptureCoverageReviewData(gaps: gaps)
        }
        return CapturePreview(
            pointCloud: pointCloudPreviewSnapshot(),
            trajectory: trajectory.arkitWorldFromCamera.isEmpty ? nil : trajectory,
            coverage: coverage
        )
    }

    // MARK: - Coverage review and repair

    /// Ranked missing regions for the finish review, or nil when there is no
    /// trustworthy coverage to judge (no LiDAR, no classification, too little
    /// saved coverage).
    func coverageReviewGaps() -> [CaptureCoverageGap]? {
        guard let tracker = coverageTracker, Self.hasMeshClassification,
              tracker.voxelCount >= 300, tracker.voxelCount < tracker.maxVoxelCount
        else { return nil }
        let faces = CaptureMeshClassificationExtractor.classifiedFaces(from: Array(meshAnchors.values))
        guard !faces.isEmpty else { return nil }
        // Only regions near where the user walked are reported, so surfaces
        // glimpsed through a doorway never become warnings. Exact-voxel
        // coverage on purpose: neighbor slack erases genuine sub-meter holes.
        return CaptureCoverageGapAnalyzer.rankedGaps(
            faces: faces,
            isCovered: { tracker.voxel(at: $0) != nil },
            cameraPositions: committedCameraPositions
        )
    }

    /// Starts the same-session repair loop with the chosen gap first. The AR
    /// session is unchanged, so targets stay valid world positions.
    func beginRepair(gaps: [CaptureCoverageGap], startingAt index: Int = 0) {
        guard !gaps.isEmpty else { return }
        clearRepair()
        var ordered = gaps
        if gaps.indices.contains(index), index != 0 {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        repairTargets = ordered
        activateRepairTarget(ordered.first)
    }

    func setGuidanceCategory(_ category: CaptureStructuralCategory, restarting: Bool = false) {
        guard restarting || category != guidanceCategory || activeRepairTarget != nil else { return }
        guidanceCategory = category
        roomOverview.layer = switch category {
        case .floor: .floor
        case .ceiling: .ceiling
        case .wall: .room
        }
        // A new pass supersedes the prior repair destination and any
        // in-flight analysis for the old pass.
        clearRepair()
        coordinator?.clearAdvisories()
    }

    /// Clears the repair loop and live gap coaching together; they share the
    /// one emphasis slot.
    func clearRepair() {
        repairTargets = []
        activateRepairTarget(nil)
        liveGapTask?.cancel()
        liveGapTask = nil
        liveGapScheduler.reset()
        liveCoverageGap = nil
        gapNavigator.reset()
        gapNavigation = nil
        lastGapNavigationAt = 0
    }

    /// Emphasize the arbitrated target only once it is on screen; off-screen
    /// targets get an edge arrow instead. Both yield to warnings.
    var coverageEmphasisTarget: CaptureCoverageGap? {
        guard let gapNavigation, gapNavigation.direction == .inView,
              eligibleNavigationTarget != nil else { return nil }
        return gapNavigation.target
    }

    private var eligibleNavigationTarget: CaptureCoverageGap? {
        guard let context = lastContext, context.isActivelySampling, context.isTrackingNormal,
              !context.hasBlockingMessage,
              let target = activeRepairTarget ?? liveCoverageGap,
              context.guidance?.id == CaptureGuidanceArbiter.guidanceID(
                  forAdvisory: Self.gapAdvisoryID(for: target.category)
              )
        else { return nil }
        return target
    }

    private var committedCameraPositions: [SIMD3<Float>] {
        committedTrajectory.values.map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
    }

    private func activateRepairTarget(_ gap: CaptureCoverageGap?) {
        roomOverview.highlightedGap = nil
        gapNavigation = nil
        gapNavigator.reset()
        lastGapNavigationAt = 0
        activeRepairTarget = gap
        repairBaselineVoxelCount = gap.map {
            coverageTracker?.coveredVoxelCount(near: $0.center, radiusM: $0.radiusM) ?? 0
        } ?? 0
    }

    /// Advances the repair loop once the active target gained enough saved
    /// coverage. ~180 voxels/m² at 7.5 cm; ~40% of the gap's area is enough.
    private func checkRepairProgress() {
        guard let target = activeRepairTarget, let tracker = coverageTracker else { return }
        let count = tracker.coveredVoxelCount(near: target.center, radiusM: target.radiusM)
        guard count - repairBaselineVoxelCount >= max(25, Int(target.areaM2 * 70)) else { return }
        repairTargets.removeAll { $0.id == target.id }
        activateRepairTarget(repairTargets.first)
    }

    // MARK: - Live analysis

    private func updateAutomaticSurfaceSelection(_ frame: ARFrame, context: CaptureLiveGuideFrameContext) {
        let pose = frame.camera.transform
        let forward = -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        let detected = lookedAtSurface.flatMap { hint -> CaptureStructuralCategory? in
            let age = frame.timestamp - hint.timestamp
            return age >= 0 && age < 1.5 && simd_dot(hint.forward, forward) > 0.99 ? hint.category : nil
        }
        if let category = automaticSurfaceSelector.update(
            vertical: forward.y,
            detected: detected,
            current: guidanceCategory,
            timestamp: frame.timestamp,
            eligible: !surfaceSelectionSuspended && context.isActivelySampling && context.isTrackingNormal
        ) {
            setGuidanceCategory(category)
        }
    }

    private func updateGapNavigation(_ frame: ARFrame) {
        guard let target = eligibleNavigationTarget,
              let viewport = navigationViewport,
              let orientation = viewport.window?.windowScene?.interfaceOrientation,
              orientation != .unknown, viewport.bounds.width > 0, viewport.bounds.height > 0
        else {
            gapNavigator.reset()
            if gapNavigation != nil { gapNavigation = nil }
            lastGapNavigationAt = 0
            return
        }
        guard frame.timestamp - lastGapNavigationAt >= 0.1 else { return }
        lastGapNavigationAt = frame.timestamp
        let next = gapNavigator.update(
            target: target,
            viewMatrix: frame.camera.viewMatrix(for: orientation),
            projection: frame.camera.projectionMatrix(
                for: orientation, viewportSize: viewport.bounds.size, zNear: 0.01, zFar: 100
            ),
            timestamp: frame.timestamp
        )
        if next != gapNavigation { gapNavigation = next }
    }

    /// Rebuilds the structural summary from classified mesh faces at ~1 Hz
    /// (2 s at `.serious`, frozen at `.critical`).
    private func updateStructuralSummaryIfDue(_ frame: ARFrame) {
        guard let tracker = coverageTracker, Self.hasMeshClassification else { return }
        let interval: TimeInterval
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return
        case .serious: interval = 2
        default: interval = 1
        }
        let now = frame.timestamp
        guard now - lastStructuralUpdateAt >= interval else { return }
        lastStructuralUpdateAt = now

        // Extracted once and shared with live gap analysis: the mesh walk is
        // the expensive half.
        let faces = CaptureMeshClassificationExtractor.classifiedFaces(from: Array(meshAnchors.values))
        let pose = frame.camera.transform
        lookedAtSurface = CaptureAutomaticSurfaceSelector.lookedAtCategory(faces: faces, pose: pose).map {
            ($0, frame.timestamp, -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
        }
        tracker.updateStructuralSummary(faces: faces)
        let summary = tracker.structuralSummary
        let hasStructure = summary.wallsTotal > 0
            || summary.floor.totalAreaM2 > 0
            || summary.ceiling.totalAreaM2 > 0
        let readout = hasStructure ? summary.readoutLine : nil
        if readout != structuralReadout { structuralReadout = readout }
        checkRepairProgress()
        checkLiveGapProgress()
        scheduleLiveGapAnalysisIfDue(now: now, faces: faces, tracker: tracker)
    }

    private func checkLiveGapProgress() {
        guard activeRepairTarget == nil, let gap = liveCoverageGap,
              let tracker = coverageTracker else { return }
        let count = tracker.coveredVoxelCount(near: gap.center, radiusM: gap.radiusM)
        guard count - liveGapBaselineVoxelCount >= max(25, Int(gap.areaM2 * 70)) else { return }
        // Enough new coverage to retire this suggestion, not proof the whole
        // surface is done; another suggestion needs fresh confirmation.
        liveGapTask?.cancel()
        liveGapTask = nil
        liveCoverageGap = nil
        liveGapScheduler.reset()
        roomOverview.highlightedGap = nil
        gapNavigation = nil
        gapNavigator.reset()
    }

    /// Runs the finish review's gap analysis during capture, off the frame
    /// path, and keeps the one confirmed result for coaching. Same filters as
    /// the review: a gap not worth reporting there is not worth interrupting
    /// someone over mid-scan.
    private func scheduleLiveGapAnalysisIfDue(
        now: TimeInterval,
        faces: [CaptureClassifiedFace],
        tracker: CaptureCoverageTracker
    ) {
        // Once evidence storage is full, retire cues too: surfaces that cannot
        // be recorded must not trap the user in a repair loop.
        if tracker.voxelCount >= tracker.maxVoxelCount {
            clearRepair()
            return
        }
        guard activeRepairTarget == nil, lastContext?.isActivelySampling == true,
              liveGapTask == nil,
              tracker.voxelCount >= 300, !faces.isEmpty,
              liveGapScheduler.shouldAnalyze(at: now, scanningSeconds: lastContext?.scanningSeconds ?? 0)
        else { return }

        let snapshot = CaptureCoverageVoxelSnapshot(tracker: tracker, faces: faces)
        let cameraPositions = committedCameraPositions
        let category = guidanceCategory
        liveGapTask = Task.detached(priority: .utility) { [weak self] in
            let gaps = CaptureCoverageGapAnalyzer.rankedGaps(
                faces: faces,
                isCovered: snapshot.isCovered(_:),
                cameraPositions: cameraPositions,
                categoryFilter: category
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled, let self, self.guidanceCategory == category else { return }
                self.liveGapTask = nil
                let selected = self.liveGapScheduler.select(from: gaps)
                // Keep a nearby target fixed while guiding toward it; a
                // shifting mesh centroid must not move the destination.
                if let previous = self.liveCoverageGap, let selected,
                   previous.category == selected.category,
                   simd_distance(previous.center, selected.center) <= 1 { return }
                self.liveCoverageGap = selected
                self.liveGapBaselineVoxelCount = selected.map {
                    self.coverageTracker?.coveredVoxelCount(near: $0.center, radiusM: $0.radiusM) ?? 0
                } ?? 0
            }
        }
    }

    private func collectSparseTrackingPoints(from frame: ARFrame, trackingNormal: Bool) {
        guard !Self.isSceneReconstructionSupported, trackingNormal,
              let rawFeaturePoints = frame.rawFeaturePoints else { return }
        let pose = frame.camera.transform
        sparsePointCloud.observe(
            points: rawFeaturePoints.points,
            cameraPosition: SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
            timestamp: frame.timestamp
        )
    }

    // MARK: - Overlay cadence

    private func integrateCoverage(_ observation: CaptureCoverageObservation?) {
        guard let observation, let tracker = coverageTracker else { return }
        CaptureCoverageCommitPolicy.integrate(
            observation,
            into: tracker,
            thermalState: ProcessInfo.processInfo.thermalState
        )
        requestOverlayRender()
    }

    private func observeOverlayCameraHeight(_ frame: ARFrame) {
        guard !meshAnchors.isEmpty else { return }
        let cell = Int32((frame.camera.transform.columns.3.y / 0.5).rounded(.down))
        guard cell != overlayCameraHeightCell else { return }
        overlayCameraHeightCell = cell
        requestOverlayRender()
    }

    private func resetOverlayRendering() {
        overlayRenderTask?.cancel()
        overlayRenderTask = nil
        lastOverlayRenderAt = -.greatestFiniteMagnitude
        overlayCameraHeightCell = nil
        overlayRevision = 0
    }

    private func requestOverlayRender(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let interval = CaptureOverlayRenderCadence.minimumInterval(for: ProcessInfo.processInfo.thermalState)
        let delay = max(0, interval - (now - lastOverlayRenderAt))
        if delay == 0 {
            overlayRenderTask?.cancel()
            overlayRenderTask = nil
            publishOverlayRender(at: now)
            return
        }
        guard overlayRenderTask == nil else { return }
        overlayRenderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.overlayRenderTask = nil
            self.publishOverlayRender(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func publishOverlayRender(at now: TimeInterval) {
        lastOverlayRenderAt = now
        overlayRevision &+= 1
    }

    // MARK: - Advisory ids

    static func gapAdvisoryID(for category: CaptureStructuralCategory) -> String {
        "coverage-gap-\(category.rawValue)"
    }

    static func nudgeAdvisoryID(for category: CaptureStructuralCategory) -> String {
        "nudge-\(category.rawValue)"
    }

    private static func nudgeMessage(for category: CaptureStructuralCategory) -> String {
        switch category {
        case .ceiling: "Don't forget the ceiling"
        case .floor: "Don't forget the floor"
        case .wall: "Don't forget the walls"
        }
    }
}
