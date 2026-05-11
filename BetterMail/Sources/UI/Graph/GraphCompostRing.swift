import SwiftUI

internal struct GraphCompostRing: View {
    internal let entries: [GraphCompostEntry]
    internal let textScale: CGFloat
    internal let onRestore: (GraphCompostEntry) -> Void

    internal var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                Text(NSLocalizedString("graph.compost.title", comment: "Graph compost panel title"))
                    .font(.system(size: 10.5 * textScale, design: .monospaced))
                    .foregroundStyle(DesignTokens.Graph.inkTertiary)
                FlowLayout(items: entries) { entry in
                    Button {
                        onRestore(entry)
                    } label: {
                        HStack(spacing: 5) {
                            Text(entry.action == .snip ? "✂" : "⏚")
                            Text(entry.subject)
                                .lineLimit(1)
                                .frame(maxWidth: 130, alignment: .leading)
                        }
                        .font(DesignTokens.font(size: 11, weight: .semibold, textScale: textScale))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(entry.action == .snip ? DesignTokens.Graph.snip : DesignTokens.Graph.archive)
                        .background(
                            Capsule()
                                .fill(entry.action == .snip ? DesignTokens.Graph.snipSoft : DesignTokens.Graph.archiveSoft)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.graphCompostRingChip(entry.id))
                    .accessibilityLabel(String.localizedStringWithFormat(
                        NSLocalizedString("graph.compost.restore.accessibility",
                                          comment: "Accessibility label for graph compost restore chip"),
                        entry.subject
                    ))
                }
            }
            .padding(10)
            .frame(maxWidth: 280, alignment: .trailing)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DesignTokens.Graph.panel.opacity(0.96))
                    .shadow(color: Color.black.opacity(0.10), radius: 16, x: 0, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(DesignTokens.Graph.line, lineWidth: 1)
            )
            .accessibilityIdentifier(AccessibilityID.graphCompostRing)
        }
    }
}

private struct FlowLayout<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .trailing, spacing: 6) {
            ForEach(items) { item in
                content(item)
            }
        }
    }
}
