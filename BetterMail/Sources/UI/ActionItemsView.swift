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
            Text("Action Items")
                .font(.headline)
            Text(subtitleText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(showDone ? "Hide done" : "Show done") {
                showDone.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var subtitleText: String {
        let open = viewModel.actionItems.filter { !$0.isDone }.count
        let folderCount = Set(viewModel.actionItems.filter { !$0.isDone }.compactMap(\.folderID)).count
        if open == 0 { return "All done" }
        return "\(open) open · \(folderCount) folder\(folderCount == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("No action items yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Right-click any thread on the canvas\nto add an action item.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        let grouped = groupedItems
        return List {
            ForEach(grouped) { group in
                Section {
                    ForEach(group.items) { item in
                        ActionItemRow(item: item,
                                      onToggleDone: { viewModel.toggleActionItemDone(item.id) },
                                      onSelect: { viewModel.selectNode(id: item.id) })
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
                                    folderTitle: "Unfiled",
                                    items: unfiled.sorted { $0.addedAt > $1.addedAt }))
        }
        return groups
    }

}

// MARK: - Row

private struct ActionItemRow: View {
    let item: ActionItem
    let onToggleDone: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onToggleDone) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? Color.green.opacity(0.7) : Color.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.subject.isEmpty ? "(no subject)" : item.subject)
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
        .onTapGesture { onSelect() }
    }
}
