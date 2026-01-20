import Combine
import CoreGraphics
import Foundation
import OSLog

struct ThreadSummaryState {
    var text: String
    var statusMessage: String
    var isSummarizing: Bool
}

@MainActor
final class ThreadCanvasViewModel: ObservableObject {
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
    @Published var selectedNodeID: String?
    @Published private(set) var selectedNodeIDs: Set<String> = []
    @Published private(set) var manualGroupByMessageKey: [String: String] = [:]
    @Published private(set) var manualAttachmentMessageIDs: Set<String> = []
    @Published private(set) var manualGroups: [String: ManualThreadGroup] = [:]
    @Published private(set) var jwzThreadMap: [String: String] = [:]
    @Published private(set) var threadFolders: [ThreadFolder] = []
    @Published private(set) var folderMembershipByThreadID: [String: String] = [:]
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
    private let settings: AutoRefreshSettings
    private let inspectorSettings: InspectorViewSettings
    private let worker: SidebarBackgroundWorker
    private var rethreadTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var summaryTasks: [String: Task<Void, Never>] = [:]
    private var summaryRefreshGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private var didStart = false
    private var shouldForceFullReload = false
    private let dayWindowIncrement = ThreadCanvasLayoutMetrics.defaultDayCount

    init(settings: AutoRefreshSettings,
         inspectorSettings: InspectorViewSettings,
         store: MessageStore = .shared,
         client: MailAppleScriptClient = MailAppleScriptClient(),
         threader: JWZThreader = JWZThreader()) {
        self.store = store
        self.client = client
        self.threader = threader
        self.settings = settings
        self.inspectorSettings = inspectorSettings
        let capability = EmailSummaryProviderFactory.makeCapability()
        self.summaryProvider = capability.provider
        self.worker = SidebarBackgroundWorker(client: client,
                                              store: store,
                                              threader: threader,
                                              summaryProvider: capability.provider)
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
        summaryTasks.values.forEach { $0.cancel() }
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
            pruneSelection(using: rethreadResult.roots)
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

    func rootID(containing nodeID: String) -> String? {
        Self.rootID(for: nodeID, in: roots)
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
        summaryRefreshGeneration += 1
        let generation = summaryRefreshGeneration
        Task { [weak self] in
            guard let self else { return }
            let subjectsByID = await worker.subjectsByRoot(rootsSnapshot)
            await MainActor.run {
                guard self.summaryRefreshGeneration == generation else { return }
                self.prepareSummaries(for: rootsSnapshot,
                                      subjectsByID: subjectsByID,
                                      summaryProvider: provider)
            }
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

    func selectNode(id: String?) {
        selectNode(id: id, additive: false)
    }

    func selectNode(id: String?, additive: Bool) {
        guard let id else {
            selectedNodeID = nil
            selectedNodeIDs = []
            return
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

    func openMessageInMail(_ node: ThreadNode) {
        let messageID = node.message.messageID
        Task.detached {
            do {
                try MailControl.openMessage(messageID: messageID)
            } catch {
                Log.appleScript.error("Open in Mail failed for messageID=\(messageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func moveThread(threadID: String, toFolderID folderID: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let updated = Self.applyMove(threadID: threadID,
                                               toFolderID: folderID,
                                               folders: threadFolders) else { return }
            do {
                try await store.upsertThreadFolders(updated.folders)
                await MainActor.run {
                    self.threadFolders = updated.folders
                    self.folderMembershipByThreadID = updated.membership
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
                }
            } catch {
                Log.app.error("Failed to remove thread from folder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    var selectedNode: ThreadNode? {
        Self.node(matching: selectedNodeID, in: roots)
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
                          folders: threadFolders,
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

        let latestSubjectNode = selectedNodes.max(by: { $0.message.date < $1.message.date })
        let defaultTitle = latestSubjectNode.map { node in
            node.message.subject.isEmpty ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing") : node.message.subject
        } ?? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing")

        let folder = ThreadFolder(id: "folder-\(UUID().uuidString.lowercased())",
                                  title: defaultTitle,
                                  color: ThreadFolderColor.random(),
                                  threadIDs: effectiveThreadIDs)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.upsertThreadFolders([folder])
                await MainActor.run {
                    self.threadFolders.append(folder)
                    for threadID in effectiveThreadIDs {
                        self.folderMembershipByThreadID[threadID] = folder.id
                    }
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

        let columnInfos: [(root: ThreadNode, latestDate: Date, threadID: String)] = roots.map { root in
            let latest = latestDate(in: root)
            let threadID = root.message.threadID ?? root.id
            return (root, latest, threadID)
        }

        var remaining = columnInfos
        var groupedItems: [(latest: Date, threads: [(root: ThreadNode, latestDate: Date, threadID: String)], folder: ThreadFolder?)] = []

        let folderLookup = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })

        for folder in folders {
            let members = remaining.filter { folder.threadIDs.contains($0.threadID) }
            guard !members.isEmpty else { continue }
            remaining.removeAll { folder.threadIDs.contains($0.threadID) }
            let folderLatest = members.map(\.latestDate).max() ?? Date.distantPast
            groupedItems.append((latest: folderLatest, threads: members.sorted { $0.latestDate > $1.latestDate }, folder: folderLookup[folder.id]))
        }

        for info in remaining {
            groupedItems.append((latest: info.latestDate, threads: [info], folder: nil))
        }

        groupedItems.sort { lhs, rhs in
            lhs.latest > rhs.latest
        }

        var columns: [ThreadCanvasColumn] = []
        columns.reserveCapacity(columnInfos.count)

        var currentColumnIndex = 0
        for item in groupedItems {
            for thread in item.threads {
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
                let folderID = folderMembershipByThreadID[thread.threadID]
                columns.append(ThreadCanvasColumn(id: thread.threadID,
                                                  title: title,
                                                  xOffset: columnX,
                                                  nodes: nodes,
                                                  latestDate: thread.latestDate,
                                                  folderID: folderID))
                currentColumnIndex += 1
            }
        }

        let columnCount = CGFloat(columns.count)
        let totalWidth = metrics.contentPadding * 2
            + metrics.dayLabelWidth
            + (columnCount * metrics.columnWidth)
            + max(columnCount - 1, 0) * metrics.columnSpacing
        let totalHeight = metrics.contentPadding * 2
            + days.reduce(0) { $0 + $1.height }
        let folderOverlays = folderOverlaysForLayout(columns: columns,
                                                     folders: folders,
                                                     membership: folderMembershipByThreadID,
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

    private static func folderOverlaysForLayout(columns: [ThreadCanvasColumn],
                                                folders: [ThreadFolder],
                                                membership: [String: String],
                                                contentHeight: CGFloat,
                                                metrics: ThreadCanvasLayoutMetrics) -> [ThreadCanvasFolderOverlay] {
        guard !folders.isEmpty else { return [] }
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })

        let groupedColumns = Dictionary(grouping: columns, by: { membership[$0.id] })
            .compactMap { (key, value) -> (String, [ThreadCanvasColumn])? in
                guard let key else { return nil }
                return (key, value)
            }

        var overlays: [ThreadCanvasFolderOverlay] = []
        overlays.reserveCapacity(groupedColumns.count)

        for (folderID, columns) in groupedColumns {
            guard let folder = foldersByID[folderID] else { continue }
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
                                                      columnIDs: sortedColumns.map(\.id)))
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

    struct FolderUpdate {
        let folders: [ThreadFolder]
        let membership: [String: String]
    }

    struct FolderRemovalUpdate {
        let remainingFolders: [ThreadFolder]
        let deletedFolderIDs: Set<String>
        let membership: [String: String]
    }

    static func applyMove(threadID: String,
                          toFolderID folderID: String,
                          folders: [ThreadFolder]) -> FolderUpdate? {
        guard let targetIndex = folders.firstIndex(where: { $0.id == folderID }) else { return nil }
        var updatedFolders = folders

        // Remove the thread from any existing folder memberships first.
        for index in updatedFolders.indices {
            if updatedFolders[index].threadIDs.contains(threadID) {
                updatedFolders[index].threadIDs.remove(threadID)
            }
        }

        updatedFolders[targetIndex].threadIDs.insert(threadID)
        let membership = folderMembershipMap(for: updatedFolders)
        return FolderUpdate(folders: updatedFolders, membership: membership)
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
            deletedFolderIDs.insert(updatedFolders[folderIndex].id)
            updatedFolders.remove(at: folderIndex)
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
