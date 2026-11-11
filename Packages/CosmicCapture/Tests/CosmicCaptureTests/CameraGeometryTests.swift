import Foundation
import simd
import Testing
import UIKit
@testable import CosmicCapture

@Suite("CameraGeometry")
struct CameraGeometryTests {
    @Test("OpenCV conversion round-trips through inverse")
    func inverseRoundTrip() {
        let rotation = CameraGeometry.makeRotation(xDegrees: 25, yDegrees: -40, zDegrees: 15)
        let arkit = CameraGeometry.makeTransform(
            rotation: rotation,
            translation: SIMD3(1.5, -0.75, 2.25)
        )
        let opencv = CameraGeometry.opencvCameraFromWorld(arkitWorldFromCamera: arkit)
        let recovered = (CameraGeometry.arkitToOpenCV.inverse * opencv).inverse

        for c in 0..<4 {
            for r in 0..<4 {
                let expected = arkit[r, c]
                let actual = recovered[r, c]
                #expect(abs(expected - actual) < 1e-5)
            }
        }
    }

    @Test("Reprojection with multi-axis rotation lands on the known pixel")
    func multiAxisReprojection() {
        // Construct an OpenCV camera pose independently, then derive the ARKit
        // world_from_camera that should export to it. Project a known camera-space
        // point and assert the pixel.
        let opencvRotation = CameraGeometry.makeRotation(xDegrees: 18, yDegrees: -27, zDegrees: 33)
        let cameraFromWorld = CameraGeometry.makeTransform(
            rotation: opencvRotation,
            translation: SIMD3(0.4, -1.2, 0.8)
        )

        // ARKit world_from_camera = inverse(diag * camera_from_world)
        let arkitWorldFromCamera = (CameraGeometry.arkitToOpenCV * cameraFromWorld).inverse
        let exported = CameraGeometry.opencvCameraFromWorld(arkitWorldFromCamera: arkitWorldFromCamera)

        for c in 0..<4 {
            for r in 0..<4 {
                #expect(abs(exported[r, c] - cameraFromWorld[r, c]) < 1e-5)
            }
        }

        let fx = 1340.0
        let fy = 1340.0
        let cx = 960.0
        let cy = 720.0
        let cameraPoint = SIMD3<Double>(0.25, -0.15, 2.0)
        let expectedPixel = SIMD2(fx * (cameraPoint.x / cameraPoint.z) + cx,
                                  fy * (cameraPoint.y / cameraPoint.z) + cy)

        let worldPoint4 = cameraFromWorld.inverse * SIMD4(
            Float(cameraPoint.x),
            Float(cameraPoint.y),
            Float(cameraPoint.z),
            1
        )
        let worldPoint = SIMD3(Double(worldPoint4.x), Double(worldPoint4.y), Double(worldPoint4.z))

        let projected = CameraGeometry.project(
            worldPoint: worldPoint,
            cameraFromWorld: exported,
            fx: fx,
            fy: fy,
            cx: cx,
            cy: cy
        )

        #expect(projected != nil)
        #expect(abs(projected!.x - expectedPixel.x) < 1e-4)
        #expect(abs(projected!.y - expectedPixel.y) < 1e-4)
    }

    @Test("Identity and pure translation also reproject")
    func identityAndTranslation() {
        let arkit = matrix_identity_float4x4
        let opencv = CameraGeometry.opencvCameraFromWorld(arkitWorldFromCamera: arkit)
        // For identity ARKit, camera_from_world OpenCV is just the flip matrix.
        #expect(abs(opencv.columns.1.y + 1) < 1e-5)
        #expect(abs(opencv.columns.2.z + 1) < 1e-5)

        // Point 2 m in front of an identity ARKit camera (looks down −Z).
        let identityPixel = CameraGeometry.project(
            worldPoint: SIMD3(0, 0, -2),
            cameraFromWorld: opencv,
            fx: 1000,
            fy: 1000,
            cx: 960,
            cy: 720
        )
        #expect(identityPixel != nil)
        #expect(abs(identityPixel!.x - 960) < 1e-4)
        #expect(abs(identityPixel!.y - 720) < 1e-4)

        var translated = matrix_identity_float4x4
        translated.columns.3 = SIMD4(2, 3, 4, 1)
        let exported = CameraGeometry.opencvCameraFromWorld(arkitWorldFromCamera: translated)
        // Same optical axis, 2 m ahead of the translated camera.
        let pixel = CameraGeometry.project(
            worldPoint: SIMD3(2, 3, 2),
            cameraFromWorld: exported,
            fx: 1000,
            fy: 1000,
            cx: 960,
            cy: 720
        )
        #expect(pixel != nil)
        #expect(abs(pixel!.x - 960) < 1e-4)
        #expect(abs(pixel!.y - 720) < 1e-4)
    }

    @Test("Intrinsics scale to pixel-buffer dimensions")
    func intrinsicsScaling() {
        let scaled = CameraGeometry.scaleIntrinsics(
            fx: 1000,
            fy: 1000,
            cx: 500,
            cy: 400,
            fromWidth: 1000,
            fromHeight: 800,
            toWidth: 1920,
            toHeight: 1440
        )
        #expect(abs(scaled.fx - 1920) < 1e-4)
        #expect(abs(scaled.fy - 1800) < 1e-4)
        #expect(abs(scaled.cx - 960) < 1e-4)
        #expect(abs(scaled.cy - 720) < 1e-4)
    }

    @Test("Portrait hold votes arkit_landscape_sensor")
    func portraitHoldVote() {
        // OpenCV camera_from_world whose world +Y (up) lands on camera X:
        // |M[0][1]| >= |M[1][1]| → portrait (USB-C down).
        let portrait = CameraGeometry.makeTransform(
            rotation: CameraGeometry.makeRotation(xDegrees: 0, yDegrees: 0, zDegrees: 90),
            translation: .zero
        )
        let ux = portrait.columns.1.x
        let uy = portrait.columns.1.y
        #expect(abs(ux) >= abs(uy))

        let voted = CameraGeometry.voteHoldOrientation(opencvCameraFromWorld: [portrait, portrait])
        #expect(voted == .arkitLandscapeSensor)
    }

    @Test("Upright landscape hold votes identity")
    func landscapeHoldVote() {
        // ARKit identity exported to OpenCV: world +Y lands on camera -Y.
        let landscape = CameraGeometry.arkitToOpenCV
        let ux = landscape.columns.1.x
        let uy = landscape.columns.1.y
        #expect(abs(ux) < abs(uy))
        #expect(uy < 0)

        let voted = CameraGeometry.voteHoldOrientation(opencvCameraFromWorld: [landscape, landscape])
        #expect(voted == .identity)
    }

    @Test("Inverted landscape hold votes rotate_180")
    func invertedLandscapeHoldVote() {
        let rotate180 = CameraGeometry.makeTransform(
            rotation: CameraGeometry.makeRotation(xDegrees: 0, yDegrees: 0, zDegrees: 180),
            translation: .zero
        )
        let landscape = rotate180 * CameraGeometry.arkitToOpenCV
        let ux = landscape.columns.1.x
        let uy = landscape.columns.1.y
        #expect(abs(ux) < abs(uy))
        #expect(uy > 0)

        let voted = CameraGeometry.voteHoldOrientation(
            opencvCameraFromWorld: [landscape, landscape]
        )
        #expect(voted == .rotate180)
    }

    @Test("Majority portrait wins a mixed trajectory")
    func majorityPortraitWins() {
        let portrait = CameraGeometry.makeTransform(
            rotation: CameraGeometry.makeRotation(xDegrees: 0, yDegrees: 0, zDegrees: 90),
            translation: .zero
        )
        let landscape = CameraGeometry.arkitToOpenCV
        let voted = CameraGeometry.voteHoldOrientation(
            opencvCameraFromWorld: [portrait, portrait, landscape]
        )
        #expect(voted == .arkitLandscapeSensor)
    }

    @Test("Chosen mode warns from current hold without changing final vote")
    func chosenModeMismatchIsIndependentFromVote() {
        let portrait = CameraGeometry.makeTransform(
            rotation: CameraGeometry.makeRotation(xDegrees: 0, yDegrees: 0, zDegrees: 90),
            translation: .zero
        )
        let landscape = CameraGeometry.arkitToOpenCV

        #expect(
            CameraGeometry.isHoldMismatch(
                opencvCameraFromWorld: landscape,
                chosenMode: .portrait
            )
        )
        #expect(
            !CameraGeometry.isHoldMismatch(
                opencvCameraFromWorld: portrait,
                chosenMode: .portrait
            )
        )

        let voted = CameraGeometry.voteHoldOrientation(
            opencvCameraFromWorld: [landscape, landscape, portrait]
        )
        #expect(voted == .identity)
    }

    @Test("Only a clear hold mismatch blocks frames; floor and ceiling views never do")
    func clearHoldMismatch() {
        let portrait = CameraGeometry.makeTransform(
            rotation: CameraGeometry.makeRotation(xDegrees: 0, yDegrees: 0, zDegrees: 90),
            translation: .zero
        )
        let landscape = CameraGeometry.arkitToOpenCV
        let lookingAtFloor = CameraGeometry.makeTransform(
            rotation: CameraGeometry.makeRotation(xDegrees: 85, yDegrees: 0, zDegrees: 0),
            translation: .zero
        ) * landscape
        let diagonal = CameraGeometry.makeTransform(
            rotation: CameraGeometry.makeRotation(xDegrees: 0, yDegrees: 0, zDegrees: 40),
            translation: .zero
        )

        #expect(CameraGeometry.isClearHoldMismatch(opencvCameraFromWorld: landscape, chosenMode: .portrait))
        #expect(CameraGeometry.isClearHoldMismatch(opencvCameraFromWorld: portrait, chosenMode: .landscape))
        #expect(!CameraGeometry.isClearHoldMismatch(opencvCameraFromWorld: portrait, chosenMode: .portrait))
        #expect(!CameraGeometry.isClearHoldMismatch(opencvCameraFromWorld: lookingAtFloor, chosenMode: .portrait))
        #expect(!CameraGeometry.isClearHoldMismatch(opencvCameraFromWorld: diagonal, chosenMode: .portrait))
        #expect(!CameraGeometry.isClearHoldMismatch(opencvCameraFromWorld: diagonal, chosenMode: .landscape))
    }

    /// `UIApplication.isIdleTimerDisabled` only sticks inside a host app.
    /// As a Swift package these tests run without one, so the system flag is
    /// checked only when an app hosts the test bundle.
    private static let hasHostApp = Bundle.main.bundlePath.hasSuffix(".app")

    @Test("Capture idle timer lock restores the system default")
    @MainActor
    func captureIdleTimerLock() {
        CaptureIdleTimerLock.restore()
        defer { CaptureIdleTimerLock.restore() }

        CaptureIdleTimerLock.setDisabled(true)
        #expect(CaptureIdleTimerLock.isDisabled)
        if Self.hasHostApp { #expect(UIApplication.shared.isIdleTimerDisabled) }

        CaptureIdleTimerLock.restore()
        #expect(!CaptureIdleTimerLock.isDisabled)
        #expect(!UIApplication.shared.isIdleTimerDisabled)
    }

    @Test("Releasing one idle timer holder keeps the screen awake for another")
    @MainActor
    func idleTimerLockHolders() {
        let secondHolder = "secondary-\(UUID().uuidString)"
        defer {
            CaptureIdleTimerLock.restore()
            CaptureIdleTimerLock.restore(holder: secondHolder)
        }

        CaptureIdleTimerLock.setDisabled(true)
        CaptureIdleTimerLock.setDisabled(true, holder: secondHolder)
        CaptureIdleTimerLock.restore()
        #expect(CaptureIdleTimerLock.isDisabled)
        if Self.hasHostApp { #expect(UIApplication.shared.isIdleTimerDisabled) }

        CaptureIdleTimerLock.restore(holder: secondHolder)
        #expect(!CaptureIdleTimerLock.isDisabled)
        #expect(!UIApplication.shared.isIdleTimerDisabled)
    }
}

private extension simd_float4x4 {
    subscript(row: Int, column: Int) -> Float {
        let col: SIMD4<Float>
        switch column {
        case 0: col = columns.0
        case 1: col = columns.1
        case 2: col = columns.2
        default: col = columns.3
        }
        switch row {
        case 0: return col.x
        case 1: return col.y
        case 2: return col.z
        default: return col.w
        }
    }
}
