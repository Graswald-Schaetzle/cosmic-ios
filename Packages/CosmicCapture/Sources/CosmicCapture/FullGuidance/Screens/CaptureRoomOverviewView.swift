import SwiftUI
import SceneKit
import os
import simd

struct CaptureRoomOverviewView: View {
    let overview: CaptureRoomOverview
    var navigation: CaptureGapNavigation? = nil
    var isExpanded = false
    var lesson: AnyView? = nil
    var warning: String? = nil
    var horizontalCompact = false
    var emphasizesExpansion = false
    var isPracticing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var guide: AnyView = AnyView(EmptyView())
    var expand: () -> Void = {}
    var close: () -> Void = {}
    @State private var resetView = 0

    var body: some View {
        Group {
            if isExpanded {
                GeometryReader { proxy in
                    VStack(spacing: 14) {
                        header
                        if proxy.size.width > proxy.size.height && (overview.layer != .room || lesson != nil) {
                            HStack(alignment: .top, spacing: 20) {
                                map
                                VStack(alignment: .leading, spacing: 14) {
                                    legend(vertical: true)
                                    Spacer(minLength: 0)
                                    status
                                }.frame(width: lesson == nil ? 190 : 250)
                            }
                        } else {
                            map
                            ViewThatFits(in: .horizontal) {
                                legend(vertical: false)
                                legend(vertical: true)
                            }
                            status
                        }
                    }
                }
            } else if horizontalCompact {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    HStack(spacing: 12) {
                        map.frame(width: 160, height: 160)
                        guide.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    compactLegend
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    map.frame(height: 160)
                    compactLegend
                    guide
                }
            }
        }
        .padding(isExpanded ? 18 : 12)
        .foregroundStyle(.white)
        .background(Color(red: 0.12, green: 0.15, blue: 0.15).opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)) }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(overview.layer == .room ? "Walls" : overview.layer == .floor ? "Floor" : "Ceiling")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("capture-surface-label")
            Spacer(minLength: 0)
            if !isPracticing || isExpanded {
            Button(action: close) {
                if isExpanded {
                    Text("Done").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).frame(height: 44)
                        .background(.white.opacity(0.12), in: Capsule())
                } else if isPracticing {
                    Text("Skip").font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                } else {
                    Image(systemName: "xmark").foregroundStyle(.white.opacity(0.6))
                        .frame(width: 44, height: 44)
                }
            }
            .overlay(alignment: .leading) {
                if isExpanded && lesson != nil {
                    CaptureTutorialPointer(direction: .right).offset(x: -38)
                }
            }
            .accessibilityLabel(isExpanded ? "Done" : isPracticing ? "Skip walkthrough" : "Hide scan guide")
            }
        }
    }

    private var map: some View {
        GeometryReader { proxy in
            CaptureRoomMiniature(overview: overview, resetView: resetView,
                renderRevision: overview.renderRevision, viewportSize: proxy.size,
                allowsOrbit: overview.layer == .room)
        }
        .background(Color(red: 0.025, green: 0.045, blue: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(overview.layer.rawValue)
        .accessibilityHint(overview.layer == .room ? "Drag to rotate. Pinch to zoom." : "Fixed to your starting direction")
        .overlay {
            if !overview.hasCoverageSnapshot {
                ProgressView().tint(.white).accessibilityLabel("Loading coverage")
            }
        }
        .overlay(alignment: .bottom) {
            if !isExpanded &&
                (!overview.hasCoverageSnapshot || !overview.patches.contains(where: { $0.category == (overview.layer.category ?? .wall) })) {
                Text(overview.layerMessage).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                if isExpanded { resetView += 1 } else { expand() }
            } label: {
                Image(systemName: isExpanded ? "viewfinder" : "arrow.up.left.and.arrow.down.right")
                    .font(.caption).frame(width: 44, height: 44)
                    .symbolEffect(.pulse, options: .repeat(2), value: emphasizesExpansion && !reduceMotion)
                    .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel(isExpanded ? "Fit room layout" : "Expand room layout")
            .captureTourTarget(.expand)
            .overlay(alignment: .bottom) {
                if emphasizesExpansion && !isExpanded {
                    CaptureTutorialPointer(direction: .up).offset(y: 36)
                }
            }
            .padding(4)
        }
        .captureTourTarget(.map)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lesson { lesson }
            else if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let gap = overview.visibleGap {
                Text(navigation?.target == gap ? navigation!.compactMessage : "Scan the marked \(gap.category.rawValue)")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("capture-layout-gap-cue")
            }

        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactLegend: some View {
        Group {
            if overview.hasCoverageSnapshot {
                ViewThatFits(in: .horizontal) {
                    compactLegendItems(vertical: false)
                    compactLegendItems(vertical: true)
                }
            }
        }
    }

    private func compactLegendItems(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            Label {
                Text("Needs scanning")
            } icon: {
                Image(systemName: "square.fill").foregroundStyle(.gray)
            }
            Label {
                Text("One view")
            } icon: {
                Image(systemName: "square.fill")
                    .foregroundStyle(Color(red: 0.6, green: 0.85, blue: 0.7))
            }
            Label {
                Text("Multiple views")
            } icon: {
                Image(systemName: "square.fill")
                    .foregroundStyle(Color(red: 0.05, green: 0.85, blue: 0.45))
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legend(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            if overview.hasCoverageSnapshot {
                Label("Needs scanning", systemImage: "square.fill").foregroundStyle(.gray)
                Label("One view", systemImage: "square.fill").foregroundStyle(Color(red: 0.6, green: 0.85, blue: 0.7))
                Label("Multiple views", systemImage: "square.fill").foregroundStyle(Color(red: 0.05, green: 0.85, blue: 0.45))
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Render the shared-session room outline surfaces, not a second camera/session.
/// Translucent, double-sided planes keep the interior visible from above/below.
private struct CaptureRoomMiniature: UIViewRepresentable {
    let overview: CaptureRoomOverview
    let resetView: Int
    let renderRevision: Int
    let viewportSize: CGSize
    let allowsOrbit: Bool

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "capture-room-miniature"
        view.isAccessibilityElement = true
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.allowsCameraControl = false
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.automaticTarget = false
        view.defaultCameraController.inertiaEnabled = false
        view.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
        view.defaultCameraController.automaticTarget = false
        view.defaultCameraController.minimumVerticalAngle = -89
        view.defaultCameraController.maximumVerticalAngle = 89
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        view.antialiasingMode = .multisampling2X
        view.addGestureRecognizer(context.coordinator.pinchGesture)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.allowsCameraControl != allowsOrbit { view.allowsCameraControl = allowsOrbit }
        context.coordinator.pinchGesture.isEnabled = !allowsOrbit
        context.coordinator.update(overview: overview, resetView: resetView, view: view, viewportSize: viewportSize)
    }

    @MainActor final class Renderer: NSObject {
        let scene = SCNScene()
        let camera = SCNNode()
        private let position = SCNNode(geometry: SCNSphere(radius: 0.07))
        private let direction = SCNNode()
        private let targetMarker = SCNNode()
        private let positionBorder = SCNNode(geometry: SCNSphere(radius: 1))
        private var nodes: [UUID: SCNNode] = [:]
        private var geometryCorners: [UUID: [SIMD3<Float>]] = [:]
        private let coverageRoot = SCNNode()
        private let contextRoot = SCNNode()
        private var lastCoverageRevision = -1
        private var lastLayer: CaptureOverviewLayer?
        private var lastTarget: CaptureCoverageGap?
        private var lastReset = -1
        private var lastLayoutRevision = -1
        private var lastReference: SIMD2<Float>?
        private var fittedSpan: Float = 0
        private var lastViewport = CGSize.zero
        private struct CameraState {
            let transform: simd_float4x4
            let scale: Double
            let target: SCNVector3
            let span: Float
            let viewport: CGSize
        }
        private var cameraStates: [CaptureOverviewLayer: CameraState] = [:]

        private var pinchStartScale: Double = 1
        lazy var pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view as? SCNView, let lens = view.pointOfView?.camera else { return }
            if gesture.state == .began { pinchStartScale = lens.orthographicScale }
            guard gesture.scale.isFinite, gesture.scale > 0 else { return }
            lens.orthographicScale = min(100, max(0.25, pinchStartScale / Double(gesture.scale)))
            view.setNeedsDisplay()
        }

        override init() {
            super.init()
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = true
            camera.camera?.zNear = 0.01
            camera.camera?.zFar = 300
            scene.rootNode.addChildNode(camera)
            scene.rootNode.addChildNode(coverageRoot)
            scene.rootNode.addChildNode(contextRoot)
            position.geometry?.firstMaterial = markerMaterial(.cyan, alpha: 1)
            positionBorder.geometry?.firstMaterial = markerMaterial(.black, alpha: 0.9)
            positionBorder.renderingOrder = 101
            position.renderingOrder = 102
            direction.renderingOrder = 100
            let targetImage = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                UIColor.systemOrange.setStroke()
                context.cgContext.setLineWidth(5)
                context.cgContext.strokeEllipse(in: CGRect(x: 8, y: 8, width: 48, height: 48))
                UIColor.black.withAlphaComponent(0.8).setStroke()
                context.cgContext.setLineWidth(2)
                context.cgContext.strokeEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
            }
            targetMarker.geometry = SCNPlane(width: 1, height: 1)
            targetMarker.geometry?.firstMaterial = markerMaterial(.white, alpha: 1)
            targetMarker.geometry?.firstMaterial?.diffuse.contents = targetImage
            targetMarker.constraints = [SCNBillboardConstraint()]
            targetMarker.renderingOrder = 99
            targetMarker.isHidden = true
            scene.rootNode.addChildNode(targetMarker)
            scene.rootNode.addChildNode(positionBorder)
            scene.rootNode.addChildNode(position)
            scene.rootNode.addChildNode(direction)
            // A schematic heading fan, not a claim of camera visibility or coverage.
            let fan = [SCNVector3(0, 0, 0), SCNVector3(-0.5, 0, -1), SCNVector3(0.5, 0, -1)]
            direction.geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: fan)],
                elements: [SCNGeometryElement(indices: [Int32(0), 1, 2], primitiveType: .triangles)])
            direction.geometry?.firstMaterial = markerMaterial(.cyan, alpha: 0.45)
        }

        private func material(_ color: UIColor, alpha: CGFloat) -> SCNMaterial {
            let result = SCNMaterial()
            result.diffuse.contents = color.withAlphaComponent(alpha)
            result.lightingModel = .constant
            result.isDoubleSided = true
            result.writesToDepthBuffer = alpha >= 1
            return result
        }

        private func markerMaterial(_ color: UIColor, alpha: CGFloat) -> SCNMaterial {
            let result = material(color, alpha: alpha)
            result.readsFromDepthBuffer = false
            result.writesToDepthBuffer = false
            return result
        }

        private func renderCoverage(_ overview: CaptureRoomOverview) {
            coverageRoot.childNodes.forEach { $0.removeFromParentNode() }
            contextRoot.childNodes.forEach { $0.removeFromParentNode() }
            let category = overview.layer.category ?? .wall
            let height = overview.patches.first(where: { $0.category == category })?.center.y ?? 0
            var outlineVertices: [SCNVector3] = []
            for edge in overview.outline.edges {
                outlineVertices += [SCNVector3(edge.start.x, height, edge.start.y), SCNVector3(edge.end.x, height, edge.end.y)]
            }
            if category != .wall && !outlineVertices.isEmpty {
                let outline = SCNGeometry(sources: [SCNGeometrySource(vertices: outlineVertices)],
                    elements: [SCNGeometryElement(indices: outlineVertices.indices.map { Int32($0) }, primitiveType: .line)])
                outline.firstMaterial = material(.white, alpha: 0.45)
                contextRoot.addChildNode(SCNNode(geometry: outline))
            }
            // Four geometry batches, rather than a SceneKit node per patch.
            for group in 0..<4 {
                let patches = overview.patches.filter {
                    $0.category == category && ($0.isTarget(overview.visibleGap) ? 3 : $0.evidence.rawValue) == group
                }
                guard !patches.isEmpty else { continue }
                var vertices: [SCNVector3] = []
                var indices: [Int32] = []
                for patch in patches {
                    let reference: SIMD3<Float> = abs(patch.normal.y) > 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
                    let right = simd_normalize(simd_cross(reference, patch.normal)) * patch.size / 2
                    let up = simd_normalize(simd_cross(patch.normal, right)) * patch.size / 2
                    let start = Int32(vertices.count)
                    vertices += [patch.center - right - up, patch.center + right - up,
                                 patch.center + right + up, patch.center - right + up].map { SCNVector3($0) }
                    indices += [start, start + 1, start + 2, start, start + 2, start + 3]
                }
                let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                    elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
                let colors: [UIColor] = [.gray, UIColor(red: 0.6, green: 0.85, blue: 0.7, alpha: 1),
                                         UIColor(red: 0.05, green: 0.85, blue: 0.45, alpha: 1), .systemOrange]
                let patchMaterial = material(colors[group], alpha: 1)
                // Mesh winding follows the observed face. Do not paint its
                // evidence onto the reverse side of a wall.
                patchMaterial.isDoubleSided = category != .wall
                geometry.firstMaterial = patchMaterial
                coverageRoot.addChildNode(SCNNode(geometry: geometry))
            }
        }

        func update(overview: CaptureRoomOverview, resetView: Int, view: SCNView, viewportSize: CGSize) {
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            defer { SCNTransaction.commit() }
            let layerChanged = lastLayer != overview.layer
            if layerChanged, let lastLayer, let lens = view.pointOfView?.camera {
                cameraStates[lastLayer] = CameraState(transform: view.pointOfView!.simdTransform,
                    scale: lens.orthographicScale, target: view.defaultCameraController.target,
                    span: fittedSpan, viewport: lastViewport)
            }
            if layerChanged || lastCoverageRevision != overview.coverageRevision || lastTarget != overview.visibleGap || lastLayoutRevision != overview.layoutRevision {
                renderCoverage(overview)
                lastCoverageRevision = overview.coverageRevision
                lastTarget = overview.visibleGap
            }
            coverageRoot.isHidden = false
            contextRoot.isHidden = overview.layer == .room
            let ids = Set(overview.surfaces.map(\.id))
            for id in Array(nodes.keys) where !ids.contains(id) {
                nodes.removeValue(forKey: id)?.removeFromParentNode()
                geometryCorners.removeValue(forKey: id)
            }
            var corners: [SIMD3<Float>] = []
            for surface in overview.surfaces {
                let local = surface.localCorners
                guard local.count >= 3 else { continue }
                let node: SCNNode
                if let existing = nodes[surface.id] {
                    node = existing
                } else {
                    node = SCNNode()
                    nodes[surface.id] = node
                    scene.rootNode.addChildNode(node)
                }
                if geometryCorners[surface.id] != local {
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: CGFloat(local[0].x), y: CGFloat(local[0].y)))
                    for point in local.dropFirst() {
                        path.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
                    }
                    path.close()
                    let shape = SCNShape(path: path, extrusionDepth: 0.002)
                    switch surface.kind {
                    case .wall: shape.firstMaterial = material(.white, alpha: 0.32)
                    case .floor: shape.firstMaterial = material(.lightGray, alpha: 0.18)
                    case .opening: shape.firstMaterial = material(.cyan, alpha: 0.12)
                    }
                    node.geometry = shape
                    if node.childNodes.isEmpty { node.addChildNode(SCNNode()) }
                    let indices: [Int32] = local.indices.flatMap {
                        [Int32($0), Int32(($0 + 1) % local.count)]
                    }
                    let border = SCNGeometry(sources: [SCNGeometrySource(vertices: local.map { SCNVector3($0) })],
                        elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
                    border.firstMaterial = material(surface.kind == .opening ? .cyan : .white, alpha: 0.65)
                    node.childNodes[0].geometry = border
                    geometryCorners[surface.id] = local
                }
                node.isHidden = overview.layer != .room
                node.simdTransform = surface.transform
                for point in local {
                    let world = surface.transform * SIMD4(point.x, point.y, point.z, 1)
                    if overview.layer == .room { corners.append(SIMD3(world.x, world.y, world.z)) }
                }
            }
            if overview.layer == .room {
                corners += overview.patches.filter { $0.category == .wall }.map(\.center)
            }
            if let category = overview.layer.category {
                corners += overview.patches.filter { $0.category == category }.map(\.center)
                let height = overview.patches.first(where: { $0.category == category })?.center.y ?? 0
                corners += overview.outline.edges.flatMap {
                    [SIMD3($0.start.x, height, $0.start.y), SIMD3($0.end.x, height, $0.end.y)]
                }
            }
            let pose = overview.cameraTransform
            let p = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            if let target = overview.visibleGap { corners.append(target.center) }
            corners.append(p)
            var lower = corners.first ?? p
            var upper = lower
            for point in corners {
                lower = simd_min(lower, point)
                upper = simd_max(upper, point)
            }
            let size = upper - lower
            let span = max(overview.layer == .room ? 4 : 2, max(size.x, max(size.y, size.z)))
            // Fit on first geometry, explicit reset, or substantial new extent.
            // Small room outline revisions must not make the fixed overview jump.
            if (layerChanged || viewportSize != lastViewport), let saved = cameraStates[overview.layer],
               resetView == lastReset, overview.referenceForward == lastReference, span <= saved.span * 1.2 {
                view.pointOfView = camera
                camera.simdTransform = saved.transform
                let oldAspect = saved.viewport.width / max(1, saved.viewport.height)
                let newAspect = viewportSize.width / max(1, viewportSize.height)
                camera.camera?.orthographicScale = saved.scale * max(1, oldAspect / max(0.1, newAspect))
                view.defaultCameraController.target = saved.target
                fittedSpan = saved.span
            } else if layerChanged || viewportSize != lastViewport || overview.referenceForward != lastReference || resetView != lastReset || span > fittedSpan * 1.2 {
                let center = (lower + upper) / 2
                view.pointOfView = camera
                let north = overview.referenceForward ?? SIMD2<Float>(0, -1)
                if overview.layer == .room {
                    // A three-quarter view reveals wall height and adjoining sides.
                    let right = SIMD2(-north.y, north.x)
                    camera.simdPosition = center + SIMD3(-north.x + right.x * 0.75, 0.8,
                                                         -north.y + right.y * 0.75) * span
                    camera.look(at: SCNVector3(center), up: SCNVector3(0, 1, 0),
                                localFront: SCNVector3(0, 0, -1))
                } else {
                    camera.simdPosition = center + SIMD3(0, span, 0)
                    camera.look(at: SCNVector3(center), up: SCNVector3(north.x, 0, north.y),
                                localFront: SCNVector3(0, 0, -1))
                }
                // Fit the actual projected geometry instead of a cube based on
                // its longest world axis, which wastes space for long rooms.
                let cameraFromWorld = simd_inverse(camera.simdWorldTransform)
                let projected = corners.map { point -> SIMD2<Float> in
                    let local = cameraFromWorld * SIMD4(point.x, point.y, point.z, 1)
                    return SIMD2(local.x, local.y)
                }
                camera.camera?.orthographicScale = CaptureOverviewFraming.scale(points: projected, viewport: viewportSize)
                view.defaultCameraController.target = SCNVector3(center)
                fittedSpan = span
                lastReset = resetView
            }
            // Keep the marker legible as the map expands. In coverage views its
            // position is projected onto the selected surface, not camera height.
            let markerHeight = overview.layer.category.flatMap { category in
                overview.patches.first(where: { $0.category == category })?.center.y
            } ?? p.y
            let markerPoint = SIMD3(p.x, markerHeight, p.z)
            let unitsPerPoint = Float(camera.camera?.orthographicScale ?? 3) * 2 / Float(max(1, viewportSize.height))
            targetMarker.isHidden = overview.visibleGap == nil
            if let target = overview.visibleGap {
                targetMarker.simdPosition = target.center
                targetMarker.simdScale = SIMD3(repeating: unitsPerPoint * 30)
            }
            position.simdPosition = markerPoint
            positionBorder.simdPosition = markerPoint
            position.simdScale = SIMD3(repeating: unitsPerPoint * 4 / 0.07)
            positionBorder.simdScale = SIMD3(repeating: unitsPerPoint * 5.5)
            direction.simdPosition = markerPoint
            direction.simdScale = SIMD3(repeating: unitsPerPoint * 24)
            let heading = overview.cameraForward
            direction.simdOrientation = simd_quatf(angle: atan2(-heading.x, -heading.y), axis: SIMD3(0, 1, 0))
            if corners.count <= 1 { fittedSpan = 0 }
            lastLayer = overview.layer
            lastLayoutRevision = overview.layoutRevision
            lastReference = overview.referenceForward
            lastViewport = viewportSize
            view.setNeedsDisplay()
        }
    }
}


/// Orthographic half-height with a small margin around projected room geometry.
enum CaptureOverviewFraming {
    static func scale(points: [SIMD2<Float>], viewport: CGSize) -> Double {
        let aspect = Float(max(1, viewport.width) / max(1, viewport.height))
        let halfWidth = points.reduce(Float(0)) { max($0, abs($1.x)) }
        let halfHeight = points.reduce(Float(0)) { max($0, abs($1.y)) }
        return Double(max(0.5, max(halfHeight, halfWidth / aspect) * 1.12))
    }
}

/// Shared between miniature and expanded views so inspecting never resets the
/// user's angle. It is separate from recording and from the review point cloud.
final class CaptureLiveCloudCamera {
    var transform: simd_float4x4?
    var scale: Double = 1
    var target = SCNVector3Zero
    /// Clip planes assigned by `fit`, preserved across view recreation.
    /// Restoring transform/scale without them left a recreated SCNCamera on
    /// its 1...100 defaults, which can clip a nearby cloud to a blank view.
    var zNear: Double?
    var zFar: Double?
    var resetRevision = 0
    private(set) var startingDirection: SIMD3<Float>?
    var overviewDirection: SIMD3<Float>?
    var viewingDirection: SIMD3<Float> { overviewDirection ?? startingDirection ?? SIMD3(0, 0, 1) }

    /// Latch the starting horizontal heading, rather than following every phone
    /// movement or resetting the user's chosen angle as points arrive.
    @discardableResult
    func recordStartingDirection(pose: simd_float4x4) -> Bool {
        guard startingDirection == nil else { return false }
        let backward = SIMD3<Float>(pose.columns.2.x, 0, pose.columns.2.z)
        guard backward.x.isFinite, backward.z.isFinite, simd_length(backward) > 0.15 else { return false }
        startingDirection = simd_normalize(backward)
        return true
    }

    func reset() {
        transform = nil
        overviewDirection = nil
        zNear = nil
        zFar = nil
        resetRevision &+= 1
    }
    func level() {
        let direction = transform.map { SIMD3<Float>($0.columns.2.x, 0, $0.columns.2.z) } ?? viewingDirection
        transform = nil
        overviewDirection = simd_length(direction) > 0.01 ? simd_normalize(direction) : startingDirection ?? SIMD3(0, 0, 1)
        zNear = nil
        zFar = nil
        resetRevision &+= 1
    }
}

struct CaptureLiveCloudCard: View {
    let pointCloud: CapturePointCloud?
    let revision: Int
    let camera: CaptureLiveCloudCamera
    var pose: simd_float4x4? = nil
    var isExpanded = false
    var horizontalCompact = false
    var isPracticing = false
    let instruction: String
    var warning: String? = nil
    var onInteraction: (() -> Void)? = nil
    var onReset: (() -> Void)? = nil
    var expand: (() -> Void)? = nil
    let close: () -> Void
    @State private var resetRevision = 0

    var body: some View {
        Group {
            if isExpanded {
                // The preview owns the whole panel. Teaching is a separate overlay.
                scene.overlay(alignment: .top) { header.padding(12) }
                    .overlay(alignment: .bottomTrailing) { controls.padding(12) }
                    .overlay(alignment: .bottomLeading) {
                        if let message = warning {
                            Text(message).font(.caption).padding(10)
                                .background(.black.opacity(0.7), in: Capsule()).padding(12)
                        }
                    }
            } else {
                VStack(spacing: 10) {
                    header
                    let layout = horizontalCompact ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 10))
                    layout {
                        scene.overlay(alignment: .topTrailing) { controls.padding(4) }
                            .frame(height: 180)
                        Text(warning ?? instruction)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(warning == nil ? .white : .orange)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(12)
            }
        }
        .foregroundStyle(.white).buttonStyle(.plain)
        .background(Color(red: 0.07, green: 0.10, blue: 0.11).opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var header: some View {
        HStack {
            Text("Your scan").font(.subheadline.weight(.semibold))
                .padding(.horizontal, isExpanded ? 12 : 0)
                .padding(.vertical, isExpanded ? 8 : 0)
                .background(isExpanded ? .black.opacity(0.7) : .clear, in: Capsule())
            Spacer()
            if !isPracticing || isExpanded {
                Button(action: close) {
                    if isExpanded { Text("Done").font(.subheadline.weight(.semibold)).padding(.horizontal, 16) }
                    else { Image(systemName: "xmark") }
                }
                .frame(minWidth: 44, minHeight: 44)
                .background(isExpanded ? .black.opacity(0.8) : .clear, in: Capsule())
                .captureTourTarget(.done)
                .accessibilityLabel(isExpanded ? "Done" : "Hide scan preview")
            }
        }
    }

    private var scene: some View {
        ZStack {
            CaptureLiveCloudScene(pointCloud: pointCloud, revision: revision, pose: pose,
                cameraState: camera, resetRevision: resetRevision, onInteraction: onInteraction)
            if pointCloud == nil {
                Text("Move slowly to start your preview.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(32).allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .captureTourTarget(.map)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                camera.reset()
                resetRevision = camera.resetRevision
                onReset?()
            } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
            }
            .captureTourTarget(.reset)
            .accessibilityLabel("Reset preview")
            .accessibilityHint("Returns to the original angle and shows the whole scan")
            if let expand {
                Button(action: expand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                }.captureTourTarget(.expand).accessibilityLabel("Expand scan preview")
            }
        }
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CaptureLiveCloudScene: UIViewRepresentable {
    let pointCloud: CapturePointCloud?
    let revision: Int
    let pose: simd_float4x4?
    let cameraState: CaptureLiveCloudCamera
    let resetRevision: Int
    var onInteraction: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(state: cameraState) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.02, green: 0.04, blue: 0.055, alpha: 1)
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = false
        view.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
        view.defaultCameraController.automaticTarget = false
        view.defaultCameraController.minimumVerticalAngle = -89
        view.defaultCameraController.maximumVerticalAngle = 89
        let scene = SCNScene()
        scene.rootNode.addChildNode(context.coordinator.cloud)
        scene.rootNode.addChildNode(context.coordinator.marker)
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        context.coordinator.camera.camera = camera
        scene.rootNode.addChildNode(context.coordinator.camera)
        view.scene = scene
        view.pointOfView = context.coordinator.camera
        if let transform = cameraState.transform {
            context.coordinator.camera.simdTransform = transform
            camera.orthographicScale = cameraState.scale
            // Restore the fitted clip planes with the pose. Without them a
            // recreated camera keeps SceneKit's 1...100 defaults and can clip
            // the whole cloud to a blank view after compact <-> expanded.
            if let zNear = cameraState.zNear { camera.zNear = zNear }
            if let zFar = cameraState.zFar { camera.zFar = zFar }
            view.defaultCameraController.target = cameraState.target
            context.coordinator.hasUserView = true
        }
        for recognizer in [UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.interacted(_:))),
                           UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.interacted(_:))),
                           UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.interacted(_:)))] {
            recognizer.delegate = context.coordinator
            recognizer.cancelsTouchesInView = false
            view.addGestureRecognizer(recognizer)
        }
        view.accessibilityIdentifier = "capture-live-point-cloud"
        view.accessibilityLabel = "Live 3D scan preview"
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onInteraction = onInteraction
        coordinator.marker.isHidden = pose == nil
        if let pose {
            if cameraState.recordStartingDirection(pose: pose) { coordinator.fittedRevision = -1 }
            coordinator.marker.simdTransform = pose
            let scale = Float(max(0.5, (view.pointOfView?.camera?.orthographicScale ?? 1) * 100 / max(100, view.bounds.height)))
            coordinator.marker.simdScale = SIMD3(repeating: scale)
        }
        view.accessibilityValue = pose == nil ? "Camera position unavailable" : "Camera position and direction shown"
        if coordinator.resetRevision != cameraState.resetRevision {
            coordinator.resetRevision = cameraState.resetRevision
            coordinator.hasUserView = false
            coordinator.fittedRevision = -1
        }
        if coordinator.revision != revision {
            coordinator.revision = revision
            coordinator.cloud.geometry = pointCloud.map(PreviewGeometry.pointCloud)
        }
        guard !coordinator.hasUserView,
              coordinator.fittedRevision != revision || coordinator.fittedSize != view.bounds.size,
              let points = pointCloud?.positions, !points.isEmpty else { return }
        // Layout can be zero during creation. Fit after UIKit supplies the actual
        // viewport, and never override a gesture that began in the meantime.
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator, !coordinator.hasUserView else { return }
            coordinator.fit(points, in: view)
        }
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.save(view)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let state: CaptureLiveCloudCamera
        let cloud = SCNNode()
        let camera = SCNNode()
        let marker = CaptureLiveCloudMarker.makeNode()
        var revision = -1
        var resetRevision: Int
        var hasUserView = false
        var onInteraction: (() -> Void)?
        var fittedRevision = -1
        var fittedSize = CGSize.zero
        init(state: CaptureLiveCloudCamera) {
            self.state = state
            resetRevision = state.resetRevision
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func interacted(_ gesture: UIGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            if gesture.state == .began || gesture.state == .changed { hasUserView = true }
            if gesture.state == .ended || gesture.state == .cancelled { save(view) }
            if gesture.state == .ended { onInteraction?() }
        }
        private static let logger = Logger(
            subsystem: "capture.preview",
            category: "CaptureLivePreview"
        )
        func save(_ view: SCNView) {
            guard hasUserView, let pointOfView = view.pointOfView else { return }
            state.transform = pointOfView.simdTransform
            state.scale = pointOfView.camera?.orthographicScale ?? 1
            state.zNear = pointOfView.camera?.zNear
            state.zFar = pointOfView.camera?.zFar
            state.target = view.defaultCameraController.target
            Self.logger.debug(
                """
                save camera scale=\(self.state.scale, format: .fixed(precision: 3)) \
                zNear=\(self.state.zNear ?? -1) zFar=\(self.state.zFar ?? -1) \
                points=\(self.cloud.geometry?.sources.first?.vectorCount ?? 0)
                """
            )
        }
        func fit(_ points: [SIMD3<Float>], in view: SCNView) {
            guard view.bounds.width > 0, view.bounds.height > 0, let first = points.first else { return }
            fittedRevision = revision
            fittedSize = view.bounds.size
            let framingPoints = marker.isHidden ? points : points + [marker.simdPosition]
            var minimum = first, maximum = first
            for point in framingPoints { minimum = simd_min(minimum, point); maximum = simd_max(maximum, point) }
            let center = (minimum + maximum) * 0.5
            let visiblePoints = framingPoints
            let radius: Float = max(1, simd_length(maximum - minimum))
            camera.simdPosition = center + state.viewingDirection * radius * 2
            camera.look(at: SCNVector3(center), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            let right = camera.simdWorldRight, up = camera.simdWorldUp
            let projected = visiblePoints.map { SIMD2<Float>(simd_dot($0 - center, right), simd_dot($0 - center, up)) }
            camera.camera?.orthographicScale = Double(CaptureOverviewFraming.scale(points: projected, viewport: view.bounds.size))
            camera.camera?.zNear = 0.01
            camera.camera?.zFar = Double(radius * 10)
            view.pointOfView = camera
            view.defaultCameraController.target = SCNVector3(center)
            Self.logger.debug(
                """
                fit camera points=\(points.count) radius=\(radius, format: .fixed(precision: 2)) \
                scale=\(self.camera.camera?.orthographicScale ?? -1, format: .fixed(precision: 3)) \
                zFar=\(self.camera.camera?.zFar ?? -1, format: .fixed(precision: 2))
                """
            )
        }
    }
}

/// A dot and a small camera frustum show position, yaw and tilt in world space.
enum CaptureLiveCloudMarker {
    static func makeNode() -> SCNNode {
        let node = SCNNode()
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 1, green: 0.38, blue: 0.12, alpha: 1)
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        let sphere = SCNSphere(radius: 0.075)
        sphere.segmentCount = 12
        sphere.firstMaterial = material
        let dot = SCNNode(geometry: sphere)
        dot.renderingOrder = 1000
        node.addChildNode(dot)
        let outlineMaterial = material.copy() as! SCNMaterial
        outlineMaterial.diffuse.contents = UIColor.black
        let outline = SCNNode(geometry: SCNSphere(radius: 0.10))
        outline.geometry?.firstMaterial = outlineMaterial
        outline.renderingOrder = 999
        node.addChildNode(outline)
        let corners: [SIMD3<Float>] = [.zero, SIMD3(-0.28, -0.17, -0.65),
            SIMD3(0.28, -0.17, -0.65), SIMD3(0.28, 0.17, -0.65), SIMD3(-0.28, 0.17, -0.65)]
        let edges = [(0,1),(0,2),(0,3),(0,4),(1,2),(2,3),(3,4),(4,1)]
        func ray(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: CGFloat) {
            let offset = end - start
            let cylinder = SCNCylinder(radius: radius, height: CGFloat(simd_length(offset)))
            cylinder.radialSegmentCount = 6
            cylinder.firstMaterial = material
            let ray = SCNNode(geometry: cylinder)
            ray.simdPosition = (start + end) / 2
            ray.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(offset))
            ray.renderingOrder = 1000
            node.addChildNode(ray)
        }
        for (a, b) in edges { ray(from: corners[a], to: corners[b], radius: 0.006) }
        ray(from: .zero, to: SIMD3(0, 0, -0.85), radius: 0.012)
        ray(from: SIMD3(-0.08, 0, -0.72), to: SIMD3(0, 0, -0.85), radius: 0.012)
        ray(from: SIMD3(0.08, 0, -0.72), to: SIMD3(0, 0, -0.85), radius: 0.012)
        node.isHidden = true
        return node
    }
}
