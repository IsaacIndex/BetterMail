import Combine
import Foundation
import OSLog

struct ThreadSummaryState {
    var text: String
    var statusMessage: String
    var isSummarizing: Bool
}

@MainActor
final class ThreadSidebarViewModel: ObservableObject {
    private actor SidebarBackgroundWorker {
        private let client: MailAppleScriptClient
        private let store: MessageStore
        private let threader: JWZThreader
        private let summaryProvider: EmailSummaryProviding?

        init(client: MailAppleScriptClient,
             store: MessageStore,
             threader: JWZThreader,
             summaryProvider: EmailSummaryProviding?) {
            self.client = client
            self.store = store
            self.threader = threader
            self.summaryProvider = summaryProvider
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
        }

        func performRefresh(effectiveLimit: Int,
                            since: Date?) async throws -> RefreshOutcome {
            let fetched = try await client.fetchMessages(since: since, limit: effectiveLimit)
            try await store.upsert(messages: fetched)
            let latest = fetched.map(\.date).max()
            return RefreshOutcome(fetchedCount: fetched.count, latestDate: latest)
        }

        func performRethread(fetchLimit: Int) async throws -> RethreadOutcome {
            let messages = try await store.fetchMessages(limit: fetchLimit)
            let result = threader.buildThreads(from: messages)
            try await store.updateThreadMembership(result.messageThreadMap, threads: result.threads)
            let unread = result.threads.reduce(0) { $0 + $1.unreadCount }
            return RethreadOutcome(roots: result.roots,
                                   unreadTotal: unread,
                                   messageCount: messages.count,
                                   threadCount: result.threads.count)
        }

        func subjectsByRoot(_ roots: [ThreadNode]) -> [String: [String]] {
            roots.reduce(into: [String: [String]]()) { result, root in
                result[root.id] = subjects(in: root)
            }
        }

        func summarize(subjects: [String]) async throws -> String {
            guard let summaryProvider else { throw CancellationError() }
            return try await summaryProvider.summarize(subjects: subjects)
        }

        private func subjects(in node: ThreadNode) -> [String] {
            var results: [String] = []
            let trimmed = node.message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                results.append(trimmed)
            }
            for child in node.children {
                results.append(contentsOf: subjects(in: child))
            }
            return results
        }
    }

    @Published private(set) var roots: [ThreadNode] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var status: String = ""
    @Published private(set) var unreadTotal: Int = 0
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var nextRefreshDate: Date?
    @Published private(set) var threadSummaries: [String: ThreadSummaryState] = [:]
    @Published private(set) var expandedSummaryIDs: Set<String> = []
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
    private let settings: AutoRefreshSettings
    private let worker: SidebarBackgroundWorker
    private var rethreadTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var summaryTasks: [String: Task<Void, Never>] = [:]
    private var didStart = false
    private var shouldForceFullReload = false

    init(settings: AutoRefreshSettings,
         store: MessageStore = .shared,
         client: MailAppleScriptClient = MailAppleScriptClient(),
         threader: JWZThreader = JWZThreader()) {
        self.store = store
        self.client = client
        self.threader = threader
        self.settings = settings
        let capability = EmailSummaryProviderFactory.makeCapability()
        self.summaryProvider = capability.provider
        self.worker = SidebarBackgroundWorker(client: client,
                                              store: store,
                                              threader: threader,
                                              summaryProvider: capability.provider)
    }

    deinit {
        rethreadTask?.cancel()
        autoRefreshTask?.cancel()
        summaryTasks.values.forEach { $0.cancel() }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Log.refresh.info("ThreadSidebarViewModel start invoked. didStart=false; kicking off initial load.")
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
                let outcome = try await worker.performRefresh(effectiveLimit: effectiveLimit,
                                                              since: since)
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
            let fetchLimit = self.fetchLimit
            let rethreadResult = try await worker.performRethread(fetchLimit: fetchLimit)
            self.roots = rethreadResult.roots
            self.unreadTotal = rethreadResult.unreadTotal
            refreshSummaries(for: rethreadResult.roots)
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
        threadSummaries[nodeID]
    }

    private func refreshSummaries(for roots: [ThreadNode]) {
        guard let summaryProvider else {
            threadSummaries = [:]
            summaryTasks.values.forEach { $0.cancel() }
            summaryTasks.removeAll()
            return
        }

        let provider = summaryProvider
        let rootsSnapshot = roots
        Task { [weak self] in
            guard let self else { return }
            let subjectsByID = await worker.subjectsByRoot(rootsSnapshot)
            prepareSummaries(for: rootsSnapshot,
                             subjectsByID: subjectsByID,
                             summaryProvider: provider)
        }
    }

    @MainActor
    private func prepareSummaries(for roots: [ThreadNode],
                                  subjectsByID: [String: [String]],
                                  summaryProvider: EmailSummaryProviding) {
        let validRootIDs = Set(roots.map(\.id))
        for (id, task) in summaryTasks where !validRootIDs.contains(id) {
            task.cancel()
            summaryTasks.removeValue(forKey: id)
            threadSummaries.removeValue(forKey: id)
            expandedSummaryIDs.remove(id)
        }

        for root in roots {
            guard let subjects = subjectsByID[root.id], !subjects.isEmpty else {
                threadSummaries.removeValue(forKey: root.id)
                summaryTasks[root.id]?.cancel()
                summaryTasks.removeValue(forKey: root.id)
                expandedSummaryIDs.remove(root.id)
                continue
            }

            threadSummaries[root.id] = ThreadSummaryState(text: threadSummaries[root.id]?.text ?? "",
                                                          statusMessage: "Summarizing…",
                                                          isSummarizing: true)

            summaryTasks[root.id]?.cancel()
            summaryTasks[root.id] = Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await worker.summarize(subjects: subjects)
                    let timestamp = DateFormatter.localizedString(from: Date(),
                                                                  dateStyle: .none,
                                                                  timeStyle: .short)
                    await MainActor.run {
                        self.updateSummary(for: root.id,
                                           text: text,
                                           status: "Updated \(timestamp)",
                                           isSummarizing: false)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.finishSummary(for: root.id)
                    }
                } catch {
                    await MainActor.run {
                        self.updateSummary(for: root.id,
                                           text: "",
                                           status: error.localizedDescription,
                                           isSummarizing: false)
                    }
                }
            }
        }
    }

    @MainActor
    private func updateSummary(for id: String,
                               text: String,
                               status: String,
                               isSummarizing: Bool) {
        threadSummaries[id] = ThreadSummaryState(text: text,
                                                 statusMessage: status,
                                                 isSummarizing: isSummarizing)
    }

    @MainActor
    private func finishSummary(for id: String) {
        guard var state = threadSummaries[id] else { return }
        state.isSummarizing = false
        threadSummaries[id] = state
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

    @MainActor
    private func updateNextRefreshDate(_ date: Date?) {
        nextRefreshDate = date
    }
}
