import Foundation

struct ThreadIntentMetadata {
    let threadID: String
    let summary: String
    let topicTag: String?
    let participants: [ThreadParticipant]
    let badges: [ThreadBadge]
    let intentSignals: ThreadIntentSignals
    let isWaitingOnMe: Bool
    let hasActiveTask: Bool
    let embedding: IntentEmbedding
    let participantLookup: Set<String>
    let lastUpdated: Date
    let unreadCount: Int
    let chronologicalIndex: Int
}

struct IntentEmbedding: Hashable {
    private let values: [Double]

    init(values: [Double]) {
        self.values = values
    }

    static func make(from text: String) -> IntentEmbedding {
        let cleaned = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var vector = Array(repeating: 0.0, count: 8)
        for token in cleaned {
            var hasher = Hasher()
            hasher.combine(token)
            let hash = hasher.finalize()
            let index = abs(hash) % vector.count
            vector[index] += 1
        }
        let magnitude = max(vector.reduce(0) { $0 + $1 * $1 }.squareRoot(), 0.0001)
        let normalized = vector.map { $0 / magnitude }
        return IntentEmbedding(values: normalized)
    }

    func cosineSimilarity(with other: IntentEmbedding) -> Double {
        guard values.count == other.values.count else { return 0 }
        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for idx in values.indices {
            let lhs = values[idx]
            let rhs = other.values[idx]
            dot += lhs * rhs
            lhsMagnitude += lhs * lhs
            rhsMagnitude += rhs * rhs
        }
        let denominator = (lhsMagnitude.squareRoot() * rhsMagnitude.squareRoot())
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }
}

actor ThreadIntentAnalyzer {
    private let summaryProvider: EmailSummaryProviding?
    private let cache: ThreadIntentCache
    private let vipSenders: Set<String>

    init(summaryProvider: EmailSummaryProviding?,
         cache: ThreadIntentCache = ThreadIntentCache(),
         vipSenders: Set<String> = []) {
        self.summaryProvider = summaryProvider
        self.cache = cache
        self.vipSenders = vipSenders
    }

    func analyze(nodes: [ThreadNode]) async -> [ThreadIntentMetadata] {
        await withTaskGroup(of: ThreadIntentMetadata?.self) { group in
            for (index, node) in nodes.enumerated() {
                group.addTask {
                    await self.enrich(node: node, chronologicalIndex: index)
                }
            }

            var results: [ThreadIntentMetadata] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
    }

    private func enrich(node: ThreadNode, chronologicalIndex: Int) async -> ThreadIntentMetadata? {
        let threadID = node.message.threadID ?? JWZThreader.threadIdentifier(for: node)
        let flattenedSubjects = Self.subjects(in: node)
        let participants = participants(in: node)
        let waitingOnMe = Self.containsWaitingOnMeText(in: node)
        let activeTask = Self.containsActiveTask(in: node)
        let urgencyScore = Self.urgencyScore(for: node)
        let priorityScore = participants.contains(where: { $0.isVIP }) ? 0.9 : 0.2
        let timeliness = Self.timelinessScore(for: node)
        let relevance = Self.intentRelevanceScore(for: node)
        let badges = Self.badges(urgency: urgencyScore,
                                 waitingOnMe: waitingOnMe,
                                 hasTask: activeTask,
                                 participants: participants)
        let intentSignals = ThreadIntentSignals(intentRelevance: relevance,
                                                urgencyScore: urgencyScore,
                                                personalPriorityScore: priorityScore,
                                                timelinessScore: timeliness)
        let topicTag = Self.topicTag(for: node)
        let embedding = IntentEmbedding.make(from: flattenedSubjects.joined(separator: " "))
        let summary = await makeSummary(for: threadID, subjects: flattenedSubjects)

        let metadata = ThreadIntentMetadata(threadID: threadID,
                                            summary: summary,
                                            topicTag: topicTag,
                                            participants: participants,
                                            badges: badges,
                                            intentSignals: intentSignals,
                                            isWaitingOnMe: waitingOnMe,
                                            hasActiveTask: activeTask,
                                            embedding: embedding,
                                            participantLookup: Set(participants.map(\.id)),
                                            lastUpdated: node.message.date,
                                            unreadCount: Self.unreadCount(in: node),
                                            chronologicalIndex: chronologicalIndex)
        await cache.upsert(ThreadIntentCache.Record(threadID: threadID,
                                                    summary: summary,
                                                    topicTag: topicTag,
                                                    intentSignals: intentSignals,
                                                    badges: badges,
                                                    lastUpdated: node.message.date))
        return metadata
    }

    private func makeSummary(for threadID: String,
                             subjects: [String]) async -> String {
        if let cached = await cache.record(for: threadID) {
            return cached.summary
        }
        guard let summaryProvider, !subjects.isEmpty else {
            return subjects.first ?? "Conversation"
        }
        do {
            return try await summaryProvider.summarize(subjects: subjects)
        } catch {
            return subjects.first ?? "Conversation"
        }
    }

    private func participants(in node: ThreadNode) -> [ThreadParticipant] {
        var participants: [ThreadParticipant] = []
        let sender = ThreadParticipant.inferred(from: node.message.from,
                                                role: .requester,
                                                vipSenders: vipSenders)
        participants.append(sender)
        let recipients = node.message.to
            .split(separator: ",")
            .map { ThreadParticipant.inferred(from: String($0),
                                              role: .collaborator,
                                              vipSenders: vipSenders) }
        participants.append(contentsOf: recipients)
        return Array(Set(participants))
    }

    private static func subjects(in node: ThreadNode) -> [String] {
        var results: [String] = []
        let trimmed = node.message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { results.append(trimmed) }
        for child in node.children {
            results.append(contentsOf: subjects(in: child))
        }
        return results
    }

    private static func containsWaitingOnMeText(in node: ThreadNode) -> Bool {
        let text = (node.message.subject + " " + node.message.snippet).lowercased()
        return text.contains("waiting on you") || text.contains("need your response") || text.contains("awaiting reply")
    }

    private static func containsActiveTask(in node: ThreadNode) -> Bool {
        let text = (node.message.subject + " " + node.message.snippet).lowercased()
        return text.contains("action required") || text.contains("todo") || text.contains("please review")
    }

    private static func urgencyScore(for node: ThreadNode) -> Double {
        let text = (node.message.subject + " " + node.message.snippet).lowercased()
        if text.contains("urgent") || text.contains("asap") { return 0.95 }
        if text.contains("today") || text.contains("eod") { return 0.7 }
        return 0.2
    }

    private static func timelinessScore(for node: ThreadNode) -> Double {
        let age = Date().timeIntervalSince(node.message.date)
        if age < 12 * 60 * 60 { return 0.8 }
        if age < 48 * 60 * 60 { return 0.5 }
        return 0.2
    }

    private static func intentRelevanceScore(for node: ThreadNode) -> Double {
        let text = (node.message.subject + " " + node.message.snippet).lowercased()
        if text.contains("plan") || text.contains("schedule") || text.contains("travel") {
            return 0.7
        }
        return 0.3
    }

    private static func topicTag(for node: ThreadNode) -> String? {
        let subject = node.message.subject.lowercased()
        if subject.contains("travel") { return "Travel Plans" }
        if subject.contains("invoice") { return "Finance" }
        if subject.contains("meeting") { return "Meetings" }
        return nil
    }

    private static func unreadCount(in node: ThreadNode) -> Int {
        var count = node.message.isUnread ? 1 : 0
        for child in node.children {
            count += unreadCount(in: child)
        }
        return count
    }

    private static func badges(urgency: Double,
                               waitingOnMe: Bool,
                               hasTask: Bool,
                               participants: [ThreadParticipant]) -> [ThreadBadge] {
        var badges: [ThreadBadge] = []
        if urgency >= 0.6 {
            badges.append(ThreadBadge(kind: .urgent,
                                      label: "Urgent",
                                      accessibilityLabel: "Urgent"))
        }
        if waitingOnMe {
            badges.append(ThreadBadge(kind: .awaitingReply,
                                      label: "Awaiting Reply",
                                      accessibilityLabel: "Awaiting your reply"))
        }
        if hasTask {
            badges.append(ThreadBadge(kind: .task,
                                      label: "Action",
                                      accessibilityLabel: "Contains action items"))
        }
        if participants.contains(where: { $0.isVIP }) {
            badges.append(ThreadBadge(kind: .vip,
                                      label: "VIP",
                                      accessibilityLabel: "VIP sender"))
        }
        return badges
    }
}
