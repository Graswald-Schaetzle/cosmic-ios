import Foundation
import simd

struct CaptureTrajectory: Sendable {
    let arkitWorldFromCamera: [simd_float4x4]

    var cameraPositions: [SIMD3<Float>] {
        arkitWorldFromCamera.map {
            SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z)
        }
    }
}

/// Reads a finished bundle's poses back into ARKit's convention. Useful for
/// checking the OpenCV conversion round-trips and for drawing a path preview.
enum CaptureTrajectoryStore {
    static func load(
        trajectoryURL: URL,
        frameRecordsDirectoryURL: URL
    ) throws -> CaptureTrajectory {
        if let trajectory = try? loadContractTrajectory(from: trajectoryURL),
           !trajectory.arkitWorldFromCamera.isEmpty
        {
            return trajectory
        }
        return try loadFrameRecords(from: frameRecordsDirectoryURL)
    }

    private static func loadContractTrajectory(
        from url: URL
    ) throws -> CaptureTrajectory {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let matrices = try JSONDecoder().decode([[[Double]]].self, from: data)
        let transforms = try matrices.map { rows -> simd_float4x4 in
            guard let opencvCameraFromWorld = simd_float4x4.fromRowMajor(rows) else {
                throw CaptureTrajectoryError.invalidMatrix
            }
            let arkitWorldFromCamera =
                opencvCameraFromWorld.inverse * CameraGeometry.arkitToOpenCV
            guard arkitWorldFromCamera.isFinite else {
                throw CaptureTrajectoryError.invalidMatrix
            }
            return arkitWorldFromCamera
        }
        guard transforms.count <= CapturePaths.maxFrames else {
            throw CaptureTrajectoryError.tooManyFrames
        }
        return CaptureTrajectory(arkitWorldFromCamera: transforms)
    }

    private static func loadFrameRecords(
        from directoryURL: URL
    ) throws -> CaptureTrajectory {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("Frame_") && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard urls.count <= CapturePaths.maxFrames else {
            throw CaptureTrajectoryError.tooManyFrames
        }

        let decoder = JSONDecoder()
        let transforms = try urls.map { url -> simd_float4x4 in
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let record = try decoder.decode(CaptureFrameRecord.self, from: data)
            guard let transform = simd_float4x4.fromRowMajor(
                record.arkitWorldFromCamera
            ), transform.isFinite
            else {
                throw CaptureTrajectoryError.invalidMatrix
            }
            return transform
        }
        guard !transforms.isEmpty else {
            throw CaptureTrajectoryError.emptyTrajectory
        }
        return CaptureTrajectory(arkitWorldFromCamera: transforms)
    }
}

enum CaptureTrajectoryError: Error {
    case emptyTrajectory
    case invalidMatrix
    case tooManyFrames
}

private extension simd_float4x4 {
    var isFinite: Bool {
        columns.0.isFinite
            && columns.1.isFinite
            && columns.2.isFinite
            && columns.3.isFinite
    }
}

private extension SIMD4 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }
}
