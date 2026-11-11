import Foundation

/// LiDAR sidecar data for one capture. Echo-3 does not accept depth data, so
/// none of this is part of `bundle/` or the uploaded ZIP.
///
/// ```
/// Documents/Captures/<id>/lidar/
/// ├── mesh.glb                       ← room mesh in the ARKit world frame
/// ├── metadata.json
/// ├── depth/Depth_000001.png         ← 16-bit millimetres, one per saved frame
/// └── confidence/Confidence_000001.png
/// ```
extension CapturePaths {
    static func lidarRoot(for id: UUID) -> URL {
        captureRoot(for: id).appendingPathComponent("lidar", isDirectory: true)
    }

    static func lidarMesh(for id: UUID) -> URL {
        lidarRoot(for: id).appendingPathComponent("mesh.glb")
    }

    static func lidarMetadata(for id: UUID) -> URL {
        lidarRoot(for: id).appendingPathComponent("metadata.json")
    }

    static func lidarDepthDir(for id: UUID) -> URL {
        lidarRoot(for: id).appendingPathComponent("depth", isDirectory: true)
    }

    static func lidarConfidenceDir(for id: UUID) -> URL {
        lidarRoot(for: id).appendingPathComponent("confidence", isDirectory: true)
    }

    /// Same one-based index as `images/Image_%06d.jpg`.
    static func lidarDepth(for id: UUID, index: Int) -> URL {
        lidarDepthDir(for: id).appendingPathComponent(String(format: "Depth_%06d.png", index))
    }

    static func lidarConfidence(for id: UUID, index: Int) -> URL {
        lidarConfidenceDir(for: id)
            .appendingPathComponent(String(format: "Confidence_%06d.png", index))
    }
}
