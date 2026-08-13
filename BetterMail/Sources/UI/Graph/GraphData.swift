import CoreGraphics
import Foundation

internal enum GraphImportance: String, Codable, Hashable {
    case low
    case medium
    case high

    internal static func from(messageCount: Int) -> GraphImportance {
        if messageCount < 4 { return .low }
        if messageCount < 9 { return .medium }
        return .high
    }

    internal var localizedTitle: String {
        switch self {
        case .low:
            return NSLocalizedString("graph.importance.low", comment: "Low graph importance")
        case .medium:
            return NSLocalizedString("graph.importance.medium", comment: "Medium graph importance")
        case .high:
            return NSLocalizedString("graph.importance.high", comment: "High graph importance")
        }
    }

    internal var ringWidth: CGFloat {
        switch self {
        case .low:
            return 1.0
        case .medium:
            return 1.2
        case .high:
            return 1.6
        }
    }
}

internal enum GraphNodeKind: String, Codable, Hashable {
    case center
    case folderGroup
    case ghostGroup
    case thread
    case remaining
    case message
}

internal enum GraphEdgeKind: String, Codable, Hashable {
    case trunk
    case grouping
    case suggested
    case chain
    case remaining
}

internal enum GraphGroupingKind: String, Codable, Hashable {
    case folder
    case suggestedTopic
}

internal enum GraphFolderSuggestionError: LocalizedError {
    case invalidSuggestion

    internal var errorDescription: String? {
        NSLocalizedString("graph.group.error.invalid",
                          comment: "Error when a graph topic suggestion cannot form a folder")
    }
}

internal struct GraphGrouping: Identifiable, Codable, Hashable {
    internal let id: String
    internal let title: String
    internal let kind: GraphGroupingKind
    internal let threadIDs: [String]
    internal let rawThreadIDs: [String]
    internal let sourceFolderID: String?
    internal let sourceTag: String?
    internal let normalizedTopic: String?
    internal let supportingReason: String?
    internal let reviewMembers: [GraphTopicMember]

    internal init(id: String,
                  title: String,
                  kind: GraphGroupingKind,
                  threadIDs: [String],
                  rawThreadIDs: [String],
                  sourceFolderID: String?,
                  sourceTag: String?,
                  normalizedTopic: String? = nil,
                  supportingReason: String? = nil,
                  reviewMembers: [GraphTopicMember] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.threadIDs = threadIDs
        self.rawThreadIDs = rawThreadIDs
        self.sourceFolderID = sourceFolderID
        self.sourceTag = sourceTag
        self.normalizedTopic = normalizedTopic
        self.supportingReason = supportingReason
        self.reviewMembers = reviewMembers
    }

    internal var isSuggestion: Bool {
        kind == .suggestedTopic
    }

    /// Stable, user-preference identity for this exact suggested grouping.
    /// Confirmed folders intentionally have no dismissal identity.
    internal var suggestionDismissalID: String? {
        guard isSuggestion, let topic = normalizedTopic ?? sourceTag else { return nil }
        return GraphData.suggestionDismissalID(forTopic: topic,
                                               rawThreadIDs: rawThreadIDs)
    }

    internal var memberCount: Int {
        max(reviewMembers.count, rawThreadIDs.count, threadIDs.count)
    }

    internal var nodeKind: GraphNodeKind {
        isSuggestion ? .ghostGroup : .folderGroup
    }

    internal var radius: CGFloat {
        18 + CGFloat(min(memberCount, 8)) * 1.4
    }

    internal var accessibilityLabel: String {
        let key = isSuggestion
            ? "graph.accessibility.group.suggestion"
            : "graph.accessibility.group.folder"
        return String.localizedStringWithFormat(
            NSLocalizedString(key, comment: "VoiceOver label for graph grouping node"),
            title,
            memberCount
        )
    }
}

internal struct GraphCenter: Codable, Hashable {
    internal let id: String
    internal let title: String

    internal static let you = GraphCenter(id: "you",
                                          title: NSLocalizedString("graph.center.you", comment: "Center graph node title"))
}

internal struct GraphThread: Identifiable, Codable, Hashable {
    internal let id: String
    internal let rawThreadID: String
    internal let rootNodeID: String
    internal let subject: String
    internal let displayTitle: String
    internal let snippet: String
    internal let sender: String
    internal let mailboxPath: String
    internal let accountName: String
    internal let lastUpdated: Date
    internal let messageCount: Int
    internal let unreadCount: Int
    internal let importance: GraphImportance
    internal let isLive: Bool
    internal let angle: Double
    internal let tags: [String]
    internal let messageIDs: [String]

    internal var radius: CGFloat {
        14 + CGFloat(min(messageCount, 12)) * 1.4
    }

    internal var accessibilityLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("graph.accessibility.thread.label",
                              comment: "VoiceOver label for graph thread node"),
            displayTitle,
            messageCount,
            importance.localizedTitle
        )
    }

    internal var accessibilityValue: String {
        String.localizedStringWithFormat(
            NSLocalizedString("graph.accessibility.thread.value",
                              comment: "VoiceOver value for graph thread node unread count"),
            unreadCount
        )
    }
}

internal struct GraphRemainingBranch: Identifiable, Codable, Hashable {
    internal static let graphID = "remaining:threads"

    internal let id: String
    internal let parentID: String
    internal let parentTitle: String
    internal let hiddenCount: Int
    internal let nextBatchCount: Int
    internal let angle: Double

    internal init(parentID: String,
                  parentTitle: String,
                  hiddenCount: Int,
                  nextBatchCount: Int,
                  angle: Double) {
        self.id = Self.graphID(for: parentID)
        self.parentID = parentID
        self.parentTitle = parentTitle
        self.hiddenCount = hiddenCount
        self.nextBatchCount = nextBatchCount
        self.angle = angle
    }

    internal static func graphID(for parentID: String) -> String {
        parentID == GraphCenter.you.id ? graphID : "remaining:children:\(parentID)"
    }

    internal var radius: CGFloat {
        22 + CGFloat(min(hiddenCount, 80)) * 0.18
    }

    internal var title: String {
        String.localizedStringWithFormat(
            NSLocalizedString("graph.remaining.title", comment: "Remaining graph branches node title"),
            hiddenCount
        )
    }

    internal var accessibilityLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("graph.remaining.accessibility",
                              comment: "VoiceOver label for expanding remaining graph branches"),
            hiddenCount,
            parentTitle,
            nextBatchCount
        )
    }
}

internal struct GraphMessageSummary: Codable, Hashable {
    internal let text: String
    internal let statusMessage: String
    internal let isSummarizing: Bool

    internal var previewText: String {
        let cleanedSummary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedSummary.isEmpty {
            return cleanedSummary
        }
        return statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

internal struct GraphMessage: Identifiable, Codable, Hashable {
    internal let id: String
    internal let rawMessageID: String
    internal let threadID: String
    internal let rawThreadID: String
    internal let index: Int
    internal let subject: String
    internal let displayTitle: String
    internal let snippet: String
    internal let sender: String
    internal let mailboxPath: String
    internal let accountName: String
    internal let date: Date
    internal let unread: Bool
    internal let tags: [String]
    internal let internalMailID: String?
    internal let summary: GraphMessageSummary?

    internal var radius: CGFloat {
        unread ? 8 : 6
    }

    internal var summaryPreviewText: String {
        summary?.previewText ?? ""
    }

    internal var accessibilityLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("graph.accessibility.message.label",
                              comment: "VoiceOver label for graph message node"),
            displayTitle,
            sender
        )
    }
}

internal struct GraphEdge: Identifiable, Codable, Hashable {
    internal let sourceID: String
    internal let targetID: String
    internal let threadID: String
    internal let kind: GraphEdgeKind

    internal var id: String {
        "\(sourceID)->\(targetID)"
    }
}

private struct GraphThreadCandidate {
    let index: Int
    let root: ThreadNode
    let nodes: [ThreadNode]
    let rawThreadID: String
    let threadID: String
    let folderID: String?
    let lastUpdated: Date
    let fullTitle: String
}

private struct GraphPrimaryBranch {
    let id: String
    let folder: ThreadFolder?
    let sourceIndex: Int
    var candidates: [GraphThreadCandidate]
}

private struct GraphSuggestionProjection {
    let id: String
    let rankedTopic: RankedGraphTopic
    let members: [GraphTopicMember]
    let candidates: [GraphThreadCandidate]
}

internal struct GraphData: Codable, Hashable {
    internal let center: GraphCenter
    internal let groupings: [GraphGrouping]
    internal let threads: [GraphThread]
    internal let remainingBranches: [GraphRemainingBranch]
    internal let messages: [GraphMessage]
    internal let edges: [GraphEdge]
    internal let visiblePrimaryBranchCount: Int
    internal let totalPrimaryBranchCount: Int

    internal static let empty = GraphData(center: .you,
                                          groupings: [],
                                          threads: [],
                                          remainingBranches: [],
                                          messages: [],
                                          edges: [],
                                          visiblePrimaryBranchCount: 0,
                                          totalPrimaryBranchCount: 0)

    internal static func threadNodeID(for rawThreadID: String) -> String {
        "thread:\(rawThreadID)"
    }

    internal static func rawThreadID(for root: ThreadNode) -> String {
        root.message.threadID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? root.id
    }

    internal static func messageNodeID(for rawMessageID: String) -> String {
        "message:\(rawMessageID)"
    }

    internal var threadByID: [String: GraphThread] {
        Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
    }

    internal var groupingByID: [String: GraphGrouping] {
        Dictionary(uniqueKeysWithValues: groupings.map { ($0.id, $0) })
    }

    internal var messageByID: [String: GraphMessage] {
        Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    }

    internal var remainingBranchByID: [String: GraphRemainingBranch] {
        Dictionary(uniqueKeysWithValues: remainingBranches.map { ($0.id, $0) })
    }

    internal var rootRemainingBranch: GraphRemainingBranch? {
        remainingBranch(forParentID: center.id)
    }

    internal func remainingBranch(forParentID parentID: String) -> GraphRemainingBranch? {
        remainingBranches.first { $0.parentID == parentID }
    }

    internal var allNodeIDs: Set<String> {
        Set([center.id] + groupings.map(\.id) + threads.map(\.id) +
            remainingBranches.map(\.id) + messages.map(\.id))
    }

    /// The number of rendered nodes that represent real emails. A thread node
    /// represents its root email; `messages` contains only the visible replies.
    internal var visibleEmailNodeCount: Int {
        threads.count + messages.count
    }

    internal func matchingNodeIDs(query rawQuery: String) -> Set<String> {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allNodeIDs }
        var matches: Set<String> = [center.id]
        matches.formUnion(remainingBranches.map(\.id))
        for grouping in groupings where grouping.title.lowercased().contains(query) {
            matches.insert(grouping.id)
            matches.formUnion(grouping.threadIDs)
        }
        for thread in threads where thread.matches(query: query) {
            matches.insert(thread.id)
            for message in messages where message.threadID == thread.id {
                matches.insert(message.id)
            }
        }
        for message in messages where message.matches(query: query) {
            matches.insert(message.id)
            matches.insert(message.threadID)
        }
        return matches
    }

    internal static func make(roots: [ThreadNode],
                              archivedThreadIDs: Set<String> = [],
                              tagsByNodeID: [String: [String]] = [:],
                              topicSignalsByRawThreadID: [String: GraphTopicSignal] = [:],
                              summariesByNodeID: [String: GraphMessageSummary] = [:],
                              titlesByNodeID: [String: String] = [:],
                              folders: [ThreadFolder] = [],
                              folderMembershipByThreadID: [String: String] = [:],
                              dismissedSuggestedTopicIDs: Set<String> = [],
                              hiddenSuggestedTopics: Set<String> = [],
                              branchLimit: Int? = nil,
                              branchBatchSize: Int = 10,
                              perNodeBranchPageSize: Int = 6,
                              visibleChildLimitsByParentID: [String: Int] = [:],
                              messageLimitPerBranch: Int? = nil,
                              now: Date = Date()) -> GraphData {
        var threads: [GraphThread] = []
        var messages: [GraphMessage] = []
        var edges: [GraphEdge] = []
        var remainingBranches: [GraphRemainingBranch] = []
        let liveCutoff = now.addingTimeInterval(-24 * 60 * 60)

        let candidates = roots.enumerated().compactMap { index, root -> (index: Int, root: ThreadNode, rawThreadID: String, threadID: String)? in
            let rawThreadID = rawThreadID(for: root)
            let threadID = threadNodeID(for: rawThreadID)
            guard !archivedThreadIDs.contains(threadID) else { return nil }
            return (index, root, rawThreadID, threadID)
        }
        var folderIDByRawThreadID = folderMembershipByThreadID.reduce(into: [String: String]()) { result, entry in
            guard let threadID = normalizedThreadID(entry.key) else { return }
            result[threadID] = entry.value
        }
        for folder in folders.sorted(by: { $0.id < $1.id }) {
            for rawThreadID in folder.threadIDs {
                guard let threadID = normalizedThreadID(rawThreadID),
                      folderIDByRawThreadID[threadID] == nil else { continue }
                folderIDByRawThreadID[threadID] = folder.id
            }
        }
        let folderByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let folderTitleByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.title) })
        let metadataCandidates = candidates.map { candidate in
            let nodes = flatten(candidate.root)
            let lastUpdated = nodes.map(\.message.date).max() ?? candidate.root.message.date
            let subject = candidate.root.message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let fullTitle = subject.isEmpty
                ? candidate.root.message.from.trimmingCharacters(in: .whitespacesAndNewlines)
                : subject
            let normalizedRawThreadID = normalizedThreadID(candidate.rawThreadID) ?? candidate.rawThreadID
            let folderID = folderIDByRawThreadID[normalizedRawThreadID]
                .flatMap { folderByID[$0] == nil ? nil : $0 }
            return GraphThreadCandidate(index: candidate.index,
                                        root: candidate.root,
                                        nodes: nodes,
                                        rawThreadID: normalizedRawThreadID,
                                        threadID: candidate.threadID,
                                        folderID: folderID,
                                        lastUpdated: lastUpdated,
                                        fullTitle: fullTitle)
        }
        let topicConversations = metadataCandidates.map { candidate in
            GraphTopicConversation(rawThreadID: candidate.rawThreadID,
                                   graphThreadID: candidate.threadID,
                                   fullTitle: candidate.fullTitle,
                                   lastUpdated: candidate.lastUpdated,
                                   existingFolderID: candidate.folderID,
                                   existingFolderTitle: candidate.folderID.flatMap { folderTitleByID[$0] })
        }
        let candidateByRawThreadID = metadataCandidates.reduce(into: [String: GraphThreadCandidate]()) {
            $0[$1.rawThreadID] = $1
        }

        var primaryBranches: [GraphPrimaryBranch] = []
        var primaryBranchIndexByID: [String: Int] = [:]
        for candidate in metadataCandidates {
            let branchID = candidate.folderID.map { "folder:\($0)" } ?? candidate.threadID
            if let branchIndex = primaryBranchIndexByID[branchID] {
                primaryBranches[branchIndex].candidates.append(candidate)
            } else {
                primaryBranchIndexByID[branchID] = primaryBranches.count
                primaryBranches.append(GraphPrimaryBranch(id: branchID,
                                                          folder: candidate.folderID.flatMap { folderByID[$0] },
                                                          sourceIndex: candidate.index,
                                                          candidates: [candidate]))
            }
        }
        let visibleLimit = branchLimit.map { max(0, $0) } ?? primaryBranches.count
        let visiblePrimaryBranches = Array(primaryBranches.prefix(visibleLimit))
        let childPageSize = max(1, perNodeBranchPageSize)

        let rankedSuggestions = GraphTopicRanker.rank(
            conversations: topicConversations,
            signalsByRawThreadID: topicSignalsByRawThreadID,
            dismissedExactPreferenceIDs: dismissedSuggestedTopicIDs,
            hiddenNormalizedTopics: hiddenSuggestedTopics,
            now: now
        )
        let suggestions = rankedSuggestions.map { rankedTopic in
            let orderedMembers = rankedTopic.members.compactMap { member -> (GraphTopicMember, GraphThreadCandidate)? in
                guard let candidate = candidateByRawThreadID[member.rawThreadID] else { return nil }
                return (member, candidate)
            }.sorted { lhs, rhs in
                if lhs.1.index != rhs.1.index { return lhs.1.index < rhs.1.index }
                return lhs.0.rawThreadID < rhs.0.rawThreadID
            }
            return GraphSuggestionProjection(
                id: "suggestion:\(GraphTopicNormalizer.identifierComponent(rankedTopic.normalizedTopic))",
                rankedTopic: rankedTopic,
                members: orderedMembers.map(\.0),
                candidates: orderedMembers.map(\.1)
            )
        }

        var admittedThreadIDs: Set<String> = []
        var visibleCandidatesByPrimaryBranchID: [String: [GraphThreadCandidate]] = [:]
        for branch in visiblePrimaryBranches {
            let limit = branch.folder == nil
                ? 1
                : max(0, visibleChildLimitsByParentID[branch.id] ?? childPageSize)
            let visibleChildren = Array(branch.candidates.prefix(limit))
            visibleCandidatesByPrimaryBranchID[branch.id] = visibleChildren
            admittedThreadIDs.formUnion(visibleChildren.map(\.threadID))
        }
        var visibleCandidatesBySuggestionID: [String: [GraphThreadCandidate]] = [:]
        for suggestion in suggestions {
            let initialPreviewLimit = min(childPageSize, 6)
            let limit = max(0, visibleChildLimitsByParentID[suggestion.id] ?? initialPreviewLimit)
            let visibleChildren = Array(suggestion.candidates.prefix(limit))
            visibleCandidatesBySuggestionID[suggestion.id] = visibleChildren
            admittedThreadIDs.formUnion(visibleChildren.map(\.threadID))
        }

        for candidate in metadataCandidates where admittedThreadIDs.contains(candidate.threadID) {
            let index = candidate.index
            let root = candidate.root
            let rawThreadID = candidate.rawThreadID
            let threadID = candidate.threadID
            let flattened = candidate.nodes
            let allMessageIDs = flattened.map(\.id)
            let visibleEmails: [ThreadNode] = if let messageLimitPerBranch {
                Array(flattened.prefix(max(1, messageLimitPerBranch)))
            } else {
                flattened
            }
            let visibleMessages = visibleEmails.dropFirst().enumerated().map { offset, node in
                let summary = summariesByNodeID[node.id] ?? summariesByNodeID[messageNodeID(for: node.id)]
                let generatedTitle = (titlesByNodeID[node.id]
                    ?? titlesByNodeID[messageNodeID(for: node.id)] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let summaryTitle = summary?.previewText
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let subjectTitle = node.message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = [generatedTitle, summaryTitle, subjectTitle, node.message.from]
                    .first { !$0.isEmpty } ?? ""
                return GraphMessage(id: messageNodeID(for: node.id),
                                    rawMessageID: node.id,
                                    threadID: threadID,
                                    rawThreadID: rawThreadID,
                                    index: offset + 1,
                                    subject: node.message.subject,
                                    displayTitle: displayTitle,
                                    snippet: node.message.snippet,
                                    sender: node.message.from,
                                    mailboxPath: node.message.mailboxID,
                                    accountName: node.message.accountName,
                                    date: node.message.date,
                                    unread: node.message.isUnread,
                                    tags: tagsByNodeID[node.id] ?? tagsByNodeID[messageNodeID(for: node.id)] ?? [],
                                    internalMailID: node.message.internalMailID,
                                    summary: summary)
            }
            let lastUpdated = flattened.map(\.message.date).max() ?? root.message.date
            let unreadCount = flattened.filter(\.message.isUnread).count
            let messageCount = flattened.count
            let angle = fmod(Double(index) * 137.5, 360)
            let tags = Array(Set(flattened.flatMap { node in
                tagsByNodeID[node.id] ?? tagsByNodeID[messageNodeID(for: node.id)] ?? []
            })).sorted()
            let fallbackTitle = root.message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let rootSummary = (summariesByNodeID[root.id]
                ?? summariesByNodeID[messageNodeID(for: root.id)])?.previewText
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let generatedTitle = (titlesByNodeID[root.id]
                ?? titlesByNodeID[messageNodeID(for: root.id)] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = [generatedTitle, rootSummary, fallbackTitle, root.message.from]
                .first { !$0.isEmpty } ?? ""
            let thread = GraphThread(id: threadID,
                                     rawThreadID: rawThreadID,
                                     rootNodeID: root.id,
                                     subject: root.message.subject,
                                     displayTitle: displayTitle,
                                     snippet: root.message.snippet,
                                     sender: root.message.from,
                                     mailboxPath: root.message.mailboxID,
                                     accountName: root.message.accountName,
                                     lastUpdated: lastUpdated,
                                     messageCount: messageCount,
                                     unreadCount: unreadCount,
                                     importance: .from(messageCount: messageCount),
                                     isLive: lastUpdated > liveCutoff,
                                     angle: angle,
                                     tags: tags,
                                     messageIDs: allMessageIDs)
            threads.append(thread)
            messages.append(contentsOf: visibleMessages)
            var previousID = threadID
            for message in visibleMessages {
                edges.append(GraphEdge(sourceID: previousID,
                                       targetID: message.id,
                                       threadID: threadID,
                                       kind: .chain))
                previousID = message.id
            }
        }

        var groupings: [GraphGrouping] = []
        for branch in visiblePrimaryBranches {
            guard let folder = branch.folder else {
                guard let threadID = visibleCandidatesByPrimaryBranchID[branch.id]?.first?.threadID else { continue }
                edges.append(GraphEdge(sourceID: GraphCenter.you.id,
                                       targetID: threadID,
                                       threadID: threadID,
                                       kind: .trunk))
                continue
            }
            let visibleChildren = visibleCandidatesByPrimaryBranchID[branch.id] ?? []
            let grouping = GraphGrouping(id: branch.id,
                                         title: folder.title,
                                         kind: .folder,
                                         threadIDs: visibleChildren.map(\.threadID),
                                         rawThreadIDs: branch.candidates.map(\.rawThreadID),
                                         sourceFolderID: folder.id,
                                         sourceTag: nil)
            groupings.append(grouping)
            edges.append(GraphEdge(sourceID: GraphCenter.you.id,
                                   targetID: grouping.id,
                                   threadID: grouping.id,
                                   kind: .trunk))
            for threadID in grouping.threadIDs {
                edges.append(GraphEdge(sourceID: grouping.id,
                                       targetID: threadID,
                                       threadID: threadID,
                                       kind: .grouping))
            }
            appendRemainingBranch(parentID: grouping.id,
                                  parentTitle: grouping.title,
                                  totalChildCount: branch.candidates.count,
                                  visibleChildCount: visibleChildren.count,
                                  nextPageSize: childPageSize,
                                  angleSeed: branch.sourceIndex + visibleChildren.count,
                                  remainingBranches: &remainingBranches,
                                  edges: &edges)
        }

        for suggestion in suggestions {
            let visibleChildren = visibleCandidatesBySuggestionID[suggestion.id] ?? []
            let grouping = GraphGrouping(id: suggestion.id,
                                         title: suggestion.rankedTopic.displayTitle,
                                         kind: .suggestedTopic,
                                         threadIDs: visibleChildren.map(\.threadID),
                                         rawThreadIDs: suggestion.members.map(\.rawThreadID),
                                         sourceFolderID: nil,
                                         sourceTag: suggestion.rankedTopic.displayTitle,
                                         normalizedTopic: suggestion.rankedTopic.normalizedTopic,
                                         supportingReason: suggestion.rankedTopic.supportingReason,
                                         reviewMembers: suggestion.members)
            groupings.append(grouping)
            edges.append(GraphEdge(sourceID: GraphCenter.you.id,
                                   targetID: grouping.id,
                                   threadID: grouping.id,
                                   kind: .suggested))
            for threadID in grouping.threadIDs {
                edges.append(GraphEdge(sourceID: grouping.id,
                                       targetID: threadID,
                                       threadID: threadID,
                                       kind: .suggested))
            }
            appendRemainingBranch(parentID: grouping.id,
                                  parentTitle: grouping.title,
                                  totalChildCount: suggestion.candidates.count,
                                  visibleChildCount: visibleChildren.count,
                                  nextPageSize: childPageSize,
                                  angleSeed: (visibleChildren.last?.index ?? 0) + visibleChildren.count,
                                  remainingBranches: &remainingBranches,
                                  edges: &edges)
        }

        appendRemainingBranch(parentID: GraphCenter.you.id,
                              parentTitle: GraphCenter.you.title,
                              totalChildCount: primaryBranches.count,
                              visibleChildCount: visiblePrimaryBranches.count,
                              nextPageSize: max(1, branchBatchSize),
                              angleSeed: visiblePrimaryBranches.count,
                              remainingBranches: &remainingBranches,
                              edges: &edges)

        return GraphData(center: .you,
                         groupings: groupings,
                         threads: threads,
                         remainingBranches: remainingBranches,
                         messages: messages,
                         edges: edges,
                         visiblePrimaryBranchCount: visiblePrimaryBranches.count,
                         totalPrimaryBranchCount: primaryBranches.count)
    }

    private static func appendRemainingBranch(parentID: String,
                                              parentTitle: String,
                                              totalChildCount: Int,
                                              visibleChildCount: Int,
                                              nextPageSize: Int,
                                              angleSeed: Int,
                                              remainingBranches: inout [GraphRemainingBranch],
                                              edges: inout [GraphEdge]) {
        let hiddenCount = max(0, totalChildCount - visibleChildCount)
        guard hiddenCount > 0 else { return }
        let branch = GraphRemainingBranch(parentID: parentID,
                                          parentTitle: parentTitle,
                                          hiddenCount: hiddenCount,
                                          nextBatchCount: min(max(1, nextPageSize), hiddenCount),
                                          angle: fmod(Double(angleSeed) * 137.5, 360))
        remainingBranches.append(branch)
        edges.append(GraphEdge(sourceID: parentID,
                               targetID: branch.id,
                               threadID: branch.id,
                               kind: .remaining))
    }

    internal static func suggestionDismissalID(forTopic topic: String,
                                               rawThreadIDs: [String]) -> String? {
        GraphTopicPreferenceID.exact(normalizedTopic: topic,
                                     rawThreadIDs: rawThreadIDs)
    }

    private static func normalizedThreadID(_ rawThreadID: String) -> String? {
        rawThreadID.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private static func flatten(_ node: ThreadNode) -> [ThreadNode] {
        [node] + node.children.flatMap { flatten($0) }
    }
}

internal enum GraphPruneMode: String, Codable, Hashable {
    case idle
    case snip
    case archive
}

internal enum GraphCompostAction: String, Codable, Hashable {
    case snip
    case archive
}

internal struct GraphCompostEntry: Identifiable, Codable, Hashable {
    internal let id: String
    internal let threadID: String
    internal let rootNodeID: String
    internal let subject: String
    internal let action: GraphCompostAction
    internal let messageIDs: [String]
    internal let priorMailboxPath: String?
    internal let priorAccountName: String?
    internal let movedMessages: [GraphSnipMovedMessage]
    internal let requiresRecovery: Bool
    internal let createdAt: Date

    internal init(id: String,
                  threadID: String,
                  rootNodeID: String,
                  subject: String,
                  action: GraphCompostAction,
                  messageIDs: [String],
                  priorMailboxPath: String?,
                  priorAccountName: String?,
                  movedMessages: [GraphSnipMovedMessage] = [],
                  requiresRecovery: Bool = false,
                  createdAt: Date) {
        self.id = id
        self.threadID = threadID
        self.rootNodeID = rootNodeID
        self.subject = subject
        self.action = action
        self.messageIDs = messageIDs
        self.priorMailboxPath = priorMailboxPath
        self.priorAccountName = priorAccountName
        self.movedMessages = movedMessages
        self.requiresRecovery = requiresRecovery
        self.createdAt = createdAt
    }
}

internal struct ArchivedInGraphEntry: Identifiable, Codable, Hashable {
    internal let threadID: String
    internal let archivedAt: Date

    internal var id: String { threadID }
}

internal enum GraphPruneState: Equatable {
    case idle
    case snipMode
    case archiveMode
    case pickingFolder(threadID: String)
    case wilting(threadID: String)
    case settling(threadID: String)
    case composted(threadID: String)
    case restoring(threadID: String)
}

internal enum GraphPruneEvent: Equatable {
    case enterSnip
    case enterArchive
    case cancel
    case edgeClicked(threadID: String)
    case folderPicked
    case animationFinished
    case restore(threadID: String)
    case restoreFinished
}

internal struct GraphPruneStateMachine {
    internal private(set) var state: GraphPruneState = .idle

    @discardableResult
    internal mutating func send(_ event: GraphPruneEvent) -> GraphPruneState {
        switch (state, event) {
        case (_, .enterSnip):
            state = .snipMode
        case (_, .enterArchive):
            state = .archiveMode
        case (.snipMode, .edgeClicked(let threadID)):
            state = .pickingFolder(threadID: threadID)
        case (.archiveMode, .edgeClicked(let threadID)):
            state = .settling(threadID: threadID)
        case (.pickingFolder(let threadID), .folderPicked):
            state = .wilting(threadID: threadID)
        case (.wilting(let threadID), .animationFinished),
             (.settling(let threadID), .animationFinished):
            state = .composted(threadID: threadID)
        case (.composted, .restore(let threadID)):
            state = .restoring(threadID: threadID)
        case (.restoring, .restoreFinished),
             (_, .cancel):
            state = .idle
        default:
            break
        }
        return state
    }
}

internal extension GraphThread {
    func matches(query: String) -> Bool {
        displayTitle.lowercased().contains(query) ||
        subject.lowercased().contains(query) ||
        snippet.lowercased().contains(query) ||
        sender.lowercased().contains(query) ||
        tags.contains { $0.lowercased().contains(query) }
    }
}

internal extension GraphMessage {
    func matches(query: String) -> Bool {
        displayTitle.lowercased().contains(query) ||
        subject.lowercased().contains(query) ||
        snippet.lowercased().contains(query) ||
        summaryPreviewText.lowercased().contains(query) ||
        sender.lowercased().contains(query) ||
        tags.contains { $0.lowercased().contains(query) }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
