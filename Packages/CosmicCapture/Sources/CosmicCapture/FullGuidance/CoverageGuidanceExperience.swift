import Observation
import SwiftUI
import UIKit

/// The full guidance setup: LiDAR coverage paint on the camera, a live point
/// cloud card, gap coaching, a first-scan walkthrough, and a finish review
/// that can send the user back to repair missing areas.
///
/// Selected by `CaptureGuidanceSetup` when built with `FULL_GUIDANCE`. All
/// capture actions still go through `CaptureFlowModel`, so the saved bundle
/// is byte-for-byte the same format as the core setup.
@MainActor
@Observable
final class CoverageGuidanceExperience: CaptureGuidanceExperience {
    let guide = CaptureCoverageGuide()
    let walkthrough = CaptureWalkthrough()
    /// The compact live card and scan guide; the user can hide both.
    var isLivePreviewEnabled = true
    private(set) var finishReview: CapturePreview?
    private(set) var completenessIssues: [CaptureFinishCompleteness.Issue] = []

    @ObservationIgnored private(set) weak var model: CaptureFlowModel?
    /// Cosmic: the LiDAR mesh of the capture saved last, kept for the door
    /// marking that follows the save.
    @ObservationIgnored private(set) var lastFinalizedMesh: CaptureLidarMesh?

    /// The live card, layout lessons and finish review need a mesh.
    var supportsScanGuide: Bool { CaptureCoverageGuide.isSceneReconstructionSupported }

    // MARK: - CaptureGuidanceExperience

    var liveGuide: (any CaptureLiveGuide)? { guide }

    func attach(to model: CaptureFlowModel) {
        self.model = model
        guide.attach(to: model.coordinator)
        // Never offer the tour on phones without LiDAR.
        if supportsScanGuide {
            walkthrough.offerIfNeeded(isFirstCapture: model.isFirstCapture, isContinuation: false)
        }
    }

    func shouldStartCapture() -> Bool {
        if walkthrough.isSelected && !CaptureOrientationLock.isLandscape {
            walkthrough.requestLandscape()
            return false
        }
        if walkthrough.isOffered { walkthrough.skip() }
        return true
    }

    func captureDidStart() {
        walkthrough.start(hasLayout: supportsScanGuide)
    }

    func presentFinishReview() -> Bool {
        walkthrough.openedReview()
        completenessIssues = guide.roomOverview.finishIssues
        // Sparse feature points are not a faithful preview of the scan, so
        // phones without LiDAR use the core finish sheet.
        guard supportsScanGuide, let model else { return false }
        let preview = guide.capturePreviewSnapshot()
        guard preview.availability.isAvailable else { return false }
        finishReview = preview
        model.isPresentingFinishReview = true
        return true
    }

    func captureDidResume() {
        walkthrough.postScanStage = nil
    }

    func captureDidSave() {
        walkthrough.saved()
    }

    /// Persists the room's LiDAR mesh and depth metadata next to the bundle.
    /// Echo-3 never sees these files. A failure here must not fail the save.
    func captureDidFinalize(id: UUID) async {
        let anchors = Array(guide.meshAnchorsSnapshot().values)
        let mesh = anchors.isEmpty ? nil : CaptureLidarMesh(anchors: anchors)
        lastFinalizedMesh = mesh
        await guide.depthRecorder.flush()
        await Task.detached(priority: .userInitiated) {
            _ = try? CaptureLidarSidecarWriter.write(mesh: mesh, captureID: id)
        }.value
    }

    func liveView() -> AnyView {
        guard let model else { return AnyView(EmptyView()) }
        return AnyView(FullLiveCaptureView(model: model, experience: self))
    }

    func flowOverlay() -> AnyView {
        guard let model else { return AnyView(EmptyView()) }
        return AnyView(CoverageGuidanceFlowOverlay(model: model, experience: self))
    }

    // MARK: - Walkthrough and review actions

    /// "Ready to scan" on the walkthrough introduction.
    func startPracticeCapture() {
        guard let model, model.step == .readiness, model.canStart, CaptureOrientationLock.isLandscape else {
            return
        }
        walkthrough.select()
        model.startCapture()
        if model.step != .live { walkthrough.requestLandscape() }
    }

    /// Keep scanning from the review. With missing areas found, the live
    /// screen coaches them one at a time until each gains coverage.
    func keepScanningFromReview() {
        let gaps = finishReview?.coverage?.gaps ?? []
        closeFinishReview()
        if !gaps.isEmpty { guide.beginRepair(gaps: gaps) }
        model?.keepCapturing()
    }

    func saveFromReview() {
        closeFinishReview()
        guard let model else { return }
        Task { await model.finishAnyway() }
    }

    /// Back from the review. A budget-exhausted capture has no resume path,
    /// so it falls back to the save-only sheet.
    func backFromReview() {
        closeFinishReview()
        guard let model else { return }
        if model.hasReachedFrameLimit {
            model.showFinishSheet = true
        } else {
            model.keepCapturing()
        }
    }

    private func closeFinishReview() {
        finishReview = nil
        model?.isPresentingFinishReview = false
    }
}

/// Walkthrough invitation and introduction over readiness, and the finish
/// review over the live screen.
private struct CoverageGuidanceFlowOverlay: View {
    let model: CaptureFlowModel
    let experience: CoverageGuidanceExperience

    var body: some View {
        ZStack {
            if model.step == .readiness && model.isCameraAuthorized
                && experience.walkthrough.isOffered
                && !experience.walkthrough.isPresentingIntroduction
            {
                walkthroughInvitation
            }
            if experience.walkthrough.isPresentingIntroduction {
                CaptureWalkthroughIntroduction(
                    walkthrough: experience.walkthrough,
                    hasLayout: experience.supportsScanGuide,
                    canStart: model.canStart,
                    readinessMessage: model.canStart
                        ? nil
                        : model.readinessIssue?.message ?? "Getting the camera ready…",
                    onStart: experience.startPracticeCapture
                )
            }
            if let preview = experience.finishReview {
                NavigationStack {
                    CapturePreviewReviewScreen(
                        preview: preview,
                        onKeepCapturing: experience.keepScanningFromReview,
                        onSave: experience.saveFromReview,
                        onBack: experience.backFromReview,
                        completenessIssues: experience.completenessIssues,
                        canKeepCapturing: model.canKeepScanning,
                        limitMessage: model.hasReachedFrameLimit ? model.frameLimitMessage : nil,
                        isWalkthrough: experience.walkthrough.isActive,
                        walkthrough: experience.walkthrough
                    )
                }
                .background(Color.black)
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
    }

    private var walkthroughInvitation: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text("Your first scan").font(.headline)
                Text("Take a two-minute practice scan that shows how coverage and the live preview work.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground)
                HStack {
                    Button("Scan on my own", action: experience.walkthrough.skip)
                        .frame(minHeight: Theme.minimumTapTarget)
                    Spacer()
                    Button("Start walkthrough", action: experience.walkthrough.presentIntroduction)
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: Theme.minimumTapTarget)
                        .accessibilityIdentifier("start-walkthrough")
                }
            }
            .padding(20)
            .foregroundStyle(Theme.foreground)
            .cosmicGlassPanel()
            .frame(maxWidth: 520)
            .padding(16)
        }
    }
}

extension CaptureOrientationLock {
    static var isLandscape: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .interfaceOrientation.isLandscape ?? false
    }
}
