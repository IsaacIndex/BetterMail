import Foundation

struct ThreadGroupSeed {
    let metadata: ThreadIntentMetadata
    let root: ThreadNode
    let related: [ThreadRelatedConversation]
    let mergeReasons: [ThreadMergeReason]
}

final class ThreadMergeEngine {
    private let similarityThreshold: Double
    private let participantOverlapThreshold: Int

    init(similarityThreshold: Double = 0.82,
         participantOverlapThreshold: Int = 1) {
        self.similarityThreshold = similarityThreshold
        self.participantOverlapThreshold = participantOverlapThreshold
    }

    func merge(nodes: [ThreadNode],
               metadata: [ThreadIntentMetadata],
               mergeOverrides: [String: ThreadGroup.MergeState] = [:]) -> [ThreadGroupSeed] {
        guard !nodes.isEmpty else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: metadata.map { ($0.threadID, $0) })
        let nodeLookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.message.threadID ?? JWZThreader.threadIdentifier(for: $0), $0) })
        var visited: Set<String> = []
        var seeds: [ThreadGroupSeed] = []

        for data in metadata {
            let id = data.threadID
            guard visited.contains(id) == false else { continue }
            guard let root = nodeLookup[id] else { continue }
            var related: [ThreadRelatedConversation] = []
            var reasons: [ThreadMergeReason] = []

            for candidate in metadata where candidate.threadID != id && !visited.contains(candidate.threadID) {
                guard let candidateNode = nodeLookup[candidate.threadID] else { continue }
                let similarity = data.embedding.cosineSimilarity(with: candidate.embedding)
                let overlap = data.participantLookup.intersection(candidate.participantLookup)
                let forcedMerge = mergeOverrides[id] == .accepted || mergeOverrides[candidate.threadID] == .accepted
                guard forcedMerge || (similarity >= similarityThreshold && overlap.count >= participantOverlapThreshold) else { continue }
                let reason = ThreadMergeReason(id: candidate.threadID,
                                               description: "Related conversation: \(candidate.topicTag ?? candidateNode.message.subject)",
                                               similarity: similarity,
                                               sharedParticipants: Array(overlap))
                related.append(ThreadRelatedConversation(id: candidate.threadID,
                                                         title: candidate.topicTag ?? candidateNode.message.subject,
                                                         nodes: [candidateNode],
                                                         reason: reason))
                reasons.append(reason)
                if mergeOverrides[candidate.threadID] != .reverted {
                    visited.insert(candidate.threadID)
                }
            }

            visited.insert(id)
            let seed = ThreadGroupSeed(metadata: data,
                                       root: root,
                                       related: related,
                                       mergeReasons: reasons)
            seeds.append(seed)
        }

        return seeds
    }
}
