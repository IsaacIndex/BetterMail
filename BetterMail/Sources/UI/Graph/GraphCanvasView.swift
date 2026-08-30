import SwiftUI

private struct OrganizerLiveDropAttempt: Equatable, Sendable {
    let id: UUID
    let itemCount: Int
    var hadVisibleHighlight: Bool
    var destination: OrganizerDropDestinationKind?
    var didRelease: Bool
}

private func recordOrganizerLiveDropCompletion(
    recorder: OrganizerMetricsRecorder,
    attempt: OrganizerLiveDropAttempt,
    mutationSucceeded: Bool,
    requestedOutcome: OrganizerMetricOutcome
) async {
    if !attempt.didRelease {
        let releaseOutcome: OrganizerMetricOutcome = requestedOutcome == .cancelled
            ? .cancelled
            : .failure
        _ = await recorder.recordEvent(
            .dropRelease,
            count: attempt.itemCount,
            status: releaseOutcome,
            failureReason: releaseOutcome == .cancelled ? .cancelled : .invalidTarget
        )
    }

    let acceptedDestination = attempt.destination == .emptyCanvas
        || attempt.destination == .confirmedGroup
    let highlightSatisfied = attempt.destination == .emptyCanvas
        || (attempt.destination == .confirmedGroup && attempt.hadVisibleHighlight)
    let succeeded = requestedOutcome == .success
        && mutationSucceeded
        && acceptedDestination
        && highlightSatisfied
    let outcome: OrganizerMetricOutcome
    if requestedOutcome == .cancelled {
        outcome = .cancelled
    } else {
        outcome = succeeded ? .success : .failure
    }
    let failureReason: OrganizerMetricCoarseFailureReason? = outcome == .success
        ? nil
        : (outcome == .cancelled ? .cancelled : .invalidTarget)
    _ = await recorder.recordEvent(
        .dropOutcome,
        count: attempt.itemCount,
        status: outcome,
        failureReason: failureReason
    )
    try? await recorder.recordRuntimeDrop(
        source: .livePointer,
        attemptCount: 1,
        successCount: outcome == .success ? 1 : 0,
        invalidTargetMutationCount: 0,
        outcome: outcome
    )
    if outcome == .failure || outcome == .cancelled {
        _ = await recorder.failActiveTimedEvents(
            outcome: outcome,
            failureReason: failureReason ?? .actionFailure
        )
    }
}

internal struct GraphCanvasView: View {
    @ObservedObject internal var threadViewModel: ThreadCanvasViewModel
    @ObservedObject internal var graphViewModel: GraphCanvasViewModel
    @ObservedObject internal var automationCoordinator: GraphAutomationCoordinator
    @ObservedObject internal var graphSettings: GraphCanvasSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    internal let topInset: CGFloat
    internal let bottomChromeInset: CGFloat
    internal let onRenderedOrganizerReceipt: OrganizerRenderedGraphReceiptHandler
    internal let onOrganizerSelectGraphNode: (String?, OrganizerPointerSelectionIntent) -> Void
    internal let onOrganizerLassoGraphNodeIDs: (Set<String>, Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var audio = GraphAudio()
    @State private var isLegendExpanded = false
    @State private var reviewedGrouping: GraphGrouping?
    @State private var restoringHistoryEntryIDs: Set<String> = []
    @State private var pendingGroupComposer: OrganizerPendingGroupComposer?
    @State private var liveDropAttempt: OrganizerLiveDropAttempt?
    @State private var dropMetricsCoordinator = OrganizerDropMetricsCoordinator()
    @State private var previousMetricSearchQuery = ""
    @State private var retrievalStartTask: Task<Bool, Never>?
    @State private var hasScheduledRetrievalVisibleMetric = false
    @State private var retrievalGeneration = 0
    @State private var isMetricRetrievalActive = false

    internal var body: some View {
        GeometryReader { proxy in
            ZStack {
                GraphRepresentable(graphViewModel: graphViewModel,
                                   settings: graphSettings,
                                   selectedNodeID: threadViewModel.selectedNodeID,
                                   selectedNodeIDs: threadViewModel.selectedNodeIDs,
                                   isLassoSelectionActive: graphViewModel.isLassoSelectionActive,
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
                                   onSelectGraphNodeWithIntent: onOrganizerSelectGraphNode,
                                   onLassoGraphNodeIDs: onOrganizerLassoGraphNodeIDs,
                                   onToggleActionItem: toggleActionItem(forGraphNodeID:),
                                   isActionItem: isActionItem(forGraphNodeID:),
                                   onMoveThreadToFolder: moveGraphThread(_:toFolderID:),
                                   onMoveThreadsToFolder: moveGraphThreads(_:toFolderID:),
                                   onCreateGroupAtCanvasPoint: { threadIDs, overlayPoint, worldPoint in
                                       pendingGroupComposer = OrganizerPendingGroupComposer(
                                           rawThreadIDs: threadIDs,
                                           overlayPoint: overlayPoint,
                                           worldPoint: worldPoint,
                                           dropAttemptID: liveDropAttempt?.id
                                       )
                                   },
                                   onDropLifecycle: handleDropLifecycle(_:),
                                   onRenderedOrganizerSnapshot: handleRenderedOrganizerSnapshot(_:))
                    .accessibilityIdentifier(AccessibilityID.graphCanvas)
                    .accessibilityLabel(NSLocalizedString("graph.accessibility.canvas",
                                                          comment: "Accessibility label for graph canvas"))
                VStack {
                    HStack(alignment: .top) {
                        GraphLegend(isExpanded: $isLegendExpanded)
                            .padding(.top, 16)
                            .padding(.leading, 18)
                        Spacer(minLength: 0)
                        ObsidianGraphControls(settings: graphSettings,
                                              data: graphViewModel.data,
                                              textScale: displaySettings.textScale,
                                              canUndoLayoutReset: graphViewModel.canUndoSpatialLayoutReset,
                                              onResetLayout: graphViewModel.resetSpatialLayout,
                                              onUndoLayoutReset: graphViewModel.undoSpatialLayoutReset)
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
                if let pendingGroupComposer {
                    OrganizerInlineGroupComposer(
                        request: pendingGroupComposer,
                        textScale: displaySettings.textScale,
                        onCancel: {
                            cancelPendingGroupComposer(pendingGroupComposer)
                        },
                        onConfirm: { title in
                            createGroup(from: pendingGroupComposer, title: title)
                        }
                    )
                    .position(composerPosition(for: pendingGroupComposer.overlayPoint,
                                               in: proxy.size))
                    .zIndex(5)
                }
                VStack {
                    Spacer()
                    if let grouping = graphViewModel.selectedGrouping {
                        if grouping.isSuggestion {
                            GraphGroupingActionBar(grouping: grouping,
                                                  textScale: displaySettings.textScale,
                                                  onReview: { reviewedGrouping = grouping },
                                                  onNotThisGroup: { rejectGrouping(grouping) },
                                                  onHideTopic: { hideGrouping(grouping) },
                                                  onOpenFolder: { openFolder(grouping) })
                                .anchorPreference(key: GraphBottomOverlayAnchorPreferenceKey.self,
                                                  value: .bounds) {
                                    GraphBottomOverlayAnchors(suggestionActionBar: $0)
                                }
                                .padding(.bottom, 8)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            GraphGroupingActionBar(grouping: grouping,
                                                  textScale: displaySettings.textScale,
                                                  onReview: { reviewedGrouping = grouping },
                                                  onNotThisGroup: { rejectGrouping(grouping) },
                                                  onHideTopic: { hideGrouping(grouping) },
                                                  onOpenFolder: { openFolder(grouping) })
                                .padding(.bottom, 8)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    if graphViewModel.snipPhase == .staging {
                        HStack(spacing: 10) {
                            Label(snipInstructionTitle, systemImage: "scissors")
                            Divider().frame(height: 14)
                            Button(NSLocalizedString("graph.snip.cancel_snipping",
                                                     comment: "Cancel the staged Snip session")) {
                                graphViewModel.discardSnipSession()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(DesignTokens.Graph.AppTheme.snip)
                            .accessibilityIdentifier(AccessibilityID.graphSnipCancelSession)
                        }
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
                    } else if selectedActionTarget == nil,
                              graphViewModel.selectedGrouping == nil,
                              let instruction = interactionInstruction {
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
                                 selectedThreadID: selectedActionTarget?.threadID,
                                 restoreHistoryEntries: graphViewModel.compostEntries,
                                 organizationHistoryItems: graphViewModel.organizationHistoryItems,
                                 restoringHistoryEntryIDs: restoringHistoryEntryIDs,
                                 automationAttentionCount: automationCoordinator.attentionCount,
                                 onRestoreHistoryEntry: restore,
                                 onDismissHistoryEntry: dismiss,
                                 onAutomation: threadViewModel.presentGraphAutomation)
                        .padding(.bottom, overlayBottomPadding)
                        .anchorPreference(key: GraphBottomOverlayAnchorPreferenceKey.self,
                                          value: .bounds) {
                            GraphBottomOverlayAnchors(toolbar: $0)
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
            cancelMetricRetrievalIfNeeded()
            graphViewModel.deactivateLassoSelection()
            graphViewModel.flushSpatialStatePersistence()
            graphViewModel.setGraphEnrichmentActive(false)
            graphViewModel.discardSnipSession()
        }
        .onChange(of: graphSettings.soundOn) { _, _ in
            warmAudioIfNeeded()
        }
        .onChange(of: graphSettings.visibleBranchCount) { _, _ in syncData() }
        .onChange(of: graphSettings.visibleBranchesPerNode) { _, _ in syncData() }
        .onChange(of: graphSettings.visibleEmailsPerThread) { _, _ in syncData() }
        .onChange(of: graphSettings.dismissedSuggestedTopicIDs) { _, _ in syncData() }
        .onChange(of: graphSettings.hiddenSuggestedTopics) { _, _ in syncData() }
        .onReceive(threadViewModel.$roots) { _ in syncData() }
        .onReceive(threadViewModel.$searchQuery) { query in
            handleMetricSearchQuery(query)
            syncData(searchQuery: query)
        }
        .onChange(of: threadViewModel.activeMailboxScope) { _, _ in
            graphViewModel.discardSnipSession()
            syncData()
        }
        .onReceive(threadViewModel.$timelineTagsByNodeID) { _ in syncData() }
        .onReceive(threadViewModel.$nodeSummaries) { _ in syncData() }
        .onReceive(threadViewModel.$threadFolders) { _ in syncData() }
        .onReceive(threadViewModel.$folderMembershipByThreadID) { _ in syncData() }
        .onReceive(automationCoordinator.$proposals) { _ in syncData() }
        .onReceive(automationCoordinator.$topicSignalsByRawThreadID) { topicSignals in
            // `@Published` emits from `willSet`, so reading the coordinator
            // property here can still return the previous dictionary. Pass the
            // emitted value through directly so a one-shot topic refresh can
            // render suggestions without waiting for an unrelated UI update.
            syncData(topicSignalsOverride: topicSignals)
        }
        .onChange(of: graphViewModel.snipNotice) { _, notice in
            guard let notice else { return }
            switch notice.style {
            case .information:
                threadViewModel.showToast(notice.message)
            case .success:
                threadViewModel.showToast(notice.message, style: .success)
            case .error:
                threadViewModel.showError(notice.message)
            }
        }
        .sheet(item: $graphViewModel.snipBatchRequest,
               onDismiss: graphViewModel.returnToSnipStaging) { request in
            SnipMoveSheet(request: request,
                          mailboxAccounts: threadViewModel.mailboxAccounts,
                          settings: graphSettings,
                          viewModel: graphViewModel)
        }
        .sheet(isPresented: $graphViewModel.isSettingsPresented) {
            GraphSettingsSheet(settings: graphSettings,
                               automationCoordinator: automationCoordinator,
                               onScanCurrentMail: threadViewModel.scanCurrentMailForGraphAutomation)
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
            guard graphViewModel.snipPhase != .allocating,
                  graphViewModel.snipPhase != .moving else { return .handled }
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

    private var snipInstructionTitle: String {
        if graphViewModel.stagedSnipCount == 0 {
            return NSLocalizedString("graph.snip.staging.empty",
                                     comment: "Snip staging mode with no branches selected")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("graph.snip.staging.count",
                              comment: "Number of staged graph branches"),
            graphViewModel.stagedSnipCount
        )
    }

    private var interactionInstruction: (title: String, systemImage: String)? {
        if graphViewModel.isLassoSelectionActive {
            return (
                NSLocalizedString("graph.toolbar.lasso.instruction",
                                  comment: "Instruction shown while area selection is active"),
                "rectangle.dashed"
            )
        }
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

    private func sourceMessage(matching source: EmailMessageSource) -> EmailMessage? {
        for root in threadViewModel.roots {
            if let message = sourceMessage(matching: source, in: root) {
                return message
            }
        }
        return nil
    }

    private func sourceMessage(matching source: EmailMessageSource,
                               in node: ThreadNode) -> EmailMessage? {
        if source.matches(node.message) {
            return node.message
        }
        for child in node.children {
            if let message = sourceMessage(matching: source, in: child) {
                return message
            }
        }
        return nil
    }

    private func isActionItem(forGraphNodeID graphNodeID: String) -> Bool {
        guard let target = graphViewModel.actionTarget(for: graphNodeID),
              let selectedMessage = sourceMessage(withID: target.rawMessageID) else {
            return false
        }
        let message = physicalSourceMessage(for: selectedMessage)
        return threadViewModel.isActionItem(message: message)
    }

    private func toggleActionItem(forGraphNodeID graphNodeID: String) {
        guard let target = graphViewModel.actionTarget(for: graphNodeID),
              let selectedMessage = sourceMessage(withID: target.rawMessageID) else {
            return
        }
        let message = physicalSourceMessage(for: selectedMessage)
        toggleActionItem(message: message, target: target)
    }

    private func physicalSourceMessage(for message: EmailMessage) -> EmailMessage {
        guard message.isEmbeddedHistory else { return message }
        return sourceMessage(matching: message.physicalSource) ?? message
    }

    private func toggleActionItem(message: EmailMessage, target: GraphThreadActionTarget) {
        if threadViewModel.isActionItem(message: message) {
            threadViewModel.removeActionItem(message: message)
            return
        }
        let folderID = message.threadID.flatMap { threadViewModel.folderMembershipByThreadID[$0] }
        threadViewModel.addActionItem(message: message,
                                      folderID: folderID,
                                      tags: target.tags)
    }

    private func handleDropLifecycle(_ signal: OrganizerDropLifecycleSignal) {
        guard let recorder = threadViewModel.organizerMetricsRecorder else { return }
        switch signal {
        case .intent(let itemCount):
            pendingGroupComposer = nil
            if let previous = liveDropAttempt {
                finishDropMetrics(previous,
                                  mutationSucceeded: false,
                                  requestedOutcome: .cancelled)
            }
            liveDropAttempt = OrganizerLiveDropAttempt(id: UUID(),
                                                       itemCount: max(itemCount, 1),
                                                       hadVisibleHighlight: false,
                                                       destination: nil,
                                                       didRelease: false)
            dropMetricsCoordinator.enqueue {
                _ = await recorder.recordEvent(.actionStart,
                                               count: 1)
                _ = await recorder.recordEvent(.dropIntent,
                                               count: max(itemCount, 1))
            }

        case .highlight(let itemCount):
            var attempt = liveDropAttempt
                ?? OrganizerLiveDropAttempt(id: UUID(),
                                            itemCount: max(itemCount, 1),
                                            hadVisibleHighlight: false,
                                            destination: nil,
                                            didRelease: false)
            attempt.hadVisibleHighlight = true
            liveDropAttempt = attempt
            dropMetricsCoordinator.enqueue {
                _ = await recorder.recordEvent(.dropHighlight,
                                               count: max(itemCount, 1),
                                               status: .success)
            }

        case .release(let itemCount, let destination, let hadVisibleHighlight):
            var attempt = liveDropAttempt
                ?? OrganizerLiveDropAttempt(id: UUID(),
                                            itemCount: max(itemCount, 1),
                                            hadVisibleHighlight: false,
                                            destination: nil,
                                            didRelease: false)
            attempt.hadVisibleHighlight = attempt.hadVisibleHighlight || hadVisibleHighlight
            attempt.destination = destination
            attempt.didRelease = true
            liveDropAttempt = attempt
            let releaseSucceeded = destination == .emptyCanvas
                || (destination == .confirmedGroup && attempt.hadVisibleHighlight)
            dropMetricsCoordinator.enqueue {
                _ = await recorder.recordEvent(.dropRelease,
                                               count: attempt.itemCount,
                                               status: releaseSucceeded ? .success : .failure,
                                               failureReason: releaseSucceeded ? nil : .invalidTarget)
            }
            if destination == .invalidTarget {
                liveDropAttempt = nil
                finishDropMetrics(attempt,
                                  mutationSucceeded: false,
                                  requestedOutcome: .failure)
            }

        case .cancelled(let itemCount):
            let attempt = liveDropAttempt
                ?? OrganizerLiveDropAttempt(id: UUID(),
                                            itemCount: max(itemCount, 1),
                                            hadVisibleHighlight: false,
                                            destination: nil,
                                            didRelease: false)
            liveDropAttempt = nil
            finishDropMetrics(attempt,
                              mutationSucceeded: false,
                              requestedOutcome: .cancelled)
        }
    }

    private func finishDropMetrics(_ attempt: OrganizerLiveDropAttempt,
                                   mutationSucceeded: Bool,
                                   requestedOutcome: OrganizerMetricOutcome) {
        guard let recorder = threadViewModel.organizerMetricsRecorder else { return }
        dropMetricsCoordinator.enqueue {
            await recordOrganizerLiveDropCompletion(
                recorder: recorder,
                attempt: attempt,
                mutationSucceeded: mutationSucceeded,
                requestedOutcome: requestedOutcome
            )
        }
    }

    private func handleRenderedOrganizerSnapshot(_ receipt: OrganizerRenderedGraphReceipt) {
        let newlyVisibleCount = receipt.newlyVisibleConfirmedMemberCount
        guard let recorder = threadViewModel.organizerMetricsRecorder else { return }
        let query = normalizedMetricQuery(threadViewModel.searchQuery)
        let generation = retrievalGeneration
        onRenderedOrganizerReceipt(receipt)
        Task {
            _ = await recorder.recordRenderedOrganizerSnapshot(
                receipt.snapshot,
                newlyVisibleCount: newlyVisibleCount,
                isStillCurrent: { @MainActor in
                    receipt.matchesFilterGeneration(
                        graphViewModel.organizerRenderFilterGeneration
                    )
                }
            )
            guard query == OrganizerMetricsRecorder.frozenRetrievalQuery,
                  receipt.matchesFilterGeneration(
                    graphViewModel.organizerRenderFilterGeneration
                  ),
                  receipt.snapshot.containsAccessibleConversation(
                    rawThreadID: OrganizerMetricsRecorder.frozenRetrievalRawThreadID
                  ),
                  !hasScheduledRetrievalVisibleMetric,
                  let startTask = retrievalStartTask else {
                return
            }
            hasScheduledRetrievalVisibleMetric = true
            guard await startTask.value,
                  !Task.isCancelled,
                  generation == retrievalGeneration,
                  receipt.matchesFilterGeneration(
                    graphViewModel.organizerRenderFilterGeneration
                  ),
                  normalizedMetricQuery(threadViewModel.searchQuery)
                    == OrganizerMetricsRecorder.frozenRetrievalQuery else {
                if generation == retrievalGeneration {
                    hasScheduledRetrievalVisibleMetric = false
                    cancelMetricRetrievalIfNeeded(recorder: recorder)
                }
                return
            }
            let visibleCount = receipt.snapshot.filteredAccessibleConversationCount
            let didRecord = await recorder.recordRenderedRetrievalVisible(
                count: visibleCount,
                generation: generation,
                isStillCurrent: { @MainActor in
                    generation == retrievalGeneration
                        && receipt.matchesFilterGeneration(
                            graphViewModel.organizerRenderFilterGeneration
                        )
                        && normalizedMetricQuery(threadViewModel.searchQuery)
                            == OrganizerMetricsRecorder.frozenRetrievalQuery
                }
            )
            guard generation == retrievalGeneration,
                  receipt.matchesFilterGeneration(
                    graphViewModel.organizerRenderFilterGeneration
                  ),
                  normalizedMetricQuery(threadViewModel.searchQuery)
                    == OrganizerMetricsRecorder.frozenRetrievalQuery else {
                if generation == retrievalGeneration {
                    cancelMetricRetrievalIfNeeded(recorder: recorder)
                }
                return
            }
            if didRecord {
                retrievalStartTask = nil
                isMetricRetrievalActive = false
            } else {
                hasScheduledRetrievalVisibleMetric = false
            }
        }
    }

    private func handleMetricSearchQuery(_ rawQuery: String) {
        let normalized = normalizedMetricQuery(rawQuery)
        defer { previousMetricSearchQuery = normalized }
        guard let recorder = threadViewModel.organizerMetricsRecorder else { return }
        if !previousMetricSearchQuery.isEmpty,
           (previousMetricSearchQuery == OrganizerMetricsRecorder.frozenRetrievalQuery
            && normalized != OrganizerMetricsRecorder.frozenRetrievalQuery
            || normalized.isEmpty
            || !OrganizerMetricsRecorder.frozenRetrievalQuery.hasPrefix(normalized)) {
            cancelMetricRetrievalIfNeeded(recorder: recorder)
            return
        }
        guard previousMetricSearchQuery.isEmpty,
              !normalized.isEmpty,
              OrganizerMetricsRecorder.frozenRetrievalQuery.hasPrefix(normalized) else {
            return
        }
        hasScheduledRetrievalVisibleMetric = false
        isMetricRetrievalActive = true
        retrievalGeneration += 1
        let generation = retrievalGeneration
        retrievalStartTask = Task {
            guard !Task.isCancelled else { return false }
            return await recorder.beginDefaultRetrievalTimedEvent(generation: generation)
        }
    }

    private func cancelMetricRetrievalIfNeeded(
        recorder: OrganizerMetricsRecorder? = nil
    ) {
        let hadActiveRequest = isMetricRetrievalActive
        retrievalGeneration += 1
        let cancellationGeneration = retrievalGeneration
        retrievalStartTask?.cancel()
        retrievalStartTask = nil
        hasScheduledRetrievalVisibleMetric = false
        isMetricRetrievalActive = false
        guard hadActiveRequest else { return }
        guard let recorder = recorder ?? threadViewModel.organizerMetricsRecorder else { return }
        Task {
            _ = await recorder.cancelDefaultRetrievalTimedEvent(
                generation: cancellationGeneration
            )
        }
    }

    private func normalizedMetricQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func cancelPendingGroupComposer(_ request: OrganizerPendingGroupComposer) {
        pendingGroupComposer = nil
        guard let attempt = liveDropAttempt,
              request.dropAttemptID == attempt.id else { return }
        liveDropAttempt = nil
        finishDropMetrics(attempt,
                          mutationSucceeded: false,
                          requestedOutcome: .cancelled)
    }

    private func moveGraphThread(_ rawThreadID: String, toFolderID folderID: String) {
        moveGraphThreads([rawThreadID], toFolderID: folderID)
    }

    private func moveGraphThreads(_ rawThreadIDs: [String], toFolderID folderID: String) {
        let attempt = liveDropAttempt
        liveDropAttempt = nil
        guard let folder = threadViewModel.threadFolders.first(where: { $0.id == folderID }) else {
            if let attempt {
                finishDropMetrics(attempt,
                                  mutationSucceeded: false,
                                  requestedOutcome: .failure)
            }
            return
        }
        let viewModel = threadViewModel
        let recorder = viewModel.organizerMetricsRecorder
        let operation: @MainActor () async -> Void = {
            do {
                let result = try await viewModel.organizeThreads(
                    Set(rawThreadIDs),
                    intoGroupID: folderID
                )
                if let attempt, let recorder {
                    await recordOrganizerLiveDropCompletion(
                        recorder: recorder,
                        attempt: attempt,
                        mutationSucceeded: result.mutation.didChange,
                        requestedOutcome: .success
                    )
                }
                viewModel.showToast(
                    String.localizedStringWithFormat(
                        NSLocalizedString("graph.folder.drop.moving",
                                          comment: "Status after dropping graph conversations onto a confirmed folder"),
                        folder.title
                    ),
                    style: .success
                )
            } catch {
                if let attempt, let recorder {
                    await recordOrganizerLiveDropCompletion(
                        recorder: recorder,
                        attempt: attempt,
                        mutationSucceeded: false,
                        requestedOutcome: .failure
                    )
                }
                viewModel.showError(error.localizedDescription)
            }
        }
        if attempt != nil {
            dropMetricsCoordinator.enqueue(operation)
        } else {
            Task { @MainActor in
                await operation()
            }
        }
    }

    private func createGroup(from request: OrganizerPendingGroupComposer,
                             title: String) {
        pendingGroupComposer = nil
        let attempt = liveDropAttempt
        guard request.dropAttemptID == attempt?.id else { return }
        liveDropAttempt = nil
        let viewModel = threadViewModel
        let graphViewModel = graphViewModel
        let recorder = viewModel.organizerMetricsRecorder
        let operation: @MainActor () async -> Void = {
            do {
                let result = try await viewModel.createOrganizationGroup(
                    title: title,
                    threadIDs: Set(request.rawThreadIDs),
                    scopeID: viewModel.activeMailboxScope.graphPagingScopeID,
                    anchor: request.worldPoint,
                    zoom: graphViewModel.zoomScale
                )
                if let intent = result.operation.spatialAnchorIntent {
                    let revision = try await graphViewModel.persistConfirmedGroupAnchor(
                        groupID: result.mutation.groupID,
                        point: request.worldPoint
                    )
                    try await viewModel.completeOrganizationSpatialAnchor(
                        operationID: result.operation.id,
                        intentID: intent.intentID,
                        opaqueStoreRevision: revision
                    )
                }
                if let attempt, let recorder {
                    await recordOrganizerLiveDropCompletion(
                        recorder: recorder,
                        attempt: attempt,
                        mutationSucceeded: result.mutation.didChange,
                        requestedOutcome: .success
                    )
                }
                viewModel.showToast(
                    NSLocalizedString("organizer.group.created",
                                      comment: "Status after creating a Group from a canvas drop"),
                    style: .success
                )
            } catch {
                if let attempt, let recorder {
                    await recordOrganizerLiveDropCompletion(
                        recorder: recorder,
                        attempt: attempt,
                        mutationSucceeded: false,
                        requestedOutcome: .failure
                    )
                }
                viewModel.showError(error.localizedDescription)
            }
        }
        if attempt != nil {
            dropMetricsCoordinator.enqueue(operation)
        } else {
            Task { @MainActor in
                await operation()
            }
        }
    }

    private func composerPosition(for requested: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(requested.x, 150), max(150, size.width - 150)),
                y: min(max(requested.y, 92), max(92, size.height - 110)))
    }

    private func performSnipAction() {
        graphViewModel.activateSnip()
    }

    private func performArchiveAction() {
        graphViewModel.activateArchive(selectedThreadID: selectedActionTarget?.threadID)
    }

    @MainActor
    private func warmAudioIfNeeded() {
        guard graphSettings.soundOn else { return }
        audio.warm()
    }

    private func syncData(searchQuery: String? = nil,
                          topicSignalsOverride: [String: GraphTopicSignal]? = nil) {
        graphViewModel.onArchiveStateChanged = { [weak threadViewModel] in
            threadViewModel?.refreshGraphArchiveVisibility()
        }
        graphViewModel.update(roots: threadViewModel.roots,
                              searchQuery: searchQuery ?? threadViewModel.searchQuery,
                              tagsByNodeID: threadViewModel.timelineTagsByNodeID,
                              summariesByNodeID: threadViewModel.nodeSummaries,
                              manualAttachmentMessageIDs: threadViewModel.manualAttachmentMessageIDs,
                              jwzThreadMap: threadViewModel.jwzThreadMap,
                              snippetLineLimit: threadViewModel.summaryContextSnippetLineLimit,
                              stopPhrases: threadViewModel.summaryContextStopPhrases,
                              folders: threadViewModel.threadFolders,
                              folderMembershipByThreadID: threadViewModel.folderMembershipByThreadID,
                              automationProposals: automationCoordinator.proposals,
                              topicSignalsOverride: topicSignalsOverride
                                  ?? automationCoordinator.topicSignalsByRawThreadID,
                              dismissedSuggestedTopicIDs: graphSettings.dismissedSuggestedTopicIDs,
                              hiddenSuggestedTopics: graphSettings.hiddenSuggestedTopics,
                              showsArchivedThreads: threadViewModel.activeMailboxScope == .graphArchive,
                              branchPageSize: graphSettings.visibleBranchCount,
                              perNodeBranchPageSize: graphSettings.visibleBranchesPerNode,
                              visibleEmailsPerThread: graphSettings.visibleEmailsPerThread,
                              mailboxScopeID: threadViewModel.activeMailboxScope.graphPagingScopeID)
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

    private func restore(_ entry: GraphCompostEntry) {
        guard restoringHistoryEntryIDs.isEmpty else { return }
        restoringHistoryEntryIDs.insert(entry.id)
        Task {
            defer { restoringHistoryEntryIDs.remove(entry.id) }
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

    private func dismiss(_ entry: GraphCompostEntry) {
        graphViewModel.dismissRestoreHistoryEntry(entry)
        threadViewModel.showToast(NSLocalizedString(
            "graph.restore_history.dismiss.success",
            comment: "Restore History dismissal confirmation toast"
        ))
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

private struct OrganizerPendingGroupComposer: Identifiable, Equatable {
    let id = UUID()
    let rawThreadIDs: [String]
    let overlayPoint: CGPoint
    let worldPoint: CGPoint
    let dropAttemptID: UUID?
}

private struct OrganizerInlineGroupComposer: View {
    let request: OrganizerPendingGroupComposer
    let textScale: CGFloat
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var title = ""
    @State private var didAttemptBlankName = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("organizer.group.composer.title",
                                  comment: "Title for inline Group naming composer"))
                .font(DesignTokens.font(size: 13,
                                        weight: .semibold,
                                        textScale: textScale))
            Text(String.localizedStringWithFormat(
                NSLocalizedString("organizer.group.composer.count",
                                  comment: "Conversation count in inline Group naming composer"),
                request.rawThreadIDs.count
            ))
            .font(DesignTokens.font(size: 10.5,
                                    weight: .regular,
                                    textScale: textScale))
            .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)

            TextField(NSLocalizedString("organizer.group.composer.placeholder",
                                        comment: "Placeholder for a new Group name"),
                      text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(submit)
                .accessibilityIdentifier(AccessibilityID.organizerGroupNameField)

            if didAttemptBlankName {
                Text(NSLocalizedString("organizer.group.composer.blank_error",
                                      comment: "Validation error for a blank Group name"))
                    .font(DesignTokens.font(size: 10,
                                            weight: .medium,
                                            textScale: textScale))
                    .foregroundStyle(.red)
            }

            HStack {
                Button(NSLocalizedString("common.cancel", comment: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 12)
                Button(NSLocalizedString("organizer.group.composer.create",
                                         comment: "Create a named Group"),
                       action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.organizerGroupCreateConfirm)
            }
        }
        .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
        .padding(14)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignTokens.Graph.AppTheme.panel)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.organizerGroupComposer)
        .onAppear { isNameFocused = true }
    }

    private func submit() {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            didAttemptBlankName = true
            return
        }
        onConfirm(normalized)
    }
}

internal struct GraphBottomOverlayAnchors {
    internal var toolbar: Anchor<CGRect>? = nil
    internal var suggestionActionBar: Anchor<CGRect>? = nil
}

internal struct GraphBottomOverlayAnchorPreferenceKey: PreferenceKey {
    internal static var defaultValue = GraphBottomOverlayAnchors()

    internal static func reduce(value: inout GraphBottomOverlayAnchors,
                                nextValue: () -> GraphBottomOverlayAnchors) {
        let next = nextValue()
        value.toolbar = next.toolbar ?? value.toolbar
        value.suggestionActionBar = next.suggestionActionBar ?? value.suggestionActionBar
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
                legendRow(title: NSLocalizedString("graph.legend.selection.title",
                                                   comment: "Graph legend area selection title"),
                          detail: NSLocalizedString("graph.legend.selection.detail",
                                                    comment: "Graph legend area selection detail")) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DesignTokens.Graph.AppTheme.accent)
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
                legendRow(title: NSLocalizedString("graph.legend.manual.title",
                                                   comment: "Graph legend manual thread link title"),
                          detail: NSLocalizedString("graph.legend.manual.detail",
                                                    comment: "Graph legend manual thread link detail")) {
                    GraphLegendCurve()
                        .stroke(DesignTokens.Graph.AppTheme.manualThread,
                                style: StrokeStyle(lineWidth: 1.6,
                                                   lineCap: .round,
                                                   lineJoin: .round,
                                                   dash: [4, 4]))
                        .frame(width: 30, height: 18)
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
