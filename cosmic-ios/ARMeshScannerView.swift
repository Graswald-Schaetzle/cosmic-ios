import SwiftUI
import ARKit

/// UIViewRepresentable-Wrapper für ARSCNView (benötigt UIKit-Integration)
struct ARMeshViewRepresentable: UIViewRepresentable {
    let arView: ARSCNView

    func makeUIView(context: Context) -> ARSCNView { arView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

/// Haupt-Scan-View – eingebettet in ContentView.
struct ARMeshScannerView: View {
    @StateObject private var viewModel = ScanViewModel()
    @State private var showErrorAlert = false

    var body: some View {
        ZStack {
            // AR-Kameraansicht mit LiDAR-Mesh
            ARMeshViewRepresentable(arView: viewModel.sceneView)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Status-Header
                statusHeader
                    .padding(.top, 12)
                    .padding(.horizontal, 16)

                Spacer()

                // Bottom Controls
                bottomControls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }
        }
        .onAppear { viewModel.startScan() }
        .onDisappear { viewModel.sceneView.session.pause() }
        .alert("Fehler", isPresented: $showErrorAlert) {
            Button("OK") { viewModel.dismissError() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            showErrorAlert = newValue != nil
        }
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack {
            scanStateIndicator
            Spacer()
            meshQualityIndicator
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

    private var meshQualityIndicator: some View {
        HStack(spacing: 4) {
            Text("Netz")
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
        return viewModel.meshAnchorCount >= thresholds[index] ? .green : Color.secondary.opacity(0.3)
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
                Task { await viewModel.stopAndExport() }
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
