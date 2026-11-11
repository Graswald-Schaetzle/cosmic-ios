import Foundation
import SceneKit
import simd
import Testing
@testable import CosmicCapture

@Suite("CapturePointCloudStore")
struct CapturePointCloudStoreTests {
    @Test("Retired mesh retains exact vertices without grid conversion")
    func retainsOriginalMeshVertices() {
        var archive = CaptureMeshPreviewArchive()
        let id = UUID()
        let earlier = [SIMD3<Float>(-4.123, 1.234, -5.678)]
        let recent = [SIMD3<Float>(2.123, 0.456, 3.789)]
        #expect(archive.previewPoints(active: recent) == recent)
        archive.retain(id: id, points: earlier)
        #expect(archive.previewPoints(active: recent) == earlier + recent)
        archive.remove(id: id)
        #expect(archive.previewPoints(active: recent) == recent)
    }

    @Test("Archive bounds retain samples from earlier and later regions")
    func archiveSamplesOriginalCoordinatesAcrossRegions() {
        var archive = CaptureMeshPreviewArchive()
        archive.pointLimit = 10
        let left = (0..<10).map { SIMD3<Float>(Float($0) * 0.01, 0, 0) }
        let right = (0..<10).map { SIMD3<Float>(Float($0) * 0.01 + 10, 0, 0) }
        archive.retain(id: UUID(), points: left)
        archive.retain(id: UUID(), points: right)
        let points = archive.previewPoints(active: [])
        #expect(points.count == 10)
        #expect(points.allSatisfy { (left + right).contains($0) })
        #expect(points.contains { $0.x < 1 })
        #expect(points.contains { $0.x > 9 })
    }
}

@Suite("Sparse tracking point collection")
struct CaptureSparsePointCloudAccumulatorTests {
    @Test("Samples, deduplicates and rejects unsafe points")
    func samplingAndValidation() {
        var accumulator = CaptureSparsePointCloudAccumulator()
        var denseObservation: [SIMD3<Float>] = []
        denseObservation.reserveCapacity(1_002)
        for index in 0..<1_000 {
            let point = SIMD3<Float>(
                Float(index % 20) * 0.04,
                Float((index / 20) % 10) * 0.04,
                Float(index / 200) * 0.04
            )
            denseObservation.append(point)
        }
        denseObservation.append(SIMD3<Float>(.nan, 0, 0))
        denseObservation.append(SIMD3<Float>(13, 0, 0))

        accumulator.observe(
            points: denseObservation,
            cameraPosition: .zero,
            timestamp: 1
        )
        let firstCount = accumulator.pointCloud?.positions.count ?? 0
        accumulator.observe(
            points: denseObservation,
            cameraPosition: .zero,
            timestamp: 1.1
        )
        accumulator.observe(
            points: denseObservation,
            cameraPosition: .zero,
            timestamp: 1.3
        )

        #expect(firstCount <= CaptureSparsePointCloudAccumulator.maxPointsPerObservation)
        #expect(accumulator.pointCloud?.positions.count == firstCount)
        #expect(accumulator.pointCloud?.source == .trackingFeatures)
        #expect(
            accumulator.pointCloud?.positions.allSatisfy {
                $0.x.isFinite && simd_length($0) <= 12
            } == true
        )
    }

    @Test("Collection is capped and reset clears its lifecycle")
    func capAndReset() {
        var accumulator = CaptureSparsePointCloudAccumulator()
        var localPoints: [SIMD3<Float>] = []
        localPoints.reserveCapacity(250)
        for index in 0..<250 {
            let point = SIMD3<Float>(
                Float(index % 10) * 0.04,
                Float((index / 10) % 5) * 0.04,
                Float(index / 50) * 0.04
            )
            localPoints.append(point)
        }

        for observationIndex in 0..<140 {
            let offset = SIMD3<Float>(
                Float(observationIndex) * 0.5,
                0,
                0
            )
            accumulator.observe(
                points: localPoints.map { $0 + offset },
                cameraPosition: offset,
                timestamp: Double(observationIndex)
            )
        }

        #expect(
            accumulator.pointCloud?.positions.count
                == CaptureSparsePointCloudAccumulator.maxPointCount
        )
        accumulator.reset()
        #expect(accumulator.pointCloud == nil)
    }
}

@Suite("Live preview budget")
struct CaptureLivePreviewBudgetTests {
    @Test("Review caps are unchanged by the live-display budget")
    func reviewCapsUnchanged() {
        #expect(CapturePointCloudStore.maxPointCount == 150_000)
        #expect(CapturePointCloudStore.maxSparsePointCount == 30_000)
        #expect(CapturePointCloudStore.maxLivePointCount == 15_000)
    }

    @Test("Live sampling hits the budget and represents archived chunks proportionally")
    func budgetAndFairness() {
        var archive = CaptureMeshPreviewArchive()
        // Distinct markers per chunk: A has z == 0, B has z == 1.
        let chunkA = (1...60_000).map { SIMD3<Float>(Float($0), 0, 0) }
        let chunkB = (1...30_000).map { SIMD3<Float>(0, Float($0), 1) }
        archive.retain(id: UUID(), points: chunkA)
        archive.retain(id: UUID(), points: chunkB)

        let points = CapturePointCloudStore.makeLivePreviewPoints(
            from: [],
            archive: archive,
            limit: 15_000
        )

        // 90k points with a 15k budget give a stride of 6: exactly 10k from
        // the 60k chunk and 5k from the 30k chunk, in either chunk order.
        #expect(points.count == 15_000)
        let fromA = points.filter { $0.z == 0 }.count
        let fromB = points.filter { $0.z == 1 }.count
        #expect(fromA == 10_000)
        #expect(fromB == 5_000)
    }

    @Test("Live sampling of nothing is empty, and small clouds pass through")
    func emptyAndSmallInputs() {
        #expect(
            CapturePointCloudStore.makeLivePreviewPoints(
                from: [],
                archive: CaptureMeshPreviewArchive()
            ).isEmpty
        )

        var archive = CaptureMeshPreviewArchive()
        let small = (1...100).map { SIMD3<Float>(Float($0), 0, 0) }
        archive.retain(id: UUID(), points: small)
        let points = CapturePointCloudStore.makeLivePreviewPoints(
            from: [],
            archive: archive
        )
        #expect(points == small)
    }
}

@Suite("Paint render state gating")
@MainActor
struct CapturePaintRenderStateTests {
    @Test("Rendering records the state; changed inputs and reset invalidate it")
    func renderStateLifecycle() {
        let container = CaptureARViewContainer.Coordinator()
        #expect(container.lastPaintRenderState == nil)

        let capture = CaptureCoverageGuide()
        let overlayRoot = SCNNode()
        let state = CaptureARViewContainer.Coordinator.PaintRenderState(
            renderRevision: 1,
            mode: .camera,
            emphasis: nil
        )
        container.renderPaintOverlay(
            from: capture,
            into: overlayRoot,
            state: state
        )
        #expect(container.lastPaintRenderState == state)

        // Coalesced work, a mode flip, or a new emphasis region must each
        // read as changed so the overlay re-renders.
        var revisionChanged = state
        revisionChanged.renderRevision = 2
        #expect(container.lastPaintRenderState != revisionChanged)
        var modeChanged = state
        modeChanged.mode = .model
        #expect(container.lastPaintRenderState != modeChanged)
        var emphasisChanged = state
        emphasisChanged.emphasis = CaptureMeshOverlay.EmphasisRegion(
            center: SIMD3(1, 0, 0),
            radiusM: 0.5
        )
        #expect(container.lastPaintRenderState != emphasisChanged)

        // Hiding or recreating the overlay root clears the memory so the next
        // update performs a full render even at unchanged revisions.
        container.resetPaintRenderState()
        #expect(container.lastPaintRenderState == nil)
    }
}

@Suite("Capture mesh overlay freshness")
struct CaptureMeshOverlayFreshnessTests {
    @Test("Anchor callback revisions restart freshness without object identity")
    @MainActor
    func revisionDrivenFreshness() {
        let coordinator = CaptureARViewContainer.Coordinator()
        let anchorID = UUID()
        let liveAnchorIDs: Set<UUID> = [anchorID]

        let initial = coordinator.refreshFreshAnchorIDs(
            among: liveAnchorIDs,
            revisions: [anchorID: 1],
            now: 10
        )
        let expired = coordinator.refreshFreshAnchorIDs(
            among: liveAnchorIDs,
            revisions: [anchorID: 1],
            now: 12
        )
        let updated = coordinator.refreshFreshAnchorIDs(
            among: liveAnchorIDs,
            revisions: [anchorID: 2],
            now: 12
        )

        #expect(initial == [anchorID])
        #expect(expired.isEmpty)
        #expect(updated == [anchorID])
    }
}
