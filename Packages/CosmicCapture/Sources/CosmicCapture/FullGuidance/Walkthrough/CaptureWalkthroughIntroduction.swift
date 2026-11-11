import SwiftUI

/// A single setup step before recording, with no repeated scanning lesson.
struct CaptureWalkthroughIntroduction: View {
    let walkthrough: CaptureWalkthrough
    let hasLayout: Bool
    let canStart: Bool
    let readinessMessage: String?
    let onStart: () -> Void
    var onOpenSettings: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height && CaptureOrientationLock.isLandscape
            ZStack {
                Color.black.opacity(0.65).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Your practice scan").font(.title2.weight(.semibold))
                            Text("Pick a small, well-lit room. Keep people out of the room while you scan.")
                                .font(.subheadline).foregroundStyle(Theme.mutedForeground)
                            HStack(spacing: 20) {
                                Image(systemName: "iphone.gen3")
                                    .font(.system(size: 48))
                                    .phaseAnimator(landscape || reduceMotion ? [90.0] : [0.0, 90.0, 90.0]) { phone, angle in
                                        phone.rotationEffect(.degrees(angle))
                                    } animation: { _ in .easeInOut(duration: 1.1) }
                                    .frame(width: 80, height: 70).accessibilityHidden(true)
                                Label(landscape ? "Landscape ready" : "Turn your phone sideways",
                                      systemImage: landscape ? "checkmark.circle.fill" : "arrow.turn.down.right")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(landscape ? Theme.success : Theme.foreground)
                                    .accessibilityIdentifier("walkthrough-orientation-check")
                            }
                            if !landscape {
                                Text("Not rotating? Turn off Orientation Lock in Control Center.")
                                    .font(.footnote).foregroundStyle(Theme.mutedForeground)
                            }
                            if let readinessMessage {
                                Text(readinessMessage).font(.footnote).foregroundStyle(Theme.mutedForeground)
                                if let onOpenSettings { Button("Open Settings", action: onOpenSettings).frame(minHeight: 44) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollBounceBehavior(.basedOnSize)
                    HStack {
                        Button("Skip tour", action: walkthrough.skip).frame(minHeight: 44)
                        Spacer()
                        Button("Ready to scan", action: onStart)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 24).frame(minHeight: 44)
                            .background(Color.white, in: Capsule()).buttonStyle(.plain)
                            .disabled(!landscape || !canStart).opacity(landscape && canStart ? 1 : 0.5)
                    }
                }
                .padding(24)
                .frame(width: min(540, proxy.size.width - 32), height: min(330, proxy.size.height - 32))
                .cosmicGlassPanel()
                .foregroundStyle(Theme.foreground).accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { walkthrough.skip() }
            }
        }
    }
}
