import SwiftUI
import CosmicCapture

/// The tabs of the app shell. `scan` is never shown as a tab: selecting it
/// starts a scan and the previous tab stays selected.
enum AppTab: Hashable {
    case home
    case captures
    case scan
}

/// App shell after sign-in (see docs/ios-redesign-plan.md, phase 2):
/// a Liquid Glass tab bar with Home and Captures, the scan button set apart
/// on the right, a bottom accessory while something uploads or processes,
/// the space switcher in the title menu and the profile behind the avatar.
struct RootView: View {
    @State private var model = AppModel()
    @State private var selection: AppTab = .home
    @State private var isScanning = false
    @State private var isShowingProfile = false

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    SpaceHomeView(onCaptureRoom: startScan)
                        .navigationTitle(model.selectedSpace?.name ?? "Home")
                        .toolbarTitleMenu { spaceMenu }
                        .toolbar { profileButton }
                }
            }

            Tab("Captures", systemImage: "square.stack", value: AppTab.captures) {
                NavigationStack {
                    RoomCapturesView(store: model.captureStore, space: model.selectedSpace)
                        .toolbar { profileButton }
                }
            }

            Tab("Scan", systemImage: "viewfinder", value: AppTab.scan, role: Self.scanTabRole) {
                // Never visible: selecting this tab opens the capture flow instead.
                Color.clear
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .activeWorkAccessory(model.activeWork) { selection = .captures }
        .tint(CosmicDesign.accent)
        .environment(model)
        .sheet(isPresented: $isShowingProfile) {
            ProfileView()
                .environment(model)
        }
        .fullScreenCover(isPresented: $isScanning) {
            CosmicRoomCaptureView(store: model.captureStore) { _ in
                selection = .captures
            }
        }
        .task { await model.loadSpaces() }
        .task { await model.captureStore.refresh() }
        .task { await model.pollProcessing() }
    }

    /// Rejects the scan tab as a selection and starts a scan instead, so the
    /// tab bar keeps showing the tab the user came from.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selection },
            set: { tab in
                if tab == .scan {
                    startScan()
                } else {
                    selection = tab
                }
            }
        )
    }

    private func startScan() {
        isScanning = true
    }

    /// iOS 27 has a dedicated role for a highlighted action tab; on iOS 26 the
    /// search role gives the same placement (a separate glass circle on the right).
    private static var scanTabRole: TabRole {
        if #available(iOS 27.0, *) {
            .prominent
        } else {
            .search
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var profileButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingProfile = true
            } label: {
                Image(systemName: "person.fill")
            }
            .accessibilityLabel("Profile")
        }
    }

    @ViewBuilder
    private var spaceMenu: some View {
        if model.spaces.isEmpty {
            Button("Reload Spaces", systemImage: "arrow.clockwise") {
                Task { await model.loadSpaces() }
            }
        } else {
            Picker("Space", selection: $model.selectedSpaceID) {
                ForEach(model.spaces) { space in
                    VStack {
                        Text(space.name)
                        Text(space.roomSummary)
                    }
                    .tag(Optional(space.spaceId))
                }
            }
        }
    }
}

// MARK: - Bottom accessory

private extension View {
    /// Shows the running upload or processing job above the tab bar. The bar
    /// only exists while there is work; iOS 26.0 cannot hide an accessory, so
    /// it gets none.
    @ViewBuilder
    func activeWorkAccessory(_ work: [AppModel.ActiveWork], onTap: @escaping () -> Void) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: !work.isEmpty) {
                ActiveWorkAccessory(work: work, onTap: onTap)
            }
        } else {
            self
        }
    }
}

/// "Kitchen · processing" with a spinner, or "Bathroom · uploading 34 %"
/// with a progress bar. Tapping it opens the Captures tab.
private struct ActiveWorkAccessory: View {
    let work: [AppModel.ActiveWork]
    let onTap: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let current = work.first {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(for: current))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if placement != .inline, let progress = current.progress {
                            ProgressView(value: progress)
                                .tint(CosmicDesign.accent)
                        }
                    }

                    Spacer(minLength: 0)

                    if let progress = current.progress {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(CosmicDesign.secondaryText)
                    }
                }
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows your captures")
        }
    }

    private func title(for item: AppModel.ActiveWork) -> String {
        let action = item.kind == .uploading ? "uploading" : "processing"
        let others = work.count - 1
        let suffix = others > 0 ? " · +\(others) more" : ""
        return "\(item.roomName) · \(action)\(suffix)"
    }
}

extension BackendSpace {
    /// "7 rooms", "1 room", "No rooms yet".
    var roomSummary: String {
        switch roomCount {
        case 0: "No rooms yet"
        case 1: "1 room"
        default: "\(roomCount) rooms"
        }
    }
}
