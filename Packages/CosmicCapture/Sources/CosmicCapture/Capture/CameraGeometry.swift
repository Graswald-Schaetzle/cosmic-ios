import Foundation
import simd

/// Hold orientation voted from the trajectory, using the values the optional
/// `cameras/orientation.json` accepts. Kept locally to orient thumbnails;
/// pixels always stay ARKit native 1920×1440.
enum CaptureCameraOrientation: String, Codable, Sendable, Hashable {
    case arkitLandscapeSensor = "arkit_landscape_sensor"
    case identity = "identity"
    case rotate180 = "rotate_180"
}

enum CaptureHoldMode: String, CaseIterable, Identifiable, Sendable {
    case portrait
    case landscape

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }
}

/// Pure camera math for ARKit → OpenCV conversion and intrinsics helpers.
enum CameraGeometry {
    /// OpenCV convention flip: +Y down, +Z forward relative to ARKit (−Z forward, +Y up).
    static let arkitToOpenCV = simd_float4x4(
        SIMD4(1, 0, 0, 0),
        SIMD4(0, -1, 0, 0),
        SIMD4(0, 0, -1, 0),
        SIMD4(0, 0, 0, 1)
    )

    /// Contract conversion:
    /// `opencv_camera_from_world = diag(1,-1,-1,1) × inverse(arkit_world_from_camera)`
    static func opencvCameraFromWorld(arkitWorldFromCamera: simd_float4x4) -> simd_float4x4 {
        arkitToOpenCV * arkitWorldFromCamera.inverse
    }

    /// Majority vote of phone hold from OpenCV `camera_from_world` (row-major).
    /// World +Y is up (`worldAlignment = .gravity`). For each 4×4 M:
    /// `|M[0][1]| >= |M[1][1]|` votes portrait. Landscape votes use the
    /// sign of `M[1][1]` to distinguish the two physical phone directions.
    static func voteHoldOrientation(
        opencvCameraFromWorld: [simd_float4x4]
    ) -> CaptureCameraOrientation {
        var portraitVotes = 0
        var uprightLandscapeVotes = 0
        var invertedLandscapeVotes = 0
        for matrix in opencvCameraFromWorld {
            let upX = matrix.columns.1.x
            let upY = matrix.columns.1.y
            if abs(upX) >= abs(upY) {
                portraitVotes += 1
            } else if upY < 0 {
                uprightLandscapeVotes += 1
            } else {
                invertedLandscapeVotes += 1
            }
        }
        let landscapeVotes = uprightLandscapeVotes + invertedLandscapeVotes
        if portraitVotes >= landscapeVotes {
            return .arkitLandscapeSensor
        }
        return invertedLandscapeVotes > uprightLandscapeVotes
            ? .rotate180
            : .identity
    }

    /// Current physical hold from one OpenCV `camera_from_world` pose.
    static func holdMode(
        opencvCameraFromWorld: simd_float4x4
    ) -> CaptureHoldMode {
        let ux = opencvCameraFromWorld.columns.1.x
        let uy = opencvCameraFromWorld.columns.1.y
        return abs(ux) >= abs(uy) ? .portrait : .landscape
    }

    static func isHoldMismatch(
        opencvCameraFromWorld: simd_float4x4,
        chosenMode: CaptureHoldMode
    ) -> Bool {
        holdMode(opencvCameraFromWorld: opencvCameraFromWorld) != chosenMode
    }

    /// True only when the pose is unambiguously in the other hold: the camera
    /// points at least 30° away from straight up or down, and world up lies
    /// within about 27° of the other hold's image axis. Near-vertical views
    /// (floor and ceiling passes) have no defined hold and never count.
    static func isClearHoldMismatch(
        opencvCameraFromWorld: simd_float4x4,
        chosenMode: CaptureHoldMode
    ) -> Bool {
        let ux = abs(opencvCameraFromWorld.columns.1.x)
        let uy = abs(opencvCameraFromWorld.columns.1.y)
        guard (ux * ux + uy * uy).squareRoot() >= 0.5 else { return false }
        switch chosenMode {
        case .portrait:
            return uy >= 2 * ux
        case .landscape:
            return ux >= 2 * uy
        }
    }

    static func scaleIntrinsics(
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float,
        fromWidth: Int,
        fromHeight: Int,
        toWidth: Int,
        toHeight: Int
    ) -> (fx: Float, fy: Float, cx: Float, cy: Float) {
        let scaleX = Float(toWidth) / Float(fromWidth)
        let scaleY = Float(toHeight) / Float(fromHeight)
        return (
            fx: fx * scaleX,
            fy: fy * scaleY,
            cx: cx * scaleX,
            cy: cy * scaleY
        )
    }

    /// Project a world point through OpenCV camera_from_world + pinhole intrinsics.
    static func project(
        worldPoint: SIMD3<Double>,
        cameraFromWorld: simd_float4x4,
        fx: Double,
        fy: Double,
        cx: Double,
        cy: Double
    ) -> SIMD2<Double>? {
        let p = cameraFromWorld * SIMD4(
            Float(worldPoint.x),
            Float(worldPoint.y),
            Float(worldPoint.z),
            1
        )
        guard abs(p.z) > 1e-8 else { return nil }
        let x = Double(p.x) / Double(p.z)
        let y = Double(p.y) / Double(p.z)
        return SIMD2(fx * x + cx, fy * y + cy)
    }

    static func makeRotation(xDegrees: Float, yDegrees: Float, zDegrees: Float) -> simd_float3x3 {
        let x = xDegrees * .pi / 180
        let y = yDegrees * .pi / 180
        let z = zDegrees * .pi / 180
        let rx = simd_float3x3(
            SIMD3(1, 0, 0),
            SIMD3(0, cos(x), sin(x)),
            SIMD3(0, -sin(x), cos(x))
        )
        let ry = simd_float3x3(
            SIMD3(cos(y), 0, -sin(y)),
            SIMD3(0, 1, 0),
            SIMD3(sin(y), 0, cos(y))
        )
        let rz = simd_float3x3(
            SIMD3(cos(z), sin(z), 0),
            SIMD3(-sin(z), cos(z), 0),
            SIMD3(0, 0, 1)
        )
        return rz * ry * rx
    }

    static func makeTransform(rotation: simd_float3x3, translation: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(rotation.columns.0, 0),
            SIMD4(rotation.columns.1, 0),
            SIMD4(rotation.columns.2, 0),
            SIMD4(translation, 1)
        )
    }
}
