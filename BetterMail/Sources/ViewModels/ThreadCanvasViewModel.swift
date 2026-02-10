import AppKit
import Combine
import CoreGraphics
import Foundation
import OSLog
import os.signpost

internal struct ThreadSummaryState {
    internal var text: String
    internal var statusMessage: String
    internal var isSummarizing: Bool
}

internal enum OpenInMailTargetingPath: Equatable {
    case messageID
    case filteredFallback
}

internal enum OpenInMailStatus: Equatable {
    case idle
    case searchingMessageID
    case searchingFilteredFallback
    case opened(OpenInMailTargetingPath)
    case notFound
    case failed(String)
}

internal struct OpenInMailState: Equatable {
    internal let messageID: String
    internal let status: OpenInMailStatus
}

internal struct ThreadCanvasScrollRequest: Equatable {
    internal let nodeID: String
    internal let token: UUID
    internal let folderID: String
    internal let boundary: MessageStore.ThreadMessageBoundary
}

internal struct ThreadCanvasJumpExpansionPlan: Equatable {
    internal let targets: [Int]
    internal let reachedRequiredDayCount: Bool
    internal let cappedDayCount: Int
    internal let requiredDayCount: Int
}

internal struct ThreadCanvasVerticalJumpResolution: Equatable {
    internal let desiredY: CGFloat
    internal let clampedY: CGFloat
    internal let maxY: CGFloat
    internal let didClampToBottom: Bool
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

private struct NodeTagInput {
    let nodeID: String
    let subject: String
    let from: String
    let snippet: String
    let fingerprint: String
}

private struct ThreadFolderEdit: Hashable {
    let title: String
    let color: ThreadFolderColor
}

private enum FolderJumpPhase: String {
    case resolvingTarget = "resolving"
    case expandingCoverage = "expanding"
    case awaitingAnchor = "awaiting_anchor"
    case scrolling = "scrolling"
}

private struct PendingFolderJumpScrollContext {
    let folderID: String
    let boundary: MessageStore.ThreadMessageBoundary
    let targetNodeID: String
}

@MainActor
internal final class ThreadCanvasViewModel: ObservableObject {
    private struct TimelineLayoutCacheKey: Hashable {
        let viewMode: ThreadCanvasViewMode
        let dayCount: Int
        let zoomBucket: Int
        let columnWidthBucket: Int
        let dataVersion: Int
        let dayStart: Date
    }

    private struct TimelineTextMeasurementCache {
        struct FontKey: Hashable {
            let fontScaleBucket: Int
            let isUnread: Bool
        }

        struct SummaryKey: Hashable {
            let fontKey: FontKey
            let widthBucket: Int
            let text: String
        }

        struct Assets {
            let summaryFont: NSFont
            let timeFont: NSFont
            let tagFont: NSFont
            let paragraph: NSParagraphStyle
            let timeHeight: CGFloat
            let tagHeight: CGFloat
        }

        private(set) var assetsByKey: [FontKey: Assets] = [:]
        private var summaryHeights: [SummaryKey: CGFloat] = [:]
        private var summaryOrder: [SummaryKey] = []
        private let summaryLimit = 500

        mutating func assets(fontScale: CGFloat, isUnread: Bool) -> Assets {
            let key = FontKey(fontScaleBucket: Self.bucket(fontScale), isUnread: isUnread)
            if let cached = assetsByKey[key] {
                return cached
            }
            let summaryFont = NSFont.systemFont(ofSize: ThreadTimelineLayoutConstants.summaryFontSize(fontScale: fontScale),
                                                weight: isUnread ? .semibold : .regular)
            let timeFont = NSFont.systemFont(ofSize: ThreadTimelineLayoutConstants.timeFontSize(fontScale: fontScale),
                                             weight: .semibold)
            let tagFont = NSFont.systemFont(ofSize: ThreadTimelineLayoutConstants.tagFontSize(fontScale: fontScale),
                                            weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let timeHeight = ceil(timeFont.ascender - timeFont.descender)
            let tagVerticalPadding = ThreadTimelineLayoutConstants.tagVerticalPadding(fontScale: fontScale)
            let tagHeight = ceil((tagFont.ascender - tagFont.descender) + (tagVerticalPadding * 2))
            let assets = Assets(summaryFont: summaryFont,
                                timeFont: timeFont,
                                tagFont: tagFont,
                                paragraph: paragraph,
                                timeHeight: timeHeight,
                                tagHeight: tagHeight)
            assetsByKey[key] = assets
            return assets
        }

        mutating func summaryHeight(text: String,
                                    fontScale: CGFloat,
                                    isUnread: Bool,
                                    availableWidth: CGFloat) -> CGFloat {
            let fontKey = FontKey(fontScaleBucket: Self.bucket(fontScale), isUnread: isUnread)
            let widthBucket = Self.bucket(availableWidth)
            let key = SummaryKey(fontKey: fontKey, widthBucket: widthBucket, text: text)
            if let cached = summaryHeights[key] {
                return cached
            }
            let assets = assets(fontScale: fontScale, isUnread: isUnread)
            let rect = (text as NSString).boundingRect(with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                       attributes: [.font: assets.summaryFont,
                                                                    .paragraphStyle: assets.paragraph])
            let height = ceil(rect.height)
            summaryHeights[key] = height
            summaryOrder.append(key)
            if summaryOrder.count > summaryLimit {
                let trimCount = summaryOrder.count - summaryLimit
                let toRemove = summaryOrder.prefix(trimCount)
                for entry in toRemove {
                    summaryHeights.removeValue(forKey: entry)
                }
                summaryOrder.removeFirst(trimCount)
            }
            return height
        }

        mutating func clear() {
            assetsByKey.removeAll()
            summaryHeights.removeAll()
            summaryOrder.removeAll()
        }

        private static func bucket(_ value: CGFloat) -> Int {
            Int((value * 1000).rounded())
        }
    }

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

    @Published internal private(set) var roots: [ThreadNode] = [] {
        didSet { invalidateLayoutCache() }
    }
    @Published internal private(set) var isRefreshing = false
    @Published internal private(set) var status: String = ""
    @Published internal private(set) var unreadTotal: Int = 0
    @Published internal private(set) var lastRefreshDate: Date?
    @Published internal private(set) var nextRefreshDate: Date?
    @Published internal private(set) var nodeSummaries: [String: ThreadSummaryState] = [:] {
        didSet { invalidateLayoutCache() }
    }
    @Published internal private(set) var folderSummaries: [String: ThreadSummaryState] = [:]
    @Published internal private(set) var expandedSummaryIDs: Set<String> = []
    @Published internal var selectedNodeID: String?
    @Published internal var selectedFolderID: String?
    @Published internal private(set) var selectedNodeIDs: Set<String> = []
    @Published internal private(set) var manualGroupByMessageKey: [String: String] = [:]
    @Published internal private(set) var manualAttachmentMessageIDs: Set<String> = [] {
        didSet { invalidateLayoutCache() }
    }
    @Published internal private(set) var manualGroups: [String: ManualThreadGroup] = [:]
    @Published internal private(set) var jwzThreadMap: [String: String] = [:] {
        didSet { invalidateLayoutCache() }
    }
    @Published internal private(set) var threadFolders: [ThreadFolder] = [] {
        didSet {
            prunePinnedFolderIDs(using: threadFolders)
            invalidateLayoutCache()
        }
    }
    @Published internal private(set) var pinnedFolderIDs: Set<String> = [] {
        didSet { invalidateLayoutCache() }
    }
    @Published private var folderEditsByID: [String: ThreadFolderEdit] = [:] {
        didSet { invalidateLayoutCache() }
    }
    @Published internal private(set) var folderMembershipByThreadID: [String: String] = [:] {
        didSet { invalidateLayoutCache() }
    }
    @Published internal private(set) var openInMailState: OpenInMailState?
    @Published internal private(set) var pendingScrollRequest: ThreadCanvasScrollRequest?
    @Published internal private(set) var dayWindowCount: Int = ThreadCanvasLayoutMetrics.defaultDayCount {
        didSet { invalidateLayoutCache() }
    }
    @Published internal private(set) var visibleDayRange: ClosedRange<Int>?
    @Published internal private(set) var visibleEmptyDayIntervals: [DateInterval] = []
    @Published internal private(set) var timelineTagsByNodeID: [String: [String]] = [:] {
        didSet { invalidateLayoutCache() }
    }
    @Published internal private(set) var visibleRangeHasMessages = false
    @Published internal private(set) var isBackfilling = false
    @Published internal private(set) var folderJumpInProgressIDs: Set<String> = []
    @Published internal var fetchLimit: Int = 10 {
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
    private let tagProvider: EmailTagProviding?
    private let tagProviderID: String
    private let tagAvailabilityMessage: String
    private let settings: AutoRefreshSettings
    private let inspectorSettings: InspectorViewSettings
    private let pinnedFolderSettings: PinnedFolderSettings
    private let backfillService: BatchBackfillServicing
    private let worker: SidebarBackgroundWorker
    private var rethreadTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var nodeSummaryTasks: [String: Task<Void, Never>] = [:]
    private var folderSummaryTasks: [String: Task<Void, Never>] = [:]
    private var timelineTagTasks: [String: Task<Void, Never>] = [:]
    private var timelineTagCacheByNodeID: [String: SummaryCacheEntry] = [:]
    private var nodeSummaryRefreshGeneration = 0
    private let folderSummaryDebounceInterval: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private var didStart = false
    private var openInMailAttemptID = UUID()
    private var shouldForceFullReload = false
    private let dayWindowIncrement = ThreadCanvasLayoutMetrics.defaultDayCount
    private var layoutCacheKey: TimelineLayoutCacheKey?
    private var layoutCache: ThreadCanvasLayout?
    private var layoutCacheVersion = 0
    private var timelineTextMeasurementCache = TimelineTextMeasurementCache()
    private var visibleRangeUpdateTask: Task<Void, Never>?
    private let visibleRangeUpdateThrottleInterval: UInt64 = 50_000_000
    private let dayWindowExpansionCooldown: TimeInterval = 0.35
    private let dayWindowExpansionNearBottomHitThreshold = 2
    private static let timelineVisibleTagLimit = 3
    private let jumpExpansionThrottleInterval: UInt64 = 70_000_000
    private let jumpAnchorRetryInterval: UInt64 = 60_000_000
    private let jumpExpansionMaxDayCount = ThreadCanvasLayoutMetrics.defaultDayCount * 520
    private let jumpExpansionMaxSteps = 18
    private let jumpAnchorResolutionAttempts = 45
    private let jumpScrollTimeoutInterval: UInt64 = 2_500_000_000
    private var folderJumpTasks: [String: Task<Void, Never>] = [:]
    private var coalescedFolderJumpBoundaries: [String: MessageStore.ThreadMessageBoundary] = [:]
    private var jumpPhaseByFolderID: [String: FolderJumpPhase] = [:]
    private var pendingScrollContextByToken: [UUID: PendingFolderJumpScrollContext] = [:]
    private var pendingScrollTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var nearBottomHitCount = 0
    private var lastDayWindowExpansionTime: Date?

    internal init(settings: AutoRefreshSettings,
                  inspectorSettings: InspectorViewSettings,
                  pinnedFolderSettings: PinnedFolderSettings? = nil,
                  store: MessageStore = .shared,
                  client: MailAppleScriptClient = MailAppleScriptClient(),
                  threader: JWZThreader = JWZThreader(),
                  backfillService: BatchBackfillServicing? = nil,
                  summaryCapability: EmailSummaryCapability? = nil,
                  tagCapability: EmailTagCapability? = nil,
                  folderSummaryDebounceInterval: TimeInterval = 30) {
        self.store = store
        self.client = client
        self.threader = threader
        self.settings = settings
        self.inspectorSettings = inspectorSettings
        self.backfillService = backfillService ?? BatchBackfillService(client: client, store: store)
        self.pinnedFolderSettings = pinnedFolderSettings ?? PinnedFolderSettings()
        self.folderSummaryDebounceInterval = folderSummaryDebounceInterval
        let capability = summaryCapability ?? EmailSummaryProviderFactory.makeCapability()
        self.summaryProvider = capability.provider
        self.summaryProviderID = capability.providerID
        self.summaryAvailabilityMessage = capability.statusMessage
        let tagCapability = tagCapability ?? EmailTagProviderFactory.makeCapability()
        self.tagProvider = tagCapability.provider
        self.tagProviderID = tagCapability.providerID
        self.tagAvailabilityMessage = tagCapability.statusMessage
        self.worker = SidebarBackgroundWorker(client: client,
                                              store: store,
                                              threader: threader)
        self.pinnedFolderIDs = self.pinnedFolderSettings.pinnedFolderIDs
        NotificationCenter.default.publisher(for: .manualThreadGroupsReset)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRethread()
            }
            .store(in: &cancellables)
        self.pinnedFolderSettings.$pinnedFolderIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] ids in
                self?.pinnedFolderIDs = ids
            }
            .store(in: &cancellables)
    }

    deinit {
        rethreadTask?.cancel()
        autoRefreshTask?.cancel()
        nodeSummaryTasks.values.forEach { $0.cancel() }
        folderSummaryTasks.values.forEach { $0.cancel() }
        timelineTagTasks.values.forEach { $0.cancel() }
        folderJumpTasks.values.forEach { $0.cancel() }
        pendingScrollTimeoutTasks.values.forEach { $0.cancel() }
    }

    internal func start() {
        guard !didStart else { return }
        didStart = true
        Log.refresh.info("ThreadCanvasViewModel start invoked. didStart=false; kicking off initial load.")
        Task { await loadCachedMessages() }
        refreshNow()
        applyAutoRefreshSettings()
    }

    internal func refreshNow(limit: Int? = nil) {
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

    internal func applyAutoRefreshSettings() {
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
            refreshTimelineTags(for: rethreadResult.roots)
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
                            try await store.deleteSummaries(scope: .emailTag, ids: Array(removedNodeIDs))
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

    internal func summaryState(for nodeID: String) -> ThreadSummaryState? {
        nodeSummaries[nodeID]
    }

    internal func folderSummaryState(for folderID: String) -> ThreadSummaryState? {
        folderSummaries[folderID]
    }

    internal func isFolderPinned(id: String) -> Bool {
        pinnedFolderIDs.contains(id)
    }

    internal func pinFolder(id: String) {
        pinnedFolderSettings.pin(id)
    }

    internal func unpinFolder(id: String) {
        pinnedFolderSettings.unpin(id)
    }

    internal var isSummaryProviderAvailable: Bool {
        summaryProvider != nil
    }

    internal func regenerateNodeSummary(for nodeID: String) {
        guard let summaryProvider else {
            if var state = nodeSummaries[nodeID] {
                state.statusMessage = summaryAvailabilityMessage
                state.isSummarizing = false
                nodeSummaries[nodeID] = state
            }
            return
        }

        nodeSummaryTasks[nodeID]?.cancel()
        nodeSummaries[nodeID] = ThreadSummaryState(text: nodeSummaries[nodeID]?.text ?? "",
                                                   statusMessage: "Summarizing…",
                                                   isSummarizing: true)

        let rootsSnapshot = roots
        let manualAttachmentSnapshot = manualAttachmentMessageIDs
        let snippetLineLimit = inspectorSettings.snippetLineLimit
        let stopPhrases = inspectorSettings.stopPhrases

        nodeSummaryTasks[nodeID] = Task { [weak self] in
            guard let self else { return }
            let inputsByNodeID = await worker.nodeSummaryInputs(for: rootsSnapshot,
                                                                manualAttachmentMessageIDs: manualAttachmentSnapshot,
                                                                snippetLineLimit: snippetLineLimit,
                                                                stopPhrases: stopPhrases)
            guard let input = inputsByNodeID[nodeID] else {
                await MainActor.run {
                    self.finishSummary(for: nodeID, in: \.nodeSummaries)
                }
                return
            }
            do {
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
                    self.updateSummary(for: nodeID,
                                       text: text,
                                       status: "Updated \(timestamp)",
                                       isSummarizing: false,
                                       in: \.nodeSummaries)
                    self.refreshFolderSummaries(for: self.roots, folders: self.threadFolders)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finishSummary(for: nodeID, in: \.nodeSummaries)
                }
            } catch {
                await MainActor.run {
                    self.updateSummary(for: nodeID,
                                       text: self.nodeSummaries[nodeID]?.text ?? "",
                                       status: error.localizedDescription,
                                       isSummarizing: false,
                                       in: \.nodeSummaries)
                }
            }
        }
    }

    internal func regenerateFolderSummary(for folderID: String) {
        guard let summaryProvider else {
            if var state = folderSummaries[folderID] {
                state.statusMessage = summaryAvailabilityMessage
                state.isSummarizing = false
                folderSummaries[folderID] = state
            }
            return
        }

        folderSummaryTasks[folderID]?.cancel()
        folderSummaries[folderID] = ThreadSummaryState(text: folderSummaries[folderID]?.text ?? "",
                                                       statusMessage: "Summarizing…",
                                                       isSummarizing: true)

        folderSummaryTasks[folderID] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let input = try await self.folderSummaryInput(for: folderID) else {
                    await MainActor.run {
                        self.finishSummary(for: folderID, in: \.folderSummaries)
                    }
                    return
                }

                if input.summaryTexts.isEmpty {
                    await MainActor.run {
                        self.updateSummary(for: folderID,
                                           text: self.folderSummaries[folderID]?.text ?? "",
                                           status: "Waiting for email summaries",
                                           isSummarizing: false,
                                           in: \.folderSummaries)
                    }
                    return
                }

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
                    self.updateSummary(for: folderID,
                                       text: text,
                                       status: "Updated \(timestamp)",
                                       isSummarizing: false,
                                       in: \.folderSummaries)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finishSummary(for: folderID, in: \.folderSummaries)
                }
            } catch {
                await MainActor.run {
                    self.updateSummary(for: folderID,
                                       text: self.folderSummaries[folderID]?.text ?? "",
                                       status: error.localizedDescription,
                                       isSummarizing: false,
                                       in: \.folderSummaries)
                }
            }
        }
    }

    internal func rootID(containing nodeID: String) -> String? {
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

    private func refreshTimelineTags(for roots: [ThreadNode]) {
        let rootsSnapshot = roots
        let tagProviderID = tagProviderID
        let providerAvailable = tagProvider != nil
        Task { [weak self] in
            guard let self else { return }
            let inputsByNodeID = Self.tagInputs(for: rootsSnapshot, providerID: tagProviderID)
            let nodeIDs = Array(inputsByNodeID.keys)
            var cachedByID: [String: SummaryCacheEntry] = [:]
            if !nodeIDs.isEmpty {
                do {
                    let cached = try await store.fetchSummaries(scope: .emailTag, ids: nodeIDs)
                    cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.scopeID, $0) })
                } catch {
                    Log.app.error("Failed to load cached timeline tags: \(error.localizedDescription, privacy: .public)")
                }
            }

            await MainActor.run {
                let validNodeIDs = Set(inputsByNodeID.keys)
                for (id, task) in timelineTagTasks where !validNodeIDs.contains(id) {
                    task.cancel()
                    timelineTagTasks.removeValue(forKey: id)
                }
                for id in timelineTagsByNodeID.keys where !validNodeIDs.contains(id) {
                    timelineTagsByNodeID.removeValue(forKey: id)
                }
                for id in timelineTagCacheByNodeID.keys where !validNodeIDs.contains(id) {
                    timelineTagCacheByNodeID.removeValue(forKey: id)
                }

                self.timelineTagCacheByNodeID = cachedByID
                for (nodeID, entry) in cachedByID {
                    guard let input = inputsByNodeID[nodeID] else { continue }
                    let isFresh = entry.fingerprint == input.fingerprint && entry.provider == tagProviderID
                    if isFresh || !providerAvailable {
                        let tags = Self.decodeTagCache(entry.summaryText)
                        if !tags.isEmpty {
                            timelineTagsByNodeID[nodeID] = tags
                        }
                    }
                }
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
                                                                                                    prefix: "Updated"),
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

    private func folderSummaryInput(for folderID: String) async throws -> FolderSummaryInput? {
        let rootsSnapshot = roots
        let foldersSnapshot = threadFolders
        let manualGroupSnapshot = manualGroupByMessageKey
        let jwzThreadSnapshot = jwzThreadMap

        guard let folder = foldersSnapshot.first(where: { $0.id == folderID }) else { return nil }

        let folderNodes = Self.folderNodesByID(roots: rootsSnapshot,
                                               folders: foldersSnapshot,
                                               manualGroupByMessageKey: manualGroupSnapshot,
                                               jwzThreadMap: jwzThreadSnapshot)
        let nodes = folderNodes[folderID] ?? []
        guard !nodes.isEmpty else { return nil }

        let nodeIDs = Set(nodes.map(\.id))
        let cachedNodes = try await store.fetchSummaries(scope: .emailNode, ids: Array(nodeIDs))
        let cachedByID = Dictionary(uniqueKeysWithValues: cachedNodes.map { ($0.scopeID, $0) })

        let sortedNodes = nodes.sorted { $0.message.date > $1.message.date }
        let summaryTexts = sortedNodes.compactMap { node in
            let inMemory = nodeSummaries[node.id]?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let inMemory, !inMemory.isEmpty {
                return inMemory
            }
            let cached = cachedByID[node.id]?.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cached, !cached.isEmpty {
                return cached
            }
            return nil
        }

        let fingerprintEntries = sortedNodes.map { node in
            FolderSummaryFingerprintEntry(nodeID: node.id,
                                          nodeFingerprint: cachedByID[node.id]?.fingerprint ?? "missing")
        }
        let fingerprint = ThreadSummaryFingerprint.makeFolder(nodeEntries: fingerprintEntries)
        return FolderSummaryInput(folderID: folderID,
                                  title: folder.title,
                                  summaryTexts: Array(summaryTexts.prefix(20)),
                                  fingerprint: fingerprint)
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
                                                                                                        prefix: "Updated"),
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

    internal static func folderThreadIDsByFolder(folders: [ThreadFolder]) -> [String: Set<String>] {
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

    internal func isSummaryExpanded(for id: String) -> Bool {
        expandedSummaryIDs.contains(id)
    }

    internal func setSummaryExpanded(_ expanded: Bool, for id: String) {
        if expanded {
            expandedSummaryIDs.insert(id)
        } else {
            expandedSummaryIDs.remove(id)
        }
    }

#if DEBUG
    internal func applyRethreadResultForTesting(roots: [ThreadNode],
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

    internal func selectNode(id: String?) {
        selectNode(id: id, additive: false)
    }

    internal func selectNode(id: String?, additive: Bool) {
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

    internal func selectFolder(id: String?) {
        if let selectedFolderID, selectedFolderID != id {
            clearFolderEdits(id: selectedFolderID)
        }
        if id != nil {
            selectedNodeID = nil
            selectedNodeIDs = []
        }
        selectedFolderID = id
    }

    internal func jumpToLatestNode(in folderID: String) {
        jumpToFolderBoundaryNode(in: folderID, boundary: .newest)
    }

    internal func jumpToFirstNode(in folderID: String) {
        jumpToFolderBoundaryNode(in: folderID, boundary: .oldest)
    }

    internal func isJumpInProgress(for folderID: String) -> Bool {
        folderJumpInProgressIDs.contains(folderID)
    }

    internal func isFolderPinned(id: String) -> Bool {
        pinnedFolderIDs.contains(id)
    }

    internal func pinFolder(id: String) {
        pinnedFolderSettings.pin(id)
    }

    internal func unpinFolder(id: String) {
        pinnedFolderSettings.unpin(id)
    }

    internal func consumeScrollRequest(_ request: ThreadCanvasScrollRequest) {
        guard pendingScrollRequest?.token == request.token else { return }
        pendingScrollRequest = nil
        pendingScrollTimeoutTasks[request.token]?.cancel()
        pendingScrollTimeoutTasks.removeValue(forKey: request.token)
        if let context = pendingScrollContextByToken.removeValue(forKey: request.token) {
            Log.app.info("Folder jump completed. marker=success folderID=\(context.folderID, privacy: .public) boundary=\(String(describing: context.boundary), privacy: .public) scrolledNodeID=\(request.nodeID, privacy: .public)")
            completeFolderJump(folderID: context.folderID)
        }
    }

    internal func cancelPendingScrollRequest(reason: String = "user_scroll") {
        guard let request = pendingScrollRequest else { return }
        pendingScrollRequest = nil
        pendingScrollTimeoutTasks[request.token]?.cancel()
        pendingScrollTimeoutTasks.removeValue(forKey: request.token)
        if let context = pendingScrollContextByToken.removeValue(forKey: request.token) {
            Log.app.info("Folder jump cancelled. marker=cancelled folderID=\(context.folderID, privacy: .public) boundary=\(String(describing: context.boundary), privacy: .public) targetNodeID=\(context.targetNodeID, privacy: .public) reason=\(reason, privacy: .public)")
            completeFolderJump(folderID: context.folderID)
        }
    }

    internal func previewFolderEdits(id: String, title: String, color: ThreadFolderColor) {
        folderEditsByID[id] = ThreadFolderEdit(title: title, color: color)
    }

    internal func clearFolderEdits(id: String) {
        folderEditsByID.removeValue(forKey: id)
    }

    internal func saveFolderEdits(id: String, title: String, color: ThreadFolderColor) {
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

    internal func openMessageInMail(_ node: ThreadNode) {
        let messageID = node.message.messageID
        let attemptID = UUID()
        openInMailAttemptID = attemptID
        setOpenInMailState(.searchingMessageID, messageID: messageID, attemptID: attemptID)
        let metadata = MailControl.OpenMessageMetadata(subject: node.message.subject,
                                                       sender: node.message.from,
                                                       date: node.message.date,
                                                       mailbox: node.message.mailboxID,
                                                       account: node.message.accountName)
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let resolution = try MailControl.resolveTargetingPath(messageID: messageID,
                                                                      metadata: metadata,
                                                                      onMessageIDFailure: { [weak self] in
                                                                          Task { @MainActor in
                                                                              guard let self else { return }
                                                                              self.setOpenInMailState(.searchingFilteredFallback,
                                                                                                      messageID: messageID,
                                                                                                      attemptID: attemptID)
                                                                          }
                                                                      })
                switch resolution {
                case .openedMessageID:
                    Log.appleScript.info("Open in Mail succeeded by Message-ID. messageID=\(messageID, privacy: .public)")
                    await MainActor.run {
                        self.setOpenInMailState(.opened(.messageID),
                                                messageID: messageID,
                                                attemptID: attemptID)
                    }
                case .openedFilteredFallback:
                    Log.appleScript.info("Open in Mail succeeded by filtered fallback. messageID=\(messageID, privacy: .public)")
                    await MainActor.run {
                        self.setOpenInMailState(.opened(.filteredFallback),
                                                messageID: messageID,
                                                attemptID: attemptID)
                    }
                case .notFound:
                    Log.appleScript.info("Open in Mail filtered fallback found no match. messageID=\(messageID, privacy: .public)")
                    await MainActor.run {
                        self.setOpenInMailState(.notFound, messageID: messageID, attemptID: attemptID)
                    }
                }
            } catch {
                Log.appleScript.error("Open in Mail failed. messageID=\(messageID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.setOpenInMailState(.failed(error.localizedDescription),
                                            messageID: messageID,
                                            attemptID: attemptID)
                }
            }
        }
    }

    internal func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func setOpenInMailState(_ status: OpenInMailStatus,
                                    messageID: String,
                                    attemptID: UUID) {
        guard openInMailAttemptID == attemptID else { return }
        openInMailState = OpenInMailState(messageID: messageID, status: status)
    }

    internal func moveThread(threadID: String, toFolderID folderID: String) {
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

    internal func removeThreadFromFolder(threadID: String) {
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

    internal var selectedNode: ThreadNode? {
        Self.node(matching: selectedNodeID, in: roots)
    }

    internal var selectedFolder: ThreadFolder? {
        threadFolders.first { $0.id == selectedFolderID }
    }

    internal func timelineNodes(today: Date = Date(),
                                calendar: Calendar = .current) -> [ThreadNode] {
        Self.timelineNodes(for: roots,
                           dayWindowCount: dayWindowCount,
                           today: today,
                           calendar: calendar)
    }

    internal func timelineTags(for nodeID: String) -> [String] {
        timelineTagsByNodeID[nodeID] ?? []
    }

    internal func requestTimelineTagsIfNeeded(for node: ThreadNode) {
        let input = Self.tagInput(for: node, providerID: tagProviderID)
        let cachedEntry = timelineTagCacheByNodeID[node.id]
        let hasFreshCache = cachedEntry?.fingerprint == input?.fingerprint && cachedEntry?.provider == tagProviderID

        if let cachedEntry {
            let cachedTags = Self.decodeTagCache(cachedEntry.summaryText)
            if timelineTagsByNodeID[node.id] == nil {
                if !cachedTags.isEmpty {
                    timelineTagsByNodeID[node.id] = cachedTags
                }
            }
            if hasFreshCache {
                return
            }
        }

        guard let tagProvider else { return }
        guard let input else { return }
        guard timelineTagTasks[node.id] == nil else { return }

        let request = EmailTagRequest(subject: input.subject,
                                      from: input.from,
                                      snippet: input.snippet)
        guard request.hasContent else { return }

        timelineTagTasks[node.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let tags = try await tagProvider.generateTags(request)
                let entry = SummaryCacheEntry(scope: .emailTag,
                                              scopeID: input.nodeID,
                                              summaryText: Self.encodeTagCache(tags),
                                              generatedAt: Date(),
                                              fingerprint: input.fingerprint,
                                              provider: tagProviderID)
                do {
                    try await store.upsertSummaries([entry])
                } catch {
                    Log.app.error("Failed to persist timeline tag cache: \(error.localizedDescription, privacy: .public)")
                }
                await MainActor.run {
                    self.timelineTagsByNodeID[node.id] = tags
                    self.timelineTagCacheByNodeID[node.id] = entry
                }
            } catch {
                await MainActor.run {
                    if let cachedEntry {
                        let cachedTags = Self.decodeTagCache(cachedEntry.summaryText)
                        if !cachedTags.isEmpty {
                        self.timelineTagsByNodeID[node.id] = cachedTags
                        } else {
                            self.timelineTagsByNodeID[node.id] = []
                        }
                    } else {
                        self.timelineTagsByNodeID[node.id] = []
                    }
                }
            }
            await MainActor.run {
                self.timelineTagTasks[node.id] = nil
            }
        }
    }

    private static func tagInputs(for roots: [ThreadNode],
                                  providerID: String) -> [String: NodeTagInput] {
        var inputs: [String: NodeTagInput] = [:]
        for node in flatten(nodes: roots) {
            if let input = tagInput(for: node, providerID: providerID) {
                inputs[node.id] = input
            }
        }
        return inputs
    }

    private static func tagInput(for node: ThreadNode,
                                 providerID: String) -> NodeTagInput? {
        let subject = normalizedTagText(node.message.subject, maxCharacters: 140)
        let from = normalizedTagText(node.message.from, maxCharacters: 80)
        let snippet = normalizedTagText(node.message.snippet, maxCharacters: 220)
        guard !subject.isEmpty || !from.isEmpty || !snippet.isEmpty else { return nil }
        let fingerprint = ThreadSummaryFingerprint.makeTags(subject: subject,
                                                            from: from,
                                                            snippet: snippet,
                                                            providerID: providerID)
        return NodeTagInput(nodeID: node.id,
                            subject: subject,
                            from: from,
                            snippet: snippet,
                            fingerprint: fingerprint)
    }

    private static func normalizedTagText(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maxCharacters else { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxCharacters)
        return String(collapsed[..<endIndex]) + "…"
    }

    private static func encodeTagCache(_ tags: [String]) -> String {
        if let data = try? JSONEncoder().encode(tags),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return tags.joined(separator: ",")
    }

    private static func decodeTagCache(_ text: String) -> [String] {
        if let data = text.data(using: .utf8),
           let tags = try? JSONDecoder().decode([String].self, from: data) {
            return tags
        }
        return text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    internal func canvasLayout(metrics: ThreadCanvasLayoutMetrics,
                               viewMode: ThreadCanvasViewMode = .default,
                               today: Date = Date(),
                               calendar: Calendar = .current) -> ThreadCanvasLayout {
        let signpostID = OSSignpostID(log: Log.performance)
        os_signpost(.begin, log: Log.performance, name: "CanvasLayout", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Log.performance, name: "CanvasLayout", signpostID: signpostID)
        }
        let dayStart = calendar.startOfDay(for: today)
        let cacheKey = TimelineLayoutCacheKey(viewMode: viewMode,
                                              dayCount: metrics.dayCount,
                                              zoomBucket: Self.zoomCacheBucket(metrics.zoom),
                                              columnWidthBucket: Self.metricsBucket(metrics.columnWidthAdjustment),
                                              dataVersion: layoutCacheVersion,
                                              dayStart: dayStart)
        if let cachedKey = layoutCacheKey,
           cachedKey == cacheKey,
           let cachedLayout = layoutCache {
            os_signpost(.event, log: Log.performance, name: "CanvasLayoutCacheHit")
            return cachedLayout
        }

        let layout = Self.canvasLayout(for: roots,
                                       metrics: metrics,
                                       viewMode: viewMode,
                                       today: today,
                                       calendar: calendar,
                                       manualAttachmentMessageIDs: manualAttachmentMessageIDs,
                                       jwzThreadMap: jwzThreadMap,
                                       folders: effectiveThreadFolders,
                                       pinnedFolderIDs: pinnedFolderIDs,
                                       folderMembershipByThreadID: folderMembershipByThreadID,
                                       nodeSummaries: nodeSummaries,
                                       timelineTagsByNodeID: timelineTagsByNodeID,
                                       measurementCache: &timelineTextMeasurementCache)
        os_signpost(.event, log: Log.performance, name: "CanvasLayoutCacheMiss")
        layoutCacheKey = cacheKey
        layoutCache = layout
        return layout
    }

    internal var canBackfillVisibleRange: Bool {
        !visibleEmptyDayIntervals.isEmpty && !isBackfilling
    }

    internal func scheduleVisibleDayRangeUpdate(scrollOffset: CGFloat,
                                                viewportHeight: CGFloat,
                                                layout: ThreadCanvasLayout,
                                                metrics: ThreadCanvasLayoutMetrics,
                                                today: Date = Date(),
                                                calendar: Calendar = .current,
                                                immediate: Bool = false) {
        os_signpost(.event, log: Log.performance, name: "VisibleRangeSchedule")
        if immediate {
            visibleRangeUpdateTask?.cancel()
            updateVisibleDayRange(scrollOffset: scrollOffset,
                                  viewportHeight: viewportHeight,
                                  layout: layout,
                                  metrics: metrics,
                                  today: today,
                                  calendar: calendar)
            return
        }

        visibleRangeUpdateTask?.cancel()
        let scroll = scrollOffset
        let height = viewportHeight
        let layoutSnapshot = layout
        let metricsSnapshot = metrics
        let todaySnapshot = today
        let calendarSnapshot = calendar
        visibleRangeUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: visibleRangeUpdateThrottleInterval)
            guard !Task.isCancelled else { return }
            os_signpost(.event, log: Log.performance, name: "VisibleRangeScheduleFired")
            self.updateVisibleDayRange(scrollOffset: scroll,
                                       viewportHeight: height,
                                       layout: layoutSnapshot,
                                       metrics: metricsSnapshot,
                                       today: todaySnapshot,
                                       calendar: calendarSnapshot)
        }
    }

    internal func updateVisibleDayRange(scrollOffset: CGFloat,
                                        viewportHeight: CGFloat,
                                        layout: ThreadCanvasLayout,
                                        metrics: ThreadCanvasLayoutMetrics,
                                        today: Date = Date(),
                                        calendar: Calendar = .current) {
        let signpostID = OSSignpostID(log: Log.performance)
        os_signpost(.begin, log: Log.performance, name: "VisibleRangeUpdate", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Log.performance, name: "VisibleRangeUpdate", signpostID: signpostID)
        }
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
        let populatedDays = layout.populatedDayIndices
        let hasMessages = range.map { range in
            range.contains { populatedDays.contains($0) }
        } ?? false
        if visibleRangeHasMessages != hasMessages {
            visibleRangeHasMessages = hasMessages
        }
        let forceExpansion = shouldForceDayWindowExpansion(scrollOffset: scrollOffset,
                                                           viewportHeight: viewportHeight,
                                                           contentHeight: layout.contentSize.height,
                                                           threshold: metrics.dayHeight * 2)
        expandDayWindowIfNeeded(visibleRange: range, forceIncrement: forceExpansion)
    }

    private func invalidateLayoutCache() {
        layoutCacheVersion &+= 1
        layoutCacheKey = nil
        layoutCache = nil
    }

    private static func metricsBucket(_ value: CGFloat) -> Int {
        Int((value * 1000).rounded())
    }

    private static func zoomCacheBucket(_ value: CGFloat) -> Int {
        let bucketStep: CGFloat = 0.025
        return Int((value / bucketStep).rounded())
    }

    internal func backfillVisibleRange(rangeOverride: DateInterval? = nil, limitOverride: Int? = nil) {
        guard !isBackfilling else { return }
        let ranges = rangeOverride.map { [$0] } ?? visibleEmptyDayIntervals
        guard !ranges.isEmpty else { return }
        isBackfilling = true
        status = NSLocalizedString("threadlist.backfill.status.fetching", comment: "Status when backfill begins")
        let limit = max(1, limitOverride ?? fetchLimit)
        let snippetLineLimit = inspectorSettings.snippetLineLimit
        Task { [weak self] in
            guard let self else { return }
            do {
                Log.refresh.info("Backfill requested. ranges=\(ranges, privacy: .public) limit=\(limit, privacy: .public) snippetLineLimit=\(snippetLineLimit, privacy: .public)")
                var fetchedCount = 0
                for range in ranges {
                    let total = try await backfillService.countMessages(in: range, mailbox: "inbox")
                    guard total > 0 else { continue }
                    let result = try await backfillService.runBackfill(range: range,
                                                                       mailbox: "inbox",
                                                                       preferredBatchSize: limit,
                                                                       totalExpected: total,
                                                                       snippetLineLimit: snippetLineLimit) { _ in }
                    fetchedCount += result.fetched
                }
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

    internal var shouldShowSelectionActions: Bool {
        selectedNodeIDs.count >= 1 || hasManualGroupMembershipInSelection
    }

    internal var canGroupSelection: Bool {
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

    internal var canUngroupSelection: Bool {
        hasManualGroupMembershipInSelection
    }

    internal func groupSelectedMessages() {
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

    internal func ungroupSelectedMessages() {
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

    private func prunePinnedFolderIDs(using folders: [ThreadFolder]) {
        let validIDs = Set(folders.map(\.id))
        pinnedFolderSettings.prune(validIDs: validIDs)
    }

    private var effectiveThreadFolders: [ThreadFolder] {
        let baseFolders: [ThreadFolder]
        if folderEditsByID.isEmpty {
            baseFolders = threadFolders
        } else {
            baseFolders = threadFolders.map { folder in
                guard let edit = folderEditsByID[folder.id] else { return folder }
                var updated = folder
                updated.title = edit.title
                updated.color = edit.color
                return updated
            }
        }
        return Self.pinnedFirstFolders(baseFolders, pinnedIDs: pinnedFolderIDs)
    }

    private func shouldForceDayWindowExpansion(scrollOffset: CGFloat,
                                               viewportHeight: CGFloat,
                                               contentHeight: CGFloat,
                                               threshold: CGFloat,
                                               now: Date = Date()) -> Bool {
        let nearBottom = Self.shouldExpandDayWindow(scrollOffset: scrollOffset,
                                                    viewportHeight: viewportHeight,
                                                    contentHeight: contentHeight,
                                                    threshold: threshold)
        if nearBottom {
            nearBottomHitCount += 1
        } else {
            nearBottomHitCount = 0
            return false
        }
        guard nearBottomHitCount >= dayWindowExpansionNearBottomHitThreshold else {
            return false
        }
        if let lastExpansion = lastDayWindowExpansionTime,
           now.timeIntervalSince(lastExpansion) < dayWindowExpansionCooldown {
            return false
        }
        lastDayWindowExpansionTime = now
        nearBottomHitCount = 0
        return true
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
        nearBottomHitCount = 0
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

    internal func addFolderForSelection() {
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

    private func jumpToFolderBoundaryNode(in folderID: String,
                                          boundary: MessageStore.ThreadMessageBoundary) {
        if folderJumpInProgressIDs.contains(folderID) {
            coalescedFolderJumpBoundaries[folderID] = boundary
            Log.app.debug("Coalesced folder jump request. folderID=\(folderID, privacy: .public) boundary=\(String(describing: boundary), privacy: .public)")
            return
        }
        beginFolderJump(folderID: folderID, boundary: boundary)
    }

    private func beginFolderJump(folderID: String,
                                 boundary: MessageStore.ThreadMessageBoundary) {
        folderJumpInProgressIDs.insert(folderID)
        updateJumpPhase(.resolvingTarget, folderID: folderID)
        folderJumpTasks[folderID]?.cancel()
        folderJumpTasks[folderID] = Task { [weak self] in
            guard let self else { return }
            do {
                let threadIDs = folderThreadIDs(for: folderID)
                guard !threadIDs.isEmpty else {
                    Log.app.error("Folder jump failed. marker=resolution-failure folderID=\(folderID, privacy: .public) reason=no-thread-members")
                    completeFolderJump(folderID: folderID)
                    return
                }
                guard let target = try await store.fetchBoundaryMessage(threadIDs: threadIDs,
                                                                        boundary: boundary) else {
                    Log.app.error("Folder jump failed. marker=resolution-failure folderID=\(folderID, privacy: .public) reason=no-boundary-message boundary=\(String(describing: boundary), privacy: .public)")
                    completeFolderJump(folderID: folderID)
                    return
                }

                updateJumpPhase(.expandingCoverage, folderID: folderID)
                let expansion = await expandDayWindow(toInclude: target.date)
                if !expansion.reachedRequiredDayCount {
                    Log.app.error("Folder jump failed. marker=expansion-ceiling folderID=\(folderID, privacy: .public) boundary=\(String(describing: boundary), privacy: .public) requiredDayCount=\(expansion.requiredDayCount, privacy: .public) cappedDayCount=\(expansion.cappedDayCount, privacy: .public)")
                    completeFolderJump(folderID: folderID)
                    return
                }
                guard !Task.isCancelled else {
                    completeFolderJump(folderID: folderID)
                    return
                }

                selectNode(id: target.messageID)
                updateJumpPhase(.awaitingAnchor, folderID: folderID)
                guard let scrollTargetID = await waitForRenderableJumpTargetID(preferredNodeID: target.messageID,
                                                                               folderThreadIDs: threadIDs,
                                                                               boundary: boundary) else {
                    Log.app.error("Folder jump failed. marker=anchor-timeout folderID=\(folderID, privacy: .public) boundary=\(String(describing: boundary), privacy: .public) selectedNodeID=\(target.messageID, privacy: .public)")
                    completeFolderJump(folderID: folderID)
                    return
                }
                guard !Task.isCancelled else {
                    completeFolderJump(folderID: folderID)
                    return
                }

                updateJumpPhase(.scrolling, folderID: folderID)
                if scrollTargetID != target.messageID {
                    Log.app.debug("Folder jump fallback anchor selected. folderID=\(folderID, privacy: .public) boundary=\(String(describing: boundary), privacy: .public) preferredNodeID=\(target.messageID, privacy: .public) fallbackNodeID=\(scrollTargetID, privacy: .public)")
                }
                enqueueScrollRequest(nodeID: scrollTargetID,
                                     folderID: folderID,
                                     boundary: boundary,
                                     selectedBoundaryNodeID: target.messageID)
            } catch {
                Log.app.error("Failed to jump folder boundary node. folderID=\(folderID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                completeFolderJump(folderID: folderID)
            }
        }
    }

    private func folderThreadIDs(for folderID: String) -> Set<String> {
        let map = Self.folderThreadIDsByFolder(folders: effectiveThreadFolders)
        return map[folderID] ?? []
    }

    private func expandDayWindow(toInclude date: Date,
                                 today: Date = Date(),
                                 calendar: Calendar = .current) async -> ThreadCanvasJumpExpansionPlan {
        let startOfToday = calendar.startOfDay(for: today)
        let startOfTarget = calendar.startOfDay(for: date)
        guard let dayDiff = calendar.dateComponents([.day], from: startOfTarget, to: startOfToday).day else {
            return ThreadCanvasJumpExpansionPlan(targets: [],
                                                 reachedRequiredDayCount: false,
                                                 cappedDayCount: dayWindowCount,
                                                 requiredDayCount: dayWindowCount)
        }
        guard dayDiff >= 0 else {
            return ThreadCanvasJumpExpansionPlan(targets: [],
                                                 reachedRequiredDayCount: true,
                                                 cappedDayCount: dayWindowCount,
                                                 requiredDayCount: dayWindowCount)
        }

        let requiredDayCount = dayDiff + 1
        let plan = Self.planJumpExpansionTargets(currentDayCount: dayWindowCount,
                                                 requiredDayCount: requiredDayCount,
                                                 maxDayCount: jumpExpansionMaxDayCount,
                                                 maxSteps: jumpExpansionMaxSteps)
        guard !plan.targets.isEmpty else { return plan }

        for target in plan.targets {
            guard !Task.isCancelled else {
                return ThreadCanvasJumpExpansionPlan(targets: plan.targets,
                                                     reachedRequiredDayCount: false,
                                                     cappedDayCount: dayWindowCount,
                                                     requiredDayCount: plan.requiredDayCount)
            }
            guard target > dayWindowCount else { continue }
            dayWindowCount = target
            scheduleRethread()
            try? await Task.sleep(nanoseconds: jumpExpansionThrottleInterval)
        }
        return plan
    }

    private func waitForRenderableJumpTargetID(preferredNodeID: String,
                                               folderThreadIDs: Set<String>,
                                               boundary: MessageStore.ThreadMessageBoundary) async -> String? {
        var fallbackTargetID: String?
        for attempt in 0..<jumpAnchorResolutionAttempts {
            guard !Task.isCancelled else { return nil }
            let candidates = renderableJumpCandidates(folderThreadIDs: folderThreadIDs)
            if let targetID = Self.resolveRenderableJumpTargetID(preferredNodeID: preferredNodeID,
                                                                 renderableCandidates: candidates,
                                                                 boundary: boundary,
                                                                 allowFallback: false) {
                if attempt > 0 {
                    Log.app.debug("Folder jump preferred anchor became renderable. marker=anchor-ready preferred=true attempt=\(attempt + 1, privacy: .public) nodeID=\(targetID, privacy: .public)")
                }
                return targetID
            }
            fallbackTargetID = Self.resolveRenderableJumpTargetID(preferredNodeID: preferredNodeID,
                                                                  renderableCandidates: candidates,
                                                                  boundary: boundary,
                                                                  allowFallback: true)
            if attempt == 0 || attempt == jumpAnchorResolutionAttempts - 1 {
                Log.app.debug("Folder jump awaiting preferred anchor. marker=anchor-await attempt=\(attempt + 1, privacy: .public) candidateCount=\(candidates.count, privacy: .public) preferredNodeID=\(preferredNodeID, privacy: .public)")
            }
            try? await Task.sleep(nanoseconds: jumpAnchorRetryInterval)
        }
        if let fallbackTargetID {
            Log.app.debug("Folder jump fallback anchor used after preferred timeout. marker=anchor-fallback fallbackNodeID=\(fallbackTargetID, privacy: .public) preferredNodeID=\(preferredNodeID, privacy: .public)")
        }
        return fallbackTargetID
    }

    private func enqueueScrollRequest(nodeID: String,
                                      folderID: String,
                                      boundary: MessageStore.ThreadMessageBoundary,
                                      selectedBoundaryNodeID: String) {
        if let existing = pendingScrollRequest {
            pendingScrollRequest = nil
            pendingScrollTimeoutTasks[existing.token]?.cancel()
            pendingScrollTimeoutTasks.removeValue(forKey: existing.token)
            if let existingContext = pendingScrollContextByToken.removeValue(forKey: existing.token) {
                Log.app.error("Folder jump failed. marker=anchor-timeout folderID=\(existingContext.folderID, privacy: .public) boundary=\(String(describing: existingContext.boundary), privacy: .public) selectedNodeID=\(existingContext.targetNodeID, privacy: .public) reason=request-superseded")
                completeFolderJump(folderID: existingContext.folderID)
            }
        }

        let token = UUID()
        let request = ThreadCanvasScrollRequest(nodeID: nodeID,
                                                token: token,
                                                folderID: folderID,
                                                boundary: boundary)
        pendingScrollRequest = request
        pendingScrollContextByToken[token] = PendingFolderJumpScrollContext(folderID: folderID,
                                                                             boundary: boundary,
                                                                             targetNodeID: selectedBoundaryNodeID)
        pendingScrollTimeoutTasks[token]?.cancel()
        pendingScrollTimeoutTasks[token] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.jumpScrollTimeoutInterval ?? 0)
            await MainActor.run {
                self?.handlePendingScrollTimeout(token: token)
            }
        }
    }

    private func handlePendingScrollTimeout(token: UUID) {
        guard pendingScrollRequest?.token == token else { return }
        pendingScrollRequest = nil
        pendingScrollTimeoutTasks[token]?.cancel()
        pendingScrollTimeoutTasks.removeValue(forKey: token)
        guard let context = pendingScrollContextByToken.removeValue(forKey: token) else { return }
        Log.app.error("Folder jump failed. marker=anchor-timeout folderID=\(context.folderID, privacy: .public) boundary=\(String(describing: context.boundary), privacy: .public) selectedNodeID=\(context.targetNodeID, privacy: .public)")
        completeFolderJump(folderID: context.folderID)
    }

    private func completeFolderJump(folderID: String) {
        folderJumpTasks[folderID]?.cancel()
        folderJumpTasks.removeValue(forKey: folderID)
        folderJumpInProgressIDs.remove(folderID)
        jumpPhaseByFolderID.removeValue(forKey: folderID)
        guard let boundary = coalescedFolderJumpBoundaries.removeValue(forKey: folderID) else { return }
        beginFolderJump(folderID: folderID, boundary: boundary)
    }

    private func updateJumpPhase(_ phase: FolderJumpPhase,
                                 folderID: String) {
        jumpPhaseByFolderID[folderID] = phase
        Log.app.debug("Folder jump phase. folderID=\(folderID, privacy: .public) phase=\(phase.rawValue, privacy: .public)")
    }

    private func renderableJumpCandidates(folderThreadIDs: Set<String>,
                                          today: Date = Date(),
                                          calendar: Calendar = .current) -> [ThreadNode] {
        guard !folderThreadIDs.isEmpty else { return [] }
        return Self.flatten(nodes: roots).filter { node in
            guard let threadID = effectiveThreadID(for: node), folderThreadIDs.contains(threadID) else {
                return false
            }
            return isNodeRenderable(node, today: today, calendar: calendar)
        }
    }

    private func isNodeRenderable(_ node: ThreadNode,
                                  today: Date,
                                  calendar: Calendar) -> Bool {
        ThreadCanvasDateHelper.dayIndex(for: node.message.date,
                                        today: today,
                                        calendar: calendar,
                                        dayCount: dayWindowCount) != nil
    }
}

private extension ThreadCanvasViewModel {
    static func newManualGroupID() -> String {
        "manual-\(UUID().uuidString.lowercased())"
    }
}

extension ThreadCanvasViewModel {
    internal static let verticalJumpScrollTolerance: CGFloat = 1

    internal static func resolvedPreservedJumpX(existingPreservedX: CGFloat?,
                                                currentX: CGFloat) -> CGFloat {
        existingPreservedX ?? currentX
    }

    internal static func resolveVerticalJump(boundary: MessageStore.ThreadMessageBoundary,
                                             targetMinYInScrollContent: CGFloat,
                                             targetMidYInScrollContent: CGFloat,
                                             totalTopPadding: CGFloat,
                                             viewportHeight: CGFloat,
                                             documentHeight: CGFloat,
                                             clipHeight: CGFloat) -> ThreadCanvasVerticalJumpResolution {
        let topVisibilityInset = max(24, totalTopPadding * 0.25)
        let desiredY: CGFloat
        switch boundary {
        case .oldest:
            desiredY = max(targetMinYInScrollContent - topVisibilityInset, 0)
        case .newest:
            desiredY = max(targetMidYInScrollContent - (viewportHeight / 2), 0)
        }

        let maxY = max(documentHeight - clipHeight, 0)
        let clampedY = min(desiredY, maxY)
        let didClampToBottom = desiredY > maxY && abs(clampedY - maxY) <= verticalJumpScrollTolerance

        return ThreadCanvasVerticalJumpResolution(desiredY: desiredY,
                                                  clampedY: clampedY,
                                                  maxY: maxY,
                                                  didClampToBottom: didClampToBottom)
    }

    internal static func shouldConsumeVerticalJump(finalY: CGFloat,
                                                   targetY: CGFloat,
                                                   didClampToBottom: Bool,
                                                   tolerance: CGFloat = verticalJumpScrollTolerance) -> Bool {
        let reachedTarget = abs(finalY - targetY) <= tolerance
        return reachedTarget || didClampToBottom
    }

    internal static func pinnedFirstFolders(_ folders: [ThreadFolder],
                                            pinnedIDs: Set<String>) -> [ThreadFolder] {
        guard !pinnedIDs.isEmpty else { return folders }
        var pinned: [ThreadFolder] = []
        var unpinned: [ThreadFolder] = []
        pinned.reserveCapacity(min(folders.count, pinnedIDs.count))
        unpinned.reserveCapacity(folders.count)
        for folder in folders {
            if pinnedIDs.contains(folder.id) {
                pinned.append(folder)
            } else {
                unpinned.append(folder)
            }
        }
        return pinned + unpinned
    }

    internal static func planJumpExpansionTargets(currentDayCount: Int,
                                                  requiredDayCount: Int,
                                                  dayWindowIncrement: Int = ThreadCanvasLayoutMetrics.defaultDayCount,
                                                  maxDayCount: Int = ThreadCanvasLayoutMetrics.defaultDayCount * 520,
                                                  maxSteps: Int = 18) -> ThreadCanvasJumpExpansionPlan {
        let normalizedCurrent = max(currentDayCount, 1)
        let normalizedRequired = max(requiredDayCount, normalizedCurrent)
        guard normalizedRequired > normalizedCurrent else {
            return ThreadCanvasJumpExpansionPlan(targets: [],
                                                 reachedRequiredDayCount: true,
                                                 cappedDayCount: normalizedCurrent,
                                                 requiredDayCount: normalizedRequired)
        }

        var targets: [Int] = []
        var current = normalizedCurrent
        let cap = max(maxDayCount, normalizedCurrent)

        while current < normalizedRequired && targets.count < maxSteps {
            let remaining = normalizedRequired - current
            let increment = adaptiveJumpExpansionIncrement(remaining: remaining,
                                                           dayWindowIncrement: max(dayWindowIncrement, 1))
            let next = min(current + increment, cap, normalizedRequired)
            guard next > current else { break }
            targets.append(next)
            current = next
        }

        return ThreadCanvasJumpExpansionPlan(targets: targets,
                                             reachedRequiredDayCount: current >= normalizedRequired,
                                             cappedDayCount: current,
                                             requiredDayCount: normalizedRequired)
    }

    internal static func boundaryNodeID(in nodes: [ThreadNode],
                                        boundary: MessageStore.ThreadMessageBoundary) -> String? {
        guard !nodes.isEmpty else { return nil }
        switch boundary {
        case .newest:
            return nodes.max { lhs, rhs in
                if lhs.message.date == rhs.message.date {
                    return lhs.id < rhs.id
                }
                return lhs.message.date < rhs.message.date
            }?.id
        case .oldest:
            return nodes.min { lhs, rhs in
                if lhs.message.date == rhs.message.date {
                    return lhs.id > rhs.id
                }
                return lhs.message.date > rhs.message.date
            }?.id
        }
    }

    internal static func resolveRenderableJumpTargetID(preferredNodeID: String,
                                                       renderableCandidates: [ThreadNode],
                                                       boundary: MessageStore.ThreadMessageBoundary,
                                                       allowFallback: Bool = true) -> String? {
        guard !renderableCandidates.isEmpty else { return nil }
        if renderableCandidates.contains(where: { $0.id == preferredNodeID }) {
            return preferredNodeID
        }
        guard allowFallback else { return nil }
        return boundaryNodeID(in: renderableCandidates, boundary: boundary)
    }

    private static func adaptiveJumpExpansionIncrement(remaining: Int,
                                                       dayWindowIncrement: Int) -> Int {
        switch remaining {
        case let value where value > dayWindowIncrement * 32:
            return dayWindowIncrement * 16
        case let value where value > dayWindowIncrement * 16:
            return dayWindowIncrement * 10
        case let value where value > dayWindowIncrement * 8:
            return dayWindowIncrement * 6
        case let value where value > dayWindowIncrement * 4:
            return dayWindowIncrement * 4
        case let value where value > dayWindowIncrement * 2:
            return dayWindowIncrement * 2
        default:
            return dayWindowIncrement
        }
    }

    internal static func canvasLayout(for roots: [ThreadNode],
                                      metrics: ThreadCanvasLayoutMetrics,
                                      viewMode: ThreadCanvasViewMode = .default,
                                      today: Date,
                                      calendar: Calendar,
                                      manualAttachmentMessageIDs: Set<String> = [],
                                      jwzThreadMap: [String: String] = [:],
                                      folders: [ThreadFolder] = [],
                                      pinnedFolderIDs: Set<String> = [],
                                      folderMembershipByThreadID: [String: String] = [:],
                                      nodeSummaries: [String: ThreadSummaryState] = [:],
                                      timelineTagsByNodeID: [String: [String]] = [:]) -> ThreadCanvasLayout {
        var measurementCache = TimelineTextMeasurementCache()
        return canvasLayout(for: roots,
                            metrics: metrics,
                            viewMode: viewMode,
                            today: today,
                            calendar: calendar,
                            manualAttachmentMessageIDs: manualAttachmentMessageIDs,
                            jwzThreadMap: jwzThreadMap,
                            folders: folders,
                            pinnedFolderIDs: pinnedFolderIDs,
                            folderMembershipByThreadID: folderMembershipByThreadID,
                            nodeSummaries: nodeSummaries,
                            timelineTagsByNodeID: timelineTagsByNodeID,
                            measurementCache: &measurementCache)
    }

    private static func canvasLayout(for roots: [ThreadNode],
                                     metrics: ThreadCanvasLayoutMetrics,
                                     viewMode: ThreadCanvasViewMode = .default,
                                     today: Date,
                                     calendar: Calendar,
                                     manualAttachmentMessageIDs: Set<String> = [],
                                     jwzThreadMap: [String: String] = [:],
                                     folders: [ThreadFolder] = [],
                                     pinnedFolderIDs: Set<String> = [],
                                     folderMembershipByThreadID: [String: String] = [:],
                                     nodeSummaries: [String: ThreadSummaryState] = [:],
                                     timelineTagsByNodeID: [String: [String]] = [:],
                                     measurementCache: inout TimelineTextMeasurementCache) -> ThreadCanvasLayout {
        let dayHeights = dayHeights(for: roots,
                                    metrics: metrics,
                                    viewMode: viewMode,
                                    today: today,
                                    calendar: calendar,
                                    nodeSummaries: nodeSummaries,
                                    timelineTagsByNodeID: timelineTagsByNodeID,
                                    measurementCache: &measurementCache)
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

            var pinnedItems: [(latest: Date, item: OrderingItem)] = []
            var remainingItems: [(latest: Date, item: OrderingItem)] = []
            pinnedItems.reserveCapacity(folderIDs.count)
            remainingItems.reserveCapacity(folderIDs.count + (threadsByFolderID[parentID]?.count ?? 0))

            for folderID in folderIDs {
                let item: OrderingItem = .folder(folderID)
                if pinnedFolderIDs.contains(folderID) {
                    pinnedItems.append((latest: latestDateForFolder(folderID), item: item))
                } else {
                    remainingItems.append((latest: latestDateForFolder(folderID), item: item))
                }
            }

            for thread in threadsByFolderID[parentID] ?? [] {
                remainingItems.append((latest: thread.latestDate, item: .thread(thread)))
            }

            let orderedPinned = pinnedItems.sorted { lhs, rhs in
                lhs.latest > rhs.latest
            }.map(\.item)
            let orderedRemaining = remainingItems.sorted { lhs, rhs in
                lhs.latest > rhs.latest
            }.map(\.item)
            return orderedPinned + orderedRemaining
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
                                            viewMode: viewMode,
                                            today: today,
                                            calendar: calendar,
                                            dayLookup: dayLookup,
                                            manualAttachmentMessageIDs: manualAttachmentMessageIDs,
                                            jwzThreadMap: jwzThreadMap,
                                            nodeSummaries: nodeSummaries,
                                            timelineTagsByNodeID: timelineTagsByNodeID,
                                            measurementCache: &measurementCache)
                    let unreadCount = nodes.reduce(0) { partial, node in
                        partial + (node.message.isUnread ? 1 : 0)
                    }
                    let title = thread.root.message.subject.isEmpty ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing") : thread.root.message.subject
                    let folderID = normalizedMembership[thread.threadID]
                    columns.append(ThreadCanvasColumn(id: thread.threadID,
                                                      title: title,
                                                      xOffset: columnX,
                                                      nodes: nodes,
                                                      unreadCount: unreadCount,
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
        let populatedDayIndices = Set(columns.flatMap { $0.nodes.map(\.dayIndex) })
        return ThreadCanvasLayout(days: days,
                                  columns: columns,
                                  contentSize: CGSize(width: totalWidth, height: totalHeight),
                                  folderOverlays: folderOverlays,
                                  populatedDayIndices: populatedDayIndices)
    }

    internal static func timelineNodes(for roots: [ThreadNode],
                                       dayWindowCount: Int,
                                       today: Date = Date(),
                                       calendar: Calendar = .current) -> [ThreadNode] {
        let clampedDayCount = max(dayWindowCount, 1)
        let allNodes = flatten(nodes: roots)
        let filtered = allNodes.filter { node in
            ThreadCanvasDateHelper.dayIndex(for: node.message.date,
                                            today: today,
                                            calendar: calendar,
                                            dayCount: clampedDayCount) != nil
        }

        return filtered.sorted { lhs, rhs in
            if lhs.message.date == rhs.message.date {
                return lhs.message.messageID > rhs.message.messageID
            }
            return lhs.message.date > rhs.message.date
        }
    }

    internal static func node(matching id: String?, in roots: [ThreadNode]) -> ThreadNode? {
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
                                    viewMode: ThreadCanvasViewMode,
                                    today: Date,
                                    calendar: Calendar,
                                    dayLookup: [Int: ThreadCanvasDay],
                                    manualAttachmentMessageIDs: Set<String>,
                                    jwzThreadMap: [String: String],
                                    nodeSummaries: [String: ThreadSummaryState],
                                    timelineTagsByNodeID: [String: [String]],
                                    measurementCache: inout TimelineTextMeasurementCache) -> [ThreadCanvasNode] {
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
            let dayBaseY = day.yOffset + metrics.nodeVerticalSpacing
            let nodeGap = metrics.nodeVerticalSpacing

            switch viewMode {
            case .timeline:
                var currentYOffset = dayBaseY
                for node in sorted {
                    let nodeHeight = timelineEntryHeight(for: node,
                                                         metrics: metrics,
                                                         summaryState: nodeSummaries[node.id],
                                                         tags: timelineTagsByNodeID[node.id] ?? [],
                                                         measurementCache: &measurementCache)
                    let frame = CGRect(x: columnX + metrics.nodeHorizontalInset,
                                       y: currentYOffset,
                                       width: metrics.nodeWidth,
                                       height: nodeHeight)
                    currentYOffset += nodeHeight + nodeGap
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
            case .default:
                let count = sorted.count
                let usableHeight = max(day.height - metrics.nodeHeight - (metrics.nodeVerticalSpacing * 2), 0)
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

    internal static func rootID(for nodeID: String, in roots: [ThreadNode]) -> String? {
        for root in roots {
            if findNode(in: root, matching: nodeID) != nil {
                return root.id
            }
        }
        return nil
    }

    private static func dayHeights(for roots: [ThreadNode],
                                   metrics: ThreadCanvasLayoutMetrics,
                                   viewMode: ThreadCanvasViewMode,
                                   today: Date,
                                   calendar: Calendar,
                                   nodeSummaries: [String: ThreadSummaryState],
                                   timelineTagsByNodeID: [String: [String]],
                                   measurementCache: inout TimelineTextMeasurementCache) -> [Int: CGFloat] {
        switch viewMode {
        case .timeline:
            return timelineDayHeights(for: roots,
                                      metrics: metrics,
                                      today: today,
                                      calendar: calendar,
                                      nodeSummaries: nodeSummaries,
                                      timelineTagsByNodeID: timelineTagsByNodeID,
                                      measurementCache: &measurementCache)
        case .default:
            return defaultDayHeights(for: roots, metrics: metrics, today: today, calendar: calendar)
        }
    }

    private static func defaultDayHeights(for roots: [ThreadNode],
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
            heights[dayIndex] = max(metrics.dayHeight, requiredDefaultDayHeight(nodeCount: count, metrics: metrics))
        }
        return heights
    }

    private static func requiredDefaultDayHeight(nodeCount: Int, metrics: ThreadCanvasLayoutMetrics) -> CGFloat {
        guard nodeCount > 1 else {
            return metrics.dayHeight
        }
        let nodeGap = metrics.nodeVerticalSpacing
        let maxStep = metrics.nodeHeight + nodeGap
        return metrics.nodeHeight
            + (metrics.nodeVerticalSpacing * 2)
            + CGFloat(nodeCount - 1) * maxStep
    }

    private static func timelineDayHeights(for roots: [ThreadNode],
                                           metrics: ThreadCanvasLayoutMetrics,
                                           today: Date,
                                           calendar: Calendar,
                                           nodeSummaries: [String: ThreadSummaryState],
                                           timelineTagsByNodeID: [String: [String]],
                                           measurementCache: inout TimelineTextMeasurementCache) -> [Int: CGFloat] {
        var maxHeightsByDay: [Int: CGFloat] = [:]
        for root in roots {
            var totalHeightByDay: [Int: CGFloat] = [:]
            var countsByDay: [Int: Int] = [:]
            for node in flatten(node: root) {
                guard let dayIndex = ThreadCanvasDateHelper.dayIndex(for: node.message.date,
                                                                     today: today,
                                                                     calendar: calendar,
                                                                     dayCount: metrics.dayCount) else {
                    continue
                }
                let nodeHeight = timelineEntryHeight(for: node,
                                                     metrics: metrics,
                                                     summaryState: nodeSummaries[node.id],
                                                     tags: timelineTagsByNodeID[node.id] ?? [],
                                                     measurementCache: &measurementCache)
                totalHeightByDay[dayIndex, default: 0] += nodeHeight
                countsByDay[dayIndex, default: 0] += 1
            }

            for (dayIndex, totalHeight) in totalHeightByDay {
                let count = countsByDay[dayIndex, default: 0]
                let gaps = count > 1 ? CGFloat(count - 1) * metrics.nodeVerticalSpacing : 0
                let requiredHeight = (metrics.nodeVerticalSpacing * 2) + totalHeight + gaps
                maxHeightsByDay[dayIndex] = max(maxHeightsByDay[dayIndex, default: 0], requiredHeight)
            }
        }

        var heights: [Int: CGFloat] = [:]
        for dayIndex in 0..<metrics.dayCount {
            let required = maxHeightsByDay[dayIndex, default: 0]
            heights[dayIndex] = max(metrics.dayHeight, required)
        }
        return heights
    }

    private static func timelineEntryHeight(for node: ThreadNode,
                                            metrics: ThreadCanvasLayoutMetrics,
                                            summaryState: ThreadSummaryState?,
                                            tags: [String],
                                            measurementCache: inout TimelineTextMeasurementCache) -> CGFloat {
        let fontScale = metrics.fontScale
        let summaryText = timelineDisplayText(for: node, summaryState: summaryState)
        let isUnread = node.message.isUnread
        let assets = measurementCache.assets(fontScale: fontScale, isUnread: isUnread)

        let dotSize = ThreadTimelineLayoutConstants.dotSize(fontScale: fontScale)
        let elementSpacing = ThreadTimelineLayoutConstants.elementSpacing(fontScale: fontScale)
        let horizontalPadding = ThreadTimelineLayoutConstants.rowHorizontalPadding(fontScale: fontScale)
        let verticalPadding = ThreadTimelineLayoutConstants.rowVerticalPadding(fontScale: fontScale)
        let summarySpacing = ThreadTimelineLayoutConstants.summaryLineSpacing(fontScale: fontScale)
        let visibleTags = tags.prefix(Self.timelineVisibleTagLimit)

        let summaryIndent = dotSize + elementSpacing
        let availableWidth = max(metrics.nodeWidth - (horizontalPadding * 2) - summaryIndent, 40)

        let summaryHeight = measurementCache.summaryHeight(text: summaryText,
                                                           fontScale: fontScale,
                                                           isUnread: isUnread,
                                                           availableWidth: availableWidth)
        let tagHeight = visibleTags.isEmpty ? 0 : assets.tagHeight
        let topLineHeight = max(assets.timeHeight, tagHeight, dotSize)
        let contentHeight = topLineHeight + summarySpacing + summaryHeight

        return contentHeight + (verticalPadding * 2)
    }

    private static func timelineDisplayText(for node: ThreadNode,
                                            summaryState: ThreadSummaryState?) -> String {
        let subject = node.message.subject.isEmpty
            ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing")
            : node.message.subject
        guard let summaryState else { return subject }
        let summaryText = summaryState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryText.isEmpty {
            return summaryText
        }
        let statusText = summaryState.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return statusText.isEmpty ? subject : statusText
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

    internal static func childFolderIDsByParent(folders: [ThreadFolder]) -> [String: [String]] {
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

    internal static func folderMembershipMap(for folders: [ThreadFolder]) -> [String: String] {
        folders.reduce(into: [String: String]()) { result, folder in
            folder.threadIDs.forEach { result[$0] = folder.id }
        }
    }

    internal struct FolderMoveUpdate {
        internal let folders: [ThreadFolder]
        internal let deletedFolderIDs: Set<String>
        internal let membership: [String: String]
    }

    internal struct FolderRemovalUpdate {
        internal let remainingFolders: [ThreadFolder]
        internal let deletedFolderIDs: Set<String>
        internal let membership: [String: String]
    }

    internal static func applyMove(threadID: String,
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

    internal static func applyRemoval(threadID: String,
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

    internal static func visibleDayRange(for layout: ThreadCanvasLayout,
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

    internal static func emptyDayIntervals(for layout: ThreadCanvasLayout,
                                           visibleRange: ClosedRange<Int>?,
                                           today: Date,
                                           calendar: Calendar) -> [DateInterval] {
        guard let visibleRange else { return [] }
        let populatedDays = layout.populatedDayIndices
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

    internal static func shouldExpandDayWindow(scrollOffset: CGFloat,
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
