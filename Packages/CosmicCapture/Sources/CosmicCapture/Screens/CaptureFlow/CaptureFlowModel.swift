import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

/// The app's scene phase, mirrored so the policy below is testable without SwiftUI.
enum CaptureSceneActivity {
    case active
    case inactive
    case background
}

enum CaptureScenePhaseAction: Equatable {
    case none
    case pause
    case resume
    case save
}

/// Inactive pauses sampling (Control Center, a call banner); background saves
/// the capture, because iOS may suspend the app and stop the camera at any time.
struct CaptureScenePhasePolicy {
    private(set) var isPausedForInactivity = false

    mutating func action(
        for activity: CaptureSceneActivity,
        isCapturing: Bool,
        isFinishReviewPresented: Bool
    ) -> CaptureScenePhaseAction {
        guard isCapturing else {
            isPausedForInactivity = false
            return .none
        }

        switch activity {
        case .inactive:
            guard !isFinishReviewPresented else { return .none }
            isPausedForInactivity = true
            return .pause
        case .background:
            isPausedForInactivity = false
            return .save
        case .active:
            guard isPausedForInactivity, !isFinishReviewPresented else {
                return .none
            }
            isPausedForInactivity = false
            return .resume
        }
    }
}

struct CaptureStartMetadata: Equatable, Sendable {
    let name: String
    let startedAt: Date
}

struct CaptureNameDraft: Equatable, Sendable {
    private(set) var value: String
    private(set) var isUserEdited = false

    init(
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        value = CaptureFormatting.automaticName(
            now: now,
            locale: locale,
            timeZone: timeZone
        )
    }

    mutating func updateFromUser(_ value: String) {
        self.value = value
        isUserEdited = true
    }

    mutating func metadataForCaptureStart(
        at startedAt: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> CaptureStartMetadata {
        if !isUserEdited {
            value = CaptureFormatting.automaticName(
                now: startedAt,
                locale: locale,
                timeZone: timeZone
            )
        }
        return CaptureStartMetadata(name: value, startedAt: startedAt)
    }
}

/// Drives one capture from readiness to a saved bundle:
/// readiness → live → (finish sheet) → saving → saved.
@MainActor
@Observable
final class CaptureFlowModel {
    enum Step: Equatable {
        case readiness
        case live
        case saving
        case saved
    }

    var step: Step = .readiness
    var scanPass: CaptureScanPass = .walls
    var isScanGuideExpanded = true

    private var captureNameDraft = CaptureNameDraft()
    var captureName: String { captureNameDraft.value }
    var readinessIssue: CaptureReadinessIssue?
    var isCheckingReadiness = true
    var isCameraAuthorized = false
    var freeStorageLabel = CaptureStorageProbe.freeGigabytesLabel()
    var isTrackingReady: Bool { coordinator.trackingState == .normal }
    var showDiscardConfirmation = false
    var showFinishSheet = false
    /// Set by a guidance add-on while its own finish review is on screen.
    var isPresentingFinishReview = false
    var finishWarnings: [CaptureQualityAdvisor.Warning] = []
    var saveError: String?
    var savedRecord: CaptureRecord?
    private(set) var hasReachedFrameLimit = false
    var canKeepScanning: Bool { !hasReachedFrameLimit }
    var frameLimitMessage: String {
        "This scan has reached its limit. Save now to keep everything you captured."
    }
    private(set) var chosenHoldMode: CaptureHoldMode = .portrait
    var isFirstCapture: Bool { library.captures.isEmpty }

    let coordinator: ARCaptureCoordinator
    /// Optional guidance add-on; nil runs the core screens.
    let experience: (any CaptureGuidanceExperience)?
    private let library: CaptureLibrary
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var hasStartedPreview = false
    private var isSavingCapture = false
    private var scenePhasePolicy = CaptureScenePhasePolicy()

    init(
        library: CaptureLibrary,
        experience: (any CaptureGuidanceExperience)? = nil,
        initialName: String? = nil
    ) {
        self.library = library
        self.experience = experience
        coordinator = ARCaptureCoordinator(liveGuide: experience?.liveGuide)
        if let initialName, !initialName.isEmpty {
            captureNameDraft.updateFromUser(initialName)
        }
        experience?.attach(to: self)
    }

    func onAppear() async {
        guard step == .readiness else { return }
        CaptureOrientationLock.beginCapturePresentation()
        CaptureIdleTimerLock.restore()
        await refreshReadiness()
        wireCoordinatorCallbacks()
        if readinessIssue == .cameraNotDetermined {
            await requestCameraPermission()
            return
        }
        if readinessIssue == nil, isCameraAuthorized {
            startPreviewIfNeeded()
        }
    }

    func onDisappear() {
        // The discard and finish sheets present over this view; keep the AR
        // session alive while they are up.
        guard !showDiscardConfirmation && !showFinishSheet && !isPresentingFinishReview else { return }
        CaptureIdleTimerLock.restore()
        coordinator.pauseSession()
        if let id = coordinator.currentWriterID {
            library.markWriterInactive(id)
        }
        endBackgroundTask()
    }

    func refreshReadiness() async {
        isCheckingReadiness = true
        freeStorageLabel = CaptureStorageProbe.freeGigabytesLabel()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isCameraAuthorized = true
            readinessIssue = coordinator.prepareReadiness()
        case .notDetermined:
            isCameraAuthorized = false
            readinessIssue = .cameraNotDetermined
        case .denied, .restricted:
            isCameraAuthorized = false
            readinessIssue = .cameraDenied
        @unknown default:
            isCameraAuthorized = false
            readinessIssue = .cameraDenied
        }

        isCheckingReadiness = false
    }

    func requestCameraPermission() async {
        let granted = await coordinator.requestCameraAccess()
        isCameraAuthorized = granted
        if granted {
            readinessIssue = coordinator.prepareReadiness()
            startPreviewIfNeeded()
        } else {
            readinessIssue = .cameraDenied
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    var canStart: Bool {
        readinessIssue == nil
            && isCameraAuthorized
            && !isCheckingReadiness
            && isTrackingReady
    }

    func updateCaptureNameFromUser(_ name: String) {
        guard step == .readiness else { return }
        captureNameDraft.updateFromUser(name)
    }

    func startCapture() {
        guard step == .readiness, canStart else { return }
        guard experience?.shouldStartCapture() ?? true else { return }
        chosenHoldMode = CaptureOrientationLock.lockForCapture()
        do {
            let metadata = captureNameDraft.metadataForCaptureStart(at: Date())
            _ = try coordinator.beginCapture(
                name: metadata.name,
                startedAt: metadata.startedAt,
                chosenHoldMode: chosenHoldMode,
                library: library
            )
            step = .live
            experience?.captureDidStart()
            syncIdleTimer()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            CaptureOrientationLock.beginCapturePresentation()
            readinessIssue = .trackingFailed(error.localizedDescription)
        }
    }

    func requestDiscard() {
        showDiscardConfirmation = true
    }

    func confirmDiscard(dismiss: () -> Void) {
        coordinator.discard(library: library)
        syncIdleTimer()
        showDiscardConfirmation = false
        dismiss()
    }

    func requestFinish() {
        presentFinishSheet(pauseSource: .finishReview)
    }

    func frameLimitReached() {
        guard !hasReachedFrameLimit else { return }
        hasReachedFrameLimit = true
        guard step == .live else { return }
        if showFinishSheet {
            coordinator.pauseSampling(source: .frameLimit)
            coordinator.pauseSession()
            return
        }
        presentFinishSheet(pauseSource: .frameLimit)
    }

    private func presentFinishSheet(pauseSource: CaptureSamplingPauseSource) {
        guard step == .live else { return }
        coordinator.pauseSampling(source: pauseSource)
        if pauseSource == .frameLimit {
            // There is no resume path once the budget is exhausted. Stop
            // ARKit too so the camera stops consuming heat behind the prompt.
            coordinator.pauseSession()
        }
        syncIdleTimer()
        CaptureOrientationLock.transition(to: .finish)
        finishWarnings = CaptureQualityAdvisor.warnings(
            frameCount: coordinator.capturedCount,
            pathLengthM: coordinator.pathLengthM,
            durationSeconds: coordinator.durationSeconds
        )
        // A budget-exhausted capture goes straight to Save; building a review
        // must not delay that prompt.
        if pauseSource != .frameLimit, experience?.presentFinishReview() == true {
            return
        }
        showFinishSheet = true
    }

    func keepCapturing() {
        guard canKeepScanning else {
            showFinishSheet = true
            CaptureOrientationLock.transition(to: .finish)
            syncIdleTimer()
            return
        }
        showFinishSheet = false
        CaptureOrientationLock.transition(to: .live)
        // Re-assert the busy guard in case a teardown marked it inactive.
        if let id = coordinator.currentWriterID {
            library.markWriterActive(id)
        }
        coordinator.resumeSampling(source: .finishReview)
        experience?.captureDidResume()
        syncIdleTimer()
    }

    func finishAnyway() async {
        showFinishSheet = false
        await saveCapture()
    }

    func saveCapture(preservingFailureMessage failureMessage: String? = nil) async {
        guard !isSavingCapture else { return }
        isSavingCapture = true
        defer { isSavingCapture = false }

        CaptureOrientationLock.transition(to: .saving)
        step = .saving
        syncIdleTimer()
        saveError = failureMessage
        beginBackgroundTask()

        do {
            let manifest = try await coordinator.finish(library: library)
            await experience?.captureDidFinalize(id: manifest.id)
            await library.refresh()
            savedRecord = library.record(for: manifest.id)
            experience?.captureDidSave()
            step = .saved
            CaptureOrientationLock.transition(to: .saved)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            saveError = failureMessage ?? error.localizedDescription
        }

        endBackgroundTask()
    }

    func retrySave() async {
        await saveCapture()
    }

    func discardFailedCapture() {
        coordinator.discard(library: library)
        endBackgroundTask()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        let activity: CaptureSceneActivity
        switch phase {
        case .active:
            activity = .active
            CaptureOrientationLock.transition(to: .foreground)
        case .inactive:
            activity = .inactive
        case .background:
            activity = .background
            CaptureOrientationLock.transition(to: .background)
        @unknown default:
            return
        }
        let action = scenePhasePolicy.action(
            for: activity,
            isCapturing: step == .live,
            isFinishReviewPresented: showFinishSheet || isPresentingFinishReview
        )
        switch action {
        case .none:
            return
        case .pause:
            coordinator.pauseSampling(source: .scenePhase)
            syncIdleTimer()
        case .resume:
            coordinator.resumeSampling(source: .scenePhase)
            syncIdleTimer()
        case .save:
            coordinator.pauseSampling(source: .scenePhase)
            syncIdleTimer()
            Task { await saveCapture() }
        }
    }

    private func startPreviewIfNeeded() {
        guard !hasStartedPreview else { return }
        hasStartedPreview = true
        coordinator.startPreview()
    }

    private func wireCoordinatorCallbacks() {
        coordinator.onFrameCommitted = { [weak self] frameCount in
            guard frameCount >= CapturePaths.maxFrames else { return }
            self?.frameLimitReached()
        }
        coordinator.onSamplingStateChanged = { [weak self] in
            self?.syncIdleTimer()
        }
        coordinator.onStorageFailure = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                guard self.step == .live else { return }
                await self.saveCapture(preservingFailureMessage: error.localizedDescription)
            }
        }
        coordinator.onFatalError = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.readinessIssue = .trackingFailed(message)
                if self.step == .live {
                    await self.saveCapture(preservingFailureMessage: message)
                }
            }
        }
    }

    private func syncIdleTimer() {
        CaptureIdleTimerLock.setDisabled(Self.shouldDisableIdleTimer(for: step))
    }

    static func shouldDisableIdleTimer(for step: Step) -> Bool {
        step == .live
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinalizeCapture") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
