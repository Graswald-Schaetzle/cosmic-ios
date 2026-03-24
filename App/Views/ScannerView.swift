import SwiftUI
import ARKit

// MARK: - ScannerView

struct ScannerView: View {
    @StateObject private var viewModel: ScanViewModel

    init(viewModel: ScanViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            // AR Camera fullscreen background
            ARMeshViewRepresentable(arView: viewModel.sceneView)
                .ignoresSafeArea()

            // Overlay layers
            VStack(spacing: 0) {
                statusBar
                Spacer()
                bottomControls
            }
        }
        .alert(
            "Fehler",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            if let message = viewModel.errorMessage {
                Text(message)
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            scanStateIndicator
            Spacer()
            meshQualityIndicator
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var scanStateIndicator: some View {
        HStack(spacing: 8) {
            if viewModel.isScanning {
                PulsingDot()
            }
            Text(scanStateLabel)
                .font(.headline)
                .foregroundColor(.primary)
            if viewModel.isScanning {
                Text(formattedDuration)
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    private var scanStateLabel: String {
        if viewModel.isUploading {
            return "Wird hochgeladen..."
        } else if viewModel.isExporting {
            return "Wird exportiert..."
        } else if viewModel.exportedFileURL != nil && !viewModel.isScanning {
            return "Export fertig"
        } else if viewModel.isScanning {
            return "Scanning..."
        } else {
            return "Bereit"
        }
    }

    private var formattedDuration: String {
        let total = Int(viewModel.scanDuration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Mesh Quality Indicator

    private var meshQualityIndicator: some View {
        HStack(spacing: 4) {
            Text("Netz-Qualität:")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(dotColor(forIndex: index))
                        .frame(width: 8, height: 8)
                }
            }
        }
    }

    private func dotColor(forIndex index: Int) -> Color {
        let count = viewModel.meshAnchorCount
        if count == 0 {
            return Color.secondary.opacity(0.3)
        } else if count < 5 {
            // Low quality: first dot only
            return index == 0 ? .red : Color.secondary.opacity(0.3)
        } else if count < 15 {
            // Medium quality: first two dots
            return index < 2 ? .orange : Color.secondary.opacity(0.3)
        } else {
            // High quality: all three dots
            return .green
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            // Upload progress
            if viewModel.isUploading {
                uploadProgressView
            }

            // Export success card
            if let fileURL = viewModel.exportedFileURL, !viewModel.isScanning, !viewModel.isExporting {
                exportSuccessCard(fileURL: fileURL)
            }

            // Scan tip while scanning
            if viewModel.isScanning {
                Text("Bewege dich langsam durch den Raum")
                    .font(.caption)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            // Main action button
            if !viewModel.isExporting && !viewModel.isUploading {
                mainActionButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
        .padding(.top, 12)
        .background(Color.black.opacity(0.6))
    }

    private var mainActionButton: some View {
        Group {
            if viewModel.isScanning {
                Button {
                    Task { await viewModel.stopAndExport() }
                } label: {
                    Text("Scan beenden & Exportieren")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.red)
                        .cornerRadius(16)
                }
            } else if viewModel.exportedFileURL == nil {
                Button {
                    viewModel.startScan()
                } label: {
                    Text("Scan starten")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.blue)
                        .cornerRadius(16)
                }
            }
        }
    }

    // MARK: - Export Success Card

    private func exportSuccessCard(fileURL: URL) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
                Text("3D-Modell gespeichert")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Text(fileURL.lastPathComponent)
                .font(.caption)
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                Task { await viewModel.uploadScan() }
            } label: {
                Text("Hochladen")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green)
                    .cornerRadius(16)
            }
            .disabled(viewModel.isUploading)
        }
        .padding(16)
        .background(Color.white.opacity(0.1))
        .cornerRadius(16)
    }

    // MARK: - Upload Progress View

    private var uploadProgressView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Wird hochgeladen...")
                    .font(.subheadline)
                    .foregroundColor(.white)
                Spacer()
                Text("\(Int(viewModel.uploadProgress * 100)) %")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.white)
            }
            ProgressView(value: viewModel.uploadProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
        }
        .padding(14)
        .background(Color.white.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Pulsing Dot Animation

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .scaleEffect(pulsing ? 1.4 : 1.0)
            .opacity(pulsing ? 0.5 : 1.0)
            .animation(
                .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}
