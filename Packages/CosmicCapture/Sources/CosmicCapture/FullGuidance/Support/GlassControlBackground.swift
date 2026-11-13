import SwiftUI

/// Native Liquid Glass for floating controls over the camera. Reduce
/// Transparency and Increase Contrast are handled by the system material.
private struct GlassControlBackground<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?

    func body(content: Content) -> some View {
        content.glassEffect(.regular.tint(tint).interactive(), in: shape)
    }
}

extension View {
    /// A `tint` keeps labels legible when bright content scrolls under the glass.
    func glassControlBackground(in shape: some Shape, tint: Color? = nil) -> some View {
        modifier(GlassControlBackground(shape: shape, tint: tint))
    }
}
