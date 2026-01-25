import AppKit
import SwiftUI

internal struct ThreadInspectorView: View {
    internal let node: ThreadNode?
    internal let summaryState: ThreadSummaryState?
    internal let summaryExpansion: Binding<Bool>?
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    internal let openInMailState: OpenInMailState?
    internal let onOpenInMail: (ThreadNode) -> Void
    internal let onOpenMatchedMessage: (OpenInMailMatch) -> Void
    internal let onCopyOpenInMailText: (String) -> Void
    internal let onCopyOpenInMailURL: (String) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        .shadow(color: Color.black.opacity(isGlassInspectorEnabled ? 0.35 : 0), radius: 1.2, x: 0, y: 1)
        .background(inspectorBackground)
        .modifier(InspectorColorSchemeModifier(isEnabled: isGlassInspectorEnabled))
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
        isGlassInspectorEnabled ? Color.white : Color.primary
    }

    private var inspectorSecondaryForegroundStyle: Color {
        isGlassInspectorEnabled ? Color.white.opacity(0.75) : Color.secondary
    }

    @ViewBuilder
    private var inspectorBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if reduceTransparency {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.96))
                .overlay(shape.stroke(Color.white.opacity(0.3)))
        } else if #available(macOS 26, *) {
            shape
                .fill(Color.white.opacity(0.08))
                .glassEffect(
                    .regular
                        .tint(Color.white.opacity(0.2)),
                    in: .rect(cornerRadius: 18)
                )
                .overlay(shape.stroke(Color.white.opacity(0.35)))
                .shadow(color: Color.black.opacity(0.25), radius: 16, y: 8)
        } else {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.9))
                .overlay(shape.stroke(Color.white.opacity(0.25)))
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
        if let state = openInMailState, state.messageID == node.message.messageID {
            VStack(alignment: .leading, spacing: 8) {
                statusLine(for: state.status)
                matchDetails(for: state.status, node: node)
            }
            .font(.caption)
            .foregroundStyle(inspectorSecondaryForegroundStyle)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func statusLine(for status: OpenInMailStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .opening:
            Label(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.opening",
                                    comment: "Open in Mail opening status"),
                  systemImage: "arrow.up.right.square")
        case .opened:
            Label(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.opened",
                                    comment: "Open in Mail success status"),
                  systemImage: "checkmark.circle")
        case .searching:
            Label(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.searching",
                                    comment: "Open in Mail fallback search status"),
                  systemImage: "magnifyingglass")
        case .matches:
            Text(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.matches",
                                   comment: "Open in Mail fallback match status"))
        case .notFound:
            Text(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.no_match",
                                   comment: "Open in Mail fallback no match status"))
        case .failed:
            Text(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.failed",
                                   comment: "Open in Mail failure status"))
        }
    }

    @ViewBuilder
    private func matchDetails(for status: OpenInMailStatus, node: ThreadNode) -> some View {
        switch status {
        case .matches(let matches):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(matches) { match in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(match.subject.isEmpty
                             ? NSLocalizedString("threadcanvas.subject.placeholder",
                                                 comment: "Placeholder subject when missing")
                             : match.subject)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(inspectorPrimaryForegroundStyle)
                        Text(match.mailboxDisplay)
                        if !match.date.isEmpty {
                            Text(match.date)
                        }
                        HStack(spacing: 8) {
                            Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.open_match",
                                                     comment: "Open matched message action"),
                                   action: { onOpenMatchedMessage(match) })
                                .controlSize(.mini)
                            Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.copy_message_id",
                                                     comment: "Copy Message-ID action"),
                                   action: { onCopyOpenInMailText(match.messageID) })
                                .controlSize(.mini)
                            Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.copy_message_url",
                                                     comment: "Copy Message URL action"),
                                   action: { onCopyOpenInMailURL(match.messageID) })
                                .controlSize(.mini)
                        }
                        .buttonStyle(.borderless)
                    }
                    Divider()
                }
            }
        case .notFound, .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("threadcanvas.inspector.open_in_mail.status.manual_hint",
                                       comment: "Open in Mail fallback guidance"))
                HStack(spacing: 8) {
                    Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.copy_message_id",
                                             comment: "Copy Message-ID action"),
                           action: { onCopyOpenInMailText(node.message.messageID) })
                        .controlSize(.mini)
                    Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.copy_message_url",
                                             comment: "Copy Message URL action"),
                           action: { onCopyOpenInMailURL(node.message.messageID) })
                        .controlSize(.mini)
                    Button(NSLocalizedString("threadcanvas.inspector.open_in_mail.action.copy_subject",
                                             comment: "Copy subject action"),
                           action: { onCopyOpenInMailText(node.message.subject) })
                        .controlSize(.mini)
                }
                .buttonStyle(.borderless)
            }
        default:
            EmptyView()
        }
    }

    private var snippetFormatter: SnippetFormatter {
        SnippetFormatter(lineLimit: inspectorSettings.snippetLineLimit,
                         stopPhrases: inspectorSettings.stopPhrases)
    }
}

private struct InspectorField: View {
    let label: String
    let value: String

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
            return reduceTransparency ? Color.secondary : Color.white.opacity(0.75)
        }
        return Color.secondary
    }
}

private struct InspectorColorSchemeModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.colorScheme(.dark)
        } else {
            content
        }
    }
}
