import AppKit
import SwiftUI

internal struct GlassBackground: View {
    internal let cornerRadius: CGFloat
    internal let fillOpacity: Double
    internal let strokeOpacity: Double

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    internal var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        baseFill(shape: shape)
            .overlay(
                shape
                    .strokeBorder(Color.white.opacity(reduceTransparency ? 0.35 : strokeOpacity))
            )
    }

    private var solidFill: Color {
        Color(nsColor: NSColor.windowBackgroundColor).opacity(fillOpacity)
    }

    @ViewBuilder
    private func baseFill(shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            shape.fill(solidFill)
        } else if #available(macOS 26, *) {
            shape
                .fill(Color.clear)
                .glassEffect(
                    .regular.tint(Color.white.opacity(fillOpacity * 0.2)),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            shape.fill(solidFill)
        }
    }
}

internal struct GlassWindowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    internal var body: some View {
        baseFill
    }

    @ViewBuilder
    private var baseFill: some View {
        if reduceTransparency {
            Rectangle().fill(Color(nsColor: NSColor.windowBackgroundColor))
        } else if #available(macOS 26, *) {
            Rectangle()
                .fill(Color(nsColor: NSColor.windowBackgroundColor))
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.06),
                            Color.black.opacity(0.08)
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
