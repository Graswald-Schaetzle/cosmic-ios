import Foundation
import simd

enum CaptureOverviewLayer: String, CaseIterable {
    case room = "Room layout"
    case floor = "Floor coverage"
    case ceiling = "Ceiling coverage"

    var category: CaptureStructuralCategory? {
        switch self {
        case .room: nil
        case .floor: .floor
        case .ceiling: .ceiling
        }
    }
}

struct CaptureSurfacePatch: Sendable {
    enum Evidence: Int, CaseIterable, Sendable { case needsViews, singleView, multipleViews }
    let center: SIMD3<Float>
    let normal: SIMD3<Float>
    let size: Float
    let category: CaptureStructuralCategory
    let evidence: Evidence

    func isTarget(_ gap: CaptureCoverageGap?) -> Bool {
        guard evidence == .needsViews, let gap, gap.category == category else { return false }
        return simd_distance(center, gap.center) <= gap.radiusM
    }
}

/// A bounded visualization of detected surfaces and committed observations.
/// Empty space creates no patch. Room outline surfaces never enter this calculation.
enum CaptureSurfaceCoverage {
    private struct Key: Hashable {
        let x: Int
        let y: Int
        let z: Int
        let category: CaptureStructuralCategory
        let side: Int
    }
    private struct Accumulator {
        var area: Float = 0
        var saved: Float = 0
        var diverse: Float = 0
        var position = SIMD3<Float>.zero
        var normal = SIMD3<Float>.zero
    }

    /// Keep opposing mesh faces separate even when they share a spatial cell.
    static func wallSide(_ normal: SIMD3<Float>) -> Int {
        abs(normal.x) >= abs(normal.z) ? (normal.x >= 0 ? 1 : 2) : (normal.z >= 0 ? 3 : 4)
    }

    /// Only camera directions on this face's side contribute evidence. Discard
    /// grazing bins conservatively because each azimuth bin spans 45 degrees.
    static func wallViewBits(_ bits: UInt16, normal: SIMD3<Float>) -> UInt16 {
        var result: UInt16 = 0
        let horizontal = SIMD2(normal.x, normal.z)
        guard simd_length(horizontal) > 0.1 else { return 0 }
        let unit = simd_normalize(horizontal)
        for sector in 0..<8 {
            let angle = -Float.pi + (Float(sector) + 0.5) * Float.pi / 4
            if simd_dot(unit, SIMD2(cos(angle), sin(angle))) > 0.38 {
                result |= bits & ((1 << sector) | (1 << (sector + 8)))
            }
        }
        return result
    }

    static func patches(faces: [CaptureClassifiedFace], tracker: CaptureCoverageTracker,
                        camera: SIMD3<Float>, limitPerCategory: Int = 2000) -> [CaptureSurfacePatch] {
        var cells: [Key: Accumulator] = [:]
        for face in faces {
            guard face.areaM2.isFinite, face.areaM2 > 0,
                  simd_distance_squared(face.center, camera) <= 144 else { continue }
            let key = Key(x: Int(floor(face.center.x / 0.2)), y: Int(floor(face.center.y / 0.2)),
                          z: Int(floor(face.center.z / 0.2)), category: face.category,
                          side: face.category == .wall ? wallSide(face.normal) : 0)
            var cell = cells[key, default: Accumulator()]
            cell.area += face.areaM2
            cell.position += face.center * face.areaM2
            if simd_length_squared(face.normal).isFinite { cell.normal += face.normal * face.areaM2 }
            if let voxel = tracker.voxel(at: face.center) {
                let bits = face.category == .wall
                    ? wallViewBits(voxel.viewDirectionBits, normal: face.normal) : voxel.viewDirectionBits
                if bits != 0 { cell.saved += face.areaM2 }
                if CaptureCoverageTracker.isSolid(viewDirectionBits: bits), voxel.maxConfidence >= 2 {
                    cell.diverse += face.areaM2
                }
            }
            cells[key] = cell
        }
        let ordered = cells.sorted { lhs, rhs in
            let a = simd_distance_squared(lhs.value.position / lhs.value.area, camera)
            let b = simd_distance_squared(rhs.value.position / rhs.value.area, camera)
            if a != b { return a < b }
            if lhs.key.x != rhs.key.x { return lhs.key.x < rhs.key.x }
            if lhs.key.y != rhs.key.y { return lhs.key.y < rhs.key.y }
            if lhs.key.z != rhs.key.z { return lhs.key.z < rhs.key.z }
            if lhs.key.category != rhs.key.category { return lhs.key.category.rawValue < rhs.key.category.rawValue }
            return lhs.key.side < rhs.key.side
        }
        var counts: [CaptureStructuralCategory: Int] = [:]
        return ordered.compactMap { key, cell in
            guard counts[key.category, default: 0] < limitPerCategory else { return nil }
            counts[key.category, default: 0] += 1
            let evidence: CaptureSurfacePatch.Evidence = cell.diverse / cell.area >= 0.8 ? .multipleViews
                : cell.saved / cell.area >= 0.8 ? .singleView : .needsViews
            let normal = simd_length(cell.normal) > 0.001 ? simd_normalize(cell.normal) : SIMD3<Float>(0, 1, 0)
            return CaptureSurfacePatch(center: cell.position / cell.area, normal: normal,
                size: min(0.18, sqrt(cell.area) * 0.9), category: key.category, evidence: evidence)
        }
    }
}

/// Session-local evidence survives mesh churn, hiding, and pass selection.
/// Stronger historical evidence retains its original patch footprint.
struct CaptureSurfaceCoverageCache {
    struct Key: Hashable {
        let x: Int
        let y: Int
        let z: Int
        let category: CaptureStructuralCategory
        let side: Int
        init(_ patch: CaptureSurfacePatch) {
            x = Int(floor(patch.center.x / 0.2))
            y = Int(floor(patch.center.y / 0.2))
            z = Int(floor(patch.center.z / 0.2))
            category = patch.category
            side = patch.category == .wall ? CaptureSurfaceCoverage.wallSide(patch.normal) : 0
        }
    }
    private var entries: [Key: (patch: CaptureSurfacePatch, order: Int)] = [:]
    private var order = 0
    private(set) var isLimited = false
    var limit = 20_000

    mutating func merge(_ patches: [CaptureSurfacePatch]) -> [CaptureSurfacePatch] {
        for patch in patches {
            order += 1
            let key = Key(patch)
            let old = entries[key]?.patch
            let retained = (old?.evidence.rawValue ?? -1) > patch.evidence.rawValue ? old! : patch
            entries[key] = (retained, order)
        }
        if entries.count > limit {
            isLimited = true
            let oldest = entries.sorted { $0.value.order < $1.value.order }.prefix(entries.count - limit)
            for entry in oldest { entries.removeValue(forKey: entry.key) }
        }
        return entries.values.sorted { $0.order < $1.order }.map(\.patch)
    }
}

/// Suggestive finish checks only. Layout is an estimate, not reconstruction truth.
/// No bounding rectangle or convex hull: concave and disconnected rooms keep their
/// actual footprint, and open layouts do not invent an enclosed floor/ceiling.
enum CaptureFinishCompleteness {
    enum Issue: String, CaseIterable, Hashable {
        case wallConnections = "Possible gaps between walls"
        case wallCoverage = "Possible gap in a wall"
        case floorCoverage = "Possible gap in the floor"
        case ceilingCoverage = "Possible gap in the ceiling"

        var surfaceLabel: String {
            switch self {
            case .wallConnections: "Wall joins"
            case .wallCoverage: "Walls"
            case .floorCoverage: "Floor"
            case .ceilingCoverage: "Ceiling"
            }
        }

        var sentence: String {
            switch self {
            case .wallConnections: "Some walls may not connect."
            case .wallCoverage: "Some walls may have gaps."
            case .floorCoverage: "Parts of the floor may be missing."
            case .ceilingCoverage: "Parts of the ceiling may be missing."
            }
        }
    }

    static func message(outline: CaptureRoomOutline, patches: [CaptureSurfacePatch],
                        coverageAvailable: Bool) -> String? {
        message(for: issues(outline: outline, patches: patches, coverageAvailable: coverageAvailable))
    }

    static func message(for issues: [Issue]) -> String? {
        guard !issues.isEmpty else { return nil }
        return issues.map(\.sentence).joined(separator: " ") + " This could affect the final result."
    }

    static func reviewIssues(_ issues: [Issue], gaps: [CaptureCoverageGap]) -> [Issue] {
        var detected = Set<Issue>()
        for gap in gaps {
            switch gap.category {
            case .wall: detected.insert(.wallCoverage)
            case .floor: detected.insert(.floorCoverage)
            case .ceiling: detected.insert(.ceilingCoverage)
            }
        }
        return Issue.allCases.filter { detected.contains($0) }
    }

    static func issues(outline: CaptureRoomOutline, patches: [CaptureSurfacePatch],
                        coverageAvailable: Bool) -> [Issue] {
        // Room outline boundaries and blank preview space are not evidence of a
        // coverage hole. Only spatially supported mesh gaps, supplied to
        // reviewIssues, produce an advisory. This also keeps open-air scans from
        // acquiring an invented ceiling requirement.
        return []
    }
}
