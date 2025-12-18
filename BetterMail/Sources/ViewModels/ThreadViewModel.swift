import Combine
import Foundation
import OSLog
import SwiftUI

@MainActor
final class ThreadViewModel: ObservableObject {
    @Published private(set) var groups: [ThreadGroup] = []
    @Published private(set) var displayedGroups: [ThreadGroup] = []
    @Published private(set) var unreadTotal: Int = 0
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isRefreshing = false
    @Published var fetchLimit: Int = 50 {
        didSet {
            if fetchLimit < 1 {
                fetchLimit = 1
            } else if fetchLimit != oldValue {
                Task { [weak self] in
                    await self?.refreshFromStore()
                }
            }
        }
    }

    private let store: MessageStore
    private let client: MailAppleScriptClient
    private let threader: JWZThreader
    private let analyzer: ThreadIntentAnalyzer
    private let mergeEngine: ThreadMergeEngine
    private let orderingPipeline = ThreadOrderingPipeline()
    private let mergeDecisions: ThreadMergeDecisionStore
    private var autoRefreshTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var didStart = false
    private var pinnedIDs: Set<String> = []
    @Published private var expandedGroupIDs: Set<String> = []

    init(store: MessageStore = .shared,
         client: MailAppleScriptClient = MailAppleScriptClient(),
         threader: JWZThreader = JWZThreader(),
         analyzer: ThreadIntentAnalyzer? = nil,
         mergeEngine: ThreadMergeEngine = ThreadMergeEngine(),
         mergeDecisions: ThreadMergeDecisionStore = ThreadMergeDecisionStore()) {
        self.store = store
        self.client = client
        self.threader = threader
        let capability = EmailSummaryProviderFactory.makeCapability()
        self.analyzer = analyzer ?? ThreadIntentAnalyzer(summaryProvider: capability.provider)
        self.mergeEngine = mergeEngine
        self.mergeDecisions = mergeDecisions
        statusMessage = capability.statusMessage
    }

    deinit {
        autoRefreshTask?.cancel()
        refreshTask?.cancel()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Task { await refreshFromStore() }
        beginAutoRefresh()
    }

    func beginAutoRefresh(interval: TimeInterval = 300) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self.refreshNow()
            }
        }
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let since = store.lastSyncDate
        statusMessage = "Refreshing…"
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let limit = self.fetchLimit
                let fetched = try await Task.detached(priority: .utility) { [client, since, limit] in
                    try client.fetchMessages(since: since, limit: limit)
                }.value
                let sinceDisplay = since.map { $0.ISO8601Format() } ?? "nil"
                Log.refresh.info("AppleScript fetch retrieved \(fetched.count, privacy: .public) messages. limit=\(limit, privacy: .public) since=\(sinceDisplay, privacy: .public)")
                try await store.upsert(messages: fetched)
                if let latest = fetched.map(\.date).max() {
                    store.lastSyncDate = latest
                }
                await refreshFromStore()
                await MainActor.run {
                    self.statusMessage = "Updated \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Refresh failed: \(error.localizedDescription)"
                }
            }
            await MainActor.run {
                self.isRefreshing = false
            }
        }
    }

    func refreshFromStore() async {
        do {
            let limit = fetchLimit
            let messages = try await store.fetchMessages(limit: limit)
            Log.refresh.debug("Loaded \(messages.count, privacy: .public) cached messages from store. limit=\(limit, privacy: .public)")
            let result = threader.buildThreads(from: messages)
            try await store.updateThreadMembership(result.messageThreadMap, threads: result.threads)
            let metadata = await analyzer.analyze(nodes: result.roots)
            let decisions = mergeDecisions.allDecisions()
            let seeds = mergeEngine.merge(nodes: result.roots,
                                          metadata: metadata,
                                          mergeOverrides: decisions)
            let groups = buildGroups(seeds: seeds, decisions: decisions)
            await MainActor.run {
                self.groups = groups
                self.unreadTotal = groups.reduce(0) { $0 + $1.unreadCount }
                self.applyOrdering()
            }
        } catch {
            statusMessage = "Threading failed: \(error.localizedDescription)"
        }
    }

    func isExpanded(_ id: String) -> Bool {
        expandedGroupIDs.contains(id)
    }

    func setExpanded(_ expanded: Bool, for id: String) {
        if expanded {
            expandedGroupIDs.insert(id)
        } else {
            expandedGroupIDs.remove(id)
        }
    }

    func acceptMerge(for id: String) {
        mergeDecisions.setDecision(.accepted, for: id)
        Task { await refreshFromStore() }
    }

    func revertMerge(for id: String) {
        mergeDecisions.setDecision(.reverted, for: id)
        Task { await refreshFromStore() }
    }

    func pin(_ id: String, enabled: Bool) {
        if enabled {
            pinnedIDs.insert(id)
        } else {
            pinnedIDs.remove(id)
        }
        applyOrdering()
    }

    private func buildGroups(seeds: [ThreadGroupSeed],
                             decisions: [String: ThreadGroup.MergeState]) -> [ThreadGroup] {
        var groups: [ThreadGroup] = []
        for seed in seeds {
            let decision = decisions[seed.metadata.threadID] ?? .suggested
            if decision == .reverted {
                groups.append(contentsOf: separateGroups(from: seed))
                continue
            }
            groups.append(makeGroup(from: seed, state: decision))
        }
        return groups
    }

    private func separateGroups(from seed: ThreadGroupSeed) -> [ThreadGroup] {
        var results: [ThreadGroup] = [makeGroup(from: seed, related: [], state: .reverted)]
        for related in seed.related {
            guard let node = related.nodes.first else { continue }
            let threadID = node.message.threadID ?? JWZThreader.threadIdentifier(for: node)
            let summary = "\(related.title) • \(related.reason.description)"
            let group = ThreadGroup(id: threadID,
                                    subject: node.message.subject.isEmpty ? related.title : node.message.subject,
                                    topicTag: related.title,
                                    summary: summary,
                                    participants: seed.metadata.participants,
                                    badges: seed.metadata.badges,
                                    intentSignals: seed.metadata.intentSignals,
                                    lastUpdated: node.message.date,
                                    unreadCount: seed.metadata.unreadCount,
                                    rootNodes: [node],
                                    relatedConversations: [],
                                    mergeReasons: [related.reason],
                                    mergeState: .reverted,
                                    isWaitingOnMe: seed.metadata.isWaitingOnMe,
                                    hasActiveTask: seed.metadata.hasActiveTask,
                                    pinned: pinnedIDs.contains(threadID),
                                    chronologicalIndex: seed.metadata.chronologicalIndex)
            results.append(group)
        }
        return results
    }

    private func makeGroup(from seed: ThreadGroupSeed,
                           related: [ThreadRelatedConversation]? = nil,
                           state: ThreadGroup.MergeState) -> ThreadGroup {
        let relatedConversations = related ?? seed.related
        return ThreadGroup(id: seed.metadata.threadID,
                           subject: seed.root.message.subject.isEmpty ? "No Subject" : seed.root.message.subject,
                           topicTag: seed.metadata.topicTag ?? relatedConversations.first?.title,
                           summary: seed.metadata.summary,
                           participants: seed.metadata.participants,
                           badges: seed.metadata.badges,
                           intentSignals: seed.metadata.intentSignals,
                           lastUpdated: seed.metadata.lastUpdated,
                           unreadCount: seed.metadata.unreadCount,
                           rootNodes: [seed.root],
                           relatedConversations: relatedConversations,
                           mergeReasons: seed.mergeReasons,
                           mergeState: state,
                           isWaitingOnMe: seed.metadata.isWaitingOnMe,
                           hasActiveTask: seed.metadata.hasActiveTask,
                           pinned: pinnedIDs.contains(seed.metadata.threadID),
                           chronologicalIndex: seed.metadata.chronologicalIndex)
    }

    private func applyOrdering() {
        displayedGroups = orderingPipeline.ordered(groups: groups,
                                                   pins: pinnedIDs)
    }
}
