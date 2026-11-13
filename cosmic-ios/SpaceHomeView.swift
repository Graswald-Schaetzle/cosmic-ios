import SwiftUI
import CosmicCapture

/// Home tab: the open space and its rooms.
///
/// Phase 2 keeps this simple (room names from `/spaces`). Phase 3 of
/// docs/ios-redesign-plan.md adds the start-room preview, the floor picker and
/// a status per room once the backend lists room captures.
struct SpaceHomeView: View {
    let onCaptureRoom: () -> Void

    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        Group {
            if let space = model.selectedSpace {
                content(for: space)
            } else if model.isLoadingSpaces {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = model.spacesErrorMessage {
                ContentUnavailableView {
                    Label("Spaces unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task { await model.loadSpaces() }
                    }
                    .buttonStyle(.cosmicSecondary)
                    .fixedSize()
                }
            } else {
                ContentUnavailableView {
                    Label("No space yet", systemImage: "house")
                } description: {
                    Text("Create a space in the Cosmic web app, then pull to refresh.")
                }
            }
        }
        .refreshable { await model.loadSpaces() }
    }

    @ViewBuilder
    private func content(for space: BackendSpace) -> some View {
        if space.rooms.isEmpty {
            ScrollView {
                ContentUnavailableView {
                    Label("No room yet", systemImage: "viewfinder")
                } description: {
                    Text("Capture your first room. It takes a few minutes per room.")
                } actions: {
                    Button("Capture Room", systemImage: "viewfinder", action: onCaptureRoom)
                        .buttonStyle(.cosmicPrimary)
                        .fixedSize()
                }
                .containerRelativeFrame(.vertical)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(space.roomSummary)
                        .font(.subheadline)
                        .foregroundStyle(CosmicDesign.secondaryText)

                    Text("Rooms")
                        .font(.title3.weight(.bold))

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(space.rooms, id: \.roomId) { room in
                            RoomTile(name: room.name ?? "Untitled room")
                        }
                        AddRoomTile(action: onCaptureRoom)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

private struct RoomTile: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "cube.transparent")
                .font(.title2)
                .foregroundStyle(CosmicDesign.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 64)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cosmicGlassPanel(cornerRadius: CosmicDesign.cardRadius)
        .accessibilityElement(children: .combine)
    }
}

private struct AddRoomTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.title2)
                Text("Capture room")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(CosmicDesign.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 110)
            .overlay {
                RoundedRectangle(cornerRadius: CosmicDesign.cardRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            }
            .contentShape(RoundedRectangle(cornerRadius: CosmicDesign.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
