import Foundation
import ARKit
import SceneKit

/// Kapsel für den ARKit-LiDAR-Scan und USDZ-Export.
/// Reine Service-Schicht – kein UI, kein State-Management.
@MainActor
final class ARMeshScannerService: NSObject {

    // MARK: - Public Properties

    let sceneView = ARSCNView(frame: .zero)

    /// Anzahl der aktuell erkannten Mesh-Anker (für Qualitätsanzeige im ViewModel)
    private(set) var meshAnchorCount: Int = 0

    // MARK: - Init

    override init() {
        super.init()
        sceneView.session.delegate = self
        sceneView.showsStatistics = false
        sceneView.automaticallyUpdatesLighting = true

    }

    // MARK: - Scanning

    func startScan() {
        meshAnchorCount = 0
        let config = ARWorldTrackingConfiguration()

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pauseScan() {
        sceneView.session.pause()
    }

    // MARK: - Export

    /// Pausiert die Session und exportiert die Szene als .usdz-Datei.
    ///
    /// NOTE: Exportiert rohes LiDAR-Gitter ohne Texturen.
    /// Für fotorealistischen Export: PhotogrammetrySession oder Metal-Shader
    /// für die Projektion des ARCamera-Feeds auf die Mesh-Nodes verwenden.
    func exportToUSDZ() async throws -> URL {
        sceneView.session.pause()

        guard let documentsDir = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw ExportError.documentsDirectoryUnavailable
        }

        let fileName = "Cosmic-Scan-\(UUID().uuidString.prefix(8)).usdz"
        let fileURL = documentsDir.appendingPathComponent(fileName)

        return try await withCheckedThrowingContinuation { continuation in
            sceneView.scene.write(
                to: fileURL,
                options: nil,
                delegate: nil
            ) { totalProgress, error, _ in
                if let error {
                    continuation.resume(throwing: ExportError.writeFailed(error.localizedDescription))
                } else if totalProgress == 1.0 {
                    continuation.resume(returning: fileURL)
                }
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension ARMeshScannerService: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let meshCount = anchors.filter { $0 is ARMeshAnchor }.count
        guard meshCount > 0 else { return }
        Task { @MainActor in
            self.meshAnchorCount += meshCount
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {}

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            print("ARSession Fehler: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum ExportError: LocalizedError {
    case documentsDirectoryUnavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "Dokumente-Ordner nicht verfügbar."
        case .writeFailed(let reason):
            return "Export fehlgeschlagen: \(reason)"
        }
    }
}
