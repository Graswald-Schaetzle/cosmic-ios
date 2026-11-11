import SwiftUI

/// Points at the real control without intercepting taps or adding another
/// VoiceOver element. Reduced motion keeps the cue visible but still.
struct CaptureTutorialPointer: View {
    enum Direction { case left, up, down, right }
    var direction: Direction = .right
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudged = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .heavy))
            .foregroundStyle(Theme.primary)
            .shadow(color: Theme.primary.opacity(0.7), radius: 5)
            .shadow(color: Theme.primary.opacity(0.3), radius: 10)
            .offset(x: horizontalOffset, y: verticalOffset)
            .frame(width: 32, height: 32)
            .onAppear { nudged = !reduceMotion }
            .onChange(of: reduceMotion) { _, reduced in nudged = !reduced }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: nudged)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch direction {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }
    private var horizontalOffset: CGFloat {
        guard nudged else { return 0 }
        return direction == .left ? -5 : direction == .right ? 5 : 0
    }
    private var verticalOffset: CGFloat {
        guard nudged else { return 0 }
        return direction == .up ? -5 : direction == .down ? 5 : 0
    }
}
