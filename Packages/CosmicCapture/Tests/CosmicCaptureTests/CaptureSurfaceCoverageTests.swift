import Testing
import simd
@testable import CosmicCapture

struct CaptureSurfaceCoverageTests {
    private func face(_ position: SIMD3<Float> = .zero, category: CaptureStructuralCategory = .floor) -> CaptureClassifiedFace {
        CaptureClassifiedFace(center: position, normal: SIMD3(0, 1, 0), areaM2: 0.02, category: category)
    }
    private func observe(_ tracker: CaptureCoverageTracker, _ p: SIMD3<Float>, diverse: Bool = false, confidence: UInt8 = 2) {
        tracker.integrate(CaptureCoverageObservation(timestamp: 1, cameraPosition: p + SIMD3(1, 2, 0),
            points: [CaptureCoveragePoint(position: p, confidence: confidence)]))
        if diverse {
            tracker.integrate(CaptureCoverageObservation(timestamp: 2, cameraPosition: p + SIMD3(-2, 0, 0),
                points: [CaptureCoveragePoint(position: p, confidence: confidence)]))
        }
    }

    @Test func evidenceComesOnlyFromSavedViewsAndDetectedGeometry() {
        let tracker = CaptureCoverageTracker()
        let faces = [face()]
        #expect(CaptureSurfaceCoverage.patches(faces: faces, tracker: tracker, camera: .zero).first?.evidence == .needsViews)
        observe(tracker, .zero)
        #expect(CaptureSurfaceCoverage.patches(faces: faces, tracker: tracker, camera: .zero).first?.evidence == .singleView)
        observe(tracker, .zero, diverse: true)
        #expect(CaptureSurfaceCoverage.patches(faces: faces, tracker: tracker, camera: .zero).first?.evidence == .multipleViews)
        #expect(CaptureSurfaceCoverage.patches(faces: [], tracker: tracker, camera: .zero).isEmpty)
    }

    @Test func wallEvidenceDoesNotTransferToOppositeFace() {
        let tracker = CaptureCoverageTracker()
        let center = SIMD3<Float>(0.02, 1, 0.02)
        let front = CaptureClassifiedFace(center: center, normal: SIMD3(0,0,1), areaM2: 0.04, category: .wall)
        let back = CaptureClassifiedFace(center: center, normal: SIMD3(0,0,-1), areaM2: 0.04, category: .wall)
        tracker.integrate(CaptureCoverageObservation(timestamp: 1, cameraPosition: center + SIMD3(1,0,2),
            points: [.init(position: center, confidence: 2)]))
        let patches = CaptureSurfaceCoverage.patches(faces: [front, back], tracker: tracker, camera: .zero)
        #expect(patches.count == 2)
        #expect(patches.first { $0.normal.z > 0 }?.evidence == .singleView)
        #expect(patches.first { $0.normal.z < 0 }?.evidence == .needsViews)
        var cache = CaptureSurfaceCoverageCache()
        #expect(cache.merge(patches).count == 2)
        tracker.integrate(CaptureCoverageObservation(timestamp: 2, cameraPosition: center + SIMD3(-2,0,1),
            points: [.init(position: center, confidence: 2)]))
        let updated = cache.merge(CaptureSurfaceCoverage.patches(faces: [front, back], tracker: tracker, camera: .zero))
        #expect(updated.first { $0.normal.z > 0 }?.evidence == .multipleViews)
        #expect(updated.first { $0.normal.z < 0 }?.evidence == .needsViews)
    }

    @Test func partialPatchAndLowConfidenceDoNotBecomeStrongGreen() {
        let tracker = CaptureCoverageTracker()
        observe(tracker, SIMD3(0.02, 0, 0), diverse: true)
        let patches = CaptureSurfaceCoverage.patches(faces: [face(SIMD3(0.02, 0, 0)), face(SIMD3(0.12, 0, 0))], tracker: tracker, camera: .zero)
        #expect(patches.count == 1)
        #expect(patches.first?.evidence == .needsViews)
        let medium = CaptureCoverageTracker()
        observe(medium, .zero, diverse: true, confidence: 1)
        #expect(CaptureSurfaceCoverage.patches(faces: [face()], tracker: medium, camera: .zero).first?.evidence == .singleView)
    }

    @Test func layersStaySeparateAndBoundedNearCamera() {
        let tracker = CaptureCoverageTracker()
        let faces = (0..<10).flatMap { x in
            [face(SIMD3(Float(x), 0, 0)), face(SIMD3(Float(x), 3, 0), category: .ceiling)]
        } + [face(SIMD3(30, 0, 0)), face(.zero, category: .wall)]
        let patches = CaptureSurfaceCoverage.patches(faces: faces, tracker: tracker, camera: .zero, limitPerCategory: 2)
        #expect(patches.count == 5)
        #expect(patches.filter { $0.category == .floor }.count == 2)
        #expect(patches.filter { $0.category == .ceiling }.count == 2)
        #expect(patches.allSatisfy { $0.center.x <= 1 })
    }

    @Test func cacheSurvivesMissingMeshAndPreservesEvidence() {
        var cache = CaptureSurfaceCoverageCache()
        let saved = CaptureSurfacePatch(center: .zero, normal: SIMD3(0, 1, 0), size: 0.1, category: .floor, evidence: .multipleViews)
        #expect(cache.merge([saved]).count == 1)
        #expect(cache.merge([]).first?.evidence == .multipleViews)
        let weaker = CaptureSurfacePatch(center: .zero, normal: SIMD3(0, 1, 0), size: 0.18, category: .floor, evidence: .needsViews)
        #expect(cache.merge([weaker]).first?.size == 0.1)
        cache.limit = 1
        let other = CaptureSurfacePatch(center: SIMD3(2, 0, 0), normal: SIMD3(0, 1, 0), size: 0.1, category: .floor, evidence: .singleView)
        #expect(cache.merge([other]).count == 1)
        #expect(cache.isLimited)
    }

    @Test @MainActor func startingDirectionStaysFixedAndLayerChangeInvalidatesRenderer() {
        let overview = CaptureRoomOverview()
        overview.recordCameraPose(matrix_identity_float4x4)
        let north = overview.referenceForward
        overview.recordCameraPose(simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))))
        #expect(overview.referenceForward == north)
        let revision = overview.renderRevision
        overview.layer = .floor
        #expect(overview.renderRevision > revision)
        #expect(overview.layerMessage == "Loading saved coverage…")
        overview.configureFixture(includeCeiling: true)
        let count = overview.patches.count
        overview.layer = .ceiling
        overview.layer = .floor
        #expect(overview.patches.count == count)
        overview.updateCoverage(faces: [], tracker: CaptureCoverageTracker(), camera: .zero)
        #expect(overview.patches.count == count)
        overview.resetRoom(clearCoverage: false)
        #expect(overview.patches.count == count)
        #expect(overview.referenceForward == north)
        overview.resetRoom()
        #expect(overview.patches.isEmpty)
        #expect(overview.referenceForward == nil)
    }

    @Test func targetRequiresMatchingCategoryAndDistance() {
        let patch = CaptureSurfacePatch(center: .zero, normal: SIMD3(0, 1, 0), size: 0.18, category: .floor, evidence: .needsViews)
        let gap = CaptureCoverageGap(id: 0, category: .floor, center: .zero, radiusM: 0.5, areaM2: 1, label: "Area")
        #expect(patch.isTarget(gap))
        #expect(!patch.isTarget(nil))
        let ceiling = CaptureCoverageGap(id: 0, category: .ceiling, center: .zero, radiusM: 0.5, areaM2: 1, label: "Area")
        #expect(!patch.isTarget(ceiling))
        let far = CaptureCoverageGap(id: 0, category: .floor, center: SIMD3(3, 0, 0), radiusM: 0.5, areaM2: 1, label: "Area")
        #expect(!patch.isTarget(far))
    }

    @Test @MainActor func hidingGuideStillAccumulatesNewSavedSurfaceEvidence() {
        let overview = CaptureRoomOverview()
        overview.configureFixture()
        let originalCount = overview.patches.count
        overview.isEnabled = false
        let center = SIMD3<Float>(4, 0, 0)
        let tracker = CaptureCoverageTracker()
        tracker.integrate(CaptureCoverageObservation(timestamp: 1, cameraPosition: SIMD3(4, 1, 0),
            points: [CaptureCoveragePoint(position: center, confidence: 2)]))
        overview.updateCoverage(faces: [CaptureClassifiedFace(center: center, normal: SIMD3(0, 1, 0),
            areaM2: 0.04, category: .floor)], tracker: tracker, camera: center)
        #expect(overview.patches.count == originalCount + 1)
        #expect(overview.patches.contains { simd_distance($0.center, center) < 0.01 && $0.evidence == .singleView })
        overview.isEnabled = true
        #expect(overview.patches.count == originalCount + 1)
    }

    @Test @MainActor func changingSurfaceNeverErasesRoomOrSavedCoverage() {
        let guide = CaptureCoverageGuide()
        guide.roomOverview.configureFixture(includeCeiling: true)
        let patches = guide.roomOverview.patches.count
        let edges = guide.roomOverview.outline.edges.count
        for category in [CaptureStructuralCategory.ceiling, .floor, .wall, .ceiling] {
            guide.setGuidanceCategory(category)
            #expect(guide.roomOverview.patches.count == patches)
            #expect(guide.roomOverview.outline.edges.count == edges)
        }
        guide.setGuidanceCategory(.wall, restarting: true)
        #expect(guide.roomOverview.outline.edges.count == edges)
        #expect(guide.roomOverview.patches.count == patches)
    }

    @Test @MainActor func layoutCueClearsOnPauseSwitchAndRetirement() {
        let overview = CaptureRoomOverview()
        overview.configureFixture(includeCeiling: true)
        let gap = CaptureCoverageGap(id: 0, category: .ceiling, center: SIMD3(0, 2.8, 0), radiusM: 1, areaM2: 1, label: "Area")
        overview.layer = .ceiling
        overview.highlightedGap = gap
        #expect(overview.visibleGap == gap)
        overview.layer = .floor
        #expect(overview.visibleGap == nil)
        overview.layer = .ceiling
        overview.coverageIsPaused = true
        #expect(overview.visibleGap == nil)
        overview.coverageIsPaused = false
        #expect(overview.visibleGap == gap)
        overview.highlightedGap = nil
        #expect(overview.visibleGap == nil)
        for evidence in [CaptureSurfacePatch.Evidence.singleView, .multipleViews] {
            let saved = CaptureSurfacePatch(center: gap.center, normal: SIMD3(0, -1, 0), size: 0.18, category: .ceiling, evidence: evidence)
            #expect(!saved.isTarget(gap), "Saved evidence must remain green inside the target")
        }
    }

    @Test @MainActor func missingCeilingStaysUnknownAndResetClearsCoverage() {
        let overview = CaptureRoomOverview()
        overview.configureFixture()
        overview.layer = .floor
        #expect(!overview.patches.isEmpty)
        overview.layer = .ceiling
        #expect(overview.layerMessage == "Look up to reveal the ceiling")
        overview.coverageIsPaused = true
        #expect(overview.layerMessage == "Coverage preview paused")
        overview.resetRoom()
        #expect(overview.patches.isEmpty)
    }
}
