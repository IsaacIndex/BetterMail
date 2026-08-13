import SwiftUI

internal struct GraphHoverCard: View {
    internal let item: GraphHoverItem
    internal let textScale: CGFloat

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item {
            case .grouping(let grouping, _):
                Label(grouping.isSuggestion
                      ? NSLocalizedString("graph.hover.group.suggestion",
                                          comment: "Graph hover label for an AI topic suggestion")
                      : NSLocalizedString("graph.hover.group.folder",
                                          comment: "Graph hover label for a confirmed folder branch"),
                      systemImage: grouping.isSuggestion ? "sparkles" : "folder.fill")
                    .font(DesignTokens.font(size: 10.5, weight: .semibold, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.accent)
                Text(grouping.title)
                    .font(DesignTokens.font(size: 13, weight: .semibold, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                    .lineLimit(2)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("graph.hover.group.detail",
                                      comment: "Graph hover grouping branch count"),
                    grouping.memberCount
                ))
                    .font(DesignTokens.font(size: 11, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
            case .thread(let thread, _):
                metadataRow(primary: thread.mailboxPath, secondary: relativeTime(from: thread.lastUpdated))
                Text(thread.subject)
                    .font(DesignTokens.font(size: 13, weight: .semibold, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                    .lineLimit(2)
                tagRow(thread.tags)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("graph.hover.thread.detail",
                                      comment: "Graph hover card thread message count and importance"),
                    thread.messageCount,
                    thread.importance.localizedTitle
                ))
                    .font(DesignTokens.font(size: 10.5, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                Text(NSLocalizedString("graph.hover.thread.hint",
                                       comment: "Graph hover card thread interaction hint"))
                    .font(.system(size: 10.5 * textScale, design: .monospaced))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
            case .remaining(let remainingBranch, _):
                Text(remainingBranch.title)
                    .font(DesignTokens.font(size: 13, weight: .semibold, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                    .lineLimit(2)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("graph.hover.remaining.parent",
                                      comment: "Graph hover card remaining branch parent"),
                    remainingBranch.parentTitle
                ))
                    .font(DesignTokens.font(size: 10.5, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("graph.hover.remaining.detail",
                                      comment: "Graph hover card remaining branches detail"),
                    remainingBranch.nextBatchCount
                ))
                    .font(DesignTokens.font(size: 11, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
            case .message(let message, _):
                metadataRow(primary: message.sender, secondary: relativeTime(from: message.date))
                Text(message.subject)
                    .font(DesignTokens.font(size: 11, weight: .semibold, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                    .lineLimit(2)
                Text(messageHoverText(message))
                    .font(DesignTokens.font(size: 12.5, weight: .medium, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                    .lineLimit(4)
                tagRow(message.tags)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignTokens.Graph.AppTheme.panel)
                .shadow(color: Color.black.opacity(0.14), radius: 24, x: 0, y: 16)
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
    }

    private func messageHoverText(_ message: GraphMessage) -> String {
        let summary = message.summaryPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            return summary
        }
        return message.snippet.isEmpty ? message.subject : message.snippet
    }

    private func metadataRow(primary: String, secondary: String) -> some View {
        HStack(spacing: 6) {
            Text(primary.isEmpty
                 ? NSLocalizedString("graph.hover.mailbox.fallback",
                                      comment: "Fallback mailbox label in graph hover card")
                 : primary)
                .lineLimit(1)
            Text("·")
            Text(secondary)
                .lineLimit(1)
        }
        .font(.system(size: 10.5 * textScale, design: .monospaced))
        .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
    }

    @ViewBuilder
    private func tagRow(_ tags: [String]) -> some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .font(DesignTokens.font(size: 10, weight: .medium, textScale: textScale))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(DesignTokens.Graph.AppTheme.accentSoft))
                        .foregroundStyle(DesignTokens.Graph.AppTheme.accent)
                }
            }
        }
    }

    private func relativeTime(from date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 3_600 {
            return String.localizedStringWithFormat(
                NSLocalizedString("graph.hover.time.minutes",
                                  comment: "Graph hover relative time in minutes"),
                max(1, Int(seconds / 60))
            )
        }
        if seconds < 86_400 {
            return String.localizedStringWithFormat(
                NSLocalizedString("graph.hover.time.hours",
                                  comment: "Graph hover relative time in hours"),
                Int(seconds / 3_600)
            )
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("graph.hover.time.days",
                              comment: "Graph hover relative time in days"),
            Int(seconds / 86_400)
        )
    }
}
