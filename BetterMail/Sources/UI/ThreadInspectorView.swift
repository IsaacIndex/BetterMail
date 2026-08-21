import AppKit
import SwiftUI

internal struct ThreadInspectorView: View {
    internal let node: ThreadNode?
    internal let generatedGraphTitle: String?
    internal let isGraphTitleRegenerating: Bool
    internal let summaryState: ThreadSummaryState?
    internal let summaryExpansion: Binding<Bool>?
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    internal let textScale: CGFloat
    internal let openInMailState: OpenInMailState?
    internal let canRegenerateSummary: Bool
    internal let onRegenerateSummary: (() -> Void)?
    internal let canRegenerateGraphTitle: Bool
    internal let onRegenerateGraphTitle: (() -> Void)?
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

            if let generatedGraphTitle = Self.displayedGeneratedGraphTitle(generatedGraphTitle) {
                generatedTitleCard(generatedGraphTitle)
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

            InspectorAddressField(label: NSLocalizedString("threadcanvas.inspector.from", comment: "From label"),
                                  value: node.message.from,
                                  systemImage: "person.crop.circle",
                                  collapsedLimit: 1,
                                  textScale: textScale,
                                  primaryForeground: inspectorPrimaryForegroundStyle,
                                  secondaryForeground: inspectorSecondaryForegroundStyle,
                                  accessibilityIdentifier: AccessibilityID.threadInspectorFromField)
                .id("from-\(node.message.id)")
            InspectorAddressField(label: NSLocalizedString("threadcanvas.inspector.to", comment: "To label"),
                                  value: node.message.to,
                                  systemImage: "person.2",
                                  collapsedLimit: 4,
                                  textScale: textScale,
                                  primaryForeground: inspectorPrimaryForegroundStyle,
                                  secondaryForeground: inspectorSecondaryForegroundStyle,
                                  accessibilityIdentifier: AccessibilityID.threadInspectorToField)
                .id("to-\(node.message.id)")
            InspectorField(label: NSLocalizedString("threadcanvas.inspector.date", comment: "Date label"),
                           value: Self.dateFormatter.string(from: node.message.date),
                           textScale: textScale)

            InspectorEmailContent(label: NSLocalizedString("threadcanvas.inspector.snippet", comment: "Snippet label"),
                                  content: snippetText(for: node),
                                  textScale: textScale,
                                  primaryForeground: inspectorPrimaryForegroundStyle,
                                  secondaryForeground: inspectorSecondaryForegroundStyle)

            openInMailButton(for: node)
            openInMailStatus(for: node)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    internal static func displayedGeneratedGraphTitle(_ title: String?) -> String? {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    private func generatedTitleCard(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(DesignTokens.font(size: 12, textScale: textScale))
                Text(NSLocalizedString("threadcanvas.inspector.generated_title.title",
                                       comment: "Title for the Apple Intelligence generated message title card"))
                    .font(DesignTokens.font(size: 12, weight: .semibold, textScale: textScale))
                Spacer(minLength: 0)
                if isGraphTitleRegenerating {
                    ProgressView()
                        .controlSize(.mini)
                }
                if let onRegenerateGraphTitle {
                    Button(action: onRegenerateGraphTitle) {
                        Image(systemName: "arrow.clockwise")
                            .font(DesignTokens.font(size: 12, textScale: textScale))
                    }
                    .buttonStyle(.plain)
                    .controlSize(.mini)
                    .disabled(!canRegenerateGraphTitle || isGraphTitleRegenerating)
                    .accessibilityLabel(NSLocalizedString("threadcanvas.inspector.generated_title.regenerate",
                                                          comment: "Accessibility label for regenerating a generated message title"))
                    .help(NSLocalizedString("threadcanvas.inspector.generated_title.regenerate",
                                            comment: "Help text for regenerating a generated message title"))
                    .accessibilityIdentifier(AccessibilityID.threadGeneratedTitleRegenerateButton)
                }
            }

            Text(title)
                .font(DesignTokens.font(size: 13, textScale: textScale))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(generatedTitleBackground)
        .accessibilityIdentifier(AccessibilityID.threadGeneratedTitle)
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

    @ViewBuilder
    private var generatedTitleBackground: some View {
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

internal nonisolated struct InspectorEmailAddress: Equatable, Sendable {
    internal let displayName: String?
    internal let email: String?

    internal var primaryText: String {
        displayName ?? email ?? ""
    }

    internal var secondaryText: String? {
        guard displayName != nil else { return nil }
        return email
    }

    internal var initial: String {
        let source = primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.first.map { String($0).uppercased() } ?? "?"
    }
}

internal nonisolated enum InspectorEmailAddressParser {
    internal static func parse(_ headerValue: String) -> [InspectorEmailAddress] {
        let unfolded = headerValue
            .replacingOccurrences(of: "[\\r\\n]+[\\t ]*",
                                  with: " ",
                                  options: .regularExpression)
        return splitAddressTokens(unfolded).compactMap(parseToken)
    }

    private static func splitAddressTokens(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false
        var angleDepth = 0

        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\", isQuoted {
                current.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" {
                isQuoted.toggle()
                current.append(character)
                continue
            }
            if !isQuoted {
                if character == "<" {
                    angleDepth += 1
                } else if character == ">", angleDepth > 0 {
                    angleDepth -= 1
                } else if (character == "," || character == ";"), angleDepth == 0 {
                    appendToken(current, to: &tokens)
                    current = ""
                    continue
                }
            }
            current.append(character)
        }
        appendToken(current, to: &tokens)
        return tokens
    }

    private static func appendToken(_ token: String, to tokens: inout [String]) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tokens.append(trimmed)
        }
    }

    private static func parseToken(_ rawToken: String) -> InspectorEmailAddress? {
        let token = removingGroupPrefix(from: rawToken)
        guard !token.isEmpty else { return nil }

        if let open = token.firstIndex(of: "<"),
           let close = token.lastIndex(of: ">"),
           open < close {
            let name = normalizedDisplayName(String(token[..<open]))
            let emailStart = token.index(after: open)
            let email = normalizedEmail(String(token[emailStart..<close]))
            guard name != nil || email != nil else { return nil }
            return InspectorEmailAddress(displayName: name, email: email)
        }

        if token.contains("@") {
            return InspectorEmailAddress(displayName: nil,
                                         email: normalizedEmail(token))
        }
        return InspectorEmailAddress(displayName: normalizedDisplayName(token),
                                     email: nil)
    }

    private static func removingGroupPrefix(from rawToken: String) -> String {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = token.firstIndex(of: ":") else { return token }
        let prefix = token[..<colon]
        let suffix = token[token.index(after: colon)...]
        guard !prefix.contains("@"), suffix.contains("@") else { return token }
        return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedDisplayName(_ value: String) -> String? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("\""), normalized.hasSuffix("\""), normalized.count >= 2 {
            normalized.removeFirst()
            normalized.removeLast()
        }
        normalized = normalized
            .replacingOccurrences(of: "\\\"", with: "\"")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedEmail(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "<>")))
            .replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive, .anchored])
        return normalized.isEmpty ? nil : normalized
    }
}

private struct InspectorAddressField: View {
    let label: String
    let value: String
    let systemImage: String
    let collapsedLimit: Int
    let textScale: CGFloat
    let primaryForeground: Color
    let secondaryForeground: Color
    let accessibilityIdentifier: String

    @State private var isExpanded = false

    private var addresses: [InspectorEmailAddress] {
        InspectorEmailAddressParser.parse(value)
    }

    private var visibleAddresses: [InspectorEmailAddress] {
        isExpanded ? addresses : Array(addresses.prefix(max(collapsedLimit, 1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(label, systemImage: systemImage)
                    .font(DesignTokens.font(size: 11, weight: .semibold, textScale: textScale))
                    .foregroundStyle(secondaryForeground)
                Spacer(minLength: 0)
                if addresses.count > 1 {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("threadcanvas.inspector.address.count",
                                          comment: "Recipient count in an inspector address field"),
                        addresses.count
                    ))
                    .font(DesignTokens.font(size: 10, weight: .medium, textScale: textScale))
                    .foregroundStyle(secondaryForeground)
                }
            }

            if addresses.isEmpty {
                Text(NSLocalizedString("threadcanvas.inspector.address.empty",
                                       comment: "Placeholder for an empty sender or recipient field"))
                    .font(DesignTokens.font(size: 12, textScale: textScale))
                    .foregroundStyle(secondaryForeground)
            } else {
                ForEach(Array(visibleAddresses.enumerated()), id: \.offset) { _, address in
                    InspectorAddressRow(address: address,
                                        textScale: textScale,
                                        primaryForeground: primaryForeground,
                                        secondaryForeground: secondaryForeground)
                }

                if addresses.count > max(collapsedLimit, 1) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Label(expansionButtonTitle,
                              systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .font(DesignTokens.font(size: 11, weight: .medium, textScale: textScale))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(inspectorCardBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var expansionButtonTitle: String {
        if isExpanded {
            return NSLocalizedString("threadcanvas.inspector.address.show_less",
                                     comment: "Button that collapses a recipient list")
        }
        let remainingCount = max(addresses.count - max(collapsedLimit, 1), 0)
        return String.localizedStringWithFormat(
            NSLocalizedString("threadcanvas.inspector.address.show_more",
                              comment: "Button that expands a recipient list"),
            remainingCount
        )
    }

    private var inspectorCardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.card, style: .continuous)
        return shape
            .fill(Color.primary.opacity(0.035))
            .overlay(shape.stroke(Color.secondary.opacity(0.16)))
    }
}

private struct InspectorAddressRow: View {
    let address: InspectorEmailAddress
    let textScale: CGFloat
    let primaryForeground: Color
    let secondaryForeground: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(address.initial)
                .font(DesignTokens.font(size: 11, weight: .semibold, textScale: textScale))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: address.primaryText)
                    .font(DesignTokens.font(size: 12,
                                            weight: address.secondaryText == nil ? .regular : .semibold,
                                            textScale: textScale))
                    .foregroundStyle(primaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondaryText = address.secondaryText {
                    Text(verbatim: secondaryText)
                        .font(DesignTokens.font(size: 11, textScale: textScale))
                        .foregroundStyle(secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct InspectorEmailContent: View {
    let label: String
    let content: String
    let textScale: CGFloat
    let primaryForeground: Color
    let secondaryForeground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: "doc.plaintext")
                .font(DesignTokens.font(size: 11, weight: .semibold, textScale: textScale))
                .foregroundStyle(secondaryForeground)
            Text(verbatim: content)
                .font(DesignTokens.font(size: 13, textScale: textScale))
                .foregroundStyle(primaryForeground)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(inspectorCardBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.threadInspectorEmailContent)
    }

    private var inspectorCardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.card, style: .continuous)
        return shape
            .fill(Color.primary.opacity(0.035))
            .overlay(shape.stroke(Color.secondary.opacity(0.16)))
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
