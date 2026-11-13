import SwiftUI

/// The glass look of the capture flow for screens of the host app: always
/// dark, translucent panels with a 32 pt radius, white capsule buttons and
/// the orange accent.
public enum CosmicGlass {
    public static let accent = Theme.primary
    public static let background = Theme.background
    public static let foreground = Theme.foreground
    public static let mutedForeground = Theme.mutedForeground
    public static let muted = Theme.muted
    public static let success = Theme.success
    public static let destructive = Theme.destructive
    public static let warning = Theme.warning
    public static let panelRadius = Theme.panelRadius
    public static let cardRadius = Theme.cardRadius
}

/// The one dominant action on a screen: a white capsule.
public struct CosmicPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryActionButtonStyle().makeBody(configuration: configuration)
    }
}

/// A quieter action next to the primary one.
public struct CosmicSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SecondaryActionButtonStyle().makeBody(configuration: configuration)
    }
}

extension View {
    /// A dark, translucent panel with a hairline edge.
    public func cosmicPanel(cornerRadius: CGFloat = CosmicGlass.panelRadius) -> some View {
        cosmicGlassPanel(cornerRadius: cornerRadius)
    }
}
