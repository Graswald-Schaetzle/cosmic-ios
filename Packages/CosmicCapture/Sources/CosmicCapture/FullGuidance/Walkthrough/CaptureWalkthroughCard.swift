import SwiftUI

/// A single contextual lesson, hosted by the existing guide on LiDAR devices.
/// Non-LiDAR devices only show it after explicitly starting the walkthrough.
struct CaptureWalkthroughCard: View {
    let walkthrough: CaptureWalkthrough
    var inspecting = false
    var hasPreview = true
    var previewLayer: CaptureOverviewLayer = .room
    var canReview = true
    var warning: String? = nil
    var action: () -> Void

    var body: some View {
        if let lesson = walkthrough.lesson {
            let index = walkthrough.lessons.firstIndex(of: lesson) ?? 0
            CaptureTourCallout(number: index + 1, count: walkthrough.totalSteps,
                title: warning != nil ? "Scan guidance" : inspecting ? "Look for missing areas" : lesson.title,
                detail: warning ?? (inspecting
                    ? "Look for holes in your scan. Don’t forget the floor and ceiling, or the sky outdoors. Tap Done to keep scanning."
                    : lesson.detail(hasLayout: walkthrough.hasLayout)),
                animation: inspecting || lesson == .review ? nil : lesson,
                colorNote: lesson == .review && walkthrough.hasLayout && warning == nil
                    ? "Blue is nearer your starting point. Purple is farther away." : nil,
                nextTitle: inspecting || [.review, .layout, .reset].contains(lesson) ? nil : "Next",
                nextEnabled: walkthrough.canAdvance,
                hasInteracted: lesson == .inspect && walkthrough.inspectedPreview,
                nextIdentifier: "walkthrough-continue", skip: walkthrough.skip, next: action)
        }
    }
}

/// One callout style for the entire tour. It lives only in the overlay layer.
struct CaptureTourCallout: View {
    let number: Int
    let count: Int
    let title: String
    let detail: String
    var animation: CaptureWalkthrough.Lesson? = .layout
    var colorNote: String? = nil
    var showsSkip = true
    var nextTitle: String? = "Next"
    var nextEnabled = true
    var hasInteracted = false
    var nextIdentifier = "walkthrough-continue"
    let skip: () -> Void
    let next: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedStep: RevealStep?

    private struct RevealStep: Equatable {
        let number: Int
        let title: String
        let nextTitle: String?
    }

    private var revealStep: RevealStep {
        RevealStep(number: number, title: title, nextTitle: nextTitle)
    }

    private var showsNext: Bool {
        nextEnabled && (hasInteracted || revealedStep == revealStep)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(number)").font(.subheadline.weight(.semibold))
                    .frame(width: 24, height: 24).background(CaptureTourStyle.accent, in: Circle()).foregroundStyle(.black)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)

            }
            HStack(spacing: 12) {
                if let animation { CaptureTourPhoneAnimation(lesson: animation)
                    .frame(width: 64, height: 64).accessibilityHidden(true) }
                Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let colorNote {
                Text(colorNote).font(.caption).foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(0..<count, id: \.self) { index in
                        Capsule().fill(index == number - 1 ? CaptureTourStyle.accent : .white.opacity(0.3))
                            .frame(width: index == number - 1 ? 12 : 3, height: 4)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(number) of \(count)")
                Spacer(minLength: 0)
                if showsSkip { Button("Skip tour", action: skip)
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: 44).accessibilityLabel("Skip walkthrough") }
                if let nextTitle {
                    Button(action: next) {
                        HStack(spacing: 6) {
                            Text(nextTitle).lineLimit(1)
                            CaptureTourArrow()
                        }
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44).foregroundStyle(.black)
                        .background(CaptureTourStyle.accent, in: Capsule())
                        .shadow(color: CaptureTourStyle.accent.opacity(0.5), radius: 8)
                    }
                    // Reserve its space so revealing Next never shifts the card.
                    .disabled(!showsNext)
                    .opacity(showsNext ? 1 : 0)
                    .allowsHitTesting(showsNext)
                    .accessibilityHidden(!showsNext)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsNext)
                    .accessibilityIdentifier(nextIdentifier)
                }
            }
        }
        .foregroundStyle(.white).buttonStyle(.plain)
        .task(id: revealStep) {
            let step = revealStep
            revealedStep = nil
            guard nextTitle != nil else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                revealedStep = step
            } catch {
                // A new step or a dismissed tour cancels the previous delay.
            }
        }
    }
}

/// A landscape phone demonstrates the actual movement, with no camera or mesh work.
struct CaptureTourPhoneAnimation: View {
    let lesson: CaptureWalkthrough.Lesson
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0.25 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
            let wave = sin(phase * .pi * 2)
            ZStack {
                if lesson == .inspect {
                    RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.3), lineWidth: 1)
                        .frame(width: 60, height: 52)
                    Image(systemName: "cube.transparent").font(.system(size: 26))
                        .foregroundStyle(.blue.opacity(0.65))
                        .rotation3DEffect(.degrees(wave * 40), axis: (x: 0, y: 1, z: 0))
                    Image(systemName: "hand.point.up.fill").font(.system(size: 24))
                        .foregroundStyle(CaptureTourStyle.accent)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                        .offset(x: wave * 19, y: 15)
                } else if lesson == .reset {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 34))
                        .foregroundStyle(CaptureTourStyle.accent)
                        .rotationEffect(.degrees(wave * 20))
                } else if lesson == .camera {
                    Path { path in
                        path.move(to: CGPoint(x: 32, y: 46))
                        path.addLine(to: CGPoint(x: 8, y: 10))
                        path.addLine(to: CGPoint(x: 56, y: 10))
                        path.closeSubpath()
                    }.fill(.orange.opacity(0.2))
                    Image(systemName: "location.north.fill").font(.system(size: 28))
                        .foregroundStyle(.orange).rotationEffect(.degrees(wave * 15))
                } else if lesson == .preview {
                    Canvas { context, _ in
                        for row in 0..<6 {
                            for column in 0..<6 {
                                let opacity = reduceMotion ? 0.8 : 0.25 + 0.7 * (1 + sin(phase * .pi * 2 - Double(row + column) * 0.3)) / 2
                                context.fill(Path(ellipseIn: CGRect(x: 7 + column * 9, y: 7 + row * 9, width: 3, height: 3)), with: .color(.cyan.opacity(opacity)))
                            }
                        }
                    }
                } else {
                    if lesson == .hiddenSurfaces {
                        // A table makes the movement relatable without implying object detection.
                        Path { path in
                            path.addRoundedRect(in: CGRect(x: 9, y: 8, width: 46, height: 8), cornerSize: CGSize(width: 2, height: 2))
                            path.addRect(CGRect(x: 13, y: 16, width: 3, height: 22))
                            path.addRect(CGRect(x: 48, y: 16, width: 3, height: 22))
                        }.fill(.white.opacity(0.6))
                    } else {
                        Image(systemName: lesson == .layout ? "arrow.up.left.and.arrow.down.right" : "arrow.up.and.down")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(.blue.opacity(0.6))
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: 0.09, green: 0.15, blue: 0.2))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: 2))
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 2, height: 8).padding(4) }
                        .frame(width: 34, height: 20)
                        .rotation3DEffect(.degrees(wave * 25), axis: (x: 1, y: 0, z: 0))
                        .offset(x: wave * 14, y: lesson == .hiddenSurfaces ? 17 : -wave * 17)
                }
            }
        }
    }
}

/// Continues teaching in an overlay without changing the underlying screen.
struct CapturePostScanCoachMark: View {
    let walkthrough: CaptureWalkthrough
    var body: some View {
        if let stage = walkthrough.postScanStage {
            CaptureTourCallout(number: walkthrough.postScanStep, count: walkthrough.totalSteps,
                title: stage == .preview ? "Check your scan" : "Save when you’re ready",
                detail: stage == .preview
                    ? "Drag or pinch to check the area you meant to scan. These dots are a rough preview."
                    : "You can revisit missing areas, or save your scan as it is.",
                animation: nil,
                showsSkip: true,
                nextTitle: stage == .preview ? "Next" : nil,
                hasInteracted: stage == .preview && walkthrough.inspectedPointCloud,
                nextIdentifier: "preview-tour-next", skip: walkthrough.skip,
                next: {
                    if stage == .preview { walkthrough.postScanStage = .actions }
                })
        }
    }
}

/// Warm teaching cues remain distinct from the app's blue actions.
enum CaptureTourStyle {
    static let accent = Color(red: 1, green: 0.79, blue: 0.32)
}

struct CaptureTourArrow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let movement = reduceMotion ? 0 : 3 * sin(timeline.date.timeIntervalSinceReferenceDate * 4)
            Image(systemName: "arrow.right").fontWeight(.bold).offset(x: movement)
        }.accessibilityHidden(true)
    }
}
