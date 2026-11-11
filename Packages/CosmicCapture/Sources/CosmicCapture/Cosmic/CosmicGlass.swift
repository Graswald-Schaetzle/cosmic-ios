import SwiftUI

/// The Cosmic glass panel: a dark, translucent surface with a large corner
/// radius and a hairline edge, matching the panels of the home screen and
/// the web app. Falls back to an opaque surface under Reduce Transparency
/// and Increase Contrast.
private struct CosmicGlassPanel: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Theme.card, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.3), lineWidth: 1))
        } else {
            content
                .background(Theme.glassFill, in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.border, lineWidth: 1))
        }
    }
}

extension View {
    func cosmicGlassPanel(cornerRadius: CGFloat = Theme.panelRadius) -> some View {
        modifier(CosmicGlassPanel(cornerRadius: cornerRadius))
    }
}
