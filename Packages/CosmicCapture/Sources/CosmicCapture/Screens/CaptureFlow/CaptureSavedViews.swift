import SwiftUI
import UIKit

/// A centered modal over the live capture.
struct CaptureCenteredSheet<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                content()
                    .frame(
                        width: min(520, geometry.size.width - 32),
                        height: min(520, geometry.size.height - 32)
                    )
                    .cosmicGlassPanel()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Finish confirmation. Shows `CaptureQualityAdvisor` warnings (too few
/// frames, too little movement, too short) before the user commits.
struct FinishCaptureSheet: View {
    @Bindable var model: CaptureFlowModel
    @State private var isFinishing = false

    private var hasWarnings: Bool { !model.finishWarnings.isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            ScreenScrollView { summary.padding(24) }
            actions.padding(.horizontal, 24).padding(.bottom, 20)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(model.hasReachedFrameLimit || hasWarnings ? Theme.warning : Theme.success)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.foreground)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            stats
        }
    }

    private var iconName: String {
        if model.hasReachedFrameLimit { return "stop.circle.fill" }
        return hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var title: String {
        if model.hasReachedFrameLimit { return "Scan limit" }
        return model.finishWarnings.first?.title ?? "Ready to save"
    }

    private var message: String {
        if model.hasReachedFrameLimit { return model.frameLimitMessage }
        if let warning = model.finishWarnings.first { return warning.message }
        let duration = CaptureFormatting.duration(model.coordinator.durationSeconds)
        return "\(duration) scanned. Save now or keep scanning."
    }

    private var stats: some View {
        let coordinator = model.coordinator
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Frames").foregroundStyle(Theme.mutedForeground)
                Text("\(coordinator.committedFrameCount)").monospacedDigit()
            }
            GridRow {
                Text("Path").foregroundStyle(Theme.mutedForeground)
                Text(String(format: "%.1f m", coordinator.pathLengthM)).monospacedDigit()
            }
            GridRow {
                Text("Blur rejects").foregroundStyle(Theme.mutedForeground)
                Text("\(coordinator.blurRejectedFrameCount)").monospacedDigit()
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.foreground)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            if model.hasReachedFrameLimit {
                saveButton(title: "Save scan", style: .primary)
            } else if hasWarnings {
                Button("Keep scanning", action: model.keepCapturing)
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(isFinishing)
                saveButton(title: "Finish anyway", style: .secondary)
            } else {
                saveButton(title: "Finish scan", style: .primary)
                Button("Keep scanning", action: model.keepCapturing)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(isFinishing)
            }
        }
    }

    private enum SaveButtonStyle { case primary, secondary }

    @ViewBuilder
    private func saveButton(title: String, style: SaveButtonStyle) -> some View {
        let button = Button(action: finish) {
            LoadingButtonLabel(
                title: title,
                loadingTitle: "Finishing…",
                isLoading: isFinishing,
                progressTint: style == .primary ? Color.black : Theme.foreground
            )
        }
        .disabled(isFinishing)
        .accessibilityIdentifier("save-scan")
        switch style {
        case .primary: button.buttonStyle(PrimaryActionButtonStyle())
        case .secondary: button.buttonStyle(SecondaryActionButtonStyle())
        }
    }

    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        Task {
            await model.finishAnyway()
            isFinishing = false
        }
    }
}

/// Finalizing: the writer rebuilds the contract files from crash-safe frame records.
struct SavingLocallyView: View {
    @Bindable var model: CaptureFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var isRetrying = false

    var body: some View {
        GeometryReader { proxy in
            ScreenScrollView {
                VStack(spacing: 18) {
                    if let saveError = model.saveError {
                        failureContent(saveError)
                    } else {
                        ProgressView().controlSize(.large)
                        Text("Saving to this \(CaptureDevice.name)…")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.foreground)
                        Text("Keep the app open for a moment.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.mutedForeground)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(32)
                .frame(minHeight: proxy.size.height)
                .readableColumn()
            }
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func failureContent(_ saveError: String) -> some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 36))
            .foregroundStyle(Theme.destructive)
            .accessibilityHidden(true)
        Text("Couldn't finish saving")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.foreground)
        Text(failureMessage(saveError))
            .font(.subheadline)
            .foregroundStyle(Theme.mutedForeground)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        if model.coordinator.committedFrameCount > 0 {
            Button {
                guard !isRetrying else { return }
                isRetrying = true
                Task {
                    await model.retrySave()
                    isRetrying = false
                }
            } label: {
                LoadingButtonLabel(title: "Try again", loadingTitle: "Saving…", isLoading: isRetrying)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(isRetrying)
            .frame(maxWidth: 320)
        } else {
            Button("Discard failed scan", role: .destructive) {
                model.discardFailedCapture()
                dismiss()
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .frame(maxWidth: 320)
        }
    }

    private func failureMessage(_ error: String) -> String {
        if model.coordinator.committedFrameCount > 0 {
            return "Your saved frames are safe. Try again.\n\(error)"
        }
        return "The scan couldn’t be saved. Start a new scan.\n\(error)"
    }
}

/// Saved: the bundle is final and validated on disk.
struct CaptureSavedView: View {
    @Bindable var model: CaptureFlowModel
    let onDone: () -> Void
    let onShowDetails: (() -> Void)?
    let onRename: () -> Void

    var body: some View {
        ScreenScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 54)
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.success)
                        .accessibilityHidden(true)
                    Text("Scan saved on this \(CaptureDevice.name)")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.foreground)
                        .multilineTextAlignment(.center)
                }
                summaryCard
                VStack(spacing: 12) {
                    if let onShowDetails {
                        Button("View bundle", action: onShowDetails)
                            .buttonStyle(PrimaryActionButtonStyle())
                            .accessibilityIdentifier("view-bundle")
                        Button("Done", action: onDone)
                            .buttonStyle(SecondaryActionButtonStyle())
                    } else {
                        Button("Done", action: onDone)
                            .buttonStyle(PrimaryActionButtonStyle())
                    }
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .readableColumn(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(model.savedRecord?.name ?? model.captureName)
                    .font(.headline)
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(2)
                Text(metaLine)
                    .font(.footnote)
                    .foregroundStyle(Theme.mutedForeground)
                Button("Rename", action: onRename)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.muted, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = model.savedRecord?.thumbnailURL,
           let image = UIImage(contentsOfFile: url.path) {
            CaptureThumbnailImage(image: Image(uiImage: image))
                .frame(width: 64, height: 64)
                .background(Color(white: 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.muted)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "cube.transparent").foregroundStyle(Theme.mutedForeground)
                }
        }
    }

    private var metaLine: String {
        let frames = model.savedRecord.map { "\($0.frameCount) frames" } ?? ""
        let duration = model.savedRecord?.formattedDuration
            ?? CaptureFormatting.duration(model.coordinator.durationSeconds)
        let size = model.savedRecord?.formattedStorageSize ?? "Unavailable"
        return [frames, duration, size].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
