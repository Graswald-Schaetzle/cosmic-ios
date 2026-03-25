import Foundation
import UIKit
import RoomPlan

/// RoomPlan-basierte Service-Schicht für den strukturierten Raumscan.
/// Kapselt RoomCaptureSession und USDZ-Export – kein UI, kein State-Management.
@MainActor
final class ARTrackingService: NSObject {

    // MARK: - Availability

    /// Gibt an, ob das Gerät LiDAR und RoomPlan unterstützt (iPhone 12 Pro+, iPad Pro 2020+).
    static var isSupported: Bool { RoomCaptureSession.isSupported }

    // MARK: - Public Properties

    let roomCaptureView = RoomCaptureView(frame: .zero)

    /// Anzahl erkannter Raumelemente (Wände, Böden, Objekte, Türen, Fenster) für Qualitätsanzeige.
    private(set) var detectedElementCount: Int = 0

    // MARK: - Private

    private var stopContinuation: CheckedContinuation<CapturedRoomData, Error>?

    // MARK: - Init

    override init() {
        super.init()
        roomCaptureView.captureSession.delegate = self
    }

    // MARK: - Scanning

    func startScan() {
        detectedElementCount = 0
        let config = RoomCaptureSession.Configuration()
        roomCaptureView.captureSession.run(configuration: config)
    }

    /// Stoppt die Session und liefert die rohen Raumdaten via async/await zurück.
    func stopAndGetData() async throws -> CapturedRoomData {
        return try await withCheckedThrowingContinuation { continuation in
            self.stopContinuation = continuation
            roomCaptureView.captureSession.stop(pauseARSession: true)
        }
    }

    // MARK: - Export

    /// Verarbeitet CapturedRoomData mit RoomBuilder, exportiert als .usdz
    /// und gibt gleichzeitig den strukturierten CapturedRoom zurück
    /// (für Objekterkennung / Spatial Upload – kein doppelter Build-Aufruf).
    func exportToUSDZ(from roomData: CapturedRoomData) async throws -> (fileURL: URL, capturedRoom: CapturedRoom) {
        let builder = RoomBuilder(options: [.beautifyObjects])

        // RoomBuilder kann bei leerem Scan unbegrenzt hängen → 30s Timeout.
        let capturedRoom: CapturedRoom = try await withThrowingTaskGroup(of: CapturedRoom.self) { group in
            group.addTask { try await builder.capturedRoom(from: roomData) }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 Sekunden
                throw ExportError.buildTimeout
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }

        guard let documentsDir = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw ExportError.documentsDirectoryUnavailable
        }

        let fileName = "Cosmic-Scan-\(UUID().uuidString.prefix(8)).usdz"
        let fileURL = documentsDir.appendingPathComponent(fileName)
        try capturedRoom.export(to: fileURL)
        return (fileURL, capturedRoom)
    }
}

// MARK: - RoomCaptureSessionDelegate

extension ARTrackingService: RoomCaptureSessionDelegate {

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let count = room.walls.count + room.floors.count + room.objects.count
            + room.doors.count + room.windows.count
        Task { @MainActor in
            self.detectedElementCount = count
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
            if let error {
                self.stopContinuation?.resume(throwing: error)
            } else {
                self.stopContinuation?.resume(returning: data)
            }
            self.stopContinuation = nil
        }
    }
}

// MARK: - Errors

enum ExportError: LocalizedError {
    case documentsDirectoryUnavailable
    case writeFailed(String)
    case buildTimeout

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "Dokumente-Ordner nicht verfügbar."
        case .writeFailed(let reason):
            return "Export fehlgeschlagen: \(reason)"
        case .buildTimeout:
            return "Export-Timeout: Bitte länger scannen (mind. 10 Sekunden) damit RoomPlan genug Daten sammeln kann."
        }
    }
}
