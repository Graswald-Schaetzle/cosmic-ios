import SwiftUI

/// Native glass for floating controls over the camera, with an opaque
/// fallback for Reduce Transparency and Increase Contrast.
private struct GlassControlBackground<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Theme.card, in: shape)
                .overlay(shape.stroke(Theme.border, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            // Pre-26 native equivalent. Still a system material, not a hand-rolled blur.
            content.background(tint == nil ? .thinMaterial : .regularMaterial, in: shape)
        }
    }
}

extension View {
    /// A `tint` keeps labels legible when bright content scrolls under the glass.
    func glassControlBackground(in shape: some Shape, tint: Color? = nil) -> some View {
        modifier(GlassControlBackground(shape: shape, tint: tint))
    }
}
