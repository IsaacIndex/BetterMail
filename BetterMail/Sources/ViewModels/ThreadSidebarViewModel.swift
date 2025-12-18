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
    @Published private(set) var roots: [ThreadNode] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var status: String = ""
    @Published private(set) var unreadTotal: Int = 0
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
    private var rethreadTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var summaryTasks: [String: Task<Void, Never>] = [:]
    private var didStart = false
    private var shouldForceFullReload = false

    init(store: MessageStore = .shared,
         client: MailAppleScriptClient = MailAppleScriptClient(),
         threader: JWZThreader = JWZThreader()) {
        self.store = store
        self.client = client
        self.threader = threader
        let capability = EmailSummaryProviderFactory.makeCapability()
        self.summaryProvider = capability.provider
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
        beginAutoRefresh()
    }

    func refreshNow(limit: Int? = nil) {
        guard !isRefreshing else {
            Log.refresh.debug("Refresh skipped because another refresh is in progress.")
            return
        }
        let effectiveLimit = limit ?? fetchLimit
        isRefreshing = true
        status = "Refreshing…"
        let since: Date?
        if shouldForceFullReload {
            Log.refresh.info("Forcing full reload due to fetchLimit change.")
            since = nil
        } else {
            since = store.lastSyncDate
        }
        let sinceDisplay = since?.ISO8601Format() ?? "nil"
        Log.refresh.info("Starting refresh. limit=\(effectiveLimit, privacy: .public) since=\(sinceDisplay, privacy: .public)")
        Task {
            do {
                let client = self.client
                let fetched = try await Task.detached(priority: .utility) {
                    try client.fetchMessages(since: since, limit: effectiveLimit)
                }.value
                Log.refresh.info("AppleScript fetch succeeded. messageCount=\(fetched.count, privacy: .public)")
                try await store.upsert(messages: fetched)
                if let latest = fetched.map(\.date).max() {
                    store.lastSyncDate = latest
                }
                if let newDate = store.lastSyncDate {
                    Log.refresh.debug("Updated lastSyncDate to \(newDate.ISO8601Format(), privacy: .public)")
                }
                shouldForceFullReload = false
                scheduleRethread()
                status = "Updated \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            } catch {
                Log.refresh.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
                status = "Refresh failed: \(error.localizedDescription)"
            }
                isRefreshing = false
        }
    }

    func beginAutoRefresh(interval: TimeInterval = 300) {
        Log.refresh.info("Configuring auto refresh. interval=\(interval, privacy: .public)s")
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self.refreshNow()
            }
        }
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
            let messages = try await store.fetchMessages(limit: fetchLimit)
            let result = threader.buildThreads(from: messages)
            try await store.updateThreadMembership(result.messageThreadMap, threads: result.threads)
            self.roots = result.roots
            self.unreadTotal = result.threads.reduce(0) { $0 + $1.unreadCount }
            refreshSummaries(for: result.roots)
            Log.refresh.info("Rethread complete. messages=\(messages.count, privacy: .public) threads=\(result.threads.count, privacy: .public) unreadTotal=\(self.unreadTotal, privacy: .public)")
        } catch {
            Log.refresh.error("Rethread failed: \(error.localizedDescription, privacy: .public)")
            status = "Threading failed: \(error.localizedDescription)"
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

        let validRootIDs = Set(roots.map(\.id))
        for (id, task) in summaryTasks where !validRootIDs.contains(id) {
            task.cancel()
            summaryTasks.removeValue(forKey: id)
            threadSummaries.removeValue(forKey: id)
            expandedSummaryIDs.remove(id)
        }

        for root in roots {
            let subjects = Self.subjects(in: root)
            guard !subjects.isEmpty else {
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
                    let text = try await summaryProvider.summarize(subjects: subjects)
                    let timestamp = DateFormatter.localizedString(from: Date(),
                                                                  dateStyle: .none,
                                                                  timeStyle: .short)
                    await self.updateSummary(for: root.id,
                                             text: text,
                                             status: "Updated \(timestamp)",
                                             isSummarizing: false)
                } catch is CancellationError {
                    await self.finishSummary(for: root.id)
                } catch {
                    await self.updateSummary(for: root.id,
                                             text: "",
                                             status: error.localizedDescription,
                                             isSummarizing: false)
                }
            }
        }
    }

    private static func subjects(in node: ThreadNode) -> [String] {
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
}
