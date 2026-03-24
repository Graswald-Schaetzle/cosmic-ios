import Foundation
import ARKit
import SceneKit
import Combine

@MainActor
class ARMeshScannerService: NSObject, ObservableObject, ARSessionDelegate {
    static let shared = ARMeshScannerService()
    
    let sceneView = ARSCNView(frame: .zero)
    @Published var isScanning = false
    @Published var exportUrl: URL?
    
    override private init() {
        super.init()
        sceneView.session.delegate = self
    }
    
    func start() {
        let config = ARWorldTrackingConfiguration()
        
        // Aktiviere das echte Raum-Gitter (LiDAR Mesh)
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
        exportUrl = nil
    }
    
    func stopAndExport() {
        sceneView.session.pause()
        isScanning = false
        
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileName = "LiDAR-Mesh-\(UUID().uuidString.prefix(8)).usdz"
        let fileURL = documentsDirectory.appendingPathComponent(fileName)
        
        sceneView.scene.write(to: fileURL, options: nil, delegate: nil) { (totalProgress, error, stop) in
            DispatchQueue.main.async {
                if let error = error {
                    print("Mesh Export Error: \(error.localizedDescription)")
                } else if totalProgress == 1.0 {
                    self.exportUrl = fileURL
                    print("Successfully exported LiDAR Mesh to \(fileURL.path)")
                }
            }
        }
    }
}
