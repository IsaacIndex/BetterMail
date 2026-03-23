import AppKit
import SwiftUI

/// A unified glass-morphism background that adapts to macOS 26+ glass effects,
/// reduce-transparency settings, and colour scheme. Replaces the per-view
/// three-branch patterns previously duplicated across nav bar, inspector, and
/// selection action bar backgrounds.
internal struct GlassBackground: View {
    internal let cornerRadius: CGFloat
    internal let fillOpacity: Double
    internal let strokeOpacity: Double
    internal let shadowOpacity: Double?
    internal let shadowRadius: CGFloat
    internal let shadowY: CGFloat
    internal let tintOpacity: Double?
    internal let isInteractive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    internal init(
        cornerRadius: CGFloat,
        fillOpacity: Double,
        strokeOpacity: Double,
        shadowOpacity: Double? = nil,
        shadowRadius: CGFloat = 0,
        shadowY: CGFloat = 0,
        tintOpacity: Double? = nil,
        isInteractive: Bool = false
    ) {
        self.cornerRadius = cornerRadius
        self.fillOpacity = fillOpacity
        self.strokeOpacity = strokeOpacity
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
        self.shadowY = shadowY
        self.tintOpacity = tintOpacity
        self.isInteractive = isInteractive
    }

    internal var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        baseFill(shape: shape)
            .overlay(
                shape
                    .stroke(strokeColor)
            )
            .modifier(ShadowModifier(opacity: resolvedShadowOpacity, radius: shadowRadius, y: shadowY))
    }

    // MARK: - Private

    private var strokeColor: Color {
        if colorScheme == .light {
            return Color.black.opacity(strokeOpacity)
        }
        return Color.white.opacity(strokeOpacity)
    }

    private var resolvedShadowOpacity: Double {
        guard let override = shadowOpacity else { return 0 }
        return override
    }

    private var solidFill: Color {
        Color(nsColor: NSColor.windowBackgroundColor).opacity(fillOpacity)
    }

    private var resolvedTintOpacity: Double {
        if let override = tintOpacity {
            return override
        }
        return fillOpacity * 0.2
    }

    @ViewBuilder
    private func baseFill(shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            shape.fill(solidFill)
        } else if #available(macOS 26, *) {
            glassView(shape: shape)
        } else {
            shape.fill(solidFill)
        }
    }

    @available(macOS 26, *)
    @ViewBuilder
    private func glassView(shape: RoundedRectangle) -> some View {
        let tint = Color.white.opacity(resolvedTintOpacity)
        if isInteractive {
            shape
                .fill(Color.white.opacity(fillOpacity))
                .glassEffect(
                    .regular
                        .tint(tint)
                        .interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            shape
                .fill(Color.white.opacity(fillOpacity))
                .glassEffect(
                    .regular
                        .tint(tint),
                    in: .rect(cornerRadius: cornerRadius)
                )
        }
    }
}

/// Applies a shadow only when opacity is greater than zero, avoiding unnecessary
/// compositing work.
private struct ShadowModifier: ViewModifier {
    let opacity: Double
    let radius: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        if opacity > 0 {
            content.shadow(color: Color.black.opacity(opacity), radius: radius, y: y)
        } else {
            content
        }
    }
}

internal struct GlassWindowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    internal var body: some View {
        baseFill
    }

    @ViewBuilder
    private var baseFill: some View {
        if reduceTransparency {
            Rectangle().fill(Color(nsColor: NSColor.windowBackgroundColor))
        } else if #available(macOS 26, *) {
            let topOpacity = colorScheme == .light ? 0.1 : 0.06
            let bottomOpacity = colorScheme == .light ? 0.03 : 0.08
            Rectangle()
                .fill(Color(nsColor: NSColor.windowBackgroundColor))
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(topOpacity),
                            Color.black.opacity(bottomOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        } else {
            Rectangle().fill(Color(nsColor: NSColor.windowBackgroundColor))
        }
    }
}
