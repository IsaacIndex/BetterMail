import AppKit
import SwiftUI

internal nonisolated enum OrganizerWorkspaceLayout {
    internal static let expandedDetailMinimumWidth: CGFloat = 720
    internal static let organizerDetailMinimumWidth: CGFloat = 480
    internal static let narrowWorkspaceThreshold: CGFloat = 660

    internal static func detailMinimumWidth(isOrganizerMode: Bool) -> CGFloat {
        isOrganizerMode ? organizerDetailMinimumWidth : expandedDetailMinimumWidth
    }

    internal static func shouldCollapseRail(workspaceWidth: CGFloat,
                                            isUserCollapsed: Bool = false) -> Bool {
        isUserCollapsed || workspaceWidth < narrowWorkspaceThreshold
    }
}

/// The graph-backed Organize workspace.
///
/// The rail is a display projection only. Selection and mutations continue to
/// flow through `ThreadCanvasViewModel` and `GraphCanvasViewModel`, which keeps
/// the existing graph, inspector, and mailbox behavior authoritative.
internal struct OrganizerWorkspaceView: View {
    @ObservedObject internal var threadViewModel: ThreadCanvasViewModel
    @ObservedObject internal var graphViewModel: GraphCanvasViewModel
    @ObservedObject internal var automationCoordinator: GraphAutomationCoordinator
    @ObservedObject internal var graphSettings: GraphCanvasSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    internal let topInset: CGFloat
    internal let bottomChromeInset: CGFloat
    internal let onRenderedOrganizerReceipt: OrganizerRenderedGraphReceiptHandler
    internal let onMoveSelection: () -> Void

    @State private var isRailCollapsed = false
    @State private var projection = OrganizerProjection.make(roots: [])
    @State private var selectionController = OrganizerSelectionController()

    private let expandedRailMinimumWidth: CGFloat = 228
    private let expandedRailMaximumWidth: CGFloat = 320
    private let collapsedRailWidth: CGFloat = 38

    internal var body: some View {
        GeometryReader { proxy in
            let isCollapsed = OrganizerWorkspaceLayout.shouldCollapseRail(
                workspaceWidth: proxy.size.width,
                isUserCollapsed: isRailCollapsed
            )
            HStack(spacing: 0) {
                OrganizerRail(
                    projection: projection,
                    isCollapsed: isCollapsed,
                    selectedConversationIDs: selectionController.selectedConversationIDs,
                    selectedCount: selectionController.selectedCount,
                    textScale: displaySettings.textScale,
                    automationCoordinator: automationCoordinator,
                    folders: threadViewModel.threadFolders,
                    onToggleCollapsed: { isRailCollapsed.toggle() },
                    onSelect: handleRailSelection(_:),
                    onRangeSelect: handleRangeSelection(_:),
                    onCommandSelect: handleCommandSelection(_:),
                    dragRawThreadIDs: railDragRawThreadIDs(for:),
                    onGroup: threadViewModel.addFolderForSelection,
                    onMove: onMoveSelection,
                    onArchive: archiveSelection,
                    canMove: threadViewModel.canMoveSelectionToMailboxFolder &&
                        !threadViewModel.isMailboxActionRunning,
                    canArchive: !selectedGraphThreadIDs.isEmpty
                )
                .frame(width: isCollapsed
                       ? collapsedRailWidth
                       : railWidth(for: proxy.size.width))

                if !isCollapsed {
                    Divider()
                        .opacity(0.7)
                }

                GraphCanvasView(
                    threadViewModel: threadViewModel,
                    graphViewModel: graphViewModel,
                    automationCoordinator: automationCoordinator,
                    graphSettings: graphSettings,
                    displaySettings: displaySettings,
                    // The workspace owns the shared top inset so the rail and
                    // graph begin on the same baseline.
                    topInset: 0,
                    bottomChromeInset: bottomChromeInset,
                    onRenderedOrganizerReceipt: onRenderedOrganizerReceipt,
                    onOrganizerSelectGraphNode: handleGraphSelection(_:intent:),
                    onOrganizerLassoGraphNodeIDs: handleGraphLasso(_:additive:)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier(AccessibilityID.organizerWorkspace)
        .onAppear {
            refreshProjectionAndSelection()
        }
        .onReceive(threadViewModel.$roots) { roots in
            refreshProjectionAndSelection(roots: roots)
        }
        .onReceive(threadViewModel.$searchQuery) { query in
            refreshProjectionAndSelection(query: query)
        }
        .onReceive(threadViewModel.$threadFolders) { folders in
            refreshProjectionAndSelection(folders: folders)
        }
        .onReceive(threadViewModel.$folderMembershipByThreadID) { membership in
            refreshProjectionAndSelection(folderMembershipByThreadID: membership)
        }
        .onReceive(threadViewModel.$manualGroupByMessageKey) { manualGroups in
            refreshProjectionAndSelection(manualGroupByMessageKey: manualGroups)
        }
        .onReceive(threadViewModel.$jwzThreadMap) { threadMap in
            refreshProjectionAndSelection(jwzThreadMap: threadMap)
        }
        .onReceive(threadViewModel.$activeMailboxScope) { scope in
            refreshProjectionAndSelection(scopeID: scope.graphPagingScopeID)
        }
        .onReceive(threadViewModel.$selectedNodeIDs) { selectedNodeIDs in
            reconcileSelection(selectedNodeIDs: selectedNodeIDs)
        }
        .onReceive(graphViewModel.$data) { data in
            refreshProjectionAndSelection(suggestedGroupings: data.groupings)
        }
        .onReceive(graphViewModel.$archivedThreadIDs) { archivedThreadIDs in
            refreshProjectionAndSelection(archivedThreadIDs: archivedThreadIDs)
        }
    }

    private func railWidth(for workspaceWidth: CGFloat) -> CGFloat {
        min(expandedRailMaximumWidth,
            max(expandedRailMinimumWidth, workspaceWidth * 0.27))
    }

    /// `@Published` emits its new value before the stored property is updated.
    /// Each override therefore carries the publisher payload into the snapshot
    /// instead of rereading one stale field from its observable object.
    private func makeProjection(
        scopeID: String? = nil,
        roots: [ThreadNode]? = nil,
        folders: [ThreadFolder]? = nil,
        folderMembershipByThreadID: [String: String]? = nil,
        archivedThreadIDs: Set<String>? = nil,
        suggestedGroupings: [GraphGrouping]? = nil,
        manualGroupByMessageKey: [String: String]? = nil,
        jwzThreadMap: [String: String]? = nil,
        query: String? = nil
    ) -> OrganizerProjection {
        OrganizerProjection.make(
            scopeID: scopeID ?? threadViewModel.activeMailboxScope.graphPagingScopeID,
            // OrganizerProjection is the single owner of Organize search
            // filtering. Passing raw scoped roots avoids narrowing them first
            // with the list-only matcher and then applying a second matcher.
            roots: roots ?? threadViewModel.roots,
            folders: folders ?? threadViewModel.threadFolders,
            folderMembershipByThreadID: folderMembershipByThreadID
                ?? threadViewModel.folderMembershipByThreadID,
            archivedThreadIDs: archivedThreadIDs ?? graphViewModel.archivedThreadIDs,
            suggestedGroupings: suggestedGroupings ?? graphViewModel.data.groupings,
            manualGroupByMessageKey: manualGroupByMessageKey
                ?? threadViewModel.manualGroupByMessageKey,
            jwzThreadMap: jwzThreadMap ?? threadViewModel.jwzThreadMap,
            query: query ?? threadViewModel.searchQuery
        )
    }

    private func refreshProjectionAndSelection(
        scopeID: String? = nil,
        roots: [ThreadNode]? = nil,
        folders: [ThreadFolder]? = nil,
        folderMembershipByThreadID: [String: String]? = nil,
        archivedThreadIDs: Set<String>? = nil,
        suggestedGroupings: [GraphGrouping]? = nil,
        manualGroupByMessageKey: [String: String]? = nil,
        jwzThreadMap: [String: String]? = nil,
        query: String? = nil
    ) {
        let nextProjection = makeProjection(
            scopeID: scopeID,
            roots: roots,
            folders: folders,
            folderMembershipByThreadID: folderMembershipByThreadID,
            archivedThreadIDs: archivedThreadIDs,
            suggestedGroupings: suggestedGroupings,
            manualGroupByMessageKey: manualGroupByMessageKey,
            jwzThreadMap: jwzThreadMap,
            query: query
        )
        projection = nextProjection
        reconcileSelection(using: nextProjection)
    }

    private func reconcileSelection(selectedNodeIDs: Set<String>? = nil) {
        reconcileSelection(using: projection, selectedNodeIDs: selectedNodeIDs)
    }

    private func reconcileSelection(
        using currentProjection: OrganizerProjection,
        selectedNodeIDs: Set<String>? = nil
    ) {
        let conversations = allConversations(in: currentProjection)
        let availableIDs = Set(conversations.map(\.id))
        let focusOrder = OrganizerSelectionController.focusOrder(
            railConversationIDs: currentProjection.unorganized.map(\.id),
            graphConversationIDs: conversations.map(\.id)
        )
        let normalizer = currentProjection.selectionNormalizer
        let selectedIDs = Set((selectedNodeIDs ?? threadViewModel.selectedNodeIDs).compactMap {
            normalizer.normalize($0)
        }).intersection(availableIDs)
        selectionController = OrganizerSelectionController(
            selectedConversationIDs: selectedIDs,
            focusID: selectionController.focusID,
            rangeAnchorID: selectionController.rangeAnchorID,
            focusOrder: focusOrder
        )
    }

    private func handleRailSelection(_ conversation: OrganizerProjection.Conversation) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) {
            handleRangeSelection(conversation)
        } else {
            applySelection(
                selectionController.selectingRailID(
                    conversation.id,
                    command: flags.contains(.command),
                    normalizingWith: selectionNormalizer()
                )
            )
        }
    }

    private func handleCommandSelection(_ conversation: OrganizerProjection.Conversation) {
        applySelection(
            selectionController.selectingRailID(
                conversation.id,
                command: true,
                normalizingWith: selectionNormalizer()
            )
        )
    }

    private func handleRangeSelection(_ conversation: OrganizerProjection.Conversation) {
        applySelection(selectionController.selectingRange(to: conversation.id))
    }

    private func handleGraphSelection(_ graphNodeID: String?,
                                      intent: OrganizerPointerSelectionIntent) {
        let normalizer = selectionNormalizer()
        guard let graphNodeID else {
            applySelection(OrganizerSelectionController(focusOrder: selectionController.focusOrder))
            return
        }
        switch intent {
        case .replace:
            applySelection(selectionController.selectingGraphNodeID(
                graphNodeID,
                command: false,
                normalizingWith: normalizer
            ))
        case .toggle:
            applySelection(selectionController.selectingGraphNodeID(
                graphNodeID,
                command: true,
                normalizingWith: normalizer
            ))
        case .range:
            guard let conversationID = normalizer.graphConversationID(from: graphNodeID) else { return }
            applySelection(selectionController.selectingRange(to: conversationID))
        }
    }

    private func handleGraphLasso(_ graphNodeIDs: Set<String>, additive: Bool) {
        applySelection(selectionController.applyingLassoGraphNodeIDs(
            graphNodeIDs,
            normalizingWith: selectionNormalizer(),
            additive: additive
        ))
    }

    private func applySelection(_ nextController: OrganizerSelectionController) {
        selectionController = nextController.reconciled(
            availableConversationIDs: Set(allConversations(in: projection).map(\.id)),
            focusOrder: nextController.focusOrder
        )

        let conversationsByID = Dictionary(uniqueKeysWithValues: allConversations(in: projection).map {
            ($0.id, $0)
        })
        var selectedConversations = selectionController.selectedIDsInFocusOrder.compactMap {
            conversationsByID[$0]
        }
        if let focusID = selectionController.focusID,
           let focused = conversationsByID[focusID] {
            selectedConversations.removeAll { $0.id == focused.id }
            selectedConversations.append(focused)
        }

        guard let first = selectedConversations.first else {
            threadViewModel.selectNode(id: nil)
            threadViewModel.selectFolder(id: nil)
            return
        }

        threadViewModel.selectNode(id: first.representativeNodeID)
        for conversation in selectedConversations.dropFirst() {
            guard conversation.representativeNodeID != first.representativeNodeID else {
                continue
            }
            threadViewModel.selectNode(id: conversation.representativeNodeID,
                                       additive: true)
        }
        let selectedCount = selectedConversations.count
        if let recorder = threadViewModel.organizerMetricsRecorder {
            Task {
                _ = await recorder.recordEvent(.selection,
                                               count: selectedCount,
                                               status: .success)
            }
        }
    }

    private func archiveSelection() {
        for threadID in selectedGraphThreadIDs {
            Task {
                await graphViewModel.archiveThread(threadID: threadID)
            }
        }
    }

    private func railDragRawThreadIDs(
        for conversation: OrganizerProjection.Conversation
    ) -> [String] {
        guard selectionController.selectedConversationIDs.contains(conversation.id) else {
            return conversation.rawConversationIDs
        }
        let conversationsByID = Dictionary(uniqueKeysWithValues: allConversations(in: projection).map {
            ($0.id, $0)
        })
        return Set(selectionController.selectedIDsInFocusOrder.flatMap {
            conversationsByID[$0]?.rawConversationIDs ?? []
        }).sorted()
    }

    private var selectedGraphThreadIDs: [String] {
        let graphNodeIDs = graphViewModel.graphNodeIDs(for: threadViewModel.selectedNodeIDs)
        return Set(graphNodeIDs.compactMap {
            graphViewModel.actionTarget(for: $0)?.threadID
        }).sorted()
    }

    private func allConversations(
        in currentProjection: OrganizerProjection
    ) -> [OrganizerProjection.Conversation] {
        currentProjection.visibleConversations
    }

    private func selectionNormalizer() -> OrganizerSelectionController.Normalizer {
        projection.selectionNormalizer
    }

}

private struct OrganizerRail: View {
    let projection: OrganizerProjection
    let isCollapsed: Bool
    let selectedConversationIDs: Set<String>
    let selectedCount: Int
    let textScale: CGFloat
    @ObservedObject var automationCoordinator: GraphAutomationCoordinator
    let folders: [ThreadFolder]
    let onToggleCollapsed: () -> Void
    let onSelect: (OrganizerProjection.Conversation) -> Void
    let onRangeSelect: (OrganizerProjection.Conversation) -> Void
    let onCommandSelect: (OrganizerProjection.Conversation) -> Void
    let dragRawThreadIDs: (OrganizerProjection.Conversation) -> [String]
    let onGroup: () -> Void
    let onMove: () -> Void
    let onArchive: () -> Void
    let canMove: Bool
    let canArchive: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if isCollapsed {
                collapsedContent
            } else {
                expandedContent
            }
        }
        .background(
            GlassBackground(
                cornerRadius: 14,
                fillOpacity: DesignTokens.Opacity.fill(for: colorScheme),
                strokeOpacity: DesignTokens.Opacity.stroke(for: colorScheme),
                shadowOpacity: DesignTokens.Opacity.shadow(for: colorScheme),
                shadowRadius: 10,
                shadowY: 4,
                tintOpacity: DesignTokens.Opacity.tint(for: colorScheme),
                isInteractive: true
            )
        )
        .padding(.leading, 2)
        .padding(.trailing, 6)
        .padding(.bottom, 4)
        .accessibilityIdentifier(AccessibilityID.organizerRail)
        .accessibilityLabel(NSLocalizedString("accessibility.organizer.rail.label",
                                              comment: "Accessibility label for the Unorganized rail"))
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .padding(.horizontal, 10)
            OrganizerRailActions(
                selectedCount: selectedCount,
                textScale: textScale,
                onGroup: onGroup,
                onMove: onMove,
                onArchive: onArchive,
                canMove: canMove,
                canArchive: canArchive
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            OrganizerSuggestionCardsView(coordinator: automationCoordinator,
                                         folders: folders)
            Divider()
                .padding(.horizontal, 10)
            OrganizerRailConversationList(
                conversations: projection.unorganized,
                isFiltering: !projection.normalizedQuery.isEmpty,
                selectedConversationIDs: selectedConversationIDs,
                textScale: textScale,
                onSelect: onSelect,
                onRangeSelect: onRangeSelect,
                onCommandSelect: onCommandSelect,
                dragRawThreadIDs: dragRawThreadIDs,
                onPrepareDrag: prepareDrag(for:),
                onGroup: { performAction(for: $0, action: onGroup) },
                onMove: { performAction(for: $0, action: onMove) },
                onArchive: { performAction(for: $0, action: onArchive) },
                canMove: canMove,
                canArchive: canArchive
            )
        }
    }

    private var collapsedContent: some View {
        VStack(spacing: 6) {
            Button(action: onToggleCollapsed) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("organizer.rail.expand", comment: "Expand the Unorganized rail"))
            .accessibilityIdentifier(AccessibilityID.organizerRailToggle)
            .accessibilityLabel(NSLocalizedString("accessibility.organizer.rail.expand",
                                                  comment: "Accessibility label for expanding the Unorganized rail"))
            .accessibilityHint(NSLocalizedString("accessibility.organizer.rail.expand.hint",
                                                 comment: "Accessibility hint for expanding the Unorganized rail"))

            Text(String(projection.unorganized.count))
                .font(DesignTokens.font(size: 10, weight: .semibold, textScale: textScale))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.organizerRailCount)
                .accessibilityLabel(String.localizedStringWithFormat(
                    NSLocalizedString("accessibility.organizer.rail.count",
                                      comment: "Accessibility label for the Unorganized conversation count"),
                    projection.unorganized.count
                ))

            if !projection.unorganized.isEmpty {
                Divider()
                    .padding(.vertical, 2)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 4) {
                        ForEach(projection.unorganized) { conversation in
                            OrganizerRailRow(
                                conversation: conversation,
                                isSelected: selectedConversationIDs.contains(conversation.id),
                                isCollapsed: true,
                                textScale: textScale,
                                onSelect: { onSelect(conversation) },
                                onRangeSelect: { onRangeSelect(conversation) },
                                onCommandSelect: { onCommandSelect(conversation) },
                                dragRawThreadIDs: dragRawThreadIDs(conversation),
                                onPrepareDrag: { prepareDrag(for: conversation) },
                                onGroup: { performAction(for: conversation, action: onGroup) },
                                onMove: { performAction(for: conversation, action: onMove) },
                                onArchive: { performAction(for: conversation, action: onArchive) },
                                canMove: canMove || !selectedConversationIDs.contains(conversation.id),
                                canArchive: canArchive || !selectedConversationIDs.contains(conversation.id)
                            )
                        }
                    }
                    .padding(.horizontal, 3)
                }
                .scrollIndicators(.hidden)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "tray")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(NSLocalizedString("organizer.rail.title", comment: "Title for the Unorganized rail"))
                    .font(DesignTokens.font(size: 13, weight: .semibold, textScale: textScale))
                    .lineLimit(1)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("organizer.rail.count", comment: "Unorganized rail count"),
                    projection.unorganized.count
                ))
                .font(DesignTokens.font(size: 10, weight: .medium, textScale: textScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onToggleCollapsed) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("organizer.rail.collapse", comment: "Collapse the Unorganized rail"))
            .accessibilityIdentifier(AccessibilityID.organizerRailToggle)
            .accessibilityLabel(NSLocalizedString("accessibility.organizer.rail.collapse",
                                                  comment: "Accessibility label for collapsing the Unorganized rail"))
            .accessibilityHint(NSLocalizedString("accessibility.organizer.rail.collapse.hint",
                                                 comment: "Accessibility hint for collapsing the Unorganized rail"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func prepareDrag(for conversation: OrganizerProjection.Conversation) {
        guard !selectedConversationIDs.contains(conversation.id) else { return }
        onSelect(conversation)
    }

    private func performAction(for conversation: OrganizerProjection.Conversation,
                               action: @escaping () -> Void) {
        guard !selectedConversationIDs.contains(conversation.id) else {
            action()
            return
        }
        onSelect(conversation)
        DispatchQueue.main.async(execute: action)
    }
}

private struct OrganizerRailConversationList: View {
    let conversations: [OrganizerProjection.Conversation]
    let isFiltering: Bool
    let selectedConversationIDs: Set<String>
    let textScale: CGFloat
    let onSelect: (OrganizerProjection.Conversation) -> Void
    let onRangeSelect: (OrganizerProjection.Conversation) -> Void
    let onCommandSelect: (OrganizerProjection.Conversation) -> Void
    let dragRawThreadIDs: (OrganizerProjection.Conversation) -> [String]
    let onPrepareDrag: (OrganizerProjection.Conversation) -> Void
    let onGroup: (OrganizerProjection.Conversation) -> Void
    let onMove: (OrganizerProjection.Conversation) -> Void
    let onArchive: (OrganizerProjection.Conversation) -> Void
    let canMove: Bool
    let canArchive: Bool

    @FocusState private var focusedConversationID: String?

    var body: some View {
        Group {
            if conversations.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(conversations) { conversation in
                            OrganizerRailRow(
                                conversation: conversation,
                                isSelected: selectedConversationIDs.contains(conversation.id),
                                isCollapsed: false,
                                textScale: textScale,
                                onSelect: { onSelect(conversation) },
                                onRangeSelect: { onRangeSelect(conversation) },
                                onCommandSelect: { onCommandSelect(conversation) },
                                dragRawThreadIDs: dragRawThreadIDs(conversation),
                                onPrepareDrag: { onPrepareDrag(conversation) },
                                onGroup: { onGroup(conversation) },
                                onMove: { onMove(conversation) },
                                onArchive: { onArchive(conversation) },
                                canMove: canMove || !selectedConversationIDs.contains(conversation.id),
                                canArchive: canArchive || !selectedConversationIDs.contains(conversation.id)
                            )
                            .focused($focusedConversationID, equals: conversation.id)
                            .id(conversation.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onKeyPress(.upArrow) {
            moveFocus(by: -1)
        }
        .onKeyPress(.downArrow) {
            moveFocus(by: 1)
        }
        .onKeyPress(.return) {
            activateFocusedConversation()
        }
        .onKeyPress(" ") {
            activateFocusedConversation()
        }
    }

    private var emptyState: some View {
        return VStack(alignment: .leading, spacing: 7) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(NSLocalizedString(isFiltering
                                   ? "organizer.rail.empty.filtered.title"
                                   : "organizer.rail.empty.title",
                                   comment: "Empty state title for the Unorganized rail"))
                .font(DesignTokens.font(size: 12, weight: .semibold, textScale: textScale))
            Text(NSLocalizedString(isFiltering
                                   ? "organizer.rail.empty.filtered.detail"
                                   : "organizer.rail.empty.detail",
                                   comment: "Empty state detail for the Unorganized rail"))
                .font(DesignTokens.font(size: 11, textScale: textScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier(AccessibilityID.organizerRailEmpty)
    }

    private func moveFocus(by offset: Int) -> KeyPress.Result {
        guard !conversations.isEmpty else { return .ignored }
        let currentIndex = focusedConversationID.flatMap { id in
            conversations.firstIndex { $0.id == id }
        } ?? (offset > 0 ? -1 : conversations.count)
        let nextIndex = min(max(currentIndex + offset, 0), conversations.count - 1)
        let conversation = conversations[nextIndex]
        focusedConversationID = conversation.id
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            onRangeSelect(conversation)
        } else {
            onSelect(conversation)
        }
        return .handled
    }

    private func activateFocusedConversation() -> KeyPress.Result {
        guard let focusedConversationID,
              let conversation = conversations.first(where: { $0.id == focusedConversationID }) else {
            return .ignored
        }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            onCommandSelect(conversation)
        } else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            onRangeSelect(conversation)
        } else {
            onSelect(conversation)
        }
        return .handled
    }
}

private struct OrganizerRailRow: View {
    let conversation: OrganizerProjection.Conversation
    let isSelected: Bool
    let isCollapsed: Bool
    let textScale: CGFloat
    let onSelect: () -> Void
    let onRangeSelect: () -> Void
    let onCommandSelect: () -> Void
    let dragRawThreadIDs: [String]
    let onPrepareDrag: () -> Void
    let onGroup: () -> Void
    let onMove: () -> Void
    let onArchive: () -> Void
    let canMove: Bool
    let canArchive: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: activate) {
            if isCollapsed {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 27, height: 28)
                    .contentShape(Rectangle())
            } else {
                expandedLabel
            }
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(accessibilityLabel)
        .contextMenu {
            Button {
                onGroup()
            } label: {
                Label(NSLocalizedString("organizer.action.group",
                                        comment: "Create a Group from a rail action menu"),
                      systemImage: "folder.badge.plus")
            }
            Button {
                onMove()
            } label: {
                Label(NSLocalizedString("organizer.action.move",
                                        comment: "Move from a rail action menu"),
                      systemImage: "folder")
            }
            .disabled(!canMove)
            Divider()
            Button {
                onArchive()
            } label: {
                Label(NSLocalizedString("organizer.action.archive",
                                        comment: "Archive from a rail action menu"),
                      systemImage: "archivebox")
            }
            .disabled(!canArchive)
        }
        .onDrag {
            dragItemProvider()
        } preview: {
            Label(dragPreviewLabel, systemImage: "tray.and.arrow.up")
                .font(DesignTokens.font(size: 11, weight: .semibold, textScale: textScale))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule(style: .continuous))
        }
        .accessibilityIdentifier(AccessibilityID.organizerRailRow(conversation.id))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected
                           ? NSLocalizedString("accessibility.organizer.row.selected",
                                               comment: "Accessibility value for a selected organizer row")
                           : "")
        .accessibilityHint(NSLocalizedString("accessibility.organizer.row.hint",
                                             comment: "Accessibility hint for an organizer row"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: NSLocalizedString("accessibility.organizer.row.toggle",
                                                       comment: "VoiceOver action to toggle organizer row selection"),
                             onCommandSelect)
        .accessibilityAction(named: NSLocalizedString("accessibility.organizer.row.extend",
                                                       comment: "VoiceOver action to extend organizer selection"),
                             onRangeSelect)
        .accessibilityAction(named: NSLocalizedString("organizer.action.group",
                                                       comment: "VoiceOver action to create a Group"),
                             onGroup)
        .accessibilityAction(named: NSLocalizedString("organizer.action.move",
                                                       comment: "VoiceOver action to move selected conversations")) {
            guard canMove else { return }
            onMove()
        }
        .accessibilityAction(named: NSLocalizedString("organizer.action.archive",
                                                       comment: "VoiceOver action to archive selected conversations")) {
            guard canArchive else { return }
            onArchive()
        }
        .padding(.horizontal, 2)
    }

    private var expandedLabel: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(conversation.displayTitle)
                        .font(DesignTokens.font(size: 12,
                                                weight: isSelected ? .semibold : .medium,
                                                textScale: textScale))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text(conversation.lastUpdated.formatted(date: .abbreviated, time: .shortened))
                        .font(DesignTokens.font(size: 9, weight: .medium, textScale: textScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(senderText)
                    .font(DesignTokens.font(size: 10, textScale: textScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !conversation.snippet.isEmpty {
                    Text(conversation.snippet)
                        .font(DesignTokens.font(size: 10, textScale: textScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Label(String(conversation.messageCount), systemImage: "bubble.left")
                    if conversation.unreadCount > 0 {
                        Label(String(conversation.unreadCount), systemImage: "envelope.badge")
                    }
                }
                .font(DesignTokens.font(size: 9, weight: .medium, textScale: textScale))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected
                  ? Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.12)
                  : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.42) : Color.clear,
                            lineWidth: 1)
            )
    }

    private var senderText: String {
        let sender = conversation.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        return sender.isEmpty
            ? NSLocalizedString("organizer.rail.sender.unknown",
                                comment: "Fallback sender for an organizer row")
            : sender
    }

    private var accessibilityLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("organizer.rail.row.label",
                              comment: "Accessibility label for an organizer conversation row"),
            conversation.displayTitle,
            senderText,
            conversation.lastUpdated.formatted(date: .abbreviated, time: .shortened),
            conversation.messageCount,
            conversation.unreadCount
        )
    }

    private var dragPreviewLabel: String {
        if dragRawThreadIDs.count == 1 {
            return conversation.displayTitle
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("organizer.rail.drag.count",
                              comment: "Number of conversations in a rail drag"),
            dragRawThreadIDs.count
        )
    }

    private func dragItemProvider() -> NSItemProvider {
        onPrepareDrag()
        let provider = NSItemProvider()
        guard let payload = OrganizerRailDragPayload(rawThreadIDs: dragRawThreadIDs),
              let data = try? payload.encoded() else {
            return provider
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: OrganizerRailDragPayload.typeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func activate() {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) {
            onRangeSelect()
        } else if flags.contains(.command) {
            onCommandSelect()
        } else {
            onSelect()
        }
    }
}

private struct OrganizerRailActions: View {
    let selectedCount: Int
    let textScale: CGFloat
    let onGroup: () -> Void
    let onMove: () -> Void
    let onArchive: () -> Void
    let canMove: Bool
    let canArchive: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullActions
            compactActions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.organizerActions)
    }

    private var fullActions: some View {
        HStack(spacing: 5) {
            selectedCountLabel
            Spacer(minLength: 4)
            actionButton(titleKey: "organizer.action.group",
                         helpKey: "organizer.action.group.help",
                         systemImage: "folder.badge.plus",
                         identifier: AccessibilityID.organizerGroupButton,
                         isDisabled: selectedCount == 0,
                         action: onGroup)
            actionButton(titleKey: "organizer.action.move",
                         helpKey: "organizer.action.move.help",
                         systemImage: "folder",
                         identifier: AccessibilityID.organizerMoveButton,
                         isDisabled: !canMove || selectedCount == 0,
                         action: onMove)
            actionButton(titleKey: "organizer.action.archive",
                         helpKey: "organizer.action.archive.help",
                         systemImage: "archivebox",
                         identifier: AccessibilityID.organizerArchiveButton,
                         isDisabled: !canArchive,
                         action: onArchive)
        }
    }

    private var compactActions: some View {
        HStack(spacing: 4) {
            selectedCountLabel
            Spacer(minLength: 2)
            iconButton(titleKey: "organizer.action.group",
                       helpKey: "organizer.action.group.help",
                       systemImage: "folder.badge.plus",
                       identifier: AccessibilityID.organizerGroupButton,
                       isDisabled: selectedCount == 0,
                       action: onGroup)
            iconButton(titleKey: "organizer.action.move",
                       helpKey: "organizer.action.move.help",
                       systemImage: "folder",
                       identifier: AccessibilityID.organizerMoveButton,
                       isDisabled: !canMove || selectedCount == 0,
                       action: onMove)
            iconButton(titleKey: "organizer.action.archive",
                       helpKey: "organizer.action.archive.help",
                       systemImage: "archivebox",
                       identifier: AccessibilityID.organizerArchiveButton,
                       isDisabled: !canArchive,
                       action: onArchive)
        }
    }

    private var selectedCountLabel: some View {
        Text(String.localizedStringWithFormat(
            NSLocalizedString(selectedCount == 0
                              ? "organizer.selection.none"
                              : "organizer.selection.count",
                              comment: "Organizer selection count"),
            selectedCount
        ))
        .font(DesignTokens.font(size: 10, weight: .medium, textScale: textScale))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityIdentifier(AccessibilityID.organizerSelectedCount)
        .accessibilityLabel(String.localizedStringWithFormat(
            NSLocalizedString("accessibility.organizer.selection.count",
                              comment: "Accessibility label for organizer selection count"),
            selectedCount
        ))
    }

    private func actionButton(titleKey: String,
                              helpKey: String,
                              systemImage: String,
                              identifier: String,
                              isDisabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(NSLocalizedString(titleKey, comment: "Organizer action button"),
                  systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(DesignTokens.font(size: 10, weight: .semibold, textScale: textScale))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDisabled)
        .help(NSLocalizedString(helpKey, comment: "Organizer action button help"))
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(NSLocalizedString(titleKey, comment: "Organizer action button"))
    }

    private func iconButton(titleKey: String,
                            helpKey: String,
                            systemImage: String,
                            identifier: String,
                            isDisabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDisabled)
        .help(NSLocalizedString(helpKey, comment: "Organizer action button help"))
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(NSLocalizedString(titleKey, comment: "Organizer action button"))
    }
}
