import AppKit
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

    // MARK: - Font Size

    internal enum FontSize {
        internal static let panelTitle: CGFloat = 13
        internal static let sectionTitle: CGFloat = 15
        internal static let bodyPrimary: CGFloat = 13
        internal static let bodySecondary: CGFloat = 12
        internal static let caption: CGFloat = 11
        internal static let micro: CGFloat = 9
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

    // MARK: - Graph View

    internal enum Graph {
        internal static let background = Color(hex: 0xFAFAF8)
        internal static let panel = Color(hex: 0xFFFFFF)
        internal static let panelSecondary = Color(hex: 0xF5F5F2)
        internal static let line = Color(hex: 0xECECE7)
        internal static let ink = Color(hex: 0x16181D)
        internal static let inkSecondary = Color(hex: 0x5A5E68)
        internal static let inkTertiary = Color(hex: 0x8C8F98)
        internal static let inkQuinary = Color(hex: 0xB8BAC0)
        internal static let accent = Color(hex: 0x4F46E5)
        internal static let accentSoft = Color(hex: 0xEEF0FF)
        internal static let snip = Color(hex: 0xB45A3C)
        internal static let snipSoft = Color(hex: 0xFBEFE8)
        internal static let archive = Color(hex: 0x6B7280)
        internal static let archiveSoft = Color(hex: 0xF1F2F4)
        internal static let live = Color(hex: 0x0EA5A4)
        internal static let water = Color(hex: 0x14B8A6)

        internal enum Botanical {
            internal static let edge = Color(hex: 0xA6B098)
            internal static let trunk = Color(hex: 0x6B7A5C)
            internal static let message = Color(hex: 0x7A8F66)
            internal static let highThreadStroke = Color(hex: 0x4A5640)

            internal static let edgeNS = NSColor(hex: 0xA6B098)
            internal static let trunkNS = NSColor(hex: 0x6B7A5C)
            internal static let messageNS = NSColor(hex: 0x7A8F66)
            internal static let highThreadStrokeNS = NSColor(hex: 0x4A5640)
        }

        internal enum AppTheme {
            internal struct Palette: Equatable {
                internal let isDark: Bool

                internal var backgroundNS: NSColor { isDark ? NSColor(hex: 0x15161A) : NSColor(hex: 0xFAFAF8) }
                internal var panelNS: NSColor { isDark ? NSColor(hex: 0x202229) : NSColor(hex: 0xFFFFFF) }
                internal var panelSecondaryNS: NSColor { isDark ? NSColor(hex: 0x2A2D35) : NSColor(hex: 0xF5F5F2) }
                internal var lineNS: NSColor { isDark ? NSColor(hex: 0x3A3D45) : NSColor(hex: 0xECECE7) }
                internal var inkNS: NSColor { isDark ? NSColor(hex: 0xF4F5F7) : NSColor(hex: 0x16181D) }
                internal var inkSecondaryNS: NSColor { isDark ? NSColor(hex: 0xC4C8D0) : NSColor(hex: 0x5A5E68) }
                internal var inkTertiaryNS: NSColor { isDark ? NSColor(hex: 0x969CA8) : NSColor(hex: 0x8C8F98) }
                internal var inkQuaternaryNS: NSColor { isDark ? NSColor(hex: 0x707784) : NSColor(hex: 0xB8BAC0) }
                internal var accentNS: NSColor { isDark ? NSColor(hex: 0x8B86FF) : NSColor(hex: 0x4F46E5) }
                internal var accentSoftNS: NSColor { isDark ? NSColor(hex: 0x2D2B54) : NSColor(hex: 0xEEF0FF) }
                internal var manualThreadNS: NSColor { isDark ? NSColor(hex: 0xFF7676) : NSColor(hex: 0xC53030) }
                internal var snipNS: NSColor { isDark ? NSColor(hex: 0xE09172) : NSColor(hex: 0xB45A3C) }
                internal var snipSoftNS: NSColor { isDark ? NSColor(hex: 0x3A241F) : NSColor(hex: 0xFBEFE8) }
                internal var archiveNS: NSColor { isDark ? NSColor(hex: 0xA8AFBA) : NSColor(hex: 0x6B7280) }
                internal var archiveSoftNS: NSColor { isDark ? NSColor(hex: 0x2D3038) : NSColor(hex: 0xF1F2F4) }
                internal var liveNS: NSColor { isDark ? NSColor(hex: 0x43D4D2) : NSColor(hex: 0x0EA5A4) }
                internal var waterNS: NSColor { isDark ? NSColor(hex: 0x4BE0CF) : NSColor(hex: 0x14B8A6) }
            }

            internal static func palette(for colorScheme: ColorScheme) -> Palette {
                Palette(isDark: colorScheme == .dark)
            }

            internal static var background: Color { Color(nsColor: backgroundNS) }
            internal static var panel: Color { Color(nsColor: panelNS) }
            internal static var panelSecondary: Color { Color(nsColor: panelSecondaryNS) }
            internal static var line: Color { Color(nsColor: lineNS) }
            internal static var ink: Color { Color(nsColor: inkNS) }
            internal static var inkSecondary: Color { Color(nsColor: inkSecondaryNS) }
            internal static var inkTertiary: Color { Color(nsColor: inkTertiaryNS) }
            internal static var inkQuaternary: Color { Color(nsColor: inkQuaternaryNS) }
            internal static var accent: Color { Color(nsColor: accentNS) }
            internal static var accentSoft: Color { Color(nsColor: accentSoftNS) }
            internal static var manualThread: Color { Color(nsColor: manualThreadNS) }
            internal static var snip: Color { Color(nsColor: snipNS) }
            internal static var snipSoft: Color { Color(nsColor: snipSoftNS) }
            internal static var archive: Color { Color(nsColor: archiveNS) }
            internal static var archiveSoft: Color { Color(nsColor: archiveSoftNS) }
            internal static var live: Color { Color(nsColor: liveNS) }
            internal static var water: Color { Color(nsColor: waterNS) }

            internal static let backgroundNS = dynamicColor(light: NSColor(hex: 0xFAFAF8),
                                                            dark: NSColor(hex: 0x15161A))
            internal static let panelNS = dynamicColor(light: NSColor(hex: 0xFFFFFF),
                                                       dark: NSColor(hex: 0x202229))
            internal static let panelSecondaryNS = dynamicColor(light: NSColor(hex: 0xF5F5F2),
                                                                dark: NSColor(hex: 0x2A2D35))
            internal static let lineNS = dynamicColor(light: NSColor(hex: 0xECECE7),
                                                      dark: NSColor(hex: 0x3A3D45))
            internal static let inkNS = dynamicColor(light: NSColor(hex: 0x16181D),
                                                     dark: NSColor(hex: 0xF4F5F7))
            internal static let inkSecondaryNS = dynamicColor(light: NSColor(hex: 0x5A5E68),
                                                              dark: NSColor(hex: 0xC4C8D0))
            internal static let inkTertiaryNS = dynamicColor(light: NSColor(hex: 0x8C8F98),
                                                             dark: NSColor(hex: 0x969CA8))
            internal static let inkQuaternaryNS = dynamicColor(light: NSColor(hex: 0xB8BAC0),
                                                               dark: NSColor(hex: 0x707784))
            internal static let accentNS = dynamicColor(light: NSColor(hex: 0x4F46E5),
                                                        dark: NSColor(hex: 0x8B86FF))
            internal static let accentSoftNS = dynamicColor(light: NSColor(hex: 0xEEF0FF),
                                                            dark: NSColor(hex: 0x2D2B54))
            internal static let manualThreadNS = dynamicColor(light: NSColor(hex: 0xC53030),
                                                              dark: NSColor(hex: 0xFF7676))
            internal static let snipNS = dynamicColor(light: NSColor(hex: 0xB45A3C),
                                                      dark: NSColor(hex: 0xE09172))
            internal static let snipSoftNS = dynamicColor(light: NSColor(hex: 0xFBEFE8),
                                                          dark: NSColor(hex: 0x3A241F))
            internal static let archiveNS = dynamicColor(light: NSColor(hex: 0x6B7280),
                                                         dark: NSColor(hex: 0xA8AFBA))
            internal static let archiveSoftNS = dynamicColor(light: NSColor(hex: 0xF1F2F4),
                                                             dark: NSColor(hex: 0x2D3038))
            internal static let liveNS = dynamicColor(light: NSColor(hex: 0x0EA5A4),
                                                      dark: NSColor(hex: 0x43D4D2))
            internal static let waterNS = dynamicColor(light: NSColor(hex: 0x14B8A6),
                                                       dark: NSColor(hex: 0x4BE0CF))

            private static func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
                NSColor(name: nil) { appearance in
                    let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                    return match == .darkAqua ? dark : light
                }
            }
        }

        internal static let backgroundNS = NSColor(hex: 0xFAFAF8)
        internal static let panelNS = NSColor(hex: 0xFFFFFF)
        internal static let lineNS = NSColor(hex: 0xECECE7)
        internal static let inkNS = NSColor(hex: 0x16181D)
        internal static let inkSecondaryNS = NSColor(hex: 0x5A5E68)
        internal static let inkTertiaryNS = NSColor(hex: 0x8C8F98)
        internal static let inkQuinaryNS = NSColor(hex: 0xB8BAC0)
        internal static let accentNS = NSColor(hex: 0x4F46E5)
        internal static let accentSoftNS = NSColor(hex: 0xEEF0FF)
        internal static let manualThreadNS = NSColor(hex: 0xC53030)
        internal static let snipNS = NSColor(hex: 0xB45A3C)
        internal static let snipSoftNS = NSColor(hex: 0xFBEFE8)
        internal static let archiveNS = NSColor(hex: 0x6B7280)
        internal static let archiveSoftNS = NSColor(hex: 0xF1F2F4)
        internal static let liveNS = NSColor(hex: 0x0EA5A4)
        internal static let waterNS = NSColor(hex: 0x14B8A6)
    }
}

// MARK: - Color Extensions

internal extension Color {
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }

    /// Primary text colour for glass surfaces.
    ///
    /// When glass effects are active (macOS 26+, reduce-transparency off) it
    /// returns a high-contrast colour appropriate for the colour scheme so text
    /// remains legible over translucent backgrounds. Otherwise falls back to the
    /// system primary.
    static func glassPrimary(
        colorScheme: ColorScheme,
        isGlassEnabled: Bool
    ) -> Color {
        guard isGlassEnabled else {
            return Color.primary
        }
        let opacity = DesignTokens.Opacity.primaryTextGlass(for: colorScheme)
        if colorScheme == .light {
            return Color.black.opacity(opacity)
        }
        return Color.white
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
        if colorScheme == .light {
            return Color.black.opacity(opacity)
        }
        return Color.white.opacity(opacity)
    }
}

internal extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
