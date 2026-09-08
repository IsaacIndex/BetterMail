// BetterMail/Sources/UI/ActionItemsView.swift
import SwiftUI

internal struct ActionItemsView: View {
    @ObservedObject internal var viewModel: ThreadCanvasViewModel
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    internal var textScale: CGFloat
    @State private var showDone = false
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool

    private let inspectorWidth: CGFloat = 320

    internal var body: some View {
        let projection = listProjection
        let summaryLookup = ActionItemSummaryLookup(roots: viewModel.roots)
        let summaryNode = viewModel.actionItems.first { $0.id == viewModel.selectedActionItemID }
            .flatMap { summaryLookup.node(for: $0) }
        VStack(spacing: 0) {
            topBar(projection: projection)
            Divider()
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.selectActionItem(id: nil) }
                if let state = projection.emptyState {
                    emptyState(state)
                } else {
                    itemList(groups: projection.groups, summaryLookup: summaryLookup)
                }
                if let id = viewModel.selectedActionItemID {
                    inspectorPanel(summaryNode: summaryNode)
                        .id(id)
                        .frame(width: inspectorWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .zIndex(1)
                        .transition(.opacity)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.actionItemsView)
        .task { await viewModel.refreshActionItemIDs() }
        .task(id: viewModel.actionItemSelectionRevision) {
            await viewModel.loadSelectedActionItem()
        }
        .onChange(of: projection.visibleItems.map(\.id)) { _, visibleIDs in
            if let id = viewModel.selectedActionItemID, !visibleIDs.contains(id) {
                viewModel.selectActionItem(id: nil)
            }
        }
    }

    private var listProjection: ActionItemListProjection {
        ActionItemListProjection(items: viewModel.actionItems,
                                 folders: viewModel.threadFolders,
                                 showDone: showDone,
                                 query: searchQuery)
    }

    private func inspectorPanel(summaryNode: ThreadNode?) -> some View {
        Group {
            if let selectedNode = viewModel.selectedActionItemNode {
                ThreadInspectorView(
                    node: selectedNode,
                    generatedGraphTitle: nil,
                    isGraphTitleRegenerating: false,
                    summaryState: summaryNode.flatMap { viewModel.summaryState(for: $0.id) },
                    summaryExpansion: Binding(
                        get: { viewModel.isSummaryExpanded(for: selectedNode.id) },
                        set: { viewModel.setSummaryExpanded($0, for: selectedNode.id) }
                    ),
                    inspectorSettings: inspectorSettings,
                    textScale: textScale,
                    openInMailState: viewModel.openInMailState,
                    canRegenerateSummary: viewModel.isSummaryProviderAvailable && summaryNode != nil,
                    onRegenerateSummary: { viewModel.regenerateNodeSummary(for: selectedNode.id) },
                    canRegenerateGraphTitle: false,
                    onRegenerateGraphTitle: nil,
                    onOpenInMail: viewModel.openMessageInMail,
                    onCopyOpenInMailText: viewModel.copyToPasteboard
                )
            } else if let error = viewModel.actionItemSelectionError {
                ContentUnavailableView {
                    Label("action_items.source.title", systemImage: "envelope.badge")
                } description: {
                    Text(error)
                }
                .background(.regularMaterial)
            } else {
                ProgressView("action_items.source.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                viewModel.selectActionItem(id: nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .padding(12)
            .accessibilityLabel(Text("action_items.inspector.close"))
        }
    }

    // MARK: - Subviews

    private func topBar(projection: ActionItemListProjection) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("mailbox.sidebar.action_items",
                                       comment: "Action Items view title"))
                    .font(.headline)
                Text(subtitleText(projection: projection))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(showDone
                       ? NSLocalizedString("action_items.hide_done",
                                           comment: "Button title for hiding completed action items")
                       : NSLocalizedString("action_items.show_done",
                                           comment: "Button title for showing completed action items")) {
                    showDone.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityIdentifier(AccessibilityID.actionItemsShowDoneButton)
                .accessibilityLabel(showDone
                                    ? NSLocalizedString("accessibility.action_items.hide_done",
                                                        comment: "Accessibility label for hiding completed action items")
                                    : NSLocalizedString("accessibility.action_items.show_done",
                                                        comment: "Accessibility label for showing completed action items"))
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("action_items.search.placeholder", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .accessibilityIdentifier(AccessibilityID.actionItemsSearchField)
                    .accessibilityLabel(Text("action_items.search.placeholder"))
                    .onKeyPress(.escape) {
                        guard !searchQuery.isEmpty else { return .ignored }
                        searchQuery = ""
                        return .handled
                    }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("action_items.search.clear"))
                }
            }
            .padding(7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func subtitleText(projection: ActionItemListProjection) -> String {
        let open = projection.openCount
        let folderCount = projection.openGroupCount
        if open == 0 {
            return NSLocalizedString("action_items.subtitle.all_done",
                                     comment: "Action Items subtitle when everything is complete")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("action_items.subtitle.counts",
                              comment: "Open action-item and folder counts"),
            open,
            folderCount
        )
    }

    private func emptyState(_ state: ActionItemListProjection.EmptyState) -> some View {
        ContentUnavailableView {
            Label(NSLocalizedString(emptyStateTitleKey(state),
                                    comment: "Action Items empty-state title"),
                  systemImage: "checklist")
        } description: {
            Text(NSLocalizedString(emptyStateDescriptionKey(state),
                                   comment: "Action Items empty-state explanation"))
        } actions: {
            if state == .noMatches {
                Button("action_items.search.clear") { searchQuery = "" }
                    .buttonStyle(.bordered)
                if !showDone, viewModel.actionItems.contains(where: \.isDone) {
                    Button("action_items.show_done") { showDone = true }
                        .buttonStyle(.bordered)
                }
            } else if state == .allDone {
                Button("action_items.show_done") { showDone = true }
                    .buttonStyle(.bordered)
            } else {
                Button(NSLocalizedString(
                    "action_items.empty.view_all_emails",
                    comment: "Button title for leaving an empty action items list and viewing all email threads"
                )) {
                    viewModel.selectMailboxScope(.allEmails)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.actionItemsEmptyViewCanvasButton)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func itemList(groups: [ActionItemListProjection.Group],
                          summaryLookup: ActionItemSummaryLookup) -> some View {
        List(selection: selectedActionItemID) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        ActionItemRow(item: item,
                                      displayTitle: displayTitle(for: item, summaryNode: summaryLookup.node(for: item)),
                                      onToggleDone: { viewModel.toggleActionItemDone(item) })
                            .tag(item.id)
                    }
                } header: {
                    HStack {
                        Text(group.title ?? NSLocalizedString("action_items.unfiled", comment: "Unfiled action items"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                        Text("\(group.items.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier(AccessibilityID.actionItemsList)
    }

    private var selectedActionItemID: Binding<String?> {
        Binding(
            get: { viewModel.selectedActionItemID },
            set: { viewModel.selectActionItem(id: $0) }
        )
    }

    // MARK: - Helpers

    private func displayTitle(for item: ActionItem, summaryNode: ThreadNode?) -> String {
        let summary = summaryNode.flatMap { viewModel.summaryState(for: $0.id) }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty { return summary }
        return item.subject.isEmpty
            ? NSLocalizedString("action_items.no_subject",
                                comment: "Fallback title for an action item without a subject")
            : item.subject
    }

    private func emptyStateTitleKey(_ state: ActionItemListProjection.EmptyState) -> String {
        switch state {
        case .noItems: return "action_items.empty.title"
        case .allDone: return "action_items.completed.title"
        case .noMatches: return "action_items.search.empty.title"
        }
    }

    private func emptyStateDescriptionKey(_ state: ActionItemListProjection.EmptyState) -> String {
        switch state {
        case .noItems: return "action_items.empty.description"
        case .allDone: return "action_items.completed.description"
        case .noMatches: return "action_items.search.empty.description"
        }
    }

}

// MARK: - Row

private struct ActionItemRow: View {
    let item: ActionItem
    let displayTitle: String
    let onToggleDone: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: isDone) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.actionItemDoneButton(item.id))
            .accessibilityLabel(item.isDone
                                ? NSLocalizedString("accessibility.action_items.mark_not_done",
                                                    comment: "Accessibility label for marking an action item not done")
                                : NSLocalizedString("accessibility.action_items.mark_done",
                                                    comment: "Accessibility label for marking an action item done"))

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(item.isDone ? .tertiary : .primary)
                    .strikethrough(item.isDone)
                    .lineLimit(1)
                Text("\(item.from) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if !item.accountName.isEmpty {
                    Text(item.accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !item.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(item.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(item.isDone ? 0.08 : 0.15),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(item.isDone ? .tertiary : .secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(item.isDone ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.actionItemRow(item.id))
        .accessibilityLabel(actionItemAccessibilityLabel)
        .accessibilityHint(NSLocalizedString("accessibility.action_items.row.hint",
                                             comment: "Accessibility hint for selecting an action item row"))
    }

    private var isDone: Binding<Bool> {
        Binding(
            get: { item.isDone },
            set: { newValue in
                guard newValue != item.isDone else { return }
                onToggleDone()
            }
        )
    }

    private var actionItemAccessibilityLabel: String {
        let status = item.isDone
            ? NSLocalizedString("accessibility.action_items.status.done",
                                comment: "Accessibility label for completed action item status")
            : NSLocalizedString("accessibility.action_items.status.open",
                                comment: "Accessibility label for open action item status")
        return String.localizedStringWithFormat(
            NSLocalizedString("accessibility.action_items.row.label",
                              comment: "Accessibility label for an action item row"),
            displayTitle,
            item.from,
            item.date.formatted(date: .abbreviated, time: .omitted),
            status
        )
    }
}
