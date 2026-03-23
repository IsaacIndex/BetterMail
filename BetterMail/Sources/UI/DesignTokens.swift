import SwiftUI

// MARK: - Design Token System

/// Centralised design tokens for BetterMail's visual language.
/// Use these constants instead of magic numbers in view code.
internal enum DesignTokens {

    // MARK: - Opacity

    internal enum Opacity {
        internal static let fillLight: Double = 0.24
        internal static let fillDark: Double = 0.08

        internal static let strokeLight: Double = 0.16
        internal static let strokeDark: Double = 0.35

        internal static let shadowLight: Double = 0.12
        internal static let shadowDark: Double = 0.25

        internal static let tintLight: Double = 0.52
        internal static let tintDark: Double = 0.20

        internal static let primaryTextGlassLight: Double = 0.82
        internal static let primaryTextGlassDark: Double = 0.82

        internal static let secondaryTextGlassLight: Double = 0.62
        internal static let secondaryTextGlassDark: Double = 0.75

        /// Returns the fill opacity for the given colour scheme.
        internal static func fill(for colorScheme: ColorScheme) -> Double {
            colorScheme == .light ? fillLight : fillDark
        }

        /// Returns the stroke opacity for the given colour scheme.
        internal static func stroke(for colorScheme: ColorScheme) -> Double {
            colorScheme == .light ? strokeLight : strokeDark
        }

        /// Returns the shadow opacity for the given colour scheme.
        internal static func shadow(for colorScheme: ColorScheme) -> Double {
            colorScheme == .light ? shadowLight : shadowDark
        }

        /// Returns the tint opacity for the given colour scheme.
        internal static func tint(for colorScheme: ColorScheme) -> Double {
            colorScheme == .light ? tintLight : tintDark
        }

        /// Returns the primary-text glass opacity for the given colour scheme.
        internal static func primaryTextGlass(for colorScheme: ColorScheme) -> Double {
            colorScheme == .light ? primaryTextGlassLight : primaryTextGlassDark
        }

        /// Returns the secondary-text glass opacity for the given colour scheme.
        internal static func secondaryTextGlass(for colorScheme: ColorScheme) -> Double {
            colorScheme == .light ? secondaryTextGlassLight : secondaryTextGlassDark
        }
    }

    // MARK: - Corner Radius

    internal enum CornerRadius {
        internal static let field: CGFloat = 6
        internal static let card: CGFloat = 10
        internal static let bar: CGFloat = 14
        internal static let panel: CGFloat = 18
    }

    // MARK: - Spacing

    internal enum Spacing {
        internal static let compact: CGFloat = 8
        internal static let standard: CGFloat = 12
        internal static let comfortable: CGFloat = 16
    }

    // MARK: - Font

    /// Shared scaled-font factory. Replaces per-view `font(size:weight:)` helpers.
    /// - Parameters:
    ///   - size: Base point size before scaling.
    ///   - weight: Font weight (default `.regular`).
    ///   - textScale: Multiplier sourced from display settings.
    /// - Returns: A system font scaled by `textScale`.
    internal static func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        textScale: CGFloat
    ) -> Font {
        .system(size: size * textScale, weight: weight)
    }
}

// MARK: - Color Extensions

internal extension Color {

    /// Primary text colour for glass surfaces.
    ///
    /// When glass effects are active (macOS 26+, reduce-transparency off) it
    /// returns white at the token-defined opacity so text remains legible over
    /// translucent backgrounds. Otherwise falls back to the system primary.
    static func glassPrimary(
        colorScheme: ColorScheme,
        isGlassEnabled: Bool
    ) -> Color {
        guard isGlassEnabled else {
            return Color.primary
        }
        let opacity = DesignTokens.Opacity.primaryTextGlass(for: colorScheme)
        return Color.white.opacity(opacity)
    }

    /// Secondary text colour for glass surfaces.
    ///
    /// Follows the same logic as ``glassPrimary(colorScheme:isGlassEnabled:)``
    /// but with lower emphasis opacity values.
    static func glassSecondary(
        colorScheme: ColorScheme,
        isGlassEnabled: Bool
    ) -> Color {
        guard isGlassEnabled else {
            return Color.secondary
        }
        let opacity = DesignTokens.Opacity.secondaryTextGlass(for: colorScheme)
        return Color.white.opacity(opacity)
    }
}
