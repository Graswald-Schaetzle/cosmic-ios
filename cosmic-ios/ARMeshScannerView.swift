import SwiftUI
import RoomPlan
import SwiftData

// MARK: - RoomCaptureViewRepresentable

/// UIViewRepresentable-Wrapper für RoomCaptureView (benötigt UIKit-Integration).
struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let roomCaptureView: RoomCaptureView

    func makeUIView(context: Context) -> RoomCaptureView { roomCaptureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

// MARK: - ARMeshScannerView

/// Haupt-Scan-View – eingebettet in ContentView.
/// Zeigt RoomCaptureView auf LiDAR-Geräten; auf anderen einen Fallback-Hinweis.
struct ARMeshScannerView: View {
    @StateObject private var viewModel = ScanViewModel()
    @Environment(\.modelContext) private var modelContext
    @State private var showErrorAlert = false

    var body: some View {
        if ARTrackingService.isSupported {
            scannerContent
        } else {
            lidarUnavailableView
        }
    }

    // MARK: - Scanner Content

    private var scannerContent: some View {
        ZStack {
            RoomCaptureViewRepresentable(roomCaptureView: viewModel.roomCaptureView)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                statusHeader
                    .padding(.top, 12)
                    .padding(.horizontal, 16)

                Spacer()

                bottomControls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }
        }
        .onAppear { viewModel.startScan() }
        .onDisappear { viewModel.pauseIfNeeded() }
        .alert("Fehler", isPresented: $showErrorAlert) {
            Button("OK") { viewModel.dismissError() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            showErrorAlert = newValue != nil
        }
    }

    // MARK: - LiDAR Unavailable Fallback

    private var lidarUnavailableView: some View {
        VStack(spacing: 20) {
            Image(systemName: "sensor.tag.radiowaves.forward.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("LiDAR nicht verfügbar")
                .font(.title2.weight(.semibold))
            Text("Der 3D-Raumscan erfordert ein iPhone 12 Pro oder neuer bzw. ein iPad Pro (2020+) mit LiDAR-Scanner.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack {
            scanStateIndicator
            Spacer()
            roomQualityIndicator
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var scanStateIndicator: some View {
        HStack(spacing: 8) {
            if viewModel.isScanning {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(pulsing)
                    .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulsing)
                Text("Scanning – \(formattedDuration(viewModel.scanDuration))")
                    .font(.subheadline.weight(.medium))
            } else if viewModel.isExporting {
                ProgressView().scaleEffect(0.8)
                Text("Wird exportiert…")
                    .font(.subheadline.weight(.medium))
            } else if viewModel.exportedFileURL != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Export fertig")
                    .font(.subheadline.weight(.medium))
            } else {
                Image(systemName: "camera.viewfinder")
                Text("Bereit")
                    .font(.subheadline.weight(.medium))
            }
        }
        .foregroundStyle(.primary)
    }

    @State private var pulsing: Double = 1.0

    /// Drei Punkte als Qualitätsindikator – basierend auf erkannten Raumelementen.
    private var roomQualityIndicator: some View {
        HStack(spacing: 4) {
            Text("Elemente")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(0..<3) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private func dotColor(for index: Int) -> Color {
        let thresholds = [1, 5, 15]
        return viewModel.detectedElementCount >= thresholds[index] ? .green : Color.secondary.opacity(0.3)
    }

    // MARK: - Bottom Controls

    @ViewBuilder
    private var bottomControls: some View {
        VStack(spacing: 12) {
            if viewModel.isUploading {
                uploadProgressView
            }

            if let url = viewModel.exportedFileURL, !viewModel.isUploading {
                exportSuccessCard(url: url)
            }

            scanButton
        }
    }

    private var uploadProgressView: some View {
        VStack(spacing: 6) {
            ProgressView(value: viewModel.uploadProgress)
                .tint(.blue)
            Text("Wird hochgeladen… \(Int(viewModel.uploadProgress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func exportSuccessCard(url: URL) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("3D-Modell gespeichert")
                    .font(.subheadline.weight(.semibold))
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await viewModel.uploadScan() }
            } label: {
                Label("Hochladen", systemImage: "icloud.and.arrow.up")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var scanButton: some View {
        Button {
            if viewModel.isScanning {
                Task { await viewModel.stopAndExport(modelContext: modelContext) }
            } else {
                viewModel.startScan()
            }
        } label: {
            Group {
                if viewModel.isExporting {
                    HStack { ProgressView().tint(.white); Text("Exportieren…") }
                } else {
                    Text(viewModel.isScanning ? "Scan beenden & Exportieren" : "Scan starten")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(viewModel.isScanning ? Color.red : Color.blue)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .disabled(viewModel.isExporting || viewModel.isUploading)
    }

    // MARK: - Helpers

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
