import Foundation

struct ThreadParticipant: Identifiable, Hashable {
    enum Role: String, Codable {
        case requester
        case owner
        case collaborator
        case observer
        case unknown

        var displayName: String {
            switch self {
            case .requester:
                return "Requester"
            case .owner:
                return "Owner"
            case .collaborator:
                return "Collaborator"
            case .observer:
                return "Observer"
            case .unknown:
                return "Participant"
            }
        }
    }

    var id: String { email.lowercased() }
    let name: String
    let email: String
    let role: Role
    let isVIP: Bool

    static func inferred(from address: String,
                         role: Role,
                         vipSenders: Set<String>) -> ThreadParticipant {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "<")
        let name: String
        let email: String
        if components.count == 2, let closingRange = components[1].range(of: ">") {
            name = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            email = String(components[1][..<closingRange.lowerBound])
        } else {
            name = trimmed
            email = trimmed
        }
        return ThreadParticipant(name: name.isEmpty ? email : name,
                                 email: email.lowercased(),
                                 role: role,
                                 isVIP: vipSenders.contains(email.lowercased()))
    }
}

struct ThreadBadge: Identifiable, Hashable, Codable {
    enum Kind: String, Codable {
        case urgent
        case awaitingReply
        case scheduled
        case vip
        case task
    }

    let kind: Kind
    let label: String
    let accessibilityLabel: String

    var id: String { "\(kind.rawValue)-\(label)" }
}

struct ThreadIntentSignals: Hashable, Codable {
    let intentRelevance: Double
    let urgencyScore: Double
    let personalPriorityScore: Double
    let timelinessScore: Double
}

struct ThreadMergeReason: Identifiable, Hashable, Codable {
    let id: String
    let description: String
    let similarity: Double
    let sharedParticipants: [String]
}

struct ThreadRelatedConversation: Identifiable, Hashable {
    let id: String
    let title: String
    let nodes: [ThreadNode]
    let reason: ThreadMergeReason

    static func == (lhs: ThreadRelatedConversation, rhs: ThreadRelatedConversation) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct ThreadGroup: Identifiable, Hashable {
    enum MergeState: String {
        case suggested
        case accepted
        case reverted
    }

    let id: String
    let subject: String
    let topicTag: String?
    let summary: String
    let participants: [ThreadParticipant]
    let badges: [ThreadBadge]
    let intentSignals: ThreadIntentSignals
    let lastUpdated: Date
    let unreadCount: Int
    let rootNodes: [ThreadNode]
    let relatedConversations: [ThreadRelatedConversation]
    let mergeReasons: [ThreadMergeReason]
    let mergeState: MergeState
    let isWaitingOnMe: Bool
    let hasActiveTask: Bool
    let pinned: Bool
    let chronologicalIndex: Int

    var messageCount: Int {
        let rootTotal = rootNodes.reduce(0) { partial, node in
            partial + Self.countMessages(in: node)
        }
        let relatedTotal = relatedConversations.reduce(0) { partial, conversation in
            partial + conversation.nodes.reduce(0) { subtotal, node in
                subtotal + Self.countMessages(in: node)
            }
        }
        return rootTotal + relatedTotal
    }

    static func == (lhs: ThreadGroup, rhs: ThreadGroup) -> Bool {
        lhs.id == rhs.id && lhs.chronologicalIndex == rhs.chronologicalIndex
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(chronologicalIndex)
    }

    private static func countMessages(in node: ThreadNode) -> Int {
        1 + node.children.reduce(0) { partial, child in
            partial + countMessages(in: child)
        }
    }
}
