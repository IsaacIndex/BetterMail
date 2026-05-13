import Combine
import CoreGraphics
import Foundation

internal enum GraphViewport {
    internal static let minimumZoomScale: CGFloat = 0.2
    internal static let maximumZoomScale: CGFloat = 5.0
    internal static let toolbarZoomFactor: CGFloat = 1.2

    internal static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumZoomScale), maximumZoomScale)
    }
}

internal enum GraphHoverItem: Equatable {
    case thread(GraphThread, CGPoint)
    case remaining(GraphRemainingBranch, CGPoint)
    case message(GraphMessage, CGPoint)
}

internal struct SnipMoveRequest: Identifiable, Equatable {
    internal let thread: GraphThread

    internal var id: String { thread.id }
}

@MainActor
internal final class GraphCanvasViewModel: ObservableObject {
    private static let branchPageSize = 10
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
    internal var onArchiveStateChanged: (() -> Void)?

    private var sourceRoots: [ThreadNode] = []
    private var currentSearchQuery = ""
    private var currentTagsByNodeID: [String: [String]] = [:]
    private var currentSummariesByNodeID: [String: GraphMessageSummary] = [:]
    private var showsArchivedThreads = false
    private var visibleBranchLimit = GraphCanvasViewModel.branchPageSize
    private var sourceThreadIDs: [String] = []
    private var previousMessageIDs: Set<String> = []
    private var archivedEntriesByThreadID: [String: ArchivedInGraphEntry] = [:]
    private var pruneStateMachine = GraphPruneStateMachine()
    private let store: MessageStore
    private let mailClient: MailAppleScriptClient

    internal init(store: MessageStore = .shared,
                  mailClient: MailAppleScriptClient = MailAppleScriptClient()) {
        self.store = store
        self.mailClient = mailClient
        Task { await loadArchivedEntries() }
    }

    internal var filteredNodeIDs: Set<String> {
        data.matchingNodeIDs(query: currentSearchQuery)
    }

    internal var selectedGraphNodeIDs: Set<String> {
        Set(data.threads.map(\.id)).union(data.messages.map(\.id))
    }

    internal func update(roots: [ThreadNode],
                         searchQuery: String,
                         tagsByNodeID: [String: [String]],
                         summariesByNodeID: [String: ThreadSummaryState],
                         showsArchivedThreads: Bool = false) {
        let nextSourceThreadIDs = roots.map { GraphData.threadNodeID(for: GraphData.rawThreadID(for: $0)) }
        if nextSourceThreadIDs != sourceThreadIDs || showsArchivedThreads != self.showsArchivedThreads {
            visibleBranchLimit = Self.branchPageSize
            sourceThreadIDs = nextSourceThreadIDs
        }
        sourceRoots = roots
        currentSearchQuery = searchQuery
        currentTagsByNodeID = tagsByNodeID
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
        visibleBranchLimit += Self.branchPageSize
        rebuildData()
    }

    internal func setHoverItem(_ item: GraphHoverItem?) {
        hoverItem = item
    }

    internal func setNodePositions(_ positions: [String: CGPoint]) {
        nodePositions = positions
    }

    internal func toggleSnipMode() {
        pruneMode = pruneMode == .snip ? .idle : .snip
        _ = pruneStateMachine.send(pruneMode == .snip ? .enterSnip : .cancel)
    }

    internal func toggleArchiveMode() {
        pruneMode = pruneMode == .archive ? .idle : .archive
        _ = pruneStateMachine.send(pruneMode == .archive ? .enterArchive : .cancel)
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

    internal func confirmSnip(request: SnipMoveRequest,
                              destinationPath: String,
                              account: String?) async throws {
        let messageIDs = request.thread.messageIDs
        guard !messageIDs.isEmpty else { return }
        _ = pruneStateMachine.send(.folderPicked)
        try await mailClient.moveMessages(messageIDs: messageIDs,
                                          toMailboxPath: destinationPath)
        let entry = GraphCompostEntry(id: "snip-\(request.thread.id)-\(UUID().uuidString)",
                                      threadID: request.thread.id,
                                      rootNodeID: request.thread.rootNodeID,
                                      subject: request.thread.subject,
                                      action: .snip,
                                      messageIDs: messageIDs,
                                      priorMailboxPath: request.thread.mailboxPath,
                                      priorAccountName: account ?? request.thread.accountName,
                                      createdAt: Date())
        compostEntries.removeAll { $0.threadID == request.thread.id }
        compostEntries.append(entry)
        snipMoveRequest = nil
        _ = pruneStateMachine.send(.animationFinished)
        pruneMode = .idle
        archivedThreadIDs.insert(request.thread.id)
        rebuildData()
    }

    internal func cancelSnip() {
        snipMoveRequest = nil
        _ = pruneStateMachine.send(.cancel)
    }

    internal func archiveThread(threadID: String) async {
        guard let thread = data.threadByID[threadID] else { return }
        do {
            let entry = ArchivedInGraphEntry(threadID: threadID, archivedAt: Date())
            try await store.upsertArchivedInGraphEntry(entry)
            archivedEntriesByThreadID[threadID] = entry
            archivedThreadIDs.insert(threadID)
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
            _ = pruneStateMachine.send(.animationFinished)
            pruneMode = .idle
            rebuildData()
            onArchiveStateChanged?()
        } catch {
            pruneMode = .idle
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
                                                  toMailboxPath: priorMailboxPath)
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
                                     summariesByNodeID: currentSummariesByNodeID,
                                     branchLimit: visibleBranchLimit,
                                     branchBatchSize: Self.branchPageSize,
                                     messageLimitPerBranch: Self.messagePreviewLimitPerBranch)
        let nextMessageIDs = Set(rebuilt.messages.map(\.id))
        let newMessageIDs = nextMessageIDs.subtracting(previousMessageIDs)
        if !previousMessageIDs.isEmpty {
            sproutingMessageIDs = newMessageIDs
        }
        previousMessageIDs = nextMessageIDs
        data = rebuilt
        syncArchivedCompostEntries()
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
