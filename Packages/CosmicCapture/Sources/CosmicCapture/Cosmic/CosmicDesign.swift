import SwiftUI

/// Design tokens shared by the app and the capture flow (iOS 26, Liquid Glass).
///
/// The look is neutral: system glass for every surface, white and grey text,
/// and a single matte silver accent on the one dominant control of a screen
/// (primary button, scan button, selected tab). Colour beyond that only
/// carries meaning (errors, the recording dot).
public enum CosmicDesign {
    /// Matte silver, top to bottom. No specular band: it should read as
    /// brushed metal, not chrome.
    public static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.925, green: 0.933, blue: 0.945), // #ECEEF1
                Color(red: 0.851, green: 0.863, blue: 0.878), // #D9DCE0
                Color(red: 0.796, green: 0.812, blue: 0.831)  // #CBCFD4
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Flat stand-in for the gradient: tints, icons, progress.
    public static let accent = Color(red: 0.851, green: 0.863, blue: 0.878)
    /// Text and symbols placed on the silver accent.
    public static let onAccent = Color(red: 0.09, green: 0.094, blue: 0.106)

    public static let destructive = Color(red: 1.0, green: 0.42, blue: 0.42)
    public static let secondaryText = Color.white.opacity(0.6)

    public static let panelRadius: CGFloat = 32
    public static let cardRadius: CGFloat = 24
    public static let minimumTapTarget: CGFloat = 44
}

/// The one dominant action on a screen: a silver capsule with dark text.
public struct CosmicPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(CosmicDesign.onAccent)
            // minHeight, not height: the label has to be free to grow with Dynamic Type.
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 20)
            .background(CosmicDesign.accentGradient, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A quieter action that must not compete with the primary one: plain glass.
public struct CosmicSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: CosmicDesign.minimumTapTarget)
            .padding(.horizontal, 20)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension ButtonStyle where Self == CosmicPrimaryButtonStyle {
    public static var cosmicPrimary: CosmicPrimaryButtonStyle { CosmicPrimaryButtonStyle() }
}

extension ButtonStyle where Self == CosmicSecondaryButtonStyle {
    public static var cosmicSecondary: CosmicSecondaryButtonStyle { CosmicSecondaryButtonStyle() }
}

extension View {
    /// A floating Cosmic panel: system Liquid Glass with the panel radius.
    /// Reduce Transparency and Increase Contrast are handled by the system.
    public func cosmicGlassPanel(cornerRadius: CGFloat = CosmicDesign.panelRadius) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
