import SwiftUI

/// Design tokens of the capture flow. The capture flow always renders dark
/// (`CaptureFlowView` sets the colour scheme), so each token has one value.
/// Surfaces use system Liquid Glass; the accent is the shared matte silver
/// from `CosmicDesign`.
///
/// Nothing in the capture pipeline depends on these.
enum Theme {
    /// Full-screen backdrop where no camera feed is visible.
    static let background = Color(red: 0.06, green: 0.07, blue: 0.09)
    static let foreground = Color.white
    /// The Cosmic accent (matte silver).
    static let primary = CosmicDesign.accent
    static let primaryForeground = CosmicDesign.onAccent
    static let muted = Color.white.opacity(0.12)
    static let mutedForeground = Color.white.opacity(0.68)
    static let success = Color(red: 0.204, green: 0.78, blue: 0.349)
    static let destructive = CosmicDesign.destructive
    static let warning = Color(red: 1.0, green: 0.584, blue: 0.0)

    /// Radius of floating panels and windows.
    static let panelRadius: CGFloat = CosmicDesign.panelRadius
    /// Radius of cards inside a panel.
    static let cardRadius: CGFloat = 20
    /// The accessibility floor for anything tappable.
    static let minimumTapTarget: CGFloat = 44
}
