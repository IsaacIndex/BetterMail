import Foundation

internal struct GraphTopicConversation: Hashable {
    internal let rawThreadID: String
    internal let graphThreadID: String
    internal let fullTitle: String
    internal let lastUpdated: Date
    internal let existingFolderID: String?
    internal let existingFolderTitle: String?
}

internal struct RankedGraphTopic: Hashable {
    internal let normalizedTopic: String
    internal let displayTitle: String
    internal let confidence: Double
    internal let specificity: Double
    internal let qualityScore: Double
    internal let supportingReason: String
    internal let members: [GraphTopicMember]

    internal var exactPreferenceID: String? {
        GraphTopicPreferenceID.exact(normalizedTopic: normalizedTopic,
                                     rawThreadIDs: members.map(\.rawThreadID))
    }
}

internal enum GraphTopicPreferenceID {
    internal static func exact(normalizedTopic: String,
                               rawThreadIDs: [String]) -> String? {
        let topic = GraphTopicNormalizer.normalize(normalizedTopic)
        let threadIDs = normalizedMemberIDs(rawThreadIDs)
        guard !topic.isEmpty, !threadIDs.isEmpty else { return nil }
        let memberComponent = threadIDs.map(encodedComponent).joined(separator: ".")
        return "suggestion-v2:\(encodedComponent(topic)):\(memberComponent)"
    }

    /// Keeps exact rejections written by the earlier tag-frequency
    /// implementation effective after migrating to lossless v2 identities.
    internal static func legacyExact(normalizedTopic: String,
                                     rawThreadIDs: [String]) -> String? {
        let topic = GraphTopicNormalizer.normalize(normalizedTopic)
        let threadIDs = normalizedMemberIDs(rawThreadIDs)
        guard !topic.isEmpty, !threadIDs.isEmpty else { return nil }
        let memberComponent = threadIDs
            .map(GraphTopicNormalizer.identifierComponent)
            .joined(separator: ".")
        return "suggestion:\(GraphTopicNormalizer.identifierComponent(topic)):\(memberComponent)"
    }

    internal static func compatibleExactIDs(normalizedTopic: String,
                                            rawThreadIDs: [String]) -> Set<String> {
        Set([exact(normalizedTopic: normalizedTopic, rawThreadIDs: rawThreadIDs),
             legacyExact(normalizedTopic: normalizedTopic, rawThreadIDs: rawThreadIDs)].compactMap { $0 })
    }

    private static func normalizedMemberIDs(_ rawThreadIDs: [String]) -> [String] {
        Set(rawThreadIDs.compactMap { rawThreadID -> String? in
            let trimmed = rawThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }).sorted()
    }

    private static func encodedComponent(_ rawValue: String) -> String {
        Data(rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Pure, deterministic graph-topic policy. Provider output is only evidence;
/// it cannot become a ghost branch unless the combined candidate passes all
/// documented thresholds below.
internal enum GraphTopicRanker {
    internal static let minimumDistinctThreadCount = 2
    internal static let minimumAverageConfidence = 0.68
    internal static let minimumSpecificity = 0.52
    internal static let minimumQualityScore = 0.62
    internal static let maximumSuggestionCount = 3

    internal static func rank(
        conversations: [GraphTopicConversation],
        signalsByRawThreadID: [String: GraphTopicSignal],
        dismissedExactPreferenceIDs: Set<String> = [],
        hiddenNormalizedTopics: Set<String> = [],
        now: Date = Date()
    ) -> [RankedGraphTopic] {
        let hiddenTopics = Set(hiddenNormalizedTopics.map(GraphTopicNormalizer.normalize))
        let conversationByID = conversations.reduce(into: [String: GraphTopicConversation]()) { result, conversation in
            let threadID = normalizedThreadID(conversation.rawThreadID)
            guard !threadID.isEmpty else { return }
            result[threadID] = conversation
        }

        var evidenceByTopic: [String: [(GraphTopicConversation, GraphTopicSignal)]] = [:]
        for (rawThreadID, signal) in signalsByRawThreadID {
            let threadID = normalizedThreadID(rawThreadID)
            guard let conversation = conversationByID[threadID],
                  signal.isUsable,
                  !hiddenTopics.contains(signal.normalizedTopic) else {
                continue
            }
            evidenceByTopic[signal.normalizedTopic, default: []].append((conversation, signal))
        }

        let candidates = evidenceByTopic.compactMap { normalizedTopic, evidence -> RankedGraphTopic? in
            let deduplicated = Dictionary(grouping: evidence, by: { normalizedThreadID($0.0.rawThreadID) })
                .compactMap { _, values in
                    values.max { lhs, rhs in
                        if lhs.1.confidence != rhs.1.confidence {
                            return lhs.1.confidence < rhs.1.confidence
                        }
                        return lhs.1.displayTitle > rhs.1.displayTitle
                    }
                }
            guard deduplicated.count >= minimumDistinctThreadCount else { return nil }

            let specificity = GraphTopicQualityPolicy.specificity(of: normalizedTopic)
            guard specificity >= minimumSpecificity else { return nil }
            let confidence = deduplicated.map { $0.1.confidence }.reduce(0, +) / Double(deduplicated.count)
            guard confidence >= minimumAverageConfidence else { return nil }

            let folderIDs = Set(deduplicated.compactMap { $0.0.existingFolderID })
            let ungroupedCount = deduplicated.filter { $0.0.existingFolderID == nil }.count
            if folderIDs.count == 1, ungroupedCount == 0 {
                return nil
            }

            let dates = deduplicated.map { $0.0.lastUpdated }
            let newestDate = dates.max() ?? now
            let oldestDate = dates.min() ?? newestDate
            let ageInDays = max(0, now.timeIntervalSince(newestDate) / 86_400)
            let spanInDays = max(0, newestDate.timeIntervalSince(oldestDate) / 86_400)
            let recency = max(0, 1 - ageInDays / 120)
            let cohesion = max(0, 1 - spanInDays / 90)
            let recencyAndCohesion = (recency + cohesion) / 2
            let usefulUngroupedMembership = Double(ungroupedCount) / Double(deduplicated.count)

            // Specificity and model confidence carry 70% of the score. Date
            // cohesion and useful ungrouped membership are bounded tie-break
            // quality signals; neither can rescue a weak or generic topic.
            let rawScore = specificity * 0.35 +
                confidence * 0.35 +
                recencyAndCohesion * 0.15 +
                usefulUngroupedMembership * 0.15
            let score = rounded(rawScore)
            guard score >= minimumQualityScore else { return nil }

            let strongestEvidence = deduplicated.sorted { lhs, rhs in
                if lhs.1.confidence != rhs.1.confidence {
                    return lhs.1.confidence > rhs.1.confidence
                }
                if lhs.1.displayTitle != rhs.1.displayTitle {
                    return lhs.1.displayTitle < rhs.1.displayTitle
                }
                return lhs.0.rawThreadID < rhs.0.rawThreadID
            }.first
            guard let strongestEvidence else { return nil }
            let displayTitle = strongestEvidence.1.displayTitle
            let reason = strongestEvidence.1.supportingReason.isEmpty
                ? String.localizedStringWithFormat(
                    NSLocalizedString("graph.group.reason.fallback",
                                      comment: "Fallback explanation for a graph topic suggestion"),
                    displayTitle
                )
                : strongestEvidence.1.supportingReason
            let members = deduplicated.map { conversation, _ in
                GraphTopicMember(rawThreadID: normalizedThreadID(conversation.rawThreadID),
                                 graphThreadID: conversation.graphThreadID,
                                 fullTitle: conversation.fullTitle,
                                 existingFolderID: conversation.existingFolderID,
                                 existingFolderTitle: conversation.existingFolderTitle)
            }.sorted { $0.rawThreadID < $1.rawThreadID }
            let compatiblePreferenceIDs = GraphTopicPreferenceID.compatibleExactIDs(
                normalizedTopic: normalizedTopic,
                rawThreadIDs: members.map(\.rawThreadID)
            )
            guard !compatiblePreferenceIDs.isEmpty,
                  dismissedExactPreferenceIDs.isDisjoint(with: compatiblePreferenceIDs) else {
                return nil
            }

            return RankedGraphTopic(normalizedTopic: normalizedTopic,
                                    displayTitle: displayTitle,
                                    confidence: rounded(confidence),
                                    specificity: rounded(specificity),
                                    qualityScore: score,
                                    supportingReason: reason,
                                    members: members)
        }.sorted(by: candidateComesFirst)

        var seenMemberSets = Set<String>()
        var deduplicated: [RankedGraphTopic] = []
        for candidate in candidates {
            let memberSet = candidate.members.map(\.rawThreadID).joined(separator: "|")
            guard seenMemberSets.insert(memberSet).inserted else { continue }
            deduplicated.append(candidate)
            if deduplicated.count == maximumSuggestionCount { break }
        }
        return deduplicated
    }

    private static func candidateComesFirst(_ lhs: RankedGraphTopic,
                                            _ rhs: RankedGraphTopic) -> Bool {
        if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
        if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.members.count != rhs.members.count { return lhs.members.count > rhs.members.count }
        return lhs.normalizedTopic < rhs.normalizedTopic
    }

    private static func normalizedThreadID(_ rawThreadID: String) -> String {
        rawThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }
}
