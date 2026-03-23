import SwiftUI

/// A compact minimap overlay that shows all thread nodes across folders as colored dots.
/// Positioned at the bottom-leading corner of the canvas for persistent spatial awareness.
internal struct GlobalMinimapOverlay: View {
    internal let folders: [GlobalMinimapFolder]
    internal let viewportRect: CGRect?

    @State private var isHovered = false

    private let minimapWidth: CGFloat = 120
    private let minimapHeight: CGFloat = 80

    internal var body: some View {
        if !folders.isEmpty {
            Canvas { context, size in
                drawBackground(context: &context, size: size)
                drawNodes(context: &context, size: size)
                drawViewport(context: &context, size: size)
            }
            .frame(width: minimapWidth, height: minimapHeight)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15))
            )
            .opacity(isHovered ? 1.0 : 0.5)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
            .padding(.leading, DesignTokens.Spacing.comfortable)
            .padding(.bottom, DesignTokens.Spacing.comfortable)
            .allowsHitTesting(true)
        }
    }

    private func drawBackground(context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(roundedRect: rect, cornerRadius: DesignTokens.CornerRadius.card),
                     with: .color(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.9)))
    }

    private func drawNodes(context: inout GraphicsContext, size: CGSize) {
        let dotRadius: CGFloat = 2.0
        for folder in folders {
            let color = Color(red: folder.color.red, green: folder.color.green, blue: folder.color.blue)
            for node in folder.nodes {
                let x = node.normalizedX * size.width
                let y = node.normalizedY * size.height
                let rect = CGRect(x: x - dotRadius, y: y - dotRadius,
                                  width: dotRadius * 2, height: dotRadius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.85)))
            }
        }
    }

    private func drawViewport(context: inout GraphicsContext, size: CGSize) {
        guard let viewport = viewportRect else { return }
        let rect = CGRect(
            x: viewport.origin.x * size.width,
            y: viewport.origin.y * size.height,
            width: viewport.width * size.width,
            height: viewport.height * size.height
        )
        context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.12)))
        context.stroke(Path(rect), with: .color(Color.accentColor.opacity(0.6)), lineWidth: 1)
    }
}

/// Data for a single folder in the global minimap.
internal struct GlobalMinimapFolder: Identifiable {
    internal let id: String
    internal let color: GlobalMinimapColor
    internal let nodes: [GlobalMinimapNode]
}

/// A simplified color representation for minimap dots.
internal struct GlobalMinimapColor {
    internal let red: Double
    internal let green: Double
    internal let blue: Double
}

/// A single node position in the global minimap (normalized 0-1).
internal struct GlobalMinimapNode {
    internal let normalizedX: CGFloat
    internal let normalizedY: CGFloat
}
