import AppKit
import Combine
import CoreGraphics
import Foundation
import OSLog
import os.signpost

internal struct ThreadSummaryState: Equatable {
    internal var text: String
    internal var statusMessage: String
    internal var isSummarizing: Bool
}

internal enum OpenInMailTargetingPath: Equatable {
    case filteredFallback
}

internal enum OpenInMailStatus: Equatable {
    case idle
    case searchingFilteredFallback
    case opened(OpenInMailTargetingPath)
    case notFound
    case failed(String)
}

internal struct OpenInMailState: Equatable {
    internal let messageKey: String
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

internal struct FolderMinimapNode: Identifiable, Hashable {
    internal let id: String
    internal let threadID: String
    internal let normalizedX: CGFloat
    internal let normalizedY: CGFloat
}

internal struct FolderMinimapEdge: Hashable {
    internal let sourceID: String
    internal let destinationID: String
}

internal struct FolderMinimapTimeTick: Hashable {
    internal let date: Date
    internal let normalizedY: CGFloat
}

internal struct FolderMinimapModel: Hashable {
    internal let folderID: String
    internal let nodes: [FolderMinimapNode]
    internal let edges: [FolderMinimapEdge]
    internal let newestDate: Date
    internal let oldestDate: Date
    internal let timeTicks: [FolderMinimapTimeTick]
}

internal struct FolderMinimapSourceNode {
    internal let threadID: String
    internal let node: ThreadNode
}

internal struct FolderMinimapViewportSnapshot: Equatable {
    internal let normalizedRectByFolderID: [String: CGRect]
}

private struct DeferredCanvasScrollPublication: Equatable {
    let visibleDayRange: ClosedRange<Int>?
    let visibleEmptyDayIntervals: [DateInterval]
    let visibleRangeHasMessages: Bool
    let minimapViewportSnapshot: FolderMinimapViewportSnapshot
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

private struct MailboxMoveCandidate {
    let nodeID: String
    let message: EmailMessage
    let account: String
    let mailboxPath: String
}

private struct ThreadFolderEdit: Hashable {
    let title: String
    let color: ThreadFolderColor
    let mailboxAccount: String?
    let mailboxPath: String?
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

private struct PendingManualAttachmentMailboxMove {
    let targetMessageKey: String
    let destinationAccount: String
    let destinationPath: String
}

private struct MailboxRecoveryContext {
    let account: String
    let path: String
    let currentMailboxPath: String?
    let currentMailboxAccount: String?
}

private struct RecoveredMailboxDestination {
    let account: String
    let path: String
    let resolution: MailboxPathResolution
}

private enum FolderDestinationRecoveryResult {
    case success(RecoveredMailboxDestination)
    case failure(String)
}

private struct FolderRefreshTarget: Hashable {
    let mailbox: String
    let account: String?
}

private struct FolderRefreshSubjectPlanItem {
    let target: FolderRefreshTarget
    let normalizedSubjects: [String]
    let seedMessages: [EmailMessage]
}

private struct BottomBarMailboxActionStatus {
    let message: String
    let expiresAt: Date
}

private enum MailboxFolderActionError: LocalizedError {
    case noSelection
    case mixedAccounts
    case missingAccount
    case missingFolderName

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return NSLocalizedString("mailbox.action.error.no_selection",
                                     comment: "Error when no messages are selected for mailbox action")
        case .mixedAccounts:
            return NSLocalizedString("mailbox.action.error.mixed_accounts",
                                     comment: "Error when selected messages span multiple accounts")
        case .missingAccount:
            return NSLocalizedString("mailbox.action.error.missing_account",
                                     comment: "Error when no account is available for mailbox action")
        case .missingFolderName:
            return NSLocalizedString("mailbox.action.error.missing_folder_name",
                                     comment: "Error when new mailbox folder name is empty")
        }
    }
}

internal protocol MailCanvasClient: MailMessageFetching {
    func fetchMessages(since date: Date?,
                       limit: Int,
                       mailbox: String,
                       account: String?,
                       snippetLineLimit: Int,
                       profile: MailFetchProfile) async throws -> [EmailMessage]
    func fetchMailboxHierarchy() async throws -> [MailboxFolder]
}

extension MailAppleScriptClient: MailCanvasClient {}

@MainActor
internal final class ThreadCanvasViewModel: ObservableObject {
    internal struct LayoutProfilingSnapshot {
        internal let totalInvalidationCount: Int
        internal let scrollSessionInvalidationCount: Int
        internal let isCanvasScrollActive: Bool
        internal let isAllFoldersScrollActive: Bool
        internal let hasDeferredEnrichmentInvalidation: Bool
    }

    internal struct FolderChromeCacheKey: Hashable {
        internal let viewMode: ThreadCanvasViewMode
        internal let rowPackingMode: ThreadCanvasRowPackingMode
        internal let dayCount: Int
        internal let showsDayAxis: Bool
        internal let zoomBucket: Int
        internal let columnWidthBucket: Int
        internal let textScaleBucket: Int
        internal let structuralVersion: Int
        internal let dayStart: Date
    }

    internal enum MailboxFolderDropPlacement {
        case before
        case after
    }

    internal enum ThreadCanvasRowPackingMode: Hashable {
        case dateBucketed
        case folderAlignedDense
    }

    private struct TimelineLayoutCacheKey: Hashable {
        let viewMode: ThreadCanvasViewMode
        let rowPackingMode: ThreadCanvasRowPackingMode
        let dayCount: Int
        let showsDayAxis: Bool
        let zoomBucket: Int
        let columnWidthBucket: Int
        let structuralVersion: Int
        let enrichmentVersion: Int
        let dayStart: Date
    }

    private enum LayoutInvalidationReason: String {
        case roots
        case nodeSummaries
        case manualAttachmentMessageIDs
        case jwzThreadMap
        case threadFolders
        case pinnedFolderIDs
        case folderEdits
        case folderMembershipByThreadID
        case dayWindowCount
        case timelineTagsByNodeID
        case generic
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
            let mailboxFont: NSFont
            let paragraph: NSParagraphStyle
            let timeHeight: CGFloat
            let tagHeight: CGFloat
            let mailboxHeight: CGFloat
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
            let tagFont = NSFont.systemFont(ofSize: ThreadTimelineLayoutConstants.tagChipFontSize(fontScale: fontScale),
                                            weight: .semibold)
            let mailboxFont = NSFont.systemFont(ofSize: ThreadTimelineLayoutConstants.mailboxChipFontSize(fontScale: fontScale),
                                                weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let timeHeight = ceil(timeFont.ascender - timeFont.descender)
            let tagVerticalPadding = ThreadTimelineLayoutConstants.tagVerticalPadding(fontScale: fontScale)
            let tagHeight = ceil((tagFont.ascender - tagFont.descender) + (tagVerticalPadding * 2))
            let mailboxHeight = ceil((mailboxFont.ascender - mailboxFont.descender) + (tagVerticalPadding * 2))
            let assets = Assets(summaryFont: summaryFont,
                                timeFont: timeFont,
                                tagFont: tagFont,
                                mailboxFont: mailboxFont,
                                paragraph: paragraph,
                                timeHeight: timeHeight,
                                tagHeight: tagHeight,
                                mailboxHeight: mailboxHeight)
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
        private let client: any MailCanvasClient
        private let store: MessageStore
        private let threader: JWZThreader

        init(client: any MailCanvasClient,
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
                            mailbox: String,
                            account: String?,
                            snippetLineLimit: Int) async throws -> RefreshOutcome {
            let fetched = try await client.fetchMessages(since: since,
                                                         limit: effectiveLimit,
                                                         mailbox: mailbox,
                                                         account: account,
                                                         snippetLineLimit: snippetLineLimit,
                                                         profile: .refresh)
            try await store.upsert(messages: fetched)
            let latest = fetched.map(\.date).max()
            return RefreshOutcome(fetchedCount: fetched.count, latestDate: latest)
        }

        func performRethread(cutoffDate: Date?,
                             mailbox: String?,
                             account: String?,
                             includeAllInboxesAliases: Bool,
                             includeThreadIDs: Set<String> = []) async throws -> RethreadOutcome {
            let scopedMessages = try await store.fetchMessages(since: cutoffDate,
                                                               limit: nil,
                                                               mailbox: mailbox,
                                                               account: account,
                                                               includeAllInboxesAliases: includeAllInboxesAliases)
            let messages = try await Self.mergedMessages(scopedMessages,
                                                         includeThreadIDs: includeThreadIDs,
                                                         store: store)
            let baseResult = threader.buildThreads(from: messages)
            let manualGroups = try await store.fetchManualThreadGroups()
            let applied = threader.applyManualGroups(manualGroups, to: baseResult)
            let effectiveGroups = applied.updatedGroups.isEmpty ? manualGroups : applied.updatedGroups
            if !applied.updatedGroups.isEmpty {
                try await store.upsertManualThreadGroups(applied.updatedGroups)
            }
            let updatedResult = applied.result
            try await store.updateThreadMembership(updatedResult.messageThreadMap, threads: updatedResult.threads)
            let storedFolders = try await store.fetchThreadFolders()
            let folders: [ThreadFolder]
            let reconciledFolders = await MainActor.run {
                ThreadCanvasViewModel.reconcileFolderThreadIdentities(folders: storedFolders,
                                                                      roots: updatedResult.roots,
                                                                      jwzThreadMap: updatedResult.jwzThreadMap)
            }
            if let reconciled = reconciledFolders {
                try await store.upsertThreadFolders(reconciled.folders)
                folders = reconciled.folders
            } else {
                folders = storedFolders
            }
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

        private static func mergedMessages(_ scopedMessages: [EmailMessage],
                                           includeThreadIDs: Set<String>,
                                           store: MessageStore) async throws -> [EmailMessage] {
            guard !includeThreadIDs.isEmpty else { return scopedMessages }
            let includedMessages = try await store.fetchMessages(threadIDs: includeThreadIDs)
            guard !includedMessages.isEmpty else { return scopedMessages }
            var messagesByID = Dictionary(uniqueKeysWithValues: scopedMessages.map { ($0.messageID, $0) })
            for message in includedMessages {
                messagesByID[message.messageID] = message
            }
            return messagesByID.values.sorted { lhs, rhs in
                if lhs.date == rhs.date {
                    return lhs.messageID < rhs.messageID
                }
                return lhs.date > rhs.date
            }
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
        didSet {
            invalidateLayoutCache(reason: .roots)
            refreshBottomBarMailboxActionStatusMessage()
        }
    }
    @Published internal var searchQuery: String = "" {
        didSet {
            invalidateLayoutCache(reason: .roots)
        }
    }

    /// Roots filtered by the current search query. Returns all roots when the query is empty.
    internal var filteredRoots: [ThreadNode] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return roots }
        return roots.filter { node in
            node.message.subject.lowercased().contains(query) ||
            node.message.from.lowercased().contains(query) ||
            node.message.snippet.lowercased().contains(query)
        }
    }

    /// Count of threads matching the current search query, nil when no search is active.
    internal var searchResultCount: Int? {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return filteredRoots.count
    }

    @Published internal private(set) var isRefreshing = false
    @Published internal private(set) var refreshProgress: Double?
    @Published internal var activeToast: ToastMessage?
    private var toastDismissTask: Task<Void, Never>?
    @Published internal private(set) var refreshingFolderThreadIDs: Set<String> = []
    @Published internal private(set) var status: String = ""
    @Published internal private(set) var errorMessage: String?
    private var errorDismissTask: Task<Void, Never>?
    @Published internal private(set) var mailboxAccounts: [MailboxAccount] = []
    @Published internal private(set) var activeMailboxScope: MailboxScope = .actionItems
    @Published internal private(set) var isMailboxHierarchyLoading = false
    @Published internal private(set) var mailboxActionStatusMessage: String?
    @Published internal private(set) var bottomBarMailboxActionStatusMessage: String?
    @Published internal private(set) var isMailboxActionRunning = false
    @Published internal private(set) var mailboxActionProgressMessage: String?
    @Published internal private(set) var unreadTotal: Int = 0
    @Published internal private(set) var needsAttentionCount: Int = 0
    @Published internal private(set) var lastRefreshDate: Date?
    @Published internal private(set) var nextRefreshDate: Date?
    @Published internal private(set) var nodeSummaries: [String: ThreadSummaryState] = [:] {
        didSet {
            invalidateLayoutCache(structural: false, enrichment: true, reason: .nodeSummaries)
            reportCollectionMutation(name: "nodeSummaries",
                                     oldCount: oldValue.count,
                                     newCount: nodeSummaries.count)
        }
    }
    @Published internal private(set) var folderSummaries: [String: ThreadSummaryState] = [:] {
        didSet {
            bumpFolderHeaderStateVersion()
            reportCollectionMutation(name: "folderSummaries",
                                     oldCount: oldValue.count,
                                     newCount: folderSummaries.count)
        }
    }
    @Published internal private(set) var expandedSummaryIDs: Set<String> = []
    @Published internal var selectedNodeID: String? {
        didSet { refreshBottomBarMailboxActionStatusMessage() }
    }
    @Published internal var selectedFolderID: String? {
        didSet { bumpFolderHeaderStateVersion() }
    }
    @Published internal private(set) var selectedNodeIDs: Set<String> = [] {
        didSet { refreshBottomBarMailboxActionStatusMessage() }
    }
    @Published internal private(set) var actionItemIDs: Set<String> = []
    @Published internal private(set) var actionItems: [ActionItem] = []
    @Published internal private(set) var manualGroupByMessageKey: [String: String] = [:]
    @Published internal private(set) var manualAttachmentMessageIDs: Set<String> = [] {
        didSet { invalidateLayoutCache(reason: .manualAttachmentMessageIDs) }
    }
    @Published internal private(set) var manualGroups: [String: ManualThreadGroup] = [:]
    @Published internal private(set) var jwzThreadMap: [String: String] = [:] {
        didSet { invalidateLayoutCache(reason: .jwzThreadMap) }
    }
    @Published internal private(set) var threadFolders: [ThreadFolder] = [] {
        didSet {
            prunePinnedFolderIDs(using: threadFolders)
            invalidateLayoutCache(reason: .threadFolders)
        }
    }
    @Published internal private(set) var pinnedFolderIDs: Set<String> = [] {
        didSet {
            bumpFolderHeaderStateVersion()
            invalidateLayoutCache(reason: .pinnedFolderIDs)
        }
    }
    @Published private var folderEditsByID: [String: ThreadFolderEdit] = [:] {
        didSet { invalidateLayoutCache(reason: .folderEdits) }
    }
    @Published internal private(set) var folderMembershipByThreadID: [String: String] = [:] {
        didSet { invalidateLayoutCache(reason: .folderMembershipByThreadID) }
    }
    @Published internal private(set) var openInMailState: OpenInMailState?
    @Published internal private(set) var pendingScrollRequest: ThreadCanvasScrollRequest?
    @Published internal private(set) var dayWindowCount: Int = ThreadCanvasLayoutMetrics.defaultDayCount {
        didSet { invalidateLayoutCache(reason: .dayWindowCount) }
    }
    @Published internal private(set) var visibleDayRange: ClosedRange<Int>?
    @Published internal private(set) var visibleEmptyDayIntervals: [DateInterval] = []

    /// Formatted description of the visible date range for display in the date rail overlay.
    internal var visibleDateRangeDescription: String? {
        guard let range = visibleDayRange else { return nil }
        let calendar = Calendar.current
        let today = Date()
        guard let startDate = calendar.date(byAdding: .day, value: range.lowerBound, to: today),
              let endDate = calendar.date(byAdding: .day, value: range.upperBound, to: today) else {
            return nil
        }
        let formatter = DateFormatter()
        if calendar.component(.year, from: startDate) == calendar.component(.year, from: endDate),
           calendar.component(.year, from: startDate) == calendar.component(.year, from: today) {
            formatter.dateFormat = "MMM d"
            let start = formatter.string(from: startDate)
            let end = formatter.string(from: endDate)
            return start == end ? start : "\(start) – \(end)"
        }
        formatter.dateFormat = "MMM d, yyyy"
        let start = formatter.string(from: startDate)
        let end = formatter.string(from: endDate)
        return start == end ? start : "\(start) – \(end)"
    }
    @Published internal private(set) var timelineTagsByNodeID: [String: [String]] = [:] {
        didSet {
            invalidateLayoutCache(structural: false, enrichment: true, reason: .timelineTagsByNodeID)
            reportCollectionMutation(name: "timelineTagsByNodeID",
                                     oldCount: oldValue.count,
                                     newCount: timelineTagsByNodeID.count)
        }
    }
    @Published internal private(set) var visibleRangeHasMessages = false
    @Published internal private(set) var isBackfilling = false
    @Published internal private(set) var folderJumpInProgressIDs: Set<String> = [] {
        didSet { bumpFolderHeaderStateVersion() }
    }
    @Published internal private(set) var minimapViewportSnapshot = FolderMinimapViewportSnapshot(normalizedRectByFolderID: [:])
    @Published internal private(set) var globalMinimapViewportNormalizedRect: CGRect?
    @Published internal private(set) var globalMinimapFoldersSnapshot: [GlobalMinimapFolder] = []
    @Published internal var fetchLimit: Int = 10 {
        didSet {
            if fetchLimit < 1 {
                fetchLimit = 1
            } else if fetchLimit != oldValue {
                shouldForceFullReload = true
            }
        }
    }

    private static let maximumRefreshFetchCount = 4
    private static let maximumAppleScriptRetryAttempts = 3
    private static let appleScriptRetryDelayNanoseconds: UInt64 = 750_000_000

    private let store: MessageStore
    private let client: any MailCanvasClient
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
    private let mailboxFolderOrderSettings: MailboxFolderOrderSettings
    private let mailboxThreadAutoMoveSettings: MailboxThreadAutoMoveSettings
    private let backfillService: BatchBackfillServicing
    private let worker: SidebarBackgroundWorker
    private var rethreadTask: Task<Void, Never>?
    private var isRethreadRunning = false
    private var hasQueuedRethread = false
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
    private var structuralLayoutVersion = 0
    private var enrichmentLayoutVersion = 0
    private var timelineTextMeasurementCache = TimelineTextMeasurementCache()
    private var visibleRangeUpdateTask: Task<Void, Never>?
    private var canvasScrollStateResetTask: Task<Void, Never>?
    private var allFoldersScrollStateResetTask: Task<Void, Never>?
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
    private var mailboxThreadAutoMoveTask: Task<Void, Never>?
    private var mailboxThreadAutoMovePassPending = false
    private var pendingManualAttachmentMailboxMove: PendingManualAttachmentMailboxMove?
    private let bottomBarMailboxActionStatusLifetime: TimeInterval = 300
    private var bottomBarMailboxActionStatusByThreadID: [String: BottomBarMailboxActionStatus] = [:]
    private var bottomBarMailboxActionStatusExpiryTask: Task<Void, Never>?
    private var nearBottomHitCount = 0
    private var lastDayWindowExpansionTime: Date?
    private var folderHeaderStateVersion = 0
    private var isCanvasScrollActive = false
    private var isAllFoldersScrollActive = false
    private var layoutInvalidationCount = 0
    private var layoutInvalidationCountDuringActiveAllFoldersScroll = 0
    private var hasDeferredEnrichmentLayoutInvalidation = false
    private var deferredEnrichmentInvalidationReasons = Set<LayoutInvalidationReason>()
    private var deferredCanvasScrollPublication: DeferredCanvasScrollPublication?
    private let canvasScrollStateResetInterval: UInt64 = 350_000_000
    private let allFoldersScrollStateResetInterval: UInt64 = 350_000_000

    internal init(settings: AutoRefreshSettings,
                  inspectorSettings: InspectorViewSettings,
                  pinnedFolderSettings: PinnedFolderSettings? = nil,
                  mailboxFolderOrderSettings: MailboxFolderOrderSettings? = nil,
                  mailboxThreadAutoMoveSettings: MailboxThreadAutoMoveSettings? = nil,
                  store: MessageStore = .shared,
                  client: any MailCanvasClient = MailAppleScriptClient(),
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
        self.mailboxFolderOrderSettings = mailboxFolderOrderSettings ?? MailboxFolderOrderSettings()
        self.mailboxThreadAutoMoveSettings = mailboxThreadAutoMoveSettings ?? MailboxThreadAutoMoveSettings()
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
        self.mailboxFolderOrderSettings.$orderedFolderIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyMailboxFolderOrderToPublishedAccounts()
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
        mailboxThreadAutoMoveTask?.cancel()
        bottomBarMailboxActionStatusExpiryTask?.cancel()
        canvasScrollStateResetTask?.cancel()
        allFoldersScrollStateResetTask?.cancel()
    }

    internal func layoutProfilingSnapshot() -> LayoutProfilingSnapshot {
        LayoutProfilingSnapshot(totalInvalidationCount: layoutInvalidationCount,
                                scrollSessionInvalidationCount: layoutInvalidationCountDuringActiveAllFoldersScroll,
                                isCanvasScrollActive: isCanvasScrollActive,
                                isAllFoldersScrollActive: isAllFoldersScrollActive,
                                hasDeferredEnrichmentInvalidation: hasDeferredEnrichmentLayoutInvalidation)
    }

    internal func currentFolderHeaderStateVersion() -> Int {
        folderHeaderStateVersion
    }

    private func bumpFolderHeaderStateVersion() {
        folderHeaderStateVersion &+= 1
    }

    internal func folderChromeCacheKey(metrics: ThreadCanvasLayoutMetrics,
                                       viewMode: ThreadCanvasViewMode = .default,
                                       today: Date = Date(),
                                       calendar: Calendar = .current) -> FolderChromeCacheKey {
        let dayStart = calendar.startOfDay(for: today)
        let rowPackingMode: ThreadCanvasRowPackingMode = activeMailboxScope == .allFolders ? .folderAlignedDense : .dateBucketed
        return FolderChromeCacheKey(viewMode: viewMode,
                                    rowPackingMode: rowPackingMode,
                                    dayCount: metrics.dayCount,
                                    showsDayAxis: metrics.showsDayAxis,
                                    zoomBucket: Self.zoomCacheBucket(metrics.zoom),
                                    columnWidthBucket: Self.metricsBucket(metrics.columnWidthAdjustment),
                                    textScaleBucket: Self.metricsBucket(metrics.textScale),
                                    structuralVersion: structuralLayoutVersion,
                                    dayStart: dayStart)
    }

    internal func noteAllFoldersScrollActivity(rawOffset: CGFloat) {
        guard activeMailboxScope == .allFolders else {
            setAllFoldersScrollActive(false)
            return
        }
        if !isAllFoldersScrollActive {
            layoutInvalidationCountDuringActiveAllFoldersScroll = 0
            setAllFoldersScrollActive(true)
            os_signpost(.event,
                        log: Log.performance,
                        name: "AllFoldersScrollSessionStart",
                        "rawOffset=%.1f totalInvalidations=%{public}d",
                        rawOffset,
                        layoutInvalidationCount)
        }
        allFoldersScrollStateResetTask?.cancel()
        allFoldersScrollStateResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.allFoldersScrollStateResetInterval ?? 0)
            guard let self, !Task.isCancelled else { return }
            self.setAllFoldersScrollActive(false)
        }
    }

    internal func noteCanvasScrollActivity(rawOffset: CGFloat) {
        if !isCanvasScrollActive {
            setCanvasScrollActive(true)
            os_signpost(.event,
                        log: Log.performance,
                        name: "CanvasScrollSessionStart",
                        "scope=%{public}s rawOffset=%.1f",
                        activeMailboxScope == .allFolders ? "allFolders" : "other",
                        rawOffset)
        }
        canvasScrollStateResetTask?.cancel()
        canvasScrollStateResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.canvasScrollStateResetInterval ?? 0)
            guard let self, !Task.isCancelled else { return }
            self.setCanvasScrollActive(false)
        }
    }

    private func setCanvasScrollActive(_ isActive: Bool) {
        guard isCanvasScrollActive != isActive else { return }
        isCanvasScrollActive = isActive
        if !isActive {
            os_signpost(.event,
                        log: Log.performance,
                        name: "CanvasScrollSessionEnd",
                        "scope=%{public}s",
                        activeMailboxScope == .allFolders ? "allFolders" : "other")
            flushDeferredCanvasScrollPublicationIfNeeded()
        }
    }

    private func setAllFoldersScrollActive(_ isActive: Bool) {
        guard isAllFoldersScrollActive != isActive else { return }
        isAllFoldersScrollActive = isActive
        if !isActive {
            os_signpost(.event,
                        log: Log.performance,
                        name: "AllFoldersScrollSessionEnd",
                        "sessionInvalidations=%{public}d totalInvalidations=%{public}d",
                        layoutInvalidationCountDuringActiveAllFoldersScroll,
                        layoutInvalidationCount)
            flushDeferredEnrichmentLayoutInvalidationIfNeeded()
        }
    }

    private var shouldDeferScrollDerivedPublication: Bool {
        isCanvasScrollActive
    }

    private func deferCanvasScrollPublication(visibleDayRange: ClosedRange<Int>?,
                                              visibleEmptyDayIntervals: [DateInterval],
                                              visibleRangeHasMessages: Bool) {
        let nextValue = DeferredCanvasScrollPublication(
            visibleDayRange: visibleDayRange,
            visibleEmptyDayIntervals: visibleEmptyDayIntervals,
            visibleRangeHasMessages: visibleRangeHasMessages,
            minimapViewportSnapshot: deferredCanvasScrollPublication?.minimapViewportSnapshot ?? minimapViewportSnapshot
        )
        guard deferredCanvasScrollPublication != nextValue else { return }
        deferredCanvasScrollPublication = nextValue
        os_signpost(.event,
                    log: Log.performance,
                    name: "CanvasScrollPublicationDeferred",
                    "scope=%{public}s rangeStart=%{public}d rangeEnd=%{public}d emptyIntervals=%{public}d hasMessages=%{public}d viewportFolders=%{public}d",
                    activeMailboxScope == .allFolders ? "allFolders" : "other",
                    visibleDayRange?.lowerBound ?? -1,
                    visibleDayRange?.upperBound ?? -1,
                    visibleEmptyDayIntervals.count,
                    visibleRangeHasMessages ? 1 : 0,
                    nextValue.minimapViewportSnapshot.normalizedRectByFolderID.count)
    }

    private func deferCanvasScrollPublication(minimapViewportSnapshot: FolderMinimapViewportSnapshot) {
        let nextValue = DeferredCanvasScrollPublication(
            visibleDayRange: deferredCanvasScrollPublication?.visibleDayRange ?? visibleDayRange,
            visibleEmptyDayIntervals: deferredCanvasScrollPublication?.visibleEmptyDayIntervals ?? visibleEmptyDayIntervals,
            visibleRangeHasMessages: deferredCanvasScrollPublication?.visibleRangeHasMessages ?? visibleRangeHasMessages,
            minimapViewportSnapshot: minimapViewportSnapshot
        )
        guard deferredCanvasScrollPublication != nextValue else { return }
        deferredCanvasScrollPublication = nextValue
        os_signpost(.event,
                    log: Log.performance,
                    name: "CanvasScrollPublicationDeferred",
                    "scope=%{public}s rangeStart=%{public}d rangeEnd=%{public}d emptyIntervals=%{public}d hasMessages=%{public}d viewportFolders=%{public}d",
                    activeMailboxScope == .allFolders ? "allFolders" : "other",
                    nextValue.visibleDayRange?.lowerBound ?? -1,
                    nextValue.visibleDayRange?.upperBound ?? -1,
                    nextValue.visibleEmptyDayIntervals.count,
                    nextValue.visibleRangeHasMessages ? 1 : 0,
                    minimapViewportSnapshot.normalizedRectByFolderID.count)
    }

    private func flushDeferredCanvasScrollPublicationIfNeeded() {
        guard let deferredCanvasScrollPublication else { return }
        self.deferredCanvasScrollPublication = nil
        if visibleDayRange != deferredCanvasScrollPublication.visibleDayRange {
            visibleDayRange = deferredCanvasScrollPublication.visibleDayRange
        }
        if visibleEmptyDayIntervals != deferredCanvasScrollPublication.visibleEmptyDayIntervals {
            visibleEmptyDayIntervals = deferredCanvasScrollPublication.visibleEmptyDayIntervals
        }
        if visibleRangeHasMessages != deferredCanvasScrollPublication.visibleRangeHasMessages {
            visibleRangeHasMessages = deferredCanvasScrollPublication.visibleRangeHasMessages
        }
        if minimapViewportSnapshot != deferredCanvasScrollPublication.minimapViewportSnapshot {
            minimapViewportSnapshot = deferredCanvasScrollPublication.minimapViewportSnapshot
        }
        os_signpost(.event,
                    log: Log.performance,
                    name: "CanvasDeferredScrollPublicationApplied",
                    "scope=%{public}s rangeStart=%{public}d rangeEnd=%{public}d emptyIntervals=%{public}d hasMessages=%{public}d viewportFolders=%{public}d",
                    activeMailboxScope == .allFolders ? "allFolders" : "other",
                    deferredCanvasScrollPublication.visibleDayRange?.lowerBound ?? -1,
                    deferredCanvasScrollPublication.visibleDayRange?.upperBound ?? -1,
                    deferredCanvasScrollPublication.visibleEmptyDayIntervals.count,
                    deferredCanvasScrollPublication.visibleRangeHasMessages ? 1 : 0,
                    deferredCanvasScrollPublication.minimapViewportSnapshot.normalizedRectByFolderID.count)
    }

    private func reportCollectionMutation(name: String,
                                          oldCount: Int,
                                          newCount: Int) {
        guard activeMailboxScope == .allFolders, isAllFoldersScrollActive else { return }
        os_signpost(.event,
                    log: Log.performance,
                    name: "AllFoldersStateMutation",
                    "collection=%{public}s oldCount=%{public}d newCount=%{public}d totalInvalidations=%{public}d sessionInvalidations=%{public}d",
                    name,
                    oldCount,
                    newCount,
                    layoutInvalidationCount,
                    layoutInvalidationCountDuringActiveAllFoldersScroll)
    }

    internal func start() {
        guard !didStart else { return }
        didStart = true
        Log.refresh.info("ThreadCanvasViewModel start invoked. didStart=false; kicking off initial load.")
        Task { await loadCachedMessages() }
        refreshMailboxHierarchy()
        refreshNow()
        applyAutoRefreshSettings()
        Task { await refreshActionItemIDs() }
    }

    // MARK: - Error Display

    internal func showToast(_ text: String, style: ToastStyle = .info, duration: TimeInterval = 3.0) {
        activeToast = ToastMessage(text: text, style: style, duration: duration)
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.activeToast = nil
            }
        }
    }

    internal func showError(_ message: String) {
        errorMessage = message
        errorDismissTask?.cancel()
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.errorMessage = nil
            }
        }
    }

    internal func dismissError() {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        errorMessage = nil
    }

    internal func refreshNow(limit: Int? = nil) {
        guard !isAnyRefreshRunning else {
            Log.refresh.debug("Refresh skipped because another refresh is in progress.")
            return
        }
        let requestedLimit = max(1, limit ?? fetchLimit)
        let effectiveLimit = min(requestedLimit, Self.maximumRefreshFetchCount)
        isRefreshing = true
        refreshProgress = nil
        status = NSLocalizedString("refresh.status.refreshing", comment: "Status when refresh begins")
        let useFullReload = shouldForceFullReload
        let mailboxTarget = activeMailboxFetchTarget
        let since: Date?
        if useFullReload {
            Log.refresh.info("Forcing full reload due to fetchLimit change.")
            since = nil
        } else {
            since = store.lastSyncDate
        }
        let sinceDisplay = since?.ISO8601Format() ?? "nil"
        Log.refresh.info("Starting refresh. requestedLimit=\(requestedLimit, privacy: .public) effectiveLimit=\(effectiveLimit, privacy: .public) since=\(sinceDisplay, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            do {
                let snippetLineLimit = inspectorSettings.snippetLineLimit
                let outcome = try await self.performRefreshWithRetry(effectiveLimit: effectiveLimit,
                                                                     since: since,
                                                                     mailbox: mailboxTarget.mailbox,
                                                                     account: mailboxTarget.account,
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
                    if Self.isMailboxResolveNotFound(error) {
                        self.status = NSLocalizedString("refresh.status.mailbox_unavailable",
                                                        comment: "Status when selected mailbox scope cannot be resolved in Mail")
                        self.showError(self.status)
                        return
                    }
                    self.status = String.localizedStringWithFormat(
                        NSLocalizedString("refresh.status.failed", comment: "Status when refresh fails"),
                        error.localizedDescription
                    )
                    self.showError(self.status)
                }
            }
            await MainActor.run {
                self.isRefreshing = false
                self.refreshProgress = nil
            }
        }
    }

    private func performRefreshWithRetry(effectiveLimit: Int,
                                         since: Date?,
                                         mailbox: String,
                                         account: String?,
                                         snippetLineLimit: Int,
                                         maxAttempts: Int = ThreadCanvasViewModel.maximumAppleScriptRetryAttempts) async throws -> SidebarBackgroundWorker.RefreshOutcome {
        precondition(maxAttempts > 0)
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await worker.performRefresh(effectiveLimit: effectiveLimit,
                                                       since: since,
                                                       mailbox: mailbox,
                                                       account: account,
                                                       snippetLineLimit: snippetLineLimit)
            } catch {
                lastError = error
                let shouldRetry = attempt < maxAttempts && Self.shouldRetryAppleScriptTimeout(after: error)
                guard shouldRetry else { throw error }
                Log.appleScript.info("Retrying refresh after AppleScript timeout. attempt \(attempt + 1, privacy: .public)/\(maxAttempts, privacy: .public)")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * Self.appleScriptRetryDelayNanoseconds)
            }
        }

        throw lastError ?? NSError(domain: "BetterMail.Refresh", code: -1)
    }

    internal var isAnyRefreshRunning: Bool {
        isRefreshing || !refreshingFolderThreadIDs.isEmpty
    }

    internal func isRefreshingFolderThreads(for folderID: String) -> Bool {
        refreshingFolderThreadIDs.contains(folderID)
    }

    internal func refreshFolderThreads(for folderID: String, limit: Int? = nil) {
        guard !isAnyRefreshRunning else {
            Log.refresh.debug("Folder refresh skipped because another refresh is in progress. folderID=\(folderID, privacy: .public)")
            return
        }

        refreshingFolderThreadIDs.insert(folderID)
        status = NSLocalizedString("threadcanvas.folder.inspector.refresh_threads.status.running",
                                   comment: "Status when refreshing the selected folder threads begins")

        let effectiveLimit = max(1, limit ?? fetchLimit)
        let snippetLineLimit = inspectorSettings.snippetLineLimit
        Task { [weak self] in
            guard let self else { return }
            do {
                let fetchedCount = try await refreshFolderCoverage(folderID: folderID,
                                                                   preferredBatchSize: effectiveLimit,
                                                                   snippetLineLimit: snippetLineLimit)
                let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
                await MainActor.run {
                    self.refreshingFolderThreadIDs.remove(folderID)
                    if fetchedCount > 0 {
                        self.scheduleRethread(delay: 0)
                    }
                    self.lastRefreshDate = Date()
                    self.status = String.localizedStringWithFormat(
                        NSLocalizedString("refresh.status.updated", comment: "Status after refresh completes"),
                        timestamp
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.refreshingFolderThreadIDs.remove(folderID)
                }
            } catch {
                Log.refresh.error("Folder refresh failed. folderID=\(folderID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.refreshingFolderThreadIDs.remove(folderID)
                    self.status = String.localizedStringWithFormat(
                        NSLocalizedString("refresh.status.failed", comment: "Status when refresh fails"),
                        error.localizedDescription
                    )
                    self.showError(self.status)
                }
            }
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
        guard !isRethreadRunning else {
            hasQueuedRethread = true
            Log.refresh.debug("Rethread requested while another pass is running; queuing a follow-up pass.")
            return
        }

        isRethreadRunning = true
        defer {
            isRethreadRunning = false
            if hasQueuedRethread {
                hasQueuedRethread = false
                scheduleRethread(delay: 0)
            }
        }

        do {
            Log.refresh.debug("Beginning rethread from store.")
            let previousNodeIDs = Set(Self.flatten(nodes: self.roots).map(\.id))
            let previousFolderIDs = Set(self.threadFolders.map(\.id))
            let cutoffDate = cachedMessageCutoffDate()
            let storeFilter = activeMailboxStoreFilter
            let includePinnedThreadIDs = try await pinnedThreadIDsToIncludeForRethread()
            let rethreadResult = try await worker.performRethread(cutoffDate: cutoffDate,
                                                                  mailbox: storeFilter.mailbox,
                                                                  account: storeFilter.account,
                                                                  includeAllInboxesAliases: storeFilter.includeAllInboxesAliases,
                                                                  includeThreadIDs: includePinnedThreadIDs)
            self.manualGroupByMessageKey = rethreadResult.manualGroupByMessageKey
            self.manualAttachmentMessageIDs = rethreadResult.manualAttachmentMessageIDs
            self.manualGroups = rethreadResult.manualGroups
            self.jwzThreadMap = rethreadResult.jwzThreadMap
            self.threadFolders = rethreadResult.folders
            self.folderMembershipByThreadID = Self.folderMembershipMap(for: rethreadResult.folders)
            let scopedRoots = Self.rootsForMailboxScope(rethreadResult.roots,
                                                        scope: activeMailboxScope,
                                                        folders: rethreadResult.folders,
                                                        manualGroupByMessageKey: rethreadResult.manualGroupByMessageKey,
                                                        jwzThreadMap: rethreadResult.jwzThreadMap)
            self.roots = scopedRoots
            self.unreadTotal = Self.flatten(nodes: scopedRoots).reduce(0) { partial, node in
                partial + (node.message.isUnread ? 1 : 0)
            }
            let actionItemThreadIDSet = Set(actionItems.map(\.threadID))
            let userAddrs = Self.buildUserAddresses(from: scopedRoots)
            self.needsAttentionCount = Self.computeNeedsAttentionCount(
                roots: scopedRoots,
                actionItemThreadIDs: actionItemThreadIDSet,
                userAddresses: userAddrs,
                now: Date(),
                calendar: Calendar.current
            )
            self.folderEditsByID = [:]
            pruneSelection(using: scopedRoots)
            pruneFolderSelection(using: rethreadResult.folders)
            refreshNodeSummaries(for: scopedRoots)
            refreshTimelineTags(for: scopedRoots)
            refreshFolderSummaries(for: scopedRoots, folders: rethreadResult.folders)
            let currentNodeIDs = Set(Self.flatten(nodes: scopedRoots).map(\.id))
            let removedNodeIDs = previousNodeIDs.subtracting(currentNodeIDs)
            let removedFolderIDs = previousFolderIDs.subtracting(rethreadResult.folders.map(\.id))
            if (activeMailboxScope == .allEmails || activeMailboxScope == .actionItems) && (!removedNodeIDs.isEmpty || !removedFolderIDs.isEmpty) {
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
            Log.refresh.info("Rethread complete. messages=\(rethreadResult.messageCount, privacy: .public) threads=\(rethreadResult.threadCount, privacy: .public) unreadTotal=\(self.unreadTotal, privacy: .public) needsAttention=\(self.needsAttentionCount, privacy: .public)")
            await runPendingManualAttachmentMailboxMoveIfNeeded()
            scheduleMailboxThreadAutoMovePass()
        } catch {
            Log.refresh.error("Rethread failed: \(error.localizedDescription, privacy: .public)")
            status = String.localizedStringWithFormat(
                NSLocalizedString("refresh.status.threading_failed", comment: "Status when threading fails"),
                error.localizedDescription
            )
            showError(status)
        }
    }

    @MainActor
    private func scheduleMailboxThreadAutoMovePass() {
        guard mailboxThreadAutoMoveTask == nil else {
            mailboxThreadAutoMovePassPending = true
            return
        }
        mailboxThreadAutoMoveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.mailboxThreadAutoMoveTask = nil
                if self.mailboxThreadAutoMovePassPending {
                    self.mailboxThreadAutoMovePassPending = false
                    self.scheduleMailboxThreadAutoMovePass()
                }
            }
            await self.runMailboxThreadAutoMovePass()
        }
    }

    @MainActor
    private func runMailboxThreadAutoMovePass() async {
        let rules = mailboxThreadAutoMoveSettings.rules
        guard !rules.isEmpty else { return }
        var shouldForceRefresh = false

        for rule in rules {
            do {
                let messages = try await store.fetchMessages(threadIDs: [rule.threadID])
                guard !messages.isEmpty else { continue }
                guard let recoveredDestination = await recoverMailboxDestination(account: rule.account,
                                                                                path: rule.destinationPath,
                                                                                messages: messages) else {
                    shouldForceRefresh = true
                    continue
                }
                if case .heuristic = recoveredDestination.resolution {
                    mailboxThreadAutoMoveSettings.updateDestination(threadIDs: [rule.threadID],
                                                                    destinationPath: recoveredDestination.path,
                                                                    account: recoveredDestination.account)
                }
                let candidates = mailboxMoveCandidates(from: messages,
                                                       account: recoveredDestination.account,
                                                       destinationPath: recoveredDestination.path)
                guard !candidates.isEmpty else { continue }

                let moveInput = Self.mailboxMoveInput(from: candidates)
                guard moveInput.unresolvedCount == 0,
                      !moveInput.internalTargets.isEmpty else {
                    continue
                }
                let moveResult = try await Self.executeMailboxMove(with: moveInput,
                                                                   destinationPath: recoveredDestination.path,
                                                                   account: recoveredDestination.account)
                let isFullSuccess = moveResult.errorCount == 0 && moveResult.movedCount > 0
                if isFullSuccess {
                    await applyOptimisticMailboxMove(candidates: candidates,
                                                     moveTargets: moveInput.internalTargets,
                                                     resolvedInternalIDsByNodeID: [:],
                                                     destinationPath: recoveredDestination.path,
                                                     destinationAccount: recoveredDestination.account)
                } else {
                    shouldForceRefresh = true
                }
            } catch {
                Log.app.error("Mailbox thread auto-move pass failed: \(error.localizedDescription, privacy: .public)")
                shouldForceRefresh = true
            }
        }

        if shouldForceRefresh {
            shouldForceFullReload = true
            refreshNow()
        }
    }

    internal func summaryState(for nodeID: String) -> ThreadSummaryState? {
        nodeSummaries[nodeID]
    }

    internal func folderSummaryState(for folderID: String) -> ThreadSummaryState? {
        folderSummaries[folderID]
    }

    internal func folderMailboxLeafName(for folderID: String) -> String? {
        let folders = effectiveThreadFolders
        guard let folder = folders.first(where: { $0.id == folderID }),
              let destination = folder.mailboxDestination else {
            return nil
        }
        return MailboxPathFormatter.leafName(from: destination.path)
    }

    internal func folderMailboxLeafNames(for folderIDs: Set<String>) -> [String: String] {
        guard !folderIDs.isEmpty else { return [:] }
        var labelsByFolderID: [String: String] = [:]
        labelsByFolderID.reserveCapacity(folderIDs.count)
        for folder in effectiveThreadFolders where folderIDs.contains(folder.id) {
            guard let destination = folder.mailboxDestination else { continue }
            guard let leafName = MailboxPathFormatter.leafName(from: destination.path),
                  !leafName.isEmpty else { continue }
            labelsByFolderID[folder.id] = leafName
        }
        return labelsByFolderID
    }

    internal func folderMailboxEditingDisabledReason(for folderID: String) -> String? {
        guard let folder = effectiveThreadFolders.first(where: { $0.id == folderID }) else { return nil }
        let accountNames = folderAccountNamesInVisibleRoots(folder)
        if accountNames.count > 1 {
            return NSLocalizedString("threadcanvas.folder.mailbox.mixed_accounts",
                                     comment: "Reason a folder mailbox destination cannot be set for mixed-account folders")
        }
        return nil
    }

    internal func preferredMailboxAccountForFolder(_ folderID: String) -> String? {
        guard let folder = effectiveThreadFolders.first(where: { $0.id == folderID }) else { return nil }
        if let destination = folder.mailboxDestination {
            return destination.account
        }
        let accountNames = folderAccountNamesInVisibleRoots(folder)
        guard accountNames.count == 1 else { return nil }
        return accountNames.first
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
                    self.showError(error.localizedDescription)
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
                    self.showError(error.localizedDescription)
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

    /// Directions for keyboard-based spatial navigation between thread nodes.
    internal enum CanvasNavigationDirection {
        case up, down, left, right
    }

    /// Navigates to the spatially adjacent thread node in the given direction.
    /// Uses the current layout to find the closest neighbor.
    internal func navigateToAdjacentNode(direction: CanvasNavigationDirection,
                                          layout: ThreadCanvasLayout) {
        guard let currentID = selectedNodeID else {
            // If nothing selected, select the first node in the first column
            if let firstNode = layout.columns.first?.nodes.first {
                selectNode(id: firstNode.id)
            }
            return
        }

        // Find current node's column and position
        var currentColumnIndex: Int?
        var currentNodeIndex: Int?
        for (colIdx, column) in layout.columns.enumerated() {
            if let nodeIdx = column.nodes.firstIndex(where: { $0.id == currentID }) {
                currentColumnIndex = colIdx
                currentNodeIndex = nodeIdx
                break
            }
        }

        guard let colIdx = currentColumnIndex, let nodeIdx = currentNodeIndex else { return }
        let column = layout.columns[colIdx]
        let currentNode = column.nodes[nodeIdx]

        switch direction {
        case .up:
            if nodeIdx > 0 {
                selectNode(id: column.nodes[nodeIdx - 1].id)
            }
        case .down:
            if nodeIdx < column.nodes.count - 1 {
                selectNode(id: column.nodes[nodeIdx + 1].id)
            }
        case .left:
            if colIdx > 0 {
                let targetColumn = layout.columns[colIdx - 1]
                if let nearest = Self.nearestNode(to: currentNode.frame.midY, in: targetColumn.nodes) {
                    selectNode(id: nearest.id)
                }
            }
        case .right:
            if colIdx < layout.columns.count - 1 {
                let targetColumn = layout.columns[colIdx + 1]
                if let nearest = Self.nearestNode(to: currentNode.frame.midY, in: targetColumn.nodes) {
                    selectNode(id: nearest.id)
                }
            }
        }
    }

    private static func nearestNode(to targetY: CGFloat,
                                     in nodes: [ThreadCanvasNode]) -> ThreadCanvasNode? {
        nodes.min { abs($0.frame.midY - targetY) < abs($1.frame.midY - targetY) }
    }

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
        selectedFolderID = id
    }

    internal func selectMailboxScope(_ scope: MailboxScope) {
        guard activeMailboxScope != scope else { return }
        activeMailboxScope = scope
        mailboxActionStatusMessage = nil
        bottomBarMailboxActionStatusMessage = nil
        scheduleRethread(delay: 0)
    }

    internal func addActionItem(message: EmailMessage, folderID: String?, tags: [String]) {
        Task { [weak self] in
            guard let self else { return }
            await MessageStore.shared.addActionItem(for: message, folderID: folderID, tags: tags)
            await refreshActionItemIDs()
        }
    }

    internal func removeActionItem(message: EmailMessage) {
        Task { [weak self] in
            guard let self else { return }
            await MessageStore.shared.removeActionItem(for: message)
            await refreshActionItemIDs()
        }
    }

    internal func toggleActionItemDone(_ messageID: String) {
        Task { [weak self] in
            guard let self else { return }
            await MessageStore.shared.toggleActionItemDone(messageID)
            await refreshActionItemIDs()
        }
    }

    private func refreshActionItemIDs() async {
        let fetched = await MessageStore.shared.fetchActionItems()
        actionItems = fetched
        actionItemIDs = Set(fetched.map(\.id))
    }

    private func setBottomBarMailboxActionStatus(_ message: String?,
                                                 forThreadID threadID: String?) {
        guard let threadID else {
            refreshBottomBarMailboxActionStatusMessage()
            return
        }

        if let message {
            bottomBarMailboxActionStatusByThreadID[threadID] = BottomBarMailboxActionStatus(
                message: message,
                expiresAt: Date().addingTimeInterval(bottomBarMailboxActionStatusLifetime)
            )
        } else {
            bottomBarMailboxActionStatusByThreadID.removeValue(forKey: threadID)
        }

        refreshBottomBarMailboxActionStatusMessage()
        scheduleBottomBarMailboxActionStatusExpiryIfNeeded()
    }

    private func refreshBottomBarMailboxActionStatusMessage(referenceDate: Date = Date()) {
        pruneExpiredBottomBarMailboxActionStatuses(referenceDate: referenceDate)
        guard let threadID = selectedThreadIDForBottomBarMailboxActionStatus(),
              let status = bottomBarMailboxActionStatusByThreadID[threadID] else {
            bottomBarMailboxActionStatusMessage = nil
            return
        }
        bottomBarMailboxActionStatusMessage = status.message
    }

    private func selectedThreadIDForBottomBarMailboxActionStatus() -> String? {
        guard let selectedNode else { return nil }
        return effectiveThreadID(for: selectedNode)
    }

    private func pruneExpiredBottomBarMailboxActionStatuses(referenceDate: Date = Date()) {
        bottomBarMailboxActionStatusByThreadID = bottomBarMailboxActionStatusByThreadID.filter {
            $0.value.expiresAt > referenceDate
        }
    }

    private func scheduleBottomBarMailboxActionStatusExpiryIfNeeded() {
        bottomBarMailboxActionStatusExpiryTask?.cancel()
        guard let nextExpiration = bottomBarMailboxActionStatusByThreadID.values.map(\.expiresAt).min() else {
            return
        }

        let delay = max(nextExpiration.timeIntervalSinceNow, 0)
        bottomBarMailboxActionStatusExpiryTask = Task { [weak self] in
            let duration = UInt64(delay * 1_000_000_000)
            if duration > 0 {
                try? await Task.sleep(nanoseconds: duration)
            }
            self?.handleBottomBarMailboxActionStatusExpiry()
        }
    }

    private func handleBottomBarMailboxActionStatusExpiry() {
        refreshBottomBarMailboxActionStatusMessage()
        scheduleBottomBarMailboxActionStatusExpiryIfNeeded()
    }

    internal func setBottomBarMailboxActionStatusForTesting(_ message: String,
                                                            threadID: String,
                                                            expiresAt: Date) {
        bottomBarMailboxActionStatusByThreadID[threadID] = BottomBarMailboxActionStatus(message: message,
                                                                                        expiresAt: expiresAt)
        refreshBottomBarMailboxActionStatusMessage(referenceDate: expiresAt.addingTimeInterval(-1))
        scheduleBottomBarMailboxActionStatusExpiryIfNeeded()
    }

    internal func expireBottomBarMailboxActionStatusesForTesting(referenceDate: Date) {
        refreshBottomBarMailboxActionStatusMessage(referenceDate: referenceDate)
        scheduleBottomBarMailboxActionStatusExpiryIfNeeded()
    }

    internal func refreshMailboxHierarchy(force: Bool = false) {
        if !force, !mailboxAccounts.isEmpty {
            return
        }
        guard !isMailboxHierarchyLoading else { return }
        isMailboxHierarchyLoading = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isMailboxHierarchyLoading = false
                }
            }
            do {
                let folders = try await fetchMailboxHierarchyWithRetry()
                let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)
                Self.logMailboxHierarchyDebug(folders: folders, accounts: accounts)
                await MainActor.run {
                    self.applyMailboxHierarchy(accounts)
                }
            } catch {
                Log.appleScript.error("Failed to fetch mailbox hierarchy: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.mailboxActionStatusMessage = String.localizedStringWithFormat(
                        NSLocalizedString("mailbox.hierarchy.error", comment: "Error when mailbox hierarchy cannot be loaded"),
                        error.localizedDescription
                    )
                }
            }
        }
    }

    @MainActor
    private func applyMailboxHierarchy(_ accounts: [MailboxAccount]) {
        let validFolderIDs = Set(MailboxHierarchyBuilder.folderIDs(in: accounts))
        mailboxFolderOrderSettings.prune(validIDs: validFolderIDs)
        let orderedAccounts = MailboxHierarchyBuilder.applyFolderOrder(mailboxFolderOrderSettings.orderedFolderIDs,
                                                                       to: accounts)
        mailboxAccounts = orderedAccounts

        guard case .mailboxFolder(let account, let path) = activeMailboxScope else {
            mailboxActionStatusMessage = nil
            return
        }

        switch MailboxHierarchyBuilder.resolveMailboxPath(account: account, path: path, in: orderedAccounts) {
        case .exact:
            mailboxActionStatusMessage = nil
        case .heuristic(let choice):
            activeMailboxScope = .mailboxFolder(account: choice.account, path: choice.path)
            mailboxActionStatusMessage = String.localizedStringWithFormat(
                NSLocalizedString("mailbox.hierarchy.selected_scope_remapped",
                                  comment: "Status when selected mailbox scope was remapped after rename"),
                account,
                path,
                choice.path
            )
            scheduleRethread(delay: 0)
        case .missing, .ambiguous:
            activeMailboxScope = .allEmails
            mailboxActionStatusMessage = String.localizedStringWithFormat(
                NSLocalizedString("mailbox.hierarchy.selected_scope_fallback_all_emails",
                                  comment: "Status when selected mailbox scope is missing and app falls back to All Emails"),
                account,
                path
            )
            scheduleRethread(delay: 0)
        }
    }

#if DEBUG
    internal func applyMailboxHierarchyForTesting(_ accounts: [MailboxAccount]) {
        applyMailboxHierarchy(accounts)
    }
#endif

    private func fetchMailboxHierarchyWithRetry(maxAttempts: Int = 3) async throws -> [MailboxFolder] {
        precondition(maxAttempts > 0)
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await client.fetchMailboxHierarchy()
            } catch {
                lastError = error
                let shouldRetry = attempt < maxAttempts && Self.shouldRetryAppleScriptTimeout(after: error)
                guard shouldRetry else { throw error }
                Log.appleScript.info("Retrying mailbox hierarchy fetch after timeout. attempt \(attempt + 1, privacy: .public)/\(maxAttempts, privacy: .public)")
                let delayNanoseconds = UInt64(attempt) * Self.appleScriptRetryDelayNanoseconds
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        throw lastError ?? NSError(domain: "BetterMail.MailboxHierarchy", code: -1)
    }

    private static func logMailboxHierarchyDebug(folders: [MailboxFolder], accounts: [MailboxAccount]) {
        let maxRows = 250
        let total = folders.count
        let shown = min(total, maxRows)
        let header = "Mailbox hierarchy fetched. folders=\(total) accounts=\(accounts.count)"

        let rowLines = folders.prefix(maxRows).enumerated().map { index, folder in
            let parent = folder.parentPath ?? "<nil>"
            let inferredParent = inferredParentPathForDebug(from: folder.path) ?? "<nil>"
            return "[\(index)] account='\(folder.account)' name='\(folder.name)' path='\(folder.path)' parentPath='\(parent)' inferredParent='\(inferredParent)'"
        }

        var treeLines: [String] = []
        for account in accounts {
            treeLines.append("account '\(account.name)'")
            treeLines.append(contentsOf: debugTreeLines(nodes: account.folders, depth: 1))
        }

        var summary = "\(header)\n-- raw rows (\(shown)/\(total)) --\n"
        summary += rowLines.joined(separator: "\n")
        if total > shown {
            summary += "\n... \(total - shown) more rows omitted ..."
        }
        summary += "\n-- built tree --\n"
        summary += treeLines.joined(separator: "\n")

        Log.appleScript.debug("\(summary, privacy: .public)")
#if DEBUG
        print(summary)
#endif
    }

    private static func debugTreeLines(nodes: [MailboxFolderNode], depth: Int) -> [String] {
        var lines: [String] = []
        for node in nodes {
            let indent = String(repeating: "  ", count: max(depth, 0))
            lines.append("\(indent)- \(node.name) [path='\(node.path)']")
            lines.append(contentsOf: debugTreeLines(nodes: node.children, depth: depth + 1))
        }
        return lines
    }

    private static func inferredParentPathForDebug(from path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for delimiter in ["/", ".", ":"] {
            guard let index = trimmed.lastIndex(of: Character(delimiter)) else { continue }
            let candidate = String(trimmed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }
        return nil
    }

    private static func shouldRetryAppleScriptTimeout(after error: Error) -> Bool {
        NSAppleScriptRunner.isTimeoutError(error)
    }

    private static func isMailboxResolveNotFound(_ error: Error) -> Bool {
        if let code = MailControl.appleScriptErrorCode(from: error) {
            return code == -1728
        }
        return false
    }

    internal var mailboxActionAccountNames: [String] {
        mailboxAccounts.map(\.name)
    }

    internal func canReorderMailboxFolder(sourceID: String,
                                          targetAccount: String,
                                          targetParentPath: String?) -> Bool {
        siblingFolderIDs(account: targetAccount, parentPath: targetParentPath).contains(sourceID)
    }

    internal func mailboxNeighborFolderIDs(account: String,
                                           path: String,
                                           parentPath: String?) -> (previousID: String?, nextID: String?) {
        let siblings = siblingFolderIDs(account: account, parentPath: parentPath)
        let currentID = mailboxFolderID(account: account, path: path)
        guard let index = siblings.firstIndex(of: currentID) else {
            return (nil, nil)
        }
        let previousID = index > 0 ? siblings[index - 1] : nil
        let nextID = (index + 1) < siblings.count ? siblings[index + 1] : nil
        return (previousID, nextID)
    }

    internal func reorderMailboxFolder(sourceID: String,
                                       targetAccount: String,
                                       targetPath: String,
                                       targetParentPath: String?,
                                       placement: MailboxFolderDropPlacement) {
        let targetID = mailboxFolderID(account: targetAccount, path: targetPath)
        let siblingIDs = siblingFolderIDs(account: targetAccount, parentPath: targetParentPath)
        mailboxFolderOrderSettings.moveRelativeToTarget(sourceID: sourceID,
                                                        targetID: targetID,
                                                        siblingIDs: siblingIDs,
                                                        insertAfterTarget: placement == .after)
        applyMailboxFolderOrderToPublishedAccounts()
    }

    internal func mailboxFolderChoices(for account: String) -> [MailboxFolderChoice] {
        guard let mailboxAccount = mailboxAccounts.first(where: { $0.name == account }) else { return [] }
        return MailboxHierarchyBuilder.folderChoices(for: mailboxAccount)
    }

    private func applyMailboxFolderOrderToPublishedAccounts() {
        mailboxAccounts = MailboxHierarchyBuilder.applyFolderOrder(mailboxFolderOrderSettings.orderedFolderIDs,
                                                                   to: mailboxAccounts)
    }

    private func siblingFolderIDs(account: String, parentPath: String?) -> [String] {
        guard let mailboxAccount = mailboxAccounts.first(where: { $0.name == account }) else { return [] }
        guard let parentPath else {
            return mailboxAccount.folders.map(\.id)
        }
        return childFolderIDs(in: mailboxAccount.folders, parentPath: parentPath)
    }

    private func childFolderIDs(in nodes: [MailboxFolderNode], parentPath: String) -> [String] {
        for node in nodes {
            if node.path == parentPath {
                return node.children.map(\.id)
            }
            let nested = childFolderIDs(in: node.children, parentPath: parentPath)
            if !nested.isEmpty {
                return nested
            }
        }
        return []
    }

    private func mailboxFolderID(account: String, path: String) -> String {
        "\(account)|\(path)"
    }

    internal var mailboxActionSelectionAccount: String? {
        selectedAccountNameForMailboxActions()
    }

    internal var mailboxActionDisabledReason: String? {
        guard !selectedNodes(in: roots).isEmpty else {
            return NSLocalizedString("mailbox.action.error.no_selection",
                                     comment: "Error when no messages are selected for mailbox action")
        }
        let accounts = mailboxActionAccountSet()
        if accounts.count > 1 {
            return NSLocalizedString("mailbox.action.error.mixed_accounts",
                                     comment: "Error when selected messages span multiple accounts")
        }
        if accounts.isEmpty && mailboxActionAccountNames.isEmpty {
            return NSLocalizedString("mailbox.action.error.missing_account",
                                     comment: "Error when no account is available for mailbox action")
        }
        return nil
    }

    internal var canMoveSelectionToMailboxFolder: Bool {
        mailboxActionDisabledReason == nil
    }

    internal func moveSelectionToMailboxFolder(path: String, in account: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        let bottomBarThreadID = selectedThreadIDForBottomBarMailboxActionStatus()
        let selectedAccounts = mailboxActionAccountSet()
        if selectedAccounts.count > 1 {
            mailboxActionStatusMessage = MailboxFolderActionError.mixedAccounts.localizedDescription
            setBottomBarMailboxActionStatus(mailboxActionStatusMessage, forThreadID: bottomBarThreadID)
            return
        }
        if let selectedAccount = selectedAccounts.first, selectedAccount != account {
            mailboxActionStatusMessage = MailboxFolderActionError.mixedAccounts.localizedDescription
            setBottomBarMailboxActionStatus(mailboxActionStatusMessage, forThreadID: bottomBarThreadID)
            return
        }
        let selectedNodes = selectedNodes(in: roots)
        guard !selectedNodes.isEmpty else {
            mailboxActionStatusMessage = MailboxFolderActionError.noSelection.localizedDescription
            setBottomBarMailboxActionStatus(mailboxActionStatusMessage, forThreadID: bottomBarThreadID)
            return
        }

        isMailboxActionRunning = true
        mailboxActionStatusMessage = nil
        setBottomBarMailboxActionStatus(nil, forThreadID: bottomBarThreadID)
        mailboxActionProgressMessage = NSLocalizedString("mailbox.action.progress.move",
                                                         comment: "Status while moving messages to mailbox folder")
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let scope = try await self.mailboxMoveScopeForSelection(selectedNodes: selectedNodes,
                                                                        account: account,
                                                                        destinationPath: trimmedPath)
                let sourceMailboxes = Set(scope.candidates.map { $0.mailboxPath }).sorted()
                await MainActor.run {
                    Log.appleScript.debug("Mailbox move requested. destination=\(trimmedPath, privacy: .public) account=\(account, privacy: .public) selectedCount=\(selectedNodes.count, privacy: .public) candidateCount=\(scope.candidates.count, privacy: .public) sourceMailboxes=\(sourceMailboxes.joined(separator: ","), privacy: .public)")
                }

                if scope.candidates.isEmpty {
                    await self.persistSingleThreadFolderMailboxDestinations(threadIDs: scope.threadIDs,
                                                                           destinationPath: trimmedPath,
                                                                           account: account)
                    await MainActor.run {
                        self.isMailboxActionRunning = false
                        self.mailboxActionProgressMessage = nil
                        self.mailboxActionStatusMessage = NSLocalizedString("mailbox.action.move.summary.no_candidates",
                                                                            comment: "Status when all thread messages are already in destination mailbox")
                        self.setBottomBarMailboxActionStatus(self.mailboxActionStatusMessage,
                                                             forThreadID: bottomBarThreadID)
                        self.upsertMailboxThreadMoveRules(threadIDs: scope.threadIDs,
                                                          destinationPath: trimmedPath,
                                                          account: account)
                    }
                    return
                }
                let moveInput = Self.mailboxMoveInput(from: scope.candidates)
                let ambiguousCount = 0
                let unresolvedCount = moveInput.unresolvedCount
                guard unresolvedCount == 0,
                      !moveInput.internalTargets.isEmpty else {
                    await MainActor.run {
                        self.isMailboxActionRunning = false
                        self.mailboxActionProgressMessage = nil
                        self.mailboxActionStatusMessage = Self.mailboxMoveBlockedStatusMessage(ambiguousCount: ambiguousCount,
                                                                                                unresolvedCount: unresolvedCount)
                        self.setBottomBarMailboxActionStatus(self.mailboxActionStatusMessage,
                                                             forThreadID: bottomBarThreadID)
                    }
                    return
                }

                let moveResult = try await Self.executeMailboxMove(with: moveInput,
                                                                   destinationPath: trimmedPath,
                                                                   account: account)
                let isFullSuccess = moveResult.errorCount == 0 && moveResult.movedCount > 0
                if isFullSuccess {
                    await self.applyOptimisticMailboxMove(candidates: scope.candidates,
                                                          moveTargets: moveInput.internalTargets,
                                                          resolvedInternalIDsByNodeID: [:],
                                                          destinationPath: trimmedPath,
                                                          destinationAccount: account)
                }
                await MainActor.run {
                    self.isMailboxActionRunning = false
                    self.mailboxActionProgressMessage = nil
                    self.mailboxActionStatusMessage = Self.mailboxMoveStatusMessage(moveResult: moveResult,
                                                                                     ambiguousCount: ambiguousCount,
                                                                                     unresolvedCount: unresolvedCount)
                    self.setBottomBarMailboxActionStatus(self.mailboxActionStatusMessage,
                                                         forThreadID: bottomBarThreadID)
                    if isFullSuccess {
                        self.upsertMailboxThreadMoveRules(threadIDs: scope.threadIDs,
                                                          destinationPath: trimmedPath,
                                                          account: account)
                        // Optimistic mailbox updates already patched local state. Avoid
                        // forcing a full refresh here so thread-folder membership does not
                        // disappear due to partial re-fetch windows.
                        self.scheduleRethread(delay: 0)
                    } else {
                        self.shouldForceFullReload = true
                        self.refreshNow()
                    }
                }
                if isFullSuccess {
                    await self.persistSingleThreadFolderMailboxDestinations(threadIDs: scope.threadIDs,
                                                                           destinationPath: trimmedPath,
                                                                           account: account)
                }
            } catch {
                await MainActor.run {
                    self.isMailboxActionRunning = false
                    self.mailboxActionProgressMessage = nil
                    self.mailboxActionStatusMessage = Self.mailboxMoveFailureMessage(for: error)
                    self.setBottomBarMailboxActionStatus(self.mailboxActionStatusMessage,
                                                         forThreadID: bottomBarThreadID)
                    if let msg = self.mailboxActionStatusMessage {
                        self.showError(msg)
                    }
                }
            }
        }
    }

    internal func createMailboxFolderAndMoveSelection(name: String,
                                                      in account: String,
                                                      parentPath: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bottomBarThreadID = selectedThreadIDForBottomBarMailboxActionStatus()
        guard !trimmedName.isEmpty else {
            mailboxActionStatusMessage = MailboxFolderActionError.missingFolderName.localizedDescription
            setBottomBarMailboxActionStatus(mailboxActionStatusMessage, forThreadID: bottomBarThreadID)
            return
        }
        let selectedAccounts = mailboxActionAccountSet()
        if selectedAccounts.count > 1 {
            mailboxActionStatusMessage = MailboxFolderActionError.mixedAccounts.localizedDescription
            setBottomBarMailboxActionStatus(mailboxActionStatusMessage, forThreadID: bottomBarThreadID)
            return
        }
        if let selectedAccount = selectedAccounts.first, selectedAccount != account {
            mailboxActionStatusMessage = MailboxFolderActionError.mixedAccounts.localizedDescription
            setBottomBarMailboxActionStatus(mailboxActionStatusMessage, forThreadID: bottomBarThreadID)
            return
        }
        let selectedNodes = selectedNodes(in: roots)
        guard !selectedNodes.isEmpty else {
            mailboxActionStatusMessage = MailboxFolderActionError.noSelection.localizedDescription
            setBottomBarMailboxActionStatus(mailboxActionStatusMessage, forThreadID: bottomBarThreadID)
            return
        }

        isMailboxActionRunning = true
        mailboxActionStatusMessage = nil
        setBottomBarMailboxActionStatus(nil, forThreadID: bottomBarThreadID)
        mailboxActionProgressMessage = NSLocalizedString("mailbox.action.progress.create_and_move",
                                                         comment: "Status while creating mailbox and moving messages")
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let destinationPath = try await MailControl.createMailbox(named: trimmedName,
                                                                          in: account,
                                                                          parentPath: parentPath)
                let scope = try await self.mailboxMoveScopeForSelection(selectedNodes: selectedNodes,
                                                                        account: account,
                                                                        destinationPath: destinationPath)
                let sourceMailboxes = Set(scope.candidates.map { $0.mailboxPath }).sorted()
                await MainActor.run {
                    Log.appleScript.debug("Mailbox create-and-move requested. destination=\(destinationPath, privacy: .public) account=\(account, privacy: .public) selectedCount=\(selectedNodes.count, privacy: .public) candidateCount=\(scope.candidates.count, privacy: .public) sourceMailboxes=\(sourceMailboxes.joined(separator: ","), privacy: .public)")
                }

                if scope.candidates.isEmpty {
                    await self.persistSingleThreadFolderMailboxDestinations(threadIDs: scope.threadIDs,
                                                                           destinationPath: destinationPath,
                                                                           account: account)
                    await MainActor.run {
                        self.isMailboxActionRunning = false
                        self.mailboxActionProgressMessage = nil
                        self.mailboxActionStatusMessage = NSLocalizedString("mailbox.action.create_and_move.summary.no_candidates",
                                                                            comment: "Status when folder is created and thread messages already live in destination mailbox")
                        self.setBottomBarMailboxActionStatus(self.mailboxActionStatusMessage,
                                                             forThreadID: bottomBarThreadID)
                        self.upsertMailboxThreadMoveRules(threadIDs: scope.threadIDs,
                                                          destinationPath: destinationPath,
                                                          account: account)
                        self.refreshMailboxHierarchy(force: true)
                        self.scheduleRethread(delay: 0)
                    }
                    return
                }
                let moveInput = Self.mailboxMoveInput(from: scope.candidates)
                let ambiguousCount = 0
                let unresolvedCount = moveInput.unresolvedCount
                guard unresolvedCount == 0,
                      !moveInput.internalTargets.isEmpty else {
                    await MainActor.run {
                        self.isMailboxActionRunning = false
                        self.mailboxActionProgressMessage = nil
                        self.mailboxActionStatusMessage = Self.mailboxCreateAndMoveBlockedStatusMessage(ambiguousCount: ambiguousCount,
                                                                                                         unresolvedCount: unresolvedCount)
                        self.setBottomBarMailboxActionStatus(self.mailboxActionStatusMessage,
                                                             forThreadID: bottomBarThreadID)
                    }
                    return
                }

                let moveResult = try await Self.executeMailboxMove(with: moveInput,
                                                                   destinationPath: destinationPath,
                                                                   account: account)
                let isFullSuccess = moveResult.errorCount == 0 && moveResult.movedCount > 0
                if isFullSuccess {
                    await self.applyOptimisticMailboxMove(candidates: scope.candidates,
                                                          moveTargets: moveInput.internalTargets,
                                                          resolvedInternalIDsByNodeID: [:],
                                                          destinationPath: destinationPath,
                                                          destinationAccount: account)
                }
                await MainActor.run {
                    self.isMailboxActionRunning = false
                    self.mailboxActionProgressMessage = nil
                    self.mailboxActionStatusMessage = Self.mailboxCreateAndMoveStatusMessage(moveResult: moveResult,
                                                                                              ambiguousCount: ambiguousCount,
                                                                                              unresolvedCount: unresolvedCount)
                    self.setBottomBarMailboxActionStatus(self.mailboxActionStatusMessage,
                                                         forThreadID: bottomBarThreadID)
                    if isFullSuccess {
                        self.upsertMailboxThreadMoveRules(threadIDs: scope.threadIDs,
                                                          destinationPath: destinationPath,
                                                          account: account)
                        self.refreshMailboxHierarchy(force: true)
                        // Keep the freshly-moved thread visible in folder overlays by
                        // rethreading from current store state instead of forcing a
                        // full mailbox refresh immediately.
                        self.scheduleRethread(delay: 0)
                    } else {
                        self.shouldForceFullReload = true
                        self.refreshMailboxHierarchy(force: true)
                        self.refreshNow()
                    }
                }
                if isFullSuccess {
                    await self.persistSingleThreadFolderMailboxDestinations(threadIDs: scope.threadIDs,
                                                                           destinationPath: destinationPath,
                                                                           account: account)
                }
            } catch {
                await MainActor.run {
                    self.isMailboxActionRunning = false
                    self.mailboxActionProgressMessage = nil
                    self.mailboxActionStatusMessage = Self.mailboxCreateAndMoveFailureMessage(for: error)
                    self.setBottomBarMailboxActionStatus(self.mailboxActionStatusMessage,
                                                         forThreadID: bottomBarThreadID)
                    if let msg = self.mailboxActionStatusMessage {
                        self.showError(msg)
                    }
                }
            }
        }
    }

    internal func jumpToLatestNode(in folderID: String) {
        jumpToFolderBoundaryNode(in: folderID, boundary: .newest)
    }

    internal func jumpToFirstNode(in folderID: String) {
        jumpToFolderBoundaryNode(in: folderID, boundary: .oldest)
    }

    /// Aggregated minimap data across all thread folders for the global minimap overlay.
    /// Uses actual layout node frame positions normalized by content size so the coordinate
    /// system matches the viewport rect (scrollOffset / contentSize).
    internal func globalMinimapFolders(layout: ThreadCanvasLayout) -> [GlobalMinimapFolder] {
        let contentWidth = layout.contentSize.width
        let contentHeight = layout.contentSize.height
        guard contentWidth > 0, contentHeight > 0 else { return [] }

        // Group layout nodes by folderID
        var folderNodes: [String: [ThreadCanvasNode]] = [:]
        for column in layout.columns {
            guard let folderID = column.folderID else { continue }
            folderNodes[folderID, default: []].append(contentsOf: column.nodes)
        }

        return threadFolders.compactMap { folder -> GlobalMinimapFolder? in
            guard let nodes = folderNodes[folder.id], !nodes.isEmpty else { return nil }
            let minimapNodes = nodes.map { node -> GlobalMinimapNode in
                GlobalMinimapNode(normalizedX: node.frame.midX / contentWidth,
                                  normalizedY: node.frame.midY / contentHeight)
            }
            let color = GlobalMinimapColor(red: folder.color.red,
                                            green: folder.color.green,
                                            blue: folder.color.blue)
            return GlobalMinimapFolder(id: folder.id, color: color, nodes: minimapNodes)
        }
    }

    /// Normalized viewport rectangle for the global minimap (0-1 range).
    /// Uses the stored `globalMinimapViewportNormalizedRect` which is computed
    /// from raw scroll offset / content size in the same coordinate space as
    /// the global minimap node positions.
    internal var globalMinimapViewportRect: CGRect? {
        globalMinimapViewportNormalizedRect
    }

    internal func folderMinimapModel(for folderID: String) -> FolderMinimapModel? {
        let threadIDs = folderThreadIDs(for: folderID)
        guard !threadIDs.isEmpty else { return nil }
        let sourceNodes = Self.flatten(nodes: roots).compactMap { node -> FolderMinimapSourceNode? in
            guard let threadID = effectiveThreadID(for: node),
                  threadIDs.contains(threadID) else {
                return nil
            }
            return FolderMinimapSourceNode(threadID: threadID, node: node)
        }
        return Self.makeFolderMinimapModel(folderID: folderID, sourceNodes: sourceNodes)
    }

    internal func jumpToFolderMinimapPoint(in folderID: String, normalizedPoint: CGPoint) {
        guard let model = folderMinimapModel(for: folderID) else { return }
        guard let targetNodeID = Self.resolveFolderMinimapTargetNodeID(model: model,
                                                                        normalizedPoint: normalizedPoint) else {
            return
        }
        jumpToFolderNode(folderID: folderID, preferredNodeID: targetNodeID)
    }

    internal func isJumpInProgress(for folderID: String) -> Bool {
        folderJumpInProgressIDs.contains(folderID)
    }

    internal func folderMinimapSelectedNodeID(for folderID: String) -> String? {
        guard let model = folderMinimapModel(for: folderID) else { return nil }
        return Self.resolveFolderMinimapSelectedNodeID(selectedNodeID: selectedNodeID,
                                                       model: model)
    }

    internal func folderMinimapViewport(for folderID: String) -> CGRect? {
        minimapViewportSnapshot.normalizedRectByFolderID[folderID]
    }

    /// Updates the global minimap node positions from the current layout.
    /// Call when the layout changes (not on every scroll).
    internal func updateGlobalMinimapFolders(layout: ThreadCanvasLayout) {
        let newFolders = globalMinimapFolders(layout: layout)
        if newFolders.count != globalMinimapFoldersSnapshot.count {
            globalMinimapFoldersSnapshot = newFolders
        } else {
            // Quick check — only update if content actually changed
            let changed = zip(newFolders, globalMinimapFoldersSnapshot).contains { $0.0.id != $0.1.id || $0.0.nodes.count != $0.1.nodes.count }
            if changed {
                globalMinimapFoldersSnapshot = newFolders
            }
        }
    }

    internal func updateFolderMinimapViewportSnapshot(layout: ThreadCanvasLayout,
                                                      scrollOffsetX: CGFloat,
                                                      scrollOffsetY: CGFloat,
                                                      viewportWidth: CGFloat,
                                                      viewportHeight: CGFloat) {
        let snapshot = Self.makeFolderMinimapViewportSnapshot(layout: layout,
                                                              scrollOffsetX: scrollOffsetX,
                                                              scrollOffsetY: scrollOffsetY,
                                                              viewportWidth: viewportWidth,
                                                              viewportHeight: viewportHeight)

        if shouldDeferScrollDerivedPublication {
            deferCanvasScrollPublication(minimapViewportSnapshot: snapshot)
            return
        }
        if minimapViewportSnapshot != snapshot {
            minimapViewportSnapshot = snapshot
        }
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
            if reason == "manual_scroll" {
                coalescedFolderJumpBoundaries.removeValue(forKey: context.folderID)
            }
            Log.app.info("Folder jump cancelled. marker=cancelled folderID=\(context.folderID, privacy: .public) boundary=\(String(describing: context.boundary), privacy: .public) targetNodeID=\(context.targetNodeID, privacy: .public) reason=\(reason, privacy: .public)")
            completeFolderJump(folderID: context.folderID)
        }
    }

    internal func previewFolderEdits(id: String,
                                     title: String,
                                     color: ThreadFolderColor,
                                     mailboxAccount: String?,
                                     mailboxPath: String?) {
        let normalized = Self.normalizedMailboxDestination(account: mailboxAccount, path: mailboxPath)
        folderEditsByID[id] = ThreadFolderEdit(title: title,
                                               color: color,
                                               mailboxAccount: normalized?.account,
                                               mailboxPath: normalized?.path)
    }

    internal func clearFolderEdits(id: String) {
        folderEditsByID.removeValue(forKey: id)
    }

    internal func saveFolderEdits(id: String,
                                  title: String,
                                  color: ThreadFolderColor,
                                  mailboxAccount: String?,
                                  mailboxPath: String?) {
        guard let index = threadFolders.firstIndex(where: { $0.id == id }) else { return }
        var updated = threadFolders
        updated[index].title = title
        updated[index].color = color
        let normalizedDestination = Self.normalizedMailboxDestination(account: mailboxAccount, path: mailboxPath)
        updated[index].mailboxAccount = normalizedDestination?.account
        updated[index].mailboxPath = normalizedDestination?.path

        Task { [weak self] in
            guard let self else { return }
            do {
                if let validationError = try await self.invalidFolderMailboxAssignment(for: updated[index]) {
                    await MainActor.run {
                        self.mailboxActionStatusMessage = validationError
                    }
                    return
                }
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

    internal func recalibratedColor(for folderID: String) -> ThreadFolderColor? {
        let sourceFolders = effectiveThreadFolders
        guard let selectedFolderIndex = sourceFolders.firstIndex(where: { $0.id == folderID }) else { return nil }

        var workingFolders = sourceFolders
        let selectedColor = ThreadFolderColor.recalibrated(for: workingFolders[selectedFolderIndex],
                                                           among: workingFolders)
        workingFolders[selectedFolderIndex].color = selectedColor

        let descendantIDs = Self.descendantFolderIDs(of: folderID,
                                                     childrenByParent: Self.childFolderIDsByParent(folders: sourceFolders))
        guard !descendantIDs.isEmpty else {
            return selectedColor
        }

        for descendantID in descendantIDs {
            guard let descendantIndex = workingFolders.firstIndex(where: { $0.id == descendantID }) else { continue }
            workingFolders[descendantIndex].color = ThreadFolderColor.recalibrated(for: workingFolders[descendantIndex],
                                                                                   among: workingFolders)
        }

        let descendantColorByID = Dictionary(uniqueKeysWithValues: descendantIDs.compactMap { descendantID in
            workingFolders.first(where: { $0.id == descendantID }).map { (descendantID, $0.color) }
        })
        let updatedFolders = threadFolders.map { folder in
            guard let updatedColor = descendantColorByID[folder.id] else { return folder }
            var updatedFolder = folder
            updatedFolder.color = updatedColor
            return updatedFolder
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.upsertThreadFolders(updatedFolders)
                await MainActor.run {
                    self.threadFolders = updatedFolders
                    self.refreshFolderSummaries(for: self.roots, folders: updatedFolders)
                }
            } catch {
                Log.app.error("Failed to save recalibrated descendant folder colors: \(error.localizedDescription, privacy: .public)")
            }
        }

        return selectedColor
    }

    internal func openMessageInMail(_ node: ThreadNode) {
        let messageKey = node.message.id.uuidString
        let attemptID = UUID()
        openInMailAttemptID = attemptID
        setOpenInMailState(.searchingFilteredFallback, messageKey: messageKey, attemptID: attemptID)
        let metadata = MailControl.OpenMessageMetadata(subject: node.message.subject,
                                                       sender: node.message.from,
                                                       date: node.message.date,
                                                       mailbox: node.message.mailboxID,
                                                       account: node.message.accountName)
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let resolution = try await MailControl.openMessageViaFilteredFallback(metadata)
                switch resolution {
                case .opened:
                    Log.appleScript.info("Open in Mail succeeded by filtered fallback. messageKey=\(messageKey, privacy: .public)")
                    await MainActor.run {
                        self.setOpenInMailState(.opened(.filteredFallback),
                                                messageKey: messageKey,
                                                attemptID: attemptID)
                    }
                case .notFound:
                    Log.appleScript.info("Open in Mail filtered fallback found no match. messageKey=\(messageKey, privacy: .public)")
                    await MainActor.run {
                        self.setOpenInMailState(.notFound, messageKey: messageKey, attemptID: attemptID)
                    }
                }
            } catch {
                Log.appleScript.error("Open in Mail failed. messageKey=\(messageKey, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.setOpenInMailState(.failed(error.localizedDescription),
                                            messageKey: messageKey,
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
                                    messageKey: String,
                                    attemptID: UUID) {
        guard openInMailAttemptID == attemptID else { return }
        openInMailState = OpenInMailState(messageKey: messageKey, status: status)
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
                if let targetFolder = updated.folders.first(where: { $0.id == folderID }),
                   targetFolder.mailboxDestination != nil {
                    let statusMessage = await self.moveThreadToAssignedFolderMailbox(threadID: threadID,
                                                                                     folder: targetFolder)
                    if let statusMessage {
                        await MainActor.run {
                            self.mailboxActionStatusMessage = statusMessage
                            self.setBottomBarMailboxActionStatus(statusMessage, forThreadID: threadID)
                        }
                    }
                }
            } catch {
                Log.app.error("Failed to move thread into folder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    internal func moveFolder(folderID: String, toParentFolderID parentFolderID: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let updated = Self.applyFolderMove(folderID: folderID,
                                                     toParentFolderID: parentFolderID,
                                                     folders: threadFolders) else { return }
            do {
                try await store.upsertThreadFolders(updated.folders)
                await MainActor.run {
                    self.threadFolders = updated.folders
                    self.folderMembershipByThreadID = updated.membership
                    self.refreshFolderSummaries(for: self.roots, folders: updated.folders)
                }
            } catch {
                Log.app.error("Failed to move folder into folder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    internal func removeFolderFromParent(folderID: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let updated = Self.applyFolderMove(folderID: folderID,
                                                     toParentFolderID: nil,
                                                     folders: threadFolders) else { return }
            do {
                try await store.upsertThreadFolders(updated.folders)
                await MainActor.run {
                    self.threadFolders = updated.folders
                    self.folderMembershipByThreadID = updated.membership
                    self.refreshFolderSummaries(for: self.roots, folders: updated.folders)
                }
            } catch {
                Log.app.error("Failed to move folder to root: \(error.localizedDescription, privacy: .public)")
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

    internal func parentFolderID(for folderID: String) -> String? {
        threadFolders.first(where: { $0.id == folderID })?.parentID
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
        let rowPackingMode: ThreadCanvasRowPackingMode = activeMailboxScope == .allFolders ? .folderAlignedDense : .dateBucketed
        let enrichmentVersion = viewMode == .timeline ? enrichmentLayoutVersion : 0
        let cacheKey = TimelineLayoutCacheKey(viewMode: viewMode,
                                              rowPackingMode: rowPackingMode,
                                              dayCount: metrics.dayCount,
                                              showsDayAxis: metrics.showsDayAxis,
                                              zoomBucket: Self.zoomCacheBucket(metrics.zoom),
                                              columnWidthBucket: Self.metricsBucket(metrics.columnWidthAdjustment),
                                              structuralVersion: structuralLayoutVersion,
                                              enrichmentVersion: enrichmentVersion,
                                              dayStart: dayStart)
        if let cachedKey = layoutCacheKey,
           cachedKey == cacheKey,
           let cachedLayout = layoutCache {
            os_signpost(.event, log: Log.performance, name: "CanvasLayoutCacheHit")
            return cachedLayout
        }

        let layout = Self.canvasLayout(for: filteredRoots,
                                       metrics: metrics,
                                       viewMode: viewMode,
                                       rowPackingMode: rowPackingMode,
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
        let emptyIntervals = Self.emptyDayIntervals(for: layout,
                                                    visibleRange: range,
                                                    today: today,
                                                    calendar: calendar)
        let populatedDays = layout.populatedDayIndices
        let hasMessages = range.map { range in
            range.contains { populatedDays.contains($0) }
        } ?? false
        if activeMailboxScope != .allFolders {
            let forceExpansion = shouldForceDayWindowExpansion(scrollOffset: scrollOffset,
                                                               viewportHeight: viewportHeight,
                                                               contentHeight: layout.contentSize.height,
                                                               threshold: metrics.dayHeight * 2)
            expandDayWindowIfNeeded(visibleRange: range, forceIncrement: forceExpansion)
        }
        if shouldDeferScrollDerivedPublication {
            deferCanvasScrollPublication(visibleDayRange: range,
                                         visibleEmptyDayIntervals: emptyIntervals,
                                         visibleRangeHasMessages: hasMessages)
            return
        }
        if visibleDayRange != range {
            visibleDayRange = range
        }
        if visibleEmptyDayIntervals != emptyIntervals {
            visibleEmptyDayIntervals = emptyIntervals
        }
        if visibleRangeHasMessages != hasMessages {
            visibleRangeHasMessages = hasMessages
        }
    }

    private func invalidateLayoutCache(structural: Bool = true,
                                       enrichment: Bool = true,
                                       reason: LayoutInvalidationReason = .generic) {
        if shouldDeferEnrichmentLayoutInvalidation(structural: structural,
                                                  enrichment: enrichment) {
            hasDeferredEnrichmentLayoutInvalidation = true
            deferredEnrichmentInvalidationReasons.insert(reason)
            os_signpost(.event,
                        log: Log.performance,
                        name: "AllFoldersLayoutInvalidationDeferred",
                        "reason=%{public}s totalInvalidations=%{public}d sessionInvalidations=%{public}d",
                        reason.rawValue,
                        layoutInvalidationCount,
                        layoutInvalidationCountDuringActiveAllFoldersScroll)
            return
        }
        if structural {
            structuralLayoutVersion &+= 1
        }
        if enrichment {
            enrichmentLayoutVersion &+= 1
        }
        layoutInvalidationCount &+= 1
        if activeMailboxScope == .allFolders, isAllFoldersScrollActive {
            layoutInvalidationCountDuringActiveAllFoldersScroll &+= 1
            os_signpost(.event,
                        log: Log.performance,
                        name: "AllFoldersLayoutInvalidated",
                        "reason=%{public}s structural=%{public}d enrichment=%{public}d totalInvalidations=%{public}d sessionInvalidations=%{public}d",
                        reason.rawValue,
                        structural,
                        enrichment,
                        layoutInvalidationCount,
                        layoutInvalidationCountDuringActiveAllFoldersScroll)
        }
        layoutCacheKey = nil
        layoutCache = nil
    }

    private func shouldDeferEnrichmentLayoutInvalidation(structural: Bool,
                                                         enrichment: Bool) -> Bool {
        activeMailboxScope == .allFolders &&
            isAllFoldersScrollActive &&
            structural == false &&
            enrichment
    }

    private func flushDeferredEnrichmentLayoutInvalidationIfNeeded() {
        guard hasDeferredEnrichmentLayoutInvalidation else { return }
        hasDeferredEnrichmentLayoutInvalidation = false
        let reasons = deferredEnrichmentInvalidationReasons
        deferredEnrichmentInvalidationReasons.removeAll(keepingCapacity: true)
        enrichmentLayoutVersion &+= 1
        layoutInvalidationCount &+= 1
        layoutCacheKey = nil
        layoutCache = nil
        let reasonSummary = reasons
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        os_signpost(.event,
                    log: Log.performance,
                    name: "AllFoldersDeferredLayoutInvalidationApplied",
                    "reasonCount=%{public}d reasons=%{public}s totalInvalidations=%{public}d",
                    reasons.count,
                    reasonSummary,
                    layoutInvalidationCount)
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
        let mailboxTarget = activeMailboxFetchTarget
        Task { [weak self] in
            guard let self else { return }
            do {
                Log.refresh.info("Backfill requested. ranges=\(ranges, privacy: .public) limit=\(limit, privacy: .public) snippetLineLimit=\(snippetLineLimit, privacy: .public)")
                var fetchedCount = 0
                for range in ranges {
                    let total = try await backfillService.countMessages(in: range,
                                                                        mailbox: mailboxTarget.mailbox,
                                                                        account: mailboxTarget.account)
                    guard total > 0 else { continue }
                    let result = try await backfillService.runBackfill(range: range,
                                                                       mailbox: mailboxTarget.mailbox,
                                                                       account: mailboxTarget.account,
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
                    self.showError(self.status)
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

        let selectionDetails = selectedNodes.map { node -> (messageKey: String, currentThreadID: String, jwzThreadID: String, manualGroupID: String?, isJWZThreaded: Bool) in
            let messageKey = node.message.threadKey
            let jwzThreadID = jwzThreadMap[messageKey] ?? node.message.threadID ?? node.id
            let isJWZThreaded = jwzThreadMap[messageKey] != nil
            let currentThreadID = manualGroupByMessageKey[messageKey] ?? jwzThreadID
            return (messageKey, currentThreadID, jwzThreadID, manualGroupByMessageKey[messageKey], isJWZThreaded)
        }
        let sourceThreadIDs = Set(selectionDetails.map { $0.currentThreadID })

        let manualGroupIDs = Set(selectionDetails.compactMap(\.manualGroupID))

        guard let targetID = selectedNodeID,
              let targetNode = Self.node(matching: targetID, in: roots) else { return }
        let targetKey = targetNode.message.threadKey
        let targetJWZID = jwzThreadMap[targetKey] ?? targetNode.message.threadID ?? targetNode.id
        let targetThreadID = effectiveThreadID(for: targetNode)
        let targetFolderMailboxMove = pendingFolderMailboxMoveForManualAttachment(targetNode: targetNode,
                                                                                  targetThreadID: targetThreadID,
                                                                                  targetMessageKey: targetKey)

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
                    try await reconcileThreadIdentityRemap(sourceThreadIDs: sourceThreadIDs,
                                                          replacementThreadID: newGroup.id,
                                                          preferredSourceThreadID: targetThreadID)
                    await MainActor.run {
                        if !manualAttachmentKeys.isEmpty {
                            self.pendingManualAttachmentMailboxMove = targetFolderMailboxMove
                        }
                        self.scheduleRethread()
                    }
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
                    try await reconcileThreadIdentityRemap(sourceThreadIDs: sourceThreadIDs,
                                                          replacementThreadID: groupID,
                                                          preferredSourceThreadID: targetThreadID)
                    await MainActor.run {
                        if !manualAttachmentKeys.isEmpty {
                            self.pendingManualAttachmentMailboxMove = targetFolderMailboxMove
                        }
                        self.scheduleRethread()
                    }
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
                try await reconcileThreadIdentityRemap(sourceThreadIDs: sourceThreadIDs,
                                                      replacementThreadID: mergedGroup.id,
                                                      preferredSourceThreadID: targetThreadID)
                await MainActor.run {
                    if !manualAttachmentKeys.isEmpty {
                        self.pendingManualAttachmentMailboxMove = targetFolderMailboxMove
                    }
                    self.scheduleRethread()
                }
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

    private func reconcileThreadIdentityRemap(sourceThreadIDs: Set<String>,
                                              replacementThreadID: String,
                                              preferredSourceThreadID: String?) async throws {
        if let update = Self.remapThreadIDsInFolders(sourceThreadIDs,
                                                     to: replacementThreadID,
                                                     preferredSourceThreadID: preferredSourceThreadID,
                                                     folders: threadFolders) {
            try await store.upsertThreadFolders(update.folders)
            if !update.deletedFolderIDs.isEmpty {
                try await store.deleteThreadFolders(ids: Array(update.deletedFolderIDs))
            }
            threadFolders = update.folders
            folderMembershipByThreadID = update.membership
            refreshFolderSummaries(for: roots, folders: update.folders)
        }
        mailboxThreadAutoMoveSettings.remap(threadIDs: sourceThreadIDs,
                                            to: replacementThreadID,
                                            preferredSourceThreadID: preferredSourceThreadID)
    }

    private func pendingFolderMailboxMoveForManualAttachment(targetNode: ThreadNode,
                                                             targetThreadID: String?,
                                                             targetMessageKey: String) -> PendingManualAttachmentMailboxMove? {
        if let targetThreadID,
           let folderID = folderMembershipByThreadID[targetThreadID],
           let folder = threadFolders.first(where: { $0.id == folderID }),
           let destination = folder.mailboxDestination {
            return PendingManualAttachmentMailboxMove(targetMessageKey: targetMessageKey,
                                                      destinationAccount: destination.account,
                                                      destinationPath: destination.path)
        }

        let account = mailboxActionAccountName(for: targetNode)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mailboxPath = mailboxPathForMailboxMove(message: targetNode.message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !mailboxPath.isEmpty else { return nil }
        return PendingManualAttachmentMailboxMove(targetMessageKey: targetMessageKey,
                                                  destinationAccount: account,
                                                  destinationPath: mailboxPath)
    }

    private func mailboxActionAccountSet() -> Set<String> {
        Set(selectedNodes(in: roots).compactMap(mailboxActionAccountName(for:)))
    }

    private func selectedAccountNameForMailboxActions() -> String? {
        let accounts = mailboxActionAccountSet()
        guard accounts.count == 1 else { return nil }
        return accounts.first
    }

    private func mailboxMoveCandidates(from messages: [EmailMessage],
                                       account: String,
                                       destinationPath: String? = nil) -> [MailboxMoveCandidate] {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return [] }
        let trimmedDestination = destinationPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var seenMessageIDs = Set<String>()
        return messages.compactMap { message in
            guard seenMessageIDs.insert(message.messageID).inserted else {
                return nil
            }
            let messageAccount = message.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !messageAccount.isEmpty &&
                messageAccount.caseInsensitiveCompare(trimmedAccount) != .orderedSame {
                return nil
            }
            let sourceMailboxPath = mailboxPathForMailboxMove(message: message)
            if !trimmedDestination.isEmpty &&
                sourceMailboxPath.caseInsensitiveCompare(trimmedDestination) == .orderedSame &&
                (messageAccount.isEmpty || messageAccount.caseInsensitiveCompare(trimmedAccount) == .orderedSame) {
                return nil
            }
            return MailboxMoveCandidate(nodeID: message.messageID,
                                        message: message,
                                        account: trimmedAccount,
                                        mailboxPath: sourceMailboxPath)
        }
    }

    private func mailboxPathForMailboxMove(message: EmailMessage) -> String {
        let mailboxID = message.mailboxID.trimmingCharacters(in: .whitespacesAndNewlines)
        if mailboxID.isEmpty {
            return "inbox"
        }
        if mailboxID.compare("all inboxes", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return ""
        }
        return mailboxID
    }

    private static func normalizedMailboxDestination(account: String?,
                                                     path: String?) -> (account: String, path: String)? {
        let trimmedAccount = account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedAccount.isEmpty, !trimmedPath.isEmpty else { return nil }
        return (trimmedAccount, trimmedPath)
    }

    private func folderAccountNamesInVisibleRoots(_ folder: ThreadFolder) -> Set<String> {
        let nodesByThreadID = Dictionary(grouping: Self.flatten(nodes: roots)) { node in
            effectiveThreadID(for: node)
        }

        return folder.threadIDs.reduce(into: Set<String>()) { result, threadID in
            let nodes = nodesByThreadID[threadID] ?? []
            for node in nodes {
                let account = mailboxActionAccountName(for: node)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !account.isEmpty {
                    result.insert(account)
                }
            }
        }
    }

    private func invalidFolderMailboxAssignment(for folder: ThreadFolder) async throws -> String? {
        guard let destination = folder.mailboxDestination else { return nil }
        let messages = try await store.fetchMessages(threadIDs: folder.threadIDs)
        let accountNames = Set(messages.compactMap { message in
            let trimmed = message.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
        if accountNames.count > 1 {
            return NSLocalizedString("threadcanvas.folder.mailbox.mixed_accounts",
                                     comment: "Reason a folder mailbox destination cannot be set for mixed-account folders")
        }
        if let resolvedAccount = accountNames.first,
           resolvedAccount.caseInsensitiveCompare(destination.account) != .orderedSame {
            return NSLocalizedString("threadcanvas.folder.mailbox.account_mismatch",
                                     comment: "Reason a folder mailbox destination account does not match the folder threads")
        }
        return nil
    }

    private func mailboxRecoveryContext(account: String,
                                        path: String,
                                        messages: [EmailMessage]) -> MailboxRecoveryContext {
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidateByKey: [String: (account: String, path: String)] = [:]
        for message in messages {
            let messageAccount = message.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            let mailboxPath = mailboxPathForMailboxMove(message: message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !messageAccount.isEmpty,
                  !mailboxPath.isEmpty,
                  messageAccount.caseInsensitiveCompare(normalizedAccount) == .orderedSame else {
                continue
            }
            candidateByKey["\(messageAccount.lowercased())||\(mailboxPath.lowercased())"] = (messageAccount, mailboxPath)
        }

        if candidateByKey.count == 1,
           let candidate = candidateByKey.values.first {
            return MailboxRecoveryContext(account: normalizedAccount,
                                          path: normalizedPath,
                                          currentMailboxPath: candidate.path,
                                          currentMailboxAccount: candidate.account)
        }

        return MailboxRecoveryContext(account: normalizedAccount,
                                      path: normalizedPath,
                                      currentMailboxPath: nil,
                                      currentMailboxAccount: nil)
    }

    private func recoverMailboxDestination(account: String,
                                           path: String,
                                           messages: [EmailMessage]) async -> RecoveredMailboxDestination? {
        let context = mailboxRecoveryContext(account: account, path: path, messages: messages)
        return await MainActor.run {
            let resolution = MailboxHierarchyBuilder.resolveMailboxPath(account: context.account,
                                                                       path: context.path,
                                                                       in: self.mailboxAccounts,
                                                                       currentMailboxPath: context.currentMailboxPath,
                                                                       currentMailboxAccount: context.currentMailboxAccount)
            guard let choice = resolution.resolvedChoice else { return nil }
            return RecoveredMailboxDestination(account: choice.account,
                                               path: choice.path,
                                               resolution: resolution)
        }
    }

    private func recoverFolderDestinationIfNeeded(folder: ThreadFolder,
                                                  messages: [EmailMessage]) async -> FolderDestinationRecoveryResult {
        guard let destination = folder.mailboxDestination else {
            return .failure(NSLocalizedString("mailbox.action.folder_destination.missing",
                                              comment: "Status when assigned folder mailbox destination is missing"))
        }

        guard let recoveredDestination = await recoverMailboxDestination(account: destination.account,
                                                                        path: destination.path,
                                                                        messages: messages) else {
            let resolution = await MainActor.run {
                let context = self.mailboxRecoveryContext(account: destination.account,
                                                          path: destination.path,
                                                          messages: messages)
                return MailboxHierarchyBuilder.resolveMailboxPath(account: context.account,
                                                                 path: context.path,
                                                                 in: self.mailboxAccounts,
                                                                 currentMailboxPath: context.currentMailboxPath,
                                                                 currentMailboxAccount: context.currentMailboxAccount)
            }
            switch resolution {
            case .ambiguous:
                return .failure(String.localizedStringWithFormat(
                    NSLocalizedString("mailbox.action.folder_destination.ambiguous",
                                      comment: "Status when assigned folder mailbox destination remap is ambiguous"),
                    destination.account,
                    destination.path
                ))
            case .missing, .exact, .heuristic:
                return .failure(String.localizedStringWithFormat(
                    NSLocalizedString("mailbox.action.folder_destination.reassign",
                                      comment: "Status when assigned folder mailbox destination must be reassigned"),
                    destination.account,
                    destination.path
                ))
            }
        }

        guard case .heuristic = recoveredDestination.resolution else {
            return .success(recoveredDestination)
        }

        var updatedFolders = threadFolders
        guard let index = updatedFolders.firstIndex(where: { $0.id == folder.id }) else {
            return .success(recoveredDestination)
        }
        updatedFolders[index].mailboxAccount = recoveredDestination.account
        updatedFolders[index].mailboxPath = recoveredDestination.path

        do {
            try await store.upsertThreadFolders(updatedFolders)
            await MainActor.run {
                self.threadFolders = updatedFolders
                self.folderEditsByID.removeValue(forKey: folder.id)
            }
            return .success(recoveredDestination)
        } catch {
            Log.app.error("Failed to persist recovered folder mailbox destination: \(error.localizedDescription, privacy: .public)")
            return .failure(String.localizedStringWithFormat(
                NSLocalizedString("mailbox.action.folder_destination.reassign",
                                  comment: "Status when assigned folder mailbox destination must be reassigned"),
                destination.account,
                destination.path
            ))
        }
    }

#if DEBUG
    internal func recoverFolderDestinationForTesting(folderID: String) async -> MailboxPathResolution? {
        guard let folder = threadFolders.first(where: { $0.id == folderID }),
              let destination = folder.mailboxDestination else {
            return nil
        }
        let messages = (try? await store.fetchMessages(threadIDs: folder.threadIDs)) ?? []
        let context = mailboxRecoveryContext(account: destination.account,
                                             path: destination.path,
                                             messages: messages)
        let resolution = await MainActor.run {
            MailboxHierarchyBuilder.resolveMailboxPath(account: context.account,
                                                      path: context.path,
                                                      in: self.mailboxAccounts,
                                                      currentMailboxPath: context.currentMailboxPath,
                                                      currentMailboxAccount: context.currentMailboxAccount)
        }
        _ = await recoverFolderDestinationIfNeeded(folder: folder, messages: messages)
        return resolution
    }
#endif

    private func persistSingleThreadFolderMailboxDestinations(threadIDs: Set<String>,
                                                              destinationPath: String,
                                                              account: String) async {
        let normalizedDestination = Self.normalizedMailboxDestination(account: account, path: destinationPath)
        guard let normalizedDestination else { return }

        let candidateFolders = threadFolders.filter { folder in
            folder.threadIDs.count == 1 && !folder.threadIDs.intersection(threadIDs).isEmpty
        }
        guard !candidateFolders.isEmpty else { return }

        var updatedFolders = threadFolders
        var didChange = false
        for folder in candidateFolders {
            guard let index = updatedFolders.firstIndex(where: { $0.id == folder.id }) else { continue }
            if updatedFolders[index].mailboxAccount == normalizedDestination.account &&
                updatedFolders[index].mailboxPath == normalizedDestination.path {
                continue
            }
            updatedFolders[index].mailboxAccount = normalizedDestination.account
            updatedFolders[index].mailboxPath = normalizedDestination.path
            didChange = true
        }
        guard didChange else { return }

        do {
            try await store.upsertThreadFolders(updatedFolders)
            await MainActor.run {
                self.threadFolders = updatedFolders
            }
        } catch {
            Log.app.error("Failed to persist inferred folder mailbox destination: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func moveThreadToAssignedFolderMailbox(threadID: String,
                                                   folder: ThreadFolder) async -> String? {
        guard let destination = folder.mailboxDestination else { return nil }
        do {
            let messages = try await store.fetchMessages(threadIDs: [threadID])
            let recoveredDestination: RecoveredMailboxDestination
            switch await recoverFolderDestinationIfNeeded(folder: folder, messages: messages) {
            case .success(let resolved):
                recoveredDestination = resolved
            case .failure(let statusMessage):
                return statusMessage
            }
            let candidates = mailboxMoveCandidates(from: messages,
                                                   account: recoveredDestination.account,
                                                   destinationPath: recoveredDestination.path)
            if candidates.isEmpty {
                await MainActor.run {
                    self.upsertMailboxThreadMoveRules(threadIDs: [threadID],
                                                      destinationPath: recoveredDestination.path,
                                                      account: recoveredDestination.account)
                }
                let baseStatus = NSLocalizedString("mailbox.action.move.summary.no_candidates",
                                                   comment: "Status when all thread messages are already in destination mailbox")
                if case .heuristic = recoveredDestination.resolution {
                    return String.localizedStringWithFormat(
                        NSLocalizedString("mailbox.action.folder_destination.remapped_with_detail",
                                          comment: "Status when assigned folder mailbox destination was remapped and move found no candidates"),
                        destination.path,
                        recoveredDestination.path,
                        baseStatus
                    )
                }
                return baseStatus
            }

            let moveInput = Self.mailboxMoveInput(from: candidates)
            guard moveInput.unresolvedCount == 0,
                  !moveInput.internalTargets.isEmpty else {
                return Self.mailboxMoveBlockedStatusMessage(ambiguousCount: 0,
                                                            unresolvedCount: moveInput.unresolvedCount)
            }

            let moveResult = try await Self.executeMailboxMove(with: moveInput,
                                                               destinationPath: recoveredDestination.path,
                                                               account: recoveredDestination.account)
            let isFullSuccess = moveResult.errorCount == 0 && moveResult.movedCount > 0
            let baseStatus = Self.mailboxMoveStatusMessage(moveResult: moveResult,
                                                           ambiguousCount: 0,
                                                           unresolvedCount: moveInput.unresolvedCount)
            if isFullSuccess {
                await applyOptimisticMailboxMove(candidates: candidates,
                                                 moveTargets: moveInput.internalTargets,
                                                 resolvedInternalIDsByNodeID: [:],
                                                 destinationPath: recoveredDestination.path,
                                                 destinationAccount: recoveredDestination.account)
                await MainActor.run {
                    self.upsertMailboxThreadMoveRules(threadIDs: [threadID],
                                                      destinationPath: recoveredDestination.path,
                                                      account: recoveredDestination.account)
                }
            }

            if case .heuristic = recoveredDestination.resolution {
                return String.localizedStringWithFormat(
                    NSLocalizedString("mailbox.action.folder_destination.remapped_with_detail",
                                      comment: "Status when assigned folder mailbox destination was remapped before move"),
                    destination.path,
                    recoveredDestination.path,
                    baseStatus
                )
            }

            return baseStatus
        } catch {
            return Self.mailboxMoveFailureMessage(for: error)
        }
    }

    @MainActor
    private func runPendingManualAttachmentMailboxMoveIfNeeded() async {
        guard let pending = pendingManualAttachmentMailboxMove else { return }
        pendingManualAttachmentMailboxMove = nil

        guard let targetNode = Self.flatten(nodes: roots).first(where: { $0.message.threadKey == pending.targetMessageKey }),
              let threadID = effectiveThreadID(for: targetNode) else {
            return
        }

        let folder = ThreadFolder(id: "pending-manual-attachment-folder",
                                  title: "",
                                  color: ThreadFolderColor(red: 0, green: 0, blue: 0, alpha: 0),
                                  threadIDs: [threadID],
                                  parentID: nil,
                                  mailboxAccount: pending.destinationAccount,
                                  mailboxPath: pending.destinationPath)
        let statusMessage = await moveThreadToAssignedFolderMailbox(threadID: threadID, folder: folder)
        if let statusMessage {
            mailboxActionStatusMessage = statusMessage
            setBottomBarMailboxActionStatus(statusMessage, forThreadID: threadID)
        }
    }

    private static func mailboxMoveFailureMessage(for error: Error) -> String {
        if let code = MailControl.appleScriptErrorCode(from: error) {
            if code == -10004 {
                return NSLocalizedString("mailbox.action.error.appleevent_privilege",
                                         comment: "Error shown when app lacks AppleEvent permission to control Mail")
            }
            if code == -1712 {
                return NSLocalizedString("mailbox.action.error.timed_out",
                                         comment: "Error shown when AppleScript operation times out")
            }
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("mailbox.action.move.failed", comment: "Status when moving messages fails"),
            error.localizedDescription
        )
    }

    private static func mailboxCreateAndMoveFailureMessage(for error: Error) -> String {
        if let code = MailControl.appleScriptErrorCode(from: error) {
            if code == -10004 {
                return NSLocalizedString("mailbox.action.error.appleevent_privilege",
                                         comment: "Error shown when app lacks AppleEvent permission to control Mail")
            }
            if code == -1712 {
                return NSLocalizedString("mailbox.action.error.timed_out",
                                         comment: "Error shown when AppleScript operation times out")
            }
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("mailbox.action.create_and_move.failed",
                              comment: "Status when creating mailbox folder and moving messages fails"),
            error.localizedDescription
        )
    }

    private static func mailboxMoveStatusMessage(moveResult: MailControl.MailboxMoveResult,
                                                 ambiguousCount: Int,
                                                 unresolvedCount: Int) -> String {
        let firstErrorDetail: String? = {
            guard moveResult.errorCount > 0 else { return nil }
            let message = moveResult.firstErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let code = moveResult.firstErrorNumber {
                return message.isEmpty ? "Apple Mail move error code \(code)." : "Apple Mail move error (\(code)): \(message)"
            }
            return message.isEmpty ? nil : "Apple Mail move error: \(message)"
        }()

        if moveResult.movedCount > 0 {
            if ambiguousCount > 0 || unresolvedCount > 0 {
                var status = String.localizedStringWithFormat(
                    NSLocalizedString("mailbox.action.move.summary.partial",
                                      comment: "Status after partially moving messages with skipped ambiguous/unresolved candidates"),
                    moveResult.movedCount,
                    ambiguousCount,
                    unresolvedCount
                )
                if let firstErrorDetail {
                    status += " \(firstErrorDetail)"
                }
                return status
            }
            var status = String.localizedStringWithFormat(
                NSLocalizedString("mailbox.action.move.summary",
                                  comment: "Status after moving messages to mailbox folder with count"),
                moveResult.movedCount
            )
            if let firstErrorDetail {
                status += " \(firstErrorDetail)"
            }
            return status
        }
        if ambiguousCount > 0 || unresolvedCount > 0 {
            var status = String.localizedStringWithFormat(
                NSLocalizedString("mailbox.action.move.summary.none",
                                  comment: "Status when no messages were moved due to ambiguous or unresolved lookup"),
                ambiguousCount,
                unresolvedCount
            )
            if let firstErrorDetail {
                status += " \(firstErrorDetail)"
            }
            return status
        }
        var status = NSLocalizedString("mailbox.action.move.summary.none_generic",
                                       comment: "Status when no messages were moved and no additional lookup details are available")
        if let firstErrorDetail {
            status += " \(firstErrorDetail)"
        }
        return status
    }

    private static func mailboxMoveBlockedStatusMessage(ambiguousCount: Int,
                                                        unresolvedCount: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("mailbox.action.move.summary.blocked",
                              comment: "Status when full-thread mailbox move is blocked due to unresolved candidates"),
            ambiguousCount,
            unresolvedCount
        )
    }

    private static func mailboxCreateAndMoveStatusMessage(moveResult: MailControl.MailboxMoveResult,
                                                          ambiguousCount: Int,
                                                          unresolvedCount: Int) -> String {
        let firstErrorDetail: String? = {
            guard moveResult.errorCount > 0 else { return nil }
            let message = moveResult.firstErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let code = moveResult.firstErrorNumber {
                return message.isEmpty ? "Apple Mail move error code \(code)." : "Apple Mail move error (\(code)): \(message)"
            }
            return message.isEmpty ? nil : "Apple Mail move error: \(message)"
        }()

        if moveResult.movedCount > 0 {
            if ambiguousCount > 0 || unresolvedCount > 0 {
                var status = String.localizedStringWithFormat(
                    NSLocalizedString("mailbox.action.create_and_move.summary.partial",
                                      comment: "Status after creating folder and partially moving messages"),
                    moveResult.movedCount,
                    ambiguousCount,
                    unresolvedCount
                )
                if let firstErrorDetail {
                    status += " \(firstErrorDetail)"
                }
                return status
            }
            var status = String.localizedStringWithFormat(
                NSLocalizedString("mailbox.action.create_and_move.summary",
                                  comment: "Status after creating folder and moving messages"),
                moveResult.movedCount
            )
            if let firstErrorDetail {
                status += " \(firstErrorDetail)"
            }
            return status
        }
        if ambiguousCount > 0 || unresolvedCount > 0 {
            var status = String.localizedStringWithFormat(
                NSLocalizedString("mailbox.action.create_and_move.summary.none",
                                  comment: "Status when folder was created but no messages moved"),
                ambiguousCount,
                unresolvedCount
            )
            if let firstErrorDetail {
                status += " \(firstErrorDetail)"
            }
            return status
        }
        var status = NSLocalizedString("mailbox.action.move.summary.none_generic",
                                       comment: "Status when no messages were moved and no additional lookup details are available")
        if let firstErrorDetail {
            status += " \(firstErrorDetail)"
        }
        return status
    }

    private static func mailboxCreateAndMoveBlockedStatusMessage(ambiguousCount: Int,
                                                                 unresolvedCount: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("mailbox.action.create_and_move.summary.blocked",
                              comment: "Status when created folder cannot receive full-thread move due to unresolved candidates"),
            ambiguousCount,
            unresolvedCount
        )
    }

    @MainActor
    private func upsertMailboxThreadMoveRules(threadIDs: Set<String>,
                                              destinationPath: String,
                                              account: String) {
        guard !threadIDs.isEmpty else { return }
        mailboxThreadAutoMoveSettings.upsert(threadIDs: threadIDs,
                                             destinationPath: destinationPath,
                                             account: account)
    }

    private func mailboxActionAccountName(for node: ThreadNode) -> String? {
        let account = node.message.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !account.isEmpty {
            return account
        }
        switch activeMailboxScope {
        case .mailboxFolder(let scopedAccount, _):
            let trimmedScopedAccount = scopedAccount.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedScopedAccount.isEmpty ? nil : trimmedScopedAccount
        case .actionItems, .allEmails, .allFolders, .allInboxes:
            return nil
        }
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
                updated.mailboxAccount = edit.mailboxAccount
                updated.mailboxPath = edit.mailboxPath
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
        guard activeMailboxScope != .allFolders else { return }
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

    private var activeMailboxFetchTarget: (mailbox: String, account: String?) {
        switch activeMailboxScope {
        case .actionItems, .allEmails, .allFolders, .allInboxes:
            return (mailbox: "inbox", account: nil)
        case .mailboxFolder(let account, let path):
            return (mailbox: path, account: account)
        }
    }

    private var activeMailboxStoreFilter: (mailbox: String?, account: String?, includeAllInboxesAliases: Bool) {
        switch activeMailboxScope {
        case .actionItems, .allEmails, .allFolders:
            return (mailbox: nil, account: nil, includeAllInboxesAliases: false)
        case .allInboxes:
            return (mailbox: "inbox", account: nil, includeAllInboxesAliases: true)
        case .mailboxFolder(let account, let path):
            return (mailbox: path, account: account, includeAllInboxesAliases: false)
        }
    }

    private func refreshFolderCoverage(folderID: String,
                                       preferredBatchSize: Int,
                                       snippetLineLimit: Int,
                                       referenceDate: Date = Date()) async throws -> Int {
        let folderNodes = Self.folderNodesByID(roots: roots,
                                               folders: threadFolders,
                                               manualGroupByMessageKey: manualGroupByMessageKey,
                                               jwzThreadMap: jwzThreadMap)[folderID] ?? []
        guard !folderNodes.isEmpty else { return 0 }

        let threadIDs = Set(folderNodes.compactMap { node -> String? in
            let trimmed = node.message.threadID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        })
        let storedMessages = try await store.fetchMessages(threadIDs: threadIDs)
        let seedMessages = storedMessages.isEmpty ? folderNodes.map(\.message) : storedMessages
        let plan = Self.folderRefreshSubjectPlan(messages: seedMessages)
        guard !plan.isEmpty else { return 0 }

        Log.refresh.info("Starting folder coverage refresh. folderID=\(folderID, privacy: .public) targets=\(plan.count, privacy: .public)")
        var fetchedCount = 0
        var seenMessageIDs = Set<String>()
        for item in plan {
            let total = try await backfillService.countMessages(matchingNormalizedSubjects: item.normalizedSubjects,
                                                                mailbox: item.target.mailbox,
                                                                account: item.target.account)
            guard total > 0 else { continue }
            let fetched = try await backfillService.fetchMessages(matchingNormalizedSubjects: item.normalizedSubjects,
                                                                  mailbox: item.target.mailbox,
                                                                  account: item.target.account,
                                                                  limit: max(total, preferredBatchSize),
                                                                  snippetLineLimit: snippetLineLimit)
            let filtered = Self.filterFolderRefreshMessages(fetched,
                                                            seedMessages: item.seedMessages,
                                                            normalizedSubjects: Set(item.normalizedSubjects),
                                                            referenceDate: referenceDate)
                .filter { seenMessageIDs.insert($0.messageID).inserted }
            guard !filtered.isEmpty else { continue }
            try await store.upsert(messages: filtered)
            fetchedCount += filtered.count
        }
        return fetchedCount
    }

    private static func folderRefreshSubjectPlan(messages: [EmailMessage]) -> [FolderRefreshSubjectPlanItem] {
        var messagesByTarget: [FolderRefreshTarget: [EmailMessage]] = [:]
        for message in messages {
            guard let target = folderRefreshTarget(for: message) else {
                continue
            }
            messagesByTarget[target, default: []].append(message)
        }

        return messagesByTarget
            .compactMap { target, targetMessages in
                let subjects = Array(Set(targetMessages.compactMap { message -> String? in
                    let normalized = MailboxRefreshSubjectNormalizer.normalize(message.subject)
                    return normalized.isEmpty ? nil : normalized
                })).sorted()
                guard !subjects.isEmpty else { return nil }
                return FolderRefreshSubjectPlanItem(target: target,
                                                    normalizedSubjects: subjects,
                                                    seedMessages: targetMessages)
            }
            .sorted {
                if $0.target.mailbox == $1.target.mailbox {
                    return $0.normalizedSubjects.joined(separator: "|") < $1.normalizedSubjects.joined(separator: "|")
                }
                return $0.target.mailbox < $1.target.mailbox
            }
    }

    private static func folderRefreshTarget(for message: EmailMessage) -> FolderRefreshTarget? {
        let mailbox = message.mailboxID.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = message.accountName.trimmingCharacters(in: .whitespacesAndNewlines)

        if mailbox.isEmpty ||
            mailbox.compare("all inboxes", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return FolderRefreshTarget(mailbox: "inbox", account: nil)
        }

        return FolderRefreshTarget(mailbox: mailbox,
                                   account: account.isEmpty ? nil : account)
    }

    private static func filterFolderRefreshMessages(_ fetched: [EmailMessage],
                                                    seedMessages: [EmailMessage],
                                                    normalizedSubjects: Set<String>,
                                                    referenceDate: Date) -> [EmailMessage] {
        let seedMessageIDs = Set(seedMessages.map { JWZThreader.normalizeIdentifier($0.messageID) }.filter { !$0.isEmpty })
        let seedRelatedIDs = seedMessages.reduce(into: seedMessageIDs) { result, message in
            if let inReplyTo = message.inReplyTo, !inReplyTo.isEmpty {
                result.insert(inReplyTo)
            }
            result.formUnion(message.references.filter { !$0.isEmpty })
        }

        return fetched.filter { message in
            let normalizedSubject = MailboxRefreshSubjectNormalizer.normalize(message.subject)
            guard normalizedSubjects.contains(normalizedSubject) else {
                return false
            }

            let candidateID = JWZThreader.normalizeIdentifier(message.messageID)
            if !candidateID.isEmpty && seedRelatedIDs.contains(candidateID) {
                return true
            }

            if let inReplyTo = message.inReplyTo, seedRelatedIDs.contains(inReplyTo) {
                return true
            }

            if !Set(message.references).isDisjoint(with: seedRelatedIDs) {
                return true
            }

            let account = message.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            let mailbox = message.mailboxID.trimmingCharacters(in: .whitespacesAndNewlines)
            let uniqueSubjects = Set(seedMessages.map { MailboxRefreshSubjectNormalizer.normalize($0.subject) }).filter { !$0.isEmpty }
            if uniqueSubjects.count == 1,
               !mailbox.isEmpty,
               !account.isEmpty,
               message.date <= referenceDate {
                return true
            }

            return false
        }
    }

#if DEBUG
    internal static func folderRefreshPlanForTesting(messages: [EmailMessage]) -> [(mailbox: String, account: String?, normalizedSubjects: [String])] {
        folderRefreshSubjectPlan(messages: messages).map { item in
            (mailbox: item.target.mailbox, account: item.target.account, normalizedSubjects: item.normalizedSubjects)
        }
    }
#endif

    private func mailboxMoveScopeForSelection(selectedNodes: [ThreadNode],
                                              account: String,
                                              destinationPath: String) async throws -> (threadIDs: Set<String>, candidates: [MailboxMoveCandidate]) {
        let effectiveThreadIDs = Set(selectedNodes.compactMap { effectiveThreadID(for: $0) })
        let selectedMessages = selectedNodes.map(\.message)
        var messageCandidates: [EmailMessage]
        if effectiveThreadIDs.isEmpty {
            messageCandidates = selectedMessages
        } else {
            let fetched = try await store.fetchMessages(threadIDs: effectiveThreadIDs)
            messageCandidates = fetched.isEmpty ? selectedMessages : fetched
        }

        let candidates = mailboxMoveCandidates(from: messageCandidates,
                                               account: account,
                                               destinationPath: destinationPath)
        return (effectiveThreadIDs, candidates)
    }

    nonisolated private static func mailboxMoveInput(from candidates: [MailboxMoveCandidate]) -> (internalTargets: [MailControl.InternalIDMoveTarget], unresolvedCount: Int) {
        var seenInternalIDs = Set<String>()
        var internalTargets: [MailControl.InternalIDMoveTarget] = []
        var unresolvedCount = 0
        internalTargets.reserveCapacity(candidates.count)

        for candidate in candidates {
            let internalID = candidate.message.internalMailID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !internalID.isEmpty {
                if seenInternalIDs.insert(internalID).inserted {
                    internalTargets.append(
                        MailControl.InternalIDMoveTarget(internalID: internalID,
                                                         sourceAccount: candidate.account,
                                                         sourceMailboxPath: candidate.mailboxPath)
                    )
                }
            } else {
                unresolvedCount += 1
            }
        }
        return (internalTargets, unresolvedCount)
    }

    nonisolated private static func executeMailboxMove(with input: (internalTargets: [MailControl.InternalIDMoveTarget], unresolvedCount: Int),
                                                       destinationPath: String,
                                                       account: String) async throws -> MailControl.MailboxMoveResult {
        var combined = MailControl.MailboxMoveResult(requestedCount: 0,
                                                     matchedCount: 0,
                                                     movedCount: 0,
                                                     errorCount: 0,
                                                     firstErrorNumber: nil,
                                                     firstErrorMessage: nil)

        if !input.internalTargets.isEmpty {
            do {
                let byInternalID = try await MailControl.moveMessagesByInternalID(targets: input.internalTargets,
                                                                                   to: destinationPath,
                                                                                   in: account)
                combined = Self.combineMailboxMoveResults(lhs: combined, rhs: byInternalID)
            } catch MailControlError.noMessagesMoved {
                combined = Self.combineMailboxMoveResults(lhs: combined,
                                                          rhs: MailControl.MailboxMoveResult(requestedCount: input.internalTargets.count,
                                                                                             matchedCount: 0,
                                                                                             movedCount: 0,
                                                                                             errorCount: 0,
                                                                                             firstErrorNumber: nil,
                                                                                             firstErrorMessage: nil))
            }
        }

        if combined.movedCount <= 0 {
            throw MailControlError.noMessagesMoved
        }
        return combined
    }

    nonisolated private static func combineMailboxMoveResults(lhs: MailControl.MailboxMoveResult,
                                                              rhs: MailControl.MailboxMoveResult) -> MailControl.MailboxMoveResult {
        MailControl.MailboxMoveResult(requestedCount: lhs.requestedCount + rhs.requestedCount,
                                      matchedCount: lhs.matchedCount + rhs.matchedCount,
                                      movedCount: lhs.movedCount + rhs.movedCount,
                                      errorCount: lhs.errorCount + rhs.errorCount,
                                      firstErrorNumber: lhs.firstErrorNumber ?? rhs.firstErrorNumber,
                                      firstErrorMessage: lhs.firstErrorMessage ?? rhs.firstErrorMessage)
    }

    private func applyOptimisticMailboxMove(candidates: [MailboxMoveCandidate],
                                            moveTargets: [MailControl.InternalIDMoveTarget],
                                            resolvedInternalIDsByNodeID: [String: String],
                                            destinationPath: String,
                                            destinationAccount: String) async {
        let destinationMailbox = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationAcct = destinationAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destinationMailbox.isEmpty, !destinationAcct.isEmpty else { return }
        let movedInternalIDs = Set(moveTargets.map { $0.internalID.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let optimisticUpdates = candidates.compactMap { candidate -> EmailMessage? in
            if movedInternalIDs.isEmpty {
                return candidate.message.assigning(mailboxID: destinationMailbox, accountName: destinationAcct)
            }
            let resolvedInternalID = resolvedInternalIDsByNodeID[candidate.nodeID]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let messageInternalID = candidate.message.internalMailID?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let internalID = [resolvedInternalID, messageInternalID]
                .compactMap({ $0 })
                .first(where: { !$0.isEmpty }),
                  movedInternalIDs.contains(internalID) else {
                return nil
            }
            return candidate.message.assigning(mailboxID: destinationMailbox, accountName: destinationAcct)
        }
        guard !optimisticUpdates.isEmpty else { return }
        do {
            try await store.upsert(messages: optimisticUpdates)
            await MainActor.run {
                self.scheduleRethread(delay: 0)
            }
        } catch {
            Log.app.error("Failed optimistic mailbox update after move: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cachedMessageCutoffDate(today: Date = Date(),
                                         calendar: Calendar = .current) -> Date? {
        let dayCount = max(dayWindowCount, 1)
        let startOfToday = calendar.startOfDay(for: today)
        return calendar.date(byAdding: .day, value: -(dayCount - 1), to: startOfToday)
    }

    private func pinnedThreadIDsToIncludeForRethread() async throws -> Set<String> {
        guard activeMailboxScope == .allEmails || activeMailboxScope == .actionItems || activeMailboxScope == .allFolders || activeMailboxScope == .allInboxes else { return [] }
        let storedFolders = try await store.fetchThreadFolders()
        let threadIDsByFolder = Self.folderThreadIDsByFolder(folders: storedFolders)
        if activeMailboxScope == .allFolders {
            return Set(threadIDsByFolder.values.flatMap(\.self))
        }
        guard !pinnedFolderIDs.isEmpty else { return [] }
        var included: Set<String> = []
        included.reserveCapacity(pinnedFolderIDs.count)
        for pinnedFolderID in pinnedFolderIDs {
            included.formUnion(threadIDsByFolder[pinnedFolderID] ?? [])
        }
        return included
    }

    internal static func rootsForMailboxScope(_ roots: [ThreadNode],
                                              scope: MailboxScope,
                                              folders: [ThreadFolder],
                                              manualGroupByMessageKey: [String: String],
                                              jwzThreadMap: [String: String]) -> [ThreadNode] {
        guard scope == .allFolders else { return roots }
        let folderThreadIDs = Set(folderThreadIDsByFolder(folders: folders).values.flatMap(\.self))
        guard !folderThreadIDs.isEmpty else { return [] }
        return roots.filter { root in
            guard let threadID = effectiveThreadID(for: root,
                                                   manualGroupByMessageKey: manualGroupByMessageKey,
                                                   jwzThreadMap: jwzThreadMap) else {
                return false
            }
            return folderThreadIDs.contains(threadID)
        }
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

    private func inferredMailboxDestinationForSelection(_ selectedNodes: [ThreadNode]) -> (account: String, path: String)? {
        guard !selectedNodes.isEmpty else { return nil }
        let destinations = selectedNodes.compactMap { node in
            Self.normalizedMailboxDestination(account: mailboxActionAccountName(for: node),
                                              path: mailboxPathForMailboxMove(message: node.message))
        }
        guard destinations.count == selectedNodes.count,
              let firstDestination = destinations.first else {
            return nil
        }
        let hasDiscrepancy = destinations.contains { destination in
            destination.account.caseInsensitiveCompare(firstDestination.account) != .orderedSame ||
                destination.path.caseInsensitiveCompare(firstDestination.path) != .orderedSame
        }
        return hasDiscrepancy ? nil : firstDestination
    }

    internal func addFolderForSelection() {
        let selectedNodes = selectedNodes(in: roots)
        guard !selectedNodes.isEmpty else { return }

        let effectiveThreadIDs = Set(selectedNodes.compactMap { effectiveThreadID(for: $0) })
        guard !effectiveThreadIDs.isEmpty else { return }

        let selectedFolderIDs = Set(effectiveThreadIDs.compactMap { folderMembershipByThreadID[$0] })
        let parentFolderID = selectedFolderIDs.count == 1 ? selectedFolderIDs.first : nil
        let inheritedMailboxDestination = parentFolderID.flatMap { folderID in
            threadFolders.first(where: { $0.id == folderID })?.mailboxDestination
        }
        let inferredMailboxDestination = inferredMailboxDestinationForSelection(selectedNodes) ?? inheritedMailboxDestination

        let latestSubjectNode = selectedNodes.max(by: { $0.message.date < $1.message.date })
        let defaultTitle = latestSubjectNode.map { node in
            node.message.subject.isEmpty ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing") : node.message.subject
        } ?? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing")

        let folder = ThreadFolder(id: "folder-\(UUID().uuidString.lowercased())",
                                  title: defaultTitle,
                                  color: ThreadFolderColor.defaultNewFolder,
                                  threadIDs: effectiveThreadIDs,
                                  parentID: parentFolderID,
                                  mailboxAccount: inferredMailboxDestination?.account,
                                  mailboxPath: inferredMailboxDestination?.path)
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

    private func jumpToFolderNode(folderID: String, preferredNodeID: String) {
        if folderJumpInProgressIDs.contains(folderID) {
            Log.app.debug("Folder minimap jump ignored while another jump is running. folderID=\(folderID, privacy: .public)")
            return
        }
        folderJumpInProgressIDs.insert(folderID)
        updateJumpPhase(.resolvingTarget, folderID: folderID)
        folderJumpTasks[folderID]?.cancel()
        folderJumpTasks[folderID] = Task { [weak self] in
            guard let self else { return }
            let threadIDs = folderThreadIDs(for: folderID)
            guard !threadIDs.isEmpty else {
                completeFolderJump(folderID: folderID)
                return
            }
            guard let preferredNode = Self.node(matching: preferredNodeID, in: roots),
                  let preferredThreadID = effectiveThreadID(for: preferredNode),
                  threadIDs.contains(preferredThreadID) else {
                completeFolderJump(folderID: folderID)
                return
            }

            updateJumpPhase(.expandingCoverage, folderID: folderID)
            let expansion = await expandDayWindow(toInclude: preferredNode.message.date)
            if !expansion.reachedRequiredDayCount {
                completeFolderJump(folderID: folderID)
                return
            }
            guard !Task.isCancelled else {
                completeFolderJump(folderID: folderID)
                return
            }

            selectNode(id: preferredNodeID)
            updateJumpPhase(.awaitingAnchor, folderID: folderID)
            guard let scrollTargetID = await waitForRenderableJumpTargetID(preferredNodeID: preferredNodeID,
                                                                           folderThreadIDs: threadIDs,
                                                                           boundary: .newest) else {
                completeFolderJump(folderID: folderID)
                return
            }
            guard !Task.isCancelled else {
                completeFolderJump(folderID: folderID)
                return
            }
            updateJumpPhase(.scrolling, folderID: folderID)
            enqueueScrollRequest(nodeID: scrollTargetID,
                                 folderID: folderID,
                                 boundary: .newest,
                                 selectedBoundaryNodeID: preferredNodeID)
        }
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

    internal static func makeFolderMinimapModel(folderID: String,
                                                sourceNodes: [FolderMinimapSourceNode]) -> FolderMinimapModel? {
        guard !sourceNodes.isEmpty else { return nil }

        var nodesByThreadID: [String: [ThreadNode]] = [:]
        for sourceNode in sourceNodes {
            let threadID = sourceNode.threadID
            let node = sourceNode.node
            nodesByThreadID[threadID, default: []].append(node)
        }

        let orderedThreadIDs = nodesByThreadID
            .compactMap { threadID, threadNodes -> (String, Date)? in
                guard let latestDate = threadNodes.map(\.message.date).max() else { return nil }
                return (threadID, latestDate)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0 < rhs.0
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
        guard !orderedThreadIDs.isEmpty else { return nil }

        let threadIndexByID = Dictionary(uniqueKeysWithValues: orderedThreadIDs.enumerated().map { ($0.element, $0.offset) })
        let orderedByDate = sourceNodes.map(\.node).sorted { lhs, rhs in
            if lhs.message.date == rhs.message.date {
                return lhs.id < rhs.id
            }
            return lhs.message.date < rhs.message.date
        }
        guard let oldestDate = orderedByDate.first?.message.date,
              let newestDate = orderedByDate.last?.message.date else {
            return nil
        }
        let dateRange = newestDate.timeIntervalSince(oldestDate)

        let mappedNodes = sourceNodes.compactMap { sourceNode -> FolderMinimapNode? in
            let threadID = sourceNode.threadID
            let node = sourceNode.node
            guard let threadIndex = threadIndexByID[threadID] else { return nil }
            let normalizedX: CGFloat
            if orderedThreadIDs.count == 1 {
                normalizedX = 0.5
            } else {
                normalizedX = (CGFloat(threadIndex) + 0.5) / CGFloat(orderedThreadIDs.count)
            }
            let normalizedY: CGFloat
            if dateRange > 0 {
                let relative = node.message.date.timeIntervalSince(oldestDate) / dateRange
                normalizedY = CGFloat(1 - relative)
            } else {
                normalizedY = 0.5
            }
            return FolderMinimapNode(id: node.id,
                                     threadID: threadID,
                                     normalizedX: normalizedX,
                                     normalizedY: normalizedY)
        }
        guard !mappedNodes.isEmpty else { return nil }

        var edges: [FolderMinimapEdge] = []
        for threadID in orderedThreadIDs {
            guard let threadNodes = nodesByThreadID[threadID] else { continue }
            let sortedThreadNodes = threadNodes.sorted { lhs, rhs in
                if lhs.message.date == rhs.message.date {
                    return lhs.id < rhs.id
                }
                return lhs.message.date < rhs.message.date
            }
            guard sortedThreadNodes.count >= 2 else { continue }
            for index in 1..<sortedThreadNodes.count {
                edges.append(FolderMinimapEdge(sourceID: sortedThreadNodes[index - 1].id,
                                               destinationID: sortedThreadNodes[index].id))
            }
        }

        return FolderMinimapModel(folderID: folderID,
                                  nodes: mappedNodes,
                                  edges: edges,
                                  newestDate: newestDate,
                                  oldestDate: oldestDate,
                                  timeTicks: makeFolderMinimapTimeTicks(nodeDates: orderedByDate.map { $0.message.date }))
    }

    internal static func resolveFolderMinimapTargetNodeID(model: FolderMinimapModel,
                                                          normalizedPoint: CGPoint,
                                                          mappingTolerance: CGFloat = 0.35) -> String? {
        guard !model.nodes.isEmpty else { return nil }
        let x = min(max(normalizedPoint.x, 0), 1)
        let y = min(max(normalizedPoint.y, 0), 1)
        let clampedPoint = CGPoint(x: x, y: y)

        let sortedColumns = Dictionary(grouping: model.nodes, by: \.threadID)
            .compactMap { _, nodes -> CGFloat? in nodes.first?.normalizedX }
            .sorted()
        guard !sortedColumns.isEmpty else { return nil }
        let nearestColumnX = sortedColumns.min { abs($0 - clampedPoint.x) < abs($1 - clampedPoint.x) } ?? clampedPoint.x
        let shouldUseCoordinateMapping = abs(nearestColumnX - clampedPoint.x) <= mappingTolerance

        if shouldUseCoordinateMapping {
            let columnNodes = model.nodes.filter { abs($0.normalizedX - nearestColumnX) <= 0.0001 }
            if let matched = columnNodes.min(by: { lhs, rhs in
                let lhsDelta = abs(lhs.normalizedY - clampedPoint.y)
                let rhsDelta = abs(rhs.normalizedY - clampedPoint.y)
                if lhsDelta == rhsDelta {
                    return lhs.id < rhs.id
                }
                return lhsDelta < rhsDelta
            }) {
                return matched.id
            }
        }

        return model.nodes.min { lhs, rhs in
            let lhsDistance = hypot(lhs.normalizedX - clampedPoint.x, lhs.normalizedY - clampedPoint.y)
            let rhsDistance = hypot(rhs.normalizedX - clampedPoint.x, rhs.normalizedY - clampedPoint.y)
            if lhsDistance == rhsDistance {
                return lhs.id < rhs.id
            }
            return lhsDistance < rhsDistance
        }?.id
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

    internal static func makeFolderMinimapTimeTicks(nodeDates: [Date],
                                                    tickCount: Int = 5) -> [FolderMinimapTimeTick] {
        guard !nodeDates.isEmpty else { return [] }

        let calendar = Calendar.current
        let latestByDay = nodeDates.reduce(into: [Date: Date]()) { result, date in
            let day = calendar.startOfDay(for: date)
            if let existing = result[day] {
                result[day] = max(existing, date)
            } else {
                result[day] = date
            }
        }
        let uniqueSortedDates = latestByDay.values.sorted(by: >)
        guard let newestDate = uniqueSortedDates.first,
              let oldestDate = uniqueSortedDates.last else {
            return []
        }

        let selectedDates: [Date]
        let clampedTickCount = max(tickCount, 2)
        if uniqueSortedDates.count <= clampedTickCount {
            selectedDates = uniqueSortedDates
        } else {
            var selectedIndices: [Int] = []
            selectedIndices.reserveCapacity(clampedTickCount)
            for index in 0..<clampedTickCount {
                let progress = Double(index) / Double(clampedTickCount - 1)
                let scaledIndex = Int(round(progress * Double(uniqueSortedDates.count - 1)))
                if selectedIndices.last != scaledIndex {
                    selectedIndices.append(scaledIndex)
                }
            }
            selectedDates = selectedIndices.map { uniqueSortedDates[$0] }
        }

        let range = newestDate.timeIntervalSince(oldestDate)
        guard range > 0 else {
            return selectedDates.map { FolderMinimapTimeTick(date: $0, normalizedY: 0.5) }
        }
        return selectedDates.map { date in
            let progress = CGFloat(newestDate.timeIntervalSince(date) / range)
            return FolderMinimapTimeTick(date: date, normalizedY: progress)
        }
    }

    internal static func resolveFolderMinimapSelectedNodeID(selectedNodeID: String?,
                                                            model: FolderMinimapModel) -> String? {
        guard let selectedNodeID else { return nil }
        return model.nodes.contains(where: { $0.id == selectedNodeID }) ? selectedNodeID : nil
    }

    internal static func makeFolderMinimapViewportSnapshot(layout: ThreadCanvasLayout,
                                                           scrollOffsetX: CGFloat,
                                                           scrollOffsetY: CGFloat,
                                                           viewportWidth: CGFloat,
                                                           viewportHeight: CGFloat) -> FolderMinimapViewportSnapshot {
        let clampedViewport = CGRect(x: max(scrollOffsetX, 0),
                                     y: max(scrollOffsetY, 0),
                                     width: max(viewportWidth, 1),
                                     height: max(viewportHeight, 1))
        var rectsByFolderID: [String: CGRect] = [:]
        let columnsByID = Dictionary(uniqueKeysWithValues: layout.columns.map { ($0.id, $0) })
        for overlay in layout.folderOverlays {
            let folderNodes = overlay.columnIDs
                .compactMap { columnsByID[$0] }
                .flatMap(\.nodes)
            guard !folderNodes.isEmpty else { continue }
            let nodeMinY = folderNodes.map { $0.frame.minY }.min() ?? overlay.frame.minY
            let nodeMaxY = folderNodes.map { $0.frame.maxY }.max() ?? overlay.frame.maxY
            let nodeOverlayFrame = CGRect(x: overlay.frame.minX,
                                          y: nodeMinY,
                                          width: overlay.frame.width,
                                          height: max(nodeMaxY - nodeMinY, 1))
            guard let normalized = projectFolderMinimapViewport(overlayFrame: nodeOverlayFrame,
                                                                viewportRect: clampedViewport) else {
                continue
            }
            rectsByFolderID[overlay.id] = normalized
        }
        return FolderMinimapViewportSnapshot(normalizedRectByFolderID: rectsByFolderID)
    }

    internal static func projectFolderMinimapViewport(overlayFrame: CGRect,
                                                      viewportRect: CGRect) -> CGRect? {
        guard overlayFrame.width > 0, overlayFrame.height > 0 else { return nil }
        let intersection = overlayFrame.intersection(viewportRect)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        let normalizedX = min(max((intersection.minX - overlayFrame.minX) / overlayFrame.width, 0), 1)
        let normalizedY = min(max((intersection.minY - overlayFrame.minY) / overlayFrame.height, 0), 1)
        let normalizedWidth = min(max(intersection.width / overlayFrame.width, 0), 1 - normalizedX)
        let normalizedHeight = min(max(intersection.height / overlayFrame.height, 0), 1 - normalizedY)
        guard normalizedWidth > 0, normalizedHeight > 0 else { return nil }
        return CGRect(x: normalizedX, y: normalizedY, width: normalizedWidth, height: normalizedHeight)
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
                                      rowPackingMode: ThreadCanvasRowPackingMode = .dateBucketed,
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
                            rowPackingMode: rowPackingMode,
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
                                     rowPackingMode: ThreadCanvasRowPackingMode = .dateBucketed,
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
        let sourceDays: [ThreadCanvasDay]
        switch rowPackingMode {
        case .dateBucketed:
            let dayHeights = dayHeights(for: roots,
                                        metrics: metrics,
                                        viewMode: viewMode,
                                        today: today,
                                        calendar: calendar,
                                        nodeSummaries: nodeSummaries,
                                        timelineTagsByNodeID: timelineTagsByNodeID,
                                        measurementCache: &measurementCache)
            var currentYOffset = metrics.contentPadding
            sourceDays = (0..<metrics.dayCount).map { index -> ThreadCanvasDay in
                let date = ThreadCanvasDateHelper.dayDate(for: index, today: today, calendar: calendar)
                let label = ThreadCanvasDateHelper.label(for: date)
                let height = dayHeights[index] ?? metrics.dayHeight
                let day = ThreadCanvasDay(id: index, date: date, label: label, yOffset: currentYOffset, height: height)
                currentYOffset += height
                return day
            }
        case .folderAlignedDense:
            sourceDays = [ThreadCanvasDay(id: 0,
                                          date: today,
                                          label: ThreadCanvasDateHelper.label(for: today),
                                          yOffset: metrics.contentPadding,
                                          height: metrics.dayHeight)]
        }
        let dayLookup = Dictionary(uniqueKeysWithValues: sourceDays.map { ($0.id, $0) })

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
                                            rowPackingMode: rowPackingMode,
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

        var layoutColumns = columns
        let contentHeight: CGFloat
        let layoutDays: [ThreadCanvasDay]
        switch rowPackingMode {
        case .dateBucketed:
            layoutDays = sourceDays
            contentHeight = metrics.contentPadding * 2
                + sourceDays.reduce(0) { $0 + $1.height }
        case .folderAlignedDense:
            let packed = densePackColumnsByFolder(columns: columns,
                                                  metrics: metrics,
                                                  viewMode: viewMode)
            layoutColumns = packed.columns
            contentHeight = packed.contentHeight
            let dayHeight = max(contentHeight - (metrics.contentPadding * 2), metrics.dayHeight)
            layoutDays = [ThreadCanvasDay(id: 0,
                                          date: today,
                                          label: ThreadCanvasDateHelper.label(for: today),
                                          yOffset: metrics.contentPadding,
                                          height: dayHeight)]
        }

        let columnCount = CGFloat(columns.count)
        let totalWidth = metrics.contentPadding * 2
            + metrics.dayLabelWidth
            + (columnCount * metrics.columnWidth)
            + max(columnCount - 1, 0) * metrics.columnSpacing
        let folderOverlays = folderOverlaysForLayout(columns: layoutColumns,
                                                     folders: folders,
                                                     pinnedFolderIDs: pinnedFolderIDs,
                                                     membership: normalizedMembership,
                                                     contentHeight: contentHeight,
                                                     metrics: metrics)
        let populatedDayIndices = Set(layoutColumns.flatMap { $0.nodes.map(\.dayIndex) })
        return ThreadCanvasLayout(days: layoutDays,
                                  columns: layoutColumns,
                                  contentSize: CGSize(width: totalWidth, height: contentHeight),
                                  folderOverlays: folderOverlays,
                                  populatedDayIndices: populatedDayIndices)
    }

    private static func densePackColumnsByFolder(columns: [ThreadCanvasColumn],
                                                 metrics: ThreadCanvasLayoutMetrics,
                                                 viewMode: ThreadCanvasViewMode) -> (columns: [ThreadCanvasColumn], contentHeight: CGFloat) {
        var packedColumns = columns
        let groupedIndices = Dictionary(grouping: columns.indices) { index -> String? in
            columns[index].folderID
        }
        let orderedGroups = groupedIndices
            .sorted { lhs, rhs in
                let lhsMinX = lhs.value.map { columns[$0].xOffset }.min() ?? .greatestFiniteMagnitude
                let rhsMinX = rhs.value.map { columns[$0].xOffset }.min() ?? .greatestFiniteMagnitude
                return lhsMinX < rhsMinX
            }
            .map(\.value)

        var globalMaxNodeY: CGFloat = metrics.contentPadding
        for groupIndices in orderedGroups {
            let sortedGroupIndices = groupIndices.sorted { lhs, rhs in
                columns[lhs].xOffset < columns[rhs].xOffset
            }
            let groupedNodes: [[ThreadCanvasNode]] = sortedGroupIndices.map { index in
                columns[index].nodes.sorted { lhs, rhs in
                    if lhs.message.date == rhs.message.date {
                        return lhs.id < rhs.id
                    }
                    return lhs.message.date > rhs.message.date
                }
            }
            let rowCount = groupedNodes.map(\.count).max() ?? 0
            guard rowCount > 0 else { continue }

            var rowHeights: [CGFloat] = []
            rowHeights.reserveCapacity(rowCount)
            for row in 0..<rowCount {
                let rowHeight: CGFloat
                switch viewMode {
                case .timeline:
                    rowHeight = groupedNodes.compactMap { nodes in
                        guard row < nodes.count else { return nil }
                        return nodes[row].frame.height
                    }
                    .max() ?? metrics.nodeHeight
                case .default:
                    rowHeight = metrics.nodeHeight
                }
                rowHeights.append(max(rowHeight, 1))
            }

            var rowTopOffsets: [CGFloat] = []
            rowTopOffsets.reserveCapacity(rowCount)
            var cursorY = metrics.contentPadding + metrics.nodeVerticalSpacing
            for rowHeight in rowHeights {
                rowTopOffsets.append(cursorY)
                cursorY += rowHeight + metrics.nodeVerticalSpacing
            }

            for (groupPosition, columnIndex) in sortedGroupIndices.enumerated() {
                let sourceNodes = groupedNodes[groupPosition]
                var updatedNodes: [ThreadCanvasNode] = []
                updatedNodes.reserveCapacity(sourceNodes.count)
                for (rowIndex, node) in sourceNodes.enumerated() {
                    let rowTop = rowTopOffsets[rowIndex]
                    let nodeHeight = viewMode == .timeline ? node.frame.height : metrics.nodeHeight
                    let frame = CGRect(x: node.frame.minX,
                                       y: rowTop,
                                       width: node.frame.width,
                                       height: nodeHeight)
                    updatedNodes.append(ThreadCanvasNode(id: node.id,
                                                         message: node.message,
                                                         threadID: node.threadID,
                                                         jwzThreadID: node.jwzThreadID,
                                                         frame: frame,
                                                         dayIndex: 0,
                                                         isManualAttachment: node.isManualAttachment))
                }
                packedColumns[columnIndex] = ThreadCanvasColumn(id: columns[columnIndex].id,
                                                                title: columns[columnIndex].title,
                                                                xOffset: columns[columnIndex].xOffset,
                                                                nodes: updatedNodes,
                                                                unreadCount: columns[columnIndex].unreadCount,
                                                                latestDate: columns[columnIndex].latestDate,
                                                                folderID: columns[columnIndex].folderID)
            }

            let groupMaxY = sortedGroupIndices.compactMap { index in
                packedColumns[index].nodes.map(\.frame.maxY).max()
            }.max() ?? globalMaxNodeY
            globalMaxNodeY = max(globalMaxNodeY, groupMaxY)
        }

        let minimumHeight = (metrics.contentPadding * 2) + metrics.dayHeight
        let contentHeight = max(globalMaxNodeY + metrics.contentPadding, minimumHeight)
        return (packedColumns, contentHeight)
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
                                    rowPackingMode: ThreadCanvasRowPackingMode,
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
            let dayIndex: Int
            switch rowPackingMode {
            case .folderAlignedDense:
                // In All Folders mode we pack rows independently of the day window.
                dayIndex = 0
            case .dateBucketed:
                guard let resolvedDayIndex = ThreadCanvasDateHelper.dayIndex(for: node.message.date,
                                                                              today: today,
                                                                              calendar: calendar,
                                                                              dayCount: metrics.dayCount) else {
                    continue
                }
                dayIndex = resolvedDayIndex
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
            if count == 0 {
                heights[dayIndex] = metrics.collapsedDayHeight
            } else {
                heights[dayIndex] = max(metrics.dayHeight, requiredDefaultDayHeight(nodeCount: count, metrics: metrics))
            }
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
            if required == 0 {
                heights[dayIndex] = metrics.collapsedDayHeight
            } else {
                heights[dayIndex] = max(metrics.dayHeight, required)
            }
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
        let mailboxHeight = MailboxPathFormatter.leafName(from: node.message.mailboxID) == nil ? 0 : assets.mailboxHeight
        let topLineHeight = max(assets.timeHeight, tagHeight, mailboxHeight, dotSize)
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

    private static func descendantFolderIDs(of folderID: String,
                                            childrenByParent: [String: [String]]) -> [String] {
        var orderedDescendantIDs: [String] = []
        var pendingIDs = childrenByParent[folderID] ?? []
        var nextIndex = 0

        while nextIndex < pendingIDs.count {
            let currentID = pendingIDs[nextIndex]
            nextIndex += 1
            orderedDescendantIDs.append(currentID)
            pendingIDs.append(contentsOf: childrenByParent[currentID] ?? [])
        }

        return orderedDescendantIDs
    }

    private static func folderOverlaysForLayout(columns: [ThreadCanvasColumn],
                                                folders: [ThreadFolder],
                                                pinnedFolderIDs: Set<String>,
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

        var pinnedHeaderContextFolderIDs: Set<String> = []
        pinnedHeaderContextFolderIDs.reserveCapacity(pinnedFolderIDs.count * 2)
        for folderID in pinnedFolderIDs where hierarchy.foldersByID[folderID] != nil {
            var currentID: String? = folderID
            while let resolvedID = currentID,
                  hierarchy.foldersByID[resolvedID] != nil,
                  !pinnedHeaderContextFolderIDs.contains(resolvedID) {
                pinnedHeaderContextFolderIDs.insert(resolvedID)
                currentID = hierarchy.foldersByID[resolvedID]?.parentID
            }
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
            let frame: CGRect
            if nodes.isEmpty {
                guard pinnedHeaderContextFolderIDs.contains(folder.id) else { continue }
                frame = CGRect(x: minX,
                               y: 0,
                               width: maxX - minX,
                               height: 0)
            } else {
                let minY = nodes.map { $0.frame.minY }.min() ?? 0
                let maxY = nodes.map { $0.frame.maxY }.max() ?? contentHeight
                let headerInset = metrics.nodeVerticalSpacing * 1.3
                let paddedMinY = max(0, minY - headerInset)
                let paddedHeight = (maxY - minY) + metrics.nodeVerticalSpacing * 2 + headerInset
                frame = CGRect(x: minX,
                               y: paddedMinY,
                               width: maxX - minX,
                               height: paddedHeight)
            }

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

    // MARK: - Needs Attention

    /// Threads updated more than this many days ago do not count as needing attention.
    internal static let needsAttentionRecencyDays: Int = 7

    /// Extracts a lowercased email address from a header value like `"Name <user@example.com>"`.
    /// Falls back to the full trimmed, lowercased string when no angle brackets are found.
    internal static func extractEmailAddress(from headerValue: String) -> String {
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "<"),
              let close = trimmed.lastIndex(of: ">"),
              open < close else {
            return trimmed.lowercased()
        }
        return String(trimmed[trimmed.index(after: open)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Returns the newest message in a thread tree by date.
    internal static func newestMessage(in node: ThreadNode) -> EmailMessage {
        node.children.reduce(node.message) { current, child in
            let childNewest = newestMessage(in: child)
            return childNewest.date > current.date ? childNewest : current
        }
    }

    /// Builds a set of lowercased email addresses that likely belong to the user
    /// by collecting addresses that appear in the `to` field of messages.
    internal static func buildUserAddresses(from nodes: [ThreadNode]) -> Set<String> {
        var addresses = Set<String>()
        for node in flatten(nodes: nodes) {
            let toField = node.message.to
            guard !toField.isEmpty else { continue }
            // Split on commas for multi-recipient fields, then extract each address.
            for part in toField.split(separator: ",") {
                let addr = extractEmailAddress(from: String(part))
                if !addr.isEmpty {
                    addresses.insert(addr)
                }
            }
        }
        return addresses
    }

    /// Counts threads that need attention: newest message is inbound (not from the user),
    /// updated within the recency window, and not tracked as an action item.
    internal static func computeNeedsAttentionCount(
        roots: [ThreadNode],
        actionItemThreadIDs: Set<String>,
        userAddresses: Set<String>,
        now: Date,
        calendar: Calendar
    ) -> Int {
        guard let cutoff = calendar.date(byAdding: .day, value: -needsAttentionRecencyDays, to: now) else {
            return 0
        }
        var count = 0
        for root in roots {
            let threadID = root.message.threadKey
            if actionItemThreadIDs.contains(threadID) { continue }
            let newest = newestMessage(in: root)
            if newest.date < cutoff { continue }
            let senderAddress = extractEmailAddress(from: newest.from)
            if userAddresses.contains(senderAddress) { continue }
            count += 1
        }
        return count
    }

    internal static func folderMembershipMap(for folders: [ThreadFolder]) -> [String: String] {
        folders.reduce(into: [String: String]()) { result, folder in
            folder.threadIDs.forEach { result[$0] = folder.id }
        }
    }

    internal static func reconcileFolderThreadIdentities(folders: [ThreadFolder],
                                                         roots: [ThreadNode],
                                                         jwzThreadMap: [String: String]) -> FolderMoveUpdate? {
        guard !folders.isEmpty, !roots.isEmpty else { return nil }

        var aliasesByThreadID: [String: String] = [:]
        for node in flatten(nodes: roots) {
            let currentThreadID = node.message.threadID ?? node.id
            let messageKey = node.message.threadKey
            aliasesByThreadID[currentThreadID] = currentThreadID
            if let jwzThreadID = jwzThreadMap[messageKey], jwzThreadID != currentThreadID {
                aliasesByThreadID[jwzThreadID] = currentThreadID
            }
        }

        var didChange = false
        let reconciledFolders = folders.map { folder -> ThreadFolder in
            let reconciledThreadIDs = Set(folder.threadIDs.map { aliasesByThreadID[$0] ?? $0 })
            if reconciledThreadIDs != folder.threadIDs {
                didChange = true
            }
            var updated = folder
            updated.threadIDs = reconciledThreadIDs
            return updated
        }

        guard didChange else { return nil }
        return FolderMoveUpdate(folders: reconciledFolders,
                                deletedFolderIDs: [],
                                membership: folderMembershipMap(for: reconciledFolders))
    }

    internal struct FolderMoveUpdate {
        internal let folders: [ThreadFolder]
        internal let deletedFolderIDs: Set<String>
        internal let membership: [String: String]
    }

    internal struct FolderHierarchyUpdate {
        internal let folders: [ThreadFolder]
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

    internal static func applyFolderMove(folderID: String,
                                         toParentFolderID parentFolderID: String?,
                                         folders: [ThreadFolder]) -> FolderHierarchyUpdate? {
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }) else { return nil }
        if let parentFolderID {
            guard parentFolderID != folderID,
                  folders.contains(where: { $0.id == parentFolderID }) else {
                return nil
            }
            let descendantIDs = Set(descendantFolderIDs(of: folderID,
                                                        childrenByParent: childFolderIDsByParent(folders: folders)))
            guard !descendantIDs.contains(parentFolderID) else { return nil }
        }

        guard folders[folderIndex].parentID != parentFolderID else { return nil }

        var updatedFolders = folders
        updatedFolders[folderIndex].parentID = parentFolderID
        return FolderHierarchyUpdate(folders: updatedFolders,
                                     membership: folderMembershipMap(for: updatedFolders))
    }

    internal static func remapThreadIDsInFolders(_ sourceThreadIDs: Set<String>,
                                                 to replacementThreadID: String,
                                                 preferredSourceThreadID: String?,
                                                 folders: [ThreadFolder]) -> FolderMoveUpdate? {
        guard !sourceThreadIDs.isEmpty,
              !replacementThreadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !folders.isEmpty else {
            return nil
        }

        var updatedFolders = folders
        var sourceFolderIDs: Set<String> = []
        for index in updatedFolders.indices {
            let removed = updatedFolders[index].threadIDs.intersection(sourceThreadIDs)
            guard !removed.isEmpty else { continue }
            sourceFolderIDs.insert(updatedFolders[index].id)
            updatedFolders[index].threadIDs.subtract(sourceThreadIDs)
        }

        guard !sourceFolderIDs.isEmpty else { return nil }

        let preferredFolderID = preferredSourceThreadID.flatMap { threadID in
            folders.first(where: { $0.threadIDs.contains(threadID) })?.id
        }
        let destinationFolderID = preferredFolderID ?? (sourceFolderIDs.count == 1 ? sourceFolderIDs.first : nil)
        if let destinationFolderID,
           let destinationIndex = updatedFolders.firstIndex(where: { $0.id == destinationFolderID }) {
            updatedFolders[destinationIndex].threadIDs.insert(replacementThreadID)
        }

        let childIDsByParent = childFolderIDsByParent(folders: updatedFolders)
        var deletedFolderIDs: Set<String> = []
        updatedFolders.removeAll { folder in
            guard folder.threadIDs.isEmpty else { return false }
            guard (childIDsByParent[folder.id]?.isEmpty ?? true) else { return false }
            deletedFolderIDs.insert(folder.id)
            return true
        }

        let membership = folderMembershipMap(for: updatedFolders)
        guard updatedFolders != folders else { return nil }
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

    internal static func preferredFitNodeBounds(for layout: ThreadCanvasLayout,
                                                viewportRect: CGRect,
                                                calendar: Calendar,
                                                latestNodeLimit: Int = 8) -> CGRect? {
        let visibleNodes = layout.columns
            .flatMap(\.nodes)
            .filter { $0.frame.intersects(viewportRect) }
        if let visibleBounds = nodeBounds(for: visibleNodes) {
            return visibleBounds
        }

        let nodes = layout.columns
            .flatMap(\.nodes)
            .sorted { lhs, rhs in
                if lhs.message.date == rhs.message.date {
                    return lhs.id < rhs.id
                }
                return lhs.message.date > rhs.message.date
            }
        guard let newest = nodes.first else { return nil }

        let newestDay = calendar.startOfDay(for: newest.message.date)
        let recentNodes = nodes.filter { node in
            let nodeDay = calendar.startOfDay(for: node.message.date)
            guard let dayDelta = calendar.dateComponents([.day], from: nodeDay, to: newestDay).day else {
                return false
            }
            return dayDelta <= 1
        }
        let candidates = Array((recentNodes.isEmpty ? nodes : recentNodes).prefix(latestNodeLimit))
        return nodeBounds(for: candidates)
    }

    private static func nodeBounds(for nodes: [ThreadCanvasNode]) -> CGRect? {
        guard let firstFrame = nodes.first?.frame else { return nil }
        return nodes.dropFirst().reduce(firstFrame) { partial, node in
            partial.union(node.frame)
        }
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
