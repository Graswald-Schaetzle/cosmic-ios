import SwiftUI

/// Full-screen, room-by-room capture for a space's tour: a room card before
/// every capture, the live scan, and after each save the question where the
/// tour continues (mark the door to the next room, or finish). Present it
/// with `fullScreenCover`.
///
/// It hosts the same steps as `CaptureFlowView`, with the room card in place
/// of the readiness screen and the door step in place of the saved screen.
public struct CosmicTourCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var flow: TourCaptureFlow

    /// - Parameters:
    ///   - onRoomSaved: called for every capture that was saved into the tour.
    ///   - onCaptureReplaced: called with the id of a capture that a
    ///     re-capture replaced and deleted from the device.
    public init(
        captureStore: CosmicCaptureStore,
        tourStore: CosmicTourStore,
        spaceID: Int,
        start: CosmicTourCaptureStart = .nextRoom,
        onRoomSaved: @escaping (CosmicCaptureSummary) -> Void = { _ in },
        onCaptureReplaced: @escaping (UUID) -> Void = { _ in }
    ) {
        _flow = State(
            initialValue: TourCaptureFlow(
                captureStore: captureStore,
                tourStore: tourStore,
                spaceID: spaceID,
                start: start,
                onRoomSaved: onRoomSaved,
                onCaptureReplaced: onCaptureReplaced
            )
        )
    }

    private var model: CaptureFlowModel { flow.model }

    public var body: some View {
        @Bindable var model = flow.model
        ZStack {
            switch model.step {
            case .readiness:
                if isBlocked {
                    CaptureReadinessView(model: model, onCancel: close)
                } else {
                    TourRoomCardView(flow: flow, onCancel: close)
                }
            case .live:
                if let experience = model.experience {
                    experience.liveView()
                } else {
                    LiveCaptureView(model: model)
                }
            case .saving:
                SavingLocallyView(model: model)
            case .saved:
                TourDoorStepView(flow: flow, onFinish: close)
            }
        }
        .overlay { model.experience?.flowOverlay() }
        .preferredColorScheme(.dark)
        .tint(Theme.primary)
        .task { await model.onAppear() }
        .onDisappear {
            model.onDisappear()
            CaptureOrientationLock.endCapturePresentation()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                flow.appDidBecomeActive()
            } else {
                flow.appDidLeaveForeground()
            }
            model.handleScenePhase(phase)
        }
        .onChange(of: model.step) { previous, step in
            if previous == .readiness, step == .live {
                flow.captureDidStart()
            }
            if step == .saved {
                flow.captureDidSave()
            }
        }
        .confirmationDialog(
            "Discard this scan?",
            isPresented: $model.showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard scan", role: .destructive) {
                model.confirmDiscard(dismiss: close)
            }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("It hasn't been saved and can't be recovered.")
        }
        .fullScreenCover(isPresented: $model.showFinishSheet, onDismiss: resumeAfterSheetDismiss) {
            CaptureCenteredSheet { FinishCaptureSheet(model: model) }
                .presentationBackground(.clear)
                .interactiveDismissDisabled(model.hasReachedFrameLimit)
        }
    }

    /// Missing camera permission or an unsupported device: the readiness
    /// screen of the capture core explains these.
    private var isBlocked: Bool {
        switch model.readinessIssue {
        case .cameraDenied, .arkitUnsupported, .unsupportedVideoFormat: true
        default: false
        }
    }

    private func close() {
        dismiss()
    }

    private func resumeAfterSheetDismiss() {
        if model.step == .live {
            model.keepCapturing()
        }
    }
}

// MARK: - Room card

/// Shown before every capture: room name, floor, and the checklist.
struct TourRoomCardView: View {
    @Bindable var flow: TourCaptureFlow
    let onCancel: () -> Void

    @State private var isAddingFloor = false
    @FocusState private var isFloorFieldFocused: Bool

    private var model: CaptureFlowModel { flow.model }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                cameraBackground
                ViewThatFits(in: .vertical) {
                    panel.fixedSize(horizontal: false, vertical: true)
                    ScrollView { panel }.scrollBounceBehavior(.basedOnSize)
                }
                .frame(width: min(540, proxy.size.width - 32))
                .frame(maxHeight: proxy.size.height - 32)
                .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: flow.roomName) { _, _ in flow.syncCaptureName() }
    }

    @ViewBuilder
    private var cameraBackground: some View {
        if model.isCameraAuthorized {
            CaptureCameraView(session: model.coordinator.session)
                .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(flow.isRecapture ? "Capture this room again" : "Next room")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.primary)

            if let arrival = flow.arrivalRoom {
                arrivalNotice(from: arrival)
            }

            if flow.isRecapture {
                VStack(alignment: .leading, spacing: 4) {
                    Text(flow.roomName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.foreground)
                    Text(flow.floorName)
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground)
                    Text("The new capture replaces the current one. Name and floor stay.")
                        .font(.footnote)
                        .foregroundStyle(Theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                TextField("Room name", text: $flow.roomName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.foreground)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .accessibilityIdentifier("tour-room-name")
                floorPicker
            }

            VStack(alignment: .leading, spacing: 12) {
                checklistRow(icon: "sun.max", title: "Turn on the lights and open the blinds")
                checklistRow(icon: "door.left.hand.closed", title: "Close every door of this room")
                checklistRow(icon: "person.slash", title: "Keep people and pets out of the room")
                checklistRow(icon: "iphone", title: "Keep the phone in one orientation for the whole room")
            }

            if let issue = model.readinessIssue, issue != .cameraNotDetermined {
                Text(issue.message)
                    .font(.footnote)
                    .foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.freeStorageLabel)
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground)

            VStack(spacing: 10) {
                Button(action: flow.startCapture) {
                    LoadingButtonLabel(
                        title: "Start scan",
                        loadingTitle: "Getting ready…",
                        isLoading: isGettingReady
                    )
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!flow.canStart)
                .opacity(flow.canStart ? 1 : 0.5)
                .accessibilityIdentifier("tour-start-scan")
                Button(flow.savedRoomCount > 0 ? "Finish tour" : "Cancel", action: onCancel)
                    .buttonStyle(SecondaryActionButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cosmicGlassPanel()
        .padding(10)
    }

    private var isGettingReady: Bool {
        model.readinessIssue == nil && !flow.isTrackingReady
    }

    private func arrivalNotice(from room: CaptureTourRoom) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(
                    "Walk through the door you marked in \(room.name), close it behind you and stand directly behind it, facing into the room. Then start the scan."
                )
                .font(.subheadline)
                .foregroundStyle(Theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "door.left.hand.open")
                    .foregroundStyle(Theme.primary)
            }
            Toggle(isOn: $flow.cameThroughMarkedDoor) {
                Text("I am standing behind that door")
                    .font(.footnote)
                    .foregroundStyle(Theme.mutedForeground)
            }
            .tint(Theme.primary)
        }
        .padding(14)
        .background(Theme.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var floorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Floor")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.mutedForeground)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(floorChoices, id: \.self) { name in
                        floorChip(name, isSelected: !isAddingFloor && isSelectedFloor(name)) {
                            isAddingFloor = false
                            flow.floorName = name
                        }
                    }
                    floorChip("New floor", systemImage: "plus", isSelected: isAddingFloor) {
                        isAddingFloor = true
                        flow.floorName = ""
                        isFloorFieldFocused = true
                    }
                }
            }
            if isAddingFloor {
                TextField("Floor name, for example Upper floor", text: $flow.floorName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.foreground)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .focused($isFloorFieldFocused)
                    .padding(.horizontal, 14)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .background(Theme.muted, in: Capsule())
                    .accessibilityIdentifier("tour-floor-name")
            }
        }
    }

    /// Floors already used in this tour; a first tour starts with the default.
    private var floorChoices: [String] {
        let existing = flow.existingFloorNames
        return existing.isEmpty ? [CaptureTour.defaultFloorName] : existing
    }

    private func isSelectedFloor(_ name: String) -> Bool {
        CaptureTour.floorKey(name) == CaptureTour.floorKey(flow.floorName)
    }

    private func floorChip(
        _ title: String,
        systemImage: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption.weight(.semibold))
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Theme.primaryForeground : Theme.foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(isSelected ? Theme.primary : Theme.muted, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func checklistRow(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.foreground)
                .frame(width: 32, height: 32)
                .background(Theme.muted, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Door step

/// After a room is saved: "Where does it continue?" The AR session is still
/// running, so the door to the next room can be measured in this capture's
/// coordinates.
struct TourDoorStepView: View {
    let flow: TourCaptureFlow
    let onFinish: () -> Void

    private var model: CaptureFlowModel { flow.model }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CaptureCameraView(session: model.coordinator.session)
                    .ignoresSafeArea()
                switch flow.doorStage {
                case .choose:
                    Color.black.opacity(0.45).ignoresSafeArea()
                    centered(choosePanel, in: proxy.size)
                case .aim:
                    aimOverlay
                case .marked(let door, let distanceM):
                    Color.black.opacity(0.45).ignoresSafeArea()
                    centered(markedPanel(door: door, distanceM: distanceM), in: proxy.size)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func centered(_ panel: some View, in size: CGSize) -> some View {
        ViewThatFits(in: .vertical) {
            panel.fixedSize(horizontal: false, vertical: true)
            ScrollView { panel }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: min(540, size.width - 32))
        .frame(maxHeight: size.height - 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // "Where does it continue?"
    private var choosePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                    .accessibilityHidden(true)
                Text("\(flow.savedRoom?.name ?? "Room") saved")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.foreground)
            }
            if let record = model.savedRecord {
                Text("\(record.frameCount) frames, \(record.formattedDuration), on this \(CaptureDevice.name)")
                    .font(.footnote)
                    .foregroundStyle(Theme.mutedForeground)
            }

            if flow.isRecapture {
                recaptureChoices
            } else {
                Text("Where does it continue?")
                    .font(.headline)
                    .foregroundStyle(Theme.foreground)
                Text("Mark the door you walk through next. The rooms are joined at that door.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    Button("Mark the door to the next room", action: flow.beginAimingAtDoor)
                        .buttonStyle(PrimaryActionButtonStyle())
                        .accessibilityIdentifier("tour-mark-door")
                    Button("Next room without a door link", action: flow.continueWithoutDoor)
                        .buttonStyle(SecondaryActionButtonStyle())
                    Button("Finish tour", action: onFinish)
                        .buttonStyle(SecondaryActionButtonStyle())
                        .accessibilityIdentifier("tour-finish")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cosmicGlassPanel()
        .padding(10)
    }

    @ViewBuilder
    private var recaptureChoices: some View {
        if let next = flow.linkedNextRoom {
            Text("Mark the door to \(next.name) again")
                .font(.headline)
                .foregroundStyle(Theme.foreground)
            Text("The door was measured in the old capture. Without a new marking this room is no longer joined to \(next.name).")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button("Mark the door", action: flow.beginAimingAtDoor)
                    .buttonStyle(PrimaryActionButtonStyle())
                Button("Skip", action: onFinish)
                    .buttonStyle(SecondaryActionButtonStyle())
            }
        } else {
            Button("Done", action: onFinish)
                .buttonStyle(PrimaryActionButtonStyle())
        }
    }

    // Camera with a crosshair.
    private var aimOverlay: some View {
        ZStack {
            Image(systemName: "plus.viewfinder")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.primary)
                .shadow(color: .black.opacity(0.6), radius: 4)
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                Text("Aim at the middle of the closed door you walk through next.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.foreground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .cosmicGlassPanel(cornerRadius: Theme.cardRadius)
                Spacer()
                if let message = flow.doorError ?? trackingMessage {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .cosmicGlassPanel(cornerRadius: Theme.cardRadius)
                }
                VStack(spacing: 10) {
                    Button {
                        Task { await flow.markDoor() }
                    } label: {
                        LoadingButtonLabel(
                            title: "Mark door",
                            loadingTitle: "Measuring…",
                            isLoading: flow.isMeasuringDoor
                        )
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(flow.isMeasuringDoor || !flow.isTrackingReady)
                    .opacity(flow.isTrackingReady ? 1 : 0.5)
                    .accessibilityIdentifier("tour-confirm-door-aim")
                    Button("Back", action: flow.cancelAiming)
                        .buttonStyle(SecondaryActionButtonStyle())
                }
                .frame(maxWidth: 420)
            }
            .padding(20)
        }
    }

    private var trackingMessage: String? {
        flow.isTrackingReady ? nil : "Hold still for a moment. Tracking is recovering."
    }

    private func markedPanel(door: CaptureDoor, distanceM: Float) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "door.left.hand.closed")
                    .foregroundStyle(Theme.primary)
                    .accessibilityHidden(true)
                Text("Door marked")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.foreground)
            }
            Text(markedDetail(door: door, distanceM: distanceM))
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            if !flow.isRecapture {
                Text("Now walk through this door and close it behind you. The next room starts directly behind it.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                Button(flow.isRecapture ? "Done" : "Continue to the next room") {
                    if flow.confirmDoor() { onFinish() }
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .accessibilityIdentifier("tour-confirm-door")
                Button("Mark again", action: flow.beginAimingAtDoor)
                    .buttonStyle(SecondaryActionButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cosmicGlassPanel()
        .padding(10)
    }

    private func markedDetail(door: CaptureDoor, distanceM: Float) -> String {
        let distance = String(format: "%.1f m away.", distanceM)
        switch door.floorSource {
        case .meshFloor, .meshLowest:
            return "\(distance) Floor height taken from the LiDAR mesh."
        case .raycast:
            return "\(distance) Floor height estimated by the camera."
        case .assumedHeight:
            return "\(distance) The floor could not be measured, so its height is a rough guess."
        }
    }
}
