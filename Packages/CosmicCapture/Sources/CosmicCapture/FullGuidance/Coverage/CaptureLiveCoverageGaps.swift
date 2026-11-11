import Foundation
import simd

/// Sendable, exact-voxel coverage lookup so gap clustering can run off the
/// main actor.
///
/// Holds only the covered voxel keys that the classified faces of this pass
/// actually land in, so the snapshot is bounded by face count rather than by
/// the whole (up to 300 000 voxel) map. Coverage stays *exact voxel* with no
/// neighbor dilation — the same choice `coverageReviewGaps()` documents, for
/// the same measured reason: 26-neighbor slack read 98.5% of mesh points as
/// covered and erased genuine sub-meter holes.
struct CaptureCoverageVoxelSnapshot: Sendable {
    private let voxelSizeM: Float
    private let coveredKeys: Set<CaptureCoverageTracker.VoxelKey>

    init(tracker: CaptureCoverageTracker, faces: [CaptureClassifiedFace]) {
        voxelSizeM = tracker.voxelSizeM
        var keys: Set<CaptureCoverageTracker.VoxelKey> = []
        keys.reserveCapacity(faces.count)
        for face in faces {
            let key = tracker.key(for: face.center)
            if tracker.voxel(at: face.center) != nil { keys.insert(key) }
        }
        coveredKeys = keys
    }

    func isCovered(_ position: SIMD3<Float>) -> Bool {
        coveredKeys.contains(
            CaptureCoverageTracker.VoxelKey(
                x: Int32((position.x / voxelSizeM).rounded(.down)),
                y: Int32((position.y / voxelSizeM).rounded(.down)),
                z: Int32((position.z / voxelSizeM).rounded(.down))
            )
        )
    }
}

/// Decides when live gap analysis runs and which single gap may be coached.
///
/// Coverage Review asks "what did this scan miss?". Live, the honest question
/// is narrower — "what has this scan missed *so far*?" — because mid-scan most
/// uncovered surface is simply not-yet-visited rather than a hole. That
/// difference is absorbed here by *tightening*, never by relaxing the
/// analyzer's filters, which keep their measured on-device defaults:
///
///  - analysis runs a few times a minute, not on the frame path: clustering is
///    world-space and room-scale, so more often buys no extra truth,
///  - a region must read uncovered on `confirmationCount` consecutive passes
///    before it can be coached, so "haven't walked there yet" decays into
///    silence on its own instead of becoming a warning,
///  - only one gap is ever surfaced, and the choice is sticky, so the pill
///    does not alternate between two regions.
///
/// Time comes from the caller; no wall clock inside.
struct CaptureLiveCoverageGapScheduler: Sendable {
    struct Policy: Sendable {
        /// Gap clustering cadence. Clustering is world-space and room-scale,
        /// so running it more often buys no extra truth — only frame budget.
        var minimumIntervalSeconds: TimeInterval = 12
        /// No coaching until the scan has run long enough that "uncovered"
        /// can mean something other than "just started".
        var warmupSeconds: TimeInterval = 20
        /// Consecutive passes a region must persist before it is coachable.
        var confirmationCount = 2
        /// How far a gap centroid may drift between passes and still count as
        /// the same region. Gap centroids are area-weighted, so a growing
        /// cluster shifts a little even when the hole itself has not moved.
        var matchRadiusM: Float = 1.0

        init() {}
    }

    private struct Observation {
        var center: SIMD3<Float>
        var streak: Int
    }

    private let policy: Policy
    private var lastAnalysisAt: TimeInterval?
    private var observations: [CaptureStructuralCategory: Observation] = [:]
    private var selectedCategory: CaptureStructuralCategory?

    init(policy: Policy = Policy()) {
        self.policy = policy
    }

    mutating func reset() {
        lastAnalysisAt = nil
        observations = [:]
        selectedCategory = nil
    }

    /// Consumes the throttle slot. Returns true at most once per interval, so
    /// callers must only call this when they are ready to run the analysis.
    mutating func shouldAnalyze(
        at now: TimeInterval,
        scanningSeconds: TimeInterval
    ) -> Bool {
        guard scanningSeconds >= policy.warmupSeconds else { return false }
        guard let last = lastAnalysisAt else {
            lastAnalysisAt = now
            return true
        }
        guard now - last >= policy.minimumIntervalSeconds else { return false }
        lastAnalysisAt = now
        return true
    }

    /// Folds one analysis result into the confirmation state and returns the
    /// single gap that may be coached, if any.
    mutating func select(
        from gaps: [CaptureCoverageGap]
    ) -> CaptureCoverageGap? {
        var next: [CaptureStructuralCategory: Observation] = [:]
        for gap in gaps where next[gap.category] == nil {
            let previous = observations[gap.category]
            let isSameRegion = previous.map {
                simd_distance($0.center, gap.center) <= policy.matchRadiusM
            } ?? false
            next[gap.category] = Observation(
                center: gap.center,
                streak: isSameRegion ? (previous?.streak ?? 0) + 1 : 1
            )
        }
        observations = next

        let confirmed = gaps.filter {
            (next[$0.category]?.streak ?? 0) >= policy.confirmationCount
        }
        guard let best = confirmed.first else {
            selectedCategory = nil
            return nil
        }
        // Stickiness: keep coaching the region already on screen while it is
        // still confirmed, so a near-tie in ranking cannot flip the message
        // back and forth.
        if let selectedCategory,
           let sticky = confirmed.first(where: { $0.category == selectedCategory })
        {
            return sticky
        }
        selectedCategory = best.category
        return best
    }
}
