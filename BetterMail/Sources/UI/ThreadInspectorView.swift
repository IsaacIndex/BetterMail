import AppKit
import SwiftUI

internal struct ThreadInspectorView: View {
    internal let node: ThreadNode?
    internal let summaryState: ThreadSummaryState?
    internal let summaryExpansion: Binding<Bool>?
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
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
                .font(.headline)

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
    }

    @ViewBuilder
    private func details(for node: ThreadNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(subjectText(for: node))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if node.message.isUnread {
                Label(NSLocalizedString("threadcanvas.inspector.unread", comment: "Unread indicator"), systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            if let summaryState, let summaryExpansion {
                ThreadSummaryDisclosureView(title: NSLocalizedString("threadcanvas.inspector.summary.title",
                                                                     comment: "Title for the thread summary disclosure in the inspector"),
                                             state: summaryState,
                                             onRegenerate: onRegenerateSummary,
                                             isRegenerateEnabled: canRegenerateSummary,
                                             isExpanded: summaryExpansion)
            }

            InspectorField(label: NSLocalizedString("threadcanvas.inspector.from", comment: "From label"),
                           value: node.message.from)
            InspectorField(label: NSLocalizedString("threadcanvas.inspector.to", comment: "To label"),
                           value: node.message.to)
            InspectorField(label: NSLocalizedString("threadcanvas.inspector.date", comment: "Date label"),
                           value: Self.dateFormatter.string(from: node.message.date))

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("threadcanvas.inspector.snippet", comment: "Snippet label"))
                    .font(.caption)
                    .foregroundStyle(inspectorSecondaryForegroundStyle)
                Text(snippetText(for: node))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            openInMailButton(for: node)
            openInMailStatus(for: node)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        Text(NSLocalizedString("threadcanvas.inspector.empty", comment: "Empty inspector placeholder"))
            .foregroundStyle(inspectorSecondaryForegroundStyle)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var isGlassInspectorEnabled: Bool {
        if #available(macOS 26, *) {
            return !reduceTransparency
        }
        return false
    }

    private var inspectorPrimaryForegroundStyle: Color {
        guard isGlassInspectorEnabled else { return Color.primary }
        if colorScheme == .light {
            return Color.black.opacity(0.82)
        }
        return Color.white
    }

    private var inspectorSecondaryForegroundStyle: Color {
        guard isGlassInspectorEnabled else { return Color.secondary }
        if colorScheme == .light {
            return Color.black.opacity(0.62)
        }
        return Color.white.opacity(0.75)
    }

    @ViewBuilder
    private var inspectorBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if reduceTransparency {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.96))
                .overlay(shape.stroke(colorScheme == .light ? Color.black.opacity(0.15) : Color.white.opacity(0.3)))
        } else if #available(macOS 26, *) {
            let strokeColor = colorScheme == .light ? Color.black.opacity(0.16) : Color.white.opacity(0.35)
            let shadowOpacity = colorScheme == .light ? 0.12 : 0.25
            let tintOpacity = colorScheme == .light ? 0.52 : 0.2
            let fillOpacity = colorScheme == .light ? 0.24 : 0.08
            shape
                .fill(Color.white.opacity(fillOpacity))
                .glassEffect(
                    .regular
                        .tint(Color.white.opacity(tintOpacity)),
                    in: .rect(cornerRadius: 18)
                )
                .overlay(shape.stroke(strokeColor))
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 16, y: 8)
        } else {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.9))
                .overlay(shape.stroke(colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.25)))
        }
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

        if #available(macOS 26, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func openInMailStatus(for node: ThreadNode) -> some View {
        let status = Self.openInMailStatus(for: openInMailState, messageID: node.message.messageID)
        VStack(alignment: .leading, spacing: 8) {
            statusLine(for: status)
            hintText(for: status)
            copyControls(for: node)
        }
        .font(.caption)
        .foregroundStyle(inspectorSecondaryForegroundStyle)
    }

    internal static func openInMailStatus(for state: OpenInMailState?, messageID: String) -> OpenInMailStatus {
        guard let state, state.messageID == messageID else { return .idle }
        return state.status
    }

    @ViewBuilder
    private func statusLine(for status: OpenInMailStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .searchingMessageID:
            Label(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.searching",
                                    comment: "Open in Mail fallback search status"),
                  systemImage: "magnifyingglass")
        case .searchingFilteredFallback:
            Label(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.searching_filtered",
                                    comment: "Open in Mail filtered fallback search status"),
                  systemImage: "magnifyingglass")
        case .opened(.messageID):
            Label(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.opened_message_id",
                                    comment: "Open in Mail success status using Message-ID"),
                  systemImage: "checkmark.circle")
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
        let messageID = node.message.messageID
        let subject = node.message.subject
        let mailboxValue = mailboxCopyValue(for: node)
        return HStack(spacing: 8) {
            Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.copy_message_id",
                                     comment: "Copy Message-ID action"),
                   action: { handleCopyAction(messageID) })
                .controlSize(.mini)
                .disabled(messageID.isEmpty)
            Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.copy_subject",
                                     comment: "Copy subject action"),
                   action: { handleCopyAction(subject) })
                .controlSize(.mini)
                .disabled(subject.isEmpty)
            Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.copy_mailbox",
                                     comment: "Copy mailbox path action"),
                   action: { handleCopyAction(mailboxValue) })
                .controlSize(.mini)
                .disabled(mailboxValue.isEmpty)
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
                .font(.caption)
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(labelForegroundStyle)
            Text(value)
                .font(.callout)
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
