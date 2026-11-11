import Foundation
import simd

/// One ranked missing-coverage region for the Coverage Review and the repair
/// loop. Centers and radii are world-space (same AR epoch as the capture).
struct CaptureCoverageGap: Equatable, Sendable, Identifiable {
    let id: Int
    let category: CaptureStructuralCategory
    let center: SIMD3<Float>
    let radiusM: Float
    let areaM2: Float
    /// Advisory copy for the review, e.g. `Missing areas in the ceiling`.
    /// Falls back to positional wall copy when semantics are weak — never
    /// stated as a definite hole.
    let label: String
}

/// Finds missing-coverage regions on classified structural surfaces.
///
/// Honesty filters: only classified planar shell categories are
/// considered (doors/windows/furniture were already dropped at extraction),
/// clusters below a minimum area are ignored as noise (small components,
/// depth-discontinuity slivers), and clustering runs in world space so
/// mesh-anchor boundaries never create phantom gap edges. At most the two
/// highest-value gaps are reported.
enum CaptureCoverageGapAnalyzer {
    struct Policy: Sendable {
        /// Clustering cell size. Coarser than coverage voxels on purpose —
        /// gaps are room-scale advisories, not voxel noise.
        var cellSizeM: Float = 0.5
        /// A cell only counts toward a gap when at least this fraction of
        /// its classified surface is uncovered. Real holes are near-fully
        /// uncovered; depth-sampling sparsity leaves covered and uncovered
        /// faces interleaved (~40–60%), so speckle cells never qualify and
        /// can't chain into a room-sized phantom gap. This — not voxel
        /// dilation — is what separates "hole" from "sampling noise":
        /// dilation also erased genuine sub-meter holes.
        var minUncoveredFraction: Float = 0.7
        /// Uncovered area below this is noise, not a reportable gap.
        /// Deliberate test holes measure ~0.3–0.6 m², so the floor sits
        /// below them; the fraction gate above handles speckle.
        var minGapAreaM2: Float = 0.3
        var maxGaps: Int = 2
        /// Gaps farther than this from anywhere the camera traveled are
        /// never reported — surfaces glimpsed through an open doorway are
        /// not part of what the user set out to scan, and warning about
        /// them erodes trust. 3 m also roughly matches where the 32×24
        /// depth sampling is still dense enough (relative to the 7.5 cm
        /// coverage voxels) for a scanned surface to actually read covered;
        /// beyond it, "uncovered" is mostly sampling sparsity, not a hole.
        var maxDistanceFromPathM: Float = 3.0

        /// Gap warnings require committed coverage surrounding the gap on
        /// the same surface. Disabled only by tests of raw clustering.
        var requiresCoveredBoundary = true

        init() {}
    }

    /// - Parameters:
    ///   - faces: Classified structural faces (world space).
    ///   - isCovered: Committed-coverage lookup, e.g. voxel existence in
    ///     `CaptureCoverageTracker`.
    ///   - cameraPositions: Committed camera positions (same world space).
    ///     When non-empty, gaps far from the traveled path are dropped and
    ///     ranking favors regions the camera was close to.
    static func rankedGaps(
        faces: [CaptureClassifiedFace],
        isCovered: (SIMD3<Float>) -> Bool,
        cameraPositions: [SIMD3<Float>] = [],
        categoryFilter: CaptureStructuralCategory? = nil,
        policy: Policy = Policy()
    ) -> [CaptureCoverageGap] {
        guard !faces.isEmpty else { return [] }

        var sceneMinY = Float.greatestFiniteMagnitude
        var sceneMaxY = -Float.greatestFiniteMagnitude
        for face in faces {
            sceneMinY = min(sceneMinY, face.center.y)
            sceneMaxY = max(sceneMaxY, face.center.y)
        }

        // Bucket uncovered faces into coarse world-space cells per category.
        struct CellKey: Hashable {
            let category: CaptureStructuralCategory
            let x: Int32
            let y: Int32
            let z: Int32
        }
        struct Cell {
            /// Uncovered classified area in the cell.
            var areaM2: Float = 0
            /// All classified area in the cell, covered or not.
            var totalAreaM2: Float = 0
            var weightedCenter: SIMD3<Float> = .zero
            var normal: SIMD3<Float> = .zero
            var surfaceCenter: SIMD3<Float> = .zero
        }

        var allCells: [CellKey: Cell] = [:]
        // Filter before ranking/capping: otherwise two large ceiling gaps
        // can crowd every wall or floor candidate out of the live pass.
        for face in faces where categoryFilter == nil || face.category == categoryFilter {
            let key = CellKey(
                category: face.category,
                x: Int32((face.center.x / policy.cellSizeM).rounded(.down)),
                y: Int32((face.center.y / policy.cellSizeM).rounded(.down)),
                z: Int32((face.center.z / policy.cellSizeM).rounded(.down))
            )
            var cell = allCells[key, default: Cell()]
            cell.totalAreaM2 += face.areaM2
            cell.normal += face.normal * face.areaM2
            cell.surfaceCenter += face.center * face.areaM2
            if !isCovered(face.center) {
                cell.areaM2 += face.areaM2
                cell.weightedCenter += face.center * face.areaM2
            }
            allCells[key] = cell
        }

        // Only mostly-uncovered cells can seed or join a gap.
        let cells = allCells.filter { _, cell in
            cell.areaM2 > 0
                && cell.areaM2 / cell.totalAreaM2 >= policy.minUncoveredFraction
        }
        guard !cells.isEmpty else { return [] }

        // Flood-fill adjacent cells of the same category into clusters.
        var visited: Set<CellKey> = []
        var clusters: [(category: CaptureStructuralCategory, areaM2: Float, center: SIMD3<Float>, keys: [CellKey])] = []

        for seed in cells.keys where !visited.contains(seed) {
            var queue = [seed]
            visited.insert(seed)
            var areaM2: Float = 0
            var weightedCenter: SIMD3<Float> = .zero
            var memberKeys: [CellKey] = []

            while let key = queue.popLast() {
                guard let cell = cells[key] else { continue }
                areaM2 += cell.areaM2
                weightedCenter += cell.weightedCenter
                memberKeys.append(key)

                for dx in Int32(-1)...1 {
                    for dy in Int32(-1)...1 {
                        for dz in Int32(-1)...1 {
                            if dx == 0, dy == 0, dz == 0 { continue }
                            let neighbor = CellKey(
                                category: key.category,
                                x: key.x + dx,
                                y: key.y + dy,
                                z: key.z + dz
                            )
                            if cells[neighbor] != nil, !visited.contains(neighbor) {
                                visited.insert(neighbor)
                                queue.append(neighbor)
                            }
                        }
                    }
                }
            }

            guard areaM2 >= policy.minGapAreaM2 else { continue }
            if policy.requiresCoveredBoundary {
                // A missing edge, a whole unvisited surface, or a distant
                // glimpse has no covered boundary and remains unknown.
                // Require support on opposing sides along two surface axes.
                var directions = Set<Int>()
                var supportKeys = Set<CellKey>()
                var offsets: [SIMD3<Int32>] = []
                for x in Int32(-1)...1 {
                    for y in Int32(-1)...1 {
                        for z in Int32(-1)...1 where x != 0 || y != 0 || z != 0 {
                            offsets.append(SIMD3(x, y, z))
                        }
                    }
                }
                for key in memberKeys {
                    guard let source = cells[key], simd_length(source.normal) > 0.001 else { continue }
                    let normal = simd_normalize(source.normal)
                    let reference: SIMD3<Float> = abs(normal.y) > 0.9 ? SIMD3(1,0,0) : SIMD3(0,1,0)
                    let right = simd_normalize(simd_cross(reference, normal))
                    let up = simd_cross(normal, right)
                    for offset in offsets {
                        let neighbor = CellKey(category: key.category, x: key.x + offset.x,
                            y: key.y + offset.y, z: key.z + offset.z)
                        guard let boundary = allCells[neighbor], boundary.totalAreaM2 > 0,
                              (boundary.totalAreaM2 - boundary.areaM2) / boundary.totalAreaM2 >= 0.65,
                              simd_length(boundary.normal) > 0.001,
                              simd_dot(normal, simd_normalize(boundary.normal)) > 0.9 else { continue }
                        // Adjacent floors or opposite sides of thin walls must
                        // never serve as support for this surface.
                        let delta = boundary.surfaceCenter / boundary.totalAreaM2 - source.surfaceCenter / source.totalAreaM2
                        guard abs(simd_dot(normal, delta)) < 0.2 else { continue }
                        let x = simd_dot(delta, right), y = simd_dot(delta, up)
                        guard max(abs(x), abs(y)) > 0.01 else { continue }
                        // Classify in the surface plane, so diagonal walls
                        // receive the same checks as axis-aligned walls.
                        directions.insert(abs(x) >= abs(y) ? (x < 0 ? 0 : 1) : (y < 0 ? 2 : 3))
                        supportKeys.insert(neighbor)
                    }
                }
                let coveredBoundaryArea = supportKeys.reduce(Float(0)) { sum, key in
                    guard let cell = allCells[key] else { return sum }
                    return sum + cell.totalAreaM2 - cell.areaM2
                }
                guard directions.count == 4, supportKeys.count >= 4, coveredBoundaryArea >= 0.5 else { continue }
            }

            clusters.append(
                (seed.category, areaM2, weightedCenter / areaM2, memberKeys)
            )
        }

        // Proximity gate + weighting: warnings must be about the space the
        // user actually scanned. A large surface seen at a distance (through
        // an open door, down a hallway) is dropped outright; among the rest,
        // a modest gap right next to the path outranks a big one far away.
        typealias Cluster = (
            category: CaptureStructuralCategory,
            areaM2: Float,
            center: SIMD3<Float>,
            keys: [CellKey]
        )
        // Written as a loop: newer compilers fail to type-check the
        // equivalent `compactMap` closure.
        var scored: [(cluster: Cluster, score: Float)] = []
        for cluster in clusters {
            if cameraPositions.isEmpty {
                if !policy.requiresCoveredBoundary {
                    scored.append((cluster, cluster.areaM2))
                }
                continue
            }
            if policy.requiresCoveredBoundary {
                // Filter the complete region, not just its centroid, so nearby
                // coverage cannot pull a remote corridor into a warning.
                var isWholeRegionNearPath = true
                for key in cluster.keys {
                    let cellCenter = SIMD3<Float>(
                        (Float(key.x) + 0.5) * policy.cellSizeM,
                        (Float(key.y) + 0.5) * policy.cellSizeM,
                        (Float(key.z) + 0.5) * policy.cellSizeM
                    )
                    let isNear = cameraPositions.contains { position in
                        simd_distance(position, cellCenter) <= policy.maxDistanceFromPathM
                    }
                    if !isNear {
                        isWholeRegionNearPath = false
                        break
                    }
                }
                guard isWholeRegionNearPath else { continue }
            }
            var nearestM = Float.greatestFiniteMagnitude
            for position in cameraPositions {
                nearestM = min(
                    nearestM,
                    simd_distance(position, cluster.center)
                )
            }
            guard nearestM <= policy.maxDistanceFromPathM else { continue }
            scored.append((cluster, cluster.areaM2 / (1 + nearestM * nearestM)))
        }

        let ranked = scored.sorted { $0.score > $1.score }
            .prefix(policy.maxGaps)
            .map(\.cluster)

        return ranked.enumerated().map { index, cluster in
            // Radius from the cluster's cell footprint, so the live emphasis
            // region covers the whole gap.
            var maxDistance: Float = 0
            for key in cluster.keys {
                let cellCenter = SIMD3<Float>(
                    (Float(key.x) + 0.5) * policy.cellSizeM,
                    (Float(key.y) + 0.5) * policy.cellSizeM,
                    (Float(key.z) + 0.5) * policy.cellSizeM
                )
                maxDistance = max(
                    maxDistance,
                    simd_distance(cellCenter, cluster.center)
                )
            }
            let region = regionName(
                for: cluster.category,
                centerY: cluster.center.y,
                sceneMinY: sceneMinY,
                sceneMaxY: sceneMaxY
            )
            return CaptureCoverageGap(
                id: index,
                category: cluster.category,
                center: cluster.center,
                radiusM: max(0.4, maxDistance + policy.cellSizeM * 0.5),
                areaM2: cluster.areaM2,
                label: label(forRegion: region)
            )
        }
    }

    /// Short region name. Wall names use vertical position because finer
    /// semantics (doorways, windows) are below label confidence.
    static func regionName(
        for category: CaptureStructuralCategory,
        centerY: Float,
        sceneMinY: Float,
        sceneMaxY: Float
    ) -> String {
        switch category {
        case .ceiling:
            return "Ceiling"
        case .floor:
            return "Floor"
        case .wall:
            let span = sceneMaxY - sceneMinY
            guard span > 0.5 else { return "Wall" }
            let relative = (centerY - sceneMinY) / span
            if relative >= 0.55 { return "Upper wall" }
            if relative <= 0.45 { return "Lower wall" }
            return "Wall"
        }
    }

    /// Factual, non-definitive advisory copy — names what's missing without
    /// commanding, and never a definite-hole claim.
    static func label(forRegion region: String) -> String {
        "Possible gap in the \(region.lowercased())"
    }
}
