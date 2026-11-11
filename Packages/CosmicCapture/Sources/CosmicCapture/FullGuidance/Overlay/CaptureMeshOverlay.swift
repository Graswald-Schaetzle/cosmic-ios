import ARKit
import Metal
import SceneKit
import SwiftUI
import UIKit

/// Coverage overlay treatments.
///
/// Default is `paint`: mesh triangles carry per-vertex fill state from the
/// coverage tracker — transparent where unscanned, faint where seen, firmer
/// where a second distinct view made the surface solid. This replaces the
/// anchor-recency dots, which showed "LiDAR refined this geometry" rather than
/// "a saved frame observed this surface".
enum CoverageOverlayStyle: String, CaseIterable, Sendable {
    case paint
    case tintedMesh
    case wireframe
    case confidenceDots

    static let active: CoverageOverlayStyle = .paint
}

/// How the paint overlay renders: over the camera feed, or as the camera-free
/// Model view where scanned surfaces are the only content.
enum CoverageOverlayMode: Sendable {
    case camera
    case model
}

enum CaptureOverlayRenderCadence {
    static func minimumInterval(
        for thermalState: ProcessInfo.ThermalState
    ) -> TimeInterval {
        switch thermalState {
        case .nominal:
            0.25
        case .fair:
            0.4
        case .serious:
            0.75
        case .critical:
            1.5
        @unknown default:
            0.75
        }
    }
}

enum CaptureCoverageCommitPolicy {
    static func integrate(
        _ observation: CaptureCoverageObservation,
        into tracker: CaptureCoverageTracker,
        thermalState _: ProcessInfo.ThermalState
    ) {
        tracker.integrate(observation)
    }
}

enum CaptureMeshOverlay {
    enum PointFreshness {
        case fresh
        case settled
    }

    /// Looks up committed coverage for a world-space position.
    typealias CoverageQuery = (SIMD3<Float>) -> CaptureCoverageTracker.Voxel?

    /// World-space sphere around the active repair target; uncovered surface
    /// inside it renders amber so the user sees exactly what to rescan.
    struct EmphasisRegion: Equatable, Sendable {
        let center: SIMD3<Float>
        let radiusM: Float

        func contains(_ position: SIMD3<Float>) -> Bool {
            simd_distance_squared(position, center) <= radiusM * radiusM
        }
    }

    /// Coverage paint colour. Pick any colour that reads over a camera feed.
    private static let coverageGreen = UIColor(red: 0.2, green: 0.82, blue: 0.48, alpha: 1)
    private static let freshBlue = UIColor(red: 0.2, green: 0.75, blue: 1, alpha: 1)

    /// Recently committed observations pulse briefly before settling.
    static let commitPulseSeconds: TimeInterval = 0.7

    /// Keep density readable without flooding the GPU.
    private static let pointVertexStride = 2
    static let livePaintHeightRadiusM: Float = 2.2
    private static let paintNodeName = "coveragePaint"
    private static let paintDepthBiasM: Float = 0.002
    private static let metalDevice = MTLCreateSystemDefaultDevice()

    static func material(
        for style: CoverageOverlayStyle,
        freshness: PointFreshness = .settled
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true

        switch style {
        case .tintedMesh:
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false
            material.diffuse.contents = coverageGreen.withAlphaComponent(0.28)
            material.emission.contents = coverageGreen.withAlphaComponent(0.18)
            material.fillMode = .fill
            material.transparency = 0.72
        case .wireframe:
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false
            material.diffuse.contents = coverageGreen.withAlphaComponent(0.9)
            material.emission.contents = coverageGreen.withAlphaComponent(0.55)
            material.fillMode = .lines
            material.transparency = 0.1
        case .confidenceDots:
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false
            let color = freshness == .fresh ? freshBlue : coverageGreen
            material.diffuse.contents = color
            material.emission.contents = color
            material.fillMode = .fill
            // Freshness remains distinguishable without color: fresh points are
            // larger and opaque, while settled points are smaller and dimmer.
            material.transparency = freshness == .fresh ? 1 : 0.35
        case .paint:
            // Per-vertex colors carry the fill; the material just blends them.
            material.diffuse.contents = UIColor.white
            material.blendMode = .alpha
            material.fillMode = .fill
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = true
            material.setValue(paintDepthBiasM, forKey: "paintDepthBiasM")
            material.shaderModifiers = [
                .geometry: """
                #pragma arguments
                float paintDepthBiasM;
                #pragma body
                float3 worldPosition =
                    (scn_node.modelTransform * _geometry.position).xyz;
                float3 cameraPosition = scn_frame.inverseViewTransform[3].xyz;
                float3 towardCamera = normalize(cameraPosition - worldPosition);
                float3 worldOffset = towardCamera * paintDepthBiasM;
                _geometry.position.xyz += (
                    scn_node.inverseModelTransform
                    * float4(worldOffset, 0.0)
                ).xyz;
                """
            ]
        }
        return material
    }

    static func depthPrepassMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = UIColor.white
        material.colorBufferWriteMask = []
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = true
        return material
    }

    /// Legacy sync for the non-paint styles (dots, tinted mesh, wireframe).
    /// The active `.paint` style renders through `syncPaint`, which caches
    /// copied geometry per anchor revision instead of rebuilding every call.
    static func sync(
        anchors: [UUID: ARMeshAnchor],
        into rootNode: SCNNode,
        freshAnchorIDs: Set<UUID>,
        style: CoverageOverlayStyle
    ) {
        removeStaleChildNodes(from: rootNode, liveAnchorIDs: Set(anchors.keys))

        for (id, anchor) in anchors {
            let freshness: PointFreshness = freshAnchorIDs.contains(id)
                ? .fresh
                : .settled
            let node = childNode(for: id, in: rootNode)
            node.geometry = geometry(
                from: anchor.geometry,
                style: style,
                freshness: freshness
            )
            node.simdTransform = anchor.transform
        }
    }

    /// Immutable per-anchor geometry copied out of ARKit's buffers once per
    /// anchor revision. Coverage recolors reuse these buffers instead of
    /// copying, transforming, and recolouring every vertex on each call.
    final class PaintAnchorCache {
        let revision: Int
        let transform: simd_float4x4
        let worldPositions: [SIMD3<Float>]
        let worldBounds: PaintWorldBounds?
        let paintChunkBounds: PaintChunkBounds?
        let colorBuffer: MTLBuffer
        let paintGeometry: SCNGeometry
        let depthGeometry: SCNGeometry
        var needsRecolor = true

        init(
            revision: Int,
            transform: simd_float4x4,
            worldPositions: [SIMD3<Float>],
            worldBounds: PaintWorldBounds?,
            paintChunkBounds: PaintChunkBounds?,
            colorBuffer: MTLBuffer,
            paintGeometry: SCNGeometry,
            depthGeometry: SCNGeometry
        ) {
            self.revision = revision
            self.transform = transform
            self.worldPositions = worldPositions
            self.worldBounds = worldBounds
            self.paintChunkBounds = paintChunkBounds
            self.colorBuffer = colorBuffer
            self.paintGeometry = paintGeometry
            self.depthGeometry = depthGeometry
        }
    }

    struct PaintWorldBounds {
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
    }

    struct PaintChunkBounds {
        let minimum: CaptureCoverageTracker.PaintChunkKey
        let maximum: CaptureCoverageTracker.PaintChunkKey

        func intersects(
            _ chunks: Set<CaptureCoverageTracker.PaintChunkKey>
        ) -> Bool {
            chunks.contains {
                $0.x >= minimum.x && $0.x <= maximum.x
                    && $0.y >= minimum.y && $0.y <= maximum.y
                    && $0.z >= minimum.z && $0.z <= maximum.z
            }
        }
    }

    static func syncPaint(
        anchors: [UUID: ARMeshAnchor],
        revisions: [UUID: Int],
        into rootNode: SCNNode,
        cache: inout [UUID: PaintAnchorCache],
        coverage: CoverageQuery?,
        voxelSizeM: Float,
        dirtyPaintChunks: Set<CaptureCoverageTracker.PaintChunkKey>,
        mode: CoverageOverlayMode = .camera,
        emphasis: EmphasisRegion? = nil,
        cameraPosition: SIMD3<Float>? = nil,
        forceRecolor: Bool = false,
        forceAnchorIDs: Set<UUID> = [],
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Set<UUID> {
        let liveAnchorIDs = Set(anchors.keys)
        removeStaleChildNodes(from: rootNode, liveAnchorIDs: liveAnchorIDs)
        if cache.keys.contains(where: { !liveAnchorIDs.contains($0) }) {
            for id in cache.keys.filter({ !liveAnchorIDs.contains($0) }) {
                cache.removeValue(forKey: id)
            }
        }
        var recoloredAnchorIDs: Set<UUID> = []

        for (id, anchor) in anchors {
            let node = childNode(for: id, in: rootNode)
            let revision = revisions[id] ?? 0
            let entry: PaintAnchorCache
            if let cached = cache[id], cached.revision == revision {
                entry = cached
            } else {
                guard let created = makePaintAnchorCache(
                    from: anchor,
                    revision: revision,
                    voxelSizeM: voxelSizeM
                ) else {
                    continue
                }
                entry = created
                cache[id] = entry
            }

            let paintNode = paintChildNode(in: node)
            if node.geometry !== entry.depthGeometry {
                node.geometry = entry.depthGeometry
                node.renderingOrder = 90
                node.simdTransform = entry.transform
            }
            if paintNode.geometry !== entry.paintGeometry {
                paintNode.geometry = entry.paintGeometry
            }

            let isVisible = shouldShowPaint(
                bounds: entry.worldBounds,
                cameraPosition: cameraPosition,
                mode: mode
            )
            if paintNode.isHidden == isVisible {
                paintNode.isHidden = !isVisible
            }
            if forceRecolor
                || forceAnchorIDs.contains(id)
                || entry.paintChunkBounds?.intersects(dirtyPaintChunks) == true
            {
                entry.needsRecolor = true
            }
            guard isVisible, entry.needsRecolor else { continue }
            updatePaintColors(
                entry,
                coverage: coverage,
                mode: mode,
                emphasis: emphasis,
                now: now
            )
            entry.needsRecolor = false
            recoloredAnchorIDs.insert(id)
        }
        return recoloredAnchorIDs
    }

    private static func removeStaleChildNodes(
        from rootNode: SCNNode,
        liveAnchorIDs: Set<UUID>
    ) {
        for child in rootNode.childNodes {
            guard let name = child.name,
                  let id = UUID(uuidString: name),
                  liveAnchorIDs.contains(id)
            else {
                child.removeFromParentNode()
                continue
            }
        }
    }

    private static func childNode(for id: UUID, in rootNode: SCNNode) -> SCNNode {
        if let existing = rootNode.childNode(withName: id.uuidString, recursively: false) {
            return existing
        }
        let node = SCNNode()
        node.name = id.uuidString
        node.renderingOrder = 90
        rootNode.addChildNode(node)
        return node
    }

    private static func paintChildNode(in anchorNode: SCNNode) -> SCNNode {
        if let existing = anchorNode.childNode(
            withName: paintNodeName,
            recursively: false
        ) {
            return existing
        }
        let node = SCNNode()
        node.name = paintNodeName
        node.renderingOrder = 100
        anchorNode.addChildNode(node)
        return node
    }

    // MARK: - Paint overlay

    /// RGBA fill for one voxel's coverage state. Pure so display policy is
    /// unit-testable: transparent when unscanned, faint green when seen, firm
    /// green when solid, desaturated blue-gray when only low-confidence depth
    /// observed it, and a brief brighter pulse right after a commit. Inside
    /// an emphasized repair region, uncovered surface renders amber instead
    /// of transparent so the missing area is visible on the mesh.
    static func paintColor(
        voxel: CaptureCoverageTracker.Voxel?,
        mode: CoverageOverlayMode,
        now: TimeInterval,
        emphasized: Bool = false
    ) -> SIMD4<Float> {
        guard let voxel else {
            guard emphasized else { return SIMD4(0, 0, 0, 0) }
            return SIMD4(1, 0.66, 0.18, mode == .camera ? 0.3 : 0.55)
        }

        let isLowConfidenceOnly = voxel.maxConfidence < 2
        var color: SIMD3<Float> = isLowConfidenceOnly
            ? SIMD3(0.45, 0.62, 0.72)
            : SIMD3(0.01, 0.85, 0.52)

        var alpha: Float
        switch voxel.state {
        case .seen:
            alpha = mode == .camera ? 0.16 : 0.45
        case .solid:
            alpha = mode == .camera ? 0.38 : 0.85
        }

        let sinceObserved = now - voxel.lastObservedAt
        if sinceObserved >= 0, sinceObserved < commitPulseSeconds {
            let pulse = Float(1 - sinceObserved / commitPulseSeconds)
            color = simd_mix(color, SIMD3(1, 1, 1), SIMD3(repeating: 0.5 * pulse))
            alpha = min(1, alpha + 0.25 * pulse)
        }
        return SIMD4(color.x, color.y, color.z, alpha)
    }

    private static func makePaintAnchorCache(
        from anchor: ARMeshAnchor,
        revision: Int,
        voxelSizeM: Float
    ) -> PaintAnchorCache? {
        let meshGeometry = anchor.geometry
        let vertices = meshGeometry.vertices
        let transform = anchor.transform
        let colorStride = MemoryLayout<SIMD4<Float>>.stride
        guard let colorBuffer = metalDevice?.makeBuffer(
            length: max(1, vertices.count * colorStride),
            options: .storageModeShared
        ) else {
            return nil
        }
        memset(colorBuffer.contents(), 0, colorBuffer.length)

        let vertexSource = ownedFloat3Source(
            from: vertices,
            semantic: .vertex
        )
        let normalSource = ownedFloat3Source(
            from: meshGeometry.normals,
            semantic: .normal
        )
        let colorSource = SCNGeometrySource(
            buffer: colorBuffer,
            vertexFormat: .float4,
            semantic: .color,
            vertexCount: vertices.count,
            dataOffset: 0,
            dataStride: colorStride
        )
        let element = ownedTriangleElement(from: meshGeometry.faces)

        var worldPositions = [SIMD3<Float>](
            repeating: .zero,
            count: vertices.count
        )
        let vertexPointer = vertices.buffer.contents()
        for index in 0..<vertices.count {
            // Packed float3: load components individually — a SIMD3 load
            // would read 16 bytes from a 12-byte-stride buffer.
            let pointer = vertexPointer
                .advanced(by: vertices.offset + vertices.stride * index)
            let local = SIMD3<Float>(
                pointer.load(as: Float.self),
                pointer.load(fromByteOffset: 4, as: Float.self),
                pointer.load(fromByteOffset: 8, as: Float.self)
            )
            let world = transform * SIMD4(local.x, local.y, local.z, 1)
            worldPositions[index] = SIMD3(world.x, world.y, world.z)
        }
        let worldBounds = bounds(of: worldPositions)
        let paintGeometry = SCNGeometry(
            sources: [vertexSource, normalSource, colorSource],
            elements: [element]
        )
        paintGeometry.materials = [material(for: .paint)]
        let depthGeometry = SCNGeometry(
            sources: [vertexSource],
            elements: [element]
        )
        depthGeometry.materials = [depthPrepassMaterial()]

        return PaintAnchorCache(
            revision: revision,
            transform: transform,
            worldPositions: worldPositions,
            worldBounds: worldBounds,
            paintChunkBounds: worldBounds.map {
                PaintChunkBounds(
                    minimum: CaptureCoverageTracker.paintChunkKey(
                        for: $0.minimum,
                        voxelSizeM: voxelSizeM
                    ),
                    maximum: CaptureCoverageTracker.paintChunkKey(
                        for: $0.maximum,
                        voxelSizeM: voxelSizeM
                    )
                )
            },
            colorBuffer: colorBuffer,
            paintGeometry: paintGeometry,
            depthGeometry: depthGeometry
        )
    }

    private static func updatePaintColors(
        _ entry: PaintAnchorCache,
        coverage: CoverageQuery?,
        mode: CoverageOverlayMode,
        emphasis: EmphasisRegion?,
        now: TimeInterval
    ) {
        let colors = entry.colorBuffer.contents().bindMemory(
            to: SIMD4<Float>.self,
            capacity: entry.worldPositions.count
        )
        for index in entry.worldPositions.indices {
            let position = entry.worldPositions[index]
            colors[index] = paintColor(
                voxel: coverage?(position),
                mode: mode,
                now: now,
                emphasized: emphasis?.contains(position) ?? false
            )
        }
    }

    private static func bounds(
        of positions: [SIMD3<Float>]
    ) -> PaintWorldBounds? {
        guard var minimum = positions.first else { return nil }
        var maximum = minimum
        for position in positions.dropFirst() {
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }
        return PaintWorldBounds(minimum: minimum, maximum: maximum)
    }

    static func shouldShowPaint(
        bounds: PaintWorldBounds?,
        cameraPosition: SIMD3<Float>?,
        mode: CoverageOverlayMode
    ) -> Bool {
        guard mode == .camera, let bounds, let cameraPosition else {
            return true
        }
        return bounds.maximum.y >= cameraPosition.y - livePaintHeightRadiusM
            && bounds.minimum.y <= cameraPosition.y + livePaintHeightRadiusM
    }

    static func settlePointNodes(
        anchorIDs: Set<UUID>,
        in rootNode: SCNNode
    ) {
        applyPointAppearance(
            .settled,
            to: anchorIDs,
            in: rootNode
        )
    }

    private static func applyPointAppearance(
        _ freshness: PointFreshness,
        to anchorIDs: Set<UUID>,
        in rootNode: SCNNode
    ) {
        for anchorID in anchorIDs {
            guard let node = rootNode.childNode(
                withName: anchorID.uuidString,
                recursively: false
            ) else {
                continue
            }
            applyPointAppearance(freshness, to: node.geometry)
        }
    }

    private static func geometry(
        from meshGeometry: ARMeshGeometry,
        style: CoverageOverlayStyle,
        freshness: PointFreshness
    ) -> SCNGeometry {
        switch style {
        case .confidenceDots:
            return pointGeometry(
                from: meshGeometry,
                freshness: freshness
            )
        case .tintedMesh, .wireframe, .paint:
            return triangleGeometry(
                from: meshGeometry,
                material: material(for: style)
            )
        }
    }

    private static func pointGeometry(
        from meshGeometry: ARMeshGeometry,
        freshness: PointFreshness
    ) -> SCNGeometry {
        let vertices = meshGeometry.vertices
        var indices: [UInt32] = []
        indices.reserveCapacity(max(1, vertices.count / pointVertexStride))
        var index = 0
        while index < vertices.count {
            indices.append(UInt32(index))
            index += pointVertexStride
        }

        let vertexSource = ownedFloat3Source(
            from: vertices,
            semantic: .vertex
        )

        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .point,
            primitiveCount: indices.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        applyPointAppearance(freshness, to: geometry)
        return geometry
    }

    private static func applyPointAppearance(
        _ freshness: PointFreshness,
        to geometry: SCNGeometry?
    ) {
        guard let geometry, let element = geometry.elements.first else { return }
        geometry.materials = [
            material(for: .confidenceDots, freshness: freshness)
        ]
        switch freshness {
        case .fresh:
            element.pointSize = 0.012
            element.minimumPointScreenSpaceRadius = 4
            element.maximumPointScreenSpaceRadius = 8
        case .settled:
            element.pointSize = 0.005
            element.minimumPointScreenSpaceRadius = 1
            element.maximumPointScreenSpaceRadius = 3
        }
    }

    private static func triangleGeometry(
        from meshGeometry: ARMeshGeometry,
        material: SCNMaterial
    ) -> SCNGeometry {
        let vertices = meshGeometry.vertices
        let normals = meshGeometry.normals
        let faces = meshGeometry.faces

        let vertexSource = ownedFloat3Source(
            from: vertices,
            semantic: .vertex
        )
        let normalSource = ownedFloat3Source(
            from: normals,
            semantic: .normal
        )
        let element = ownedTriangleElement(from: faces)

        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        geometry.materials = [material]
        return geometry
    }

    /// ARKit owns and reuses mesh Metal buffers as anchors update. SceneKit
    /// renders asynchronously, so it must receive an immutable copy rather
    /// than a source that references ARKit's buffer after the anchor changes.
    private static func ownedFloat3Source(
        from source: ARGeometrySource,
        semantic: SCNGeometrySource.Semantic
    ) -> SCNGeometrySource {
        let componentsPerVector = 3
        let bytesPerComponent = MemoryLayout<Float>.size
        let vectorByteCount = componentsPerVector * bytesPerComponent
        let dataByteCount = source.count > 0
            ? source.stride * (source.count - 1) + vectorByteCount
            : 0
        let data = Data(
            bytes: source.buffer.contents().advanced(by: source.offset),
            count: dataByteCount
        )
        return SCNGeometrySource(
            data: data,
            semantic: semantic,
            vectorCount: source.count,
            usesFloatComponents: true,
            componentsPerVector: componentsPerVector,
            bytesPerComponent: bytesPerComponent,
            dataOffset: 0,
            dataStride: source.stride
        )
    }

    private static func ownedTriangleElement(
        from faces: ARGeometryElement
    ) -> SCNGeometryElement {
        let indexCount = faces.count * faces.indexCountPerPrimitive
        let data = Data(
            bytes: faces.buffer.contents(),
            count: indexCount * faces.bytesPerIndex
        )
        return SCNGeometryElement(
            data: data,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: faces.bytesPerIndex
        )
    }

}

/// UIKit bridge that shares the ARSession and renders the coverage overlay.
struct CaptureARViewContainer: UIViewRepresentable {
    let session: ARSession
    let guide: CaptureCoverageGuide
    var renderRevision: Int
    var overlayMode: CoverageOverlayMode = .camera
    /// Active repair gap from Coverage Review; its region renders emphasized.
    var repairTarget: CaptureCoverageGap?
    var showsMeshOverlay = true

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        guide.navigationViewport = view
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.delegate = context.coordinator

        if showsMeshOverlay {
            let overlayRoot = SCNNode()
            overlayRoot.name = "captureMeshOverlay"
            view.scene.rootNode.addChildNode(overlayRoot)
            context.coordinator.overlayRoot = overlayRoot
        }
        context.coordinator.attachSessionOnNextRunLoopTurn(
            session,
            to: view
        )
        return view
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        coordinator.isDismantled = true
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        guard showsMeshOverlay else {
            context.coordinator.overlayRoot?.removeFromParentNode()
            context.coordinator.overlayRoot = nil
            context.coordinator.resetPaintRenderState()
            return
        }
        if context.coordinator.overlayRoot == nil {
            let overlayRoot = SCNNode()
            overlayRoot.name = "captureMeshOverlay"
            uiView.scene.rootNode.addChildNode(overlayRoot)
            context.coordinator.overlayRoot = overlayRoot
            // A recreated root has no children: force a full render pass even
            // when the revisions have not moved since the overlay was hidden.
            context.coordinator.resetPaintRenderState()
        }
        guard let overlayRoot = context.coordinator.overlayRoot else { return }

        // Model mode hides the camera feed so the painted surfaces are the
        // only content; the AR session (and coverage integration) keeps running.
        // ARSCNView renders the camera feed *through* `scene.background.contents`,
        // so it must be saved and restored — assigning nil would permanently
        // kill the live camera view.
        if overlayMode == .model {
            if !context.coordinator.isCameraBackgroundHidden {
                context.coordinator.savedCameraBackground =
                    uiView.scene.background.contents
                context.coordinator.isCameraBackgroundHidden = true
                uiView.scene.background.contents = UIColor.black
            }
        } else if context.coordinator.isCameraBackgroundHidden {
            uiView.scene.background.contents =
                context.coordinator.savedCameraBackground
            context.coordinator.savedCameraBackground = nil
            context.coordinator.isCameraBackgroundHidden = false
        }

        if CoverageOverlayStyle.active == .paint {
            let renderState = Coordinator.PaintRenderState(
                renderRevision: renderRevision,
                mode: overlayMode,
                emphasis: repairTarget.map {
                    CaptureMeshOverlay.EmphasisRegion(
                        center: $0.center,
                        radiusM: $0.radiusM
                    )
                }
            )
            // Timer-, pose-, or stats-driven SwiftUI updates land here with an
            // unchanged render state and must not touch anchors or geometry.
            guard context.coordinator.lastPaintRenderState != renderState else {
                return
            }
            context.coordinator.renderPaintOverlay(
                from: guide,
                into: overlayRoot,
                state: renderState
            )
        } else {
            let anchors = guide.meshAnchorsSnapshot()
            let freshAnchorIDs = context.coordinator.refreshFreshAnchorIDs(
                among: Set(anchors.keys),
                revisions: guide.meshAnchorRevisionsSnapshot()
            )
            CaptureMeshOverlay.sync(
                anchors: anchors,
                into: overlayRoot,
                freshAnchorIDs: freshAnchorIDs,
                style: .active
            )
            // Settlement swaps in confidence-dot materials, which would
            // corrupt paint geometry — it stays exclusive to the dot style.
            context.coordinator.scheduleSettlement(in: overlayRoot)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, ARSCNViewDelegate {
        private static let freshnessLifetime: TimeInterval = 1.5

        var overlayRoot: SCNNode?
        /// Camera-feed background saved while Model view hides it.
        var savedCameraBackground: Any?
        var isCameraBackgroundHidden = false
        /// Set by `dismantleUIView` so a pending session attach for a view
        /// SwiftUI already discarded never steals the session from its successor.
        var isDismantled = false

        /// Attaches the shared `ARSession` outside the current layout pass.
        ///
        /// The readiness and live screens each host a `CaptureARViewContainer`
        /// on the same session, and both exist for a frame when the step
        /// changes. On iOS 27, `-[ARSession setViewLayer:]` holds the session's
        /// lock while `ARSCNView` publishes its orientation and flushes
        /// CoreAnimation; that flush runs a SwiftUI layout pass, which creates
        /// the other container, whose `makeUIView` re-entered `setViewLayer:`
        /// on the same thread and died in `_os_unfair_lock_recursive_abort`
        /// (crash point `-[ARSession setViewLayer:] + 48`, iOS 27.0).
        /// Deferring to the next run-loop turn keeps every attach
        /// at top level: a nested layout can only schedule one, never nest one.
        func attachSessionOnNextRunLoopTurn(
            _ session: ARSession,
            to view: ARSCNView
        ) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, !self.isDismantled else { return }
                view.session = session
            }
        }
        private var lastSeenAnchorRevisions: [UUID: Int] = [:]
        private var freshUntilByAnchor: [UUID: TimeInterval] = [:]
        private var settleTask: Task<Void, Never>?

        // MARK: - Paint rendering

        /// Everything that affects painted output. Unchanged state means
        /// `updateUIView` returns before reading a single anchor.
        struct PaintRenderState: Equatable {
            var renderRevision: Int
            var mode: CoverageOverlayMode
            var emphasis: CaptureMeshOverlay.EmphasisRegion?
        }

        private(set) var lastPaintRenderState: PaintRenderState?
        private var paintCache: [UUID: CaptureMeshOverlay.PaintAnchorCache] = [:]
        private var pulseSettleTask: Task<Void, Never>?
        private var pulseAnchorIDs: Set<UUID> = []

        /// Cache stays: anchor geometry keyed by revision remains valid while
        /// the overlay is hidden. Only the "what was last rendered" memory and
        /// the pending pulse settle are discarded.
        func resetPaintRenderState() {
            lastPaintRenderState = nil
            pulseSettleTask?.cancel()
            pulseSettleTask = nil
            pulseAnchorIDs = []
        }

        func renderPaintOverlay(
            from capture: CaptureCoverageGuide,
            into overlayRoot: SCNNode,
            state: PaintRenderState
        ) {
            let previousState = lastPaintRenderState
            lastPaintRenderState = state
            let forceRecolor = previousState == nil
                || previousState?.mode != state.mode
                || previousState?.emphasis != state.emphasis
            let recoloredAnchorIDs = performPaintRender(
                from: capture,
                into: overlayRoot,
                state: state,
                forceRecolor: forceRecolor
            )
            if !recoloredAnchorIDs.isEmpty {
                schedulePulseSettle(
                    from: capture,
                    into: overlayRoot,
                    state: state,
                    anchorIDs: recoloredAnchorIDs
                )
            }
        }

        private func performPaintRender(
            from capture: CaptureCoverageGuide,
            into overlayRoot: SCNNode,
            state: PaintRenderState,
            forceRecolor: Bool = false,
            forceAnchorIDs: Set<UUID> = [],
            consumeChanges: Bool = true
        ) -> Set<UUID> {
            let tracker = capture.coverageTracker
            let dirtyPaintChunks = consumeChanges
                ? tracker?.takePendingPaintChunks() ?? []
                : []
            let cameraPose = capture.liveCameraPoseSnapshot()
            let cameraPosition = cameraPose.map {
                SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z)
            }
            let recolored = CaptureMeshOverlay.syncPaint(
                anchors: capture.meshAnchorsSnapshot(),
                revisions: capture.meshAnchorRevisionsSnapshot(),
                into: overlayRoot,
                cache: &paintCache,
                coverage: { position in tracker?.voxelForPaint(near: position) },
                voxelSizeM: tracker?.voxelSizeM ?? 0.075,
                dirtyPaintChunks: dirtyPaintChunks,
                mode: state.mode,
                emphasis: state.emphasis,
                cameraPosition: cameraPosition,
                forceRecolor: forceRecolor,
                forceAnchorIDs: forceAnchorIDs
            )
            return recolored
        }

        /// One deferred recolor after the commit pulse expires. Renders are
        /// gated on revisions now, so without this pass the pulse highlight
        /// would stay frozen at commit brightness until the next change.
        private func schedulePulseSettle(
            from capture: CaptureCoverageGuide,
            into overlayRoot: SCNNode,
            state: PaintRenderState,
            anchorIDs: Set<UUID>
        ) {
            pulseAnchorIDs.formUnion(anchorIDs)
            pulseSettleTask?.cancel()
            pulseSettleTask = Task { @MainActor [weak self, weak capture, weak overlayRoot] in
                try? await Task.sleep(
                    for: .seconds(CaptureMeshOverlay.commitPulseSeconds + 0.05)
                )
                guard !Task.isCancelled,
                      let self,
                      let capture,
                      let overlayRoot,
                      self.overlayRoot === overlayRoot,
                      let currentState = self.lastPaintRenderState,
                      currentState.mode == state.mode,
                      currentState.emphasis == state.emphasis
                else { return }
                let anchorIDs = self.pulseAnchorIDs
                self.pulseAnchorIDs = []
                // Colors-only pass; deliberately does not reschedule itself.
                _ = self.performPaintRender(
                    from: capture,
                    into: overlayRoot,
                    state: currentState,
                    forceAnchorIDs: anchorIDs,
                    consumeChanges: false
                )
            }
        }

        func refreshFreshAnchorIDs(
            among liveAnchorIDs: Set<UUID>,
            revisions: [UUID: Int],
            now: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) -> Set<UUID> {
            lastSeenAnchorRevisions = lastSeenAnchorRevisions.filter {
                liveAnchorIDs.contains($0.key)
            }
            freshUntilByAnchor = freshUntilByAnchor.filter {
                liveAnchorIDs.contains($0.key)
            }

            for anchorID in liveAnchorIDs {
                guard let revision = revisions[anchorID],
                      lastSeenAnchorRevisions[anchorID] != revision
                else {
                    continue
                }
                lastSeenAnchorRevisions[anchorID] = revision
                freshUntilByAnchor[anchorID] = now + Self.freshnessLifetime
            }

            removeExpiredFreshness(at: now)
            return Set(freshUntilByAnchor.keys)
        }

        func scheduleSettlement(in rootNode: SCNNode) {
            settleTask?.cancel()
            guard let nextExpiration = freshUntilByAnchor.values.min() else {
                settleTask = nil
                return
            }
            let delaySeconds = max(
                0,
                nextExpiration - ProcessInfo.processInfo.systemUptime
            )
            settleTask = Task { @MainActor [weak self, weak rootNode] in
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard !Task.isCancelled, let self, let rootNode else { return }
                let expiredAnchorIDs = self.removeExpiredFreshness(
                    at: ProcessInfo.processInfo.systemUptime
                )
                CaptureMeshOverlay.settlePointNodes(
                    anchorIDs: expiredAnchorIDs,
                    in: rootNode
                )
                self.scheduleSettlement(in: rootNode)
            }
        }

        @discardableResult
        private func removeExpiredFreshness(
            at now: TimeInterval
        ) -> Set<UUID> {
            let expiredAnchorIDs = Set(
                freshUntilByAnchor.compactMap { anchorID, expiration in
                    expiration <= now ? anchorID : nil
                }
            )
            for anchorID in expiredAnchorIDs {
                freshUntilByAnchor.removeValue(forKey: anchorID)
            }
            return expiredAnchorIDs
        }
    }
}

/// The live screen re-renders its body every 100 ms for the pose marker and
/// once a second for the recording timer. Used with `.equatable()`, this lets
/// SwiftUI skip `updateUIView` unless an overlay input actually changed.
extension CaptureARViewContainer: @MainActor Equatable {
    static func == (lhs: CaptureARViewContainer, rhs: CaptureARViewContainer) -> Bool {
        lhs.guide === rhs.guide
            && lhs.renderRevision == rhs.renderRevision
            && lhs.overlayMode == rhs.overlayMode
            && lhs.repairTarget == rhs.repairTarget
            && lhs.showsMeshOverlay == rhs.showsMeshOverlay
    }
}
