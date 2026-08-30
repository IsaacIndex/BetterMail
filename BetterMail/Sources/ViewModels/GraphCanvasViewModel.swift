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

/// The spatial anchor replay boundary is deliberately a value/closure seam.
/// The organization ledger owns intent and receipt durability; this presenter
/// only applies a resolved, in-memory intent and reports the resulting JSON
/// store revision. It does not claim that the two stores are one transaction.
internal struct GraphSpatialAnchorReplayIntent: Equatable, Sendable {
    internal let intentID: String
    internal let groupID: String
    internal let x: Double
    internal let y: Double
    internal let zoom: Double

    internal init(intentID: String,
                  groupID: String,
                  x: Double,
                  y: Double,
                  zoom: Double) {
        self.intentID = intentID
        self.groupID = groupID
        self.x = x
        self.y = y
        self.zoom = zoom
    }
}

internal struct GraphSpatialAnchorReplayReceipt: Equatable, Sendable {
    internal let intentID: String
    internal let appliedAt: Date
    internal let opaqueStoreRevision: String

    internal init(intentID: String,
                  appliedAt: Date,
                  opaqueStoreRevision: String) {
        self.intentID = intentID
        self.appliedAt = appliedAt
        self.opaqueStoreRevision = opaqueStoreRevision
    }
}

internal struct GraphSpatialAnchorReplaySeam: Sendable {
    internal let pendingIntent: @MainActor @Sendable (String) async -> GraphSpatialAnchorReplayIntent?
    internal let recordReceipt: @MainActor @Sendable (GraphSpatialAnchorReplayReceipt) async -> Void

    internal init(pendingIntent: @escaping @MainActor @Sendable (String) async -> GraphSpatialAnchorReplayIntent?,
                  recordReceipt: @escaping @MainActor @Sendable (GraphSpatialAnchorReplayReceipt) async -> Void) {
        self.pendingIntent = pendingIntent
        self.recordReceipt = recordReceipt
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

private enum GraphSnipRestoreError: LocalizedError {
    case incomplete

    var errorDescription: String? {
        NSLocalizedString("graph.snip.restore.incomplete",
                          comment: "Some messages could not be restored from Snip history")
    }
}

private enum GraphRestoreHistoryError: LocalizedError {
    case operationInProgress

    var errorDescription: String? {
        NSLocalizedString("graph.restore_history.error.in_progress",
                          comment: "A Restore History operation is already running")
    }
}

@MainActor
internal final class GraphCanvasViewModel: ObservableObject {
    internal nonisolated static let defaultBranchPageSize = 10
    internal nonisolated static let defaultPerNodeBranchPageSize = 6
    internal nonisolated static let defaultEmailPageSize = GraphCanvasSettings.defaultVisibleEmailsPerThread
    internal nonisolated static let defaultSummaryContextSnippetLineLimit = 10

    @Published internal private(set) var data: GraphData = .empty
    @Published internal var hoverItem: GraphHoverItem?
    @Published internal var pruneMode: GraphPruneMode = .idle
    @Published internal private(set) var isLassoSelectionActive = false
    @Published internal private(set) var compostEntries: [GraphCompostEntry] = []
    @Published internal private(set) var organizationHistoryItems: [OrganizationHistoryItem] = []
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
    @Published internal private(set) var confirmedGroupAnchors: [String: CGPoint] = [:]
    @Published internal private(set) var canUndoSpatialLayoutReset = false
    @Published internal private(set) var pruneAnimationRequest: GraphPruneAnimationRequest?
    @Published internal private(set) var selectedGroupingID: String?
    @Published internal private(set) var regeneratingGraphTitleNodeIDs: Set<String> = []
    internal var onArchiveStateChanged: (() -> Void)?

    private var sourceRoots: [ThreadNode] = []
    private var currentSearchQuery = ""
    internal private(set) var organizerRenderFilterGeneration: UInt64 = 0
    private var currentTagsByNodeID: [String: [String]] = [:]
    private var currentSummariesByNodeID: [String: GraphMessageSummary] = [:]
    private var currentManualAttachmentMessageIDs: Set<String> = []
    private var currentJWZThreadMap: [String: String] = [:]
    private var currentSnippetLineLimit = GraphCanvasViewModel.defaultSummaryContextSnippetLineLimit
    private var currentStopPhrases: [String] = []
    private var graphTitlesByNodeID: [String: String] = [:]
    private var graphTopicSignalsByRawThreadID: [String: GraphTopicSignal] = [:]
    private var currentAutomationProposals: [GraphAutomationProposal] = []
    private var usesRefreshOwnedTopicSignals = false
    private var graphTitleFingerprintsByNodeID: [String: String] = [:]
    private var graphTopicFingerprintsByRawThreadID: [String: String] = [:]
    private var currentGraphTitleInputs: [String: GraphTitleGenerationInput] = [:]
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
    private var emailPageSize = GraphCanvasViewModel.defaultEmailPageSize
    private var visibleEmailLimitsByThreadID: [String: Int] = [:]
    private var mailboxScopeID = ""
    private var sourceThreadIDs: [String] = []
    private var previousMessageIDs: Set<String> = []
    private var archivedEntriesByThreadID: [String: ArchivedInGraphEntry] = [:]
    private var dismissedRestoreHistoryEntryIDs: Set<String> = []
    private var restoringHistoryEntryID: String?
    private var pruneStateMachine = GraphPruneStateMachine()
    private var pruneCompletionTask: Task<Void, Never>?
    private var graphTitleRefreshTask: Task<Void, Never>?
    private var graphTitleRefreshID: UUID?
    private var organizerRenderedGraphVisibilityTracker = OrganizerRenderedGraphVisibilityTracker()
#if DEBUG
    /// Deterministic suspension seam for exercising supersession after a
    /// non-cancellation-aware persistence continuation resumes.
    internal var graphTitlePostPersistenceHookForTesting: (() async -> Void)?
    internal private(set) var lastSpatialLoadDispositionForTesting = "not-started"
    internal private(set) var lastSpatialReplayIntentIDForTesting: String?
    internal private(set) var lastSpatialReplayAnchorForTesting: CGPoint?
#endif
    private var graphTopicRefreshTask: Task<Void, Never>?
    private var graphTopicRefreshID: UUID?
    private var spatialLoadTask: Task<Void, Never>?
    private var spatialPersistenceTask: Task<Void, Never>?
    private var spatialResetTask: Task<Void, Never>?
    private var organizationHistoryRefreshTask: Task<Void, Never>?
    private var spatialResetScopeID: String?
    private var spatialLoadGeneration = UUID()
    private var spatialLoadedScopeID: String?
    private var spatialLayoutResetUndo: (scopeID: String, snapshot: GraphSpatialSnapshot)?
    /// Scene physics reports are deliberately kept out of `@Published` state
    /// until the layout settles. Publishing every 200 ms makes SwiftUI
    /// reconfigure the mounted scene while its simulator is still moving.
    private var pendingSceneNodePositions: [String: CGPoint] = [:]
    private var isGraphTitleGenerationActive = false
    private var isGraphTopicGenerationActive = false
    private let store: MessageStore
    private let organizationOperationStore: OrganizationOperationStore
    private let organizationMailService: any OrganizationMailExecutionServicing
    private let graphTitleCapabilityProvider: (() -> GraphTitleCapability)?
    private let graphTopicCapabilityProvider: (() -> GraphTopicCapability)?
    private let graphSpatialStore: GraphSpatialStateStore
    private let graphSpatialAnchorReplay: GraphSpatialAnchorReplaySeam?

    internal init(store: MessageStore? = nil,
                  mailClient: any GraphSnipMailMoving = MailAppleScriptClient(),
                  organizationOperationStore: OrganizationOperationStore = .shared,
                  organizationMailService: (any OrganizationMailExecutionServicing)? = nil,
                  graphTitleCapabilityProvider: (() -> GraphTitleCapability)? = nil,
                  graphTopicCapabilityProvider: (() -> GraphTopicCapability)? = nil,
                  graphSpatialStore: GraphSpatialStateStore = GraphSpatialStateStore(),
                  graphSpatialAnchorReplay: GraphSpatialAnchorReplaySeam? = nil) {
        self.store = store ?? .shared
        self.organizationOperationStore = organizationOperationStore
        self.organizationMailService = organizationMailService
            ?? OrganizationMailExecutionService(
                operationStore: organizationOperationStore,
                transport: DefaultOrganizationMailGatewayTransport(mailClient: mailClient)
            )
        self.graphTitleCapabilityProvider = graphTitleCapabilityProvider
        self.graphTopicCapabilityProvider = graphTopicCapabilityProvider
        self.graphSpatialStore = graphSpatialStore
        self.graphSpatialAnchorReplay = graphSpatialAnchorReplay
        Task { await loadArchivedEntries() }
    }

    internal var filteredNodeIDs: Set<String> {
        data.matchingNodeIDs(query: currentSearchQuery)
    }

    internal var searchResultCount: Int? {
        data.searchResultCount(query: currentSearchQuery)
    }

    internal var selectedGraphNodeIDs: Set<String> {
        Set(data.groupings.map(\.id))
            .union(data.threads.map(\.id))
            .union(data.messages.map(\.id))
    }

    internal var selectedGrouping: GraphGrouping? {
        selectedGroupingID.flatMap { data.groupingByID[$0] }
    }

    internal func renderedOrganizerReceipt(
        for snapshot: OrganizerRenderedGraphSnapshot,
        filterGeneration: UInt64
    ) -> OrganizerRenderedGraphReceipt {
        organizerRenderedGraphVisibilityTracker.receipt(
            for: snapshot,
            filterGeneration: filterGeneration
        )
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
        if usesRefreshOwnedTopicSignals {
            isGraphTopicGenerationActive = false
            cancelGraphTopicRefresh()
            currentGraphTopicInputs = [:]
            return
        }
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
                         manualAttachmentMessageIDs: Set<String> = [],
                         jwzThreadMap: [String: String] = [:],
                         snippetLineLimit: Int = GraphCanvasViewModel.defaultSummaryContextSnippetLineLimit,
                         stopPhrases: [String] = [],
                         folders: [ThreadFolder] = [],
                         folderMembershipByThreadID: [String: String] = [:],
                         automationProposals: [GraphAutomationProposal] = [],
                         topicSignalsOverride: [String: GraphTopicSignal]? = nil,
                         dismissedSuggestedTopicIDs: Set<String> = [],
                         hiddenSuggestedTopics: Set<String> = [],
                         showsArchivedThreads: Bool = false,
                         branchPageSize: Int = GraphCanvasViewModel.defaultBranchPageSize,
                         perNodeBranchPageSize: Int = 6,
                         visibleEmailsPerThread: Int = GraphCanvasViewModel.defaultEmailPageSize,
                         mailboxScopeID: String = "") {
        let clampedBranchPageSize = GraphCanvasSettings.clampedVisibleBranchCount(branchPageSize)
        let clampedPerNodeBranchPageSize = GraphCanvasSettings.clampedVisibleBranchesPerNode(perNodeBranchPageSize)
        let clampedEmailPageSize = GraphCanvasSettings.clampedVisibleEmailsPerThread(visibleEmailsPerThread)
        let nextSourceThreadIDs = roots.map { GraphData.threadNodeID(for: GraphData.rawThreadID(for: $0)) }
        let sourceChanged = nextSourceThreadIDs != sourceThreadIDs
        let archiveVisibilityChanged = showsArchivedThreads != self.showsArchivedThreads
        let mailboxScopeChanged = mailboxScopeID != self.mailboxScopeID
        let previousMailboxScopeID = self.mailboxScopeID
        if mailboxScopeChanged {
            if !previousMailboxScopeID.isEmpty {
                spatialPersistenceTask?.cancel()
                scheduleSpatialPersistence(for: previousMailboxScopeID,
                                           immediately: true,
                                           replacesPendingTask: false)
            }
            spatialLoadTask?.cancel()
            spatialLoadGeneration = UUID()
            spatialLoadedScopeID = nil
            spatialResetTask = nil
            spatialResetScopeID = nil
            nodePositions = [:]
            confirmedGroupAnchors = [:]
            pendingSceneNodePositions = [:]
            zoomScale = 1.0
            panOffset = .zero
            discardSpatialLayoutResetUndo()
        }
        if sourceChanged || archiveVisibilityChanged || mailboxScopeChanged ||
            clampedBranchPageSize != self.branchPageSize {
            visibleBranchLimit = clampedBranchPageSize
        }
        if sourceChanged || archiveVisibilityChanged ||
            mailboxScopeChanged ||
            clampedPerNodeBranchPageSize != self.perNodeBranchPageSize {
            visibleChildLimitsByParentID = [:]
        }
        if clampedEmailPageSize != self.emailPageSize || mailboxScopeChanged {
            visibleEmailLimitsByThreadID = [:]
        }
        sourceThreadIDs = nextSourceThreadIDs
        self.branchPageSize = clampedBranchPageSize
        self.perNodeBranchPageSize = clampedPerNodeBranchPageSize
        self.emailPageSize = clampedEmailPageSize
        self.mailboxScopeID = mailboxScopeID
        sourceRoots = roots
        let previousNormalizedSearchQuery = currentSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let nextNormalizedSearchQuery = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if previousNormalizedSearchQuery != nextNormalizedSearchQuery {
            organizerRenderFilterGeneration &+= 1
        }
        currentSearchQuery = searchQuery
        currentTagsByNodeID = tagsByNodeID
        currentManualAttachmentMessageIDs = manualAttachmentMessageIDs
        currentJWZThreadMap = jwzThreadMap
        currentSnippetLineLimit = snippetLineLimit
        currentStopPhrases = stopPhrases
        currentFolders = folders
        currentFolderMembershipByThreadID = folderMembershipByThreadID
        currentAutomationProposals = automationProposals
        if let topicSignalsOverride {
            usesRefreshOwnedTopicSignals = true
            cancelGraphTopicRefresh()
            graphTopicSignalsByRawThreadID = topicSignalsOverride
        } else {
            usesRefreshOwnedTopicSignals = false
        }
        self.dismissedSuggestedTopicIDs = dismissedSuggestedTopicIDs
        self.hiddenSuggestedTopics = hiddenSuggestedTopics
        self.showsArchivedThreads = showsArchivedThreads
        currentSummariesByNodeID = summariesByNodeID.mapValues {
            GraphMessageSummary(text: $0.text,
                                statusMessage: $0.statusMessage,
                                isSummarizing: $0.isSummarizing,
                                generationID: $0.generationID)
        }
        rebuildData()
        scheduleOrganizationHistoryRefresh()
        if mailboxScopeChanged {
            publishSpatialSceneState(forceApply: true)
        }
        if !mailboxScopeID.isEmpty,
           (mailboxScopeChanged || spatialLoadedScopeID != mailboxScopeID) {
            beginSpatialLoad(for: mailboxScopeID)
        }
    }

    internal func expandRemainingBranches(parentID: String) {
        expandRemaining(scope: .branches(parentID: parentID))
    }

    internal func expandRemaining(scope: GraphRemainderScope) {
        switch scope {
        case .branches(let parentID):
            guard data.remainingBranch(forParentID: parentID) != nil else { return }
            if parentID == data.center.id {
                visibleBranchLimit += branchPageSize
            } else {
                let currentVisibleChildCount = data.groupingByID[parentID]?.threadIDs.count
                    ?? perNodeBranchPageSize
                visibleChildLimitsByParentID[parentID] =
                    (visibleChildLimitsByParentID[parentID] ?? currentVisibleChildCount) + perNodeBranchPageSize
            }
        case .messages(let threadID):
            guard data.remainingEmails(forThreadID: threadID) != nil else { return }
            let visibleCount = 1 + data.messages.lazy.filter { $0.threadID == threadID }.count
            visibleEmailLimitsByThreadID[threadID] =
                (visibleEmailLimitsByThreadID[threadID] ?? visibleCount) + emailPageSize
        }
        rebuildData()
    }

    internal func setHoverItem(_ item: GraphHoverItem?) {
        hoverItem = item
    }

    internal func setNodePositions(_ positions: [String: CGPoint]) {
        pendingSceneNodePositions = [:]
        guard mergeNodePositions(positions) else { return }
        discardSpatialLayoutResetUndo()
        publishSpatialSceneState()
        scheduleSpatialPersistence()
    }

    /// Records positions emitted by the already-mounted SpriteKit scene.
    /// Interim physics frames are coalesced without notifying SwiftUI. The
    /// settled frame becomes the durable model snapshot, but is never bridged
    /// back into that same scene because it is already authoritative.
    internal func recordSceneNodePositions(_ positions: [String: CGPoint],
                                           isSettled: Bool) {
        let finitePositions = positions.filter { _, position in
            position.x.isFinite && position.y.isFinite
        }
        guard !finitePositions.isEmpty else {
            if isSettled {
                pendingSceneNodePositions = [:]
            }
            return
        }
        guard isSettled else {
            pendingSceneNodePositions = finitePositions
            return
        }

        var settledPositions = pendingSceneNodePositions
        settledPositions.merge(finitePositions) { _, settled in settled }
        pendingSceneNodePositions = [:]
        _ = mergeNodePositions(settledPositions)
        scheduleSpatialPersistence()
    }

    @discardableResult
    private func mergeNodePositions(_ positions: [String: CGPoint]) -> Bool {
        guard !positions.isEmpty else { return false }
        var mergedPositions = nodePositions
        for (nodeID, position) in positions where position.x.isFinite && position.y.isFinite {
            mergedPositions[nodeID] = position
        }
        var mergedGroupAnchors = confirmedGroupAnchors
        for grouping in data.groupings where grouping.kind == .folder {
            guard let sourceFolderID = grouping.sourceFolderID,
                  let position = mergedPositions[grouping.id] else { continue }
            mergedGroupAnchors[sourceFolderID] = position
        }
        guard mergedPositions != nodePositions
                || mergedGroupAnchors != confirmedGroupAnchors else { return false }
        nodePositions = mergedPositions
        confirmedGroupAnchors = mergedGroupAnchors
        return true
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
        if snipPhase == .staging && stagedSnipItems.isEmpty {
            discardSnipSession()
        }
        isLassoSelectionActive = false
        pruneMode = pruneMode == .archive ? .idle : .archive
        _ = pruneStateMachine.send(pruneMode == .archive ? .enterArchive : .cancel)
    }

    internal func toggleLassoSelection() {
        guard !isArchiveDisabledForSnip else { return }
        if isLassoSelectionActive {
            isLassoSelectionActive = false
            return
        }
        exitPruneMode()
        isLassoSelectionActive = true
    }

    internal func deactivateLassoSelection() {
        isLassoSelectionActive = false
    }

    internal func activateSnip() {
        switch snipPhase {
        case .idle:
            isLassoSelectionActive = false
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
        isLassoSelectionActive = false
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
        if snipPhase == .staging && stagedSnipItems.isEmpty {
            discardSnipSession()
        }
        isLassoSelectionActive = false
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
    internal func confirmSnipBatch(
        request: GraphSnipBatchRequest,
        disclosedEffects: GraphSnipBatchDisclosure
    ) async -> GraphSnipBatchResult? {
        guard snipPhase == .allocating,
              request == snipBatchRequest,
              request.items == stagedSnipItems,
              canConfirmSnipAllocations,
              let currentDisclosure = currentSnipBatchDisclosure(for: request),
              currentDisclosure == disclosedEffects else { return nil }
        let frozenAllocations = snipAllocations
        snipPhase = .moving
        snipMoveCompletedCount = 0
        snipMoveTotalCount = request.items.count
        let result = await executeSnipBatch(items: request.items,
                                            allocations: frozenAllocations,
                                            disclosedEffects: disclosedEffects,
                                            batchID: request.id)
        completeSnipBatch(result)
        return result
    }

    internal func currentSnipBatchDisclosure(
        for request: GraphSnipBatchRequest
    ) -> GraphSnipBatchDisclosure? {
        guard snipPhase == .allocating,
              request == snipBatchRequest,
              request.items == stagedSnipItems,
              canConfirmSnipAllocations else {
            return nil
        }
        return Self.makeSnipBatchDisclosure(request: request,
                                            allocations: snipAllocations)
    }

    internal static func makeSnipBatchDisclosure(
        request: GraphSnipBatchRequest,
        allocations: [String: GraphSnipAllocation]
    ) -> GraphSnipBatchDisclosure? {
        guard Set(request.items.map(\.threadID)).count == request.items.count else {
            return nil
        }
        let rows = request.items.compactMap { item -> GraphSnipEffectDisclosure? in
            guard let allocation = allocations[item.threadID],
                  allocation.threadID == item.threadID else {
                return nil
            }
            let destinationAccount = allocation.destinationAccountName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let destinationPath = allocation.destinationMailboxPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destinationAccount.isEmpty,
                  !destinationPath.isEmpty,
                  destinationAccount.caseInsensitiveCompare(request.accountName) == .orderedSame,
                  destinationAccount.caseInsensitiveCompare(item.accountName) == .orderedSame else {
                return nil
            }
            let effect = snipMailEffect(item: item, allocation: allocation)
            if let effect, !effect.hasCompleteMailDisclosure {
                return nil
            }
            return GraphSnipEffectDisclosure(threadID: item.threadID,
                                             subject: item.subject,
                                             destinationAccountName: destinationAccount,
                                             destinationMailboxPath: destinationPath,
                                             effect: effect)
        }
        guard rows.count == request.items.count else { return nil }
        return GraphSnipBatchDisclosure(requestID: request.id, items: rows)
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
            let source = node.message.physicalSource
            let messageID = source.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedID = GraphMailMoveResult.normalizedMessageID(messageID)
            let message = GraphSnipMessage(id: messageID,
                                           sourceMailboxPath: source.mailboxID,
                                           sourceAccountName: source.accountName)
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
        allocations: [String: GraphSnipAllocation],
        disclosedEffects: GraphSnipBatchDisclosure,
        batchID: UUID
    ) async -> GraphSnipBatchResult {
        var batchResult = GraphSnipBatchResult()
        let disclosureByThreadID = Dictionary(uniqueKeysWithValues: disclosedEffects.items.map {
            ($0.threadID, $0)
        })
        for item in items {
            guard let allocation = allocations[item.threadID],
                  let disclosure = disclosureByThreadID[item.threadID] else {
                snipMoveCompletedCount += 1
                continue
            }
            let (classification, outcome) = await executeSnipItem(item,
                                                                  allocation: allocation,
                                                                  disclosure: disclosure,
                                                                  batchID: batchID)
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
        allocation: GraphSnipAllocation,
        disclosure: GraphSnipEffectDisclosure,
        batchID: UUID
    ) async -> (GraphSnipExecutionClassification, GraphSnipBatchOutcome) {
        let destination = GraphMailboxTuple(accountName: allocation.destinationAccountName,
                                            mailboxPath: allocation.destinationMailboxPath)
        let messagesToMove = item.messages.filter {
            !destination.matches(accountName: $0.sourceAccountName,
                                 mailboxPath: $0.sourceMailboxPath)
        }
        guard !messagesToMove.isEmpty else {
            guard disclosure.effect == nil,
                  disclosure.destinationAccountName == allocation.destinationAccountName
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  disclosure.destinationMailboxPath == allocation.destinationMailboxPath
                    .trimmingCharacters(in: .whitespacesAndNewlines) else {
                return (.unchanged,
                        GraphSnipBatchOutcome(item: item,
                                              allocation: allocation,
                                              displacedMessages: []))
            }
            return (.succeeded,
                    GraphSnipBatchOutcome(item: item,
                                          allocation: allocation,
                                          displacedMessages: []))
        }

        guard let effect = Self.snipMailEffect(item: item, allocation: allocation),
              let disclosedEffect = disclosure.effect,
              effect == disclosedEffect else {
            return (.unchanged,
                    GraphSnipBatchOutcome(item: item,
                                          allocation: allocation,
                                          displacedMessages: []))
        }
        let routes = effect.sourceRoutes
        let now = Date()
        let operationID = OrganizationMailOperationIdentifier.make(
            namespace: "graph-snip",
            seed: "\(batchID.uuidString)|\(item.threadID)|\(allocation.destinationAccountName)|\(allocation.destinationMailboxPath)"
        )

        let gatewayOutcome: OrganizationMailGatewayOutcome
        do {
            let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
                effect: effect,
                disclosedEffect: disclosedEffect,
                confirmedAt: now,
                now: now
            )
            gatewayOutcome = try await organizationMailService.move(
                OrganizationMailMoveExecution(operationID: operationID,
                                              kind: .snip,
                                              effect: effect,
                                              authorization: authorization,
                                              currentConsent: nil,
                                              routes: routes,
                                              destination: effect.destination ?? .none,
                                              now: now)
            )
        } catch {
            Log.app.error("Graph batch Snip Mail move failed. messageCount=\(routes.count, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)")
            return (.unchanged,
                    GraphSnipBatchOutcome(item: item,
                                          allocation: allocation,
                                          displacedMessages: []))
        }

        let completedRoutes = Set(gatewayOutcome.completedRoutes)
        let movedMessages = messagesToMove.compactMap { message -> GraphSnipMovedMessage? in
            let route = OrganizationMailRoute(messageID: message.id,
                                              account: message.sourceAccountName,
                                              mailboxPath: message.sourceMailboxPath)
            guard completedRoutes.contains(route) else { return nil }
            return GraphSnipMovedMessage(messageID: message.id,
                                         sourceMailboxPath: message.sourceMailboxPath,
                                         sourceAccountName: message.sourceAccountName,
                                         destinationMailboxPath: allocation.destinationMailboxPath,
                                         destinationAccountName: allocation.destinationAccountName)
        }.sorted { $0.id < $1.id }
        if gatewayOutcome.isComplete, movedMessages.count == routes.count {
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
        // Partial Mail work is retained for explicit History recovery. It is
        // never silently compensated with an undisclosed restore mutation.
        return (.recoveryNeeded,
                GraphSnipBatchOutcome(item: item,
                                      allocation: allocation,
                                      displacedMessages: movedMessages))
    }

    private static func snipMailEffect(
        item: GraphSnipItem,
        allocation: GraphSnipAllocation
    ) -> OrganizationEffect? {
        let destination = GraphMailboxTuple(accountName: allocation.destinationAccountName,
                                            mailboxPath: allocation.destinationMailboxPath)
        let routes = item.messages.filter {
            !destination.matches(accountName: $0.sourceAccountName,
                                 mailboxPath: $0.sourceMailboxPath)
        }.map {
            OrganizationMailRoute(messageID: $0.id,
                                  account: $0.sourceAccountName,
                                  mailboxPath: $0.sourceMailboxPath)
        }.sorted {
            if $0.account != $1.account { return $0.account < $1.account }
            if $0.mailboxPath != $1.mailboxPath { return $0.mailboxPath < $1.mailboxPath }
            return $0.messageID < $1.messageID
        }
        guard !routes.isEmpty else { return nil }
        return OrganizationEffect.appleMail(
            operation: .snip,
            mutation: .messageMove,
            messageCount: routes.count,
            sourceRoutes: routes,
            destination: .mailbox(account: allocation.destinationAccountName,
                                  path: allocation.destinationMailboxPath),
            reversibility: .conditionallyReversible
        )
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
        scheduleOrganizationHistoryRefresh()

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
            dismissedRestoreHistoryEntryIDs.remove("archive-\(threadID)")
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
            scheduleOrganizationHistoryRefresh()
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

    internal func dismissRestoreHistoryEntry(_ entry: GraphCompostEntry) {
        dismissedRestoreHistoryEntryIDs.insert(entry.id)
        compostEntries.removeAll { $0.id == entry.id }
        scheduleOrganizationHistoryRefresh()
    }

    internal func restore(_ entry: GraphCompostEntry) async throws {
        guard restoringHistoryEntryID == nil else {
            throw GraphRestoreHistoryError.operationInProgress
        }
        restoringHistoryEntryID = entry.id
        if entry.action == .archive {
            _ = pruneStateMachine.send(.restore(threadID: entry.threadID))
        }
        defer {
            restoringHistoryEntryID = nil
            if entry.action == .archive {
                _ = pruneStateMachine.send(.restoreFinished)
            }
        }
        switch entry.action {
        case .archive:
            try await store.deleteArchivedInGraphEntry(threadID: entry.threadID)
            archivedEntriesByThreadID.removeValue(forKey: entry.threadID)
            archivedThreadIDs.remove(entry.threadID)
        case .snip:
            if !entry.movedMessages.isEmpty {
                let remainingMessages = await restoreMovedMessages(entry.movedMessages,
                                                                   operationSeed: entry.id)
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
                    scheduleOrganizationHistoryRefresh()
                    throw GraphSnipRestoreError.incomplete
                }
            } else if entry.priorMailboxPath != nil {
                // Legacy entries lack exact current source routes. Recovery is
                // deliberately fail-closed instead of asking Mail to search by
                // identifier and infer the source mailbox.
                throw GraphSnipRestoreError.incomplete
            }
            archivedThreadIDs.remove(entry.threadID)
        }
        dismissedRestoreHistoryEntryIDs.remove(entry.id)
        compostEntries.removeAll { $0.id == entry.id }
        scheduleOrganizationHistoryRefresh()
        rebuildData()
        if entry.action == .archive {
            onArchiveStateChanged?()
        }
    }

    private func restoreMovedMessages(
        _ movedMessages: [GraphSnipMovedMessage],
        operationSeed: String
    ) async -> [GraphSnipMovedMessage] {
        let routes = movedMessages.map { message in
            OrganizationMailRestoreRoute(
                current: OrganizationMailRoute(messageID: message.messageID,
                                               account: message.destinationAccountName,
                                               mailboxPath: message.destinationMailboxPath),
                destination: OrganizationMailRoute(messageID: message.messageID,
                                                   account: message.sourceAccountName,
                                                   mailboxPath: message.sourceMailboxPath)
            )
        }
        let now = Date()
        let effect = OrganizationEffect.appleMail(
            operation: .messageRestore,
            mutation: .messageRestore,
            messageCount: routes.count,
            sourceRoutes: routes.map(\.current),
            destination: .originalSourceRoutes,
            reversibility: .conditionallyReversible
        )
        do {
            let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
                effect: effect,
                confirmedAt: now,
                now: now
            )
            let outcome = try await organizationMailService.restore(
                OrganizationMailRestoreExecution(
                    operationID: OrganizationMailOperationIdentifier.makeRestore(
                        namespace: "graph-snip-restore",
                        seed: operationSeed,
                        routes: routes
                    ),
                    kind: .undo,
                    effect: effect,
                    authorization: authorization,
                    currentConsent: nil,
                    routes: routes,
                    now: now
                )
            )
            let completed = Set(outcome.completedRoutes)
            return movedMessages.filter { message in
                let current = OrganizationMailRoute(messageID: message.messageID,
                                                    account: message.destinationAccountName,
                                                    mailboxPath: message.destinationMailboxPath)
                return !completed.contains(current)
            }
        } catch {
            Log.app.error("Graph Snip restore failed. messageCount=\(routes.count, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)")
            return movedMessages
        }
    }

    internal func zoomIn() {
        setZoom(zoomScale * GraphViewport.toolbarZoomFactor)
    }

    internal func zoomOut() {
        setZoom(zoomScale / GraphViewport.toolbarZoomFactor)
    }

    internal func setZoom(_ value: CGFloat) {
        discardSpatialLayoutResetUndo()
        zoomScale = GraphViewport.clampedZoom(value)
        scheduleSpatialPersistence()
    }

    internal func setPanOffset(_ value: CGPoint) {
        discardSpatialLayoutResetUndo()
        panOffset = value
        scheduleSpatialPersistence()
    }

    internal func resetViewport() {
        discardSpatialLayoutResetUndo()
        zoomScale = 1.0
        panOffset = .zero
        scheduleSpatialPersistence()
    }

    /// Resets only the currently active mailbox scope. The actor-backed store
    /// keeps every other scope intact; failed writes never mutate the active
    /// in-memory state back into the persisted document.
    internal func resetSpatialLayout() {
        pendingSceneNodePositions = [:]
        guard !mailboxScopeID.isEmpty else {
            discardSpatialLayoutResetUndo()
            nodePositions = [:]
            confirmedGroupAnchors = [:]
            resetViewport()
            publishSpatialSceneState(forceApply: true)
            return
        }

        spatialLoadTask?.cancel()
        spatialLoadGeneration = UUID()
        spatialPersistenceTask?.cancel()
        spatialLayoutResetUndo = (scopeID: mailboxScopeID,
                                  snapshot: makeSpatialSnapshot())
        canUndoSpatialLayoutReset = true
        nodePositions = [:]
        confirmedGroupAnchors = [:]
        zoomScale = 1.0
        panOffset = .zero
        spatialLoadedScopeID = mailboxScopeID
        publishSpatialSceneState(forceApply: true)
        let scopeID = mailboxScopeID
        let resetTask = Task { [graphSpatialStore] in
            do {
                try await graphSpatialStore.resetActiveScope(scopeID: scopeID)
            } catch {
                Log.app.error("Graph spatial reset failed: \(String(describing: error), privacy: .private)")
            }
        }
        spatialResetTask = resetTask
        spatialResetScopeID = scopeID
    }

    /// Restores the exact pre-reset snapshot only while the same mailbox scope
    /// remains active. The reset write is awaited before the restoration write
    /// so a fast Undo cannot be overwritten by the earlier actor operation.
    internal func undoSpatialLayoutReset() {
        guard let undo = spatialLayoutResetUndo,
              undo.scopeID == mailboxScopeID else {
            discardSpatialLayoutResetUndo()
            return
        }

        let pendingReset = spatialResetScopeID == undo.scopeID ? spatialResetTask : nil
        spatialResetTask = nil
        spatialResetScopeID = nil
        spatialLayoutResetUndo = nil
        canUndoSpatialLayoutReset = false
        applySpatialSnapshot(undo.snapshot,
                             scopeID: undo.scopeID,
                             replayIntent: nil)
        publishSpatialSceneState(forceApply: true)

        let restoredSnapshot = makeSpatialSnapshot()
        let graphSpatialStore = graphSpatialStore
        spatialPersistenceTask?.cancel()
        spatialPersistenceTask = Task {
            await pendingReset?.value
            do {
                try await graphSpatialStore.save(restoredSnapshot,
                                                 forScopeID: undo.scopeID)
            } catch {
                Log.app.error("Graph spatial reset undo failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Flushes the current scope's latest snapshot at lifecycle boundaries.
    /// This is intentionally a scheduled actor write, not a claim of
    /// Core Data + JSON atomicity.
    internal func flushSpatialStatePersistence() {
        if !pendingSceneNodePositions.isEmpty {
            _ = mergeNodePositions(pendingSceneNodePositions)
            pendingSceneNodePositions = [:]
        }
        scheduleSpatialPersistence(for: mailboxScopeID, immediately: true)
    }

#if DEBUG
    /// Deterministic test barrier for the asynchronous actor-backed scope load.
    /// Production presentation remains non-blocking; tests use this instead of
    /// assuming a fixed delay is sufficient on every CI or local machine.
    internal func awaitSpatialStateLoadForTesting() async {
        await spatialLoadTask?.value
    }

    internal func awaitSpatialStatePersistenceForTesting() async {
        await spatialPersistenceTask?.value
    }
#endif

    /// Persists a newly confirmed Group anchor before the organization ledger
    /// records its separate spatial receipt. The returned revision is opaque
    /// and contains no mailbox, Group, or conversation identifier.
    internal func persistConfirmedGroupAnchor(groupID: String,
                                              point: CGPoint) async throws -> String {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty,
              !mailboxScopeID.isEmpty,
              point.x.isFinite,
              point.y.isFinite else {
            throw GraphSpatialStateStoreError.invalidScopeID
        }
        discardSpatialLayoutResetUndo()
        pendingSceneNodePositions = [:]
        confirmedGroupAnchors[normalizedGroupID] = point
        if let grouping = data.groupings.first(where: { $0.sourceFolderID == normalizedGroupID }) {
            nodePositions[grouping.id] = point
        }
        publishSpatialSceneState(forceApply: true)
        let snapshot = makeSpatialSnapshot()
        try await graphSpatialStore.save(snapshot, forScopeID: mailboxScopeID)
        return spatialStoreRevision(for: snapshot.updatedAt)
    }

    /// Prunes a scope only when the caller has a complete source inventory.
    /// Visible/paged graph IDs must not be passed here: omitted IDs are treated
    /// as genuinely deleted and removed from both the in-memory merge and the
    /// durable opaque-token document.
    internal func pruneSpatialState(sourceNodeIDs: Set<String>,
                                    confirmedGroupIDs: Set<String>) {
        guard !mailboxScopeID.isEmpty else { return }
        spatialPersistenceTask?.cancel()
        let validNodeIDs = sourceNodeIDs.filter(GraphSpatialOpaqueToken.shouldPersistNodeID)
        let syntheticNodeIDs = Set(data.groupings.map(\.id))
            .union([data.center.id])
            .union(data.remainingBranches.map(\.id))
        nodePositions = nodePositions.filter { nodeID, _ in
            syntheticNodeIDs.contains(nodeID) || validNodeIDs.contains(nodeID)
        }
        confirmedGroupAnchors = confirmedGroupAnchors.filter { confirmedGroupIDs.contains($0.key) }
        publishSpatialSceneState()

        let scopeID = mailboxScopeID
        let graphSpatialStore = graphSpatialStore
        Task {
            do {
                try await graphSpatialStore.prune(scopeID: scopeID,
                                                  sourceNodeIDs: Set(validNodeIDs),
                                                  confirmedGroupIDs: confirmedGroupIDs)
            } catch {
                Log.app.error("Graph spatial prune failed: \(String(describing: error), privacy: .private)")
            }
        }
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

    private func graphTitleInputForRegeneration(for selectedNodeID: String?) -> GraphTitleGenerationInput? {
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
            scheduleOrganizationHistoryRefresh()
        } catch {
            archivedEntriesByThreadID = [:]
            archivedThreadIDs = []
            scheduleOrganizationHistoryRefresh()
        }
    }

    private func scheduleOrganizationHistoryRefresh() {
        organizationHistoryRefreshTask?.cancel()
        let legacyCompost = compostEntries
        let legacyAutomation = currentAutomationProposals
        let operationStore = organizationOperationStore
        organizationHistoryRefreshTask = Task { [weak self] in
            let operations = (try? await operationStore.allOperations()) ?? []
            guard !Task.isCancelled, let self else { return }
            self.organizationHistoryItems = OrganizationHistoryProjection.make(
                operations: operations,
                legacyCompost: legacyCompost,
                legacyAutomation: legacyAutomation
            )
        }
    }

    private func beginSpatialLoad(for scopeID: String) {
        guard !scopeID.isEmpty else { return }
        spatialLoadTask?.cancel()
        let generation = UUID()
        spatialLoadGeneration = generation
        let sourceNodeIDs = spatialSourceNodeIDs()
        let confirmedGroupIDs = spatialConfirmedGroupIDs()
        let graphSpatialStore = graphSpatialStore
        let graphSpatialAnchorReplay = graphSpatialAnchorReplay
        spatialLoadTask = Task { [weak self] in
            let snapshot = await graphSpatialStore.load(scopeID: scopeID,
                                                         sourceNodeIDs: sourceNodeIDs,
                                                         confirmedGroupIDs: confirmedGroupIDs)
            let replayIntent = await graphSpatialAnchorReplay?.pendingIntent(scopeID)
            guard let self else { return }
            guard !Task.isCancelled else {
#if DEBUG
                self.lastSpatialLoadDispositionForTesting = "cancelled"
#endif
                return
            }
            guard self.spatialLoadGeneration == generation else {
#if DEBUG
                self.lastSpatialLoadDispositionForTesting = "superseded"
#endif
                return
            }
            guard self.mailboxScopeID == scopeID else {
#if DEBUG
                self.lastSpatialLoadDispositionForTesting = "scope-changed"
#endif
                return
            }
            self.applySpatialSnapshot(snapshot,
                                      scopeID: scopeID,
                                      replayIntent: replayIntent)
#if DEBUG
            self.lastSpatialLoadDispositionForTesting = "applied"
#endif
        }
    }

    private func applySpatialSnapshot(_ snapshot: GraphSpatialSnapshot,
                                      scopeID: String,
                                      replayIntent: GraphSpatialAnchorReplayIntent?) {
        guard mailboxScopeID == scopeID else { return }
        pendingSceneNodePositions = [:]
        var restoredPositions = snapshot.nodePositions.reduce(into: [String: CGPoint]()) { result, entry in
            let point = CGPoint(x: entry.value.x, y: entry.value.y)
            guard point.x.isFinite, point.y.isFinite else { return }
            result[entry.key] = point
        }
        var restoredAnchors = snapshot.confirmedGroupAnchors.reduce(into: [String: CGPoint]()) { result, entry in
            let point = CGPoint(x: entry.value.x, y: entry.value.y)
            guard point.x.isFinite, point.y.isFinite else { return }
            result[entry.key] = point
        }
        var restoredZoom = GraphViewport.clampedZoom(CGFloat(snapshot.zoomScale))
        if let replayIntent,
           replayIntent.x.isFinite,
           replayIntent.y.isFinite,
           replayIntent.zoom.isFinite,
           replayIntent.zoom > 0 {
            let point = CGPoint(x: replayIntent.x, y: replayIntent.y)
            restoredAnchors[replayIntent.groupID] = point
            restoredZoom = GraphViewport.clampedZoom(CGFloat(replayIntent.zoom))
            if let grouping = data.groupings.first(where: { $0.sourceFolderID == replayIntent.groupID }) {
                restoredPositions[grouping.id] = point
            }
        }

        nodePositions = restoredPositions
        confirmedGroupAnchors = restoredAnchors
        zoomScale = restoredZoom
        panOffset = CGPoint(x: snapshot.panOffset.x, y: snapshot.panOffset.y)
#if DEBUG
        lastSpatialReplayIntentIDForTesting = replayIntent?.intentID
        lastSpatialReplayAnchorForTesting = replayIntent.flatMap { restoredAnchors[$0.groupID] }
#endif
        spatialLoadedScopeID = scopeID
        publishSpatialSceneState()

        guard let replayIntent else { return }
        let replaySnapshot = makeSpatialSnapshot()
        let receipt = GraphSpatialAnchorReplayReceipt(
            intentID: replayIntent.intentID,
            appliedAt: Date(),
            opaqueStoreRevision: spatialStoreRevision(for: replaySnapshot.updatedAt)
        )
        let graphSpatialStore = graphSpatialStore
        let graphSpatialAnchorReplay = graphSpatialAnchorReplay
        spatialPersistenceTask?.cancel()
        spatialPersistenceTask = Task {
            do {
                try await graphSpatialStore.save(replaySnapshot, forScopeID: scopeID)
                await graphSpatialAnchorReplay?.recordReceipt(receipt)
            } catch {
                Log.app.error("Graph spatial anchor replay failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func scheduleSpatialPersistence(for scopeID: String? = nil,
                                             immediately: Bool = false,
                                             replacesPendingTask: Bool = true) {
        let targetScopeID = scopeID ?? mailboxScopeID
        guard !targetScopeID.isEmpty else { return }
        let snapshot = makeSpatialSnapshot()
        let pendingReset = spatialResetScopeID == targetScopeID ? spatialResetTask : nil
        if replacesPendingTask {
            spatialPersistenceTask?.cancel()
        }
        let graphSpatialStore = graphSpatialStore
        let persistenceTask = Task {
            await pendingReset?.value
            guard !Task.isCancelled else { return }
            if !immediately {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            do {
                try await graphSpatialStore.save(snapshot, forScopeID: targetScopeID)
            } catch {
                Log.app.error("Graph spatial state save failed: \(String(describing: error), privacy: .private)")
            }
        }
        if replacesPendingTask {
            spatialPersistenceTask = persistenceTask
        }
    }

    private func discardSpatialLayoutResetUndo() {
        spatialLayoutResetUndo = nil
        canUndoSpatialLayoutReset = false
    }

    private func makeSpatialSnapshot() -> GraphSpatialSnapshot {
        let groupingNodeIDs = Set(data.groupings.map(\.id))
        let persistedNodePositions = nodePositions.reduce(into: [String: GraphSpatialPoint]()) { result, entry in
            guard !groupingNodeIDs.contains(entry.key),
                  entry.key != data.center.id,
                  GraphSpatialOpaqueToken.shouldPersistNodeID(entry.key),
                  entry.value.x.isFinite,
                  entry.value.y.isFinite else { return }
            result[entry.key] = GraphSpatialPoint(x: Double(entry.value.x),
                                                  y: Double(entry.value.y))
        }
        var groupAnchors = confirmedGroupAnchors.reduce(into: [String: GraphSpatialPoint]()) { result, entry in
            guard entry.value.x.isFinite, entry.value.y.isFinite else { return }
            result[entry.key] = GraphSpatialPoint(x: Double(entry.value.x),
                                                  y: Double(entry.value.y))
        }
        for grouping in data.groupings where grouping.kind == .folder {
            guard let folderID = grouping.sourceFolderID,
                  let point = nodePositions[grouping.id],
                  point.x.isFinite,
                  point.y.isFinite else { continue }
            groupAnchors[folderID] = GraphSpatialPoint(x: Double(point.x), y: Double(point.y))
        }
        return GraphSpatialSnapshot(nodePositions: persistedNodePositions,
                                    confirmedGroupAnchors: groupAnchors,
                                    zoomScale: Double(zoomScale),
                                    panOffset: GraphSpatialPoint(x: Double(panOffset.x),
                                                                 y: Double(panOffset.y)),
                                    updatedAt: Date())
    }

    private func spatialSourceNodeIDs() -> Set<String> {
        var result = Set(data.allNodeIDs.filter {
            !$0.hasPrefix("remaining:") && !data.groupingByID.keys.contains($0) && $0 != data.center.id
        })
        for root in sourceRoots {
            result.insert(GraphData.threadNodeID(for: GraphData.rawThreadID(for: root)))
            for node in Self.flatten(root) {
                result.insert(GraphData.messageNodeID(for: node.id))
            }
        }
        return result.filter(GraphSpatialOpaqueToken.shouldPersistNodeID)
    }

    private func spatialConfirmedGroupIDs() -> Set<String> {
        Set(currentFolders.map(\.id) + data.groupings.compactMap { grouping in
            grouping.kind == .folder ? grouping.sourceFolderID : nil
        })
    }

    private func spatialStoreRevision(for date: Date) -> String {
        String(Int(date.timeIntervalSinceReferenceDate * 1_000))
    }

    private func publishSpatialSceneState(forceApply: Bool = false) {
        GraphSpatialSceneBridge.publish(nodePositions: nodePositions,
                                        confirmedGroupAnchors: confirmedGroupAnchors,
                                        forceApply: forceApply)
    }

    private func rebuildData() {
        // Persistence can publish the archived ID while the prune animation is
        // still active (for example when the initial archive load completes at
        // the same time as a new archive). Keep those exact branches projected
        // until the animation request finishes; `finishPruneAnimation` clears
        // the request before rebuilding, so they disappear at one boundary.
        let pendingPruneThreadIDs = pruneAnimationRequest?.threadIDs ?? []
        let hiddenArchivedThreadIDs = showsArchivedThreads
            ? []
            : archivedThreadIDs.subtracting(pendingPruneThreadIDs)
        let rebuilt = GraphData.make(roots: sourceRoots,
                                     archivedThreadIDs: hiddenArchivedThreadIDs,
                                     tagsByNodeID: currentTagsByNodeID,
                                     topicSignalsByRawThreadID: graphTopicSignalsByRawThreadID,
                                     summariesByNodeID: currentSummariesByNodeID,
                                     titlesByNodeID: graphTitlesByNodeID,
                                     manualAttachmentMessageIDs: currentManualAttachmentMessageIDs,
                                     jwzThreadMap: currentJWZThreadMap,
                                     folders: currentFolders,
                                     folderMembershipByThreadID: currentFolderMembershipByThreadID,
                                     automationProposals: currentAutomationProposals,
                                     dismissedSuggestedTopicIDs: dismissedSuggestedTopicIDs,
                                     hiddenSuggestedTopics: hiddenSuggestedTopics,
                                     branchLimit: visibleBranchLimit,
                                     branchBatchSize: branchPageSize,
                                     perNodeBranchPageSize: perNodeBranchPageSize,
                                     visibleChildLimitsByParentID: visibleChildLimitsByParentID,
                                     messageLimitPerBranch: emailPageSize,
                                     visibleEmailLimitsByThreadID: visibleEmailLimitsByThreadID)
        let nextMessageIDs = Set(rebuilt.messages.map(\.id))
        let newMessageIDs = nextMessageIDs.subtracting(previousMessageIDs)
        if !previousMessageIDs.isEmpty {
            sproutingMessageIDs = newMessageIDs
        }
        previousMessageIDs = nextMessageIDs
        data = rebuilt
        publishSpatialSceneState()
        if let selectedGroupingID, rebuilt.groupingByID[selectedGroupingID] == nil {
            self.selectedGroupingID = nil
        }
        syncArchivedCompostEntries()
        refreshGraphTitles(for: rebuilt)
        if !usesRefreshOwnedTopicSignals {
            refreshGraphTopics()
        }
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
                                  providerID: String) -> [String: GraphTitleGenerationInput] {
        let contextBuild = graphTitleContextBuild(providerID: providerID)
        var visibleNodeIDs = Set(graphData.threads.map(\.rootNodeID))
        visibleNodeIDs.formUnion(graphData.messages.map(\.rawMessageID))
        var inputs: [String: GraphTitleGenerationInput] = [:]
        inputs.reserveCapacity(visibleNodeIDs.count)

        for nodeID in visibleNodeIDs.sorted() {
            guard let contextInput = contextBuild.inputsByNodeID[nodeID],
                  let summaryState = currentSummariesByNodeID[nodeID]
                    ?? currentSummariesByNodeID[GraphData.messageNodeID(for: nodeID)],
                  !summaryState.isSummarizing else {
                continue
            }
            let summary = summaryState.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty,
                  let threadRevision = contextBuild.threadRevisionsByThreadID[contextInput.effectiveThreadID] else {
                continue
            }
            inputs[nodeID] = GraphTitleGenerationInputBuilder.make(
                nodeInput: contextInput,
                summary: summary,
                summaryGenerationID: summaryState.generationID,
                threadRevision: threadRevision,
                providerID: providerID
            )
        }
        return inputs
    }

    /// Uses every message in each effective source thread, including messages
    /// currently paged out of Graph, so visible title fingerprints still change
    /// when a hidden neighbour changes the conversation position.
    private func graphTitleContextBuild(providerID: String) -> ThreadSummaryContextBuild {
        var sources: [ThreadSummaryMessageSource] = []
        sources.reserveCapacity(sourceRoots.reduce(0) {
            $0 + Self.flattenConversation($1).count
        })

        for root in sourceRoots {
            let effectiveThreadID = GraphData.rawThreadID(for: root)
            for node in Self.flattenConversation(root) {
                let message = node.message
                let automaticThreadID = currentJWZThreadMap[message.threadKey]
                    ?? message.threadID
                    ?? node.id
                sources.append(ThreadSummaryMessageSourceBuilder.make(
                    message: message,
                    nodeID: node.id,
                    cacheKey: node.id,
                    effectiveThreadID: effectiveThreadID,
                    automaticThreadID: automaticThreadID,
                    isManualAttachment: currentManualAttachmentMessageIDs.contains(node.id),
                    snippetLineLimit: currentSnippetLineLimit,
                    stopPhrases: currentStopPhrases
                ))
            }
        }

        return ThreadSummaryContextBuilder.build(sources: sources,
                                                 providerID: providerID)
    }

    private func loadAndGenerateGraphTitles(inputs: [String: GraphTitleGenerationInput],
                                            initialCapability: GraphTitleCapability,
                                            refreshID: UUID) async {
        var cachedByID: [String: SummaryCacheEntry] = [:]
        do {
            let cached = try await store.fetchSummaries(scope: .graphTitle,
                                                        ids: Array(inputs.keys))
            cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.scopeID, $0) })
        } catch {
            Log.app.error("Failed to load graph-title cache: \(error.localizedDescription, privacy: .private)")
        }

        guard isCurrentGraphTitleRefresh(refreshID, inputs: inputs) else { return }
        var didApplyCachedTitle = false
        var pendingInputs: [GraphTitleGenerationInput] = []
        for input in inputs.values.sorted(by: { $0.nodeID < $1.nodeID }) {
            if let cached = cachedByID[input.nodeID],
               cached.fingerprint == input.fingerprint,
               cached.provider == initialCapability.providerID,
               !regeneratingGraphTitleNodeIDs.contains(input.nodeID) {
                graphTitlesByNodeID[input.nodeID] = GraphTitleFormatter.normalizedGeneratedTitle(
                    cached.summaryText,
                    fallback: input.request.subject
                )
                graphTitleFingerprintsByNodeID[input.nodeID] = cached.fingerprint
                didApplyCachedTitle = true
            } else {
                // Keep a prior semantic phrase readable while generation is
                // pending or unavailable. Legacy ordinal decoration is
                // stripped immediately; position remains model context only.
                let staleTitle = graphTitlesByNodeID[input.nodeID]
                    ?? cachedByID[input.nodeID]?.summaryText
                if let staleTitle, !staleTitle.isEmpty {
                    graphTitlesByNodeID[input.nodeID] = GraphTitleFormatter.normalizedGeneratedTitle(
                        staleTitle,
                        fallback: input.request.subject
                    )
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
                let semanticTitle = try await provider.makeGraphTitle(input.request)
                let title = GraphTitleFormatter.normalizedGeneratedTitle(
                    semanticTitle,
                    fallback: input.request.subject
                )
                guard isCurrentGraphTitleRefresh(refreshID, inputs: inputs),
                      currentGraphTitleInputs[input.nodeID]?.fingerprint == input.fingerprint else { return }
                let entry = SummaryCacheEntry(scope: .graphTitle,
                                              scopeID: input.nodeID,
                                              summaryText: title,
                                              generatedAt: Date(),
                                              fingerprint: input.fingerprint,
                                              provider: capability.providerID)
                try await store.upsertSummaries([entry])
#if DEBUG
                await graphTitlePostPersistenceHookForTesting?()
#endif
                guard isCurrentGraphTitleRefresh(refreshID, inputs: inputs),
                      currentGraphTitleInputs[input.nodeID]?.fingerprint == input.fingerprint else { return }
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
                Log.app.error("Failed to generate graph title: \(error.localizedDescription, privacy: .private)")
                regeneratingGraphTitleNodeIDs.remove(input.nodeID)
            }
        }

        guard isCurrentGraphTitleRefresh(refreshID, inputs: inputs) else { return }
        finishGraphTitleRegeneration(for: inputs)
        finishGraphTitleRefresh(refreshID)
    }

    private static let maximumGraphTitleReadinessRetries = 20

    private func isCurrentGraphTitleRefresh(_ refreshID: UUID,
                                            inputs: [String: GraphTitleGenerationInput]) -> Bool {
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

    private func finishGraphTitleRegeneration(for inputs: [String: GraphTitleGenerationInput]) {
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
            Log.app.error("Failed to load graph-topic cache: \(error.localizedDescription, privacy: .private)")
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
                    Log.app.error("Failed to persist graph-topic cache: \(error.localizedDescription, privacy: .private)")
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
                Log.app.error("Failed to generate graph topic: \(error.localizedDescription, privacy: .private)")
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
        let rootsData = GraphData.make(roots: sourceRoots,
                                       archivedThreadIDs: [],
                                       tagsByNodeID: currentTagsByNodeID,
                                       manualAttachmentMessageIDs: currentManualAttachmentMessageIDs,
                                       jwzThreadMap: currentJWZThreadMap)
        for threadID in archivedThreadIDs.subtracting(existingArchiveIDs) {
            let entryID = "archive-\(threadID)"
            guard !dismissedRestoreHistoryEntryIDs.contains(entryID) else { continue }
            guard let thread = rootsData.threadByID[threadID],
                  let archivedEntry = archivedEntriesByThreadID[threadID] else { continue }
            compostEntries.append(GraphCompostEntry(id: entryID,
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
            entry.action == .archive &&
                (!archivedThreadIDs.contains(entry.threadID) ||
                 dismissedRestoreHistoryEntryIDs.contains(entry.id))
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
