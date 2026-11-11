import SwiftUI
import simd

/// Live capture for the full guidance setup: coverage paint on the camera,
/// a live point cloud card, gap coaching and the walkthrough coach marks.
struct FullLiveCaptureView: View {
    @Bindable var model: CaptureFlowModel
    @Bindable var experience: CoverageGuidanceExperience
    @State private var isOverviewExpanded = false
    @State private var liveCloud: CapturePointCloud?
    @State private var liveCloudRevision = 0
    @State private var livePose: simd_float4x4?
    @State private var liveCamera = CaptureLiveCloudCamera()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                cameraSurface
                if !isOverviewExpanded {
                if CaptureScreenLayoutPolicy.usesLandscapeColumns(
                    availableSize: proxy.size,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                ) {
                    landscapeChrome
                } else {
                    portraitChrome
                }
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsRoomOverview && !isOverviewExpanded && CaptureScreenLayoutPolicy.usesLandscapeColumns(availableSize: proxy.size, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                    integratedOverview(horizontal: false)
                        .frame(width: 300)
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                }
            }
            .overlay(alignment: .top) {
                if let guidance = statusBannerGuidance, !isOverviewExpanded {
                    Label(
                        guidance.message,
                        systemImage: guidance.severity == .critical
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
                        guidance.severity == .critical
                            ? Color.red.opacity(0.88)
                            : Color.orange.opacity(0.88),
                        in: Capsule()
                    )
                    .padding(.horizontal, 72)
                    .padding(.top, 64)
                    .accessibilityIdentifier("capture-status-warning")
                }
            }
            .overlay {
                if isOverviewExpanded {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack {
                        HStack(spacing: 6) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text(CaptureFormatting.duration(model.coordinator.durationSeconds))
                                .font(.body.monospacedDigit().weight(.semibold))
                        }
                        .foregroundStyle(.white).padding(10)
                        .background(.black.opacity(0.65), in: Capsule())
                        Spacer()
                    }.padding(.top, 8).allowsHitTesting(false)
                    let landscape = proxy.size.width > proxy.size.height
                    let layout = landscape ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 12))
                    layout {
                        CaptureLiveCloudCard(pointCloud: liveCloud, revision: liveCloudRevision,
                            camera: liveCamera, pose: livePose, isExpanded: true,
                            instruction: liveInstruction, warning: walkthroughWarning?.message,
                            onInteraction: walkthrough.interactedWithPreview, onReset: walkthrough.resetPreview,
                            close: { isOverviewExpanded = false })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if walkthrough.isActive {
                            Color.clear
                                .frame(width: landscape ? 300 : nil, height: landscape ? nil : 230)
                                .captureTourTarget(.tourPanel)
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 58).padding(.bottom, 12)

                }
            }
        }
        .overlayPreferenceValue(CaptureTourAnchors.self) { anchors in
            GeometryReader { geometry in
                if walkthrough.isActive && walkthrough.postScanStage == nil {
                    let target = tourTarget
                    CaptureCoachMark(walkthrough: walkthrough,
                        target: target.flatMap { anchors[$0] }.map { geometry[$0] }, availableSize: geometry.size, safeAreaInsets: geometry.safeAreaInsets, highlightsMap: target == .map,
                        canReview: model.coordinator.status == .running && model.coordinator.committedFrameCount > 0,
                        inspecting: isOverviewExpanded && walkthrough.lesson == .layout,
                        hasPreview: liveCloud != nil,
                        avoiding: isOverviewExpanded ? nil : anchors[.liveCard].map { geometry[$0] },
                        panel: anchors[.tourPanel].map { geometry[$0] },
                        visibleRegion: isOverviewExpanded || target == nil ? anchors[.map].map { geometry[$0] } : nil,
                        warning: walkthroughWarning?.message, action: advanceTour)
                }
            }
        }
        .onChange(of: experience.isLivePreviewEnabled) { _, enabled in
            if !enabled { isOverviewExpanded = false }
        }
        .onChange(of: isOverviewExpanded) { _, expanded in
            if expanded { walkthrough.openedLayout() }
            else { walkthrough.closedLayout() }
        }
        .onChange(of: walkthrough.lesson) { _, lesson in
            if isOverviewExpanded && lesson == .layout { walkthrough.openedLayout() }
            guard let lesson, UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: lesson.title)
        }
        .onAppear { updatePracticeEvidence() }
        .onChange(of: model.coordinator.committedFrameCount) { _, _ in updatePracticeEvidence() }
        .onChange(of: walkthrough.lesson) { _, _ in updatePracticeEvidence() }
        .statusBarHidden(true)
        .task {
            // Snapshot at most once a second, only when the mesh changed. Never
            // tie point-cloud allocations to the camera's frame rate.
            var lastRevision = -1
            var lastCloudUpdate = Date.distantPast
            var lastDetailMode = false
            while !Task.isCancelled {
                if scenePhase == .active, showsRoomOverview {
                    livePose = guide.liveCameraPoseSnapshot()
                    // Compact card: cheap budget-capped cloud. Expanded view:
                    // full review-quality density — affordable because the
                    // camera mesh overlay is suspended while it is covered.
                    let wantsDetail = isOverviewExpanded
                    if wantsDetail != lastDetailMode {
                        lastDetailMode = wantsDetail
                        lastRevision = -1
                        lastCloudUpdate = .distantPast
                    }
                    let interval: TimeInterval = ProcessInfo.processInfo.thermalState == .serious ? 3 : 1
                    if ProcessInfo.processInfo.thermalState != .critical,
                       Date().timeIntervalSince(lastCloudUpdate) >= interval,
                       lastRevision != guide.meshRevision {
                        lastRevision = guide.meshRevision
                        lastCloudUpdate = Date()
                        let snapshot = wantsDetail
                            ? guide.pointCloudPreviewSnapshot()
                            : guide.livePointCloudSnapshot()
                        if let cloud = snapshot {
                            liveCloud = cloud
                            liveCloudRevision &+= 1
                        }
                    }
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }

        .onChange(of: displayedGuidance?.message) { _, message in
            guard let message, UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private var cameraSurface: some View {
        ZStack {
            // `.equatable()` keeps the 100 ms pose marker and the one-second
            // recording timer from re-entering the AR representable: SwiftUI
            // only calls `updateUIView` when an overlay input changed.
            // While the expanded preview covers the camera, the mesh overlay
            // is suspended entirely and catches up on close.
            CaptureARViewContainer(
                session: model.coordinator.session,
                guide: guide,
                renderRevision: guide.overlayRevision,
                overlayMode: .camera,
                repairTarget: guide.coverageEmphasisTarget,
                showsMeshOverlay: CaptureCoverageGuide.isSceneReconstructionSupported
                    && !isOverviewExpanded
            )
            .equatable()
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .black.opacity(0.45),
                    .clear,
                    .clear,
                    .black.opacity(0.55),
                ],
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
            if showsRoomOverview {
                portraitOverview
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .readableColumn()
            } else if walkthrough.isActive || model.isScanGuideExpanded || model.coordinator.guidance != nil {
                scanGuide
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
            }
            bottomControls
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .readableColumn(maxWidth: 440)
        }
        .safeAreaPadding(.horizontal, 8)
    }

    @ViewBuilder
    private var portraitOverview: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView { integratedOverview(horizontal: false) }
                .scrollBounceBehavior(.basedOnSize)
        } else {
            integratedOverview(horizontal: true)
        }
    }

    private var landscapeChrome: some View {
        VStack(spacing: 0) {
            if walkthrough.isActive && showsRoomOverview {
                HStack {
                    VStack(alignment: .leading, spacing: 12) {
                        chromeButton(systemName: "xmark", action: model.requestDiscard)
                            .accessibilityLabel("Close")
                        recordingStatus
                    }
                    Spacer()
                }
                .padding(.top, 8)
            } else {
                topChrome.padding(.top, 8)
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 18) {
                if !showsRoomOverview && (walkthrough.isActive || model.isScanGuideExpanded || model.coordinator.guidance != nil) {
                    scanGuide
                        .frame(maxWidth: 440)
                }
                Spacer(minLength: 0)
                bottomControls.frame(maxWidth: 240)
            }
            .padding(.bottom, 10)
        }
        .safeAreaPadding(.horizontal, 16)
    }

    private var topChrome: some View {
        HStack(alignment: .center) {
            chromeButton(systemName: "xmark") {
                model.requestDiscard()
            }
            .accessibilityLabel("Close")
            .accessibilityHint("Discards this scan")

            Spacer()

            recordingStatus

            Spacer()

            Color.clear
                .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(captureIsAdvancing ? Color.red : Color.orange)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(
                CaptureFormatting.duration(
                    model.coordinator.activeDurationSeconds
                )
            )
            .font(.body.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            Text(captureIsAdvancing ? "active" : "paused")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(chromeBackground)
    }

    private func integratedOverview(horizontal: Bool) -> some View {
        CaptureLiveCloudCard(pointCloud: liveCloud, revision: liveCloudRevision,
            camera: liveCamera, pose: livePose, horizontalCompact: horizontal, isPracticing: walkthrough.isActive,
            instruction: compactOverviewInstruction,
            warning: nil,
                            onInteraction: walkthrough.interactedWithPreview, onReset: walkthrough.resetPreview,
            expand: { isOverviewExpanded = true }, close: {
                if walkthrough.isActive {
                    walkthrough.skip()
                } else {
                    experience.isLivePreviewEnabled = false
                    model.isScanGuideExpanded = false
                }
            })
            .captureTourTarget(.liveCard)
    }

    private var liveInstruction: String {
        if let guidance = displayedGuidance,
           guidance.severity >= .warning || guidance.id == "flow-reacquiring"
        {
            return guidance.message
        }
        if let navigation = guide.gapNavigation, navigation.direction != .inView {
            return navigation.message
        }
        if let advisory = advisoryGuidance {
            return advisory.message
        }
        return "Move slowly and sweep from high to low."
    }

    /// Coverage cues from the guide (missing area, forgotten surface). They
    /// coach through the instruction line, never the warning banner.
    private var advisoryGuidance: CaptureGuidance? {
        guard let guidance = model.coordinator.guidance,
              guidance.id.hasPrefix(CaptureGuidanceArbiter.advisoryIDPrefix) else { return nil }
        return guidance
    }

    private var compactOverviewInstruction: String {
        statusBannerGuidance == nil
            ? liveInstruction
            : "Move slowly and sweep from high to low."
    }

    private var showsRoomOverview: Bool {
        experience.supportsScanGuide && experience.isLivePreviewEnabled
    }

    private func updatePracticeEvidence() {
        walkthrough.observeCapture(frames: model.coordinator.committedFrameCount,
            distance: Float(model.coordinator.pathLengthM),
            category: guide.guidanceCategory)
    }

    private var walkthroughWarning: CaptureGuidance? {
        displayedGuidance.flatMap { $0.severity >= .warning ? $0 : nil }
    }

    private var tourTarget: CaptureTourTarget? {
        switch walkthrough.lesson {
        case .preview, .inspect, .camera: return .map
        case .reset: return .reset
        case .layout: return isOverviewExpanded ? .done : .expand
        case .review: return isOverviewExpanded ? .done : .finish
        case .hiddenSurfaces: return isOverviewExpanded ? .done : showsRoomOverview ? .liveCard : nil
        default: return nil
        }
    }

    private func advanceTour() {
        guard walkthrough.canAdvance else { return }
        if walkthrough.lesson == .layout {
            isOverviewExpanded = true
        } else if walkthrough.lesson == .review {
            model.requestFinish()
        } else {
            walkthrough.advance()
        }
    }

    private var guideContent: some View {
        Text(liveInstruction)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(12)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
    }

    private var displayedGuidance: CaptureGuidance? {
        guard let guidance = model.coordinator.guidance,
              !guidance.id.hasPrefix(CaptureGuidanceArbiter.advisoryIDPrefix) else { return nil }
        return guidance
    }

    private var guide: CaptureCoverageGuide { experience.guide }
    private var walkthrough: CaptureWalkthrough { experience.walkthrough }

    private var statusBannerGuidance: CaptureGuidance? {
        if let guidance = displayedGuidance,
           guidance.severity >= .warning || guidance.id == "flow-reacquiring"
        {
            return guidance
        }
        if model.coordinator.isActivelySampling,
           model.coordinator.trackingState == .normal,
           let lastCommit = model.coordinator.lastFrameCommittedAt,
           Date().timeIntervalSince(lastCommit) >= 3
        {
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

    @ViewBuilder
    private var scanGuide: some View {
        if walkthrough.isActive {
            EmptyView()
        } else if !experience.supportsScanGuide {
            if let warning = displayedGuidance, warning.severity >= .warning {
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: 440)
                    .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("capture-warning")
            }
        } else if model.isScanGuideExpanded {
            ScrollView { guideContent }
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 260 : 300)
                .frame(maxWidth: 440)
        } else {
            guideContent
                .frame(maxWidth: 440)
        }
    }

    private var bottomControls: some View {
        HStack(spacing: 12) {
            if experience.supportsScanGuide && !model.isScanGuideExpanded && !experience.isLivePreviewEnabled {
                Button {
                    model.isScanGuideExpanded = true
                    experience.isLivePreviewEnabled = true
                } label: {
                    Label("Guide", systemImage: "viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .background(chromeBackground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show scan guide")
            }
            finishButton
        }
    }

    private var finishButton: some View {
        Button {
            model.requestFinish()
        } label: {
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
        .captureTourTarget(.finish)
        .accessibilityHint("Reviews and saves this scan")
    }

    private func chromeButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
                .background(chromeBackground)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var chromeBackground: some View {
        if reduceTransparency || contrast == .increased {
            Capsule()
                .fill(Color.black.opacity(0.72))
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
        } else {
            Capsule()
                .fill(.black.opacity(0.35))
                .glassControlBackground(in: Capsule())
        }
    }
}
