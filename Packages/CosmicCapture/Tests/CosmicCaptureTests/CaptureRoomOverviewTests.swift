import Foundation
import Testing
import simd
@testable import CosmicCapture

struct CaptureRoomOverviewTests {
    @Test @MainActor func partialAndRestartedRoomSnapshotsPreserveWalls() {
        let overview = CaptureRoomOverview()
        overview.configureFixture()
        let original = overview.surfaces
        overview.mergeLayout([])
        #expect(overview.surfaces.count == original.count)
        overview.mergeLayout([original[0]])
        #expect(overview.surfaces.count == original.count)
        #expect(overview.outline.edges.count == 4)
        let replacement = CaptureRoomSurface(id: UUID(), transform: original[0].transform,
            dimensions: original[0].dimensions, kind: original[0].kind)
        overview.mergeLayout([replacement])
        #expect(overview.surfaces.count == original.count)
        #expect(overview.surfaces.contains { $0.id == replacement.id })
        overview.stop()
        overview.layer = .floor
        overview.layer = .room
        #expect(overview.outline.edges.count == 4)
        overview.mergeLayout([], removing: [replacement.id])
        #expect(overview.outline.edges.count == 3)
        overview.resetRoom()
        #expect(overview.surfaces.isEmpty)
        #expect(overview.outline.edges.isEmpty)
    }

    @Test func wallEndpointsRespectWorldTransform() {
        var transform = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        transform.columns.3 = SIMD4(3, 1.5, -4, 1)
        let edge = CaptureRoomOutline.edge(transform: transform, width: 4, opening: false)
        #expect(simd_distance(edge.start, SIMD2(3, -2)) < 0.001)
        #expect(simd_distance(edge.end, SIMD2(3, -6)) < 0.001)
        #expect(!edge.opening)
    }

    @Test @MainActor func previewDefaultsToEnabledAndHidingRetainsEvidence() {
        let overview = CaptureRoomOverview()
        #expect(overview.isEnabled)
        overview.configureFixture()
        #expect(overview.outline.edges.count == 4)
        #expect(overview.surfaces.count == 4)
        #expect(overview.surfaces.allSatisfy { $0.dimensions.y == 2.8 })
        #expect(overview.cameraTransform.columns.3.y == 1.5)
        overview.resetRoom()
        #expect(overview.outline.edges.isEmpty)
        #expect(overview.surfaces.isEmpty)
        #expect(overview.isEnabled)
        overview.configureFixture()
        overview.isEnabled = false
        #expect(!overview.outline.edges.isEmpty)
        #expect(!overview.surfaces.isEmpty)
        #expect(!overview.patches.isEmpty)
    }

    @Test func nonRectangularFloorPreservesItsPolygon() {
        let corners: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(3, 0, 0), SIMD3(3, 1, 0),
                                      SIMD3(1, 1, 0), SIMD3(1, 3, 0), SIMD3(0, 3, 0)]
        let surface = CaptureRoomSurface(id: UUID(), transform: matrix_identity_float4x4,
            dimensions: SIMD3(3, 3, 0), kind: .floor, polygonCorners: corners)
        #expect(surface.localCorners == corners)
    }

}

struct CaptureFinishCompletenessTests {
    private func room(_ offset: Float = 0) -> [CaptureRoomOutline.Edge] {
        let p: [SIMD2<Float>] = [SIMD2(offset, 0), SIMD2(offset + 4, 0), SIMD2(offset + 4, 4), SIMD2(offset, 4)]
        return (0..<4).map { .init(start: p[$0], end: p[($0 + 1) % 4], opening: false) }
    }
    private func saved(_ offset: Float = 0) -> [CaptureSurfacePatch] {
        var result: [CaptureSurfacePatch] = []
        for category in [CaptureStructuralCategory.floor, .ceiling] {
            for x in 0..<10 {
                for z in 0..<10 {
                    let center = SIMD3<Float>(offset + Float(x) * 0.4 + 0.2,
                        category == .floor ? 0 : 3, Float(z) * 0.4 + 0.2)
                    result.append(CaptureSurfacePatch(center: center, normal: SIMD3(0, 1, 0),
                        size: 0.2, category: category, evidence: .singleView))
                }
            }
        }
        return result
    }

    @Test func reviewIgnoresLayoutOnlyIssuesButKeepsMeasuredGaps() {
        #expect(CaptureFinishCompleteness.reviewIssues([.wallConnections, .ceilingCoverage], gaps: []).isEmpty)
        let gap = CaptureCoverageGap(id: 0, category: .wall, center: .zero, radiusM: 0.5, areaM2: 1, label: "Wall")
        #expect(CaptureFinishCompleteness.reviewIssues([.wallConnections], gaps: [gap]) == [.wallCoverage])
    }

    @Test func fullyObservedRoomHasNoAdvisory() {
        #expect(CaptureFinishCompleteness.message(outline: .init(edges: room()),
            patches: saved(), coverageAvailable: true) == nil)
    }
    @Test func openWallsRemainUnknownWithoutMeasuredGaps() {
        let message = CaptureFinishCompleteness.message(outline: .init(edges: Array(room().prefix(3))),
            patches: [], coverageAvailable: true)
        #expect(message == nil)
    }
    @Test func detectedOpeningBridgesWallEnds() {
        var edges = room()
        edges[0] = .init(start: SIMD2(0, 0), end: SIMD2(1, 0), opening: false)
        edges += [.init(start: SIMD2(1, 0), end: SIMD2(3, 0), opening: true),
                  .init(start: SIMD2(3, 0), end: SIMD2(4, 0), opening: false)]
        #expect(CaptureFinishCompleteness.message(outline: .init(edges: edges),
            patches: saved(), coverageAvailable: true) == nil)
    }
    @Test func closedRoomWithoutCeilingEvidenceDoesNotInventCeiling() {
        let message = CaptureFinishCompleteness.message(outline: .init(edges: room()),
            patches: saved().filter { $0.category == .floor }, coverageAvailable: true)
        #expect(message == nil)
    }
    @Test func unavailableOrLimitedCoverageIsNotMissingCoverage() {
        #expect(CaptureFinishCompleteness.message(outline: .init(edges: room()),
            patches: [], coverageAvailable: false) == nil)
        #expect(CaptureFinishCompleteness.message(outline: .init(),
            patches: [], coverageAvailable: true) == nil)
    }
    @Test func separateRoomsDoNotCountSpaceBetweenThemAsMissing() {
        #expect(CaptureFinishCompleteness.message(outline: .init(edges: room() + room(10)),
            patches: saved() + saved(10), coverageAvailable: true) == nil)
    }
    @Test func windowsOverWallsDoNotInventFloorBetweenSeparateRooms() {
        var edges = room() + room(20)
        edges.append(.init(start: SIMD2(4, 1), end: SIMD2(4, 3), opening: true))
        edges.append(.init(start: SIMD2(20, 1), end: SIMD2(20, 3), opening: true))
        #expect(CaptureFinishCompleteness.message(outline: .init(edges: edges),
            patches: saved() + saved(20), coverageAvailable: true) == nil)
    }

    @Test func fewCentralPatchesDoNotDefineScanIntent() {
        let message = CaptureFinishCompleteness.message(outline: .init(edges: room()),
            patches: saved().filter { $0.center.x > 1.5 && $0.center.x < 2.5 }, coverageAvailable: true)
        #expect(message == nil)
    }
}
