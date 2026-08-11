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

internal struct SnipMoveRequest: Identifiable, Equatable {
    internal let thread: GraphThread

    internal var id: String { thread.id }
}

internal struct GraphThreadActionTarget: Equatable {
    internal let threadID: String
    internal let rawMessageID: String
    internal let subject: String
    internal let tags: [String]
}

internal struct GraphPruneAnimationRequest: Identifiable, Equatable {
    internal let id: UUID
    internal let threadID: String
    internal let action: GraphCompostAction

    internal init(threadID: String, action: GraphCompostAction) {
        self.id = UUID()
        self.threadID = threadID
        self.action = action
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

@MainActor
internal final class GraphCanvasViewModel: ObservableObject {
    internal static let defaultBranchPageSize = 10
    private static let messagePreviewLimitPerBranch = 10

    @Published internal private(set) var data: GraphData = .empty
    @Published internal var hoverItem: GraphHoverItem?
    @Published internal var pruneMode: GraphPruneMode = .idle
    @Published internal private(set) var compostEntries: [GraphCompostEntry] = []
    @Published internal var snipMoveRequest: SnipMoveRequest?
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
    private let mailClient: MailAppleScriptClient
    private let graphTitleCapabilityProvider: (() -> GraphTitleCapability)?
    private let graphTopicCapabilityProvider: (() -> GraphTopicCapability)?

    internal init(store: MessageStore = .shared,
                  mailClient: MailAppleScriptClient = MailAppleScriptClient(),
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
        data.threads.count + (data.remainingBranch?.hiddenThreadCount ?? 0)
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
                         branchPageSize: Int = GraphCanvasViewModel.defaultBranchPageSize) {
        let clampedBranchPageSize = GraphCanvasSettings.clampedVisibleBranchCount(branchPageSize)
        let nextSourceThreadIDs = roots.map { GraphData.threadNodeID(for: GraphData.rawThreadID(for: $0)) }
        if nextSourceThreadIDs != sourceThreadIDs ||
            showsArchivedThreads != self.showsArchivedThreads ||
            clampedBranchPageSize != self.branchPageSize {
            visibleBranchLimit = clampedBranchPageSize
            sourceThreadIDs = nextSourceThreadIDs
        }
        self.branchPageSize = clampedBranchPageSize
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

    internal func expandRemainingBranches() {
        guard data.remainingBranch != nil else { return }
        visibleBranchLimit += branchPageSize
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
        pruneMode = pruneMode == .snip ? .idle : .snip
        _ = pruneStateMachine.send(pruneMode == .snip ? .enterSnip : .cancel)
    }

    internal func toggleArchiveMode() {
        pruneMode = pruneMode == .archive ? .idle : .archive
        _ = pruneStateMachine.send(pruneMode == .archive ? .enterArchive : .cancel)
    }

    internal func activateSnip(selectedThreadID: String?) {
        if let selectedThreadID {
            requestSnip(threadID: selectedThreadID)
        } else {
            toggleSnipMode()
        }
    }

    internal func activateArchive(selectedThreadID: String?) {
        if let selectedThreadID {
            requestArchive(threadID: selectedThreadID)
        } else {
            toggleArchiveMode()
        }
    }

    internal func exitPruneMode() {
        pruneMode = .idle
        _ = pruneStateMachine.send(.cancel)
    }

    internal func requestPrune(threadID: String) {
        switch pruneMode {
        case .idle:
            break
        case .snip:
            _ = pruneStateMachine.send(.edgeClicked(threadID: threadID))
            guard let thread = data.threadByID[threadID] else { return }
            snipMoveRequest = SnipMoveRequest(thread: thread)
        case .archive:
            _ = pruneStateMachine.send(.edgeClicked(threadID: threadID))
            Task { await archiveThread(threadID: threadID) }
        }
    }

    internal func requestSnip(threadID: String) {
        if pruneMode != .snip {
            _ = pruneStateMachine.send(.cancel)
            pruneMode = .snip
            _ = pruneStateMachine.send(.enterSnip)
        }
        requestPrune(threadID: threadID)
    }

    internal func requestArchive(threadID: String) {
        if pruneMode != .archive {
            _ = pruneStateMachine.send(.cancel)
            pruneMode = .archive
            _ = pruneStateMachine.send(.enterArchive)
        }
        requestPrune(threadID: threadID)
    }

    internal func confirmSnip(request: SnipMoveRequest,
                              destinationPath: String,
                              account: String?) async throws {
        let messageIDs = request.thread.messageIDs
        guard !messageIDs.isEmpty else { return }
        _ = pruneStateMachine.send(.folderPicked)
        try await mailClient.moveMessages(messageIDs: messageIDs,
                                          toMailboxPath: destinationPath,
                                          account: account,
                                          sourceMailboxPath: request.thread.mailboxPath,
                                          sourceAccount: request.thread.accountName)
        let entry = GraphCompostEntry(id: "snip-\(request.thread.id)-\(UUID().uuidString)",
                                      threadID: request.thread.id,
                                      rootNodeID: request.thread.rootNodeID,
                                      subject: request.thread.subject,
                                      action: .snip,
                                      messageIDs: messageIDs,
                                      priorMailboxPath: request.thread.mailboxPath,
                                      priorAccountName: request.thread.accountName,
                                      createdAt: Date())
        compostEntries.removeAll { $0.threadID == request.thread.id }
        compostEntries.append(entry)
        snipMoveRequest = nil
        pruneMode = .idle
        beginPruneAnimation(threadID: request.thread.id, action: .snip)
    }

    internal func cancelSnip() {
        snipMoveRequest = nil
        _ = pruneStateMachine.send(.cancel)
        pruneMode = .idle
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
        _ = pruneStateMachine.send(.animationFinished)
        archivedThreadIDs.insert(request.threadID)
        rebuildData()
        if request.action == .archive {
            onArchiveStateChanged?()
        }
    }

    internal func restore(_ entry: GraphCompostEntry) async throws {
        _ = pruneStateMachine.send(.restore(threadID: entry.threadID))
        switch entry.action {
        case .archive:
            try await store.deleteArchivedInGraphEntry(threadID: entry.threadID)
            archivedEntriesByThreadID.removeValue(forKey: entry.threadID)
            archivedThreadIDs.remove(entry.threadID)
        case .snip:
            if let priorMailboxPath = entry.priorMailboxPath {
                try await mailClient.moveMessages(messageIDs: entry.messageIDs,
                                                  toMailboxPath: priorMailboxPath,
                                                  account: entry.priorAccountName)
            }
            archivedThreadIDs.remove(entry.threadID)
        }
        compostEntries.removeAll { $0.id == entry.id }
        _ = pruneStateMachine.send(.restoreFinished)
        rebuildData()
        if entry.action == .archive {
            onArchiveStateChanged?()
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
        pruneCompletionTask?.cancel()
        let request = GraphPruneAnimationRequest(threadID: threadID, action: action)
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
