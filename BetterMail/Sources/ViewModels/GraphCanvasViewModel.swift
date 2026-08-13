import Combine
import CoreGraphics
import Foundation
internal import os

internal enum GraphViewport {
    internal static let minimumZoomScale: CGFloat = 0.2
    internal static let maximumZoomScale: CGFloat = 5.0
    internal static let toolbarZoomFactor: CGFloat = 1.2

    internal static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumZoomScale), maximumZoomScale)
    }
}

internal enum GraphHoverItem: Equatable {
    case grouping(GraphGrouping, CGPoint)
    case thread(GraphThread, CGPoint)
    case remaining(GraphRemainingBranch, CGPoint)
    case message(GraphMessage, CGPoint)
}

internal struct GraphThreadActionTarget: Equatable {
    internal let threadID: String
    internal let rawMessageID: String
    internal let subject: String
    internal let tags: [String]
}

internal struct GraphPruneAnimationRequest: Identifiable, Equatable {
    internal let id: UUID
    internal let threadIDs: Set<String>
    internal let action: GraphCompostAction

    internal init(threadID: String, action: GraphCompostAction) {
        self.id = UUID()
        self.threadIDs = [threadID]
        self.action = action
    }

    internal init(threadIDs: Set<String>, action: GraphCompostAction) {
        self.id = UUID()
        self.threadIDs = threadIDs
        self.action = action
    }

    internal var threadID: String? {
        threadIDs.count == 1 ? threadIDs.first : nil
    }
}

private struct GraphTitleInput: Hashable {
    let nodeID: String
    let subject: String
    let summary: String
    let fingerprint: String
}

private struct GraphTopicInput: Hashable {
    let rawThreadID: String
    let subject: String
    let threadSummary: String
    let representativeContent: String
    let fingerprint: String
}

private struct GraphMailboxTuple: Hashable {
    let accountName: String
    let mailboxPath: String

    func matches(accountName: String, mailboxPath: String) -> Bool {
        self.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(accountName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame &&
        self.mailboxPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(mailboxPath.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}

private enum GraphSnipExecutionClassification {
    case succeeded
    case unchanged
    case rolledBack
    case recoveryNeeded
}

private struct GraphSnipRestoreTuple: Hashable {
    let destination: GraphMailboxTuple
    let origin: GraphMailboxTuple
}

private enum GraphSnipRestoreError: LocalizedError {
    case incomplete

    var errorDescription: String? {
        NSLocalizedString("graph.snip.restore.incomplete",
                          comment: "Some messages could not be restored from Snip Compost")
    }
}

@MainActor
internal final class GraphCanvasViewModel: ObservableObject {
    internal static let defaultBranchPageSize = 10
    internal static let defaultPerNodeBranchPageSize = 6
    private static let messagePreviewLimitPerBranch = 10

    @Published internal private(set) var data: GraphData = .empty
    @Published internal var hoverItem: GraphHoverItem?
    @Published internal var pruneMode: GraphPruneMode = .idle
    @Published internal private(set) var compostEntries: [GraphCompostEntry] = []
    @Published internal private(set) var snipPhase: GraphSnipPhase = .idle
    @Published internal private(set) var stagedSnipItems: [GraphSnipItem] = []
    @Published internal private(set) var snipLockedAccountName: String?
    @Published internal var snipBatchRequest: GraphSnipBatchRequest?
    @Published internal private(set) var snipAllocations: [String: GraphSnipAllocation] = [:]
    @Published internal private(set) var snipVisualTransition: GraphSnipVisualTransition?
    @Published internal private(set) var snipNotice: GraphSnipNotice?
    @Published internal private(set) var snipMoveCompletedCount = 0
    @Published internal private(set) var snipMoveTotalCount = 0
    @Published internal private(set) var lastSnipBatchResult: GraphSnipBatchResult?
    @Published internal var isSettingsPresented = false
    @Published internal private(set) var zoomScale: CGFloat = 1.0
    @Published internal private(set) var panOffset: CGPoint = .zero
    @Published internal private(set) var sproutingMessageIDs: Set<String> = []
    @Published internal private(set) var archivedThreadIDs: Set<String> = []
    @Published internal private(set) var nodePositions: [String: CGPoint] = [:]
    @Published internal private(set) var pruneAnimationRequest: GraphPruneAnimationRequest?
    @Published internal private(set) var selectedGroupingID: String?
    @Published internal private(set) var regeneratingGraphTitleNodeIDs: Set<String> = []
    internal var onArchiveStateChanged: (() -> Void)?

    private var sourceRoots: [ThreadNode] = []
    private var currentSearchQuery = ""
    private var currentTagsByNodeID: [String: [String]] = [:]
    private var currentSummariesByNodeID: [String: GraphMessageSummary] = [:]
    private var graphTitlesByNodeID: [String: String] = [:]
    private var graphTopicSignalsByRawThreadID: [String: GraphTopicSignal] = [:]
    private var graphTitleFingerprintsByNodeID: [String: String] = [:]
    private var graphTopicFingerprintsByRawThreadID: [String: String] = [:]
    private var currentGraphTitleInputs: [String: GraphTitleInput] = [:]
    private var currentGraphTopicInputs: [String: GraphTopicInput] = [:]
    private var currentFolders: [ThreadFolder] = []
    private var currentFolderMembershipByThreadID: [String: String] = [:]
    private var dismissedSuggestedTopicIDs: Set<String> = []
    private var hiddenSuggestedTopics: Set<String> = []
    private var showsArchivedThreads = false
    private var branchPageSize = GraphCanvasViewModel.defaultBranchPageSize
    private var visibleBranchLimit = GraphCanvasViewModel.defaultBranchPageSize
    private var perNodeBranchPageSize = GraphCanvasViewModel.defaultPerNodeBranchPageSize
    private var visibleChildLimitsByParentID: [String: Int] = [:]
    private var sourceThreadIDs: [String] = []
    private var previousMessageIDs: Set<String> = []
    private var archivedEntriesByThreadID: [String: ArchivedInGraphEntry] = [:]
    private var pruneStateMachine = GraphPruneStateMachine()
    private var pruneCompletionTask: Task<Void, Never>?
    private var graphTitleRefreshTask: Task<Void, Never>?
    private var graphTitleRefreshID: UUID?
    private var graphTopicRefreshTask: Task<Void, Never>?
    private var graphTopicRefreshID: UUID?
    private var isGraphTitleGenerationActive = false
    private var isGraphTopicGenerationActive = false
    private let store: MessageStore
    private let mailClient: any GraphSnipMailMoving
    private let graphTitleCapabilityProvider: (() -> GraphTitleCapability)?
    private let graphTopicCapabilityProvider: (() -> GraphTopicCapability)?

    internal init(store: MessageStore = .shared,
                  mailClient: any GraphSnipMailMoving = MailAppleScriptClient(),
                  graphTitleCapabilityProvider: (() -> GraphTitleCapability)? = nil,
                  graphTopicCapabilityProvider: (() -> GraphTopicCapability)? = nil) {
        self.store = store
        self.mailClient = mailClient
        self.graphTitleCapabilityProvider = graphTitleCapabilityProvider
        self.graphTopicCapabilityProvider = graphTopicCapabilityProvider
        Task { await loadArchivedEntries() }
    }

    internal var filteredNodeIDs: Set<String> {
        data.matchingNodeIDs(query: currentSearchQuery)
    }

    internal var selectedGraphNodeIDs: Set<String> {
        Set(data.groupings.map(\.id))
            .union(data.threads.map(\.id))
            .union(data.messages.map(\.id))
    }

    internal var selectedGrouping: GraphGrouping? {
        selectedGroupingID.flatMap { data.groupingByID[$0] }
    }

    internal var totalBranchCount: Int {
        data.totalPrimaryBranchCount
    }

    internal var stagedSnipThreadIDs: Set<String> {
        Set(stagedSnipItems.map(\.threadID))
    }

    internal var stagedSnipCount: Int {
        stagedSnipItems.count
    }

    internal var snipActionTitle: String {
        guard stagedSnipCount > 0 else {
            return NSLocalizedString("graph.toolbar.snip", comment: "Graph snip mode")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("graph.toolbar.allocate_count",
                              comment: "Allocate staged graph branches button"),
            stagedSnipCount
        )
    }

    internal var isArchiveDisabledForSnip: Bool {
        !stagedSnipItems.isEmpty || snipPhase == .allocating || snipPhase == .moving
    }

    internal var canConfirmSnipAllocations: Bool {
        !stagedSnipItems.isEmpty &&
            stagedSnipItems.allSatisfy { snipAllocations[$0.threadID] != nil }
    }

    internal var fullyStagedSnipGroupingIDs: Set<String> {
        Set(data.groupings.compactMap { grouping in
            guard grouping.kind == .folder else { return nil }
            let eligible = eligibleThreadIDs(in: grouping)
            return !eligible.isEmpty && eligible.allSatisfy(stagedSnipThreadIDs.contains)
                ? grouping.id
                : nil
        })
    }

    internal var partiallyStagedSnipGroupingIDs: Set<String> {
        Set(data.groupings.compactMap { grouping in
            guard grouping.kind == .folder else { return nil }
            let eligible = eligibleThreadIDs(in: grouping)
            let stagedCount = eligible.filter(stagedSnipThreadIDs.contains).count
            return stagedCount > 0 && stagedCount < eligible.count ? grouping.id : nil
        })
    }

    /// Keeps local-model work scoped to the mounted graph. In particular, a
    /// Graph -> Timeline switch must not leave title generation rebuilding the
    /// graph projection while the timeline is being mounted.
    internal func setGraphTitleGenerationActive(_ isActive: Bool) {
        guard isActive != isGraphTitleGenerationActive else { return }
        isGraphTitleGenerationActive = isActive
        if isActive {
            refreshGraphTitles(for: data)
        } else {
            cancelGraphTitleRefresh()
            currentGraphTitleInputs = [:]
            regeneratingGraphTitleNodeIDs = []
        }
    }

    internal func setGraphEnrichmentActive(_ isActive: Bool) {
        setGraphTitleGenerationActive(isActive)
        setGraphTopicGenerationActive(isActive)
    }

    private func setGraphTopicGenerationActive(_ isActive: Bool) {
        guard isActive != isGraphTopicGenerationActive else { return }
        isGraphTopicGenerationActive = isActive
        if isActive {
            refreshGraphTopics()
        } else {
            cancelGraphTopicRefresh()
            currentGraphTopicInputs = [:]
        }
    }

    internal func update(roots: [ThreadNode],
                         searchQuery: String,
                         tagsByNodeID: [String: [String]],
                         summariesByNodeID: [String: ThreadSummaryState],
                         folders: [ThreadFolder] = [],
                         folderMembershipByThreadID: [String: String] = [:],
                         dismissedSuggestedTopicIDs: Set<String> = [],
                         hiddenSuggestedTopics: Set<String> = [],
                         showsArchivedThreads: Bool = false,
                         branchPageSize: Int = GraphCanvasViewModel.defaultBranchPageSize,
                         perNodeBranchPageSize: Int = 6) {
        let clampedBranchPageSize = GraphCanvasSettings.clampedVisibleBranchCount(branchPageSize)
        let clampedPerNodeBranchPageSize = GraphCanvasSettings.clampedVisibleBranchesPerNode(perNodeBranchPageSize)
        let nextSourceThreadIDs = roots.map { GraphData.threadNodeID(for: GraphData.rawThreadID(for: $0)) }
        let sourceChanged = nextSourceThreadIDs != sourceThreadIDs
        let archiveVisibilityChanged = showsArchivedThreads != self.showsArchivedThreads
        if sourceChanged || archiveVisibilityChanged || clampedBranchPageSize != self.branchPageSize {
            visibleBranchLimit = clampedBranchPageSize
        }
        if sourceChanged || archiveVisibilityChanged ||
            clampedPerNodeBranchPageSize != self.perNodeBranchPageSize {
            visibleChildLimitsByParentID = [:]
        }
        sourceThreadIDs = nextSourceThreadIDs
        self.branchPageSize = clampedBranchPageSize
        self.perNodeBranchPageSize = clampedPerNodeBranchPageSize
        sourceRoots = roots
        currentSearchQuery = searchQuery
        currentTagsByNodeID = tagsByNodeID
        currentFolders = folders
        currentFolderMembershipByThreadID = folderMembershipByThreadID
        self.dismissedSuggestedTopicIDs = dismissedSuggestedTopicIDs
        self.hiddenSuggestedTopics = hiddenSuggestedTopics
        self.showsArchivedThreads = showsArchivedThreads
        currentSummariesByNodeID = summariesByNodeID.mapValues {
            GraphMessageSummary(text: $0.text,
                                statusMessage: $0.statusMessage,
                                isSummarizing: $0.isSummarizing)
        }
        rebuildData()
    }

    internal func expandRemainingBranches(parentID: String) {
        guard data.remainingBranch(forParentID: parentID) != nil else { return }
        if parentID == data.center.id {
            visibleBranchLimit += branchPageSize
        } else {
            let currentVisibleChildCount = data.groupingByID[parentID]?.threadIDs.count
                ?? perNodeBranchPageSize
            visibleChildLimitsByParentID[parentID] =
                (visibleChildLimitsByParentID[parentID] ?? currentVisibleChildCount) + perNodeBranchPageSize
        }
        rebuildData()
    }

    internal func setHoverItem(_ item: GraphHoverItem?) {
        hoverItem = item
    }

    internal func setNodePositions(_ positions: [String: CGPoint]) {
        nodePositions = positions
    }

    internal func selectGrouping(id: String?) {
        selectedGroupingID = id
    }

    internal func toggleSnipMode() {
        activateSnip()
    }

    internal func toggleArchiveMode() {
        guard !isArchiveDisabledForSnip else {
            publishSnipNotice(
                NSLocalizedString("graph.snip.notice.archive_disabled",
                                  comment: "Archive is unavailable while snips are staged")
            )
            return
        }
        pruneMode = pruneMode == .archive ? .idle : .archive
        _ = pruneStateMachine.send(pruneMode == .archive ? .enterArchive : .cancel)
    }

    internal func activateSnip() {
        switch snipPhase {
        case .idle:
            pruneMode = .snip
            snipPhase = .staging
            lastSnipBatchResult = nil
            // Batch Snip is governed by `snipPhase`; the legacy prune state
            // machine remains Archive-only in production.
            _ = pruneStateMachine.send(.cancel)
        case .staging where stagedSnipItems.isEmpty:
            discardSnipSession()
        case .staging:
            presentSnipAllocation()
        case .allocating, .moving:
            break
        }
    }

    /// Compatibility entry point for older command plumbing. A pre-existing
    /// graph selection is deliberately ignored when a Snip session begins.
    internal func activateSnip(selectedThreadID: String?) {
        activateSnip()
    }

    internal func activateArchive(selectedThreadID: String?) {
        guard !isArchiveDisabledForSnip else { return }
        if let selectedThreadID {
            requestArchive(threadID: selectedThreadID)
        } else {
            toggleArchiveMode()
        }
    }

    internal func exitPruneMode() {
        switch snipPhase {
        case .allocating, .moving:
            // The allocation sheet owns Escape/dismissal. Let its onDismiss
            // callback return to staging so the batch and drafts survive.
            return
        case .staging:
            discardSnipSession()
            return
        case .idle:
            break
        }
        pruneMode = .idle
        _ = pruneStateMachine.send(.cancel)
    }

    internal func requestPrune(threadID: String) {
        switch pruneMode {
        case .idle:
            break
        case .snip:
            toggleSnipTarget(.thread(threadID))
        case .archive:
            _ = pruneStateMachine.send(.edgeClicked(threadID: threadID))
            Task { await archiveThread(threadID: threadID) }
        }
    }

    internal func requestSnip(threadID: String) {
        if snipPhase == .idle {
            activateSnip()
        }
        toggleSnipTarget(.thread(threadID))
    }

    internal func requestArchive(threadID: String) {
        guard !isArchiveDisabledForSnip else { return }
        if pruneMode != .archive {
            _ = pruneStateMachine.send(.cancel)
            pruneMode = .archive
            _ = pruneStateMachine.send(.enterArchive)
        }
        requestPrune(threadID: threadID)
    }

    internal func toggleSnipTarget(_ target: GraphSnipTarget) {
        guard snipPhase == .staging, pruneMode == .snip else { return }
        switch target {
        case .thread(let threadID):
            guard let item = snipItem(threadID: threadID) else { return }
            toggleSnipItems([item], cascades: false)
        case .confirmedGroup(let groupingID):
            guard let grouping = data.groupingByID[groupingID], grouping.kind == .folder else { return }
            toggleSnipGrouping(grouping)
        }
    }

    internal func presentSnipAllocation() {
        guard snipPhase == .staging,
              !stagedSnipItems.isEmpty,
              let accountName = snipLockedAccountName else { return }
        snipBatchRequest = GraphSnipBatchRequest(accountName: accountName,
                                                 items: stagedSnipItems)
        snipPhase = .allocating
    }

    internal func returnToSnipStaging() {
        guard snipPhase != .moving else { return }
        snipBatchRequest = nil
        snipPhase = stagedSnipItems.isEmpty ? .idle : .staging
        pruneMode = stagedSnipItems.isEmpty ? .idle : .snip
    }

    internal func discardSnipSession() {
        guard snipPhase != .moving else { return }
        let unstagedThreadIDs = stagedSnipItems.map(\.threadID)
        if !unstagedThreadIDs.isEmpty {
            snipVisualTransition = GraphSnipVisualTransition(threadIDs: unstagedThreadIDs,
                                                             change: .unstage,
                                                             cascades: unstagedThreadIDs.count > 1)
        }
        stagedSnipItems = []
        snipAllocations = [:]
        snipLockedAccountName = nil
        snipBatchRequest = nil
        snipPhase = .idle
        snipMoveCompletedCount = 0
        snipMoveTotalCount = 0
        _ = pruneStateMachine.send(.cancel)
        pruneMode = .idle
    }

    internal func cancelSnip() {
        returnToSnipStaging()
    }

    internal func setSnipAllocation(threadID: String, destinationPath: String?) {
        guard snipPhase == .allocating,
              stagedSnipThreadIDs.contains(threadID),
              let accountName = snipLockedAccountName else { return }
        let trimmedPath = destinationPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedPath.isEmpty {
            snipAllocations.removeValue(forKey: threadID)
        } else {
            snipAllocations[threadID] = GraphSnipAllocation(threadID: threadID,
                                                            destinationMailboxPath: trimmedPath,
                                                            destinationAccountName: accountName)
        }
    }

    internal func applySnipDestinationToAll(_ destinationPath: String) {
        for item in stagedSnipItems {
            setSnipAllocation(threadID: item.threadID, destinationPath: destinationPath)
        }
    }

    @discardableResult
    internal func confirmSnipBatch(request: GraphSnipBatchRequest) async -> GraphSnipBatchResult? {
        guard snipPhase == .allocating,
              request.items.map(\.threadID) == stagedSnipItems.map(\.threadID),
              canConfirmSnipAllocations else { return nil }
        let frozenAllocations = snipAllocations
        snipPhase = .moving
        snipMoveCompletedCount = 0
        snipMoveTotalCount = request.items.count
        let result = await executeSnipBatch(items: request.items,
                                            allocations: frozenAllocations)
        completeSnipBatch(result)
        return result
    }

    private func toggleSnipItems(_ items: [GraphSnipItem], cascades: Bool) {
        guard let item = items.first else { return }
        if stagedSnipThreadIDs.contains(item.threadID) {
            unstageSnipItems(items, cascades: cascades)
            return
        }
        if let lockedAccount = snipLockedAccountName,
           !accountsMatch(lockedAccount, item.accountName) {
            publishSnipNotice(
                String.localizedStringWithFormat(
                    NSLocalizedString("graph.snip.notice.account_mismatch",
                                      comment: "A thread belongs to another Mail account"),
                    lockedAccount
                ),
                style: .error
            )
            return
        }
        if snipLockedAccountName == nil {
            snipLockedAccountName = item.accountName
        }
        stageSnipItems(items, cascades: cascades)
    }

    private func toggleSnipGrouping(_ grouping: GraphGrouping) {
        let allItems = grouping.rawThreadIDs.compactMap(snipItem(rawThreadID:))
        guard !allItems.isEmpty else { return }
        let accountKeys = Set(allItems.map { normalizedAccount($0.accountName) })
        if snipLockedAccountName == nil, accountKeys.count > 1 {
            publishSnipNotice(
                NSLocalizedString("graph.snip.notice.mixed_group_choose_thread",
                                  comment: "A mixed-account group cannot start a Snip batch"),
                style: .error
            )
            return
        }
        if snipLockedAccountName == nil {
            snipLockedAccountName = allItems[0].accountName
        }
        guard let lockedAccount = snipLockedAccountName else { return }
        let eligibleItems = allItems.filter { accountsMatch($0.accountName, lockedAccount) }
        guard !eligibleItems.isEmpty else { return }
        let eligibleIDs = Set(eligibleItems.map(\.threadID))
        if eligibleIDs.isSubset(of: stagedSnipThreadIDs) {
            unstageSnipItems(eligibleItems, cascades: true)
        } else {
            stageSnipItems(eligibleItems.filter { !stagedSnipThreadIDs.contains($0.threadID) },
                           cascades: true)
        }
        let skippedCount = allItems.count - eligibleItems.count
        if skippedCount > 0 {
            publishSnipNotice(
                String.localizedStringWithFormat(
                    NSLocalizedString("graph.snip.notice.group_skipped_accounts",
                                      comment: "Threads skipped because they belong to another account"),
                    skippedCount
                )
            )
        }
    }

    private func stageSnipItems(_ items: [GraphSnipItem], cascades: Bool) {
        let newItems = items.filter { !stagedSnipThreadIDs.contains($0.threadID) }
        guard !newItems.isEmpty else { return }
        stagedSnipItems.append(contentsOf: newItems)
        snipVisualTransition = GraphSnipVisualTransition(threadIDs: newItems.map(\.threadID),
                                                         change: .stage,
                                                         cascades: cascades)
    }

    private func unstageSnipItems(_ items: [GraphSnipItem], cascades: Bool) {
        let IDs = Set(items.map(\.threadID))
        guard !IDs.isEmpty else { return }
        stagedSnipItems.removeAll { IDs.contains($0.threadID) }
        for threadID in IDs {
            snipAllocations.removeValue(forKey: threadID)
        }
        snipVisualTransition = GraphSnipVisualTransition(threadIDs: Array(IDs).sorted(),
                                                         change: .unstage,
                                                         cascades: cascades)
        if stagedSnipItems.isEmpty {
            snipLockedAccountName = nil
        }
    }

    private func eligibleThreadIDs(in grouping: GraphGrouping) -> Set<String> {
        let items = grouping.rawThreadIDs.compactMap(snipItem(rawThreadID:))
        guard let lockedAccount = snipLockedAccountName else {
            let accountKeys = Set(items.map { normalizedAccount($0.accountName) })
            return accountKeys.count <= 1 ? Set(items.map(\.threadID)) : []
        }
        return Set(items.filter { accountsMatch($0.accountName, lockedAccount) }.map(\.threadID))
    }

    private func snipItem(threadID: String) -> GraphSnipItem? {
        guard let thread = data.threadByID[threadID] else { return nil }
        return snipItem(rawThreadID: thread.rawThreadID)
    }

    private func snipItem(rawThreadID: String) -> GraphSnipItem? {
        guard let root = sourceRoots.first(where: { GraphData.rawThreadID(for: $0) == rawThreadID }) else {
            return nil
        }
        var seenMessageLocations: Set<String> = []
        let messages = Self.flatten(root).compactMap { node -> GraphSnipMessage? in
            let messageID = node.message.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedID = GraphMailMoveResult.normalizedMessageID(messageID)
            let message = GraphSnipMessage(id: messageID,
                                           sourceMailboxPath: node.message.mailboxID,
                                           sourceAccountName: node.message.accountName)
            guard !normalizedID.isEmpty,
                  seenMessageLocations.insert(message.locationIdentity).inserted else { return nil }
            return message
        }
        guard !messages.isEmpty else { return nil }
        return GraphSnipItem(threadID: GraphData.threadNodeID(for: rawThreadID),
                             rawThreadID: rawThreadID,
                             rootNodeID: root.id,
                             subject: root.message.subject,
                             accountName: root.message.accountName,
                             messages: messages)
    }

    private func accountsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedAccount(lhs) == normalizedAccount(rhs)
    }

    private func normalizedAccount(_ accountName: String) -> String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func flatten(_ node: ThreadNode) -> [ThreadNode] {
        [node] + node.children.flatMap(flatten)
    }

    private func publishSnipNotice(_ message: String,
                                   style: GraphSnipNotice.Style = .information) {
        snipNotice = GraphSnipNotice(message: message, style: style)
    }

    private func executeSnipBatch(
        items: [GraphSnipItem],
        allocations: [String: GraphSnipAllocation]
    ) async -> GraphSnipBatchResult {
        var batchResult = GraphSnipBatchResult()
        for item in items {
            guard let allocation = allocations[item.threadID] else {
                snipMoveCompletedCount += 1
                continue
            }
            let (classification, outcome) = await executeSnipItem(item, allocation: allocation)
            switch classification {
            case .succeeded:
                batchResult.succeeded.append(outcome)
            case .unchanged:
                batchResult.unchanged.append(outcome)
            case .rolledBack:
                batchResult.rolledBack.append(outcome)
            case .recoveryNeeded:
                batchResult.recoveryNeeded.append(outcome)
            }
            snipMoveCompletedCount += 1
        }
        return batchResult
    }

    private func executeSnipItem(
        _ item: GraphSnipItem,
        allocation: GraphSnipAllocation
    ) async -> (GraphSnipExecutionClassification, GraphSnipBatchOutcome) {
        let destination = GraphMailboxTuple(accountName: allocation.destinationAccountName,
                                            mailboxPath: allocation.destinationMailboxPath)
        let messagesToMove = item.messages.filter {
            !destination.matches(accountName: $0.sourceAccountName,
                                 mailboxPath: $0.sourceMailboxPath)
        }
        var messagesBySource: [GraphMailboxTuple: [GraphSnipMessage]] = [:]
        var sourceOrder: [GraphMailboxTuple] = []
        for message in messagesToMove {
            let source = GraphMailboxTuple(accountName: message.sourceAccountName,
                                           mailboxPath: message.sourceMailboxPath)
            if messagesBySource[source] == nil {
                sourceOrder.append(source)
            }
            messagesBySource[source, default: []].append(message)
        }

        var movedByLocation: [String: GraphSnipMovedMessage] = [:]
        for source in sourceOrder {
            let sourceMessages = messagesBySource[source] ?? []
            do {
                let result = try await mailClient.moveMessages(
                    messageIDs: sourceMessages.map(\.id),
                    toMailboxPath: allocation.destinationMailboxPath,
                    account: allocation.destinationAccountName,
                    sourceMailboxPath: source.mailboxPath,
                    sourceAccount: source.accountName
                )
                for message in sourceMessages where result.contains(message.id) {
                    let moved = GraphSnipMovedMessage(messageID: message.id,
                                                      sourceMailboxPath: message.sourceMailboxPath,
                                                      sourceAccountName: message.sourceAccountName,
                                                      destinationMailboxPath: allocation.destinationMailboxPath,
                                                      destinationAccountName: allocation.destinationAccountName)
                    movedByLocation[message.locationIdentity] = moved
                }
            } catch {
                Log.app.error("Graph batch snip move failed for thread \(item.threadID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let requiredLocations = Set(messagesToMove.map(\.locationIdentity))
        let movedLocations = Set(movedByLocation.keys)
        let movedMessages = movedByLocation.values.sorted { $0.id < $1.id }
        if requiredLocations.isSubset(of: movedLocations) {
            return (.succeeded,
                    GraphSnipBatchOutcome(item: item,
                                          allocation: allocation,
                                          displacedMessages: movedMessages))
        }
        if movedMessages.isEmpty {
            return (.unchanged,
                    GraphSnipBatchOutcome(item: item,
                                          allocation: allocation,
                                          displacedMessages: []))
        }

        let remainingDisplaced = await compensateMovedMessages(movedMessages,
                                                                allocation: allocation)
        if remainingDisplaced.isEmpty {
            return (.rolledBack,
                    GraphSnipBatchOutcome(item: item,
                                          allocation: allocation,
                                          displacedMessages: []))
        }
        return (.recoveryNeeded,
                GraphSnipBatchOutcome(item: item,
                                      allocation: allocation,
                                      displacedMessages: remainingDisplaced))
    }

    private func compensateMovedMessages(
        _ movedMessages: [GraphSnipMovedMessage],
        allocation: GraphSnipAllocation
    ) async -> [GraphSnipMovedMessage] {
        var messagesByOrigin: [GraphMailboxTuple: [GraphSnipMovedMessage]] = [:]
        var originOrder: [GraphMailboxTuple] = []
        for message in movedMessages {
            let origin = GraphMailboxTuple(accountName: message.sourceAccountName,
                                           mailboxPath: message.sourceMailboxPath)
            if messagesByOrigin[origin] == nil {
                originOrder.append(origin)
            }
            messagesByOrigin[origin, default: []].append(message)
        }

        var restoredLocations: Set<String> = []
        for origin in originOrder {
            let messages = messagesByOrigin[origin] ?? []
            do {
                let result = try await mailClient.moveMessages(
                    messageIDs: messages.map(\.messageID),
                    toMailboxPath: origin.mailboxPath,
                    account: origin.accountName,
                    sourceMailboxPath: allocation.destinationMailboxPath,
                    sourceAccount: allocation.destinationAccountName
                )
                for message in messages where result.contains(message.messageID) {
                    restoredLocations.insert(message.id)
                }
            } catch {
                Log.app.error("Graph batch snip rollback failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return movedMessages.filter {
            !restoredLocations.contains($0.id)
        }
    }

    private func completeSnipBatch(_ result: GraphSnipBatchResult) {
        let now = Date()
        for outcome in result.succeeded {
            compostEntries.removeAll { $0.threadID == outcome.item.threadID && $0.action == .snip }
            compostEntries.append(
                GraphCompostEntry(id: "snip-\(outcome.item.threadID)-\(UUID().uuidString)",
                                  threadID: outcome.item.threadID,
                                  rootNodeID: outcome.item.rootNodeID,
                                  subject: outcome.item.subject,
                                  action: .snip,
                                  messageIDs: outcome.displacedMessages.map(\.messageID),
                                  priorMailboxPath: nil,
                                  priorAccountName: nil,
                                  movedMessages: outcome.displacedMessages,
                                  createdAt: now)
            )
        }
        for outcome in result.recoveryNeeded {
            compostEntries.removeAll { $0.threadID == outcome.item.threadID && $0.action == .snip }
            compostEntries.append(
                GraphCompostEntry(id: "snip-recovery-\(outcome.item.threadID)-\(UUID().uuidString)",
                                  threadID: outcome.item.threadID,
                                  rootNodeID: outcome.item.rootNodeID,
                                  subject: outcome.item.subject,
                                  action: .snip,
                                  messageIDs: outcome.displacedMessages.map(\.messageID),
                                  priorMailboxPath: nil,
                                  priorAccountName: nil,
                                  movedMessages: outcome.displacedMessages,
                                  requiresRecovery: true,
                                  createdAt: now)
            )
        }

        let successfulThreadIDs = Set(result.succeeded.map(\.item.threadID))
        let visibleFailureThreadIDs = result.unchanged.map(\.item.threadID) +
            result.rolledBack.map(\.item.threadID) + result.recoveryNeeded.map(\.item.threadID)
        if !visibleFailureThreadIDs.isEmpty {
            snipVisualTransition = GraphSnipVisualTransition(threadIDs: visibleFailureThreadIDs,
                                                             change: .unstage,
                                                             cascades: visibleFailureThreadIDs.count > 1)
        }
        lastSnipBatchResult = result
        stagedSnipItems = []
        snipAllocations = [:]
        snipLockedAccountName = nil
        snipBatchRequest = nil
        snipPhase = .idle
        pruneMode = .idle
        _ = pruneStateMachine.send(.cancel)
        if !successfulThreadIDs.isEmpty {
            beginPruneAnimation(threadIDs: successfulThreadIDs, action: .snip)
        }
        let summary = String.localizedStringWithFormat(
            NSLocalizedString("graph.snip.completion.summary",
                              comment: "Aggregate Batch Snip completion counts"),
            result.succeeded.count,
            result.unchanged.count,
            result.rolledBack.count,
            result.recoveryNeeded.count
        )
        publishSnipNotice(summary,
                          style: result.recoveryNeeded.isEmpty ? .success : .error)
    }

    internal func archiveThread(threadID: String) async {
        guard let thread = data.threadByID[threadID] else { return }
        do {
            let entry = ArchivedInGraphEntry(threadID: threadID, archivedAt: Date())
            try await store.upsertArchivedInGraphEntry(entry)
            archivedEntriesByThreadID[threadID] = entry
            compostEntries.removeAll { $0.threadID == threadID }
            compostEntries.append(GraphCompostEntry(id: "archive-\(threadID)",
                                                    threadID: threadID,
                                                    rootNodeID: thread.rootNodeID,
                                                    subject: thread.subject,
                                                    action: .archive,
                                                    messageIDs: thread.messageIDs,
                                                    priorMailboxPath: nil,
                                                    priorAccountName: nil,
                                                    createdAt: entry.archivedAt))
            pruneMode = .idle
            beginPruneAnimation(threadID: threadID, action: .archive)
        } catch {
            pruneMode = .idle
        }
    }

    internal func finishPruneAnimation(id: UUID) {
        guard let request = pruneAnimationRequest,
              request.id == id else { return }
        pruneCompletionTask?.cancel()
        pruneCompletionTask = nil
        pruneAnimationRequest = nil
        if request.action == .archive {
            _ = pruneStateMachine.send(.animationFinished)
        }
        archivedThreadIDs.formUnion(request.threadIDs)
        rebuildData()
        if request.action == .archive {
            onArchiveStateChanged?()
        }
    }

    internal func restore(_ entry: GraphCompostEntry) async throws {
        if entry.action == .archive {
            _ = pruneStateMachine.send(.restore(threadID: entry.threadID))
        }
        switch entry.action {
        case .archive:
            try await store.deleteArchivedInGraphEntry(threadID: entry.threadID)
            archivedEntriesByThreadID.removeValue(forKey: entry.threadID)
            archivedThreadIDs.remove(entry.threadID)
        case .snip:
            if !entry.movedMessages.isEmpty {
                let remainingMessages = await restoreMovedMessages(entry.movedMessages)
                if !remainingMessages.isEmpty {
                    let replacement = GraphCompostEntry(
                        id: entry.id,
                        threadID: entry.threadID,
                        rootNodeID: entry.rootNodeID,
                        subject: entry.subject,
                        action: entry.action,
                        messageIDs: remainingMessages.map(\.messageID),
                        priorMailboxPath: nil,
                        priorAccountName: nil,
                        movedMessages: remainingMessages,
                        requiresRecovery: true,
                        createdAt: entry.createdAt
                    )
                    if let index = compostEntries.firstIndex(where: { $0.id == entry.id }) {
                        compostEntries[index] = replacement
                    }
                    throw GraphSnipRestoreError.incomplete
                }
            } else if let priorMailboxPath = entry.priorMailboxPath {
                _ = try await mailClient.moveMessages(messageIDs: entry.messageIDs,
                                                      toMailboxPath: priorMailboxPath,
                                                      account: entry.priorAccountName,
                                                      sourceMailboxPath: nil,
                                                      sourceAccount: nil)
            }
            archivedThreadIDs.remove(entry.threadID)
        }
        compostEntries.removeAll { $0.id == entry.id }
        if entry.action == .archive {
            _ = pruneStateMachine.send(.restoreFinished)
        }
        rebuildData()
        if entry.action == .archive {
            onArchiveStateChanged?()
        }
    }

    private func restoreMovedMessages(
        _ movedMessages: [GraphSnipMovedMessage]
    ) async -> [GraphSnipMovedMessage] {
        var groups: [GraphSnipRestoreTuple: [GraphSnipMovedMessage]] = [:]
        var order: [GraphSnipRestoreTuple] = []
        for message in movedMessages {
            let tuple = GraphSnipRestoreTuple(
                destination: GraphMailboxTuple(accountName: message.destinationAccountName,
                                               mailboxPath: message.destinationMailboxPath),
                origin: GraphMailboxTuple(accountName: message.sourceAccountName,
                                          mailboxPath: message.sourceMailboxPath)
            )
            if groups[tuple] == nil {
                order.append(tuple)
            }
            groups[tuple, default: []].append(message)
        }

        var restoredLocations: Set<String> = []
        for tuple in order {
            let messages = groups[tuple] ?? []
            do {
                let result = try await mailClient.moveMessages(
                    messageIDs: messages.map(\.messageID),
                    toMailboxPath: tuple.origin.mailboxPath,
                    account: tuple.origin.accountName,
                    sourceMailboxPath: tuple.destination.mailboxPath,
                    sourceAccount: tuple.destination.accountName
                )
                for message in messages where result.contains(message.messageID) {
                    restoredLocations.insert(message.id)
                }
            } catch {
                Log.app.error("Graph Snip restore failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return movedMessages.filter {
            !restoredLocations.contains($0.id)
        }
    }

    internal func zoomIn() {
        setZoom(zoomScale * GraphViewport.toolbarZoomFactor)
    }

    internal func zoomOut() {
        setZoom(zoomScale / GraphViewport.toolbarZoomFactor)
    }

    internal func setZoom(_ value: CGFloat) {
        zoomScale = GraphViewport.clampedZoom(value)
    }

    internal func setPanOffset(_ value: CGPoint) {
        panOffset = value
    }

    internal func resetViewport() {
        zoomScale = 1.0
        panOffset = .zero
    }

    internal func selectedGraphNodeID(for selectedNodeID: String?) -> String? {
        guard let selectedNodeID else { return nil }
        if data.messageByID[selectedNodeID] != nil {
            return selectedNodeID
        }
        if let message = data.messages.first(where: { $0.rawMessageID == selectedNodeID }) {
            return message.id
        }
        return data.threads.first {
            $0.rootNodeID == selectedNodeID ||
            $0.id == selectedNodeID ||
            $0.rawThreadID == selectedNodeID
        }?.id
    }

    internal func graphNodeIDs(for selectedNodeIDs: Set<String>) -> Set<String> {
        Set(selectedNodeIDs.compactMap { selectedGraphNodeID(for: $0) })
    }

    internal func generatedGraphTitle(for selectedNodeID: String?) -> String? {
        guard let graphNodeID = selectedGraphNodeID(for: selectedNodeID),
              let sourceNodeID = rootNodeID(forGraphNodeID: graphNodeID),
              let title = graphTitlesByNodeID[sourceNodeID]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }

    internal func isRegeneratingGraphTitle(for selectedNodeID: String?) -> Bool {
        guard let graphNodeID = selectedGraphNodeID(for: selectedNodeID),
              let sourceNodeID = rootNodeID(forGraphNodeID: graphNodeID) else {
            return false
        }
        return regeneratingGraphTitleNodeIDs.contains(sourceNodeID)
    }

    internal func canRegenerateGraphTitle(for selectedNodeID: String?) -> Bool {
        graphTitleInputForRegeneration(for: selectedNodeID) != nil
    }

    internal func regenerateGraphTitle(for selectedNodeID: String?) {
        guard let input = graphTitleInputForRegeneration(for: selectedNodeID) else { return }

        regeneratingGraphTitleNodeIDs.insert(input.nodeID)
        graphTitleFingerprintsByNodeID.removeValue(forKey: input.nodeID)
        currentGraphTitleInputs = [:]
        refreshGraphTitles(for: data)
    }

    internal func rootNodeID(forGraphNodeID graphNodeID: String?) -> String? {
        guard let graphNodeID else { return nil }
        if let thread = data.threadByID[graphNodeID] {
            return thread.rootNodeID
        }
        if let message = data.messageByID[graphNodeID] {
            return message.rawMessageID
        }
        return nil
    }

    private func graphTitleInputForRegeneration(for selectedNodeID: String?) -> GraphTitleInput? {
        guard isGraphTitleGenerationActive,
              let graphTitleCapabilityProvider,
              let graphNodeID = selectedGraphNodeID(for: selectedNodeID),
              let sourceNodeID = rootNodeID(forGraphNodeID: graphNodeID) else {
            return nil
        }

        let capability = graphTitleCapabilityProvider()
        guard capability.provider != nil else { return nil }
        return graphTitleInputs(in: data, providerID: capability.providerID)[sourceNodeID]
    }

    internal func actionTarget(for selectedNodeID: String?) -> GraphThreadActionTarget? {
        guard let graphNodeID = selectedGraphNodeID(for: selectedNodeID) else { return nil }
        if let thread = data.threadByID[graphNodeID] {
            return GraphThreadActionTarget(threadID: thread.id,
                                           rawMessageID: thread.rootNodeID,
                                           subject: thread.subject,
                                           tags: thread.tags)
        }
        guard let message = data.messageByID[graphNodeID],
              let thread = data.threadByID[message.threadID] else { return nil }
        return GraphThreadActionTarget(threadID: thread.id,
                                       rawMessageID: message.rawMessageID,
                                       subject: thread.subject,
                                       tags: message.tags)
    }

    internal func nextSelection(from selectedNodeID: String?,
                                direction: GraphDirection) -> String? {
        let selectedGraphID = selectedGraphNodeID(for: selectedNodeID)
            ?? data.threads.first?.id
            ?? data.messages.first?.id
        guard let selectedGraphID,
              let origin = nodePositions[selectedGraphID] else {
            return data.threads.first?.rootNodeID ?? data.messages.first?.rawMessageID
        }

        let candidates = nodePositions.filter { candidate in
            candidate.key != selectedGraphID &&
            (data.threadByID[candidate.key] != nil || data.messageByID[candidate.key] != nil)
        }
        let next = candidates.min { lhs, rhs in
            score(lhs.value, from: origin, direction: direction) <
            score(rhs.value, from: origin, direction: direction)
        }?.key
        return rootNodeID(forGraphNodeID: next)
    }

    internal func water(threadID: String, settings: GraphCanvasSettings) {
        settings.incrementWateredCount(for: threadID)
    }

    private func loadArchivedEntries() async {
        do {
            let entries = try await store.fetchArchivedInGraphEntries()
            archivedEntriesByThreadID = Dictionary(uniqueKeysWithValues: entries.map { ($0.threadID, $0) })
            archivedThreadIDs = Set(entries.map(\.threadID))
            rebuildData()
        } catch {
            archivedEntriesByThreadID = [:]
            archivedThreadIDs = []
        }
    }

    private func rebuildData() {
        let hiddenArchivedThreadIDs = showsArchivedThreads ? [] : archivedThreadIDs
        let rebuilt = GraphData.make(roots: sourceRoots,
                                     archivedThreadIDs: hiddenArchivedThreadIDs,
                                     tagsByNodeID: currentTagsByNodeID,
                                     topicSignalsByRawThreadID: graphTopicSignalsByRawThreadID,
                                     summariesByNodeID: currentSummariesByNodeID,
                                     titlesByNodeID: graphTitlesByNodeID,
                                     folders: currentFolders,
                                     folderMembershipByThreadID: currentFolderMembershipByThreadID,
                                     dismissedSuggestedTopicIDs: dismissedSuggestedTopicIDs,
                                     hiddenSuggestedTopics: hiddenSuggestedTopics,
                                     branchLimit: visibleBranchLimit,
                                     branchBatchSize: branchPageSize,
                                     perNodeBranchPageSize: perNodeBranchPageSize,
                                     visibleChildLimitsByParentID: visibleChildLimitsByParentID,
                                     messageLimitPerBranch: Self.messagePreviewLimitPerBranch)
        let nextMessageIDs = Set(rebuilt.messages.map(\.id))
        let newMessageIDs = nextMessageIDs.subtracting(previousMessageIDs)
        if !previousMessageIDs.isEmpty {
            sproutingMessageIDs = newMessageIDs
        }
        previousMessageIDs = nextMessageIDs
        data = rebuilt
        if let selectedGroupingID, rebuilt.groupingByID[selectedGroupingID] == nil {
            self.selectedGroupingID = nil
        }
        syncArchivedCompostEntries()
        refreshGraphTitles(for: rebuilt)
        refreshGraphTopics()
    }

    private func refreshGraphTitles(for graphData: GraphData) {
        guard isGraphTitleGenerationActive,
              let graphTitleCapabilityProvider else { return }
        let capability = graphTitleCapabilityProvider()
        let inputs = graphTitleInputs(in: graphData, providerID: capability.providerID)
        let inputNodeIDs = Set(inputs.keys)
        let staleRegenerationNodeIDs = regeneratingGraphTitleNodeIDs.subtracting(inputNodeIDs)
        if !staleRegenerationNodeIDs.isEmpty {
            regeneratingGraphTitleNodeIDs.subtract(staleRegenerationNodeIDs)
        }
        guard !inputs.isEmpty else {
            cancelGraphTitleRefresh()
            currentGraphTitleInputs = [:]
            return
        }

        let inputsChanged = inputs != currentGraphTitleInputs
        let needsRefresh = inputs.values.contains {
            graphTitleFingerprintsByNodeID[$0.nodeID] != $0.fingerprint ||
                regeneratingGraphTitleNodeIDs.contains($0.nodeID)
        }
        if !inputsChanged, graphTitleRefreshTask != nil || !needsRefresh {
            return
        }

        cancelGraphTitleRefresh()
        currentGraphTitleInputs = inputs
        let refreshID = UUID()
        graphTitleRefreshID = refreshID
        graphTitleRefreshTask = Task { [weak self] in
            await self?.loadAndGenerateGraphTitles(inputs: inputs,
                                                   initialCapability: capability,
                                                   refreshID: refreshID)
        }
    }

    private func graphTitleInputs(in graphData: GraphData,
                                  providerID: String) -> [String: GraphTitleInput] {
        var inputs: [String: GraphTitleInput] = [:]
        inputs.reserveCapacity(graphData.visibleEmailNodeCount)

        for thread in graphData.threads {
            let summary = (currentSummariesByNodeID[thread.rootNodeID]
                ?? currentSummariesByNodeID[GraphData.messageNodeID(for: thread.rootNodeID)])?.text ?? ""
            let subject = thread.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedSummary.isEmpty else { continue }
            inputs[thread.rootNodeID] = GraphTitleInput(
                nodeID: thread.rootNodeID,
                subject: subject,
                summary: cleanedSummary,
                fingerprint: ThreadSummaryFingerprint.makeGraphTitle(subject: subject,
                                                                     summary: cleanedSummary,
                                                                     providerID: providerID)
            )
        }

        for message in graphData.messages {
            let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = message.summary?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !summary.isEmpty else { continue }
            inputs[message.rawMessageID] = GraphTitleInput(
                nodeID: message.rawMessageID,
                subject: subject,
                summary: summary,
                fingerprint: ThreadSummaryFingerprint.makeGraphTitle(subject: subject,
                                                                     summary: summary,
                                                                     providerID: providerID)
            )
        }
        return inputs
    }

    private func loadAndGenerateGraphTitles(inputs: [String: GraphTitleInput],
                                            initialCapability: GraphTitleCapability,
                                            refreshID: UUID) async {
        var cachedByID: [String: SummaryCacheEntry] = [:]
        do {
            let cached = try await store.fetchSummaries(scope: .graphTitle,
                                                        ids: Array(inputs.keys))
            cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.scopeID, $0) })
        } catch {
            Log.app.error("Failed to load graph-title cache: \(error.localizedDescription, privacy: .public)")
        }

        guard isCurrentGraphTitleRefresh(refreshID, inputs: inputs) else { return }
        var didApplyCachedTitle = false
        var pendingInputs: [GraphTitleInput] = []
        for input in inputs.values.sorted(by: { $0.nodeID < $1.nodeID }) {
            if let cached = cachedByID[input.nodeID],
               cached.fingerprint == input.fingerprint,
               cached.provider == initialCapability.providerID,
               !regeneratingGraphTitleNodeIDs.contains(input.nodeID) {
                graphTitlesByNodeID[input.nodeID] = cached.summaryText
                graphTitleFingerprintsByNodeID[input.nodeID] = cached.fingerprint
                didApplyCachedTitle = true
            } else {
                if graphTitlesByNodeID[input.nodeID] == nil,
                   let staleTitle = cachedByID[input.nodeID]?.summaryText,
                   !staleTitle.isEmpty {
                    graphTitlesByNodeID[input.nodeID] = staleTitle
                    didApplyCachedTitle = true
                }
                pendingInputs.append(input)
            }
        }
        if didApplyCachedTitle {
            rebuildData()
        }

        var capability = initialCapability
        var retryCount = 0
        while capability.provider == nil,
              capability.shouldRetry,
              retryCount < Self.maximumGraphTitleReadinessRetries,
              isCurrentGraphTitleRefresh(refreshID, inputs: inputs) {
            retryCount += 1
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard isCurrentGraphTitleRefresh(refreshID, inputs: inputs),
                  let graphTitleCapabilityProvider else { return }
            capability = graphTitleCapabilityProvider()
        }

        guard isCurrentGraphTitleRefresh(refreshID, inputs: inputs) else {
            return
        }
        guard let provider = capability.provider else {
            finishGraphTitleRegeneration(for: inputs)
            finishGraphTitleRefresh(refreshID)
            return
        }

        for input in pendingInputs {
            guard isCurrentGraphTitleRefresh(refreshID, inputs: inputs),
                  currentGraphTitleInputs[input.nodeID]?.fingerprint == input.fingerprint else { return }
            do {
                let title = try await provider.makeGraphTitle(
                    GraphTitleRequest(subject: input.subject, summary: input.summary)
                )
                guard isCurrentGraphTitleRefresh(refreshID, inputs: inputs),
                      currentGraphTitleInputs[input.nodeID]?.fingerprint == input.fingerprint else { return }
                let entry = SummaryCacheEntry(scope: .graphTitle,
                                              scopeID: input.nodeID,
                                              summaryText: title,
                                              generatedAt: Date(),
                                              fingerprint: input.fingerprint,
                                              provider: capability.providerID)
                do {
                    try await store.upsertSummaries([entry])
                } catch {
                    Log.app.error("Failed to persist graph-title cache: \(error.localizedDescription, privacy: .public)")
                }
                graphTitlesByNodeID[input.nodeID] = title
                graphTitleFingerprintsByNodeID[input.nodeID] = input.fingerprint
                regeneratingGraphTitleNodeIDs.remove(input.nodeID)
                rebuildData()
            } catch is CancellationError {
                if isCurrentGraphTitleRefresh(refreshID, inputs: inputs) {
                    finishGraphTitleRegeneration(for: inputs)
                    finishGraphTitleRefresh(refreshID)
                }
                return
            } catch {
                Log.app.error("Failed to generate graph title: \(error.localizedDescription, privacy: .public)")
                regeneratingGraphTitleNodeIDs.remove(input.nodeID)
            }
        }

        guard isCurrentGraphTitleRefresh(refreshID, inputs: inputs) else { return }
        finishGraphTitleRegeneration(for: inputs)
        finishGraphTitleRefresh(refreshID)
    }

    private static let maximumGraphTitleReadinessRetries = 20

    private func isCurrentGraphTitleRefresh(_ refreshID: UUID,
                                            inputs: [String: GraphTitleInput]) -> Bool {
        !Task.isCancelled &&
            isGraphTitleGenerationActive &&
            graphTitleRefreshID == refreshID &&
            currentGraphTitleInputs == inputs
    }

    private func cancelGraphTitleRefresh() {
        graphTitleRefreshID = nil
        graphTitleRefreshTask?.cancel()
        graphTitleRefreshTask = nil
    }

    private func finishGraphTitleRefresh(_ refreshID: UUID) {
        guard graphTitleRefreshID == refreshID else { return }
        graphTitleRefreshID = nil
        graphTitleRefreshTask = nil
    }

    private func finishGraphTitleRegeneration(for inputs: [String: GraphTitleInput]) {
        regeneratingGraphTitleNodeIDs.subtract(Set(inputs.keys))
    }

    private func refreshGraphTopics() {
        guard isGraphTopicGenerationActive,
              let graphTopicCapabilityProvider else { return }
        let capability = graphTopicCapabilityProvider()
        let inputs = graphTopicInputs(providerID: capability.providerID)
        guard !inputs.isEmpty else {
            cancelGraphTopicRefresh()
            currentGraphTopicInputs = [:]
            return
        }

        let inputsChanged = inputs != currentGraphTopicInputs
        let needsRefresh = inputs.values.contains {
            graphTopicFingerprintsByRawThreadID[$0.rawThreadID] != $0.fingerprint
        }
        if !inputsChanged, graphTopicRefreshTask != nil || !needsRefresh {
            return
        }

        cancelGraphTopicRefresh()
        currentGraphTopicInputs = inputs
        let refreshID = UUID()
        graphTopicRefreshID = refreshID
        graphTopicRefreshTask = Task { [weak self] in
            await self?.loadAndGenerateGraphTopics(inputs: inputs,
                                                   initialCapability: capability,
                                                   refreshID: refreshID)
        }
    }

    private func graphTopicInputs(providerID: String) -> [String: GraphTopicInput] {
        var inputs: [String: GraphTopicInput] = [:]
        inputs.reserveCapacity(sourceRoots.count)

        for root in sourceRoots {
            let nodes = Self.flattenConversation(root)
                .sorted { lhs, rhs in
                    if lhs.message.date != rhs.message.date {
                        return lhs.message.date < rhs.message.date
                    }
                    return lhs.id < rhs.id
                }
            guard !nodes.isEmpty else { continue }
            let rawThreadID = GraphData.rawThreadID(for: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawThreadID.isEmpty else { continue }
            let subject = root.message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let threadSummary = nodes.reversed().compactMap { node -> String? in
                let summary = (currentSummariesByNodeID[node.id]
                    ?? currentSummariesByNodeID[GraphData.messageNodeID(for: node.id)])?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return summary.isEmpty ? nil : summary
            }.first ?? ""
            let representativeContent = Self.representativeConversationContent(nodes)
            guard !subject.isEmpty || !threadSummary.isEmpty || !representativeContent.isEmpty else {
                continue
            }
            inputs[rawThreadID] = GraphTopicInput(
                rawThreadID: rawThreadID,
                subject: subject,
                threadSummary: threadSummary,
                representativeContent: representativeContent,
                fingerprint: ThreadSummaryFingerprint.makeGraphTopic(
                    subject: subject,
                    threadSummary: threadSummary,
                    representativeContent: representativeContent,
                    providerID: providerID
                )
            )
        }
        return inputs
    }

    private func loadAndGenerateGraphTopics(inputs: [String: GraphTopicInput],
                                            initialCapability: GraphTopicCapability,
                                            refreshID: UUID) async {
        var cachedByID: [String: SummaryCacheEntry] = [:]
        do {
            let cached = try await store.fetchSummaries(scope: .graphTopic,
                                                        ids: Array(inputs.keys))
            cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.scopeID, $0) })
        } catch {
            Log.app.error("Failed to load graph-topic cache: \(error.localizedDescription, privacy: .public)")
        }

        guard isCurrentGraphTopicRefresh(refreshID, inputs: inputs) else { return }
        var didApplyCachedResult = false
        var pendingInputs: [GraphTopicInput] = []
        for input in inputs.values.sorted(by: { $0.rawThreadID < $1.rawThreadID }) {
            guard let cached = cachedByID[input.rawThreadID],
                  cached.fingerprint == input.fingerprint,
                  cached.provider == initialCapability.providerID,
                  let record = Self.decodeGraphTopicCache(cached.summaryText) else {
                pendingInputs.append(input)
                continue
            }
            if let signal = record.signal {
                graphTopicSignalsByRawThreadID[input.rawThreadID] = signal
            } else {
                graphTopicSignalsByRawThreadID.removeValue(forKey: input.rawThreadID)
            }
            graphTopicFingerprintsByRawThreadID[input.rawThreadID] = cached.fingerprint
            didApplyCachedResult = true
        }
        if didApplyCachedResult {
            rebuildData()
        }

        guard !pendingInputs.isEmpty else {
            finishGraphTopicRefresh(refreshID)
            return
        }

        var capability = initialCapability
        var retryCount = 0
        while capability.provider == nil,
              capability.shouldRetry,
              retryCount < Self.maximumGraphTopicReadinessRetries,
              isCurrentGraphTopicRefresh(refreshID, inputs: inputs) {
            retryCount += 1
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard isCurrentGraphTopicRefresh(refreshID, inputs: inputs),
                  let graphTopicCapabilityProvider else { return }
            capability = graphTopicCapabilityProvider()
        }

        guard isCurrentGraphTopicRefresh(refreshID, inputs: inputs),
              let provider = capability.provider else {
            finishGraphTopicRefresh(refreshID)
            return
        }

        var didApplyGeneratedResult = false
        for input in pendingInputs {
            guard isCurrentGraphTopicRefresh(refreshID, inputs: inputs),
                  currentGraphTopicInputs[input.rawThreadID]?.fingerprint == input.fingerprint else {
                return
            }
            do {
                let signal = try await provider.generateTopic(
                    GraphTopicRequest(subject: input.subject,
                                      threadSummary: input.threadSummary,
                                      representativeContent: input.representativeContent)
                )
                guard isCurrentGraphTopicRefresh(refreshID, inputs: inputs),
                      currentGraphTopicInputs[input.rawThreadID]?.fingerprint == input.fingerprint else {
                    return
                }
                let record = GraphTopicCacheRecord(signal: signal)
                let entry = SummaryCacheEntry(scope: .graphTopic,
                                              scopeID: input.rawThreadID,
                                              summaryText: Self.encodeGraphTopicCache(record),
                                              generatedAt: Date(),
                                              fingerprint: input.fingerprint,
                                              provider: capability.providerID)
                do {
                    try await store.upsertSummaries([entry])
                } catch {
                    Log.app.error("Failed to persist graph-topic cache: \(error.localizedDescription, privacy: .public)")
                }
                if let signal {
                    graphTopicSignalsByRawThreadID[input.rawThreadID] = signal
                } else {
                    graphTopicSignalsByRawThreadID.removeValue(forKey: input.rawThreadID)
                }
                graphTopicFingerprintsByRawThreadID[input.rawThreadID] = input.fingerprint
                didApplyGeneratedResult = true
            } catch is CancellationError {
                return
            } catch {
                Log.app.error("Failed to generate graph topic: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard isCurrentGraphTopicRefresh(refreshID, inputs: inputs) else { return }
        if didApplyGeneratedResult {
            rebuildData()
        }
        finishGraphTopicRefresh(refreshID)
    }

    private static let maximumGraphTopicReadinessRetries = 20

    private func isCurrentGraphTopicRefresh(_ refreshID: UUID,
                                            inputs: [String: GraphTopicInput]) -> Bool {
        !Task.isCancelled &&
            isGraphTopicGenerationActive &&
            graphTopicRefreshID == refreshID &&
            currentGraphTopicInputs == inputs
    }

    private func cancelGraphTopicRefresh() {
        graphTopicRefreshID = nil
        graphTopicRefreshTask?.cancel()
        graphTopicRefreshTask = nil
    }

    private func finishGraphTopicRefresh(_ refreshID: UUID) {
        guard graphTopicRefreshID == refreshID else { return }
        graphTopicRefreshID = nil
        graphTopicRefreshTask = nil
    }

    private static func flattenConversation(_ node: ThreadNode) -> [ThreadNode] {
        [node] + node.children.flatMap(flattenConversation)
    }

    private static func representativeConversationContent(_ nodes: [ThreadNode]) -> String {
        guard !nodes.isEmpty else { return "" }
        let indices: [Int]
        if nodes.count <= 4 {
            indices = Array(nodes.indices)
        } else {
            indices = Array(Set([0, nodes.count / 3, (nodes.count * 2) / 3, nodes.count - 1])).sorted()
        }
        return indices.enumerated().map { offset, index in
            let message = nodes[index].message
            let subject = String(message.subject.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            let sender = String(message.from.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            let snippet = String(message.snippet.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            return "\(offset + 1). Subject: \(subject) | From: \(sender) | Content: \(snippet)"
        }.joined(separator: "\n")
    }

    private static func encodeGraphTopicCache(_ record: GraphTopicCacheRecord) -> String {
        guard let data = try? JSONEncoder().encode(record) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeGraphTopicCache(_ value: String) -> GraphTopicCacheRecord? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GraphTopicCacheRecord.self, from: data)
    }

    private func beginPruneAnimation(threadID: String, action: GraphCompostAction) {
        beginPruneAnimation(threadIDs: [threadID], action: action)
    }

    private func beginPruneAnimation(threadIDs: Set<String>, action: GraphCompostAction) {
        guard !threadIDs.isEmpty else { return }
        pruneCompletionTask?.cancel()
        let request = GraphPruneAnimationRequest(threadIDs: threadIDs, action: action)
        pruneAnimationRequest = request
        pruneCompletionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.finishPruneAnimation(id: request.id)
        }
    }

    private func syncArchivedCompostEntries() {
        guard showsArchivedThreads else {
            compostEntries.removeAll { $0.action == .archive }
            return
        }
        let existingArchiveIDs = Set(compostEntries.filter { $0.action == .archive }.map(\.threadID))
        let rootsData = GraphData.make(roots: sourceRoots, archivedThreadIDs: [], tagsByNodeID: currentTagsByNodeID)
        for threadID in archivedThreadIDs.subtracting(existingArchiveIDs) {
            guard let thread = rootsData.threadByID[threadID],
                  let archivedEntry = archivedEntriesByThreadID[threadID] else { continue }
            compostEntries.append(GraphCompostEntry(id: "archive-\(threadID)",
                                                    threadID: threadID,
                                                    rootNodeID: thread.rootNodeID,
                                                    subject: thread.subject,
                                                    action: .archive,
                                                    messageIDs: thread.messageIDs,
                                                    priorMailboxPath: nil,
                                                    priorAccountName: nil,
                                                    createdAt: archivedEntry.archivedAt))
        }
        compostEntries.removeAll { entry in
            entry.action == .archive && !archivedThreadIDs.contains(entry.threadID)
        }
    }

    private func score(_ point: CGPoint, from origin: CGPoint, direction: GraphDirection) -> CGFloat {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        switch direction {
        case .up where dy > 0:
            return dy + abs(dx) * 1.35
        case .down where dy < 0:
            return -dy + abs(dx) * 1.35
        case .left where dx < 0:
            return -dx + abs(dy) * 1.35
        case .right where dx > 0:
            return dx + abs(dy) * 1.35
        default:
            return .greatestFiniteMagnitude
        }
    }
}
