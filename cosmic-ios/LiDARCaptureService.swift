import Foundation
import ARKit
import Combine
import CoreImage
import UIKit

/// Piggybacks on RoomPlan's ARSession to simultaneously capture raw LiDAR frames,
/// camera poses (in Nerfstudio format), and mesh anchors for live visualization.
/// Attach after calling RoomCaptureSession.run() so the ARSession is active.
final class LiDARCaptureService: NSObject {

    // MARK: - Public

    /// Publishes batches of updated mesh anchors for live wireframe visualization.
    /// Throttle externally (e.g. to 10 Hz) before rendering.
    let meshSubject = PassthroughSubject<[ARMeshAnchor], Never>()

    /// Number of frames captured so far (updated on main queue).
    private(set) var capturedFrameCount: Int = 0

    // MARK: - Private: Configuration

    /// Capture one frame every N ARKit frames.
    /// At 30Hz ARKit: interval=15 → ~2 fps. At 60Hz: interval=15 → ~4 fps.
    private let frameInterval = 15

    /// Minimum camera translation (metres) since last capture to accept a new frame.
    private let minTranslation: Float = 0.03     // 3 cm

    /// Minimum camera rotation (radians) since last capture to accept a new frame.
    private let minRotation: Float = 0.052       // ~3 degrees

    // MARK: - Private: State

    private let captureQueue = DispatchQueue(label: "com.cosmic.lidar.capture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private weak var arSession: ARSession?
    private var scanDirectory: URL?
    private var framesDirectory: URL?

    // Frame-rate counters (accessed only from ARKit delegate queue)
    private var frameCounter: Int = 0
    private var capturedIndex: Int = 0
    private var lastCapturePose: simd_float4x4?

    /// Accumulated frame records — appended on captureQueue, read after session stops.
    private var frameRecords: [FrameRecord] = []

    private struct FrameRecord {
        let filename: String
        let matrix: [[Float]]
        let flX: Float
        let flY: Float
        let cx: Float
        let cy: Float
        let width: Int
        let height: Int
    }

    // MARK: - Lifecycle

    /// Start capturing frames from the given ARSession.
    /// Call this immediately after RoomCaptureSession.run() so the session is running.
    /// - Parameters:
    ///   - arSession: The ARSession exposed by RoomCaptureSession.arSession.
    ///   - scanId: Unique identifier for this scan; used to create the output directory.
    func startCapture(arSession: ARSession, scanId: String) {
        guard let docsDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return }

        let dir = docsDir.appendingPathComponent("scans/\(scanId)", isDirectory: true)
        let framesDir = dir.appendingPathComponent("frames", isDirectory: true)

        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        scanDirectory   = dir
        framesDirectory = framesDir
        frameCounter    = 0
        capturedIndex   = 0
        lastCapturePose = nil
        frameRecords    = []
        capturedFrameCount = 0

        self.arSession = arSession
        arSession.delegate = self
    }

    /// Stops frame capture, writes transforms.json, and returns the scan directory URL.
    /// Call AFTER the RoomCaptureSession has been stopped (so no more ARKit callbacks arrive).
    func stopAndFinalize() async throws -> URL {
        arSession?.delegate = nil

        // Drain the capture queue so all pending frame I/O and record appends finish.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            captureQueue.async { continuation.resume() }
        }

        guard let scanDir = scanDirectory else { throw LiDARError.notStarted }
        guard !frameRecords.isEmpty else { throw LiDARError.noFramesCaptured }

        try writeTransformsJSON(to: scanDir)
        return scanDir
    }

    /// The scan directory path (set after startCapture, nil before).
    var currentScanDirectory: URL? { scanDirectory }

    // MARK: - transforms.json

    private func writeTransformsJSON(to directory: URL) throws {
        guard let first = frameRecords.first else { return }

        var frameArray: [[String: Any]] = []
        frameArray.reserveCapacity(frameRecords.count)

        for record in frameRecords {
            frameArray.append([
                "file_path": record.filename,
                "transform_matrix": record.matrix as [[Any]]
            ])
        }

        let json: [String: Any] = [
            "camera_model": "OPENCV",
            "fl_x": Double(first.flX),
            "fl_y": Double(first.flY),
            "cx":   Double(first.cx),
            "cy":   Double(first.cy),
            "w":    first.width,
            "h":    first.height,
            "k1": 0.0, "k2": 0.0, "p1": 0.0, "p2": 0.0,
            "frames": frameArray
        ]

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let url  = directory.appendingPathComponent("transforms.json")
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Frame Capture Helpers

    /// Returns true and advances state if this ARFrame should be captured.
    /// Called exclusively on the ARKit delegate queue (serial).
    private func shouldCapture(_ frame: ARFrame) -> Bool {
        frameCounter += 1
        guard frameCounter % frameInterval == 0 else { return false }

        let pose = frame.camera.transform

        if let last = lastCapturePose {
            let dt = simd_float3(
                pose.columns.3.x - last.columns.3.x,
                pose.columns.3.y - last.columns.3.y,
                pose.columns.3.z - last.columns.3.z
            )
            let dist = simd_length(dt)

            // Approximate angle between rotations via trace of relative rotation
            let rel   = simd_mul(simd_inverse(last), pose)
            let trace = rel.columns.0.x + rel.columns.1.y + rel.columns.2.z
            let angle = acos(max(-1, min(1, (trace - 1) / 2)))

            guard dist >= minTranslation || angle >= minRotation else { return false }
        }

        return true
    }

    /// Captures a single ARFrame: writes JPEG to disk and records the camera pose.
    /// Called on the ARKit delegate queue; I/O dispatched to captureQueue.
    private func captureFrame(_ frame: ARFrame) {
        let localIndex      = capturedIndex
        capturedIndex      += 1
        lastCapturePose     = frame.camera.transform

        let pixelBuffer = frame.capturedImage
        let pose        = frame.camera.transform
        let K           = frame.camera.intrinsics
        let res         = frame.camera.imageResolution

        // Transform from ARKit (camera looks -Z, Y-up, right-handed)
        // to Nerfstudio OpenGL convention (camera looks +Z, Y-down).
        // Flip Y and Z axis vectors of the camera-to-world matrix.
        var m = pose
        m.columns.1 = -m.columns.1
        m.columns.2 = -m.columns.2

        // Row-major 4×4 for JSON:  row[i] = [col0[i], col1[i], col2[i], col3[i]]
        let matrix: [[Float]] = [
            [m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x],
            [m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y],
            [m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z],
            [0, 0, 0, 1]
        ]

        let record = FrameRecord(
            filename: "frames/frame_\(String(format: "%05d", localIndex)).jpg",
            matrix:   matrix,
            flX:      K.columns.0.x,
            flY:      K.columns.1.y,
            cx:       K.columns.2.x,
            cy:       K.columns.2.y,
            width:    Int(res.width),
            height:   Int(res.height)
        )

        captureQueue.async { [weak self] in
            guard let self, let framesDir = self.framesDirectory else { return }

            let ciImage  = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent),
                  let jpeg    = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
            else { return }

            let fileURL = framesDir.appendingPathComponent(
                "frame_\(String(format: "%05d", localIndex)).jpg"
            )
            try? jpeg.write(to: fileURL, options: .atomic)

            self.frameRecords.append(record)

            DispatchQueue.main.async { [weak self] in
                self?.capturedFrameCount += 1
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension LiDARCaptureService: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard shouldCapture(frame) else { return }
        captureFrame(frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }
        meshSubject.send(meshAnchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }
        meshSubject.send(meshAnchors)
    }
}

// MARK: - Errors

enum LiDARError: LocalizedError {
    case notStarted
    case noFramesCaptured

    var errorDescription: String? {
        switch self {
        case .notStarted:        return "LiDAR-Capture wurde nicht gestartet."
        case .noFramesCaptured:  return "Keine Frames aufgezeichnet – bitte langsamer scannen."
        }
    }
}
