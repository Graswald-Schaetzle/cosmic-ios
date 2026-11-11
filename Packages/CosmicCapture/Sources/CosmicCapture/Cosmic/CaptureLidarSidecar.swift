import Foundation

/// Describes the LiDAR sidecar files of one capture (`lidar/metadata.json`).
struct CaptureLidarMetadata: Codable, Sendable, Equatable {
    struct Mesh: Codable, Sendable, Equatable {
        var file: String
        var vertexCount: Int
        var faceCount: Int
        var anchorCount: Int
        var hasClassification: Bool
        var groups: [String]

        enum CodingKeys: String, CodingKey {
            case file
            case vertexCount = "vertex_count"
            case faceCount = "face_count"
            case anchorCount = "anchor_count"
            case hasClassification = "has_classification"
            case groups
        }
    }

    struct Depth: Codable, Sendable, Equatable {
        var directory: String
        var confidenceDirectory: String?
        var frameCount: Int
        var encoding: String
        var note: String

        enum CodingKeys: String, CodingKey {
            case directory
            case confidenceDirectory = "confidence_directory"
            case frameCount = "frame_count"
            case encoding
            case note
        }
    }

    var schemaVersion: Int
    var createdAt: Date
    var worldFrame: String
    var mesh: Mesh?
    var depth: Depth?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case worldFrame = "world_frame"
        case mesh
        case depth
    }

    static let currentSchemaVersion = 1
    static let worldFrameDescription =
        "ARKit world: gravity-aligned, right-handed, +Y up, metres. Same world as the "
        + "poses in bundle/cameras/camera_trajectory.json, which stores OpenCV "
        + "camera_from_world = diag(1,-1,-1,1) * inverse(ARKit camera transform)."
}

/// Writes the mesh and metadata once a capture is finalized.
enum CaptureLidarSidecarWriter {
    @discardableResult
    static func write(
        mesh: CaptureLidarMesh?,
        captureID: UUID,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> CaptureLidarMetadata {
        let root = CapturePaths.lidarRoot(for: captureID)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        var meshInfo: CaptureLidarMetadata.Mesh?
        if let mesh, !mesh.isEmpty {
            let glb = try CaptureLidarMeshGLBEncoder.encode(mesh)
            try glb.write(to: CapturePaths.lidarMesh(for: captureID), options: .atomic)
            meshInfo = .init(
                file: "mesh.glb",
                vertexCount: mesh.vertexCount,
                faceCount: mesh.faceCount,
                anchorCount: mesh.anchorCount,
                hasClassification: mesh.hasClassification,
                groups: mesh.groups.map(\.name)
            )
        }

        var depthInfo: CaptureLidarMetadata.Depth?
        let depthCount = pngCount(in: CapturePaths.lidarDepthDir(for: captureID), fileManager)
        if depthCount > 0 {
            let confidenceCount = pngCount(
                in: CapturePaths.lidarConfidenceDir(for: captureID), fileManager
            )
            depthInfo = .init(
                directory: "depth",
                confidenceDirectory: confidenceCount > 0 ? "confidence" : nil,
                frameCount: depthCount,
                encoding: "16-bit grayscale PNG, millimetres, 0 = no measurement",
                note: "Depth_NNNNNN.png belongs to bundle/images/Image_NNNNNN.jpg. The depth "
                    + "map covers the same field of view at a lower resolution; scale the "
                    + "frame's intrinsics by depth size / image size. Confidence values are "
                    + "ARConfidenceLevel raw values (0 low, 1 medium, 2 high)."
            )
        }

        let metadata = CaptureLidarMetadata(
            schemaVersion: CaptureLidarMetadata.currentSchemaVersion,
            createdAt: now,
            worldFrame: CaptureLidarMetadata.worldFrameDescription,
            mesh: meshInfo,
            depth: depthInfo
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(
            to: CapturePaths.lidarMetadata(for: captureID), options: .atomic
        )
        return metadata
    }

    private static func pngCount(in directory: URL, _ fileManager: FileManager) -> Int {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".png") }.count
    }
}
