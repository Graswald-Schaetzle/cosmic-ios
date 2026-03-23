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
        // Visualisiert das LiDAR-Mesh, während der User den Raum scannt
        sceneView.debugOptions = [.showSceneUnderstanding]
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
        
        // Speicherort für das fertige 3D-Modell definieren
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileName = "LiDAR-Mesh-\(UUID().uuidString.prefix(8)).usdz"
        let fileURL = documentsDirectory.appendingPathComponent(fileName)
        
        // AI AGENT NOTE: This exports the raw LiDAR geometry to USDZ. 
        // For full photorealism (textures), custom Metal shaders projecting the ARCamera feed 
        // onto these nodes must be added, OR you must switch to PhotogrammetrySession 
        // to process captured images into a textured mesh asynchronously.
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
