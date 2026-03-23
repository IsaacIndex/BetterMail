import AppKit
import SwiftUI

internal struct ThreadSummaryDisclosureView: View {
    internal let title: String
    internal let state: ThreadSummaryState
    internal let textScale: CGFloat
    internal let onRegenerate: (() -> Void)?
    internal let isRegenerateEnabled: Bool
    @Binding internal var isExpanded: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .trailing) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack() {
                        Image(systemName: "sparkles")
                            .font(DesignTokens.font(size: 12, textScale: textScale))
                        Text(title)
                            .font(DesignTokens.font(size: 12, weight: .semibold, textScale: textScale))
                        if state.isSummarizing {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer()
                        if !state.text.isEmpty {
                            Text(state.text)
                                .font(DesignTokens.font(size: 11, textScale: textScale))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .opacity(isExpanded ? 0 : 1)
                        } else if !state.statusMessage.isEmpty {
                            Text(state.statusMessage)
                                .font(DesignTokens.font(size: 11, textScale: textScale))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.down")
                            .font(DesignTokens.font(size: 11, weight: .semibold, textScale: textScale))
                            .rotationEffect(isExpanded ? .degrees(180) : .degrees(0))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, onRegenerate == nil ? 0 : 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let onRegenerate {
                    Button(action: onRegenerate) {
                        Image(systemName: "arrow.clockwise")
                            .font(DesignTokens.font(size: 12, textScale: textScale))
                    }
                    .buttonStyle(.plain)
                    .controlSize(.mini)
                    .disabled(!isRegenerateEnabled || state.isSummarizing)
                    .accessibilityLabel(NSLocalizedString("threadcanvas.inspector.summary.regenerate",
                                                          comment: "Accessibility label for regenerating a summary"))
                    .help(NSLocalizedString("threadcanvas.inspector.summary.regenerate",
                                            comment: "Help text for regenerating a summary"))
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if !state.text.isEmpty {
                        Text(state.text)
                            .font(DesignTokens.font(size: 12, textScale: textScale))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !state.statusMessage.isEmpty {
                        Text(state.statusMessage)
                            .font(DesignTokens.font(size: 11, textScale: textScale))
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(8)
        .background(summaryBackground)
    }

    @ViewBuilder
    private var summaryBackground: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.card, style: .continuous)
        if reduceTransparency {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor))
                .overlay(shape.stroke(Color.secondary.opacity(0.2)))
        } else {
            shape
                .fill(Color.accentColor.opacity(0.08))
                .overlay(shape.stroke(Color.accentColor.opacity(0.25)))
        }
    }

}
