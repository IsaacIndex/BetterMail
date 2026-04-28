import AppKit
import SwiftUI

internal struct ThreadInspectorView: View {
    internal let node: ThreadNode?
    internal let summaryState: ThreadSummaryState?
    internal let summaryExpansion: Binding<Bool>?
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    internal let textScale: CGFloat
    internal let openInMailState: OpenInMailState?
    internal let canRegenerateSummary: Bool
    internal let onRegenerateSummary: (() -> Void)?
    internal let onOpenInMail: (ThreadNode) -> Void
    internal let onCopyOpenInMailText: (String) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var isCopyToastVisible = false
    @State private var copyToastMessage = ""
    @State private var copyToastHideWorkItem: DispatchWorkItem?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("threadcanvas.inspector.title", comment: "Title for the inspector panel"))
                .font(DesignTokens.font(size: 13, weight: .semibold, textScale: textScale))

            Divider()

            if let node {
                ScrollView {
                    details(for: node)
                }
            } else {
                emptyState
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(inspectorPrimaryForegroundStyle)
        .shadow(color: Color.black.opacity(isGlassInspectorEnabled ? (colorScheme == .light ? 0.14 : 0.35) : 0),
                radius: 1.2,
                x: 0,
                y: 1)
        .background(inspectorBackground)
        .overlay(alignment: .bottom) {
            copyToast
        }
        .accessibilityIdentifier(AccessibilityID.threadInspector)
        .accessibilityLabel(NSLocalizedString("threadcanvas.inspector.title",
                                              comment: "Title for the inspector panel"))
    }

    @ViewBuilder
    private func details(for node: ThreadNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(subjectText(for: node))
                .font(DesignTokens.font(size: 15, weight: .semibold, textScale: textScale))
                .fixedSize(horizontal: false, vertical: true)

            if node.message.isUnread {
                Label(NSLocalizedString("threadcanvas.inspector.unread", comment: "Unread indicator"), systemImage: "circle.fill")
                    .font(DesignTokens.font(size: 12, textScale: textScale))
                    .foregroundStyle(Color.accentColor)
            }

            if let summaryState, let summaryExpansion {
                ThreadSummaryDisclosureView(title: NSLocalizedString("threadcanvas.inspector.summary.title",
                                                                     comment: "Title for the thread summary disclosure in the inspector"),
                                             state: summaryState,
                                             textScale: textScale,
                                             onRegenerate: onRegenerateSummary,
                                             isRegenerateEnabled: canRegenerateSummary,
                                             isExpanded: summaryExpansion)
            }

            InspectorField(label: NSLocalizedString("threadcanvas.inspector.from", comment: "From label"),
                           value: node.message.from,
                           textScale: textScale)
            InspectorField(label: NSLocalizedString("threadcanvas.inspector.to", comment: "To label"),
                           value: node.message.to,
                           textScale: textScale)
            InspectorField(label: NSLocalizedString("threadcanvas.inspector.date", comment: "Date label"),
                           value: Self.dateFormatter.string(from: node.message.date),
                           textScale: textScale)

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("threadcanvas.inspector.snippet", comment: "Snippet label"))
                    .font(DesignTokens.font(size: 12, textScale: textScale))
                    .foregroundStyle(inspectorSecondaryForegroundStyle)
                Text(snippetText(for: node))
                    .font(DesignTokens.font(size: 13, textScale: textScale))
                    .fixedSize(horizontal: false, vertical: true)
            }

            openInMailButton(for: node)
            openInMailStatus(for: node)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(NSLocalizedString("threadcanvas.inspector.empty", comment: "Empty inspector placeholder"))
                .foregroundStyle(inspectorSecondaryForegroundStyle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var isGlassInspectorEnabled: Bool {
        if #available(macOS 26, *) {
            return !reduceTransparency
        }
        return false
    }

    private var inspectorPrimaryForegroundStyle: Color {
        Color.glassPrimary(colorScheme: colorScheme, isGlassEnabled: isGlassInspectorEnabled)
    }

    private var inspectorSecondaryForegroundStyle: Color {
        Color.glassSecondary(colorScheme: colorScheme, isGlassEnabled: isGlassInspectorEnabled)
    }

    private var inspectorBackground: some View {
        GlassBackground(
            cornerRadius: DesignTokens.CornerRadius.panel,
            fillOpacity: DesignTokens.Opacity.fill(for: colorScheme),
            strokeOpacity: DesignTokens.Opacity.stroke(for: colorScheme),
            shadowOpacity: DesignTokens.Opacity.shadow(for: colorScheme),
            shadowRadius: 16,
            shadowY: 8,
            tintOpacity: DesignTokens.Opacity.tint(for: colorScheme)
        )
    }

    private func subjectText(for node: ThreadNode) -> String {
        node.message.subject.isEmpty ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing") : node.message.subject
    }

    private func snippetText(for node: ThreadNode) -> String {
        let formatted = snippetFormatter.format(node.message.snippet)
        if formatted.isEmpty {
            return NSLocalizedString("threadcanvas.inspector.snippet.empty", comment: "Placeholder when snippet missing")
        }
        return formatted
    }

    @ViewBuilder
    private func openInMailButton(for node: ThreadNode) -> some View {
        let button = Button(action: { onOpenInMail(node) }) {
            Label(NSLocalizedString("threadcanvas.inspector.open_in_mail", comment: "Open in Mail button title"),
                  systemImage: "envelope.open")
        }
        .controlSize(.small)
        .accessibilityIdentifier(AccessibilityID.threadInspectorOpenInMailButton)
        .accessibilityHint(NSLocalizedString("accessibility.thread_inspector.open_in_mail.hint",
                                            comment: "Accessibility hint for opening a message in Apple Mail"))

        if #available(macOS 26, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func openInMailStatus(for node: ThreadNode) -> some View {
        let status = Self.openInMailStatus(for: openInMailState, messageKey: node.message.id.uuidString)
        VStack(alignment: .leading, spacing: 8) {
            statusLine(for: status)
            hintText(for: status)
            copyControls(for: node)
        }
        .font(DesignTokens.font(size: 12, textScale: textScale))
        .foregroundStyle(inspectorSecondaryForegroundStyle)
    }

    internal static func openInMailStatus(for state: OpenInMailState?, messageKey: String) -> OpenInMailStatus {
        guard let state, state.messageKey == messageKey else { return .idle }
        return state.status
    }

    @ViewBuilder
    private func statusLine(for status: OpenInMailStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .searchingFilteredFallback:
            Label(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.searching_filtered",
                                    comment: "Open in Mail filtered fallback search status"),
                  systemImage: "magnifyingglass")
        case .opened(.filteredFallback):
            Label(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.opened_filtered",
                                    comment: "Open in Mail success status using filtered fallback"),
                  systemImage: "checkmark.circle")
        case .notFound:
            Text(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.no_match",
                                   comment: "Open in Mail fallback no match status"))
        case .failed:
            Text(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.failed",
                                   comment: "Open in Mail failure status"))
        }
    }

    @ViewBuilder
    private func hintText(for status: OpenInMailStatus) -> some View {
        switch status {
        case .notFound, .failed:
            Text(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.manual_hint",
                                   comment: "Open in Mail fallback guidance"))
        default:
            EmptyView()
        }
    }

    private func copyControls(for node: ThreadNode) -> some View {
        let subject = node.message.subject
        let mailboxValue = mailboxCopyValue(for: node)
        return HStack(spacing: 8) {
            Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.copy_subject",
                                     comment: "Copy subject action"),
                   action: { handleCopyAction(subject) })
                .controlSize(.mini)
                .disabled(subject.isEmpty)
                .accessibilityIdentifier(AccessibilityID.threadInspectorCopySubjectButton)
            Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.copy_mailbox",
                                     comment: "Copy mailbox path action"),
                   action: { handleCopyAction(mailboxValue) })
                .controlSize(.mini)
                .disabled(mailboxValue.isEmpty)
                .accessibilityIdentifier(AccessibilityID.threadInspectorCopyMailboxButton)
        }
        .buttonStyle(InspectorCopyButtonStyle())
    }

    private func mailboxCopyValue(for node: ThreadNode) -> String {
        let mailbox = node.message.mailboxID.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = node.message.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        if mailbox.isEmpty {
            return account
        }
        if account.isEmpty {
            return mailbox
        }
        return "\(account): \(mailbox)"
    }

    private var snippetFormatter: SnippetFormatter {
        SnippetFormatter(lineLimit: inspectorSettings.snippetLineLimit,
                         stopPhrases: inspectorSettings.stopPhrases)
    }

    private func handleCopyAction(_ value: String) {
        guard !value.isEmpty else { return }
        onCopyOpenInMailText(value)
        showCopyToast(message: NSLocalizedString("threadcanvas.inspector.copy_toast",
                                                comment: "Toast text when inspector copy action succeeds"))
    }

    private func showCopyToast(message: String) {
        copyToastMessage = message
        withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
            isCopyToastVisible = true
        }
        copyToastHideWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.2)) {
                isCopyToastVisible = false
            }
        }
        copyToastHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    @ViewBuilder
    private var copyToast: some View {
        if isCopyToastVisible {
            Text(copyToastMessage)
                .font(DesignTokens.font(size: 12, textScale: textScale))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(copyToastBackground)
                .foregroundStyle(copyToastForegroundStyle)
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.2), radius: 6, y: 3)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityLabel(copyToastMessage)
        }
    }

    private var copyToastBackground: some View {
        let shape = Capsule()
        if reduceTransparency {
            let strokeColor = colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.2)
            return AnyView(shape.fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.95))
                .overlay(shape.stroke(strokeColor)))
        }
        if isGlassInspectorEnabled {
            if colorScheme == .light {
                return AnyView(shape.fill(Color.white.opacity(0.82))
                    .overlay(shape.stroke(Color.black.opacity(0.12))))
            }
            return AnyView(shape.fill(Color.black.opacity(0.55))
                .overlay(shape.stroke(Color.white.opacity(0.18))))
        }
        return AnyView(shape.fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.9))
            .overlay(shape.stroke(Color.black.opacity(0.1))))
    }

    private var copyToastForegroundStyle: Color {
        if colorScheme == .light {
            return Color.black.opacity(0.86)
        }
        return Color.white.opacity(0.95)
    }

}

private struct InspectorField: View {
    let label: String
    let value: String
    let textScale: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(DesignTokens.font(size: 11, textScale: textScale))
                .foregroundStyle(labelForegroundStyle)
            Text(value)
                .font(DesignTokens.font(size: 13, textScale: textScale))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var labelForegroundStyle: Color {
        if #available(macOS 26, *) {
            guard !reduceTransparency else { return Color.secondary }
            if colorScheme == .light {
                return Color.black.opacity(0.62)
            }
            return Color.white.opacity(0.75)
        }
        return Color.secondary
    }

}

private struct InspectorCopyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
