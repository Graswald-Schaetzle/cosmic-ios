import ARKit
import SceneKit
import SwiftUI

/// Shows the coordinator's `ARSession` camera feed. Display only: the view
/// never runs, pauses, or reconfigures the session.
struct CaptureCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        // Attach on the next run-loop turn: assigning the session while
        // SwiftUI is still building the view hierarchy can drop the first
        // camera texture and leave a black preview.
        DispatchQueue.main.async { [weak view] in
            view?.session = session
        }
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
