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
    case thread
    case remaining
    case message
}

internal enum GraphEdgeKind: String, Codable, Hashable {
    case trunk
    case chain
    case remaining
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
            subject,
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
    internal let hiddenThreadCount: Int
    internal let nextBatchCount: Int
    internal let angle: Double

    internal init(hiddenThreadCount: Int,
                  nextBatchCount: Int,
                  angle: Double) {
        self.id = Self.graphID
        self.hiddenThreadCount = hiddenThreadCount
        self.nextBatchCount = nextBatchCount
        self.angle = angle
    }

    internal var radius: CGFloat {
        22 + CGFloat(min(hiddenThreadCount, 80)) * 0.18
    }

    internal var title: String {
        String.localizedStringWithFormat(
            NSLocalizedString("graph.remaining.title", comment: "Remaining graph branches node title"),
            hiddenThreadCount
        )
    }

    internal var accessibilityLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("graph.remaining.accessibility",
                              comment: "VoiceOver label for expanding remaining graph branches"),
            hiddenThreadCount,
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
            subject,
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

internal struct GraphData: Codable, Hashable {
    internal let center: GraphCenter
    internal let threads: [GraphThread]
    internal let remainingBranch: GraphRemainingBranch?
    internal let messages: [GraphMessage]
    internal let edges: [GraphEdge]

    internal static let empty = GraphData(center: .you, threads: [], remainingBranch: nil, messages: [], edges: [])

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

    internal var messageByID: [String: GraphMessage] {
        Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    }

    internal var allNodeIDs: Set<String> {
        var ids = Set([center.id] + threads.map(\.id) + messages.map(\.id))
        if let remainingBranch {
            ids.insert(remainingBranch.id)
        }
        return ids
    }

    internal func matchingNodeIDs(query rawQuery: String) -> Set<String> {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allNodeIDs }
        var matches: Set<String> = [center.id]
        if let remainingBranch {
            matches.insert(remainingBranch.id)
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
                              summariesByNodeID: [String: GraphMessageSummary] = [:],
                              branchLimit: Int? = nil,
                              branchBatchSize: Int = 10,
                              messageLimitPerBranch: Int? = nil,
                              now: Date = Date()) -> GraphData {
        var threads: [GraphThread] = []
        var messages: [GraphMessage] = []
        var edges: [GraphEdge] = []
        let liveCutoff = now.addingTimeInterval(-24 * 60 * 60)

        let candidates = roots.enumerated().compactMap { index, root -> (index: Int, root: ThreadNode, rawThreadID: String, threadID: String)? in
            let rawThreadID = rawThreadID(for: root)
            let threadID = threadNodeID(for: rawThreadID)
            guard !archivedThreadIDs.contains(threadID) else { return nil }
            return (index, root, rawThreadID, threadID)
        }
        let visibleLimit = branchLimit.map { max(0, $0) } ?? candidates.count
        let visibleCandidates = candidates.prefix(visibleLimit)

        for candidate in visibleCandidates {
            let index = candidate.index
            let root = candidate.root
            let rawThreadID = candidate.rawThreadID
            let threadID = candidate.threadID
            let flattened = flatten(root)
            let allMessageIDs = flattened.map(\.id)
            let visibleFlattened: [ThreadNode]
            if let messageLimitPerBranch {
                visibleFlattened = Array(flattened.prefix(max(1, messageLimitPerBranch)))
            } else {
                visibleFlattened = flattened
            }
            let visibleMessages = visibleFlattened.enumerated().map { messageIndex, node in
                let summary = summariesByNodeID[node.id] ?? summariesByNodeID[messageNodeID(for: node.id)]
                return GraphMessage(id: messageNodeID(for: node.id),
                                    rawMessageID: node.id,
                                    threadID: threadID,
                                    rawThreadID: rawThreadID,
                                    index: messageIndex,
                                    subject: node.message.subject,
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
            let thread = GraphThread(id: threadID,
                                     rawThreadID: rawThreadID,
                                     rootNodeID: root.id,
                                     subject: root.message.subject,
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
            edges.append(GraphEdge(sourceID: GraphCenter.you.id,
                                   targetID: threadID,
                                   threadID: threadID,
                                   kind: .trunk))
            var previousID = threadID
            for message in visibleMessages {
                edges.append(GraphEdge(sourceID: previousID,
                                       targetID: message.id,
                                       threadID: threadID,
                                       kind: .chain))
                previousID = message.id
            }
        }

        let hiddenCount = max(0, candidates.count - visibleCandidates.count)
        let remainingBranch: GraphRemainingBranch?
        if hiddenCount > 0 {
            let nextBatchCount = min(max(1, branchBatchSize), hiddenCount)
            let angle = fmod(Double(visibleCandidates.count) * 137.5, 360)
            let branch = GraphRemainingBranch(hiddenThreadCount: hiddenCount,
                                              nextBatchCount: nextBatchCount,
                                              angle: angle)
            remainingBranch = branch
            edges.append(GraphEdge(sourceID: GraphCenter.you.id,
                                   targetID: branch.id,
                                   threadID: branch.id,
                                   kind: .remaining))
        } else {
            remainingBranch = nil
        }

        return GraphData(center: .you,
                         threads: threads,
                         remainingBranch: remainingBranch,
                         messages: messages,
                         edges: edges)
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
    internal let createdAt: Date
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
        subject.lowercased().contains(query) ||
        snippet.lowercased().contains(query) ||
        sender.lowercased().contains(query) ||
        tags.contains { $0.lowercased().contains(query) }
    }
}

internal extension GraphMessage {
    func matches(query: String) -> Bool {
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
