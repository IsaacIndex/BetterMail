import AppKit
import SwiftUI

struct ThreadInspectorView: View {
    let node: ThreadNode?
    let summaryState: ThreadSummaryState?
    let summaryExpansion: Binding<Bool>?
    let onOpenInMail: (ThreadNode) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private static let previewMaxLines = 10

    var body: some View {
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
        let trimmed = node.message.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return NSLocalizedString("threadcanvas.inspector.snippet.empty", comment: "Placeholder when snippet missing")
        }
        return Self.trimmedPreview(trimmed, maxLines: Self.previewMaxLines)
    }

    private static func trimmedPreview(_ text: String, maxLines: Int) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > maxLines else { return text }
        var limited = lines.prefix(maxLines).map(String.init)
        if let lastIndex = limited.indices.last {
            limited[lastIndex] = limited[lastIndex] + "…"
        }
        return limited.joined(separator: "\n")
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
