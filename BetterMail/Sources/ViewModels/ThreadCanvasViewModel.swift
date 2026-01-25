import AppKit
import Combine
import CoreGraphics
import Foundation
import OSLog

struct ThreadSummaryState {
    var text: String
    var statusMessage: String
    var isSummarizing: Bool
}

struct OpenInMailMatch: Identifiable, Equatable {
    let messageID: String
    let subject: String
    let mailbox: String
    let account: String
    let date: String

    var id: String {
        [messageID, mailbox, account, date].joined(separator: "|")
    }

    var mailboxDisplay: String {
        account.isEmpty ? mailbox : "\(account) • \(mailbox)"
    }
}

enum OpenInMailStatus: Equatable {
    case idle
    case opening
    case opened
    case searching
    case matches([OpenInMailMatch])
    case notFound
    case failed(String)
}

struct OpenInMailState: Equatable {
    let messageID: String
    let status: OpenInMailStatus
}

private struct NodeSummaryInput {
    let nodeID: String
    let cacheKey: String
    let subject: String
    let body: String
    let priorMessages: [EmailSummaryContextEntry]
    let fingerprint: String
}

private struct FolderSummaryInput {
    let folderID: String
    let title: String
    let summaryTexts: [String]
    let fingerprint: String
}

private struct ThreadFolderEdit: Hashable {
    let title: String
    let color: ThreadFolderColor
}

@MainActor
final class ThreadCanvasViewModel: ObservableObject {
    private actor SidebarBackgroundWorker {
        private let client: MailAppleScriptClient
        private let store: MessageStore
        private let threader: JWZThreader

        init(client: MailAppleScriptClient,
             store: MessageStore,
             threader: JWZThreader) {
            self.client = client
            self.store = store
            self.threader = threader
        }

        struct RefreshOutcome {
            let fetchedCount: Int
            let latestDate: Date?
        }

        struct RethreadOutcome {
            let roots: [ThreadNode]
            let unreadTotal: Int
            let messageCount: Int
            let threadCount: Int
            let manualGroupByMessageKey: [String: String]
            let manualAttachmentMessageIDs: Set<String>
            let manualGroups: [String: ManualThreadGroup]
            let jwzThreadMap: [String: String]
            let folders: [ThreadFolder]
        }

        func performRefresh(effectiveLimit: Int,
                            since: Date?,
                            snippetLineLimit: Int) async throws -> RefreshOutcome {
            let fetched = try await client.fetchMessages(since: since,
                                                         limit: effectiveLimit,
                                                         snippetLineLimit: snippetLineLimit)
            try await store.upsert(messages: fetched)
            let latest = fetched.map(\.date).max()
            return RefreshOutcome(fetchedCount: fetched.count, latestDate: latest)
        }

        func performRethread(cutoffDate: Date?) async throws -> RethreadOutcome {
            let messages = try await store.fetchMessages(since: cutoffDate)
            let baseResult = threader.buildThreads(from: messages)
            let manualGroups = try await store.fetchManualThreadGroups()
            let applied = threader.applyManualGroups(manualGroups, to: baseResult)
            let effectiveGroups = applied.updatedGroups.isEmpty ? manualGroups : applied.updatedGroups
            if !applied.updatedGroups.isEmpty {
                try await store.upsertManualThreadGroups(applied.updatedGroups)
            }
            let updatedResult = applied.result
            try await store.updateThreadMembership(updatedResult.messageThreadMap, threads: updatedResult.threads)
            let folders = try await store.fetchThreadFolders()
            let unread = updatedResult.threads.reduce(0) { $0 + $1.unreadCount }
            let groupsByID = Dictionary(uniqueKeysWithValues: effectiveGroups.map { ($0.id, $0) })
            return RethreadOutcome(roots: updatedResult.roots,
                                   unreadTotal: unread,
                                   messageCount: messages.count,
                                   threadCount: updatedResult.threads.count,
                                   manualGroupByMessageKey: updatedResult.manualGroupByMessageKey,
                                   manualAttachmentMessageIDs: updatedResult.manualAttachmentMessageIDs,
                                   manualGroups: groupsByID,
                                   jwzThreadMap: updatedResult.jwzThreadMap,
                                   folders: folders)
        }

        func performBackfill(ranges: [DateInterval],
                             limit: Int,
                             snippetLineLimit: Int) async throws -> Int {
            Log.refresh.info("Backfill requested. ranges=\(ranges, privacy: .public) limit=\(limit, privacy: .public) snippetLineLimit=\(snippetLineLimit, privacy: .public)")
            guard !ranges.isEmpty else { return 0 }
            var totalFetched = 0
            for range in ranges {
                let fetched = try await client.fetchMessages(in: range,
                                                             limit: limit,
                                                             snippetLineLimit: snippetLineLimit)
                totalFetched += fetched.count
                try await store.upsert(messages: fetched)
            }
            return totalFetched
        }

        func nodeSummaryInputs(for roots: [ThreadNode],
                               manualAttachmentMessageIDs: Set<String>,
                               snippetLineLimit: Int,
                               stopPhrases: [String]) -> [String: NodeSummaryInput] {
            let formatter = SnippetFormatter(lineLimit: snippetLineLimit,
                                             stopPhrases: stopPhrases)
            var inputs: [String: NodeSummaryInput] = [:]

            for root in roots {
                let timeline = Self.timelineNodes(for: root)
                var priorEntries: [EmailSummaryContextEntry] = []
                priorEntries.reserveCapacity(timeline.count)

                for node in timeline {
                    let subject = Self.normalizedText(node.message.subject,
                                                      maxCharacters: 140)
                    let body = Self.normalizedText(formatter.format(node.message.snippet),
                                                   maxCharacters: 600)
                    let priorContext = Array(priorEntries.suffix(8))
                    if !subject.isEmpty || !body.isEmpty {
                        let fingerprintEntries = priorContext.map {
                            NodeSummaryFingerprintEntry(messageID: $0.messageID,
                                                        subject: $0.subject,
                                                        bodySnippet: $0.bodySnippet)
                        }
                        let fingerprint = ThreadSummaryFingerprint.makeNode(subject: subject,
                                                                            body: body,
                                                                            priorEntries: fingerprintEntries)
                        inputs[node.id] = NodeSummaryInput(nodeID: node.id,
                                                           cacheKey: node.id,
                                                           subject: subject,
                                                           body: body,
                                                           priorMessages: priorContext,
                                                           fingerprint: fingerprint)
                    }

                    let priorSnippet = Self.normalizedText(formatter.format(node.message.snippet),
                                                           maxCharacters: 220)
                    if !subject.isEmpty || !priorSnippet.isEmpty {
                        priorEntries.append(EmailSummaryContextEntry(messageID: node.message.messageID,
                                                                     subject: subject,
                                                                     bodySnippet: priorSnippet))
                    } else if manualAttachmentMessageIDs.contains(node.id) {
                        priorEntries.append(EmailSummaryContextEntry(messageID: node.message.messageID,
                                                                     subject: "Manual attachment",
                                                                     bodySnippet: ""))
                    }
                }
            }

            return inputs
        }

        private static func timelineNodes(for root: ThreadNode) -> [ThreadNode] {
            let nodes = flatten(node: root)
            return nodes.sorted {
                if $0.message.date == $1.message.date {
                    return $0.message.messageID < $1.message.messageID
                }
                return $0.message.date < $1.message.date
            }
        }

        private static func flatten(node: ThreadNode) -> [ThreadNode] {
            var results: [ThreadNode] = [node]
            for child in node.children {
                results.append(contentsOf: flatten(node: child))
            }
            return results
        }

        private static func normalizedText(_ text: String, maxCharacters: Int) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            let collapsed = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard collapsed.count > maxCharacters else { return collapsed }
            let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxCharacters)
            return String(collapsed[..<endIndex]) + "…"
        }
    }

    @Published private(set) var roots: [ThreadNode] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var status: String = ""
    @Published private(set) var unreadTotal: Int = 0
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var nextRefreshDate: Date?
    @Published private(set) var nodeSummaries: [String: ThreadSummaryState] = [:]
    @Published private(set) var folderSummaries: [String: ThreadSummaryState] = [:]
    @Published private(set) var expandedSummaryIDs: Set<String> = []
    @Published var selectedNodeID: String?
    @Published var selectedFolderID: String?
    @Published private(set) var selectedNodeIDs: Set<String> = []
    @Published private(set) var manualGroupByMessageKey: [String: String] = [:]
    @Published private(set) var manualAttachmentMessageIDs: Set<String> = []
    @Published private(set) var manualGroups: [String: ManualThreadGroup] = [:]
    @Published private(set) var jwzThreadMap: [String: String] = [:]
    @Published private(set) var threadFolders: [ThreadFolder] = []
    @Published private var folderEditsByID: [String: ThreadFolderEdit] = [:]
    @Published private(set) var folderMembershipByThreadID: [String: String] = [:]
    @Published private(set) var openInMailState: OpenInMailState?
    @Published private(set) var dayWindowCount: Int = ThreadCanvasLayoutMetrics.defaultDayCount
    @Published private(set) var visibleDayRange: ClosedRange<Int>?
    @Published private(set) var visibleEmptyDayIntervals: [DateInterval] = []
    @Published private(set) var visibleRangeHasMessages = false
    @Published private(set) var isBackfilling = false
    @Published var fetchLimit: Int = 10 {
        didSet {
            if fetchLimit < 1 {
                fetchLimit = 1
            } else if fetchLimit != oldValue {
                shouldForceFullReload = true
            }
        }
    }

    private let store: MessageStore
    private let client: MailAppleScriptClient
    private let threader: JWZThreader
    private let summaryProvider: EmailSummaryProviding?
    private let summaryProviderID: String
    private let summaryAvailabilityMessage: String
    private let settings: AutoRefreshSettings
    private let inspectorSettings: InspectorViewSettings
    private let worker: SidebarBackgroundWorker
    private var rethreadTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var nodeSummaryTasks: [String: Task<Void, Never>] = [:]
    private var folderSummaryTasks: [String: Task<Void, Never>] = [:]
    private var nodeSummaryRefreshGeneration = 0
    private let folderSummaryDebounceInterval: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private var didStart = false
    private var openInMailAttemptID = UUID()
    private var shouldForceFullReload = false
    private let dayWindowIncrement = ThreadCanvasLayoutMetrics.defaultDayCount

    init(settings: AutoRefreshSettings,
         inspectorSettings: InspectorViewSettings,
         store: MessageStore = .shared,
         client: MailAppleScriptClient = MailAppleScriptClient(),
         threader: JWZThreader = JWZThreader(),
         summaryCapability: EmailSummaryCapability? = nil,
         folderSummaryDebounceInterval: TimeInterval = 30) {
        self.store = store
        self.client = client
        self.threader = threader
        self.settings = settings
        self.inspectorSettings = inspectorSettings
        self.folderSummaryDebounceInterval = folderSummaryDebounceInterval
        let capability = summaryCapability ?? EmailSummaryProviderFactory.makeCapability()
        self.summaryProvider = capability.provider
        self.summaryProviderID = capability.providerID
        self.summaryAvailabilityMessage = capability.statusMessage
        self.worker = SidebarBackgroundWorker(client: client,
                                              store: store,
                                              threader: threader)
        NotificationCenter.default.publisher(for: .manualThreadGroupsReset)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRethread()
            }
            .store(in: &cancellables)
    }

    deinit {
        rethreadTask?.cancel()
        autoRefreshTask?.cancel()
        nodeSummaryTasks.values.forEach { $0.cancel() }
        folderSummaryTasks.values.forEach { $0.cancel() }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Log.refresh.info("ThreadCanvasViewModel start invoked. didStart=false; kicking off initial load.")
        Task { await loadCachedMessages() }
        refreshNow()
        applyAutoRefreshSettings()
    }

    func refreshNow(limit: Int? = nil) {
        guard !isRefreshing else {
            Log.refresh.debug("Refresh skipped because another refresh is in progress.")
            return
        }
        let effectiveLimit = limit ?? fetchLimit
        isRefreshing = true
        status = NSLocalizedString("refresh.status.refreshing", comment: "Status when refresh begins")
        let useFullReload = shouldForceFullReload
        let since: Date?
        if useFullReload {
            Log.refresh.info("Forcing full reload due to fetchLimit change.")
            since = nil
        } else {
            since = store.lastSyncDate
        }
        let sinceDisplay = since?.ISO8601Format() ?? "nil"
        Log.refresh.info("Starting refresh. limit=\(effectiveLimit, privacy: .public) since=\(sinceDisplay, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            do {
                let snippetLineLimit = inspectorSettings.snippetLineLimit
                let outcome = try await worker.performRefresh(effectiveLimit: effectiveLimit,
                                                              since: since,
                                                              snippetLineLimit: snippetLineLimit)
                if let latest = outcome.latestDate {
                    store.lastSyncDate = latest
                    Log.refresh.debug("Updated lastSyncDate to \(latest.ISO8601Format(), privacy: .public)")
                }
                Log.refresh.info("AppleScript fetch succeeded. messageCount=\(outcome.fetchedCount, privacy: .public)")
                let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
                await MainActor.run {
                    if useFullReload {
                        self.shouldForceFullReload = false
                    }
                    self.scheduleRethread()
                    self.lastRefreshDate = Date()
                    self.status = String.localizedStringWithFormat(
                        NSLocalizedString("refresh.status.updated", comment: "Status after refresh completes"),
                        timestamp
                    )
                }
            } catch is CancellationError {
                Log.refresh.debug("Refresh cancelled before completion.")
            } catch {
                Log.refresh.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.status = String.localizedStringWithFormat(
                        NSLocalizedString("refresh.status.failed", comment: "Status when refresh fails"),
                        error.localizedDescription
                    )
                }
            }
            await MainActor.run { self.isRefreshing = false }
        }
    }

    func applyAutoRefreshSettings() {
        if settings.isEnabled {
            scheduleAutoRefresh(interval: settings.interval)
        } else {
            stopAutoRefresh()
        }
    }

    private func scheduleAutoRefresh(interval: TimeInterval) {
        let clampedInterval = min(max(interval, AutoRefreshSettings.minimumInterval), AutoRefreshSettings.maximumInterval)
        Log.refresh.info("Configuring auto refresh. interval=\(clampedInterval, privacy: .public)s")
        autoRefreshTask?.cancel()
        nextRefreshDate = Date().addingTimeInterval(clampedInterval)
        autoRefreshTask = Task { [weak self] in
            while let self {
                let nextDate = Date().addingTimeInterval(clampedInterval)
                await self.updateNextRefreshDate(nextDate)
                do {
                    try await Task.sleep(nanoseconds: UInt64(clampedInterval * 1_000_000_000))
                    try Task.checkCancellation()
                } catch is CancellationError {
                    Log.refresh.debug("Auto refresh cancelled before scheduling next run.")
                    break
                } catch {
                    Log.refresh.error("Auto refresh wait failed: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                await self.refreshNow()
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        nextRefreshDate = nil
    }

    private func loadCachedMessages() async {
        Log.refresh.debug("Loading cached messages to seed UI.")
        await performRethread()
    }

    private func scheduleRethread(delay: TimeInterval = 0.25) {
        Log.refresh.debug("Scheduling rethread in \(delay, privacy: .public)s")
        rethreadTask?.cancel()
        rethreadTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self.performRethread()
        }
    }

    private func performRethread() async {
        do {
            Log.refresh.debug("Beginning rethread from store.")
            let previousNodeIDs = Set(Self.flatten(nodes: self.roots).map(\.id))
            let previousFolderIDs = Set(self.threadFolders.map(\.id))
            let cutoffDate = cachedMessageCutoffDate()
            let rethreadResult = try await worker.performRethread(cutoffDate: cutoffDate)
            self.roots = rethreadResult.roots
            self.unreadTotal = rethreadResult.unreadTotal
            self.manualGroupByMessageKey = rethreadResult.manualGroupByMessageKey
            self.manualAttachmentMessageIDs = rethreadResult.manualAttachmentMessageIDs
            self.manualGroups = rethreadResult.manualGroups
            self.jwzThreadMap = rethreadResult.jwzThreadMap
            self.threadFolders = rethreadResult.folders
            self.folderMembershipByThreadID = Self.folderMembershipMap(for: rethreadResult.folders)
            self.folderEditsByID = [:]
            pruneSelection(using: rethreadResult.roots)
            pruneFolderSelection(using: rethreadResult.folders)
            refreshNodeSummaries(for: rethreadResult.roots)
            refreshFolderSummaries(for: rethreadResult.roots, folders: rethreadResult.folders)
            let currentNodeIDs = Set(Self.flatten(nodes: rethreadResult.roots).map(\.id))
            let removedNodeIDs = previousNodeIDs.subtracting(currentNodeIDs)
            let removedFolderIDs = previousFolderIDs.subtracting(rethreadResult.folders.map(\.id))
            if !removedNodeIDs.isEmpty || !removedFolderIDs.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        if !removedNodeIDs.isEmpty {
                            try await store.deleteSummaries(scope: .emailNode, ids: Array(removedNodeIDs))
                        }
                        if !removedFolderIDs.isEmpty {
                            try await store.deleteSummaries(scope: .folder, ids: Array(removedFolderIDs))
                        }
                    } catch {
                        Log.app.error("Failed to delete stale summary caches: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            Log.refresh.info("Rethread complete. messages=\(rethreadResult.messageCount, privacy: .public) threads=\(rethreadResult.threadCount, privacy: .public) unreadTotal=\(self.unreadTotal, privacy: .public)")
        } catch {
            Log.refresh.error("Rethread failed: \(error.localizedDescription, privacy: .public)")
            status = String.localizedStringWithFormat(
                NSLocalizedString("refresh.status.threading_failed", comment: "Status when threading fails"),
                error.localizedDescription
            )
        }
    }

    func summaryState(for nodeID: String) -> ThreadSummaryState? {
        nodeSummaries[nodeID]
    }

    func folderSummaryState(for folderID: String) -> ThreadSummaryState? {
        folderSummaries[folderID]
    }

    func rootID(containing nodeID: String) -> String? {
        Self.rootID(for: nodeID, in: roots)
    }

    private func refreshNodeSummaries(for roots: [ThreadNode]) {
        let rootsSnapshot = roots
        let manualAttachmentSnapshot = manualAttachmentMessageIDs
        let snippetLineLimit = inspectorSettings.snippetLineLimit
        let stopPhrases = inspectorSettings.stopPhrases
        let provider = summaryProvider
        let providerStatusMessage = summaryAvailabilityMessage
        nodeSummaryRefreshGeneration += 1
        let generation = nodeSummaryRefreshGeneration
        Task { [weak self] in
            guard let self else { return }
            let inputsByNodeID = await worker.nodeSummaryInputs(for: rootsSnapshot,
                                                                manualAttachmentMessageIDs: manualAttachmentSnapshot,
                                                                snippetLineLimit: snippetLineLimit,
                                                                stopPhrases: stopPhrases)
            let cacheKeys = inputsByNodeID.values.map(\.cacheKey)
            var cachedByKey: [String: SummaryCacheEntry] = [:]
            if !cacheKeys.isEmpty {
                do {
                    let cached = try await store.fetchSummaries(scope: .emailNode, ids: cacheKeys)
                    cachedByKey = Dictionary(uniqueKeysWithValues: cached.map { ($0.scopeID, $0) })
                } catch {
                    Log.app.error("Failed to load cached summaries: \(error.localizedDescription, privacy: .public)")
                }
            }
            await MainActor.run {
                guard self.nodeSummaryRefreshGeneration == generation else { return }
                self.prepareNodeSummaries(for: rootsSnapshot,
                                          inputsByNodeID: inputsByNodeID,
                                          cachedByKey: cachedByKey,
                                          summaryProvider: provider,
                                          providerStatusMessage: providerStatusMessage)
            }
        }
    }

    @MainActor
    private func prepareNodeSummaries(for roots: [ThreadNode],
                                      inputsByNodeID: [String: NodeSummaryInput],
                                      cachedByKey: [String: SummaryCacheEntry],
                                      summaryProvider: EmailSummaryProviding?,
                                      providerStatusMessage: String) {
        let validNodeIDs = Set(inputsByNodeID.keys)
        for (id, task) in nodeSummaryTasks where !validNodeIDs.contains(id) {
            task.cancel()
            nodeSummaryTasks.removeValue(forKey: id)
            nodeSummaries.removeValue(forKey: id)
            expandedSummaryIDs.remove(id)
        }

        for input in inputsByNodeID.values {
            guard !input.subject.isEmpty || !input.body.isEmpty else {
                nodeSummaries.removeValue(forKey: input.nodeID)
                nodeSummaryTasks[input.nodeID]?.cancel()
                nodeSummaryTasks.removeValue(forKey: input.nodeID)
                expandedSummaryIDs.remove(input.nodeID)
                continue
            }

            let cachedEntry = cachedByKey[input.cacheKey]
            let hasFreshCache = cachedEntry?.fingerprint == input.fingerprint
            let isProviderAvailable = summaryProvider != nil

            if let cachedEntry, hasFreshCache {
                nodeSummaryTasks[input.nodeID]?.cancel()
                nodeSummaryTasks.removeValue(forKey: input.nodeID)
                nodeSummaries[input.nodeID] = ThreadSummaryState(text: cachedEntry.summaryText,
                                                                 statusMessage: cachedStatusMessage(for: cachedEntry,
                                                                                                    prefix: "Cached"),
                                                                 isSummarizing: false)
                continue
            }

            if !isProviderAvailable {
                nodeSummaryTasks[input.nodeID]?.cancel()
                nodeSummaryTasks.removeValue(forKey: input.nodeID)
                if let cachedEntry {
                    nodeSummaries[input.nodeID] = ThreadSummaryState(text: cachedEntry.summaryText,
                                                                     statusMessage: cachedStatusMessage(for: cachedEntry,
                                                                                                        prefix: "Last updated",
                                                                                                        suffix: providerStatusMessage),
                                                                     isSummarizing: false)
                } else {
                    nodeSummaries.removeValue(forKey: input.nodeID)
                }
                continue
            }

            let placeholderText = cachedEntry?.summaryText ?? nodeSummaries[input.nodeID]?.text ?? ""
            nodeSummaries[input.nodeID] = ThreadSummaryState(text: placeholderText,
                                                             statusMessage: "Summarizing…",
                                                             isSummarizing: true)

            nodeSummaryTasks[input.nodeID]?.cancel()
            nodeSummaryTasks[input.nodeID] = Task { [weak self] in
                guard let self else { return }
                do {
                    guard let summaryProvider else { return }
                    let request = EmailSummaryRequest(subject: input.subject,
                                                      body: input.body,
                                                      priorMessages: input.priorMessages)
                    let text = try await summaryProvider.summarizeEmail(request)
                    let generatedAt = Date()
                    let entry = SummaryCacheEntry(scope: .emailNode,
                                                  scopeID: input.cacheKey,
                                                  summaryText: text,
                                                  generatedAt: generatedAt,
                                                  fingerprint: input.fingerprint,
                                                  provider: summaryProviderID)
                    do {
                        try await store.upsertSummaries([entry])
                    } catch {
                        Log.app.error("Failed to persist summary cache: \(error.localizedDescription, privacy: .public)")
                    }
                    let timestamp = DateFormatter.localizedString(from: Date(),
                                                                  dateStyle: .none,
                                                                  timeStyle: .short)
                    await MainActor.run {
                        self.updateSummary(for: input.nodeID,
                                           text: text,
                                           status: "Updated \(timestamp)",
                                           isSummarizing: false,
                                           in: \.nodeSummaries)
                        self.refreshFolderSummaries(for: self.roots, folders: self.threadFolders)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.finishSummary(for: input.nodeID, in: \.nodeSummaries)
                    }
                } catch {
                    await MainActor.run {
                        if let cachedEntry {
                            self.updateSummary(for: input.nodeID,
                                               text: cachedEntry.summaryText,
                                               status: self.cachedStatusMessage(for: cachedEntry,
                                                                                prefix: "Last updated",
                                                                                suffix: error.localizedDescription),
                                               isSummarizing: false,
                                               in: \.nodeSummaries)
                        } else {
                            self.updateSummary(for: input.nodeID,
                                               text: "",
                                               status: error.localizedDescription,
                                               isSummarizing: false,
                                               in: \.nodeSummaries)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func updateSummary(for id: String,
                               text: String,
                               status: String,
                               isSummarizing: Bool,
                               in summaries: ReferenceWritableKeyPath<ThreadCanvasViewModel, [String: ThreadSummaryState]>) {
        self[keyPath: summaries][id] = ThreadSummaryState(text: text,
                                                          statusMessage: status,
                                                          isSummarizing: isSummarizing)
    }

    @MainActor
    private func finishSummary(for id: String,
                               in summaries: ReferenceWritableKeyPath<ThreadCanvasViewModel, [String: ThreadSummaryState]>) {
        guard var state = self[keyPath: summaries][id] else { return }
        state.isSummarizing = false
        self[keyPath: summaries][id] = state
    }

    private func cachedStatusMessage(for entry: SummaryCacheEntry,
                                     prefix: String,
                                     suffix: String? = nil) -> String {
        let timestamp = DateFormatter.localizedString(from: entry.generatedAt,
                                                      dateStyle: .none,
                                                      timeStyle: .short)
        var message = "\(prefix) \(timestamp)"
        if let suffix, !suffix.isEmpty {
            message += "; \(suffix)"
        }
        return message
    }

    private func refreshFolderSummaries(for roots: [ThreadNode],
                                        folders: [ThreadFolder]) {
        let rootsSnapshot = roots
        let foldersSnapshot = folders
        let manualGroupSnapshot = manualGroupByMessageKey
        let jwzThreadSnapshot = jwzThreadMap
        let provider = summaryProvider
        let providerStatusMessage = summaryAvailabilityMessage
        let debounceInterval = folderSummaryDebounceInterval

        Task { [weak self] in
            guard let self else { return }
            let folderNodes = Self.folderNodesByID(roots: rootsSnapshot,
                                                   folders: foldersSnapshot,
                                                   manualGroupByMessageKey: manualGroupSnapshot,
                                                   jwzThreadMap: jwzThreadSnapshot)
            let allNodeIDs = Set(folderNodes.values.flatMap { $0.map(\.id) })
            var cachedNodeByID: [String: SummaryCacheEntry] = [:]
            if !allNodeIDs.isEmpty {
                do {
                    let cachedNodes = try await store.fetchSummaries(scope: .emailNode, ids: Array(allNodeIDs))
                    cachedNodeByID = Dictionary(uniqueKeysWithValues: cachedNodes.map { ($0.scopeID, $0) })
                } catch {
                    Log.app.error("Failed to load cached node summaries: \(error.localizedDescription, privacy: .public)")
                }
            }

            let folderIDs = foldersSnapshot.map(\.id)
            var cachedFolderByID: [String: SummaryCacheEntry] = [:]
            if !folderIDs.isEmpty {
                do {
                    let cachedFolders = try await store.fetchSummaries(scope: .folder, ids: folderIDs)
                    cachedFolderByID = Dictionary(uniqueKeysWithValues: cachedFolders.map { ($0.scopeID, $0) })
                } catch {
                    Log.app.error("Failed to load cached folder summaries: \(error.localizedDescription, privacy: .public)")
                }
            }

            let inputsByFolderID = Self.folderSummaryInputs(for: foldersSnapshot,
                                                            folderNodes: folderNodes,
                                                            cachedNodeSummaries: cachedNodeByID)
            await MainActor.run {
                self.prepareFolderSummaries(for: foldersSnapshot,
                                            inputsByFolderID: inputsByFolderID,
                                            cachedByKey: cachedFolderByID,
                                            summaryProvider: provider,
                                            providerStatusMessage: providerStatusMessage,
                                            debounceInterval: debounceInterval)
            }
        }
    }

    @MainActor
    private func prepareFolderSummaries(for folders: [ThreadFolder],
                                        inputsByFolderID: [String: FolderSummaryInput],
                                        cachedByKey: [String: SummaryCacheEntry],
                                        summaryProvider: EmailSummaryProviding?,
                                        providerStatusMessage: String,
                                        debounceInterval: TimeInterval) {
        let validFolderIDs = Set(inputsByFolderID.keys)
        for (id, task) in folderSummaryTasks where !validFolderIDs.contains(id) {
            task.cancel()
            folderSummaryTasks.removeValue(forKey: id)
            folderSummaries.removeValue(forKey: id)
        }

        for folder in folders {
            guard let input = inputsByFolderID[folder.id] else {
                folderSummaryTasks[folder.id]?.cancel()
                folderSummaryTasks.removeValue(forKey: folder.id)
                folderSummaries.removeValue(forKey: folder.id)
                continue
            }

            let cachedEntry = cachedByKey[input.folderID]
            let hasFreshCache = cachedEntry?.fingerprint == input.fingerprint
            let isProviderAvailable = summaryProvider != nil

            if input.summaryTexts.isEmpty {
                folderSummaryTasks[input.folderID]?.cancel()
                folderSummaryTasks.removeValue(forKey: input.folderID)
                if let cachedEntry {
                    folderSummaries[input.folderID] = ThreadSummaryState(text: cachedEntry.summaryText,
                                                                         statusMessage: cachedStatusMessage(for: cachedEntry,
                                                                                                            prefix: "Last updated",
                                                                                                            suffix: "Waiting for email summaries"),
                                                                         isSummarizing: false)
                } else {
                    folderSummaries.removeValue(forKey: input.folderID)
                }
                continue
            }

            if let cachedEntry, hasFreshCache {
                folderSummaryTasks[input.folderID]?.cancel()
                folderSummaryTasks.removeValue(forKey: input.folderID)
                folderSummaries[input.folderID] = ThreadSummaryState(text: cachedEntry.summaryText,
                                                                     statusMessage: cachedStatusMessage(for: cachedEntry,
                                                                                                        prefix: "Cached"),
                                                                     isSummarizing: false)
                continue
            }

            if !isProviderAvailable {
                folderSummaryTasks[input.folderID]?.cancel()
                folderSummaryTasks.removeValue(forKey: input.folderID)
                if let cachedEntry {
                    folderSummaries[input.folderID] = ThreadSummaryState(text: cachedEntry.summaryText,
                                                                         statusMessage: cachedStatusMessage(for: cachedEntry,
                                                                                                            prefix: "Last updated",
                                                                                                            suffix: providerStatusMessage),
                                                                         isSummarizing: false)
                } else {
                    folderSummaries.removeValue(forKey: input.folderID)
                }
                continue
            }

            let placeholderText = cachedEntry?.summaryText ?? folderSummaries[input.folderID]?.text ?? ""
            folderSummaries[input.folderID] = ThreadSummaryState(text: placeholderText,
                                                                 statusMessage: "Summarizing…",
                                                                 isSummarizing: true)

            folderSummaryTasks[input.folderID]?.cancel()
            folderSummaryTasks[input.folderID] = Task { [weak self] in
                guard let self else { return }
                do {
                    if debounceInterval > 0 {
                        try await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
                        try Task.checkCancellation()
                    }
                    guard let summaryProvider else { return }
                    let request = FolderSummaryRequest(title: input.title,
                                                       messageSummaries: input.summaryTexts)
                    let text = try await summaryProvider.summarizeFolder(request)
                    let generatedAt = Date()
                    let entry = SummaryCacheEntry(scope: .folder,
                                                  scopeID: input.folderID,
                                                  summaryText: text,
                                                  generatedAt: generatedAt,
                                                  fingerprint: input.fingerprint,
                                                  provider: summaryProviderID)
                    do {
                        try await store.upsertSummaries([entry])
                    } catch {
                        Log.app.error("Failed to persist folder summary cache: \(error.localizedDescription, privacy: .public)")
                    }
                    let timestamp = DateFormatter.localizedString(from: Date(),
                                                                  dateStyle: .none,
                                                                  timeStyle: .short)
                    await MainActor.run {
                        self.updateSummary(for: input.folderID,
                                           text: text,
                                           status: "Updated \(timestamp)",
                                           isSummarizing: false,
                                           in: \.folderSummaries)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.finishSummary(for: input.folderID, in: \.folderSummaries)
                    }
                } catch {
                    await MainActor.run {
                        if let cachedEntry {
                            self.updateSummary(for: input.folderID,
                                               text: cachedEntry.summaryText,
                                               status: self.cachedStatusMessage(for: cachedEntry,
                                                                                prefix: "Last updated",
                                                                                suffix: error.localizedDescription),
                                               isSummarizing: false,
                                               in: \.folderSummaries)
                        } else {
                            self.updateSummary(for: input.folderID,
                                               text: "",
                                               status: error.localizedDescription,
                                               isSummarizing: false,
                                               in: \.folderSummaries)
                        }
                    }
                }
            }
        }
    }

    private static func folderSummaryInputs(for folders: [ThreadFolder],
                                            folderNodes: [String: [ThreadNode]],
                                            cachedNodeSummaries: [String: SummaryCacheEntry]) -> [String: FolderSummaryInput] {
        var inputs: [String: FolderSummaryInput] = [:]
        inputs.reserveCapacity(folders.count)

        for folder in folders {
            let nodes = folderNodes[folder.id] ?? []
            let sortedNodes = nodes.sorted { $0.message.date > $1.message.date }
            let summaryTexts = sortedNodes.compactMap { node in
                cachedNodeSummaries[node.id]?.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            let fingerprintEntries = sortedNodes.map { node in
                FolderSummaryFingerprintEntry(nodeID: node.id,
                                              nodeFingerprint: cachedNodeSummaries[node.id]?.fingerprint ?? "missing")
            }
            let fingerprint = ThreadSummaryFingerprint.makeFolder(nodeEntries: fingerprintEntries)
            inputs[folder.id] = FolderSummaryInput(folderID: folder.id,
                                                   title: folder.title,
                                                   summaryTexts: Array(summaryTexts.prefix(20)),
                                                   fingerprint: fingerprint)
        }
        return inputs
    }

    private static func folderNodesByID(roots: [ThreadNode],
                                        folders: [ThreadFolder],
                                        manualGroupByMessageKey: [String: String],
                                        jwzThreadMap: [String: String]) -> [String: [ThreadNode]] {
        let rootsByThreadID = Dictionary(uniqueKeysWithValues: roots.compactMap { root -> (String, ThreadNode)? in
            guard let effectiveID = effectiveThreadID(for: root,
                                                      manualGroupByMessageKey: manualGroupByMessageKey,
                                                      jwzThreadMap: jwzThreadMap) else { return nil }
            return (effectiveID, root)
        })
        let threadIDsByFolder = folderThreadIDsByFolder(folders: folders)
        var results: [String: [ThreadNode]] = [:]
        results.reserveCapacity(folders.count)

        for (folderID, threadIDs) in threadIDsByFolder {
            var nodes: [ThreadNode] = []
            for threadID in threadIDs {
                if let root = rootsByThreadID[threadID] {
                    nodes.append(contentsOf: flatten(node: root))
                }
            }
            results[folderID] = nodes
        }
        return results
    }

    private static func folderThreadIDsByFolder(folders: [ThreadFolder]) -> [String: Set<String>] {
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let childrenByParent = childFolderIDsByParent(folders: folders)

        func collectThreadIDs(for folderID: String) -> Set<String> {
            var ids = foldersByID[folderID]?.threadIDs ?? []
            for childID in childrenByParent[folderID] ?? [] {
                ids.formUnion(collectThreadIDs(for: childID))
            }
            return ids
        }

        var results: [String: Set<String>] = [:]
        results.reserveCapacity(folders.count)
        for folder in folders {
            results[folder.id] = collectThreadIDs(for: folder.id)
        }
        return results
    }

    private static func effectiveThreadID(for node: ThreadNode,
                                          manualGroupByMessageKey: [String: String],
                                          jwzThreadMap: [String: String]) -> String? {
        let messageKey = node.message.threadKey
        if let manualGroupID = manualGroupByMessageKey[messageKey] {
            return manualGroupID
        }
        if let jwzID = jwzThreadMap[messageKey] {
            return jwzID
        }
        if let threadID = node.message.threadID {
            return threadID
        }
        return node.id
    }

    func isSummaryExpanded(for id: String) -> Bool {
        expandedSummaryIDs.contains(id)
    }

    func setSummaryExpanded(_ expanded: Bool, for id: String) {
        if expanded {
            expandedSummaryIDs.insert(id)
        } else {
            expandedSummaryIDs.remove(id)
        }
    }

#if DEBUG
    func applyRethreadResultForTesting(roots: [ThreadNode],
                                       manualGroupByMessageKey: [String: String] = [:],
                                       manualAttachmentMessageIDs: Set<String> = [],
                                       jwzThreadMap: [String: String] = [:],
                                       folders: [ThreadFolder] = []) {
        self.roots = roots
        self.manualGroupByMessageKey = manualGroupByMessageKey
        self.manualAttachmentMessageIDs = manualAttachmentMessageIDs
        self.jwzThreadMap = jwzThreadMap
        self.threadFolders = folders
        self.folderMembershipByThreadID = Self.folderMembershipMap(for: folders)
        refreshNodeSummaries(for: roots)
        refreshFolderSummaries(for: roots, folders: folders)
    }
#endif

    func selectNode(id: String?) {
        selectNode(id: id, additive: false)
    }

    func selectNode(id: String?, additive: Bool) {
        guard let id else {
            selectedNodeID = nil
            selectedNodeIDs = []
            return
        }

        if let selectedFolderID {
            clearFolderEdits(id: selectedFolderID)
            self.selectedFolderID = nil
        }

        if additive {
            if selectedNodeIDs.contains(id) {
                selectedNodeIDs.remove(id)
                if selectedNodeID == id {
                    selectedNodeID = selectedNodeIDs.sorted().first
                }
            } else {
                selectedNodeIDs.insert(id)
                selectedNodeID = id
            }
        } else {
            selectedNodeID = id
            selectedNodeIDs = [id]
        }
    }

    func selectFolder(id: String?) {
        if let selectedFolderID, selectedFolderID != id {
            clearFolderEdits(id: selectedFolderID)
        }
        if id != nil {
            selectedNodeID = nil
            selectedNodeIDs = []
        }
        selectedFolderID = id
    }

    func previewFolderEdits(id: String, title: String, color: ThreadFolderColor) {
        folderEditsByID[id] = ThreadFolderEdit(title: title, color: color)
    }

    func clearFolderEdits(id: String) {
        folderEditsByID.removeValue(forKey: id)
    }

    func saveFolderEdits(id: String, title: String, color: ThreadFolderColor) {
        guard let index = threadFolders.firstIndex(where: { $0.id == id }) else { return }
        var updated = threadFolders
        updated[index].title = title
        updated[index].color = color

        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.upsertThreadFolders(updated)
                await MainActor.run {
                    self.threadFolders = updated
                    self.clearFolderEdits(id: id)
                    self.refreshFolderSummaries(for: self.roots, folders: updated)
                }
            } catch {
                Log.app.error("Failed to save thread folder edits: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func openMessageInMail(_ node: ThreadNode) {
        let messageID = node.message.messageID
        let attemptID = UUID()
        openInMailAttemptID = attemptID
        setOpenInMailState(.opening, messageID: messageID, attemptID: attemptID)
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try MailControl.openMessage(messageID: messageID)
                Log.appleScript.info("Open in Mail succeeded. messageID=\(messageID, privacy: .public)")
                await MainActor.run {
                    self.setOpenInMailState(.opened, messageID: messageID, attemptID: attemptID)
                }
            } catch {
                Log.appleScript.error("Open in Mail failed. messageID=\(messageID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.setOpenInMailState(.searching, messageID: messageID, attemptID: attemptID)
                }
                do {
                    let matches = try MailControl.searchMessages(messageID: messageID, limit: 5)
                    Log.appleScript.info("Open in Mail fallback search finished. messageID=\(messageID, privacy: .public) matches=\(matches.count, privacy: .public)")
                    let mapped = matches.map {
                        OpenInMailMatch(messageID: $0.messageID,
                                        subject: $0.subject,
                                        mailbox: $0.mailbox,
                                        account: $0.account,
                                        date: $0.date)
                    }
                    await MainActor.run {
                        let status: OpenInMailStatus = mapped.isEmpty ? .notFound : .matches(mapped)
                        self.setOpenInMailState(status, messageID: messageID, attemptID: attemptID)
                    }
                } catch {
                    Log.appleScript.error("Open in Mail fallback search failed. messageID=\(messageID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    await MainActor.run {
                        self.setOpenInMailState(.failed(error.localizedDescription),
                                                messageID: messageID,
                                                attemptID: attemptID)
                    }
                }
            }
        }
    }

    func openMatchedMessage(_ match: OpenInMailMatch) {
        let attemptID = UUID()
        openInMailAttemptID = attemptID
        setOpenInMailState(.opening, messageID: match.messageID, attemptID: attemptID)
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let opened = try MailControl.openMessageViaAppleScript(messageID: match.messageID)
                let status: OpenInMailStatus = opened ? .opened : .notFound
                Log.appleScript.info("Open in Mail fallback open result. messageID=\(match.messageID, privacy: .public) opened=\(opened, privacy: .public)")
                await MainActor.run {
                    self.setOpenInMailState(status, messageID: match.messageID, attemptID: attemptID)
                }
            } catch {
                Log.appleScript.error("Open in Mail fallback open failed. messageID=\(match.messageID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.setOpenInMailState(.failed(error.localizedDescription),
                                            messageID: match.messageID,
                                            attemptID: attemptID)
                }
            }
        }
    }

    func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    func copyOpenInMailURL(messageID: String) {
        do {
            let url = try MailControl.messageURL(for: messageID)
            copyToPasteboard(url.absoluteString)
            Log.appleScript.debug("Copied message URL to pasteboard. messageID=\(messageID, privacy: .public)")
        } catch {
            Log.appleScript.error("Failed to build message URL for copy. messageID=\(messageID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func setOpenInMailState(_ status: OpenInMailStatus,
                                    messageID: String,
                                    attemptID: UUID) {
        guard openInMailAttemptID == attemptID else { return }
        openInMailState = OpenInMailState(messageID: messageID, status: status)
    }

    func moveThread(threadID: String, toFolderID folderID: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let updated = Self.applyMove(threadID: threadID,
                                               toFolderID: folderID,
                                               folders: threadFolders) else { return }
            do {
                try await store.upsertThreadFolders(updated.folders)
                if !updated.deletedFolderIDs.isEmpty {
                    try await store.deleteThreadFolders(ids: Array(updated.deletedFolderIDs))
                }
                await MainActor.run {
                    self.threadFolders = updated.folders
                    self.folderMembershipByThreadID = updated.membership
                    self.refreshFolderSummaries(for: self.roots, folders: updated.folders)
                }
            } catch {
                Log.app.error("Failed to move thread into folder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func removeThreadFromFolder(threadID: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let updated = Self.applyRemoval(threadID: threadID, folders: threadFolders) else { return }
            do {
                try await store.upsertThreadFolders(updated.remainingFolders)
                if !updated.deletedFolderIDs.isEmpty {
                    try await store.deleteThreadFolders(ids: Array(updated.deletedFolderIDs))
                }
                await MainActor.run {
                    self.threadFolders = updated.remainingFolders
                    self.folderMembershipByThreadID = updated.membership
                    self.refreshFolderSummaries(for: self.roots, folders: updated.remainingFolders)
                }
            } catch {
                Log.app.error("Failed to remove thread from folder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    var selectedNode: ThreadNode? {
        Self.node(matching: selectedNodeID, in: roots)
    }

    var selectedFolder: ThreadFolder? {
        threadFolders.first { $0.id == selectedFolderID }
    }

    func canvasLayout(metrics: ThreadCanvasLayoutMetrics,
                      today: Date = Date(),
                      calendar: Calendar = .current) -> ThreadCanvasLayout {
        Self.canvasLayout(for: roots,
                          metrics: metrics,
                          today: today,
                          calendar: calendar,
                          manualAttachmentMessageIDs: manualAttachmentMessageIDs,
                          jwzThreadMap: jwzThreadMap,
                          folders: effectiveThreadFolders,
                          folderMembershipByThreadID: folderMembershipByThreadID)
    }

    var canBackfillVisibleRange: Bool {
        !visibleEmptyDayIntervals.isEmpty && !isBackfilling
    }

    func updateVisibleDayRange(scrollOffset: CGFloat,
                               viewportHeight: CGFloat,
                               layout: ThreadCanvasLayout,
                               metrics: ThreadCanvasLayoutMetrics,
                               today: Date = Date(),
                               calendar: Calendar = .current) {
        guard viewportHeight > 0 else { return }
        let range = Self.visibleDayRange(for: layout,
                                         scrollOffset: scrollOffset,
                                         viewportHeight: viewportHeight)
        if visibleDayRange != range {
            visibleDayRange = range
        }
        let emptyIntervals = Self.emptyDayIntervals(for: layout,
                                                    visibleRange: range,
                                                    today: today,
                                                    calendar: calendar)
        if visibleEmptyDayIntervals != emptyIntervals {
            visibleEmptyDayIntervals = emptyIntervals
        }
        let populatedDays = Set(layout.columns.flatMap { $0.nodes.map(\.dayIndex) })
        let hasMessages = range.map { range in
            range.contains { populatedDays.contains($0) }
        } ?? false
        if visibleRangeHasMessages != hasMessages {
            visibleRangeHasMessages = hasMessages
        }
        let nearBottom = Self.shouldExpandDayWindow(scrollOffset: scrollOffset,
                                                    viewportHeight: viewportHeight,
                                                    contentHeight: layout.contentSize.height,
                                                    threshold: metrics.dayHeight * 2)
        expandDayWindowIfNeeded(visibleRange: range, forceIncrement: nearBottom)
    }

    func backfillVisibleRange(rangeOverride: DateInterval? = nil, limitOverride: Int? = nil) {
        guard !isBackfilling else { return }
        let ranges = rangeOverride.map { [$0] } ?? visibleEmptyDayIntervals
        guard !ranges.isEmpty else { return }
        isBackfilling = true
        status = NSLocalizedString("threadlist.backfill.status.fetching", comment: "Status when backfill begins")
        let limit = limitOverride ?? fetchLimit
        let snippetLineLimit = inspectorSettings.snippetLineLimit
        Task { [weak self] in
            guard let self else { return }
            do {
                let fetchedCount = try await worker.performBackfill(ranges: ranges,
                                                                    limit: limit,
                                                                    snippetLineLimit: snippetLineLimit)
                await MainActor.run {
                    self.isBackfilling = false
                    self.status = String.localizedStringWithFormat(
                        NSLocalizedString("threadlist.backfill.status.complete",
                                          comment: "Status after backfill completes"),
                        fetchedCount
                    )
                    if fetchedCount > 0 {
                        self.scheduleRethread()
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isBackfilling = false
                }
            } catch {
                await MainActor.run {
                    self.isBackfilling = false
                    self.status = String.localizedStringWithFormat(
                        NSLocalizedString("threadlist.backfill.status.failed",
                                          comment: "Status when backfill fails"),
                        error.localizedDescription
                    )
                }
            }
        }
    }

    var shouldShowSelectionActions: Bool {
        selectedNodeIDs.count >= 1 || hasManualGroupMembershipInSelection
    }

    var canGroupSelection: Bool {
        guard selectedNodeIDs.count >= 2,
              let targetID = selectedNodeID,
              let targetNode = Self.node(matching: targetID, in: roots) else {
            return false
        }
        let targetKey = targetNode.message.threadKey
        let targetMembershipID = manualGroupByMessageKey[targetKey]
            ?? jwzThreadMap[targetKey]
            ?? targetNode.message.threadID
            ?? targetNode.id
        return selectedNodes(in: roots).contains {
            let messageKey = $0.message.threadKey
            let membershipID = manualGroupByMessageKey[messageKey]
                ?? jwzThreadMap[messageKey]
                ?? $0.message.threadID
                ?? $0.id
            return membershipID != targetMembershipID
        }
    }

    var canUngroupSelection: Bool {
        hasManualGroupMembershipInSelection
    }

    func groupSelectedMessages() {
        let selectedNodes = selectedNodes(in: roots)
        guard selectedNodes.count >= 2 else {
            return
        }

        let selectionDetails = selectedNodes.map { node -> (messageKey: String, jwzThreadID: String, manualGroupID: String?, isJWZThreaded: Bool) in
            let messageKey = node.message.threadKey
            let jwzThreadID = jwzThreadMap[messageKey] ?? node.message.threadID ?? node.id
            let isJWZThreaded = jwzThreadMap[messageKey] != nil
            return (messageKey, jwzThreadID, manualGroupByMessageKey[messageKey], isJWZThreaded)
        }

        let manualGroupIDs = Set(selectionDetails.compactMap(\.manualGroupID))

        guard let targetID = selectedNodeID,
              let targetNode = Self.node(matching: targetID, in: roots) else { return }
        let targetKey = targetNode.message.threadKey
        let targetJWZID = jwzThreadMap[targetKey] ?? targetNode.message.threadID ?? targetNode.id

        var jwzThreadCounts: [String: Int] = [:]
        for detail in selectionDetails {
            jwzThreadCounts[detail.jwzThreadID, default: 0] += 1
        }
        var jwzThreadIDs: Set<String> = []
        for detail in selectionDetails where detail.manualGroupID == nil {
            let count = jwzThreadCounts[detail.jwzThreadID] ?? 0
            if detail.isJWZThreaded || detail.jwzThreadID == targetJWZID || count > 1 {
                jwzThreadIDs.insert(detail.jwzThreadID)
            }
        }

        let manualAttachmentKeys = selectionDetails
            .filter { detail in
                !detail.isJWZThreaded &&
                    detail.jwzThreadID != targetJWZID &&
                    (jwzThreadCounts[detail.jwzThreadID] ?? 0) == 1
            }
            .map(\.messageKey)

        if manualGroupIDs.isEmpty {
            guard jwzThreadIDs.count >= 2 || (!manualAttachmentKeys.isEmpty && !jwzThreadIDs.isEmpty) else { return }
            let newGroup = ManualThreadGroup(id: Self.newManualGroupID(),
                                             jwzThreadIDs: jwzThreadIDs,
                                             manualMessageKeys: Set(manualAttachmentKeys))
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await store.upsertManualThreadGroups([newGroup])
                    await MainActor.run { self.scheduleRethread() }
                } catch {
                    Log.app.error("Failed to save manual thread group: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        if manualGroupIDs.count == 1, (!jwzThreadIDs.isEmpty || !manualAttachmentKeys.isEmpty) {
            guard let groupID = manualGroupIDs.first,
                  var group = manualGroups[groupID] else { return }
            group.jwzThreadIDs.formUnion(jwzThreadIDs)
            group.manualMessageKeys.formUnion(manualAttachmentKeys)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await store.upsertManualThreadGroups([group])
                    await MainActor.run { self.scheduleRethread() }
                } catch {
                    Log.app.error("Failed to update manual thread group: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        guard manualGroupIDs.count >= 2 else { return }
        var mergedJWZIDs: Set<String> = []
        var mergedManualKeys: Set<String> = []
        for groupID in manualGroupIDs {
            guard let group = manualGroups[groupID] else { continue }
            mergedJWZIDs.formUnion(group.jwzThreadIDs)
            mergedManualKeys.formUnion(group.manualMessageKeys)
        }
        mergedJWZIDs.formUnion(jwzThreadIDs)
        mergedManualKeys.formUnion(manualAttachmentKeys)
        let mergedGroup = ManualThreadGroup(id: Self.newManualGroupID(),
                                            jwzThreadIDs: mergedJWZIDs,
                                            manualMessageKeys: mergedManualKeys)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.upsertManualThreadGroups([mergedGroup])
                for groupID in manualGroupIDs {
                    try await store.deleteManualThreadGroup(id: groupID)
                }
                await MainActor.run { self.scheduleRethread() }
            } catch {
                Log.app.error("Failed to merge manual thread groups: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func ungroupSelectedMessages() {
        let selectedNodes = selectedNodes(in: roots)
        guard !selectedNodes.isEmpty else { return }

        var removalsByGroupID: [String: (jwzThreadIDs: Set<String>, messageKeys: Set<String>)] = [:]
        for node in selectedNodes {
            let messageKey = node.message.threadKey
            guard let groupID = manualGroupByMessageKey[messageKey] else { continue }
            if manualAttachmentMessageIDs.contains(node.id) {
                removalsByGroupID[groupID, default: ([], [])].messageKeys.insert(messageKey)
            } else {
                let jwzThreadID = jwzThreadMap[messageKey] ?? node.message.threadID ?? node.id
                removalsByGroupID[groupID, default: ([], [])].jwzThreadIDs.insert(jwzThreadID)
            }
        }

        guard !removalsByGroupID.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await removeManualGroupMembership(removalsByGroupID: removalsByGroupID)
                await MainActor.run { self.scheduleRethread() }
            } catch {
                Log.app.error("Failed to remove manual thread grouping: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    private func updateNextRefreshDate(_ date: Date?) {
        nextRefreshDate = date
    }

    private var hasManualGroupMembershipInSelection: Bool {
        !manualGroupByMessageKey.isEmpty &&
            selectedNodes(in: roots).contains { manualGroupByMessageKey[$0.message.threadKey] != nil }
    }

    private func selectedNodes(in roots: [ThreadNode]) -> [ThreadNode] {
        guard !selectedNodeIDs.isEmpty else { return [] }
        return Self.nodes(matching: selectedNodeIDs, in: roots)
    }

    private func pruneSelection(using roots: [ThreadNode]) {
        let validIDs = Set(Self.flatten(nodes: roots).map(\.id))
        if selectedNodeIDs.isEmpty {
            selectedNodeID = nil
            return
        }
        selectedNodeIDs = selectedNodeIDs.intersection(validIDs)
        if let selectedNodeID, !selectedNodeIDs.contains(selectedNodeID) {
            self.selectedNodeID = selectedNodeIDs.sorted().first
        }
        if selectedNodeIDs.isEmpty {
            selectedNodeID = nil
        }
    }

    private func pruneFolderSelection(using folders: [ThreadFolder]) {
        guard let selectedFolderID else { return }
        let validIDs = Set(folders.map(\.id))
        if !validIDs.contains(selectedFolderID) {
            self.selectedFolderID = nil
        }
    }

    private var effectiveThreadFolders: [ThreadFolder] {
        guard !folderEditsByID.isEmpty else { return threadFolders }
        return threadFolders.map { folder in
            guard let edit = folderEditsByID[folder.id] else { return folder }
            var updated = folder
            updated.title = edit.title
            updated.color = edit.color
            return updated
        }
    }

    private func expandDayWindowIfNeeded(visibleRange: ClosedRange<Int>?,
                                         forceIncrement: Bool) {
        var targetDayCount = dayWindowCount
        if let visibleRange {
            let highestVisibleDay = visibleRange.upperBound
            let desiredBlocks = (highestVisibleDay / dayWindowIncrement) + 1
            let desiredDayCount = desiredBlocks * dayWindowIncrement
            targetDayCount = max(targetDayCount, desiredDayCount)
        }
        if forceIncrement && targetDayCount == dayWindowCount {
            targetDayCount += dayWindowIncrement
        }
        guard targetDayCount > dayWindowCount else { return }
#if DEBUG
        Log.app.info("ThreadCanvas expand dayWindowCount=\(self.dayWindowCount, privacy: .public) -> \(targetDayCount, privacy: .public) visibleRange=\(String(describing: visibleRange), privacy: .public) forceIncrement=\(forceIncrement, privacy: .public)")
        print("ThreadCanvas expand dayWindowCount=\(self.dayWindowCount) -> \(targetDayCount) visibleRange=\(String(describing: visibleRange)) forceIncrement=\(forceIncrement)")
#endif
        dayWindowCount = targetDayCount
        scheduleRethread()
    }

    private func cachedMessageCutoffDate(today: Date = Date(),
                                         calendar: Calendar = .current) -> Date? {
        let dayCount = max(dayWindowCount, 1)
        let startOfToday = calendar.startOfDay(for: today)
        return calendar.date(byAdding: .day, value: -(dayCount - 1), to: startOfToday)
    }

    private func removeManualGroupMembership(removalsByGroupID: [String: (jwzThreadIDs: Set<String>, messageKeys: Set<String>)]) async throws {
        for (groupID, removals) in removalsByGroupID {
            guard var group = manualGroups[groupID] else { continue }
            group.jwzThreadIDs.subtract(removals.jwzThreadIDs)
            group.manualMessageKeys.subtract(removals.messageKeys)
            if group.manualMessageKeys.isEmpty && group.jwzThreadIDs.isEmpty {
                try await store.deleteManualThreadGroup(id: groupID)
            } else {
                try await store.upsertManualThreadGroups([group])
            }
        }
    }

    func addFolderForSelection() {
        let selectedNodes = selectedNodes(in: roots)
        guard !selectedNodes.isEmpty else { return }

        let effectiveThreadIDs = Set(selectedNodes.compactMap { effectiveThreadID(for: $0) })
        guard !effectiveThreadIDs.isEmpty else { return }

        let selectedFolderIDs = Set(effectiveThreadIDs.compactMap { folderMembershipByThreadID[$0] })
        let parentFolderID = selectedFolderIDs.count == 1 ? selectedFolderIDs.first : nil

        let latestSubjectNode = selectedNodes.max(by: { $0.message.date < $1.message.date })
        let defaultTitle = latestSubjectNode.map { node in
            node.message.subject.isEmpty ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing") : node.message.subject
        } ?? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing")

        let folder = ThreadFolder(id: "folder-\(UUID().uuidString.lowercased())",
                                  title: defaultTitle,
                                  color: ThreadFolderColor.random(),
                                  threadIDs: effectiveThreadIDs,
                                  parentID: parentFolderID)
        let childIDsByParent = Self.childFolderIDsByParent(folders: threadFolders + [folder])
        let updatedExistingFolders: [ThreadFolder] = threadFolders.compactMap { existingFolder in
            var updatedFolder = existingFolder
            updatedFolder.threadIDs.subtract(effectiveThreadIDs)
            if updatedFolder.threadIDs.isEmpty && (childIDsByParent[updatedFolder.id]?.isEmpty ?? true) {
                return nil
            }
            return updatedFolder
        }
        let deletedFolderIDs = Set(threadFolders.map(\.id)).subtracting(updatedExistingFolders.map(\.id))
        let updatedFolders = updatedExistingFolders + [folder]

        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.upsertThreadFolders(updatedFolders)
                if !deletedFolderIDs.isEmpty {
                    try await store.deleteThreadFolders(ids: Array(deletedFolderIDs))
                }
                await MainActor.run {
                    self.threadFolders = updatedFolders
                    self.folderMembershipByThreadID = Self.folderMembershipMap(for: updatedFolders)
                    self.refreshFolderSummaries(for: self.roots, folders: updatedFolders)
                }
            } catch {
                Log.app.error("Failed to save thread folder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func effectiveThreadID(for node: ThreadNode) -> String? {
        let messageKey = node.message.threadKey
        if let manualGroupID = manualGroupByMessageKey[messageKey] {
            return manualGroupID
        }
        if let jwzID = jwzThreadMap[messageKey] {
            return jwzID
        }
        if let threadID = node.message.threadID {
            return threadID
        }
        return node.id
    }
}

private extension ThreadCanvasViewModel {
    static func newManualGroupID() -> String {
        "manual-\(UUID().uuidString.lowercased())"
    }
}

extension ThreadCanvasViewModel {
    static func canvasLayout(for roots: [ThreadNode],
                             metrics: ThreadCanvasLayoutMetrics,
                             today: Date,
                             calendar: Calendar,
                             manualAttachmentMessageIDs: Set<String> = [],
                             jwzThreadMap: [String: String] = [:],
                             folders: [ThreadFolder] = [],
                             folderMembershipByThreadID: [String: String] = [:]) -> ThreadCanvasLayout {
        let dayHeights = dayHeights(for: roots, metrics: metrics, today: today, calendar: calendar)
        var currentYOffset = metrics.contentPadding
        let days = (0..<metrics.dayCount).map { index -> ThreadCanvasDay in
            let date = ThreadCanvasDateHelper.dayDate(for: index, today: today, calendar: calendar)
            let label = ThreadCanvasDateHelper.label(for: date)
            let height = dayHeights[index] ?? metrics.dayHeight
            let day = ThreadCanvasDay(id: index, date: date, label: label, yOffset: currentYOffset, height: height)
            currentYOffset += height
            return day
        }
        let dayLookup = Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0) })

        typealias ThreadInfo = (root: ThreadNode, latestDate: Date, threadID: String)
        enum OrderingItem {
            case folder(String)
            case thread(ThreadInfo)
        }

        let columnInfos: [ThreadInfo] = roots.map { root in
            let latest = Self.latestDate(in: root)
            let threadID = root.message.threadID ?? root.id
            return (root, latest, threadID)
        }

        var columns: [ThreadCanvasColumn] = []
        columns.reserveCapacity(columnInfos.count)
        let hierarchy = folderHierarchy(for: folders)
        let normalizedMembership = folderMembershipByThreadID.reduce(into: [String: String]()) { result, entry in
            if hierarchy.foldersByID[entry.value] != nil {
                result[entry.key] = entry.value
            }
        }
        let threadsByFolderID = Dictionary(grouping: columnInfos) { info -> String? in
            normalizedMembership[info.threadID]
        }

        var latestByFolderID: [String: Date] = [:]
        func latestDateForFolder(_ folderID: String) -> Date {
            if let cached = latestByFolderID[folderID] {
                return cached
            }
            let threadDates = threadsByFolderID[folderID]?.map(\.latestDate) ?? []
            let childDates = (hierarchy.childrenByParentID[folderID] ?? []).map { latestDateForFolder($0) }
            let latest = (threadDates + childDates).max() ?? Date.distantPast
            latestByFolderID[folderID] = latest
            return latest
        }

        func orderedItems(for parentID: String?) -> [OrderingItem] {
            let folderIDs: [String]
            if let parentID {
                folderIDs = hierarchy.childrenByParentID[parentID] ?? []
            } else {
                folderIDs = hierarchy.rootFolderIDs
            }

            var items: [(latest: Date, item: OrderingItem)] = []
            items.reserveCapacity(folderIDs.count + (threadsByFolderID[parentID]?.count ?? 0))

            for folderID in folderIDs {
                items.append((latest: latestDateForFolder(folderID), item: .folder(folderID)))
            }

            for thread in threadsByFolderID[parentID] ?? [] {
                items.append((latest: thread.latestDate, item: .thread(thread)))
            }

            return items.sorted { lhs, rhs in
                lhs.latest > rhs.latest
            }.map(\.item)
        }

        var currentColumnIndex = 0
        func appendColumns(for items: [OrderingItem]) {
            for item in items {
                switch item {
                case .folder(let folderID):
                    appendColumns(for: orderedItems(for: folderID))
                case .thread(let thread):
                    let columnX = metrics.contentPadding
                        + metrics.dayLabelWidth
                        + CGFloat(currentColumnIndex) * (metrics.columnWidth + metrics.columnSpacing)
                    let nodes = layoutNodes(for: thread.root,
                                            threadID: thread.threadID,
                                            columnX: columnX,
                                            metrics: metrics,
                                            today: today,
                                            calendar: calendar,
                                            dayLookup: dayLookup,
                                            manualAttachmentMessageIDs: manualAttachmentMessageIDs,
                                            jwzThreadMap: jwzThreadMap)
                    let title = thread.root.message.subject.isEmpty ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing") : thread.root.message.subject
                    let folderID = normalizedMembership[thread.threadID]
                    columns.append(ThreadCanvasColumn(id: thread.threadID,
                                                      title: title,
                                                      xOffset: columnX,
                                                      nodes: nodes,
                                                      latestDate: thread.latestDate,
                                                      folderID: folderID))
                    currentColumnIndex += 1
                }
            }
        }

        appendColumns(for: orderedItems(for: nil))

        let columnCount = CGFloat(columns.count)
        let totalWidth = metrics.contentPadding * 2
            + metrics.dayLabelWidth
            + (columnCount * metrics.columnWidth)
            + max(columnCount - 1, 0) * metrics.columnSpacing
        let totalHeight = metrics.contentPadding * 2
            + days.reduce(0) { $0 + $1.height }
        let folderOverlays = folderOverlaysForLayout(columns: columns,
                                                     folders: folders,
                                                     membership: normalizedMembership,
                                                     contentHeight: totalHeight,
                                                     metrics: metrics)
        return ThreadCanvasLayout(days: days,
                                  columns: columns,
                                  contentSize: CGSize(width: totalWidth, height: totalHeight),
                                  folderOverlays: folderOverlays)
    }

    static func node(matching id: String?, in roots: [ThreadNode]) -> ThreadNode? {
        guard let id else { return nil }
        for root in roots {
            if let match = findNode(in: root, matching: id) {
                return match
            }
        }
        return nil
    }

    private static func latestDate(in node: ThreadNode) -> Date {
        node.children.reduce(node.message.date) { current, child in
            max(current, latestDate(in: child))
        }
    }

    private static func layoutNodes(for root: ThreadNode,
                                    threadID: String,
                                    columnX: CGFloat,
                                    metrics: ThreadCanvasLayoutMetrics,
                                    today: Date,
                                    calendar: Calendar,
                                    dayLookup: [Int: ThreadCanvasDay],
                                    manualAttachmentMessageIDs: Set<String>,
                                    jwzThreadMap: [String: String]) -> [ThreadCanvasNode] {
        var grouped: [Int: [ThreadNode]] = [:]
        let allNodes = flatten(node: root)
        for node in allNodes {
            guard let dayIndex = ThreadCanvasDateHelper.dayIndex(for: node.message.date,
                                                                 today: today,
                                                                 calendar: calendar,
                                                                 dayCount: metrics.dayCount) else {
                continue
            }
            grouped[dayIndex, default: []].append(node)
        }

        var nodes: [ThreadCanvasNode] = []
        for (dayIndex, dayNodes) in grouped {
            guard let day = dayLookup[dayIndex] else { continue }
            let sorted = dayNodes.sorted { lhs, rhs in
                lhs.message.date > rhs.message.date
            }
            let count = sorted.count
            let dayBaseY = day.yOffset + metrics.nodeVerticalSpacing
            let usableHeight = max(day.height - metrics.nodeHeight - (metrics.nodeVerticalSpacing * 2), 0)
            let nodeGap = metrics.nodeVerticalSpacing
            let maxStep = metrics.nodeHeight + nodeGap
            let step = count > 1 ? min(maxStep, usableHeight / CGFloat(count - 1)) : 0

            for (stackIndex, node) in sorted.enumerated() {
                let y = dayBaseY + CGFloat(stackIndex) * step
                let frame = CGRect(x: columnX + metrics.nodeHorizontalInset,
                                   y: y,
                                   width: metrics.nodeWidth,
                                   height: metrics.nodeHeight)
                let messageKey = node.message.threadKey
                let jwzThreadID = jwzThreadMap[messageKey] ?? node.message.threadID ?? threadID
                nodes.append(ThreadCanvasNode(id: node.id,
                                              message: node.message,
                                              threadID: threadID,
                                              jwzThreadID: jwzThreadID,
                                              frame: frame,
                                              dayIndex: dayIndex,
                                              isManualAttachment: manualAttachmentMessageIDs.contains(node.id)))
            }
        }

        return nodes.sorted { lhs, rhs in
            if lhs.dayIndex == rhs.dayIndex {
                return lhs.message.date > rhs.message.date
            }
            return lhs.dayIndex < rhs.dayIndex
        }
    }

    private static func flatten(node: ThreadNode) -> [ThreadNode] {
        var results = [node]
        for child in node.children {
            results.append(contentsOf: flatten(node: child))
        }
        return results
    }

    private static func findNode(in node: ThreadNode, matching id: String) -> ThreadNode? {
        if node.id == id {
            return node
        }
        for child in node.children {
            if let match = findNode(in: child, matching: id) {
                return match
            }
        }
        return nil
    }

    static func rootID(for nodeID: String, in roots: [ThreadNode]) -> String? {
        for root in roots {
            if findNode(in: root, matching: nodeID) != nil {
                return root.id
            }
        }
        return nil
    }

    private static func dayHeights(for roots: [ThreadNode],
                                   metrics: ThreadCanvasLayoutMetrics,
                                   today: Date,
                                   calendar: Calendar) -> [Int: CGFloat] {
        var maxCountsByDay: [Int: Int] = [:]
        for root in roots {
            var countsByDay: [Int: Int] = [:]
            for node in flatten(node: root) {
                guard let dayIndex = ThreadCanvasDateHelper.dayIndex(for: node.message.date,
                                                                     today: today,
                                                                     calendar: calendar,
                                                                     dayCount: metrics.dayCount) else {
                    continue
                }
                countsByDay[dayIndex, default: 0] += 1
            }
            for (dayIndex, count) in countsByDay {
                maxCountsByDay[dayIndex] = max(maxCountsByDay[dayIndex, default: 0], count)
            }
        }

        var heights: [Int: CGFloat] = [:]
        for dayIndex in 0..<metrics.dayCount {
            let count = maxCountsByDay[dayIndex, default: 0]
            heights[dayIndex] = max(metrics.dayHeight, requiredDayHeight(nodeCount: count, metrics: metrics))
        }
        return heights
    }

    private static func requiredDayHeight(nodeCount: Int, metrics: ThreadCanvasLayoutMetrics) -> CGFloat {
        guard nodeCount > 1 else {
            return metrics.dayHeight
        }
        let nodeGap = metrics.nodeVerticalSpacing
        let maxStep = metrics.nodeHeight + nodeGap
        return metrics.nodeHeight
            + (metrics.nodeVerticalSpacing * 2)
            + CGFloat(nodeCount - 1) * maxStep
    }

    private struct FolderHierarchy {
        let foldersByID: [String: ThreadFolder]
        let childrenByParentID: [String: [String]]
        let rootFolderIDs: [String]
        let depthByID: [String: Int]
    }

    private static func folderHierarchy(for folders: [ThreadFolder]) -> FolderHierarchy {
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var childrenByParentID: [String: [String]] = [:]
        var rootFolderIDs: [String] = []

        for folder in folders {
            if let parentID = folder.parentID, foldersByID[parentID] != nil {
                childrenByParentID[parentID, default: []].append(folder.id)
            } else {
                rootFolderIDs.append(folder.id)
            }
        }

        var depthByID: [String: Int] = [:]
        func resolveDepth(for folderID: String, visiting: inout Set<String>) -> Int {
            if let cached = depthByID[folderID] {
                return cached
            }
            guard let folder = foldersByID[folderID] else {
                depthByID[folderID] = 0
                return 0
            }
            guard let parentID = folder.parentID, foldersByID[parentID] != nil else {
                depthByID[folderID] = 0
                return 0
            }
            if visiting.contains(folderID) {
                depthByID[folderID] = 0
                return 0
            }
            visiting.insert(folderID)
            let parentDepth = resolveDepth(for: parentID, visiting: &visiting)
            visiting.remove(folderID)
            let depth = parentDepth + 1
            depthByID[folderID] = depth
            return depth
        }

        for folder in folders {
            var visiting: Set<String> = []
            _ = resolveDepth(for: folder.id, visiting: &visiting)
        }

        return FolderHierarchy(foldersByID: foldersByID,
                               childrenByParentID: childrenByParentID,
                               rootFolderIDs: rootFolderIDs,
                               depthByID: depthByID)
    }

    static func childFolderIDsByParent(folders: [ThreadFolder]) -> [String: [String]] {
        folderHierarchy(for: folders).childrenByParentID
    }

    private static func folderOverlaysForLayout(columns: [ThreadCanvasColumn],
                                                folders: [ThreadFolder],
                                                membership: [String: String],
                                                contentHeight: CGFloat,
                                                metrics: ThreadCanvasLayoutMetrics) -> [ThreadCanvasFolderOverlay] {
        guard !folders.isEmpty else { return [] }
        let hierarchy = folderHierarchy(for: folders)
        let columnsByFolderID = Dictionary(grouping: columns) { column -> String? in
            membership[column.id]
        }

        var columnCache: [String: [ThreadCanvasColumn]] = [:]
        func columnsForFolder(_ folderID: String) -> [ThreadCanvasColumn] {
            if let cached = columnCache[folderID] {
                return cached
            }
            var result = columnsByFolderID[folderID] ?? []
            for childID in hierarchy.childrenByParentID[folderID] ?? [] {
                result.append(contentsOf: columnsForFolder(childID))
            }
            columnCache[folderID] = result
            return result
        }

        var overlays: [ThreadCanvasFolderOverlay] = []
        overlays.reserveCapacity(folders.count)

        for folder in folders {
            let columns = columnsForFolder(folder.id)
            guard !columns.isEmpty else { continue }
            let sortedColumns = columns.sorted { $0.xOffset < $1.xOffset }
            let minX = (sortedColumns.first?.xOffset ?? 0)
            let maxX = (sortedColumns.last.map { $0.xOffset + metrics.columnWidth } ?? 0)

            let nodes = sortedColumns.flatMap(\.nodes)
            guard !nodes.isEmpty else { continue }
            let minY = nodes.map { $0.frame.minY }.min() ?? 0
            let maxY = nodes.map { $0.frame.maxY }.max() ?? contentHeight
            let headerInset = metrics.nodeVerticalSpacing * 1.3
            let paddedMinY = max(0, minY - headerInset)
            let paddedHeight = (maxY - minY) + metrics.nodeVerticalSpacing * 2 + headerInset

            let frame = CGRect(x: minX,
                               y: paddedMinY,
                               width: maxX - minX,
                               height: paddedHeight)

            overlays.append(ThreadCanvasFolderOverlay(id: folder.id,
                                                      title: folder.title,
                                                      color: folder.color,
                                                      frame: frame,
                                                      columnIDs: sortedColumns.map(\.id),
                                                      parentID: folder.parentID,
                                                      depth: hierarchy.depthByID[folder.id] ?? 0))
        }

        return overlays.sorted { lhs, rhs in
            lhs.frame.minX < rhs.frame.minX
        }
    }

    private static func nodes(matching ids: Set<String>, in roots: [ThreadNode]) -> [ThreadNode] {
        guard !ids.isEmpty else { return [] }
        return flatten(nodes: roots).filter { ids.contains($0.id) }
    }

    private static func flatten(nodes: [ThreadNode]) -> [ThreadNode] {
        var results: [ThreadNode] = []
        for node in nodes {
            results.append(contentsOf: flatten(node: node))
        }
        return results
    }

    static func folderMembershipMap(for folders: [ThreadFolder]) -> [String: String] {
        folders.reduce(into: [String: String]()) { result, folder in
            folder.threadIDs.forEach { result[$0] = folder.id }
        }
    }

    struct FolderMoveUpdate {
        let folders: [ThreadFolder]
        let deletedFolderIDs: Set<String>
        let membership: [String: String]
    }

    struct FolderRemovalUpdate {
        let remainingFolders: [ThreadFolder]
        let deletedFolderIDs: Set<String>
        let membership: [String: String]
    }

    static func applyMove(threadID: String,
                          toFolderID folderID: String,
                          folders: [ThreadFolder]) -> FolderMoveUpdate? {
        guard folders.contains(where: { $0.id == folderID }) else { return nil }
        var updatedFolders = folders
        var deletedFolderIDs: Set<String> = []

        // Remove the thread from any existing folder memberships first.
        for index in updatedFolders.indices {
            if updatedFolders[index].threadIDs.contains(threadID) {
                updatedFolders[index].threadIDs.remove(threadID)
            }
        }

        let childIDsByParent = childFolderIDsByParent(folders: updatedFolders)
        updatedFolders.removeAll { folder in
            guard folder.id != folderID else { return false }
            guard folder.threadIDs.isEmpty else { return false }
            guard (childIDsByParent[folder.id]?.isEmpty ?? true) else { return false }
            deletedFolderIDs.insert(folder.id)
            return true
        }

        guard let targetIndex = updatedFolders.firstIndex(where: { $0.id == folderID }) else { return nil }
        updatedFolders[targetIndex].threadIDs.insert(threadID)
        let membership = folderMembershipMap(for: updatedFolders)
        return FolderMoveUpdate(folders: updatedFolders,
                                deletedFolderIDs: deletedFolderIDs,
                                membership: membership)
    }

    static func applyRemoval(threadID: String,
                             folders: [ThreadFolder]) -> FolderRemovalUpdate? {
        guard let folderIndex = folders.firstIndex(where: { $0.threadIDs.contains(threadID) }) else {
            return nil
        }
        var updatedFolders = folders
        var deletedFolderIDs: Set<String> = []

        updatedFolders[folderIndex].threadIDs.remove(threadID)
        if updatedFolders[folderIndex].threadIDs.isEmpty {
            let childIDsByParent = childFolderIDsByParent(folders: updatedFolders)
            let folderID = updatedFolders[folderIndex].id
            if (childIDsByParent[folderID]?.isEmpty ?? true) {
                deletedFolderIDs.insert(folderID)
                updatedFolders.remove(at: folderIndex)
            }
        }

        let membership = folderMembershipMap(for: updatedFolders)
        return FolderRemovalUpdate(remainingFolders: updatedFolders,
                                   deletedFolderIDs: deletedFolderIDs,
                                   membership: membership)
    }

    static func visibleDayRange(for layout: ThreadCanvasLayout,
                                scrollOffset: CGFloat,
                                viewportHeight: CGFloat) -> ClosedRange<Int>? {
        let visibleStart = scrollOffset
        let visibleEnd = scrollOffset + viewportHeight
        let visibleDays = layout.days.filter { day in
            let dayStart = day.yOffset
            let dayEnd = day.yOffset + day.height
            return dayEnd >= visibleStart && dayStart <= visibleEnd
        }
        guard let minID = visibleDays.map(\.id).min(),
              let maxID = visibleDays.map(\.id).max() else {
            return nil
        }
        return minID...maxID
    }

    static func emptyDayIntervals(for layout: ThreadCanvasLayout,
                                  visibleRange: ClosedRange<Int>?,
                                  today: Date,
                                  calendar: Calendar) -> [DateInterval] {
        guard let visibleRange else { return [] }
        let populatedDays = Set(layout.columns.flatMap { $0.nodes.map(\.dayIndex) })
        let emptyDayIndices = (visibleRange.lowerBound...visibleRange.upperBound)
            .filter { !populatedDays.contains($0) }
        guard !emptyDayIndices.isEmpty else { return [] }
        let sorted = emptyDayIndices.sorted()

        var intervals: [DateInterval] = []
        var startIndex = sorted[0]
        var previousIndex = startIndex

        for index in sorted.dropFirst() {
            if index == previousIndex + 1 {
                previousIndex = index
                continue
            }
            if let interval = dayInterval(startIndex: startIndex,
                                          endIndex: previousIndex,
                                          today: today,
                                          calendar: calendar) {
                intervals.append(interval)
            }
            startIndex = index
            previousIndex = index
        }

        if let interval = dayInterval(startIndex: startIndex,
                                      endIndex: previousIndex,
                                      today: today,
                                      calendar: calendar) {
            intervals.append(interval)
        }
        return intervals
    }

    static func shouldExpandDayWindow(scrollOffset: CGFloat,
                                      viewportHeight: CGFloat,
                                      contentHeight: CGFloat,
                                      threshold: CGFloat) -> Bool {
        let visibleBottom = scrollOffset + viewportHeight
        return visibleBottom >= contentHeight - threshold
    }

    private static func dayInterval(startIndex: Int,
                                    endIndex: Int,
                                    today: Date,
                                    calendar: Calendar) -> DateInterval? {
        guard startIndex <= endIndex else { return nil }
        let newerDate = ThreadCanvasDateHelper.dayDate(for: startIndex, today: today, calendar: calendar)
        let olderDate = ThreadCanvasDateHelper.dayDate(for: endIndex, today: today, calendar: calendar)
        guard let endDate = calendar.date(byAdding: .day, value: 1, to: newerDate) else {
            return nil
        }
        let start = min(olderDate, newerDate)
        let end = max(endDate, start)
        return DateInterval(start: start, end: end)
    }
}
