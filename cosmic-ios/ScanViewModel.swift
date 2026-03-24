import Foundation
import RoomPlan
import Combine
import SwiftData

/// Präsentationslogik und State-Management für den Scan-Flow.
/// Koordiniert ARTrackingService, LiDARCaptureService, UploadService und ReconstructionJobService.
@MainActor
final class ScanViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isScanning: Bool = false
    @Published private(set) var isExporting: Bool = false
    @Published private(set) var isUploading: Bool = false
    @Published private(set) var exportedFileURL: URL?
    @Published private(set) var uploadProgress: Double = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var detectedElementCount: Int = 0
    @Published private(set) var scanDuration: TimeInterval = 0
    @Published private(set) var lidarFrameCount: Int = 0

    // MARK: - Dependencies

    private let scanner       = ARTrackingService()
    private let lidarService  = LiDARCaptureService()
    private let uploader      = UploadService.shared
    private let spatialUploader = SpatialUploadService.shared
    private let reconstructionService = ReconstructionJobService.shared

    /// RoomCaptureView nach oben durchreichen, damit die View es einbetten kann.
    var roomCaptureView: RoomCaptureView { scanner.roomCaptureView }

    /// Mesh-Publisher for live wireframe visualization.
    var meshPublisher: PassthroughSubject<[ARMeshAnchor], Never> { lidarService.meshSubject }

    // MARK: - Private

    private var scanTimer: Timer?
    private var uploaderCancellable: AnyCancellable?
    private var lidarFrameCancellable: AnyCancellable?
    private var currentScanRecord: ScanRecord?
    private var lastCapturedRoom: CapturedRoom?
    private var currentScanId: String?
    private var currentScanDirectory: URL?
    private var lastUploadResult: UploadResult?

    // MARK: - Init

    init() {
        uploaderCancellable = uploader.$uploadProgress
            .receive(on: RunLoop.main)
            .assign(to: \.uploadProgress, on: self)
    }

    // MARK: - Actions

    func startScan() {
        exportedFileURL    = nil
        errorMessage       = nil
        detectedElementCount = 0
        scanDuration       = 0
        lidarFrameCount    = 0
        currentScanRecord  = nil
        currentScanId      = nil
        currentScanDirectory = nil
        lastUploadResult   = nil
        isScanning         = true

        let scanId = UUID().uuidString
        currentScanId = scanId

        scanner.startScan()

        // Attach LiDAR capture to the same ARSession that RoomPlan is using
        lidarService.startCapture(
            arSession: scanner.roomCaptureView.captureSession.arSession,
            scanId: scanId
        )

        startTimer()
    }

    func stopAndExport(modelContext: ModelContext) async {
        guard isScanning else { return }
        stopTimer()
        isScanning  = false
        isExporting = true
        errorMessage = nil
        lastCapturedRoom = nil

        do {
            // Stop RoomPlan and get structured data
            let roomData = try await scanner.stopAndGetData()
            let (url, capturedRoom) = try await scanner.exportToUSDZ(from: roomData)
            exportedFileURL  = url
            lastCapturedRoom = capturedRoom

            let scanName = "Raum \(formattedDate())"
            let record   = ScanRecord(name: scanName, localFileURL: url)
            modelContext.insert(record)
            currentScanRecord = record

            // Finalize LiDAR capture (writes transforms.json, drains queue)
            do {
                let scanDir = try await lidarService.stopAndFinalize()
                currentScanDirectory = scanDir
                lidarFrameCount = lidarService.capturedFrameCount
            } catch {
                // LiDAR finalization failure is non-critical — USDZ export already succeeded.
                // The reconstruction job simply won't be submitted.
                print("LiDAR-Finalisierung fehlgeschlagen (nicht kritisch): \(error.localizedDescription)")
            }

        } catch {
            errorMessage = error.localizedDescription
        }

        isExporting = false
    }

    func uploadScan() async {
        guard let fileURL = exportedFileURL else {
            errorMessage = "Keine Datei zum Hochladen vorhanden."
            return
        }

        isUploading   = true
        uploadProgress = 0
        errorMessage  = nil

        let spaceName = currentScanRecord?.name ?? "Raum \(formattedDate())"

        do {
            // Upload USDZ model
            let result = try await uploader.uploadScan(fileURL: fileURL, spaceName: spaceName)
            lastUploadResult = result
            print("USDZ-Upload erfolgreich: \(result.modelUrl)")
            currentScanRecord?.remoteURL  = result.modelUrl
            currentScanRecord?.isUploaded = true

            // Upload spatial objects (RoomPlan semantic data)
            if let capturedRoom = lastCapturedRoom, let spaceId = Int(result.space.id) {
                do {
                    let spatialResult = try await spatialUploader.upload(
                        capturedRoom: capturedRoom,
                        spaceId: spaceId
                    )
                    if let data = spatialResult.data {
                        print("Spatial-Upload: \(data.objectsCount) Objekte, \(data.surfacesCount) Flächen")
                    }
                } catch {
                    print("Spatial-Upload fehlgeschlagen (nicht kritisch): \(error.localizedDescription)")
                }
                lastCapturedRoom = nil
            }

            // Submit LiDAR reconstruction job (ARKit frames + poses → Gaussian Splatting)
            if let scanDir = currentScanDirectory, let spaceId = Int(result.space.id) {
                await submitReconstructionJob(scanDirectory: scanDir, spaceId: spaceId, spaceName: spaceName)
            }

        } catch {
            errorMessage = error.localizedDescription
        }

        isUploading = false
    }

    /// Pausiert eine laufende Session beim Verlassen der View.
    func pauseIfNeeded() {
        guard isScanning else { return }
        scanner.roomCaptureView.captureSession.stop(pauseARSession: true)
        isScanning = false
        stopTimer()
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Reconstruction Job

    private func submitReconstructionJob(
        scanDirectory: URL,
        spaceId: Int,
        spaceName: String
    ) async {
        guard lidarService.capturedFrameCount > 0 else {
            print("Reconstruction-Job übersprungen: Keine LiDAR-Frames.")
            return
        }

        do {
            // Package frames + transforms.json into a ZIP
            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let zipURL  = docsDir.appendingPathComponent("reconstruction_\(spaceId)_\(Int(Date().timeIntervalSince1970)).zip")

            print("ZIP wird erstellt: \(lidarService.capturedFrameCount) Frames …")
            let _ = try await ScanPackager.createZip(scanDirectory: scanDirectory, outputURL: zipURL)

            let zipSizeMB = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int).map {
                String(format: "%.1f MB", Double($0) / 1_000_000)
            } ?? "?"
            print("ZIP erstellt: \(zipSizeMB)")

            // Submit: create job → upload → start GPU worker
            let job = try await reconstructionService.submitScan(
                spaceId: spaceId,
                title: "\(spaceName) – LiDAR",
                zipURL: zipURL
            )
            print("Reconstruction-Job gestartet: job_id=\(job.jobId), status=\(job.status)")

            // Clean up local zip (frames stay until next scan to allow retry)
            try? FileManager.default.removeItem(at: zipURL)

        } catch {
            // Reconstruction job failure is non-critical — the USDZ/spatial upload already succeeded.
            print("Reconstruction-Job fehlgeschlagen (nicht kritisch): \(error.localizedDescription)")
        }
    }

    // MARK: - Timer

    private func startTimer() {
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scanDuration       += 1
                self?.detectedElementCount = self?.scanner.detectedElementCount ?? 0
                self?.lidarFrameCount     = self?.lidarService.capturedFrameCount ?? 0
            }
        }
    }

    private func stopTimer() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    // MARK: - Helpers

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: Date())
    }
}
