import SwiftUI
import CosmicCapture

/// Lists the room captures saved on this device. Each capture holds an
/// Echo-3 bundle plus LiDAR sidecar data (see docs/echo3-capture-plan.md).
/// A capture can be uploaded into the selected space, where the backend
/// turns it into a splat with Echo-3, or exported as a ZIP.
struct RoomCapturesView: View {
    let store: CosmicCaptureStore
    /// The space uploads go into. Without one, uploading is disabled.
    let space: BackendSpace?

    @State private var uploads = RoomCaptureUploadService.shared
    @State private var exportingID: UUID?
    @State private var exportedZip: ExportedZip?
    @State private var quotingID: UUID?
    @State private var pendingUpload: PendingUpload?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.captures.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(store.captures) { capture in
                                row(for: capture)
                            }
                            .onDelete(perform: delete)
                        } footer: {
                            Text(footerText)
                        }
                    }
                }
            }
            .navigationTitle("Room Captures")
            .task { await store.refresh() }
            .task { await pollProcessing() }
            .refreshable {
                await store.refresh()
                await uploads.refreshProcessing()
            }
            .sheet(item: $exportedZip) { zip in
                ActivityView(items: [zip.url])
            }
            .alert(
                "Process this room?",
                isPresented: Binding(
                    get: { pendingUpload != nil },
                    set: { if !$0 { pendingUpload = nil } }
                ),
                presenting: pendingUpload
            ) { pending in
                if pending.quote.hasEnough {
                    Button("Upload") { startUpload(pending) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(quoteMessage(for: pending))
            }
            .alert(
                "Action failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var footerText: String {
        if let space {
            return "Uploads go into the space \"\(space.name)\". Processing a room takes about half an hour; LiDAR depth images stay on this device."
        }
        return "Select a space to upload captures. Until then a capture can be exported as a ZIP."
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No captures yet", systemImage: "camera.viewfinder")
        } description: {
            Text("Start a scan to capture your first room.")
        }
    }

    private func row(for capture: CosmicCaptureSummary) -> some View {
        let state = uploads.state(for: capture.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                thumbnail(for: capture)
                VStack(alignment: .leading, spacing: 4) {
                    Text(capture.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(detailLine(for: capture))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        statusBadge(for: state)
                        if capture.lidarMeshURL != nil {
                            badge("LiDAR mesh", systemImage: "cube.transparent")
                        }
                    }
                }
                Spacer(minLength: 0)
                uploadButton(for: capture, state: state)
                exportButton(for: capture)
            }
            if let fraction = uploads.progress[capture.id] {
                ProgressView(value: fraction)
            }
            if state?.phase == .failed, let message = state?.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if state?.lidarMeshMissing == true {
                Text("The LiDAR mesh could not be uploaded.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(for state: RoomCaptureUploadState?) -> some View {
        switch state?.phase {
        case nil:
            badge("On device", systemImage: "internaldrive")
        case .uploading:
            badge("Uploading", systemImage: "arrow.up.circle")
        case .processing:
            badge("Processing", systemImage: "hourglass")
        case .completed:
            badge("In space", systemImage: "checkmark.circle")
        case .failed:
            badge("Failed", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func thumbnail(for capture: CosmicCaptureSummary) -> some View {
        if let url = capture.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "cube.transparent")
                        .foregroundStyle(.secondary)
                }
        }
    }

    /// Shown for captures that are not uploaded yet or whose upload failed.
    @ViewBuilder
    private func uploadButton(for capture: CosmicCaptureSummary, state: RoomCaptureUploadState?) -> some View {
        if quotingID == capture.id {
            ProgressView()
                .frame(width: 44, height: 44)
        } else if state == nil || state?.phase == .failed {
            Button {
                requestUpload(capture)
            } label: {
                Image(systemName: state == nil ? "icloud.and.arrow.up" : "arrow.clockwise")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(space == nil || quotingID != nil)
            .accessibilityLabel(state == nil ? "Upload capture" : "Retry upload")
        }
    }

    @ViewBuilder
    private func exportButton(for capture: CosmicCaptureSummary) -> some View {
        if exportingID == capture.id {
            ProgressView()
                .frame(width: 44, height: 44)
        } else {
            Button {
                export(capture)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(exportingID != nil)
            .accessibilityLabel("Export capture ZIP")
        }
    }

    private func badge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    private func detailLine(for capture: CosmicCaptureSummary) -> String {
        let size = ByteCountFormatter.string(fromByteCount: capture.bundleBytes, countStyle: .file)
        let duration = Duration.seconds(capture.durationSeconds)
            .formatted(.time(pattern: .minuteSecond))
        return "\(capture.frameCount) frames · \(duration) · \(size)"
    }

    private func quoteMessage(for pending: PendingUpload) -> String {
        let quote = pending.quote
        let size = ByteCountFormatter.string(fromByteCount: pending.capture.bundleBytes, countStyle: .file)
        var lines = [
            "Costs \(quote.requiredCredits.formatted()) of \(quote.availableCredits.formatted()) available credits."
        ]
        if let seconds = quote.estimatedDurationSeconds {
            lines.append("Takes about \(Int((seconds / 60).rounded())) minutes.")
        }
        if quote.hasEnough {
            lines.append("The upload is about \(size); keep the app open until it finishes.")
        } else {
            lines.append("There are not enough credits to process this room.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    /// Fetches the price first: processing spends credits, so the user confirms it.
    private func requestUpload(_ capture: CosmicCaptureSummary) {
        guard let space else { return }
        quotingID = capture.id
        Task {
            do {
                let quote = try await uploads.quote(frameCount: capture.frameCount)
                pendingUpload = PendingUpload(capture: capture, spaceID: space.spaceId, quote: quote)
            } catch {
                errorMessage = error.localizedDescription
            }
            quotingID = nil
        }
    }

    private func startUpload(_ pending: PendingUpload) {
        Task {
            await uploads.upload(pending.capture, to: pending.spaceID, store: store)
        }
    }

    /// Follows captures in processing while the list is open.
    private func pollProcessing() async {
        while !Task.isCancelled {
            if uploads.hasProcessingCaptures {
                await uploads.refreshProcessing()
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func export(_ capture: CosmicCaptureSummary) {
        exportingID = capture.id
        Task {
            do {
                let url = try await store.makeBundleZip(id: capture.id)
                exportedZip = ExportedZip(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
            exportingID = nil
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { store.captures[$0].id }
        for id in ids {
            do {
                try store.delete(id: id)
                uploads.forget(id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PendingUpload {
    let capture: CosmicCaptureSummary
    let spaceID: Int
    let quote: RoomCaptureQuote
}

private struct ExportedZip: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
