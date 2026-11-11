import SwiftUI

/// Readiness: camera permission, device checks, scan name, and a short
/// checklist before the first frame is recorded.
struct CaptureReadinessView: View {
    @Bindable var model: CaptureFlowModel
    let onCancel: () -> Void

    @State private var isRequestingCameraPermission = false

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
                VStack {
                    topBar
                    Spacer()
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
                    .background(CameraChromeBackground())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var cameraBackground: some View {
        if model.isCameraAuthorized {
            CaptureCameraView(session: model.coordinator.session)
                .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
            Image(systemName: "camera.fill")
                .font(.system(size: 42))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.readinessIssue {
            case .cameraDenied:
                deniedContent
            case .arkitUnsupported, .unsupportedVideoFormat:
                blockedContent(issue: model.readinessIssue!)
            default:
                readyContent
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cosmicGlassPanel()
        .padding(10)
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(
                "Scan name",
                text: Binding(
                    get: { model.captureName },
                    set: { model.updateCaptureNameFromUser($0) }
                )
            )
            .font(.headline)
            .foregroundStyle(Theme.foreground)

            VStack(alignment: .leading, spacing: 12) {
                checklistRow(icon: "sun.max", title: "Turn on the lights and open the blinds")
                checklistRow(icon: "door.left.hand.closed", title: "Close every door of this room")
                checklistRow(icon: "person.slash", title: "Keep people and pets out of view")
                checklistRow(icon: "figure.walk", title: "Walk slowly and keep the phone in one orientation")
            }

            if let issue = model.readinessIssue, issue != .cameraNotDetermined {
                Text(issue.message)
                    .font(.footnote)
                    .foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground)
            actions
        }
    }

    private var statusLine: String {
        model.freeStorageLabel
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

    private var actions: some View {
        VStack(spacing: 10) {
            if model.readinessIssue == .cameraNotDetermined {
                Button {
                    guard !isRequestingCameraPermission else { return }
                    isRequestingCameraPermission = true
                    Task {
                        await model.requestCameraPermission()
                        isRequestingCameraPermission = false
                    }
                } label: {
                    LoadingButtonLabel(
                        title: "Continue",
                        loadingTitle: "Requesting access…",
                        isLoading: isRequestingCameraPermission
                    )
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(isRequestingCameraPermission)
            } else {
                Button(action: model.startCapture) {
                    LoadingButtonLabel(
                        title: "Start scan",
                        loadingTitle: "Getting ready…",
                        isLoading: isInitializingTracking
                    )
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!model.canStart)
                .opacity(model.canStart ? 1 : 0.5)
                .accessibilityIdentifier("start-scan")
            }
            Button("Cancel", action: onCancel)
                .buttonStyle(SecondaryActionButtonStyle())
        }
    }

    private var isInitializingTracking: Bool {
        model.readinessIssue == nil
            && model.isCameraAuthorized
            && !model.isCheckingReadiness
            && !model.isTrackingReady
    }

    private var deniedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Camera access required")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.foreground)
            Text(CaptureReadinessIssue.cameraDenied.message)
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings", action: model.openSettings)
                .buttonStyle(PrimaryActionButtonStyle())
            Button("Not now", action: onCancel)
                .buttonStyle(SecondaryActionButtonStyle())
        }
    }

    private func blockedContent(issue: CaptureReadinessIssue) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(issue.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.foreground)
            Text(issue.message)
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close", action: onCancel)
                .buttonStyle(SecondaryActionButtonStyle())
        }
    }
}
