import ARKit
import Observation
import simd

struct CaptureRoomSurface: Sendable {
    enum Kind: Sendable { case wall, floor, opening }
    let id: UUID
    let transform: simd_float4x4
    let dimensions: SIMD3<Float>
    let kind: Kind
    var polygonCorners: [SIMD3<Float>] = []

    var localCorners: [SIMD3<Float>] {
        if polygonCorners.count >= 3 { return polygonCorners }
        let x = dimensions.x / 2
        let y = dimensions.y / 2
        return [SIMD3(-x, -y, 0), SIMD3(x, -y, 0), SIMD3(x, y, 0), SIMD3(-x, y, 0)]
    }
}

struct CaptureRoomOutline: Sendable {
    struct Edge: Sendable {
        let start: SIMD2<Float>
        let end: SIMD2<Float>
        let opening: Bool
    }
    var edges: [Edge] = []

    static func edge(transform: simd_float4x4, width: Float, opening: Bool) -> Edge {
        let a = transform * SIMD4<Float>(-width / 2, 0, 0, 1)
        let b = transform * SIMD4<Float>(width / 2, 0, 0, 1)
        return Edge(start: SIMD2(a.x, a.z), end: SIMD2(b.x, b.z), opening: opening)
    }
}

/// Optional layout preview. It never supplies completion or saved-coverage data.
@MainActor @Observable
final class CaptureRoomOverview {
    var isEnabled = true
    private(set) var outline = CaptureRoomOutline()
    private(set) var surfaces: [CaptureRoomSurface] = []
    var layer: CaptureOverviewLayer = .room {
        didSet { renderRevision &+= 1 }
    }
    private(set) var renderRevision = 0
    private(set) var layoutRevision = 0
    private(set) var hasCoverageSnapshot = false
    private(set) var referenceForward: SIMD2<Float>?
    @ObservationIgnored private var retainedSurfaces: [UUID: CaptureRoomSurface] = [:]
    @ObservationIgnored private var coverageCache = CaptureSurfaceCoverageCache()
    private(set) var patches: [CaptureSurfacePatch] = []
    private(set) var coverageRevision = 0
    var highlightedGap: CaptureCoverageGap? { didSet { renderRevision &+= 1 } }
    var coverageIsPaused = false { didSet { renderRevision &+= 1 } }

    /// Never carry a cue onto a different surface or through paused tracking.
    var visibleGap: CaptureCoverageGap? {
        guard !coverageIsPaused, let gap = highlightedGap,
              gap.category == (layer.category ?? .wall) else { return nil }
        return gap
    }

    var finishIssues: [CaptureFinishCompleteness.Issue] {
        CaptureFinishCompleteness.issues(outline: outline, patches: patches,
            coverageAvailable: hasCoverageSnapshot && !coverageCache.isLimited && !coverageIsPaused)
    }

    var layerMessage: String {
        let category = layer.category ?? .wall
        if coverageIsPaused { return "Coverage preview paused" }
        if !hasCoverageSnapshot { return "Loading saved coverage…" }
        if coverageCache.isLimited { return "Large scan. Showing recent coverage only." }
        if !patches.contains(where: { $0.category == category }) {
            return category == .wall ? "Scan along a wall to reveal coverage"
                : category == .ceiling ? "Look up to reveal the ceiling" : "Look down to reveal the floor"
        }
        return highlightedGap?.category == category ? "Scan the amber area" : "The outline is an estimate. Blank areas have no data yet."
    }

    func updateCoverage(faces: [CaptureClassifiedFace], tracker: CaptureCoverageTracker, camera: SIMD3<Float>) {
        guard !coverageIsPaused else { return }
        patches = coverageCache.merge(CaptureSurfaceCoverage.patches(faces: faces, tracker: tracker, camera: camera))
        hasCoverageSnapshot = true
        coverageRevision &+= 1
        renderRevision &+= 1
    }
    private(set) var cameraTransform = matrix_identity_float4x4
    private(set) var cameraPosition = SIMD2<Float>.zero
    private(set) var cameraForward = SIMD2<Float>(0, -1)
    private(set) var message = "Move slowly to reveal the layout"

    #if DEBUG
    func configureFixture(includeCeiling: Bool = false) {
        isEnabled = true
        let corners: [SIMD2<Float>] = [SIMD2(-3, -2), SIMD2(3, -2), SIMD2(3, 2), SIMD2(-3, 2)]
        outline = CaptureRoomOutline(edges: (0..<4).map {
            CaptureRoomOutline.Edge(start: corners[$0], end: corners[($0 + 1) % 4], opening: false)
        })
        surfaces = (0..<4).map { index in
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            let direction = simd_normalize(b - a)
            var transform = matrix_identity_float4x4
            transform.columns.0 = SIMD4(direction.x, 0, direction.y, 0)
            transform.columns.2 = SIMD4(-direction.y, 0, direction.x, 0)
            transform.columns.3 = SIMD4((a.x + b.x) / 2, 1.4, (a.y + b.y) / 2, 1)
            return CaptureRoomSurface(id: UUID(), transform: transform,
                dimensions: SIMD3(simd_distance(a, b), 2.8, 0), kind: .wall)
        }
        retainedSurfaces = Dictionary(uniqueKeysWithValues: surfaces.map { ($0.id, $0) })
        cameraTransform.columns.3 = SIMD4(0, 1.5, 0, 1)
        referenceForward = SIMD2(0, -1)
        var faces = (0..<10).flatMap { x in
            (0..<10).map { z in
                CaptureClassifiedFace(center: SIMD3(Float(x) * 0.2 - 1, 0, Float(z) * 0.2 - 1),
                    normal: SIMD3(0, 1, 0), areaM2: 0.04, category: .floor)
            }
        }
        if includeCeiling {
            faces += faces.map { CaptureClassifiedFace(center: $0.center + SIMD3(0, 2.8, 0),
                normal: SIMD3(0, -1, 0), areaM2: $0.areaM2, category: .ceiling) }
        }
        faces += (0..<20).flatMap { x in
            (0..<14).map { y in
                CaptureClassifiedFace(center: SIMD3(Float(x) * 0.2 - 2, Float(y) * 0.2, -2),
                    normal: SIMD3(0, 0, 1), areaM2: 0.04, category: .wall)
            }
        }
        let tracker = CaptureCoverageTracker()
        for face in faces where face.center.x > -0.4 {
            tracker.integrate(CaptureCoverageObservation(timestamp: 1, cameraPosition: face.center + (face.category == .wall ? SIMD3(2, 0, 1) : SIMD3(1, 2, 0)),
                points: [CaptureCoveragePoint(position: face.center, confidence: 2)]))
            if face.center.x > 0.2 {
                tracker.integrate(CaptureCoverageObservation(timestamp: 2, cameraPosition: face.center + (face.category == .wall ? SIMD3(-2, 0, 1) : SIMD3(-2, 0, 0)),
                    points: [CaptureCoveragePoint(position: face.center, confidence: 2)]))
            }
        }
        updateCoverage(faces: faces, tracker: tracker, camera: .zero)
        layoutRevision &+= 1
        message = "Estimated room outline"
    }
    #endif

    /// Merges detected layout surfaces for this capture, updating matching IDs.
    func mergeLayout(_ incoming: [CaptureRoomSurface], removing removed: Set<UUID> = []) {
        guard !incoming.isEmpty || !removed.isEmpty else { return }
        for id in removed { retainedSurfaces.removeValue(forKey: id) }
        for surface in incoming {
            // The same plane can arrive under a new ID. Replace near-identical
            // geometry instead of drawing it twice.
            if retainedSurfaces[surface.id] == nil {
                let center = SIMD3(surface.transform.columns.3.x, surface.transform.columns.3.y, surface.transform.columns.3.z)
                if let duplicate = retainedSurfaces.values.first(where: { old in
                    guard old.kind == surface.kind else { return false }
                    let oldCenter = SIMD3(old.transform.columns.3.x, old.transform.columns.3.y, old.transform.columns.3.z)
                    let normal = SIMD3(surface.transform.columns.2.x, surface.transform.columns.2.y, surface.transform.columns.2.z)
                    let oldNormal = SIMD3(old.transform.columns.2.x, old.transform.columns.2.y, old.transform.columns.2.z)
                    return simd_distance(center, oldCenter) < 0.15 && abs(simd_dot(normal, oldNormal)) > 0.98
                        && simd_distance(surface.dimensions, old.dimensions) < 0.25
                }) { retainedSurfaces.removeValue(forKey: duplicate.id) }
            }
            // Bounded memory; keep existing areas rather than evicting them.
            if retainedSurfaces[surface.id] != nil || retainedSurfaces.count < 600 {
                retainedSurfaces[surface.id] = surface
            }
        }
        surfaces = retainedSurfaces.values.sorted { $0.id.uuidString < $1.id.uuidString }
        outline = CaptureRoomOutline(edges: surfaces.filter { $0.kind != .floor }.map {
            CaptureRoomOutline.edge(transform: $0.transform, width: $0.dimensions.x, opening: $0.kind == .opening)
        })
        layoutRevision &+= 1
        renderRevision &+= 1
    }

    func stop() {}

    func resetRoom(clearCoverage: Bool = true) {
        stop()
        outline = CaptureRoomOutline()
        surfaces = []
        retainedSurfaces = [:]
        if clearCoverage {
            patches = []
            coverageCache = CaptureSurfaceCoverageCache()
            hasCoverageSnapshot = false
            referenceForward = nil
        }
        highlightedGap = nil
        coverageRevision &+= 1
        layoutRevision &+= 1
        message = "Move slowly to reveal the layout"
    }

    func recordCameraPose(_ pose: simd_float4x4) {
        cameraTransform = pose
        cameraPosition = SIMD2(pose.columns.3.x, pose.columns.3.z)
        let forward = SIMD2(-pose.columns.2.x, -pose.columns.2.z)
        if simd_length(forward) > 0.1 {
            cameraForward = simd_normalize(forward)
            if referenceForward == nil { referenceForward = cameraForward }
        }
        renderRevision &+= 1
    }
}
