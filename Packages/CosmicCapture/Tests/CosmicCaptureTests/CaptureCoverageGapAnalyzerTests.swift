import Foundation
import simd
import Testing
@testable import CosmicCapture

@Suite("CaptureCoverageGapAnalyzer")
struct CaptureCoverageGapAnalyzerTests {
    // These cases isolate clustering/ranking. Boundary-support
    // filtering is exercised separately below with actual surrounded holes.
    private func rawGaps(faces: [CaptureClassifiedFace], isCovered: (SIMD3<Float>) -> Bool,
                         cameraPositions: [SIMD3<Float>] = [], categoryFilter: CaptureStructuralCategory? = nil,
                         policy: CaptureCoverageGapAnalyzer.Policy = .init()) -> [CaptureCoverageGap] {
        var clustering = policy
        clustering.requiresCoveredBoundary = false
        clustering.minUncoveredFraction = 0.5
        return CaptureCoverageGapAnalyzer.rankedGaps(faces: faces, isCovered: isCovered,
            cameraPositions: cameraPositions, categoryFilter: categoryFilter, policy: clustering)
    }

    @Test func warningsRequireASurroundedHoleNearTheScan() {
        let faces = patch(category: .floor, y: 0, xRange: -4...4, zRange: -4...4,
                          spacing: 0.5, areaPerFace: 0.25)
        let path = [SIMD3<Float>(0, 1, 0)]
        let hole: (SIMD3<Float>) -> Bool = { abs($0.x) > 0.5 || abs($0.z) > 0.5 }
        let gaps = CaptureCoverageGapAnalyzer.rankedGaps(faces: faces, isCovered: hole, cameraPositions: path)
        #expect(gaps.count == 1)
        #expect(CaptureCoverageGapAnalyzer.rankedGaps(faces: faces, isCovered: { _ in false }, cameraPositions: path).isEmpty)
        #expect(CaptureCoverageGapAnalyzer.rankedGaps(faces: faces, isCovered: { $0.x < 0 }, cameraPositions: path).isEmpty)
        #expect(CaptureCoverageGapAnalyzer.rankedGaps(faces: faces, isCovered: hole).isEmpty)
        #expect(CaptureCoverageGapAnalyzer.rankedGaps(faces: faces, isCovered: hole, cameraPositions: [SIMD3(12, 1, 0)]).isEmpty)
        #expect(CaptureCoverageGapAnalyzer.rankedGaps(faces: faces, isCovered: { _ in true }, cameraPositions: path).isEmpty)
    }

    @Test func rotatedWallHoleUsesSurfacePlane() {
        let rotation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0,1,0))
        let faces = (-4...4).flatMap { x in (-4...4).map { y in
            CaptureClassifiedFace(center: rotation.act(SIMD3<Float>(Float(x)*0.5, Float(y)*0.5, 0)),
                normal: rotation.act(SIMD3(0,0,1)), areaM2: 0.25, category: .wall)
        }}
        let gaps = CaptureCoverageGapAnalyzer.rankedGaps(faces: faces, isCovered: { point in
            let local = rotation.inverse.act(point)
            return abs(local.x) > 0.6 || abs(local.y) > 0.6
        }, cameraPositions: [SIMD3(0,0,1)])
        #expect(gaps.count == 1)
    }

    @Test func ceilingAndWallHolesNeedSameSurfaceSupport() {
        for category in [CaptureStructuralCategory.ceiling, .wall] {
            let faces = (-4...4).flatMap { a in (-4...4).map { b in
                CaptureClassifiedFace(center: category == .wall ? SIMD3<Float>(Float(a)*0.5, Float(b)*0.5, 0)
                    : SIMD3<Float>(Float(a)*0.5, 2.5, Float(b)*0.5),
                    normal: category == .wall ? SIMD3(0, 0, 1) : SIMD3(0, -1, 0), areaM2: 0.25, category: category)
            }}
            let covered: (SIMD3<Float>) -> Bool = { abs($0.x) > 0.5 || abs(category == .wall ? $0.y : $0.z) > 0.5 }
            #expect(CaptureCoverageGapAnalyzer.rankedGaps(faces: faces, isCovered: covered,
                cameraPositions: [SIMD3(0, 1, 1)]).count == 1)
            let opposite = faces.map { CaptureClassifiedFace(center: $0.center, normal: -$0.normal, areaM2: $0.areaM2, category: $0.category) }
            #expect(CaptureCoverageGapAnalyzer.rankedGaps(faces: faces + opposite, isCovered: covered,
                cameraPositions: [SIMD3(0, 1, 1)]).isEmpty)
        }
    }

    private func face(
        _ x: Float,
        _ y: Float,
        _ z: Float,
        area: Float = 0.3,
        category: CaptureStructuralCategory,
        normal: SIMD3<Float> = SIMD3(0, 1, 0)
    ) -> CaptureClassifiedFace {
        CaptureClassifiedFace(
            center: SIMD3(x, y, z),
            normal: normal,
            areaM2: area,
            category: category
        )
    }

    /// A patch of same-category faces spread over a region.
    private func patch(
        category: CaptureStructuralCategory,
        y: Float,
        xRange: ClosedRange<Int>,
        zRange: ClosedRange<Int>,
        spacing: Float = 0.25,
        areaPerFace: Float = 0.3
    ) -> [CaptureClassifiedFace] {
        var faces: [CaptureClassifiedFace] = []
        for xi in xRange {
            for zi in zRange {
                faces.append(
                    face(
                        Float(xi) * spacing,
                        y,
                        Float(zi) * spacing,
                        area: areaPerFace,
                        category: category
                    )
                )
            }
        }
        return faces
    }

    @Test("An uncovered ceiling patch becomes one ranked gap")
    func singleGap() {
        let faces = patch(category: .ceiling, y: 2.5, xRange: 0...4, zRange: 0...4)
            + patch(category: .floor, y: 0, xRange: 0...4, zRange: 0...4)

        let gaps = rawGaps(
            faces: faces,
            isCovered: { $0.y < 1 }  // floor covered, ceiling not
        )

        #expect(gaps.count == 1)
        #expect(gaps.first?.category == .ceiling)
        #expect(gaps.first?.label == "Possible gap in the ceiling")
        #expect(abs((gaps.first?.center.y ?? 0) - 2.5) < 0.01)
    }

    @Test("Current pass filters before large ceiling gaps consume the ranking budget")
    func passFilterPrecedesRanking() {
        let faces = patch(category: .ceiling, y: 2.5, xRange: 0...5, zRange: 0...5)
            + patch(category: .ceiling, y: 2.5, xRange: 15...20, zRange: 0...5)
            + patch(category: .wall, y: 1, xRange: 0...1, zRange: 0...1)
            + patch(category: .floor, y: 0, xRange: 0...1, zRange: 0...1)
        let global = rawGaps(faces: faces, isCovered: { _ in false })
        #expect(global.count == 2)
        #expect(global.allSatisfy { $0.category == .ceiling })
        for category in [CaptureStructuralCategory.wall, .floor, .ceiling] {
            let focused = rawGaps(
                faces: faces, isCovered: { _ in false }, categoryFilter: category
            )
            #expect(!focused.isEmpty)
            #expect(focused.allSatisfy { $0.category == category })
        }
    }

    @Test("Small uncovered fragments are filtered as noise")
    func smallComponentsFiltered() {
        // One 0.25 m² face is below the 0.3 m² minimum.
        let faces = [face(0, 2.5, 0, area: 0.25, category: .ceiling)]
        let gaps = rawGaps(
            faces: faces,
            isCovered: { _ in false }
        )
        #expect(gaps.isEmpty)
    }

    @Test("Sampling speckle never forms a gap; a real hole in it does")
    func speckleFiltered() throws {
        // Depth-sampling sparsity: every cell partially uncovered (~25%,
        // uncovered where both grid indices are odd). Total uncovered area
        // is large (~12 m²), but no cell is *mostly* uncovered, so nothing
        // may be reported — this is the pattern that used to chain into a
        // room-sized phantom gap.
        let speckle = patch(
            category: .ceiling, y: 2.5, xRange: 0...12, zRange: 0...12
        )
        func sparseCovered(_ center: SIMD3<Float>) -> Bool {
            let xi = Int((center.x / 0.25).rounded())
            let zi = Int((center.z / 0.25).rounded())
            return xi % 2 == 0 || zi % 2 == 0
        }
        let none = rawGaps(
            faces: speckle,
            isCovered: sparseCovered
        )
        #expect(none.isEmpty)

        // The same scene with a fully uncovered 0.75 × 0.75 m hole: only the
        // hole is reported.
        let holeRange: ClosedRange<Float> = 1.0...1.75
        let gaps = rawGaps(
            faces: speckle,
            isCovered: { center in
                if holeRange.contains(center.x), holeRange.contains(center.z) {
                    return false
                }
                return sparseCovered(center)
            }
        )
        #expect(gaps.count == 1)
        let gap = try #require(gaps.first)
        #expect(gap.category == .ceiling)
        #expect(abs(gap.center.x - 1.375) < 0.5)
        #expect(abs(gap.center.z - 1.375) < 0.5)
    }

    @Test("At most the two highest-value gaps are reported, largest first")
    func rankedAndCapped() {
        // Three well-separated uncovered patches with distinct areas.
        let big = patch(
            category: .ceiling, y: 2.5, xRange: 0...5, zRange: 0...5
        )
        let medium = patch(
            category: .floor, y: 0, xRange: 40...43, zRange: 40...43
        )
        let small = patch(
            category: .wall, y: 1, xRange: 80...81, zRange: 80...81
        )

        let gaps = rawGaps(
            faces: big + medium + small,
            isCovered: { _ in false }
        )

        #expect(gaps.count == 2)
        #expect(gaps[0].category == .ceiling)
        #expect(gaps[1].category == .floor)
        #expect(gaps[0].areaM2 > gaps[1].areaM2)
        #expect(gaps[0].id == 0)
        #expect(gaps[1].id == 1)
    }

    @Test("Adjacent cells merge into one gap across cell boundaries")
    func mergesAcrossCells() {
        // A strip 3 m long crosses several 0.5 m cells; still one gap.
        let faces = patch(category: .ceiling, y: 2.5, xRange: 0...12, zRange: 0...1)
        let gaps = rawGaps(
            faces: faces,
            isCovered: { _ in false }
        )
        #expect(gaps.count == 1)
    }

    @Test("Different categories never merge into one gap")
    func categoriesStaySeparate() {
        // Floor and ceiling patches at the same x/z; distinct gaps.
        let faces = patch(category: .floor, y: 0, xRange: 0...4, zRange: 0...4)
            + patch(category: .ceiling, y: 0.4, xRange: 0...4, zRange: 0...4)
        let gaps = rawGaps(
            faces: faces,
            isCovered: { _ in false }
        )
        #expect(gaps.count == 2)
        #expect(Set(gaps.map(\.category)) == [.floor, .ceiling])
    }

    @Test("Gap radius covers the cluster footprint")
    func radiusCoversFootprint() {
        let faces = patch(category: .ceiling, y: 2.5, xRange: 0...8, zRange: 0...8)
        let gaps = rawGaps(
            faces: faces,
            isCovered: { _ in false }
        )
        let gap = gaps[0]
        // Farthest face corner from the weighted center must fall inside.
        for face in faces {
            #expect(simd_distance(face.center, gap.center) <= gap.radiusM)
        }
    }

    @Test("Wall labels reflect vertical position; semantics stay modest")
    func wallLabels() {
        #expect(
            CaptureCoverageGapAnalyzer.regionName(
                for: .wall, centerY: 2.2, sceneMinY: 0, sceneMaxY: 2.5
            ) == "Upper wall"
        )
        #expect(
            CaptureCoverageGapAnalyzer.regionName(
                for: .wall, centerY: 0.3, sceneMinY: 0, sceneMaxY: 2.5
            ) == "Lower wall"
        )
        #expect(
            CaptureCoverageGapAnalyzer.regionName(
                for: .wall, centerY: 1.25, sceneMinY: 0, sceneMaxY: 2.5
            ) == "Wall"
        )
        // Degenerate vertical span: no positional claim.
        #expect(
            CaptureCoverageGapAnalyzer.regionName(
                for: .wall, centerY: 1, sceneMinY: 0.9, sceneMaxY: 1.1
            ) == "Wall"
        )
        #expect(
            CaptureCoverageGapAnalyzer.regionName(
                for: .floor, centerY: 0, sceneMinY: 0, sceneMaxY: 2.5
            ) == "Floor"
        )
        // Advisory copy names what's missing, never a definitive-hole claim.
        #expect(
            CaptureCoverageGapAnalyzer.label(forRegion: "Upper wall")
                == "Possible gap in the upper wall"
        )
    }

    @Test("Covered surfaces produce no gaps")
    func fullyCoveredScene() {
        let faces = patch(category: .ceiling, y: 2.5, xRange: 0...4, zRange: 0...4)
        let gaps = rawGaps(
            faces: faces,
            isCovered: { _ in true }
        )
        #expect(gaps.isEmpty)
    }

    @Test("Gaps far from the traveled path are never reported")
    func farGapsDropped() {
        // A large uncovered wall ~10 m from the camera path — e.g. the next
        // room seen through an open door — must not become a warning.
        let nearCeiling = patch(
            category: .ceiling, y: 2.5, xRange: 0...4, zRange: 0...4
        )
        // ~3.8 m out: inside the old 4 m gate, beyond the 3 m one. Depth
        // sampling is too sparse there for coverage to ever read true, so
        // reporting it would be a never-ending ask.
        let midWall = patch(
            category: .wall, y: 1.5, xRange: 14...18, zRange: 0...4
        )
        let farWall = patch(
            category: .wall, y: 1, xRange: 100...110, zRange: 0...4
        )
        let cameraPath = [SIMD3<Float>(0.2, 1.5, 0.2)]

        let gaps = rawGaps(
            faces: nearCeiling + midWall + farWall,
            isCovered: { _ in false },
            cameraPositions: cameraPath
        )

        #expect(gaps.count == 1)
        #expect(gaps.first?.category == .ceiling)
    }

    @Test("A modest gap near the path outranks a larger distant one")
    func proximityOutranksArea() {
        // Floor gap right under the camera (4.8 m² at ~1.5 m) vs. a larger
        // ceiling patch farther out but inside the 3 m cutoff (7.5 m² at
        // ~2.2 m): the close one must rank first.
        let nearFloor = patch(
            category: .floor, y: 0, xRange: 0...3, zRange: 0...3
        )
        let farCeiling = patch(
            category: .ceiling, y: 2.5, xRange: 30...34, zRange: 0...4
        )
        // One position by the floor gap, one within range of the ceiling.
        let cameraPath = [
            SIMD3<Float>(0.1, 1.5, 0.1),
            SIMD3<Float>(6.0, 1.5, 0.5),
        ]

        let gaps = rawGaps(
            faces: nearFloor + farCeiling,
            isCovered: { _ in false },
            cameraPositions: cameraPath
        )

        #expect(gaps.count == 2)
        #expect(gaps[0].category == .floor)
        #expect(gaps[1].category == .ceiling)
        #expect(gaps[1].areaM2 > gaps[0].areaM2)
    }
}

@Suite("Repair emphasis paint policy")
struct RepairEmphasisPaintTests {
    @Test("Uncovered surface inside the repair region renders amber, visible")
    func emphasizedUncoveredVisible() {
        let plain = CaptureMeshOverlay.paintColor(
            voxel: nil,
            mode: .camera,
            now: 10
        )
        let emphasized = CaptureMeshOverlay.paintColor(
            voxel: nil,
            mode: .camera,
            now: 10,
            emphasized: true
        )
        #expect(plain.w == 0)
        #expect(emphasized.w > 0.2)
        // Amber: strong red, weak blue.
        #expect(emphasized.x > 0.9)
        #expect(emphasized.z < 0.4)
    }

    @Test("Covered surface keeps its normal fill inside the region")
    func emphasizedCoveredUnchanged() {
        let voxel = CaptureCoverageTracker.Voxel(
            observationCount: 1,
            viewDirectionBits: 0b1,
            maxConfidence: 2,
            lastObservedAt: -100
        )
        let normal = CaptureMeshOverlay.paintColor(
            voxel: voxel,
            mode: .camera,
            now: 10
        )
        let emphasized = CaptureMeshOverlay.paintColor(
            voxel: voxel,
            mode: .camera,
            now: 10,
            emphasized: true
        )
        #expect(normal == emphasized)
    }

    @Test("Emphasis region containment is a sphere test")
    func regionContainment() {
        let region = CaptureMeshOverlay.EmphasisRegion(
            center: SIMD3(1, 2, 3),
            radiusM: 0.5
        )
        #expect(region.contains(SIMD3(1.2, 2, 3)))
        #expect(!region.contains(SIMD3(1.6, 2, 3)))
    }
}

@Suite("Coverage review support")
struct CaptureCoverageReviewSupportTests {
    @Test("coveredVoxelCount counts voxels inside the sphere only")
    func coveredVoxelCountNearRegion() {
        let tracker = CaptureCoverageTracker(voxelSizeM: 0.1)
        tracker.integrate(
            CaptureCoverageObservation(
                timestamp: 0,
                cameraPosition: SIMD3(0, 2, 0),
                points: [
                    CaptureCoveragePoint(position: SIMD3(0, 0, 0), confidence: 2),
                    CaptureCoveragePoint(position: SIMD3(0.2, 0, 0), confidence: 2),
                    CaptureCoveragePoint(position: SIMD3(5, 0, 0), confidence: 2),
                ]
            )
        )
        #expect(
            tracker.coveredVoxelCount(near: SIMD3(0.1, 0, 0), radiusM: 0.5) == 2
        )
        #expect(
            tracker.coveredVoxelCount(near: SIMD3(5, 0, 0), radiusM: 0.3) == 1
        )
        #expect(
            tracker.coveredVoxelCount(near: SIMD3(10, 0, 0), radiusM: 1) == 0
        )
    }

}
