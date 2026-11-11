import SceneKit
import SwiftUI
import UIKit

enum CapturePreviewCopy {
    static let reviewGuidance =
        "Check the area you meant to scan. Revisit any obvious holes, or save when you’re ready."
    static let coverageGuidance =
        "Some areas may need more coverage. This could affect the final result."
    static let gestureHint = "Drag to look around. Pinch to zoom."

    static func accessibilityLabel(
        availability: CapturePreviewAvailability
    ) -> String {
        var parts = ["Interactive capture preview."]
        if availability.hasPointCloud {
            parts.append("Point Cloud layer available.")
        }
        if availability.hasTrajectory {
            parts.append("Cameras layer available.")
        }
        parts.append("The preview is a rough guide.")
        return parts.joined(separator: " ")
    }

    static func layerDetail(isAvailable: Bool) -> String? {
        isAvailable ? nil : "Not recorded for this scan"
    }
}

struct CapturePreviewReviewScreen: View {
    let preview: CapturePreview
    let onKeepCapturing: () -> Void
    let onSave: () -> Void
    let onBack: (() -> Void)?
    let completenessIssues: [CaptureFinishCompleteness.Issue]
    let canKeepCapturing: Bool
    let limitMessage: String?
    let isWalkthrough: Bool
    var walkthrough: CaptureWalkthrough?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var visibility: CapturePreviewLayerVisibility

    init(
        preview: CapturePreview,
        onKeepCapturing: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onBack: (() -> Void)? = nil,
        completenessIssues: [CaptureFinishCompleteness.Issue] = [],
        canKeepCapturing: Bool = true,
        limitMessage: String? = nil,
        isWalkthrough: Bool = false,
        walkthrough: CaptureWalkthrough? = nil
    ) {
        self.preview = preview
        self.onKeepCapturing = onKeepCapturing
        self.onSave = onSave
        self.onBack = onBack
        self.completenessIssues = completenessIssues
        self.canKeepCapturing = canKeepCapturing
        self.limitMessage = limitMessage
        self.isWalkthrough = isWalkthrough
        self.walkthrough = walkthrough
        _visibility = State(
            initialValue: CapturePreviewLayerVisibility(
                availability: preview.availability
            )
        )
    }

    private var locatedGaps: [CaptureCoverageGap] {
        (preview.coverage?.gaps ?? []).filter {
            $0.center.x.isFinite && $0.center.y.isFinite && $0.center.z.isFinite
                && $0.radiusM.isFinite && $0.radiusM > 0
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                previewBackground
                if CaptureScreenLayoutPolicy.usesLandscapeColumns(
                    availableSize: proxy.size,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                ) {
                    landscapeReview(availableSize: proxy.size)
                } else {
                    portraitReview
                }
            }
        }
        .overlayPreferenceValue(CaptureTourAnchors.self) { anchors in
            GeometryReader { geometry in
                if let walkthrough, let stage = walkthrough.postScanStage {
                    let target: CaptureTourTarget = stage == .preview ? .reviewPreview : .reviewActions
                    CaptureTourOverlay(target: anchors[target].map { geometry[$0] },
                        availableSize: geometry.size, safeAreaInsets: geometry.safeAreaInsets,
                        panel: anchors[.tourPanel].map { geometry[$0] }, dimOpacity: 0.65) {
                        CapturePostScanCoachMark(walkthrough: walkthrough)
                    }
                }
            }
        }
        .navigationTitle("Capture preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black.opacity(0.65), for: .navigationBar)
        .toolbar {
            if canKeepCapturing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") {
                        if let onBack {
                            onBack()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var portraitReview: some View {
        if walkthrough?.postScanStage != nil {
            VStack(spacing: 12) {
                CapturePreviewViewport(preview: preview, visibility: $visibility,
                    bottomInset: 12)
                    .captureTourTarget(.reviewPreview)
                    .accessibilityIdentifier("capture-review-viewport")
                    .frame(maxHeight: .infinity)
                if let limitMessage {
                    limitNotice(limitMessage)
                }
                Color.clear.frame(height: 180).captureTourTarget(.tourPanel)
                reviewActions
                    .readableColumn(maxWidth: 520)
            }.padding(16)
        } else {
        ZStack {
            CapturePreviewViewport(
                preview: preview,
                visibility: $visibility,
                bottomInset: 150
            )
            .simultaneousGesture(DragGesture(minimumDistance: 16).onChanged { _ in walkthrough?.inspectedPointCloud = true })
            .simultaneousGesture(MagnifyGesture().onChanged { _ in walkthrough?.inspectedPointCloud = true })
            .accessibilityAction(named: "Mark preview inspected") { walkthrough?.inspectedPointCloud = true }
            .captureTourTarget(.reviewPreview)

            VStack(spacing: 12) {
                if let limitMessage {
                    limitNotice(limitMessage)
                } else {
                    reviewExplanation
                }
                Spacer()
                reviewActions
                    .readableColumn(maxWidth: 520)
            }
            .padding(20)
        }
    }

    }

    private func landscapeReview(availableSize: CGSize) -> some View {
        HStack(spacing: 0) {
            CapturePreviewViewport(
                preview: preview,
                visibility: $visibility,
                bottomInset: 12
            )
            .simultaneousGesture(DragGesture(minimumDistance: 16).onChanged { _ in walkthrough?.inspectedPointCloud = true })
            .simultaneousGesture(MagnifyGesture().onChanged { _ in walkthrough?.inspectedPointCloud = true })
            .accessibilityAction(named: "Mark preview inspected") { walkthrough?.inspectedPointCloud = true }
            .captureTourTarget(.reviewPreview)
            .accessibilityIdentifier("capture-review-viewport")
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                if walkthrough?.postScanStage != nil {
                    Color.clear.frame(maxHeight: .infinity).captureTourTarget(.tourPanel)
                } else {
                ScrollView {
                    if let limitMessage {
                        limitNotice(limitMessage)
                    } else {
                        reviewExplanation
                    }
                }
                .defaultScrollAnchor(.top)
                .defaultScrollAnchor(.top, for: .alignment)
                }
                reviewActions
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(width: min(380, max(300, availableSize.width * 0.4)))
            .background(.black.opacity(0.72))
        }
    }

    private var reviewExplanation: some View {
        Text(
            locatedGaps.isEmpty
                ? CapturePreviewCopy.reviewGuidance
                : CapturePreviewCopy.coverageGuidance
        )
            .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }

    private func limitNotice(_ message: String) -> some View {
        Label(message, systemImage: "stop.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var reviewActions: some View {
        VStack(spacing: 10) {
            if canKeepCapturing {
                Button {
                    onKeepCapturing()
                } label: {
                    Label("Keep scanning", systemImage: "camera.viewfinder")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            .black.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.white.opacity(0.28), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            Button(canKeepCapturing ? "Save" : "Save scan", action: onSave)
                .buttonStyle(PrimaryActionButtonStyle())
                .captureTourTarget(.reviewActions)

        }
    }
}

private struct CapturePreviewViewport: View {
    let preview: CapturePreview
    @Binding var visibility: CapturePreviewLayerVisibility
    let bottomInset: CGFloat

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isShowingLayers = false

    private var layersOnLeading: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            CapturePreviewSceneView(
                preview: preview,
                visibility: visibility
            )
            .ignoresSafeArea(edges: .bottom)
            .accessibilityLabel(accessibilityLabel)

            if !visibility.hasVisibleLayer {
                noVisibleLayers
            }

            VStack {
                Spacer()
                previewLegend
                    .frame(maxWidth: .infinity, alignment: layersOnLeading ? .trailing : .center)
                    .padding(.leading, layersOnLeading ? 84 : 0)
                    .padding(.trailing, layersOnLeading ? 12 : 0)
                    .padding(.bottom, bottomInset)
            }
            .allowsHitTesting(false)

            VStack {
                Spacer()
                HStack {
                    if !layersOnLeading { Spacer() }
                    layerControls
                    if layersOnLeading { Spacer() }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, bottomInset + (layersOnLeading ? 0 : 62))
            }
        }
    }

    private var noVisibleLayers: some View {
        ContentUnavailableView {
            Label("No layers visible", systemImage: "square.3.layers.3d.slash")
        } description: {
            Text("Turn on Point Cloud or Cameras to inspect this capture.")
        } actions: {
            Button("Show available layers") {
                visibility = CapturePreviewLayerVisibility.allAvailable(
                    for: preview.availability
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.55))
    }

    @ViewBuilder
    private var layerControls: some View {
        VStack(alignment: layersOnLeading ? .leading : .trailing, spacing: 10) {
            if isShowingLayers {
                CapturePreviewLayersPanel(
                    availability: preview.availability,
                    visibility: $visibility,
                    onClose: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            isShowingLayers = false
                        }
                    }
                )
                .transition(.move(edge: layersOnLeading ? .leading : .trailing).combined(with: .opacity))
            }

            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isShowingLayers.toggle()
                }
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.72), in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.22), lineWidth: 1)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isShowingLayers ? "Hide preview layers" : "Show preview layers"
            )
            .accessibilityValue(layerAccessibilityValue)
        }
    }

    private var previewLegend: some View {
        Text(CapturePreviewCopy.gestureHint)
            .font(.caption)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: Capsule())
    }

    private var layerAccessibilityValue: String {
        let pointCloud = visibility.isPointCloudVisible ? "on" : "off"
        let cameras = visibility.areCamerasVisible ? "on" : "off"
        return "Point Cloud \(pointCloud), Cameras \(cameras)"
    }

    private var accessibilityLabel: String {
        CapturePreviewCopy.accessibilityLabel(
            availability: preview.availability
        )
    }
}

private struct CapturePreviewLayersPanel: View {
    let availability: CapturePreviewAvailability
    @Binding var visibility: CapturePreviewLayerVisibility
    let onClose: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Layers", systemImage: "square.3.layers.3d")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(
                            width: Theme.minimumTapTarget,
                            height: Theme.minimumTapTarget
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close layers")
            }

            layerToggle(
                title: "Point Cloud",
                detail: CapturePreviewCopy.layerDetail(
                    isAvailable: availability.hasPointCloud
                ),
                systemImage: "circle.grid.3x3.fill",
                isAvailable: availability.hasPointCloud,
                isOn: $visibility.isPointCloudVisible
            )

            Divider()
                .overlay(.white.opacity(0.16))

            layerToggle(
                title: "Cameras",
                detail: CapturePreviewCopy.layerDetail(
                    isAvailable: availability.hasTrajectory
                ),
                systemImage: "camera.fill",
                isAvailable: availability.hasTrajectory,
                isOn: $visibility.areCamerasVisible
            )
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: verticalSizeClass == .compact ? 260 : 310)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
    }

    private func layerToggle(
        title: String,
        detail: String?,
        systemImage: String,
        isAvailable: Bool,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            } icon: {
                Image(systemName: systemImage)
                    .frame(width: 24)
            }
        }
        .tint(Theme.primary)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.52)
        .frame(minHeight: Theme.minimumTapTarget)
        .accessibilityLabel(title)
        .accessibilityHint(detail ?? "")
    }
}

private struct CapturePreviewSceneView: UIViewRepresentable {
    let preview: CapturePreview
    let visibility: CapturePreviewLayerVisibility

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = previewUIColor
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        view.allowsCameraControl = true
        view.scene = makeScene(coordinator: context.coordinator)
        view.pointOfView = context.coordinator.cameraNode
        updateVisibility(context.coordinator)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        updateVisibility(context.coordinator)
    }

    private func updateVisibility(_ coordinator: Coordinator) {
        coordinator.pointCloudNode?.isHidden = !visibility.isPointCloudVisible
        coordinator.camerasNode?.isHidden = !visibility.areCamerasVisible
    }

    private func makeScene(coordinator: Coordinator) -> SCNScene {
        let scene = SCNScene()
        let bounds = PreviewBounds(preview: preview)
        let contentNode = SCNNode()
        contentNode.simdPosition = -bounds.center
        scene.rootNode.addChildNode(contentNode)

        addPointCloud(to: contentNode, coordinator: coordinator)
        addCameras(
            to: contentNode,
            radius: bounds.radius,
            coordinator: coordinator
        )
        let camera = makeCameraNode(radius: bounds.radius)
        coordinator.cameraNode = camera
        scene.rootNode.addChildNode(camera)
        return scene
    }

    private func addPointCloud(
        to contentNode: SCNNode,
        coordinator: Coordinator
    ) {
        guard let pointCloud = preview.pointCloud else { return }
        let node = SCNNode(
            geometry: PreviewGeometry.pointCloud(pointCloud)
        )
        node.renderingOrder = 100
        contentNode.addChildNode(node)
        coordinator.pointCloudNode = node
    }

    private func addCameras(
        to contentNode: SCNNode,
        radius: Float,
        coordinator: Coordinator
    ) {
        guard let trajectory = preview.trajectory else { return }
        let node = PreviewGeometry.cameras(
            trajectory,
            radius: radius
        )
        contentNode.addChildNode(node)
        coordinator.camerasNode = node
    }

    private func makeCameraNode(radius: Float) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.zNear = Double(max(0.001, radius * 0.005))
        camera.zFar = Double(max(20, radius * 10))

        let node = SCNNode()
        node.camera = camera
        // Distance ≈ 1.95 × radius: the closest framing that still fits the
        // whole bounding sphere in the 55° vertical FOV (r / tan 27.5° ≈
        // 1.92 r), so the capture fills the viewport instead of floating
        // small in the middle.
        node.simdPosition = SIMD3<Float>(
            radius * 0.60,
            radius * 0.49,
            radius * 1.79
        )
        node.look(at: SCNVector3Zero)
        return node
    }

    final class Coordinator {
        var cameraNode: SCNNode?
        var pointCloudNode: SCNNode?
        var camerasNode: SCNNode?
    }
}

enum PreviewGeometry {
    static let cameraPathNodeName = "camera-path"
    static let cameraFrustumNodeName = "camera-frustum"

    static let cameraBlue = UIColor(
        red: 0,
        green: 0.65,
        blue: 1,
        alpha: 1
    )

    static func pointCloud(_ pointCloud: CapturePointCloud) -> SCNGeometry {
        let positions = pointCloud.positions
        let colors = pointCloud.hasSceneColors
            ? sceneColors(pointCloud)
            : depthColors(pointCloud)
        let indices = (0..<positions.count).map(UInt32.init)
        let element = SCNGeometryElement(
            data: indices.withUnsafeBufferPointer { Data(buffer: $0) },
            primitiveType: .point,
            primitiveCount: positions.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        element.pointSize = pointCloud.source == .trackingFeatures
            ? 0.009
            : 0.006
        element.minimumPointScreenSpaceRadius = pointCloud.source
            == .trackingFeatures ? 2 : 1.5
        element.maximumPointScreenSpaceRadius = 4

        let geometry = SCNGeometry(
            sources: [
                source(positions, semantic: .vertex, componentsPerVector: 3),
                source(colors, semantic: .color, componentsPerVector: 4),
            ],
            elements: [element]
        )
        geometry.materials = [pointMaterial()]
        return geometry
    }

    static func cameras(
        _ trajectory: CaptureTrajectory,
        radius: Float
    ) -> SCNNode {
        let plan = CaptureTrajectoryRenderPlan.make(
            trajectory: trajectory,
            sceneRadiusM: radius
        )
        let layerNode = SCNNode()
        guard !plan.pathPositions.isEmpty else { return layerNode }

        if plan.pathPositions.count > 1 {
            let pathNode = SCNNode(
                geometry: pathGeometry(
                    plan.pathPositions,
                    radius: plan.style.pathRadiusM
                )
            )
            pathNode.name = cameraPathNodeName
            pathNode.renderingOrder = 200
            layerNode.addChildNode(pathNode)
        }

        addFrustums(
            plan.frustumTransforms,
            style: plan.style,
            to: layerNode
        )
        return layerNode
    }

    private static func depthColors(
        _ pointCloud: CapturePointCloud
    ) -> [SIMD4<Float>] {
        let distances = pointCloud.distancesFromCaptureOriginM.filter {
            $0.isFinite && $0 >= 0
        }
        let nearDistanceM = distances.min() ?? 0
        let farDistanceM = distances.max() ?? nearDistanceM
        let spanM = max(0.001, farDistanceM - nearDistanceM)
        let nearColor = SIMD4<Float>(0.18, 0.82, 1, 1)
        let farColor = SIMD4<Float>(0.67, 0.36, 0.95, 1)

        return pointCloud.distancesFromCaptureOriginM.map { distanceM in
            let depth = min(1, max(0, (distanceM - nearDistanceM) / spanM))
            return simd_mix(
                nearColor,
                farColor,
                SIMD4<Float>(repeating: depth)
            )
        }
    }

    private static func sceneColors(
        _ pointCloud: CapturePointCloud
    ) -> [SIMD4<Float>] {
        guard let colorsRGB = pointCloud.colorsRGB else {
            return depthColors(pointCloud)
        }
        return colorsRGB.map { color in
            SIMD4(
                Float(color.x) / 255,
                Float(color.y) / 255,
                Float(color.z) / 255,
                1
            )
        }
    }

    private static func pathGeometry(
        _ positions: [SIMD3<Float>],
        radius: Float
    ) -> SCNGeometry {
        let segments = (1..<positions.count).map { index in
            LineSegment(
                start: positions[index - 1],
                end: positions[index]
            )
        }
        return tubeGeometry(
            segments: segments,
            radius: radius,
            name: cameraPathNodeName
        )
    }

    private static func addFrustums(
        _ transforms: [simd_float4x4],
        style: CaptureTrajectoryRenderStyle,
        to layerNode: SCNNode
    ) {
        let geometry = frustumGeometry(style: style)
        for transform in transforms {
            let node = SCNNode(geometry: geometry)
            node.name = cameraFrustumNodeName
            node.simdTransform = transform
            node.renderingOrder = 210
            layerNode.addChildNode(node)
        }
    }

    private static func frustumGeometry(
        style: CaptureTrajectoryRenderStyle
    ) -> SCNGeometry {
        let depth = style.frustumDepthM
        let halfWidth = depth * 0.75
        let halfHeight = depth * 0.5625
        let positions = [
            SIMD3<Float>(0, 0, 0),
            SIMD3(-halfWidth, halfHeight, -depth),
            SIMD3(halfWidth, halfHeight, -depth),
            SIMD3(halfWidth, -halfHeight, -depth),
            SIMD3(-halfWidth, -halfHeight, -depth),
            SIMD3<Float>(0, 0, -depth * 1.55),
        ]
        let segmentIndices = [
            (0, 1), (0, 2), (0, 3), (0, 4),
            (1, 2), (2, 3), (3, 4), (4, 1),
            (0, 5),
        ]
        return tubeGeometry(
            segments: segmentIndices.map { indices in
                LineSegment(
                    start: positions[indices.0],
                    end: positions[indices.1]
                )
            },
            radius: style.frustumStrokeRadiusM,
            name: cameraFrustumNodeName
        )
    }

    private static func tubeGeometry(
        segments: [LineSegment],
        radius: Float,
        name: String
    ) -> SCNGeometry {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(segments.count * 8)
        indices.reserveCapacity(segments.count * 36)

        for segment in segments {
            appendTube(
                for: segment,
                radius: radius,
                vertices: &vertices,
                indices: &indices
            )
        }

        let geometry = SCNGeometry(
            sources: [
                source(
                    vertices,
                    semantic: .vertex,
                    componentsPerVector: 3
                )
            ],
            elements: [triangleElement(indices)]
        )
        geometry.name = name
        geometry.materials = [constantMaterial(color: cameraBlue)]
        return geometry
    }

    private static func appendTube(
        for segment: LineSegment,
        radius: Float,
        vertices: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) {
        let delta = segment.end - segment.start
        let length = simd_length(delta)
        guard length > 0.000_001 else { return }

        let direction = delta / length
        let reference = abs(direction.y) < 0.9
            ? SIMD3<Float>(0, 1, 0)
            : SIMD3<Float>(1, 0, 0)
        let normal = simd_normalize(simd_cross(direction, reference))
        let binormal = simd_normalize(simd_cross(direction, normal))
        let offsets = [
            normal * radius,
            binormal * radius,
            -normal * radius,
            -binormal * radius,
        ]
        let baseIndex = UInt32(vertices.count)
        vertices.append(contentsOf: offsets.map { segment.start + $0 })
        vertices.append(contentsOf: offsets.map { segment.end + $0 })

        for side in 0..<4 {
            let next = (side + 1) % 4
            let start = baseIndex + UInt32(side)
            let startNext = baseIndex + UInt32(next)
            let end = baseIndex + 4 + UInt32(side)
            let endNext = baseIndex + 4 + UInt32(next)
            indices.append(contentsOf: [
                start, end, startNext,
                startNext, end, endNext,
            ])
        }
        indices.append(contentsOf: [
            baseIndex, baseIndex + 2, baseIndex + 1,
            baseIndex, baseIndex + 3, baseIndex + 2,
            baseIndex + 4, baseIndex + 5, baseIndex + 6,
            baseIndex + 4, baseIndex + 6, baseIndex + 7,
        ])
    }

    private static func source<Value>(
        _ values: [Value],
        semantic: SCNGeometrySource.Semantic,
        componentsPerVector: Int
    ) -> SCNGeometrySource {
        SCNGeometrySource(
            data: values.withUnsafeBufferPointer { Data(buffer: $0) },
            semantic: semantic,
            vectorCount: values.count,
            usesFloatComponents: true,
            componentsPerVector: componentsPerVector,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Value>.stride
        )
    }

    private static func triangleElement(
        _ indices: [UInt32]
    ) -> SCNGeometryElement {
        SCNGeometryElement(
            data: indices.withUnsafeBufferPointer { Data(buffer: $0) },
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
    }

    private static func constantMaterial(color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        return material
    }

    private static func pointMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = true
        return material
    }

    private struct LineSegment {
        let start: SIMD3<Float>
        let end: SIMD3<Float>
    }
}

private struct PreviewBounds {
    let center: SIMD3<Float>
    let radius: Float

    init(preview: CapturePreview) {
        var points = preview.pointCloud?.positions ?? []
        if let trajectory = preview.trajectory {
            points.append(contentsOf: trajectory.cameraPositions)
        }
        guard var minimum = points.first else {
            center = .zero
            radius = 1
            return
        }
        var maximum = minimum
        for point in points.dropFirst() {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        center = (minimum + maximum) * 0.5
        radius = max(0.25, simd_length(maximum - minimum) * 0.5)
    }
}

private var previewBackground: some View {
    Color(red: 0.02, green: 0.04, blue: 0.055)
        .ignoresSafeArea()
}

private let previewUIColor = UIColor(
    red: 0.02,
    green: 0.04,
    blue: 0.055,
    alpha: 1
)
