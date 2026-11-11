import ARKit
import Foundation
import simd

struct CapturePointCloud: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case lidarMesh = "lidar_mesh"
        case lidarMeshAndDepth = "lidar_mesh_and_depth"
        case trackingFeatures = "tracking_features"
    }

    let positions: [SIMD3<Float>]
    let distancesFromCaptureOriginM: [Float]
    let colorsRGB: [SIMD3<UInt8>]?
    let source: Source

    init(
        positions: [SIMD3<Float>],
        colorsRGB: [SIMD3<UInt8>]? = nil,
        source: Source = .lidarMesh
    ) {
        precondition(colorsRGB == nil || colorsRGB?.count == positions.count)
        self.positions = positions
        distancesFromCaptureOriginM = positions.map(simd_length)
        self.colorsRGB = colorsRGB
        self.source = source
    }

    init(
        positions: [SIMD3<Float>],
        distancesFromCaptureOriginM: [Float],
        colorsRGB: [SIMD3<UInt8>]? = nil,
        source: Source
    ) {
        precondition(positions.count == distancesFromCaptureOriginM.count)
        precondition(colorsRGB == nil || colorsRGB?.count == positions.count)
        self.positions = positions
        self.distancesFromCaptureOriginM = distancesFromCaptureOriginM
        self.colorsRGB = colorsRGB
        self.source = source
    }

    var hasSceneColors: Bool {
        colorsRGB?.count == positions.count && !positions.isEmpty
    }
}

/// In-memory point cloud for the live preview and the finish review.
///
/// Never written to disk and never part of the bundle. LiDAR devices sample
/// scene-reconstruction mesh vertices; other devices keep bounded ARKit
/// tracking features for visual guidance only.
enum CapturePointCloudStore {
    static let maxPointCount = 150_000
    static let maxSparsePointCount = 30_000
    /// Live-display budget. Small enough that snapshot preparation stays cheap
    /// on the main actor during a scan; the finish review keeps `maxPointCount`.
    static let maxLivePointCount = 15_000

    static func makePreviewPoints(from anchors: [ARMeshAnchor]) -> [SIMD3<Float>] {
        let sortedAnchors = anchors.sorted {
            $0.identifier.uuidString < $1.identifier.uuidString
        }
        let totalVertexCount = sortedAnchors.reduce(0) {
            $0 + $1.geometry.vertices.count
        }
        guard totalVertexCount > 0 else { return [] }

        let sampleStride = max(
            1,
            Int(ceil(Double(totalVertexCount) / Double(maxPointCount)))
        )
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(min(totalVertexCount, maxPointCount))

        var globalVertexIndex = 0
        for anchor in sortedAnchors {
            appendPoints(
                from: anchor,
                sampleStride: sampleStride,
                globalVertexIndex: &globalVertexIndex,
                to: &points
            )
        }
        return points
    }

    /// Builds the live-display cloud directly at its budget.
    ///
    /// Unlike the review path (`makePreviewPoints` up to 150k, an archive
    /// merge, and a display resample), this samples archived chunks and active
    /// anchors once, with one stride proportional to their combined size, so
    /// the main actor never materializes the full-resolution cloud during a
    /// scan. Retired and active regions are represented fairly because the
    /// stride is global across both.
    static func makeLivePreviewPoints(
        from anchors: [ARMeshAnchor],
        archive: CaptureMeshPreviewArchive,
        limit: Int = maxLivePointCount
    ) -> [SIMD3<Float>] {
        let sortedAnchors = anchors.sorted {
            $0.identifier.uuidString < $1.identifier.uuidString
        }
        let archivedChunks = archive.sortedChunks()
        let activeVertexCount = sortedAnchors.reduce(0) {
            $0 + $1.geometry.vertices.count
        }
        let archivedPointCount = archivedChunks.reduce(0) { $0 + $1.count }
        let totalCount = activeVertexCount + archivedPointCount
        guard totalCount > 0, limit > 0 else { return [] }

        let sampleStride = max(
            1,
            Int(ceil(Double(totalCount) / Double(limit)))
        )
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(min(totalCount, limit))

        var globalVertexIndex = 0
        for chunk in archivedChunks {
            // Archived chunks were produced by `makePreviewPoints`, so their
            // points are already finite; jump by the stride instead of
            // visiting every point.
            let remainder = globalVertexIndex % sampleStride
            let firstOffset = remainder == 0 ? 0 : sampleStride - remainder
            var index = firstOffset
            while index < chunk.count {
                points.append(chunk[index])
                index += sampleStride
            }
            globalVertexIndex += chunk.count
        }
        for anchor in sortedAnchors {
            appendPoints(
                from: anchor,
                sampleStride: sampleStride,
                globalVertexIndex: &globalVertexIndex,
                to: &points
            )
        }
        return points
    }

    private static func appendPoints(
        from anchor: ARMeshAnchor,
        sampleStride: Int,
        globalVertexIndex: inout Int,
        to points: inout [SIMD3<Float>]
    ) {
        let vertices = anchor.geometry.vertices
        for vertexIndex in 0..<vertices.count {
            defer { globalVertexIndex += 1 }
            guard globalVertexIndex % sampleStride == 0 else { continue }

            let localPoint = vertex(at: vertexIndex, from: vertices)
            let worldPoint = anchor.transform * SIMD4<Float>(localPoint, 1)
            let point = SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }
            points.append(point)
        }
    }

    private static func vertex(
        at index: Int,
        from source: ARGeometrySource
    ) -> SIMD3<Float> {
        let pointer = source.buffer.contents()
            .advanced(by: source.offset + source.stride * index)
        return SIMD3<Float>(
            pointer.load(as: Float.self),
            pointer.load(fromByteOffset: 4, as: Float.self),
            pointer.load(fromByteOffset: 8, as: Float.self)
        )
    }
}

struct CaptureSparsePointCloudAccumulator: Sendable {
    static let maxPointCount = CapturePointCloudStore.maxSparsePointCount
    static let maxPointsPerObservation = 250
    static let minimumObservationIntervalSeconds: TimeInterval = 0.2
    static let voxelSizeM: Float = 0.03
    static let maxDistanceFromCameraM: Float = 12

    private struct VoxelKey: Hashable, Sendable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    private var points: [SIMD3<Float>] = []
    private var occupiedVoxels: Set<VoxelKey> = []
    private var lastObservationTimestamp: TimeInterval?

    var pointCloud: CapturePointCloud? {
        guard !points.isEmpty else { return nil }
        return CapturePointCloud(
            positions: points,
            source: .trackingFeatures
        )
    }

    mutating func reset() {
        points.removeAll(keepingCapacity: false)
        occupiedVoxels.removeAll(keepingCapacity: false)
        lastObservationTimestamp = nil
    }

    mutating func observe(
        points observedPoints: [SIMD3<Float>],
        cameraPosition: SIMD3<Float>,
        timestamp: TimeInterval
    ) {
        observedPoints.withUnsafeBufferPointer {
            observe(
                points: $0,
                cameraPosition: cameraPosition,
                timestamp: timestamp
            )
        }
    }

    mutating func observe(
        points observedPoints: UnsafeBufferPointer<SIMD3<Float>>,
        cameraPosition: SIMD3<Float>,
        timestamp: TimeInterval
    ) {
        guard self.points.count < Self.maxPointCount,
              timestamp.isFinite,
              shouldObserve(timestamp: timestamp),
              !observedPoints.isEmpty
        else {
            return
        }
        lastObservationTimestamp = timestamp

        let remainingCapacity = Self.maxPointCount - self.points.count
        let observationLimit = min(
            Self.maxPointsPerObservation,
            remainingCapacity
        )
        let stride = max(
            1,
            Int(ceil(Double(observedPoints.count) / Double(observationLimit)))
        )

        var acceptedCount = 0
        for index in Swift.stride(
            from: 0,
            to: observedPoints.count,
            by: stride
        ) {
            guard acceptedCount < observationLimit else { break }
            let point = observedPoints[index]
            guard isValid(point, cameraPosition: cameraPosition),
                  let voxel = voxelKey(for: point),
                  occupiedVoxels.insert(voxel).inserted
            else {
                continue
            }
            self.points.append(point)
            acceptedCount += 1
        }
    }

    private func shouldObserve(timestamp: TimeInterval) -> Bool {
        guard let lastObservationTimestamp else { return true }
        return timestamp - lastObservationTimestamp
            >= Self.minimumObservationIntervalSeconds
    }

    private func isValid(
        _ point: SIMD3<Float>,
        cameraPosition: SIMD3<Float>
    ) -> Bool {
        point.isFinite
            && cameraPosition.isFinite
            && simd_distance(point, cameraPosition)
                <= Self.maxDistanceFromCameraM
    }

    private func voxelKey(for point: SIMD3<Float>) -> VoxelKey? {
        let scaled = point / Self.voxelSizeM
        guard scaled.x >= Float(Int32.min),
              scaled.x <= Float(Int32.max),
              scaled.y >= Float(Int32.min),
              scaled.y <= Float(Int32.max),
              scaled.z >= Float(Int32.min),
              scaled.z <= Float(Int32.max)
        else {
            return nil
        }
        return VoxelKey(
            x: Int32(floor(scaled.x)),
            y: Int32(floor(scaled.y)),
            z: Int32(floor(scaled.z))
        )
    }
}

private extension SIMD3 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

/// Preserves original mesh vertices when ARKit removes an anchor from its live
/// map. This is preview-only: retired geometry never feeds live gap guidance.
struct CaptureMeshPreviewArchive {
    private(set) var chunks: [UUID: [SIMD3<Float>]] = [:]
    var pointLimit = 450_000

    mutating func retain(id: UUID, points: [SIMD3<Float>]) {
        guard !points.isEmpty else { return }
        chunks[id] = points
        let count = chunks.values.reduce(0) { $0 + $1.count }
        guard count > pointLimit else { return }
        for id in chunks.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let points = chunks[id] else { continue }
            let budget = max(1, points.count * pointLimit / count)
            chunks[id] = Self.sample(points, limit: budget)
        }
    }

    mutating func remove(id: UUID) { chunks.removeValue(forKey: id) }

    /// Chunks in a deterministic order so repeated live samples stay stable.
    func sortedChunks() -> [[SIMD3<Float>]] {
        chunks.keys
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { chunks[$0] }
    }

    func previewPoints(active: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard !chunks.isEmpty else { return active }
        let retained = chunks.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { chunks[$0] ?? [] }
        return Self.sample(retained + active, limit: CapturePointCloudStore.maxPointCount)
    }

    private static func sample(_ points: [SIMD3<Float>], limit: Int) -> [SIMD3<Float>] {
        guard points.count > limit else { return points }
        return (0..<limit).map { points[$0 * points.count / limit] }
    }
}

extension CapturePointCloud {
    /// Keep the live display inexpensive without modifying the review cloud.
    func livePreviewSample(limit: Int = 30_000) -> CapturePointCloud {
        guard limit > 0, positions.count > limit else { return self }
        let indices = (0..<limit).map { $0 * positions.count / limit }
        return CapturePointCloud(positions: indices.map { positions[$0] },
            distancesFromCaptureOriginM: indices.map { distancesFromCaptureOriginM[$0] },
            colorsRGB: colorsRGB.map { colors in indices.map { colors[$0] } }, source: source)
    }
}
