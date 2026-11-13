import SwiftUI
import CosmicCapture

/// The capture tour of one space: every room grouped by floor with its
/// status, and the actions around it: add the next room, capture a room
/// again, upload one room or all of them.
struct CaptureTourView: View {
    let space: BackendSpace
    let captureStore: CosmicCaptureStore
    let tourStore: CosmicTourStore

    @Environment(\.dismiss) private var dismiss
    @State private var uploads = RoomCaptureUploadService.shared
    @State private var captureStart: CaptureStart?
    @State private var pendingUpload: PendingTourUpload?
    @State private var roomToRemove: CaptureTourRoom?
    @State private var isQuoting = false
    @State private var isUploadingAll = false
    @State private var errorMessage: String?

    private var tour: CaptureTour { tourStore.tour(for: space.spaceId) }

    var body: some View {
        ZStack {
            CosmicGlass.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if tour.rooms.isEmpty {
                    emptyState
                } else {
                    roomList
                }
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .tint(CosmicGlass.accent)
        .task {
            await captureStore.refresh()
            await uploads.syncTour(spaceID: space.spaceId, tours: tourStore)
        }
        .task { await pollProcessing() }
        .fullScreenCover(item: $captureStart, onDismiss: captureDidClose) { start in
            CosmicTourCaptureView(
                captureStore: captureStore,
                tourStore: tourStore,
                spaceID: space.spaceId,
                start: start.mode,
                onCaptureReplaced: { uploads.forget($0) }
            )
        }
        .alert(
            pendingUpload?.title ?? "",
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
            Text(pending.message)
        }
        .confirmationDialog(
            "Remove \(roomToRemove?.name ?? "room") from this device?",
            isPresented: Binding(
                get: { roomToRemove != nil },
                set: { if !$0 { roomToRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: roomToRemove
        ) { room in
            Button("Remove room", role: .destructive) { remove(room) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The capture is deleted from this device. A room that was already uploaded stays in the space.")
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

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Capture tour")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(CosmicGlass.accent)
                Text(space.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(CosmicGlass.foreground)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CosmicGlass.foreground)
                    .frame(width: 44, height: 44)
                    .background(CosmicGlass.muted, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No rooms yet")
                .font(.headline)
                .foregroundStyle(CosmicGlass.foreground)
            Text("Capture the space room by room with every door closed. After each room you mark the door you walk through next; the rooms are joined at these doors.")
                .font(.subheadline)
                .foregroundStyle(CosmicGlass.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .cosmicPanel()
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var roomList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(tour.floors) { floor in
                    floorSection(floor)
                }
                if let message = uploads.connectionSyncError {
                    Label("The door links could not be sent: \(message)", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(CosmicGlass.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
                Text("Processing a room takes about half an hour and costs credits. Keep the app open while a room uploads. LiDAR depth images stay on this device.")
                    .font(.footnote)
                    .foregroundStyle(CosmicGlass.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .refreshable {
            await captureStore.refresh()
            await uploads.refreshProcessing()
            await uploads.syncTour(spaceID: space.spaceId, tours: tourStore)
        }
    }

    private func floorSection(_ floor: CaptureTour.Floor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(floor.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.08, green: 0.06, blue: 0.02))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(CosmicGlass.accent, in: Capsule())
            ForEach(floor.rooms) { room in
                roomRow(room)
                if room.id != floor.rooms.last?.id {
                    Divider().overlay(Color.white.opacity(0.10))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cosmicPanel()
    }

    private func roomRow(_ room: CaptureTourRoom) -> some View {
        let capture = capture(for: room)
        let state = uploads.state(for: room.captureID)
        let status = status(of: room)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail(for: capture)
                VStack(alignment: .leading, spacing: 5) {
                    Text(room.name)
                        .font(.headline)
                        .foregroundStyle(CosmicGlass.foreground)
                        .lineLimit(2)
                    statusBadge(status)
                    if let capture {
                        Text(detailLine(for: capture))
                            .font(.caption)
                            .foregroundStyle(CosmicGlass.mutedForeground)
                    }
                    ForEach(linkLines(for: room), id: \.self) { line in
                        Label(line, systemImage: "door.left.hand.open")
                            .font(.caption)
                            .foregroundStyle(CosmicGlass.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                roomMenu(room, status: status)
            }
            if let fraction = uploads.progress[room.captureID] {
                ProgressView(value: fraction)
                    .tint(CosmicGlass.accent)
            }
            if status == .failed, let message = state?.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(CosmicGlass.destructive)
                    .lineLimit(4)
            } else if status == .missing {
                Text("The capture is no longer on this device. Capture the room again.")
                    .font(.caption)
                    .foregroundStyle(CosmicGlass.warning)
            } else if state?.lidarMeshMissing == true {
                Text("The LiDAR mesh could not be uploaded.")
                    .font(.caption)
                    .foregroundStyle(CosmicGlass.warning)
            }
        }
    }

    private func roomMenu(_ room: CaptureTourRoom, status: CaptureTourRoomStatus) -> some View {
        Menu {
            if status.canUpload {
                Button {
                    requestUpload([room])
                } label: {
                    Label(status == .failed ? "Retry upload" : "Upload", systemImage: "icloud.and.arrow.up")
                }
                .disabled(isBusy)
            }
            Button {
                captureStart = CaptureStart(mode: .recapture(roomID: room.id))
            } label: {
                Label("Capture again", systemImage: "arrow.triangle.2.circlepath.camera")
            }
            .disabled(status == .uploading || !CosmicCaptureStore.isCaptureSupported)
            Button(role: .destructive) {
                roomToRemove = room
            } label: {
                Label("Remove from device", systemImage: "trash")
            }
            .disabled(status == .uploading)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CosmicGlass.foreground)
                .frame(width: 44, height: 44)
                .background(CosmicGlass.muted, in: Circle())
        }
        .accessibilityLabel("Actions for \(room.name)")
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button {
                captureStart = CaptureStart(mode: .nextRoom)
            } label: {
                Label(tour.rooms.isEmpty ? "Capture first room" : "Add next room", systemImage: "plus")
            }
            .buttonStyle(CosmicPrimaryButtonStyle())
            .disabled(!CosmicCaptureStore.isCaptureSupported)
            .opacity(CosmicCaptureStore.isCaptureSupported ? 1 : 0.5)

            if !CosmicCaptureStore.isCaptureSupported {
                Text("This device cannot capture rooms.")
                    .font(.footnote)
                    .foregroundStyle(CosmicGlass.mutedForeground)
            }

            if !uploadableRooms.isEmpty {
                Button {
                    requestUpload(uploadableRooms)
                } label: {
                    HStack(spacing: 8) {
                        if isQuoting || isUploadingAll {
                            ProgressView().tint(CosmicGlass.foreground)
                        }
                        Text(uploadAllTitle)
                    }
                }
                .buttonStyle(CosmicSecondaryButtonStyle())
                .disabled(isBusy)
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    // MARK: - Row pieces

    private func statusBadge(_ status: CaptureTourRoomStatus) -> some View {
        Label(status.title, systemImage: statusSymbol(status))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor(status).opacity(0.16), in: Capsule())
    }

    private func statusSymbol(_ status: CaptureTourRoomStatus) -> String {
        switch status {
        case .onDevice: return "internaldrive"
        case .uploading: return "arrow.up.circle"
        case .processing: return "hourglass"
        case .inSpace: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .missing: return "questionmark.circle"
        }
    }

    private func statusColor(_ status: CaptureTourRoomStatus) -> Color {
        switch status {
        case .onDevice: return CosmicGlass.foreground
        case .uploading, .processing: return CosmicGlass.accent
        case .inSpace: return CosmicGlass.success
        case .failed: return CosmicGlass.destructive
        case .missing: return CosmicGlass.warning
        }
    }

    @ViewBuilder
    private func thumbnail(for capture: CosmicCaptureSummary?) -> some View {
        if let url = capture?.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(CosmicGlass.muted)
                .frame(width: 60, height: 60)
                .overlay {
                    Image(systemName: "cube.transparent")
                        .foregroundStyle(CosmicGlass.mutedForeground)
                }
        }
    }

    private func detailLine(for capture: CosmicCaptureSummary) -> String {
        let size = ByteCountFormatter.string(fromByteCount: capture.bundleBytes, countStyle: .file)
        let duration = Duration.seconds(capture.durationSeconds)
            .formatted(.time(pattern: .minuteSecond))
        return "\(capture.frameCount) frames · \(duration) · \(size)"
    }

    /// How the room is joined to its neighbours.
    private func linkLines(for room: CaptureTourRoom) -> [String] {
        var lines: [String] = []
        if let previous = tour.previousRoom(of: room.id) {
            lines.append(
                room.entryDoor == nil
                    ? "Door from \(previous.name) not measured in this capture"
                    : "Door from \(previous.name)"
            )
        }
        if let nextID = room.nextRoomID, let next = tour.room(id: nextID) {
            lines.append(
                room.exitDoor == nil
                    ? "Door to \(next.name) not marked in this capture"
                    : "Door to \(next.name)"
            )
        } else if room.exitDoor != nil {
            lines.append("Door marked, next room not captured yet")
        }
        return lines
    }

    // MARK: - State

    private func capture(for room: CaptureTourRoom) -> CosmicCaptureSummary? {
        captureStore.captures.first { $0.id == room.captureID }
    }

    private func status(of room: CaptureTourRoom) -> CaptureTourRoomStatus {
        CaptureTourRoomStatus(
            hasLocalCapture: capture(for: room) != nil,
            phase: uploads.state(for: room.captureID)?.phase
        )
    }

    private var uploadableRooms: [CaptureTourRoom] {
        tour.rooms.filter { status(of: $0).canUpload }
    }

    private var isBusy: Bool { isQuoting || isUploadingAll }

    private var uploadAllTitle: String {
        if isUploadingAll { return "Uploading rooms…" }
        let count = uploadableRooms.count
        return count == 1 ? "Upload 1 room" : "Upload all \(count) rooms"
    }

    // MARK: - Actions

    /// Fetches the price first: processing spends credits, so the user
    /// confirms it. For several rooms the costs are added up.
    private func requestUpload(_ rooms: [CaptureTourRoom]) {
        let captures = rooms.compactMap { capture(for: $0) }
        guard !rooms.isEmpty, captures.count == rooms.count else { return }
        isQuoting = true
        Task {
            do {
                var quotes: [RoomCaptureQuote] = []
                for capture in captures {
                    quotes.append(try await uploads.quote(frameCount: capture.frameCount))
                }
                if let total = RoomCaptureQuote.total(of: quotes) {
                    pendingUpload = PendingTourUpload(
                        rooms: rooms,
                        quote: total,
                        uploadBytes: captures.reduce(0) { $0 + $1.bundleBytes }
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isQuoting = false
        }
    }

    /// Uploads one room after the other; each ZIP is several hundred megabytes.
    private func startUpload(_ pending: PendingTourUpload) {
        isUploadingAll = pending.rooms.count > 1
        Task {
            for room in pending.rooms {
                await uploads.uploadTourRoom(
                    room.id, spaceID: space.spaceId, tours: tourStore, captures: captureStore
                )
            }
            isUploadingAll = false
        }
    }

    private func remove(_ room: CaptureTourRoom) {
        tourStore.update(spaceID: space.spaceId) { $0.removeRoom(id: room.id) }
        uploads.forget(room.captureID)
        do {
            if capture(for: room) != nil {
                try captureStore.delete(id: room.captureID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func captureDidClose() {
        Task {
            await captureStore.refresh()
            await uploads.syncTour(spaceID: space.spaceId, tours: tourStore)
        }
    }

    /// Follows rooms in processing while the overview is open.
    private func pollProcessing() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if uploads.hasProcessingCaptures {
                await uploads.refreshProcessing()
            }
        }
    }
}

private struct CaptureStart: Identifiable {
    let id = UUID()
    let mode: CosmicTourCaptureStart
}

/// One or several rooms waiting for the user to confirm the price.
private struct PendingTourUpload {
    let rooms: [CaptureTourRoom]
    let quote: RoomCaptureQuote
    let uploadBytes: Int64

    var title: String {
        rooms.count == 1 ? "Process \(rooms[0].name)?" : "Process \(rooms.count) rooms?"
    }

    var message: String {
        let size = ByteCountFormatter.string(fromByteCount: uploadBytes, countStyle: .file)
        var lines = [
            "Costs \(quote.requiredCredits.formatted()) of \(quote.availableCredits.formatted()) available credits."
        ]
        if let seconds = quote.estimatedDurationSeconds {
            let minutes = Int((seconds / 60).rounded())
            lines.append(
                rooms.count == 1 ? "Takes about \(minutes) minutes." : "Takes about \(minutes) minutes per room."
            )
        }
        if quote.hasEnough {
            lines.append("The upload is about \(size); keep the app open until it finishes.")
        } else {
            lines.append(
                rooms.count == 1
                    ? "There are not enough credits to process this room."
                    : "There are not enough credits to process all rooms. Upload them one by one."
            )
        }
        return lines.joined(separator: "\n")
    }
}
