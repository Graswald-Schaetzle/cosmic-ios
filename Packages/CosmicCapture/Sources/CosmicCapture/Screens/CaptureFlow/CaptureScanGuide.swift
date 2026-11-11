import SwiftUI

/// Which surface the user is working on. Selecting a pass only changes the
/// advice; it never asserts that a surface is complete.
enum CaptureScanPass: String, CaseIterable, Identifiable {
    case walls = "Walls"
    case ceiling = "Ceiling"
    case floor = "Floor"

    var id: Self { self }

    func isOpposite(to aim: CaptureAim) -> Bool {
        switch (self, aim) {
        case (.ceiling, .down), (.floor, .up), (.walls, .up), (.walls, .down): true
        default: false
        }
    }

    func matches(_ aim: CaptureAim) -> Bool {
        switch (self, aim) {
        case (.ceiling, .up), (.floor, .down), (.walls, .level): true
        default: false
        }
    }

    func instruction(aim: CaptureAim?) -> String {
        switch (self, aim) {
        case (.ceiling, .up): "Move along the ceiling"
        case (.floor, .down): "Scan the floor"
        case (.walls, .up): "Tilt down toward the walls"
        case (.walls, .down): "Tilt up toward the walls"
        default: instruction
        }
    }

    func symbol(aim: CaptureAim?) -> String {
        switch (self, aim) {
        case (.ceiling, .up), (.floor, .down): "arrow.left.and.right"
        case (.walls, .up): "arrow.down"
        case (.walls, .down): "arrow.up"
        default: symbol
        }
    }

    var symbol: String {
        switch self {
        case .walls: "arrow.left.and.right"
        case .ceiling: "arrow.up"
        case .floor: "arrow.down"
        }
    }

    var instruction: String {
        switch self {
        case .walls: "Scan along the wall"
        case .ceiling: "Tilt up and sweep the ceiling"
        case .floor: "Scan the floor"
        }
    }

    var detail: String {
        switch self {
        case .walls:
            "Focus first on one part of the room and include its corners. Then move on to the next part."
        case .ceiling:
            "Keep the top of a wall in view. Move along it to capture the ceiling from different spots."
        case .floor:
            "Keep the bottom of a wall in view. Move around furniture to capture the floor beyond it."
        }
    }
}

/// A correction can pass through level on the way from floor to ceiling.
/// Changing the selected pass or interrupting guidance clears that history.
struct CaptureAimFeedback {
    enum Style: Equatable { case neutral, correcting, corrected }
    private var pass: CaptureScanPass?
    private var needsCorrection = false

    mutating func update(pass: CaptureScanPass, aim: CaptureAim?, eligible: Bool) -> Style {
        guard eligible, let aim else {
            self = Self()
            return .neutral
        }
        if self.pass != pass {
            self.pass = pass
            needsCorrection = false
        }
        if pass.isOpposite(to: aim) {
            needsCorrection = true
            return .correcting
        }
        if needsCorrection, pass.matches(aim) {
            needsCorrection = false
            return .corrected
        }
        return needsCorrection ? .correcting : .neutral
    }
}

/// The live coaching card. The arbiter's message, when present, owns the one
/// instruction slot; otherwise the card shows the selected pass's advice and
/// colours it when the camera aims away from that surface.
struct CaptureScanGuide: View {
    @Binding var selectedPass: CaptureScanPass
    @Binding var isExpanded: Bool
    let guidance: CaptureGuidance?
    let aim: CaptureAim?
    let isSampling: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var feedback = CaptureAimFeedback()
    @State private var feedbackStyle: CaptureAimFeedback.Style = .neutral

    private struct FeedbackInput: Equatable {
        let pass: CaptureScanPass
        let aim: CaptureAim?
        let eligible: Bool
    }

    private var feedbackInput: FeedbackInput {
        FeedbackInput(pass: selectedPass, aim: aim, eligible: isSampling && guidance == nil)
    }

    private var isAlert: Bool {
        guidance.map { $0.isUrgentStyle || $0.severity >= .warning } ?? false
    }

    private var cueColor: Color {
        guard guidance == nil else { return isAlert ? .yellow : .white }
        switch feedbackStyle {
        case .neutral: return .white
        case .correcting: return Color(red: 1, green: 0.75, blue: 0.25)
        case .corrected: return Color(red: 0.45, green: 0.95, blue: 0.65)
        }
    }

    private var instruction: String {
        if let guidance { return guidance.message }
        if feedbackStyle == .corrected { return "Good angle. Keep moving" }
        return selectedPass.instruction(aim: feedbackInput.eligible ? aim : nil)
    }

    private var symbol: String {
        if guidance != nil {
            return isAlert ? "exclamationmark.triangle.fill" : "viewfinder"
        }
        return selectedPass.symbol(aim: feedbackInput.eligible ? aim : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(cueColor)
                    .symbolEffect(
                        .pulse,
                        options: .repeating,
                        isActive: feedbackStyle == .correcting && !reduceMotion
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(instruction)
                        .font(.headline)
                        .foregroundStyle(cueColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capture-guide-instruction")
                    if isExpanded, guidance == nil {
                        Text(selectedPass.detail)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(isAlert ? 0.5 : 0.16), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: feedbackStyle)
        .task(id: feedbackInput) {
            feedbackStyle = feedback.update(
                pass: selectedPass, aim: aim, eligible: feedbackInput.eligible
            )
            guard feedbackStyle == .corrected else { return }
            do {
                try await Task.sleep(for: .seconds(1.4))
                feedbackStyle = .neutral
            } catch {
                // A newer pose, selection, or warning cancels this confirmation.
            }
        }
        .onChange(of: instruction) { _, instruction in
            guard UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: instruction)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Surface", selection: $selectedPass) {
                ForEach(CaptureScanPass.allCases) { pass in
                    Text(pass.rawValue).tag(pass)
                }
            }
            .pickerStyle(.segmented)
            .colorScheme(.dark)
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "info.circle")
                    .font(.body.weight(.semibold))
                    .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide tips" : "Show tips")
        }
    }
}
