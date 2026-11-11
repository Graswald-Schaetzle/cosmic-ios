import SwiftUI

/// Design tokens of the Cosmic glass look: dark, translucent panels over the
/// camera, white text, large radii. The capture flow always renders dark
/// (`CaptureFlowView` sets the colour scheme), so each token has one value.
///
/// Nothing in the capture pipeline depends on these.
enum Theme {
    /// Full-screen backdrop where no camera feed is visible.
    static let background = Color(red: 0.06, green: 0.07, blue: 0.09)
    static let foreground = Color.white
    /// Opaque panel surface, used where transparency is reduced.
    static let card = Color(red: 0.18, green: 0.18, blue: 0.18)
    /// Tint laid over the blur material of a glass panel.
    static let glassFill = Color(red: 0.18, green: 0.18, blue: 0.18).opacity(0.52)
    /// Cosmic orange, the accent of the room chips.
    static let primary = Color(red: 1.0, green: 0.651, blue: 0.0)
    static let primaryForeground = Color(red: 0.08, green: 0.06, blue: 0.02)
    static let muted = Color.white.opacity(0.12)
    static let mutedForeground = Color.white.opacity(0.68)
    static let success = Color(red: 0.204, green: 0.78, blue: 0.349)
    static let destructive = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let warning = Color(red: 1.0, green: 0.584, blue: 0.0)
    static let border = Color.white.opacity(0.10)

    /// Radius of floating panels and windows.
    static let panelRadius: CGFloat = 32
    /// Radius of cards inside a panel.
    static let cardRadius: CGFloat = 20
    /// The accessibility floor for anything tappable.
    static let minimumTapTarget: CGFloat = 44
}
