import Foundation
import ARKit
import Combine
import SwiftData

/// Präsentationslogik und State-Management für den Scan-Flow.
/// Koordiniert ARMeshScannerService und UploadService.
@MainActor
final class ScanViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isScanning: Bool = false
    @Published private(set) var isExporting: Bool = false
    @Published private(set) var isUploading: Bool = false
    @Published private(set) var exportedFileURL: URL?
    @Published private(set) var uploadProgress: Double = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var meshAnchorCount: Int = 0
    @Published private(set) var scanDuration: TimeInterval = 0

    // MARK: - Dependencies

    private let scanner = ARMeshScannerService()
    private let uploader = UploadService.shared

    /// ARSCNView nach oben durchreichen, damit die View es einbetten kann
    var sceneView: ARSCNView { scanner.sceneView }

    // MARK: - Private

    private var scanTimer: Timer?
    private var uploaderCancellable: AnyCancellable?
    private var currentScanRecord: ScanRecord?

    // MARK: - Init

    init() {
        uploaderCancellable = uploader.$uploadProgress
            .receive(on: RunLoop.main)
            .assign(to: \.uploadProgress, on: self)
    }

    // MARK: - Actions

    func startScan() {
        exportedFileURL = nil
        errorMessage = nil
        meshAnchorCount = 0
        scanDuration = 0
        currentScanRecord = nil
        isScanning = true

        scanner.startScan()
        startTimer()
    }

    func stopAndExport(modelContext: ModelContext) async {
        guard isScanning else { return }
        stopTimer()
        isScanning = false
        isExporting = true
        errorMessage = nil

        do {
            let url = try await scanner.exportToUSDZ()
            exportedFileURL = url

            let scanName = "Raum \(formattedDate())"
            let record = ScanRecord(name: scanName, localFileURL: url)
            modelContext.insert(record)
            currentScanRecord = record
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

        isUploading = true
        uploadProgress = 0
        errorMessage = nil

        let spaceName = currentScanRecord?.name ?? "Raum \(formattedDate())"

        do {
            let result = try await uploader.uploadScan(fileURL: fileURL, spaceName: spaceName)
            print("Upload erfolgreich: \(result.modelUrl)")
            currentScanRecord?.remoteURL = result.modelUrl
            currentScanRecord?.isUploaded = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isUploading = false
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Timer

    private func startTimer() {
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scanDuration += 1
                self?.meshAnchorCount = self?.scanner.meshAnchorCount ?? 0
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
