import SwiftUI

internal struct GraphRestoreHistoryControl: View {
    internal let entries: [GraphCompostEntry]
    internal let restoringEntryIDs: Set<String>
    internal let textScale: CGFloat
    internal let onRestore: (GraphCompostEntry) -> Void
    internal let onDismiss: (GraphCompostEntry) -> Void

    @State private var isPresented = false
    @State private var dismissalCandidate: GraphCompostEntry?

    internal var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(toolbarTitle, systemImage: "clock.arrow.circlepath")
                .labelStyle(.titleAndIcon)
                .font(DesignTokens.font(size: 12,
                                        weight: .semibold,
                                        textScale: textScale))
                .frame(width: 108)
                .frame(minHeight: 26)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isPresented
                              ? DesignTokens.Graph.AppTheme.panelSecondary
                              : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .accessibilityLabel(NSLocalizedString(
            "graph.restore_history.title",
            comment: "Restore History control accessibility label"
        ))
        .accessibilityValue(String.localizedStringWithFormat(
            NSLocalizedString(
                "graph.restore_history.accessibility.count",
                comment: "Restore History item count"
            ),
            entries.count
        ))
        .accessibilityIdentifier(AccessibilityID.graphRestoreHistoryControl)
        .help(NSLocalizedString(
            "graph.restore_history.toolbar.help",
            comment: "Help for the Restore History toolbar control"
        ))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
        .alert(
            NSLocalizedString(
                "graph.restore_history.dismiss.confirm.title",
                comment: "Title for confirming Restore History dismissal"
            ),
            isPresented: Binding(
                get: { dismissalCandidate != nil },
                set: { if !$0 { dismissalCandidate = nil } }
            ),
            presenting: dismissalCandidate
        ) { entry in
            Button(NSLocalizedString(
                "graph.restore_history.dismiss",
                comment: "Confirm Restore History dismissal"
            ), role: .destructive) {
                onDismiss(entry)
                dismissalCandidate = nil
            }
            Button(NSLocalizedString(
                "graph.restore_history.dismiss.cancel",
                comment: "Cancel Restore History dismissal"
            ), role: .cancel) {
                dismissalCandidate = nil
            }
        } message: { entry in
            Text(String.localizedStringWithFormat(
                NSLocalizedString(
                    "graph.restore_history.dismiss.confirm.message",
                    comment: "Restore History dismissal confirmation explanation"
                ),
                entry.subject
            ))
        }
    }

    private var toolbarTitle: String {
        String.localizedStringWithFormat(
            NSLocalizedString(
                "graph.restore_history.toolbar",
                comment: "Restore History toolbar title and count"
            ),
            entries.count
        )
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString(
                    "graph.restore_history.title",
                    comment: "Restore History popover title"
                ))
                .font(DesignTokens.font(size: 15,
                                        weight: .semibold,
                                        textScale: textScale))
                .foregroundStyle(DesignTokens.Graph.AppTheme.ink)

                Text(NSLocalizedString(
                    "graph.restore_history.subtitle",
                    comment: "Restore History popover explanation"
                ))
                .font(DesignTokens.font(size: 11,
                                        weight: .regular,
                                        textScale: textScale))
                .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 22))
                        .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
                    Text(NSLocalizedString(
                        "graph.restore_history.empty",
                        comment: "Restore History empty state"
                    ))
                    .font(DesignTokens.font(size: 12,
                                            weight: .medium,
                                            textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(GraphRestoreHistorySection.make(from: entries)) { section in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(section.localizedTitle)
                                    .font(DesignTokens.font(size: 10.5,
                                                            weight: .semibold,
                                                            textScale: textScale))
                                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
                                    .textCase(.uppercase)

                                ForEach(section.entries) { entry in
                                    GraphRestoreHistoryRow(
                                        entry: entry,
                                        isRestoring: restoringEntryIDs.contains(entry.id),
                                        actionsDisabled: !restoringEntryIDs.isEmpty,
                                        textScale: textScale,
                                        onRestore: { onRestore(entry) },
                                        onDismiss: { dismissalCandidate = entry }
                                    )
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 344)
        .background(DesignTokens.Graph.AppTheme.panel)
        .accessibilityIdentifier(AccessibilityID.graphRestoreHistoryPopover)
    }
}

private struct GraphRestoreHistoryRow: View {
    let entry: GraphCompostEntry
    let isRestoring: Bool
    let actionsDisabled: Bool
    let textScale: CGFloat
    let onRestore: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: entry.action == .snip ? "scissors" : "archivebox")
                    .foregroundStyle(actionTint)
                Text(entry.subject)
                    .font(DesignTokens.font(size: 12,
                                            weight: .semibold,
                                            textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(entry.createdAt,
                     format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(DesignTokens.font(size: 9.5,
                                            weight: .regular,
                                            textScale: textScale))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
            }

            Label(GraphRestoreHistoryPresentation.mailboxSummary(for: entry),
                  systemImage: "arrow.right")
                .font(DesignTokens.font(size: 10.5,
                                        weight: .regular,
                                        textScale: textScale))
                .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = GraphRestoreHistoryPresentation.recoveryWarning(for: entry) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.font(size: 10.5,
                                            weight: .medium,
                                            textScale: textScale))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: onRestore) {
                    HStack(spacing: 5) {
                        if isRestoring {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(NSLocalizedString(
                            entry.requiresRecovery
                                ? "graph.restore_history.retry"
                                : "graph.restore_history.restore",
                            comment: "Explicit Restore History action"
                        ))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(actionTint)
                .disabled(actionsDisabled)
                .accessibilityLabel(String.localizedStringWithFormat(
                    NSLocalizedString(
                        entry.requiresRecovery
                            ? "graph.restore_history.retry.accessibility"
                            : "graph.restore_history.restore.accessibility",
                        comment: "Subject-specific Restore History action label"
                    ),
                    entry.subject
                ))
                .accessibilityHint(NSLocalizedString(
                    "graph.restore_history.restore.accessibility.hint",
                    comment: "Restore History action accessibility hint"
                ))
                .accessibilityIdentifier(AccessibilityID.graphRestoreHistoryRestore(entry.id))

                Button(NSLocalizedString(
                    "graph.restore_history.dismiss",
                    comment: "Dismiss a Restore History entry"
                ), action: onDismiss)
                    .buttonStyle(.bordered)
                    .disabled(actionsDisabled)
                    .accessibilityLabel(String.localizedStringWithFormat(
                        NSLocalizedString(
                            "graph.restore_history.dismiss.accessibility",
                            comment: "Subject-specific Restore History dismissal label"
                        ),
                        entry.subject
                    ))
                    .accessibilityHint(NSLocalizedString(
                        "graph.restore_history.dismiss.accessibility.hint",
                        comment: "Restore History dismissal accessibility hint"
                    ))
                    .accessibilityIdentifier(AccessibilityID.graphRestoreHistoryDismiss(entry.id))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignTokens.Graph.AppTheme.panelSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.graphRestoreHistoryRow(entry.id))
    }

    private var actionTint: Color {
        entry.action == .snip
            ? DesignTokens.Graph.AppTheme.snip
            : DesignTokens.Graph.AppTheme.archive
    }
}

internal struct GraphRestoreHistorySection: Identifiable, Equatable {
    internal let action: GraphCompostAction
    internal let entries: [GraphCompostEntry]

    internal var id: String { action.rawValue }

    internal var localizedTitle: String {
        NSLocalizedString(
            action == .snip
                ? "graph.restore_history.section.snipped"
                : "graph.restore_history.section.archived",
            comment: "Restore History section title"
        )
    }

    internal static func make(from entries: [GraphCompostEntry]) -> [GraphRestoreHistorySection] {
        let sorted = entries.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id < $1.id
        }
        return [GraphCompostAction.snip, .archive].compactMap { action in
            let sectionEntries = sorted.filter { $0.action == action }
            guard !sectionEntries.isEmpty else { return nil }
            return GraphRestoreHistorySection(action: action, entries: sectionEntries)
        }
    }
}

internal enum GraphRestoreHistoryPresentation {
    internal static func mailboxSummary(for entry: GraphCompostEntry) -> String {
        if entry.action == .archive {
            return NSLocalizedString(
                "graph.restore_history.route.archive",
                comment: "Graph archive source and destination summary"
            )
        }

        let routes = uniqueRoutes(for: entry)
        if let first = routes.first {
            if routes.count == 1 {
                return first
            }
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "graph.restore_history.route.more",
                    comment: "Restore History mailbox route with additional route count"
                ),
                first,
                routes.count - 1
            )
        }

        if let priorMailboxPath = entry.priorMailboxPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !priorMailboxPath.isEmpty {
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "graph.restore_history.route.restore_to",
                    comment: "Legacy Restore History destination mailbox"
                ),
                priorMailboxPath
            )
        }

        return NSLocalizedString(
            "graph.restore_history.route.unavailable",
            comment: "Unavailable Restore History mailbox route"
        )
    }

    internal static func recoveryWarning(for entry: GraphCompostEntry) -> String? {
        guard entry.requiresRecovery else { return nil }
        let count = max(entry.movedMessages.count, entry.messageIDs.count)
        if count == 1 {
            return NSLocalizedString(
                "graph.restore_history.recovery_warning.one",
                comment: "Restore History partial recovery warning for one message"
            )
        }
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "graph.restore_history.recovery_warning.many",
                comment: "Restore History partial recovery warning"
            ),
            count
        )
    }

    private static func uniqueRoutes(for entry: GraphCompostEntry) -> [String] {
        var seen: Set<String> = []
        var routes: [String] = []
        for message in entry.movedMessages {
            let source = mailboxName(path: message.sourceMailboxPath,
                                     account: message.sourceAccountName,
                                     comparedWith: message.destinationAccountName)
            let destination = mailboxName(path: message.destinationMailboxPath,
                                          account: message.destinationAccountName,
                                          comparedWith: message.sourceAccountName)
            let route = String.localizedStringWithFormat(
                NSLocalizedString(
                    "graph.restore_history.route.move",
                    comment: "Restore History source to destination mailbox route"
                ),
                source,
                destination
            )
            if seen.insert(route).inserted {
                routes.append(route)
            }
        }
        return routes
    }

    private static func mailboxName(path: String,
                                    account: String,
                                    comparedWith otherAccount: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOtherAccount = otherAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty,
              trimmedAccount.localizedCaseInsensitiveCompare(trimmedOtherAccount) != .orderedSame else {
            return trimmedPath
        }
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "graph.restore_history.route.mailbox_account",
                comment: "Mailbox and account shown in Restore History"
            ),
            trimmedAccount,
            trimmedPath
        )
    }
}
