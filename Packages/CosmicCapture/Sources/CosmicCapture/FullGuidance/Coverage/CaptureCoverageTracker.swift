import Foundation
import simd

/// Two-level display state per surface voxel. `seen` renders the faint fill,
/// `solid` the firmer fill once a second, angularly distinct committed view
/// observed the surface. Coverage stays a vector internally — never a single
/// completion number for the user.
enum CaptureCoverageDisplayState: UInt8, Sendable {
    case seen = 0
    case solid = 1
}

/// One depth point from a committed keyframe, in world space.
struct CaptureCoveragePoint: Sendable {
    let position: SIMD3<Float>
    /// ARKit depth confidence: 0 low, 1 medium, 2 high.
    let confidence: UInt8
}

/// All coverage evidence from one committed keyframe.
struct CaptureCoverageObservation: Sendable {
    let timestamp: TimeInterval
    let cameraPosition: SIMD3<Float>
    let points: [CaptureCoveragePoint]
}

/// Structural face classes we aggregate for the readout and dwell nudges.
enum CaptureStructuralCategory: String, CaseIterable, Sendable {
    case floor
    case wall
    case ceiling
}

/// One mesh face with classification, extracted from ARKit types elsewhere so
/// the aggregation stays testable.
struct CaptureClassifiedFace: Sendable {
    let center: SIMD3<Float>
    let normal: SIMD3<Float>
    let areaM2: Float
    let category: CaptureStructuralCategory
}

/// Per-category coverage for the live readout line and the dwell nudge.
struct CaptureStructuralSummary: Equatable, Sendable {
    struct CategoryCoverage: Equatable, Sendable {
        var totalAreaM2: Float = 0
        var coveredAreaM2: Float = 0

        var coveredFraction: Float {
            totalAreaM2 > 0 ? coveredAreaM2 / totalAreaM2 : 0
        }
    }

    var floor = CategoryCoverage()
    var ceiling = CategoryCoverage()
    var wallsTotal = 0
    var wallsCovered = 0
    var wallArea = CategoryCoverage()

    /// Categories that demonstrably exist in the mesh (enough classified
    /// area) yet have zero committed coverage — the only honest basis for a
    /// "Don't forget the ceiling" nudge.
    func nudgeCandidates(
        minimumAreaM2: Float = 1
    ) -> [CaptureStructuralCategory] {
        var result: [CaptureStructuralCategory] = []
        if ceiling.totalAreaM2 >= minimumAreaM2, ceiling.coveredAreaM2 <= 0 {
            result.append(.ceiling)
        }
        if floor.totalAreaM2 >= minimumAreaM2, floor.coveredAreaM2 <= 0 {
            result.append(.floor)
        }
        if wallArea.totalAreaM2 >= minimumAreaM2, wallArea.coveredAreaM2 <= 0 {
            result.append(.wall)
        }
        return result
    }

    /// The quiet one-line readout, e.g. `Walls 3/4 · Floor ✓ · Ceiling —`.
    var readoutLine: String {
        let walls = wallsTotal > 0 ? "Walls \(wallsCovered)/\(wallsTotal)" : "Walls —"
        return "\(walls) · Floor \(Self.mark(floor)) · Ceiling \(Self.mark(ceiling))"
    }

    /// Spoken form of `readoutLine`. The marks are glyphs VoiceOver reads
    /// poorly or not at all, so the ambient readout announces words instead.
    /// Still no number: `—` is "not covered yet", never "0%".
    static func spokenReadout(_ line: String) -> String {
        line.replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "/", with: " of ")
            .replacingOccurrences(of: "✓", with: "covered")
            .replacingOccurrences(of: "◐", with: "partly covered")
            .replacingOccurrences(of: "—", with: "not covered yet")
    }

    private static func mark(_ coverage: CategoryCoverage) -> String {
        guard coverage.coveredAreaM2 > 0 else { return "—" }
        return coverage.coveredFraction >= 0.5 ? "✓" : "◐"
    }
}

/// Bounded directional surface-voxel map with commit-truthful integration.
///
/// Coverage means "a sharp, saved RGB frame observed this surface", so callers
/// must only `integrate` observations after the frame record commits. Voxels
/// track view-direction diversity in 16 bins (8 azimuth × 2 elevation);
/// stationary repeats land in the same bin and never add diversity.
final class CaptureCoverageTracker {
    struct VoxelKey: Hashable, Sendable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    struct PaintChunkKey: Hashable, Sendable {
        let x: Int32
        let y: Int32
        let z: Int32
    }
    struct Voxel: Sendable {
        var observationCount: UInt16
        var viewDirectionBits: UInt16
        var maxConfidence: UInt8
        var lastObservedAt: TimeInterval

        var state: CaptureCoverageDisplayState {
            CaptureCoverageTracker.isSolid(viewDirectionBits: viewDirectionBits)
                ? .solid
                : .seen
        }
    }

    struct PaintLookup: Sendable {
        let voxel: Voxel?
        let dictionaryProbeCount: Int
    }
    private final class VoxelRecord {
        let key: VoxelKey
        var voxel: Voxel

        init(key: VoxelKey, voxel: Voxel) {
            self.key = key
            self.voxel = voxel
        }
    }
    private static let paintChunkSide: Int32 = 4

    /// 7.5 cm voxels: inside a 5–10 cm band; ~180 voxels/m² of surface.
    let voxelSizeM: Float
    /// Hard memory bound; integration stops adding new voxels when reached.
    let maxVoxelCount: Int
    /// Points below this ARKit confidence are ignored entirely.
    let minimumConfidence: UInt8

    private var voxelRecords: [VoxelKey: VoxelRecord] = [:]
    private var paintBuckets: [PaintChunkKey: [VoxelRecord]] = [:]
    private var pendingPaintChunks: Set<PaintChunkKey> = []
    private(set) var structuralSummary = CaptureStructuralSummary()

    init(
        voxelSizeM: Float = 0.075,
        maxVoxelCount: Int = 300_000,
        minimumConfidence: UInt8 = 1
    ) {
        self.voxelSizeM = voxelSizeM
        self.maxVoxelCount = maxVoxelCount
        self.minimumConfidence = minimumConfidence
    }

    var voxelCount: Int { voxelRecords.count }

    func reset() {
        voxelRecords = [:]
        paintBuckets = [:]
        pendingPaintChunks = []
        structuralSummary = CaptureStructuralSummary()
    }

    // MARK: - Integration

    func integrate(_ observation: CaptureCoverageObservation) {
        for point in observation.points {
            guard point.confidence >= minimumConfidence else { continue }
            let key = key(for: point.position)
            let bin = Self.viewDirectionBin(
                from: point.position,
                toCamera: observation.cameraPosition
            )
            let binBit: UInt16 = 1 << bin

            if let record = voxelRecords[key] {
                var voxel = record.voxel
                voxel.observationCount = voxel.observationCount &+ 1
                voxel.viewDirectionBits |= binBit
                voxel.maxConfidence = max(voxel.maxConfidence, point.confidence)
                voxel.lastObservedAt = observation.timestamp
                record.voxel = voxel
                markPaintChunks(for: key)
            } else if voxelRecords.count < maxVoxelCount {
                insertVoxel(
                    Voxel(
                        observationCount: 1,
                        viewDirectionBits: binBit,
                        maxConfidence: point.confidence,
                        lastObservedAt: observation.timestamp
                    ),
                    for: key
                )
            }
        }
    }

    // MARK: - Query

    func key(for position: SIMD3<Float>) -> VoxelKey {
        VoxelKey(
            x: Int32((position.x / voxelSizeM).rounded(.down)),
            y: Int32((position.y / voxelSizeM).rounded(.down)),
            z: Int32((position.z / voxelSizeM).rounded(.down))
        )
    }

    func voxel(at position: SIMD3<Float>) -> Voxel? {
        voxelRecords[key(for: position)]?.voxel
    }

    func paintLookup(at position: SIMD3<Float>) -> PaintLookup {
        let queryKey = key(for: position)
        let chunkKey = Self.paintChunkKey(for: queryKey)
        let candidates = paintBuckets[chunkKey] ?? []
        var selected: Voxel?

        for record in candidates where Self.isNeighbor(record.key, queryKey) {
            let candidate = record.voxel
            if Self.prefer(candidate, over: selected) {
                selected = candidate
            }
        }
        return PaintLookup(
            voxel: selected,
            dictionaryProbeCount: 1
        )
    }

    func voxelForPaint(near position: SIMD3<Float>) -> Voxel? {
        paintLookup(at: position).voxel
    }

    func takePendingPaintChunks() -> Set<PaintChunkKey> {
        let chunks = pendingPaintChunks
        pendingPaintChunks = []
        return chunks
    }

    static func paintChunkKey(
        for position: SIMD3<Float>,
        voxelSizeM: Float
    ) -> PaintChunkKey {
        paintChunkKey(
            for: VoxelKey(
                x: Int32((position.x / voxelSizeM).rounded(.down)),
                y: Int32((position.y / voxelSizeM).rounded(.down)),
                z: Int32((position.z / voxelSizeM).rounded(.down))
            )
        )
    }

    /// True when the point's voxel or any 26-neighbor is covered. The one
    /// voxel of slack absorbs depth noise plus the small residual a valid
    /// relocalization leaves — continuation validation uses this so honest
    /// alignments are not rejected over centimeters.
    func hasCoverage(near position: SIMD3<Float>) -> Bool {
        let center = key(for: position)
        for dx in Int32(-1)...1 {
            for dy in Int32(-1)...1 {
                for dz in Int32(-1)...1 {
                    let neighbor = VoxelKey(
                        x: center.x + dx,
                        y: center.y + dy,
                        z: center.z + dz
                    )
                    if voxelRecords[neighbor] != nil { return true }
                }
            }
        }
        return false
    }

    /// Number of covered voxels whose centers fall inside a world-space
    /// sphere. The repair loop compares this against a baseline to decide
    /// when a review target has actually gained coverage.
    func coveredVoxelCount(
        near center: SIMD3<Float>,
        radiusM: Float
    ) -> Int {
        let radiusSquared = radiusM * radiusM
        var count = 0
        for key in voxelRecords.keys {
            let position = SIMD3<Float>(
                (Float(key.x) + 0.5) * voxelSizeM,
                (Float(key.y) + 0.5) * voxelSizeM,
                (Float(key.z) + 0.5) * voxelSizeM
            )
            if simd_distance_squared(position, center) <= radiusSquared {
                count += 1
            }
        }
        return count
    }

    /// Fraction of observed voxels that reached `solid` — a tuning metric (a
    /// competent scan should end mostly solid).
    var solidFraction: Float {
        guard !voxelRecords.isEmpty else { return 0 }
        let solid = voxelRecords.values.reduce(into: 0) { count, record in
            if record.voxel.state == .solid { count += 1 }
        }
        return Float(solid) / Float(voxelRecords.count)
    }

    private func insertVoxel(_ voxel: Voxel, for key: VoxelKey) {
        let record = VoxelRecord(key: key, voxel: voxel)
        voxelRecords[key] = record
        Self.forEachPaintChunk(affectedBy: key) { chunk in
            paintBuckets[chunk, default: []].append(record)
            pendingPaintChunks.insert(chunk)
        }
    }

    private func markPaintChunks(for key: VoxelKey) {
        Self.forEachPaintChunk(affectedBy: key) {
            pendingPaintChunks.insert($0)
        }
    }

    private static func forEachPaintChunk(
        affectedBy key: VoxelKey,
        _ body: (PaintChunkKey) -> Void
    ) {
        let minChunk = paintChunkKey(
            for: VoxelKey(x: key.x - 1, y: key.y - 1, z: key.z - 1)
        )
        let maxChunk = paintChunkKey(
            for: VoxelKey(x: key.x + 1, y: key.y + 1, z: key.z + 1)
        )
        for x in minChunk.x...maxChunk.x {
            for y in minChunk.y...maxChunk.y {
                for z in minChunk.z...maxChunk.z {
                    body(PaintChunkKey(x: x, y: y, z: z))
                }
            }
        }
    }

    private static func paintChunkKey(for key: VoxelKey) -> PaintChunkKey {
        PaintChunkKey(
            x: floorDiv(key.x, by: paintChunkSide),
            y: floorDiv(key.y, by: paintChunkSide),
            z: floorDiv(key.z, by: paintChunkSide)
        )
    }

    private static func floorDiv(_ value: Int32, by divisor: Int32) -> Int32 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    private static func isNeighbor(_ lhs: VoxelKey, _ rhs: VoxelKey) -> Bool {
        abs(lhs.x - rhs.x) <= 1
            && abs(lhs.y - rhs.y) <= 1
            && abs(lhs.z - rhs.z) <= 1
    }

    private static func prefer(_ candidate: Voxel, over current: Voxel?) -> Bool {
        guard let current else { return true }
        if candidate.state != current.state {
            return candidate.state == .solid
        }
        if candidate.maxConfidence != current.maxConfidence {
            return candidate.maxConfidence > current.maxConfidence
        }
        return candidate.lastObservedAt > current.lastObservedAt
    }

    // MARK: - View-direction bins

    /// 16 bins: 8 azimuth sectors × 2 elevation rows for the surface→camera
    /// direction.
    static func viewDirectionBin(
        from surface: SIMD3<Float>,
        toCamera camera: SIMD3<Float>
    ) -> Int {
        let direction = camera - surface
        let length = simd_length(direction)
        guard length > 1e-6 else { return 0 }
        let unit = direction / length

        let azimuth = atan2(unit.z, unit.x)
        var sector = Int((azimuth + .pi) / (2 * .pi / 8))
        sector = min(max(sector, 0), 7)
        let elevationRow = unit.y > 0.5 ? 1 : 0
        return elevationRow * 8 + sector
    }

    /// Solid requires two committed views that are angularly distinct: either
    /// two azimuth sectors at least 2 apart circularly (≥45° guaranteed) or
    /// views from both elevation rows.
    ///
    /// Allocation-free: this runs once per mesh vertex during overlay
    /// recolouring, so it must not build arrays. Two set sectors are at
    /// circular distance ≥ 2 exactly when the 8-bit azimuth mask overlaps a
    /// rotation of itself by 2, 3, or 4 positions (circular distances span
    /// 1...4, and offsets k and 8−k are the same distance).
    static func isSolid(viewDirectionBits: UInt16) -> Bool {
        let low = UInt8(truncatingIfNeeded: viewDirectionBits)
        let high = UInt8(truncatingIfNeeded: viewDirectionBits >> 8)
        if low != 0, high != 0 { return true }

        let azimuthBits = low | high
        for shift in UInt8(2)...4 {
            let rotated = (azimuthBits << shift) | (azimuthBits >> (8 - shift))
            if azimuthBits & rotated != 0 { return true }
        }
        return false
    }

    // MARK: - Structural aggregation

    /// Rebuilds the per-category summary from classified mesh faces (extracted
    /// from `ARMeshAnchor`s elsewhere). Wall instances are clustered by face
    /// normal azimuth so `Walls 3/4` counts distinct wall orientations, not
    /// mesh chunks.
    func updateStructuralSummary(faces: [CaptureClassifiedFace]) {
        var summary = CaptureStructuralSummary()
        var wallAzimuthTotal = [Float](repeating: 0, count: 8)
        var wallAzimuthCovered = [Float](repeating: 0, count: 8)
        /// Walls below this area are noise (furniture edges, door jambs).
        let minWallAreaM2: Float = 0.8

        for face in faces {
            let isCovered = voxel(at: face.center) != nil
            switch face.category {
            case .floor:
                summary.floor.totalAreaM2 += face.areaM2
                if isCovered { summary.floor.coveredAreaM2 += face.areaM2 }
            case .ceiling:
                summary.ceiling.totalAreaM2 += face.areaM2
                if isCovered { summary.ceiling.coveredAreaM2 += face.areaM2 }
            case .wall:
                summary.wallArea.totalAreaM2 += face.areaM2
                if isCovered { summary.wallArea.coveredAreaM2 += face.areaM2 }
                let azimuth = atan2(face.normal.z, face.normal.x)
                var bucket = Int((azimuth + .pi) / (2 * .pi / 8))
                bucket = min(max(bucket, 0), 7)
                wallAzimuthTotal[bucket] += face.areaM2
                if isCovered { wallAzimuthCovered[bucket] += face.areaM2 }
            }
        }

        for bucket in 0..<8 where wallAzimuthTotal[bucket] >= minWallAreaM2 {
            summary.wallsTotal += 1
            if wallAzimuthCovered[bucket] / wallAzimuthTotal[bucket] >= 0.5 {
                summary.wallsCovered += 1
            }
        }

        structuralSummary = summary
    }

    // MARK: - Persistence

    /// Compact in-memory binary snapshot: magic, version, voxel size, count,
    /// then fixed-width records. Never written to the bundle.
    func serialized() -> Data {
        var data = Data()
        data.append(contentsOf: "CCOV".utf8)
        var version = UInt32(1).littleEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        var size = voxelSizeM
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        var count = UInt32(voxelRecords.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        for (key, voxelRecord) in voxelRecords {
            let voxel = voxelRecord.voxel
            var serializedRecord = SerializedVoxel(
                x: key.x.littleEndian,
                y: key.y.littleEndian,
                z: key.z.littleEndian,
                observationCount: voxel.observationCount.littleEndian,
                viewDirectionBits: voxel.viewDirectionBits.littleEndian,
                maxConfidence: voxel.maxConfidence,
                state: voxel.state.rawValue
            )
            withUnsafeBytes(of: &serializedRecord) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }

    static func deserialize(_ data: Data) -> CaptureCoverageTracker? {
        let headerSize = 4 + 4 + 4 + 4
        guard data.count >= headerSize,
              data.prefix(4).elementsEqual("CCOV".utf8)
        else {
            return nil
        }
        let voxelSize = data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: 8, as: Float.self)
        }
        let count = data.withUnsafeBytes { buffer in
            Int(UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
        }
        let recordSize = MemoryLayout<SerializedVoxel>.size
        guard data.count >= headerSize + count * recordSize else { return nil }

        let tracker = CaptureCoverageTracker(voxelSizeM: voxelSize)
        data.withUnsafeBytes { buffer in
            for index in 0..<count {
                let offset = headerSize + index * recordSize
                let record = buffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: SerializedVoxel.self
                )
                let key = VoxelKey(
                    x: Int32(littleEndian: record.x),
                    y: Int32(littleEndian: record.y),
                    z: Int32(littleEndian: record.z)
                )
                tracker.insertVoxel(
                    Voxel(
                        observationCount: UInt16(littleEndian: record.observationCount),
                        viewDirectionBits: UInt16(littleEndian: record.viewDirectionBits),
                        maxConfidence: record.maxConfidence,
                        lastObservedAt: 0
                    ),
                    for: key
                )
            }
        }
        return tracker
    }

    private struct SerializedVoxel {
        let x: Int32
        let y: Int32
        let z: Int32
        let observationCount: UInt16
        let viewDirectionBits: UInt16
        let maxConfidence: UInt8
        let state: UInt8
    }
}
