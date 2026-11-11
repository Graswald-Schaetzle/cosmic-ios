import Foundation
import Testing
import simd
@testable import CosmicCapture

struct CaptureGapNavigationTests {
    private func gap(_ center: SIMD3<Float>) -> CaptureCoverageGap {
        CaptureCoverageGap(id: 1, category: .wall, center: center,
                           radiusM: 0.5, areaM2: 1, label: "Missing wall area")
    }

    private var projection: simd_float4x4 {
        simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                      SIMD4(0, 0, -1, -1), SIMD4(0, 0, -0.01, 0))
    }

    @Test func directionsUseScreenAxesAndNeverMirrorBehindCamera() {
        let cases: [(SIMD3<Float>, CaptureGapDirection)] = [
            (SIMD3(-3, 0, -1), .left), (SIMD3(3, 0, -1), .right),
            (SIMD3(0, 3, -1), .up), (SIMD3(0, -3, -1), .down),
            (SIMD3(0, 0, -2), .inView), (SIMD3(-2, 0, 2), .left),
            (SIMD3(2, 0, 2), .right), (SIMD3(0, 0, 2), .right),
            (SIMD3(0, 3, 0), .up), (SIMD3(0, -3, 0), .down),
            (SIMD3(0, 3, 0.2), .up)
        ]
        for (point, expected) in cases {
            var navigator = CaptureGapNavigator()
            let cue = navigator.update(target: gap(point), viewMatrix: matrix_identity_float4x4,
                                       projection: projection, timestamp: 0)
            #expect(cue?.direction == expected)
        }
    }

    @Test func viewportRotationAndAspectAreIncludedInProjection() {
        let cases: [(Float, CaptureGapDirection)] = [(0, .right), (.pi / 2, .up), (-.pi / 2, .down), (.pi, .left)]
        for (roll, expected) in cases {
            var navigator = CaptureGapNavigator()
            let view = simd_float4x4(simd_quatf(angle: roll, axis: SIMD3(0, 0, 1)))
            let cue = navigator.update(target: gap(SIMD3(3, 0, -1)), viewMatrix: view,
                                       projection: projection, timestamp: 0)
            #expect(cue?.direction == expected)
        }
        var narrow = projection
        narrow.columns.0.x = 2
        var navigator = CaptureGapNavigator()
        let cue = navigator.update(target: gap(SIMD3(0.6, 0, -1)), viewMatrix: matrix_identity_float4x4,
                                   projection: narrow, timestamp: 0)
        #expect(cue?.direction == .right)
    }

    @Test func frustumHysteresisAndDwellPreventBoundaryFlicker() {
        var navigator = CaptureGapNavigator()
        let target = gap(SIMD3(0, 0, -1))
        _ = navigator.update(target: target, viewMatrix: matrix_identity_float4x4,
                             projection: projection, timestamp: 0)
        var view = matrix_identity_float4x4
        view.columns.3.x = 0.9
        let nearEdge = navigator.update(target: target, viewMatrix: view, projection: projection, timestamp: 1)
        #expect(nearEdge?.direction == .inView)
        view.columns.3.x = 1.2
        let transient = navigator.update(target: target, viewMatrix: view, projection: projection, timestamp: 2)
        #expect(transient?.direction == .inView)
        let sustained = navigator.update(target: target, viewMatrix: view, projection: projection, timestamp: 2.3)
        #expect(sustained?.direction == .right)
        view.columns.3.x = 0.9
        let notReacquired = navigator.update(target: target, viewMatrix: view, projection: projection, timestamp: 3)
        #expect(notReacquired?.direction == .right)
        view.columns.3.x = 0.5
        _ = navigator.update(target: target, viewMatrix: view, projection: projection, timestamp: 4)
        let acquired = navigator.update(target: target, viewMatrix: view, projection: projection, timestamp: 4.3)
        #expect(acquired?.direction == .inView)
    }

    @Test func directlyBehindKeepsThePreviousTurnAndInvalidPointsClear() {
        var navigator = CaptureGapNavigator()
        _ = navigator.update(target: gap(SIMD3(-0.5, 0, 3)), viewMatrix: matrix_identity_float4x4,
                             projection: projection, timestamp: 0)
        let behind = navigator.update(target: gap(SIMD3(0.1, 0, 3)), viewMatrix: matrix_identity_float4x4,
                                      projection: projection, timestamp: 1)
        #expect(behind?.direction == .left)
        let close = navigator.update(target: gap(.zero), viewMatrix: matrix_identity_float4x4,
                                     projection: projection, timestamp: 2)
        #expect(close == nil)
        let invalid = navigator.update(target: gap(SIMD3(.nan, 0, 1)), viewMatrix: matrix_identity_float4x4,
                                       projection: projection, timestamp: 3)
        #expect(invalid == nil)
    }

    /// Drives the arbiter with whatever the guide currently advises.
    @MainActor private func evaluate(
        _ arbiter: CaptureGuidanceArbiter,
        _ guide: CaptureCoverageGuide,
        at timestamp: TimeInterval,
        tracking: CaptureTrackingSignal = .normal
    ) -> CaptureGuidance? {
        arbiter.evaluate(
            CaptureGuidanceInput(timestamp: timestamp, tracking: tracking, advisories: guide.advisories())
        )
    }

    @Test @MainActor func explicitRepairPersistsButTrackingWarningsWin() {
        let arbiter = CaptureGuidanceArbiter()
        let guide = CaptureCoverageGuide()
        guide.beginRepair(gaps: [gap(SIMD3(0, 0, -2))])
        _ = evaluate(arbiter, guide, at: 0)
        _ = evaluate(arbiter, guide, at: 1)
        let visible = evaluate(arbiter, guide, at: 40)
        #expect(visible?.id == CaptureGuidanceArbiter.guidanceID(
            forAdvisory: CaptureCoverageGuide.gapAdvisoryID(for: .wall)
        ))
        _ = evaluate(arbiter, guide, at: 41, tracking: .notAvailable)
        let warning = evaluate(arbiter, guide, at: 42, tracking: .notAvailable)
        #expect(warning?.severity == .critical)
    }

    @Test @MainActor func repairAdvisoryHasNoDisplayLimitOrCooldown() {
        let guide = CaptureCoverageGuide()
        guide.beginRepair(gaps: [gap(SIMD3(0, 0, -2))])
        let advisory = guide.advisories().first
        #expect(advisory?.message == "Missing wall area")
        #expect(advisory?.displayLimitSeconds == nil)
        #expect(advisory?.reentryCooldownSeconds == 0)
    }

    @Test @MainActor func selectedPassCancelsPriorRepairAndKeepsSafetyMessage() {
        let guide = CaptureCoverageGuide()
        let coordinator = ARCaptureCoordinator(liveGuide: guide)
        guide.attach(to: coordinator)
        guide.beginRepair(gaps: [gap(SIMD3(0, 0, -2))])
        coordinator.guidance = CaptureGuidance(
            id: "motion-warning", severity: .warning, message: "Going too fast",
            isUrgentStyle: false, wantsHaptic: false
        )
        guide.setGuidanceCategory(.floor)
        #expect(guide.guidanceCategory == .floor)
        #expect(guide.activeRepairTarget == nil)
        #expect(guide.gapNavigation == nil)
        #expect(guide.advisories().isEmpty)
        #expect(coordinator.guidance?.id == "motion-warning")
    }

    @Test func copyUsesDetectedCategoryForEverySurface() {
        for category in CaptureStructuralCategory.allCases {
            let target = CaptureCoverageGap(id: 0, category: category, center: .zero,
                                           radiusM: 1, areaM2: 1, label: "Area")
            let navigation = CaptureGapNavigation(target: target, direction: .inView)
            #expect(navigation.message == "Scan the highlighted \(category.rawValue) area")
        }
    }
}
