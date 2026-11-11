import Foundation
import Testing
import simd
@testable import CosmicCapture

@Suite("First scan walkthrough")
@MainActor
struct CaptureWalkthroughTests {
    private func withStore(_ body: (UserDefaults) -> Void) {
        let name = "WalkthroughTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func introductionCanBeClosedOrSkippedWithoutStartingCapture() {
        withStore { defaults in
            let lesson = CaptureWalkthrough(defaults: defaults)
            lesson.presentIntroduction()
            #expect(lesson.isPresentingIntroduction)
            #expect(lesson.introductionPage == 0)
            #expect(!lesson.isSelected)
            #expect(!lesson.isActive)
            lesson.requestLandscape()
            #expect(lesson.introductionPage == 1)
            lesson.skip()
            #expect(!lesson.isPresentingIntroduction)
            #expect(!lesson.isSelected)
            lesson.presentIntroduction()
            #expect(lesson.introductionPage == 0)
            lesson.select()
            #expect(!lesson.isPresentingIntroduction)
            #expect(lesson.isSelected)
            #expect(!lesson.isActive)
        }
    }

    @Test func offerRespectsSkipAndAllowsReplay() {
        withStore { defaults in
            let lesson = CaptureWalkthrough(defaults: defaults)
            lesson.offerIfNeeded(isFirstCapture: true, isContinuation: false)
            #expect(lesson.isOffered)
            lesson.skip()
            let next = CaptureWalkthrough(defaults: defaults)
            next.offerIfNeeded(isFirstCapture: true, isContinuation: false)
            #expect(!next.isOffered)
            next.select()
            next.start(hasLayout: true)
            #expect(next.lesson == .preview)
        }
    }

    @Test func noAutomaticOfferForExistingOrContinuedScans() {
        withStore { defaults in
            let lesson = CaptureWalkthrough(defaults: defaults)
            lesson.offerIfNeeded(isFirstCapture: false, isContinuation: false)
            #expect(!lesson.isOffered)
            lesson.offerIfNeeded(isFirstCapture: true, isContinuation: true)
            #expect(!lesson.isOffered)
            lesson.start(hasLayout: true)
            #expect(!lesson.isActive)
        }
    }

    @Test func layoutLessonRequiresOpeningThenClosingPreview() {
        withStore { defaults in
            let lesson = CaptureWalkthrough(defaults: defaults)
            lesson.select()
            lesson.start(hasLayout: true)
            #expect(lesson.lesson == .preview)
            while lesson.lesson != .layout { lesson.advance() }
            #expect(lesson.lesson == .layout)
            lesson.closedLayout()
            #expect(lesson.lesson == .layout)
            lesson.openedLayout()
            #expect(lesson.lesson == .layout)
            lesson.closedLayout()
            #expect(lesson.lesson == .hiddenSurfaces)
            lesson.closedLayout()
            #expect(lesson.lesson == .hiddenSurfaces)
        }
    }

    @Test func nonLiDARSkipsLayoutAndNeverWaitsForCoverage() {
        withStore { defaults in
            let lesson = CaptureWalkthrough(defaults: defaults)
            lesson.select()
            lesson.start(hasLayout: false)
            var visited: [CaptureWalkthrough.Lesson] = []
            for _ in 0..<3 {
                visited.append(lesson.lesson!)
                lesson.advance()
            }
            #expect(visited == [.sweep, .hiddenSurfaces, .review])
            #expect(lesson.lesson == .review)
            #expect(!lesson.didComplete)
        }
    }

    @Test func reviewAndRepairPreserveLessonUntilSave() {
        withStore { defaults in
            let lesson = CaptureWalkthrough(defaults: defaults)
            lesson.select()
            lesson.start(hasLayout: true)
            lesson.openedReview()
            #expect(lesson.lesson == .review)
            #expect(!lesson.didComplete)
            // Returning to live capture does not reset teaching or mark it complete.
            lesson.openedReview()
            #expect(!lesson.didComplete)
            lesson.saved()
            #expect(lesson.didComplete)
            #expect(!lesson.isActive)
            #expect(defaults.string(forKey: CaptureWalkthrough.choiceKey) == "completed")
        }
    }

    @Test func skipCannotBeMarkedCompletedByLaterSave() {
        withStore { defaults in
            let lesson = CaptureWalkthrough(defaults: defaults)
            lesson.select()
            lesson.start(hasLayout: true)
            lesson.openedReview()
            lesson.skip()
            lesson.saved()
            #expect(!lesson.didComplete)
            #expect(defaults.string(forKey: CaptureWalkthrough.choiceKey) == "skipped")
        }
    }
    @Test func previewIntroductionDoesNotRequireScanEvidence() {
        withStore { defaults in
            let tour = CaptureWalkthrough(defaults: defaults)
            tour.select()
            tour.start(hasLayout: true)
            #expect(tour.canAdvance)
            tour.advance()
            #expect(tour.lesson == .inspect)
            #expect(!tour.canAdvance)
            tour.interactedWithPreview()
            #expect(tour.canAdvance)
            tour.advance()
            #expect(tour.lesson == .reset)
            #expect(!tour.canAdvance)
            tour.resetPreview()
            #expect(tour.lesson == .camera)
        }
    }

    @Test func continuousSweepNeverRequiresASpecificSurface() {
        withStore { defaults in
            let tour = CaptureWalkthrough(defaults: defaults)
            tour.select()
            tour.start(hasLayout: false)
            for category in [CaptureStructuralCategory.wall, .floor] {
                #expect(tour.canAdvance)
                tour.observeCapture(frames: 100, distance: 10, category: category)
                tour.observeCapture(frames: 120, distance: 11, category: category)
                #expect(tour.canAdvance)
                #expect(tour.practiceFrames == 20)
                tour.advance()
            }
        }
    }

    @Test func liveSamplePreservesColoursAndDistancesWithoutChangingSource() {
        let cloud = CapturePointCloud(positions: (0..<100).map { SIMD3<Float>(Float($0), 0, 0) },
            colorsRGB: (0..<100).map { SIMD3<UInt8>(UInt8($0), 10, 20) })
        let sampled = cloud.livePreviewSample(limit: 10)
        #expect(sampled.positions.count == 10)
        #expect(sampled.positions.last?.x == 90)
        #expect(sampled.colorsRGB?.last?.x == 90)
        #expect(sampled.distancesFromCaptureOriginM.last == 90)
        #expect(sampled.source == cloud.source)
        #expect(cloud.positions.count == 100)
    }

    @Test func liveSampleIncludesRetiredAndCurrentAreas() {
        var archive = CaptureMeshPreviewArchive()
        archive.retain(id: UUID(), points: [SIMD3<Float>(-10, 0, 0)])
        let cloud = CapturePointCloud(positions: archive.previewPoints(active: [SIMD3<Float>(10, 0, 0)]))
        #expect(cloud.livePreviewSample().positions.contains(SIMD3<Float>(-10, 0, 0)))
        #expect(cloud.livePreviewSample().positions.contains(SIMD3<Float>(10, 0, 0)))
    }
    @Test func tourTeachesPreviewControlsBeforeObjectsAndFinalPass() {
        withStore { defaults in
            let tour = CaptureWalkthrough(defaults: defaults)
            tour.select()
            tour.start(hasLayout: true)
            #expect(tour.lessons == [.preview, .inspect, .reset, .camera, .layout, .hiddenSurfaces, .review])
            for _ in 0..<6 { tour.advance() }
            #expect(tour.lesson == .review)
            #expect(!tour.canAdvance)
            #expect(tour.lesson?.title == "Do one final pass")
        }
    }

    @Test func previewStartsLevelAndKeepsStartingHeading() {
        let camera = CaptureLiveCloudCamera()
        var pose = matrix_identity_float4x4
        pose.columns.2 = SIMD4(0.6, 0.8, 0, 0)
        #expect(camera.recordStartingDirection(pose: pose))
        #expect(simd_distance(camera.viewingDirection, SIMD3(1, 0, 0)) < 0.0001)
        #expect(!camera.recordStartingDirection(pose: matrix_identity_float4x4))
        camera.overviewDirection = SIMD3(0, 0, -1)
        camera.reset()
        #expect(simd_distance(camera.viewingDirection, SIMD3(1, 0, 0)) < 0.0001)
    }

    @Test func previewCameraKeepsClipPlanesUntilRefitAndClearsThemOnReset() {
        let camera = CaptureLiveCloudCamera()
        // Saved with a user gesture: survives compact <-> expanded recreation,
        // where SceneKit's default 1...100 planes could clip the whole cloud.
        camera.zNear = 0.01
        camera.zFar = 42
        #expect(camera.zNear == 0.01)
        #expect(camera.zFar == 42)

        // Reset and Level hand control back to auto-fit, which reassigns the
        // planes; stale values must not leak into the refit camera.
        camera.reset()
        #expect(camera.zNear == nil)
        #expect(camera.zFar == nil)

        camera.zNear = 0.02
        camera.zFar = 24
        camera.level()
        #expect(camera.zNear == nil)
        #expect(camera.zFar == nil)
    }

    @Test func previewWaitsForUsableHeadingWhenPhonePointsStraightUp() {
        let camera = CaptureLiveCloudCamera()
        var pose = matrix_identity_float4x4
        pose.columns.2 = SIMD4(0, 1, 0, 0)
        #expect(!camera.recordStartingDirection(pose: pose))
        #expect(camera.viewingDirection == SIMD3(0, 0, 1))
        #expect(camera.recordStartingDirection(pose: matrix_identity_float4x4))
        #expect(camera.viewingDirection.y == 0)
    }

    @Test func movementKeepsInstructionsVisibleWithoutBlockingProgress() {
        withStore { defaults in
            let tour = CaptureWalkthrough(defaults: defaults)
            tour.select()
            tour.start(hasLayout: true)
            #expect(tour.canAdvance)
            tour.observeCapture(frames: 1, distance: 0, category: .wall)
            tour.observeCapture(frames: 12, distance: 0.3, category: .floor)
            tour.observeCapture(frames: 24, distance: 0.7, category: .wall)
            #expect(tour.canAdvance)
            tour.advance()
            #expect(tour.lesson == .inspect)
            tour.openedReview()
            #expect(tour.postScanStep == 8)
            #expect(tour.totalSteps == 9)
            tour.saved()
            #expect(tour.didComplete)
        }
    }

    @Test func tourPlacementNeverCoversMiniPreview() {
        for size in [CGSize(width: 800, height: 370), CGSize(width: 932, height: 430), CGSize(width: 390, height: 844)] {
            let landscape = size.width > size.height
            let preview = landscape ? CGRect(x: size.width - 316, y: 8, width: 300, height: 260)
                : CGRect(x: 16, y: 480, width: size.width - 32, height: 270)
            for target in [nil, Optional(CGRect(x: preview.maxX - 44, y: preview.minY + 44, width: 44, height: 44))] {
                let card = CaptureTourPlacement.frame(size: size, height: 230, target: target, avoiding: preview, panel: nil)
                #expect(!card.intersects(preview))
                #expect(CGRect(origin: .zero, size: size).contains(card))
                if landscape { #expect(card.midY > size.height * 0.55) }
            }
        }
    }

    @Test func expandedTourStaysInsideItsReservedPanel() {
        let size = CGSize(width: 932, height: 430)
        let panel = CGRect(x: 616, y: 58, width: 300, height: 360)
        let preview = CGRect(x: 12, y: 58, width: 588, height: 360)
        for height: CGFloat in [150, 240, 600] {
            let card = CaptureTourPlacement.frame(size: size, height: height,
                                                  target: preview, avoiding: nil, panel: panel)
            #expect(panel.contains(card))
            #expect(!preview.intersects(card))
            #expect(card.maxY == panel.maxY)
        }
    }

    @Test func arrowShaftEntersHeadStraightAcrossTightAndOffsetLayouts() throws {
        // Reproduce the narrow review-panel gap and the steep connection to Done,
        // then cover the same geometry with cards on all four sides of a target.
        let layouts: [(CGRect, CGRect)] = [
            (CGRect(x: 540, y: 90, width: 280, height: 170), CGRect(x: 60, y: 72, width: 472, height: 320)),
            (CGRect(x: 510, y: 205, width: 300, height: 170), CGRect(x: 405, y: 64, width: 80, height: 54)),
            (CGRect(x: 140, y: 150, width: 320, height: 180), CGRect(x: 488, y: 8, width: 300, height: 250)),
            (CGRect(x: 30, y: 220, width: 320, height: 170), CGRect(x: 100, y: 406, width: 44, height: 44)),
            (CGRect(x: 30, y: 470, width: 320, height: 170), CGRect(x: 16, y: 20, width: 350, height: 434)),
        ]
        for (card, target) in layouts {
            let arrow = try #require(CaptureTourArrowGeometry(card: card, target: target))
            let dx = arrow.tip.x - arrow.shaftJoin.x
            let dy = arrow.tip.y - arrow.shaftJoin.y
            let terminalLength = hypot(dx, dy)
            #expect(terminalLength >= 16)
            #expect(abs(dx / terminalLength - arrow.direction.dx) < 0.0001)
            #expect(abs(dy / terminalLength - arrow.direction.dy) < 0.0001)
            let base = CGPoint(x: (arrow.headLeft.x + arrow.headRight.x) / 2,
                               y: (arrow.headLeft.y + arrow.headRight.y) / 2)
            #expect(abs(hypot(arrow.tip.x - base.x, arrow.tip.y - base.y) - 11) < 0.0001)
            #expect(abs((arrow.tip.x - base.x) * dy - (arrow.tip.y - base.y) * dx) < 0.0001)
            #expect(!card.contains(arrow.headLeft))
            #expect(!card.contains(arrow.headRight))
            #expect(!card.contains(arrow.tip))
            // The curve must enter the straight shaft in the same direction.
            let tangentX = arrow.shaftJoin.x - arrow.control2.x
            let tangentY = arrow.shaftJoin.y - arrow.control2.y
            #expect(abs(tangentX * dy - tangentY * dx) < 0.0001)
            #expect(tangentX * dx + tangentY * dy >= -0.0001)
        }
    }

    @Test func levelViewKeepsChosenYawAndRemovesElevation() {
        let camera = CaptureLiveCloudCamera()
        var transform = matrix_identity_float4x4
        transform.columns.2 = SIMD4(0.6, 0.8, 0, 0)
        camera.transform = transform
        camera.level()
        #expect(simd_distance(camera.viewingDirection, SIMD3(1, 0, 0)) < 0.0001)
        #expect(camera.transform == nil)
    }

    @Test func gesturesAndResetDoNotSkipUnrelatedLessons() {
        withStore { defaults in
            let tour = CaptureWalkthrough(defaults: defaults)
            tour.select()
            tour.start(hasLayout: true)
            tour.interactedWithPreview()
            tour.resetPreview()
            #expect(tour.lesson == .preview)
            tour.advance()
            #expect(!tour.canAdvance)
            tour.interactedWithPreview()
            #expect(tour.canAdvance)
            tour.skip()
            tour.resetPreview()
            tour.interactedWithPreview()
            #expect(!tour.isActive)
        }
    }

}
