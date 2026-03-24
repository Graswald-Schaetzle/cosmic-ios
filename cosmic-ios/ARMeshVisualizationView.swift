import SwiftUI
import SceneKit
import ARKit
import Combine

/// Transparent SceneKit overlay that renders live ARMeshAnchor wireframes
/// over the RoomCaptureView — replicating the Polycam scanning wireframe aesthetic.
/// Place in a ZStack above the RoomCaptureViewRepresentable with allowsHitTesting(false).
struct ARMeshVisualizationView: UIViewRepresentable {

    let meshPublisher: PassthroughSubject<[ARMeshAnchor], Never>

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque        = false
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = false

        let scene = SCNScene()
        scene.background.contents  = UIColor.clear
        view.scene = scene

        // Orthographic-like camera that covers the full screen at Z=0
        // The actual mesh nodes carry their own world transforms from ARKit.
        let cameraNode        = SCNNode()
        cameraNode.name       = "camera"
        cameraNode.camera     = SCNCamera()
        cameraNode.position   = SCNVector3(0, 0, 10)
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        context.coordinator.scnView = view
        context.coordinator.subscribe(to: meshPublisher)

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator {
        weak var scnView: SCNView?
        private var cancellable: AnyCancellable?
        /// Maps anchor UUID → SCNNode so we update existing nodes instead of recreating.
        private var anchorNodes: [UUID: SCNNode] = [:]

        func subscribe(to publisher: PassthroughSubject<[ARMeshAnchor], Never>) {
            cancellable = publisher
                .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] anchors in
                    self?.updateMesh(anchors: anchors)
                }
        }

        private func updateMesh(anchors: [ARMeshAnchor]) {
            guard let scene = scnView?.scene else { return }

            for anchor in anchors {
                let geometry = makeGeometry(from: anchor)
                let transform = SCNMatrix4(anchor.transform)

                if let existing = anchorNodes[anchor.identifier] {
                    existing.geometry  = geometry
                    existing.transform = transform
                } else {
                    let node        = SCNNode(geometry: geometry)
                    node.transform  = transform
                    node.name       = anchor.identifier.uuidString
                    scene.rootNode.addChildNode(node)
                    anchorNodes[anchor.identifier] = node
                }
            }

            scnView?.setNeedsDisplay()
        }

        private func makeGeometry(from anchor: ARMeshAnchor) -> SCNGeometry {
            let mesh = anchor.geometry

            // Vertex source
            let vertexSource = SCNGeometrySource(
                buffer:            mesh.vertices.buffer,
                vertexFormat:      .float3,
                semantic:          .vertex,
                vertexCount:       mesh.vertices.count,
                dataOffset:        mesh.vertices.offset,
                dataStride:        mesh.vertices.stride
            )

            // Face element (triangles)
            let faceElement = SCNGeometryElement(
                buffer:           mesh.faces.buffer,
                primitiveType:    .triangles,
                primitiveCount:   mesh.faces.count,
                bytesPerIndex:    mesh.faces.bytesPerIndex
            )

            let geometry            = SCNGeometry(sources: [vertexSource], elements: [faceElement])
            geometry.materials      = [wireMaterial()]
            return geometry
        }

        private func wireMaterial() -> SCNMaterial {
            let mat               = SCNMaterial()
            mat.fillMode          = .lines
            mat.diffuse.contents  = UIColor.cyan.withAlphaComponent(0.55)
            mat.isDoubleSided     = true
            mat.lightingModel     = .constant   // no lighting calculation needed for wireframe
            return mat
        }
    }
}
