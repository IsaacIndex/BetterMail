import SwiftUI

internal struct GraphCanvasView: View {
    @ObservedObject internal var threadViewModel: ThreadCanvasViewModel
    @ObservedObject internal var graphViewModel: GraphCanvasViewModel
    @ObservedObject internal var graphSettings: GraphCanvasSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    internal let topInset: CGFloat
    internal let bottomChromeInset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var audio = GraphAudio()
    @State private var isLegendExpanded = false
    @State private var reviewedGrouping: GraphGrouping?

    internal var body: some View {
        GeometryReader { proxy in
            ZStack {
                GraphRepresentable(graphViewModel: graphViewModel,
                                   settings: graphSettings,
                                   selectedNodeID: threadViewModel.selectedNodeID,
                                   selectedNodeIDs: threadViewModel.selectedNodeIDs,
                                   reduceMotion: reduceMotion,
                                   colorScheme: colorScheme,
                                   textScale: displaySettings.textScale,
                                   audio: audio,
                                   onSelectRootNode: { nodeID, isAdditive in
                                       threadViewModel.selectNode(id: nodeID, additive: isAdditive)
                                       if nodeID == nil {
                                           threadViewModel.selectFolder(id: nil)
                                       }
                                   },
                                   onToggleActionItem: toggleActionItem(forGraphNodeID:),
                                   isActionItem: isActionItem(forGraphNodeID:))
                    .accessibilityIdentifier(AccessibilityID.graphCanvas)
                    .accessibilityLabel(NSLocalizedString("graph.accessibility.canvas",
                                                          comment: "Accessibility label for graph canvas"))
                VStack {
                    HStack {
                        GraphLegend(isExpanded: $isLegendExpanded)
                            .padding(.top, 16)
                            .padding(.leading, 18)
                        Spacer(minLength: 0)
                        ObsidianGraphControls(settings: graphSettings,
                                              searchQuery: $threadViewModel.searchQuery,
                                              data: graphViewModel.data,
                                              totalBranchCount: graphViewModel.totalBranchCount,
                                              textScale: displaySettings.textScale)
                            .padding(.top, 16)
                            .padding(.trailing, 18)
                    }
                    Spacer(minLength: 0)
                }
                .zIndex(1)
                if let hoverItem = graphViewModel.hoverItem {
                    GraphHoverCard(item: hoverItem, textScale: displaySettings.textScale)
                        .position(hoverPosition(for: hoverItem, in: proxy.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .allowsHitTesting(false)
                        .zIndex(2)
                }
                VStack {
                    Spacer()
                    if let grouping = graphViewModel.selectedGrouping {
                        GraphGroupingActionBar(grouping: grouping,
                                               textScale: displaySettings.textScale,
                                               onReview: { reviewedGrouping = grouping },
                                               onNotThisGroup: { rejectGrouping(grouping) },
                                               onHideTopic: { hideGrouping(grouping) },
                                               onOpenFolder: { openFolder(grouping) })
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if selectedActionTarget == nil,
                       graphViewModel.selectedGrouping == nil,
                       let instruction = pruneInstruction {
                        Label(instruction.title, systemImage: instruction.systemImage)
                            .font(DesignTokens.font(size: 11,
                                                   weight: .semibold,
                                                   textScale: displaySettings.textScale))
                            .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(DesignTokens.Graph.AppTheme.panel)
                                    .shadow(color: Color.black.opacity(0.08), radius: 12, y: 5)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
                            )
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    GraphToolbar(viewModel: graphViewModel,
                                 settings: graphSettings,
                                 textScale: displaySettings.textScale,
                                 selectedThreadID: selectedActionTarget?.threadID)
                    .padding(.bottom, overlayBottomPadding)
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        GraphCompostRing(entries: graphViewModel.compostEntries,
                                         textScale: displaySettings.textScale,
                                         onRestore: restore)
                        .padding(.trailing, 24)
                        .padding(.bottom, overlayBottomPadding)
                    }
                }
            }
        }
        .padding(.top, topInset)
        .background(DesignTokens.Graph.AppTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            warmAudioIfNeeded()
            graphViewModel.setGraphEnrichmentActive(true)
            syncData()
        }
        .onDisappear {
            graphViewModel.setGraphEnrichmentActive(false)
        }
        .onChange(of: graphSettings.soundOn) { _, _ in
            warmAudioIfNeeded()
        }
        .onChange(of: graphSettings.visibleBranchCount) { _, _ in syncData() }
        .onChange(of: graphSettings.dismissedSuggestedTopicIDs) { _, _ in syncData() }
        .onChange(of: graphSettings.hiddenSuggestedTopics) { _, _ in syncData() }
        .onReceive(threadViewModel.$roots) { _ in syncData() }
        .onReceive(threadViewModel.$searchQuery) { _ in syncData() }
        .onReceive(threadViewModel.$activeMailboxScope) { _ in syncData() }
        .onReceive(threadViewModel.$timelineTagsByNodeID) { _ in syncData() }
        .onReceive(threadViewModel.$nodeSummaries) { _ in syncData() }
        .onReceive(threadViewModel.$threadFolders) { _ in syncData() }
        .onReceive(threadViewModel.$folderMembershipByThreadID) { _ in syncData() }
        .sheet(item: $graphViewModel.snipMoveRequest) { request in
            SnipMoveSheet(request: request,
                          mailboxAccounts: threadViewModel.mailboxAccounts,
                          settings: graphSettings,
                          onConfirm: { path, account in
                              Task { await confirmSnip(request: request, path: path, account: account) }
                          },
                          onCancel: graphViewModel.cancelSnip)
        }
        .sheet(isPresented: $graphViewModel.isSettingsPresented) {
            GraphSettingsSheet(settings: graphSettings)
        }
        .sheet(item: $reviewedGrouping) { grouping in
            GraphSuggestionReviewSheet(
                grouping: grouping,
                impactProvider: { threadIDs in
                    threadViewModel.graphFolderSuggestionImpact(for: threadIDs)
                },
                confirmFolder: { title, threadIDs in
                    _ = try await threadViewModel.confirmGraphFolderSuggestion(
                        title: title,
                        threadIDs: threadIDs
                    )
                },
                onNotThisGroup: { rejectGrouping(grouping) },
                onHideTopic: { hideGrouping(grouping) },
                onCreated: completeReviewedGrouping
            )
        }
    }

    internal func handleKey(_ key: GraphKeyboardCommand) -> KeyPress.Result {
        switch key {
        case .snip:
            performSnipAction()
        case .archive:
            performArchiveAction()
        case .escape:
            graphViewModel.exitPruneMode()
        case .water:
            guard let threadID = graphViewModel.selectedGraphNodeID(for: threadViewModel.selectedNodeID),
                  graphViewModel.data.threadByID[threadID] != nil else { return .ignored }
            graphViewModel.water(threadID: threadID, settings: graphSettings)
            audio.play(.water, settings: graphSettings)
        case .zoomIn:
            graphViewModel.zoomIn()
        case .zoomOut:
            graphViewModel.zoomOut()
        case .reset:
            graphViewModel.resetViewport()
        }
        return .handled
    }

    private var reduceMotion: Bool {
        graphSettings.shouldReduceMotion(systemReduceMotion: systemReduceMotion)
    }

    private var overlayBottomPadding: CGFloat {
        24 + bottomChromeInset
    }

    private var selectedActionTarget: GraphThreadActionTarget? {
        graphViewModel.actionTarget(for: threadViewModel.selectedNodeID)
    }

    private var pruneInstruction: (title: String, systemImage: String)? {
        switch graphViewModel.pruneMode {
        case .idle:
            return nil
        case .snip:
            return (
                NSLocalizedString("graph.toolbar.snip.instruction",
                                  comment: "Instruction shown while choosing a graph branch to snip"),
                "scissors"
            )
        case .archive:
            return (
                NSLocalizedString("graph.toolbar.archive.instruction",
                                  comment: "Instruction shown while choosing a graph branch to archive"),
                "archivebox"
            )
        }
    }

    private func sourceMessage(withID messageID: String) -> EmailMessage? {
        for root in threadViewModel.roots {
            if let message = sourceMessage(withID: messageID, in: root) {
                return message
            }
        }
        return nil
    }

    private func sourceMessage(withID messageID: String, in node: ThreadNode) -> EmailMessage? {
        if node.id == messageID {
            return node.message
        }
        for child in node.children {
            if let message = sourceMessage(withID: messageID, in: child) {
                return message
            }
        }
        return nil
    }

    private func isActionItem(forGraphNodeID graphNodeID: String) -> Bool {
        guard let target = graphViewModel.actionTarget(for: graphNodeID),
              let message = sourceMessage(withID: target.rawMessageID) else {
            return false
        }
        return threadViewModel.actionItemIDs.contains(message.messageID)
    }

    private func toggleActionItem(forGraphNodeID graphNodeID: String) {
        guard let target = graphViewModel.actionTarget(for: graphNodeID),
              let message = sourceMessage(withID: target.rawMessageID) else {
            return
        }
        toggleActionItem(message: message, target: target)
    }

    private func toggleActionItem(message: EmailMessage, target: GraphThreadActionTarget) {
        if threadViewModel.actionItemIDs.contains(message.messageID) {
            threadViewModel.removeActionItem(message: message)
            return
        }
        let folderID = message.threadID.flatMap { threadViewModel.folderMembershipByThreadID[$0] }
        threadViewModel.addActionItem(message: message,
                                      folderID: folderID,
                                      tags: target.tags)
    }

    private func performSnipAction() {
        graphViewModel.activateSnip(selectedThreadID: selectedActionTarget?.threadID)
    }

    private func performArchiveAction() {
        graphViewModel.activateArchive(selectedThreadID: selectedActionTarget?.threadID)
    }

    @MainActor
    private func warmAudioIfNeeded() {
        guard graphSettings.soundOn else { return }
        audio.warm()
    }

    private func syncData() {
        graphViewModel.onArchiveStateChanged = { [weak threadViewModel] in
            threadViewModel?.refreshGraphArchiveVisibility()
        }
        graphViewModel.update(roots: threadViewModel.roots,
                              searchQuery: threadViewModel.searchQuery,
                              tagsByNodeID: threadViewModel.timelineTagsByNodeID,
                              summariesByNodeID: threadViewModel.nodeSummaries,
                              folders: threadViewModel.threadFolders,
                              folderMembershipByThreadID: threadViewModel.folderMembershipByThreadID,
                              dismissedSuggestedTopicIDs: graphSettings.dismissedSuggestedTopicIDs,
                              hiddenSuggestedTopics: graphSettings.hiddenSuggestedTopics,
                              showsArchivedThreads: threadViewModel.activeMailboxScope == .graphArchive,
                              branchPageSize: graphSettings.visibleBranchCount)
        for root in threadViewModel.roots.prefix(10) {
            threadViewModel.requestTimelineTagsIfNeeded(for: root)
        }
    }

    private func hoverPosition(for item: GraphHoverItem, in size: CGSize) -> CGPoint {
        let rawPoint: CGPoint
        switch item {
        case .grouping(_, let point), .thread(_, let point), .remaining(_, let point), .message(_, let point):
            rawPoint = point
        }
        let x = min(max(rawPoint.x + 150, 140), max(140, size.width - 140))
        let y = min(max(size.height - rawPoint.y + 76, 90), max(90, size.height - 90))
        return CGPoint(x: x, y: y)
    }

    private func confirmSnip(request: SnipMoveRequest, path: String, account: String?) async {
        do {
            try await graphViewModel.confirmSnip(request: request,
                                                 destinationPath: path,
                                                 account: account)
            threadViewModel.showToast(NSLocalizedString("graph.snip.success",
                                                        comment: "Graph snip success toast"),
                                      style: .success)
        } catch {
            graphViewModel.cancelSnip()
            threadViewModel.showError(error.localizedDescription)
        }
    }

    private func restore(_ entry: GraphCompostEntry) {
        Task {
            do {
                try await graphViewModel.restore(entry)
                threadViewModel.showToast(NSLocalizedString("graph.restore.success",
                                                            comment: "Graph restore success toast"),
                                          style: .success)
            } catch {
                threadViewModel.showError(error.localizedDescription)
            }
        }
    }

    private func rejectGrouping(_ grouping: GraphGrouping) {
        guard grouping.isSuggestion,
              let dismissalID = grouping.suggestionDismissalID else {
            return
        }
        graphSettings.rejectSuggestedGroup(id: dismissalID)
        graphViewModel.selectGrouping(id: nil)
        threadViewModel.showToast(NSLocalizedString("graph.group.not_this_group.success",
                                                    comment: "Exact graph topic group rejection toast"),
                                  style: .success)
    }

    private func hideGrouping(_ grouping: GraphGrouping) {
        guard grouping.isSuggestion,
              let topic = grouping.normalizedTopic ?? grouping.sourceTag else { return }
        graphSettings.hideSuggestedTopic(topic)
        graphViewModel.selectGrouping(id: nil)
        threadViewModel.showToast(NSLocalizedString("graph.group.hide_topic.success",
                                                    comment: "Hidden graph topic toast"),
                                  style: .success)
    }

    private func completeReviewedGrouping() {
        graphViewModel.selectGrouping(id: nil)
        syncData()
        threadViewModel.showToast(NSLocalizedString("graph.group.confirm.success",
                                                    comment: "Graph grouping confirmation success toast"),
                                  style: .success)
    }

    private func openFolder(_ grouping: GraphGrouping) {
        guard let folderID = grouping.sourceFolderID else { return }
        graphViewModel.selectGrouping(id: nil)
        threadViewModel.selectFolder(id: folderID)
    }
}

private struct GraphCanopyStatus: View {
    let visibleCount: Int
    let totalCount: Int
    let textScale: CGFloat

    private var needsTrim: Bool { totalCount > 10 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Label(String.localizedStringWithFormat(
                NSLocalizedString("graph.canopy.count",
                                  comment: "Graph canopy visible and total branch count"),
                visibleCount,
                totalCount
            ), systemImage: needsTrim ? "leaf.fill" : "leaf")
                .font(DesignTokens.font(size: 11, weight: .semibold, textScale: textScale))
            Text(needsTrim
                 ? NSLocalizedString("graph.canopy.trim",
                                     comment: "Graph canopy asks the user to trim branches")
                 : NSLocalizedString("graph.canopy.stable",
                                     comment: "Graph canopy is at a stable branch count"))
                .font(DesignTokens.font(size: 9.5, textScale: textScale))
                .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
        }
        .foregroundStyle(needsTrim ? DesignTokens.Graph.AppTheme.snip : DesignTokens.Graph.AppTheme.ink)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct GraphGroupingActionBar: View {
    let grouping: GraphGrouping
    let textScale: CGFloat
    let onReview: () -> Void
    let onNotThisGroup: () -> Void
    let onHideTopic: () -> Void
    let onOpenFolder: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: grouping.isSuggestion ? "sparkles" : "folder.fill")
                .foregroundStyle(DesignTokens.Graph.AppTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                if grouping.isSuggestion {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("graph.group.suggestion.presentation",
                                          comment: "Potential graph topic presentation"),
                        grouping.title,
                        grouping.memberCount
                    ))
                    .font(DesignTokens.font(size: 11.5, weight: .semibold, textScale: textScale))
                    .fixedSize(horizontal: false, vertical: true)
                    if let reason = grouping.supportingReason, !reason.isEmpty {
                        Text(reason)
                            .font(DesignTokens.font(size: 9.5, textScale: textScale))
                            .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                            .lineLimit(2)
                    }
                } else {
                    Text(grouping.title)
                        .font(DesignTokens.font(size: 11.5, weight: .semibold, textScale: textScale))
                        .lineLimit(1)
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("graph.group.folder.detail",
                                          comment: "Graph grouping branch detail"),
                        grouping.memberCount
                    ))
                    .font(DesignTokens.font(size: 9.5, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            if grouping.isSuggestion {
                Button(NSLocalizedString("graph.group.not_this_group",
                                         comment: "Reject this exact graph topic group"),
                       action: onNotThisGroup)
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.graphSuggestionNotThisGroupAction)
                Button(NSLocalizedString("graph.group.hide_topic",
                                         comment: "Hide a graph topic across member changes"),
                       action: onHideTopic)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.graphSuggestionHideTopicAction)
            }
            Button(action: grouping.isSuggestion ? onReview : onOpenFolder) {
                Label(grouping.isSuggestion
                      ? NSLocalizedString("graph.group.review.action",
                                          comment: "Review and edit a graph topic suggestion")
                      : NSLocalizedString("graph.group.open_folder",
                                          comment: "Open a confirmed graph folder"),
                      systemImage: grouping.isSuggestion ? "slider.horizontal.3" : "arrow.right")
                    .font(DesignTokens.font(size: 10.5, weight: .semibold, textScale: textScale))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Graph.AppTheme.accent)
            .accessibilityIdentifier(AccessibilityID.graphSuggestionReviewAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignTokens.Graph.AppTheme.panel)
                .shadow(color: Color.black.opacity(0.10), radius: 18, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(grouping.isSuggestion
                        ? DesignTokens.Graph.AppTheme.accent.opacity(0.55)
                        : DesignTokens.Graph.AppTheme.line,
                        style: StrokeStyle(lineWidth: 1,
                                           dash: grouping.isSuggestion ? [5, 4] : []))
        )
    }
}

private struct GraphLegend: View {
    @Binding fileprivate var isExpanded: Bool

    fileprivate var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                legendRow(title: NSLocalizedString("graph.legend.you.title",
                                                   comment: "Graph legend current user node title"),
                          detail: NSLocalizedString("graph.legend.you.detail",
                                                    comment: "Graph legend current user node detail")) {
                    Circle()
                        .fill(DesignTokens.Graph.AppTheme.panel)
                        .overlay(Circle().stroke(DesignTokens.Graph.AppTheme.accent, lineWidth: 2))
                        .frame(width: 21, height: 21)
                }
                legendRow(title: NSLocalizedString("graph.legend.thread.title",
                                                   comment: "Graph legend thread node title"),
                          detail: NSLocalizedString("graph.legend.thread.detail",
                                                    comment: "Graph legend thread node detail")) {
                    HStack(spacing: 3) {
                        legendCircle(stroke: DesignTokens.Graph.AppTheme.inkQuaternary, lineWidth: 1)
                        legendCircle(stroke: DesignTokens.Graph.AppTheme.inkSecondary, lineWidth: 1.4)
                        legendCircle(stroke: DesignTokens.Graph.AppTheme.ink, lineWidth: 1.9)
                    }
                }
                legendRow(title: NSLocalizedString("graph.legend.folder.title",
                                                   comment: "Graph legend folder branch title"),
                          detail: NSLocalizedString("graph.legend.folder.detail",
                                                    comment: "Graph legend folder branch detail")) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DesignTokens.Graph.AppTheme.accent)
                }
                legendRow(title: NSLocalizedString("graph.legend.ghost.title",
                                                   comment: "Graph legend ghost branch title"),
                          detail: NSLocalizedString("graph.legend.ghost.detail",
                                                    comment: "Graph legend ghost branch detail")) {
                    ZStack {
                        Circle()
                            .stroke(DesignTokens.Graph.AppTheme.accent,
                                    style: StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DesignTokens.Graph.AppTheme.accent)
                    }
                    .frame(width: 22, height: 22)
                }
                legendRow(title: NSLocalizedString("graph.legend.message.title",
                                                   comment: "Graph legend message node title"),
                          detail: NSLocalizedString("graph.legend.message.detail",
                                                    comment: "Graph legend message node detail")) {
                    HStack(spacing: -4) {
                        GraphLegendLeafShape()
                            .fill(DesignTokens.Graph.AppTheme.panel)
                            .overlay(GraphLegendLeafShape().stroke(DesignTokens.Graph.AppTheme.ink, lineWidth: 1))
                            .frame(width: 21, height: 15)
                        GraphLegendLeafShape()
                            .fill(DesignTokens.Graph.AppTheme.accent)
                            .overlay(GraphLegendLeafShape().stroke(DesignTokens.Graph.AppTheme.ink.opacity(0.55),
                                                                   lineWidth: 0.8))
                            .frame(width: 21, height: 15)
                    }
                }
                legendRow(title: NSLocalizedString("graph.legend.remaining.title",
                                                   comment: "Graph legend remaining branch title"),
                          detail: NSLocalizedString("graph.legend.remaining.detail",
                                                    comment: "Graph legend remaining branch detail")) {
                    ZStack {
                        Circle()
                            .stroke(DesignTokens.Graph.AppTheme.archive,
                                    style: StrokeStyle(lineWidth: 1.4,
                                                       lineCap: .round,
                                                       dash: [4, 3]))
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignTokens.Graph.AppTheme.archive)
                    }
                    .frame(width: 23, height: 23)
                }
                legendRow(title: NSLocalizedString("graph.legend.branch.title",
                                                   comment: "Graph legend branch line title"),
                          detail: NSLocalizedString("graph.legend.branch.detail",
                                                    comment: "Graph legend branch line detail")) {
                    VStack(spacing: 5) {
                        GraphLegendCurve()
                            .stroke(DesignTokens.Graph.AppTheme.inkTertiary,
                                    style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                        GraphLegendCurve()
                            .stroke(DesignTokens.Graph.AppTheme.inkQuaternary,
                                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    }
                    .frame(width: 32, height: 20)
                }
                legendRow(title: NSLocalizedString("graph.legend.archive.title",
                                                   comment: "Graph legend archive branch title"),
                          detail: NSLocalizedString("graph.legend.archive.detail",
                                                    comment: "Graph legend archive branch detail")) {
                    GraphLegendCurve()
                        .stroke(DesignTokens.Graph.AppTheme.archive,
                                style: StrokeStyle(lineWidth: 1.5,
                                                   lineCap: .round,
                                                   lineJoin: .round,
                                                   dash: [5, 4]))
                        .frame(width: 32, height: 18)
                }
            }
            .padding(.top, 8)
        } label: {
            Label(NSLocalizedString("graph.legend.title", comment: "Graph legend disclosure title"),
                  systemImage: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
        }
        .font(.system(size: 10))
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .frame(width: isExpanded ? 286 : 116, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 8)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .accessibilityIdentifier("graph.legend")
    }

    private func legendCircle(stroke: Color, lineWidth: CGFloat) -> some View {
        Circle()
            .fill(DesignTokens.Graph.AppTheme.panel)
            .overlay(Circle().stroke(stroke, lineWidth: lineWidth))
            .frame(width: 15, height: 15)
    }

    private func legendRow<Icon: View>(title: String,
                                       detail: String,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon()
                .frame(width: 34, height: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct GraphLegendLeafShape: Shape {
    fileprivate func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control: CGPoint(x: rect.minX + rect.width * 0.16,
                                           y: rect.minY - rect.height * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: midY),
                          control: CGPoint(x: rect.maxX - rect.width * 0.16,
                                           y: rect.minY - rect.height * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX - rect.width * 0.16,
                                           y: rect.maxY + rect.height * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: midY),
                          control: CGPoint(x: rect.minX + rect.width * 0.16,
                                           y: rect.maxY + rect.height * 0.04))
        path.closeSubpath()
        return path
    }
}

private struct GraphLegendCurve: Shape {
    fileprivate func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 4))
        path.addCurve(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 4),
                      control1: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.midY + 4),
                      control2: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.midY - 4))
        return path
    }
}

internal enum GraphKeyboardCommand {
    case snip
    case archive
    case escape
    case water
    case zoomIn
    case zoomOut
    case reset
}
