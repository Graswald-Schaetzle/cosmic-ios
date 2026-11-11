import SwiftUI

/// Full-screen capture flow: readiness → live → saving → saved.
struct CaptureFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: CaptureFlowModel
    @State private var isRenaming = false

    private let library: CaptureLibrary
    private let onShowCaptureDetails: ((UUID) -> Void)?
    private let onSaved: ((CaptureRecord) -> Void)?

    init(
        library: CaptureLibrary,
        initialName: String? = nil,
        onShowCaptureDetails: ((UUID) -> Void)? = nil,
        onSaved: ((CaptureRecord) -> Void)? = nil
    ) {
        self.library = library
        self.onShowCaptureDetails = onShowCaptureDetails
        self.onSaved = onSaved
        _model = State(
            initialValue: CaptureFlowModel(
                library: library,
                experience: CaptureGuidanceSetup.makeExperience(),
                initialName: initialName
            )
        )
    }

    var body: some View {
        ZStack {
            switch model.step {
            case .readiness:
                CaptureReadinessView(model: model, onCancel: close)
            case .live:
                if let experience = model.experience {
                    experience.liveView()
                } else {
                    LiveCaptureView(model: model)
                }
            case .saving:
                SavingLocallyView(model: model)
            case .saved:
                CaptureSavedView(
                    model: model,
                    onDone: close,
                    onShowDetails: detailsAction,
                    onRename: { isRenaming = true }
                )
            }
        }
        .overlay { model.experience?.flowOverlay() }
        // The Cosmic glass look is dark regardless of the system appearance.
        .preferredColorScheme(.dark)
        .tint(Theme.primary)
        .task { await model.onAppear() }
        .onDisappear {
            model.onDisappear()
            CaptureOrientationLock.endCapturePresentation()
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
        .onChange(of: model.step) { _, step in
            if step == .saved, let record = model.savedRecord {
                onSaved?(record)
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
        .sheet(isPresented: $isRenaming) {
            CaptureRenameSheet(
                initialName: model.savedRecord?.name ?? model.captureName,
                onSave: rename
            )
        }
    }

    private var detailsAction: (() -> Void)? {
        guard onShowCaptureDetails != nil else { return nil }
        return { showDetails() }
    }

    private func close() {
        dismiss()
    }

    private func showDetails() {
        guard let id = model.savedRecord?.id else { return }
        onShowCaptureDetails?(id)
        dismiss()
    }

    private func resumeAfterSheetDismiss() {
        if model.step == .live {
            model.keepCapturing()
        }
    }

    private func rename(to newName: String) -> String? {
        guard let id = model.savedRecord?.id else {
            return "This scan is no longer available."
        }
        do {
            try library.rename(id: id, to: newName)
            if var saved = model.savedRecord {
                saved.name = newName
                model.savedRecord = saved
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
