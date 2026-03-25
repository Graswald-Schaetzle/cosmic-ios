import ARKit

/// Leitet ARSessionDelegate-Callbacks an zwei Delegates weiter –
/// so kann LiDARCaptureService RoomPlan's ARSession mitbenutzen,
/// ohne dessen internen Delegate zu überschreiben (was die Kamera-Preview bricht).
final class ARSessionDelegateMultiplexer: NSObject, ARSessionDelegate {

    /// RoomPlan's interner Delegate (schwache Referenz damit kein Retain-Cycle entsteht).
    weak var primary: ARSessionDelegate?

    /// LiDARCaptureService (schwache Referenz).
    weak var secondary: ARSessionDelegate?

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        primary?.session?(session, didUpdate: frame)
        secondary?.session?(session, didUpdate: frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        primary?.session?(session, didAdd: anchors)
        secondary?.session?(session, didAdd: anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        primary?.session?(session, didUpdate: anchors)
        secondary?.session?(session, didUpdate: anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        primary?.session?(session, didRemove: anchors)
        secondary?.session?(session, didRemove: anchors)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        primary?.session?(session, cameraDidChangeTrackingState: camera)
        secondary?.session?(session, cameraDidChangeTrackingState: camera)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        primary?.sessionWasInterrupted?(session)
        secondary?.sessionWasInterrupted?(session)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        primary?.sessionInterruptionEnded?(session)
        secondary?.sessionInterruptionEnded?(session)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        primary?.session?(session, didFailWithError: error)
        secondary?.session?(session, didFailWithError: error)
    }
}
