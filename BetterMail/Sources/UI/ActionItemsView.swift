// BetterMail/Sources/UI/ActionItemsView.swift
import SwiftUI

internal struct ActionItemsView: View {
    @ObservedObject internal var viewModel: ThreadCanvasViewModel
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    internal var textScale: CGFloat
    @State private var showDone = false
    @State private var isInspectorVisible = false

    private let inspectorWidth: CGFloat = 320

    internal var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { viewModel.selectNode(id: nil) }
            VStack(spacing: 0) {
                topBar
                Divider()
                if viewModel.actionItems.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            }
            if isInspectorVisible, let selectedNode = viewModel.selectedNode {
                ThreadInspectorView(
                    node: selectedNode,
                    generatedGraphTitle: nil,
                    isGraphTitleRegenerating: false,
                    summaryState: viewModel.summaryState(for: selectedNode.id),
                    summaryExpansion: Binding(
                        get: { viewModel.isSummaryExpanded(for: selectedNode.id) },
                        set: { viewModel.setSummaryExpanded($0, for: selectedNode.id) }
                    ),
                    inspectorSettings: inspectorSettings,
                    textScale: textScale,
                    openInMailState: viewModel.openInMailState,
                    canRegenerateSummary: viewModel.isSummaryProviderAvailable,
                    onRegenerateSummary: { viewModel.regenerateNodeSummary(for: selectedNode.id) },
                    canRegenerateGraphTitle: false,
                    onRegenerateGraphTitle: nil,
                    onOpenInMail: viewModel.openMessageInMail,
                    onCopyOpenInMailText: viewModel.copyToPasteboard
                )
                .id(selectedNode.id)
                .frame(width: inspectorWidth)
                .padding(.top, 50)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(1)
                .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: viewModel.selectedNodeID)
            }
        }
        .accessibilityIdentifier(AccessibilityID.actionItemsView)
        .onAppear {
            isInspectorVisible = viewModel.selectedNodeID != nil
        }
        .onChange(of: viewModel.selectedNodeID) { _, newValue in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                isInspectorVisible = newValue != nil
            }
        }
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("mailbox.sidebar.action_items",
                                   comment: "Action Items view title"))
                .font(.headline)
            Text(subtitleText)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var subtitleText: String {
        let open = viewModel.actionItems.filter { !$0.isDone }.count
        let folderCount = Set(viewModel.actionItems.filter { !$0.isDone }.compactMap(\.folderID)).count
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label(NSLocalizedString("action_items.empty.title",
                                    comment: "Action Items empty-state title"),
                  systemImage: "checklist")
        } description: {
            Text(NSLocalizedString("action_items.empty.description",
                                   comment: "Action Items empty-state explanation"))
        } actions: {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        let grouped = groupedItems
        return List(selection: selectedActionItemID) {
            ForEach(grouped) { group in
                Section {
                    ForEach(group.items) { item in
                        ActionItemRow(item: item,
                                      displayTitle: displayTitle(for: item),
                                      onToggleDone: { viewModel.toggleActionItemDone(item) })
                            .tag(item.messageID)
                    }
                } header: {
                    HStack {
                        Text(group.folderTitle)
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
            get: { viewModel.selectedNodeID },
            set: { viewModel.selectNode(id: $0) }
        )
    }

    // MARK: - Helpers

    private func displayTitle(for item: ActionItem) -> String {
        let summary = viewModel.summaryState(for: item.messageID)?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty { return summary }
        return item.subject.isEmpty
            ? NSLocalizedString("action_items.no_subject",
                                comment: "Fallback title for an action item without a subject")
            : item.subject
    }

    // MARK: - Grouping

    private struct ItemGroup: Identifiable {
        var id: String { folderID ?? "__unfiled__" }
        let folderID: String?
        let folderTitle: String
        let items: [ActionItem]
    }

    private var groupedItems: [ItemGroup] {
        let visible = showDone ? viewModel.actionItems : viewModel.actionItems.filter { !$0.isDone }
        let folderMap = Dictionary(grouping: visible, by: \.folderID)
        let folders = viewModel.threadFolders

        var groups: [ItemGroup] = folderMap.compactMap { folderID, groupItems in
            guard let fid = folderID else { return nil }
            let title = folders.first(where: { $0.id == fid })?.title ?? fid
            return ItemGroup(folderID: fid,
                             folderTitle: title,
                             items: groupItems.sorted { $0.addedAt > $1.addedAt })
        }
        .sorted { $0.folderTitle < $1.folderTitle }

        if let unfiled = folderMap[nil], !unfiled.isEmpty {
            groups.append(ItemGroup(folderID: nil,
                                    folderTitle: NSLocalizedString(
                                        "action_items.unfiled",
                                        comment: "Action-item section for messages without a BetterMail group"
                                    ),
                                    items: unfiled.sorted { $0.addedAt > $1.addedAt }))
        }
        return groups
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
