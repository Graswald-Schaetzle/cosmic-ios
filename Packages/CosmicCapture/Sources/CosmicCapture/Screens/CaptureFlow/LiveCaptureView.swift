import SwiftUI

/// Live capture: camera feed, recording status, frame counter, one coaching
/// card, and Finish. Coaching is presentation only; the coordinator's gates
/// decide which frames are kept.
struct LiveCaptureView: View {
    @Bindable var model: CaptureFlowModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                cameraSurface
                if CaptureScreenLayoutPolicy.usesLandscapeColumns(
                    availableSize: proxy.size,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                ) {
                    landscapeChrome
                } else {
                    portraitChrome
                }
            }
            .overlay(alignment: .top) {
                if let banner = statusBanner {
                    Label(
                        banner.message,
                        systemImage: banner.severity == .critical
                            ? "exclamationmark.triangle.fill"
                            : "info.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 460)
                    .background(
                        banner.severity == .critical
                            ? Color.red.opacity(0.88)
                            : Color.orange.opacity(0.88),
                        in: Capsule()
                    )
                    .padding(.horizontal, 72)
                    .padding(.top, 64)
                    .accessibilityIdentifier("capture-status-warning")
                }
            }
        }
        .statusBarHidden(true)
    }

    private var cameraSurface: some View {
        ZStack {
            CaptureCameraView(session: model.coordinator.session)
                .ignoresSafeArea()
            LinearGradient(
                colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var portraitChrome: some View {
        VStack(spacing: 0) {
            topChrome
                .padding(.horizontal, 16)
                .padding(.top, 12)
            Spacer()
            scanGuide
                .frame(maxWidth: 440)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            finishButton
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .readableColumn(maxWidth: 440)
        }
        .safeAreaPadding(.horizontal, 8)
    }

    private var landscapeChrome: some View {
        VStack(spacing: 0) {
            topChrome.padding(.top, 8)
            Spacer()
            HStack(alignment: .bottom, spacing: 18) {
                scanGuide.frame(maxWidth: 440)
                Spacer(minLength: 0)
                finishButton.frame(maxWidth: 240)
            }
            .padding(.bottom, 10)
        }
        .safeAreaPadding(.horizontal, 16)
    }

    private var topChrome: some View {
        HStack(alignment: .center) {
            Button(action: model.requestDiscard) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
                    .background(CameraChromeBackground())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityHint("Discards this scan")

            Spacer()
            recordingStatus
            Spacer()

            Color.clear.frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(captureIsAdvancing ? Color.red : Color.orange)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(CaptureFormatting.duration(model.coordinator.activeDurationSeconds))
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
            Text("\(model.coordinator.committedFrameCount) frames")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityIdentifier("capture-frame-count")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CameraChromeBackground())
    }

    private var scanGuide: some View {
        CaptureScanGuide(
            selectedPass: $model.scanPass,
            isExpanded: $model.isScanGuideExpanded,
            guidance: guideGuidance,
            aim: model.coordinator.scanAim,
            isSampling: model.coordinator.isActivelySampling
        )
    }

    /// Warnings go to the banner; the guide card keeps coaching-level messages.
    private var guideGuidance: CaptureGuidance? {
        guard let guidance = model.coordinator.guidance, statusBanner?.id != guidance.id else {
            return nil
        }
        return guidance
    }

    private var statusBanner: CaptureGuidance? {
        if let guidance = model.coordinator.guidance,
           guidance.severity >= .warning || guidance.id == "flow-reacquiring" {
            return guidance
        }
        if model.coordinator.isActivelySampling,
           model.coordinator.trackingState == .normal,
           let lastCommit = model.coordinator.lastFrameCommittedAt,
           Date().timeIntervalSince(lastCommit) >= 3 {
            return CaptureGuidance(
                id: "capture-waiting-for-movement",
                severity: .warning,
                message: "Paused because the phone is still. Move to continue.",
                isUrgentStyle: false,
                wantsHaptic: false
            )
        }
        return nil
    }

    private var captureIsAdvancing: Bool {
        guard model.coordinator.isActivelySampling,
              model.coordinator.trackingState == .normal,
              let lastCommit = model.coordinator.lastFrameCommittedAt
        else {
            return false
        }
        return Date().timeIntervalSince(lastCommit) < 3
    }

    private var finishButton: some View {
        Button(action: model.requestFinish) {
            Text("Finish")
                .font(.headline)
                .foregroundStyle(.black)
                .frame(minWidth: 148, maxWidth: .infinity, minHeight: 50)
                .padding(.horizontal, 22)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(
            model.coordinator.status != .running
                || model.coordinator.committedFrameCount == 0
        )
        .opacity(model.coordinator.committedFrameCount == 0 ? 0.55 : 1)
        .accessibilityIdentifier("finish-scan")
        .accessibilityHint("Reviews and saves this scan")
    }
}
