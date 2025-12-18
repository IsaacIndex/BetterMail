#if canImport(XCTest)
import XCTest
@testable import BetterMail

final class ThreadIntentPipelineTests: XCTestCase {
    func testMergeClustersFragmentsWhenSimilarityHigh() {
        let nodeA = ThreadNode(message: makeMessage(id: "a@example.com",
                                                    subject: "Travel Plans",
                                                    snippet: "ASAP itinerary",
                                                    from: "Alex <alex@example.com>",
                                                    to: "Taylor <taylor@example.com>",
                                                    date: .now))
        let nodeB = ThreadNode(message: makeMessage(id: "b@example.com",
                                                    subject: "Re: Travel Plans",
                                                    snippet: "Need your reply",
                                                    from: "Taylor <taylor@example.com>",
                                                    to: "Alex <alex@example.com>",
                                                    date: .now))
        let signals = ThreadIntentSignals(intentRelevance: 0.5,
                                          urgencyScore: 0.9,
                                          personalPriorityScore: 0.7,
                                          timelinessScore: 0.6)
        let metadataA = ThreadIntentMetadata(threadID: "a@example.com",
                                             summary: "Trip summary",
                                             topicTag: "Travel",
                                             participants: [],
                                             badges: [],
                                             intentSignals: signals,
                                             isWaitingOnMe: true,
                                             hasActiveTask: true,
                                             embedding: IntentEmbedding.make(from: "travel plans"),
                                             participantLookup: Set(arrayLiteral: "alex@example.com"),
                                             lastUpdated: .now,
                                             unreadCount: 1,
                                             chronologicalIndex: 0)
        let metadataB = ThreadIntentMetadata(threadID: "b@example.com",
                                             summary: "Trip summary",
                                             topicTag: "Travel",
                                             participants: [],
                                             badges: [],
                                             intentSignals: signals,
                                             isWaitingOnMe: true,
                                             hasActiveTask: true,
                                             embedding: IntentEmbedding.make(from: "travel itinerary"),
                                             participantLookup: Set(arrayLiteral: "alex@example.com"),
                                             lastUpdated: .now,
                                             unreadCount: 1,
                                             chronologicalIndex: 1)
        let engine = ThreadMergeEngine(similarityThreshold: 0.2)
        let seeds = engine.merge(nodes: [nodeA, nodeB],
                                 metadata: [metadataA, metadataB],
                                 mergeOverrides: [:])
        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(seeds.first?.related.first?.id, "b@example.com")
    }

    func testOrderingPipelineRespectsPinsAndChronologicalFallback() {
        let groupA = ThreadGroup(id: "A",
                                 subject: "Subject A",
                                 topicTag: nil,
                                 summary: "Summary",
                                 participants: [],
                                 badges: [],
                                 intentSignals: ThreadIntentSignals(intentRelevance: 0.3,
                                                                    urgencyScore: 0.2,
                                                                    personalPriorityScore: 0.2,
                                                                    timelinessScore: 0.2),
                                 lastUpdated: Date(),
                                 unreadCount: 0,
                                 rootNodes: [],
                                 relatedConversations: [],
                                 mergeReasons: [],
                                 mergeState: .suggested,
                                 isWaitingOnMe: false,
                                 hasActiveTask: false,
                                 pinned: false,
                                 chronologicalIndex: 1)
        let groupB = ThreadGroup(id: "B",
                                 subject: "Subject B",
                                 topicTag: nil,
                                 summary: "Summary",
                                 participants: [],
                                 badges: [],
                                 intentSignals: ThreadIntentSignals(intentRelevance: 0.9,
                                                                    urgencyScore: 0.9,
                                                                    personalPriorityScore: 0.9,
                                                                    timelinessScore: 0.9),
                                 lastUpdated: Date(),
                                 unreadCount: 0,
                                 rootNodes: [],
                                 relatedConversations: [],
                                 mergeReasons: [],
                                 mergeState: .suggested,
                                 isWaitingOnMe: false,
                                 hasActiveTask: false,
                                 pinned: false,
                                 chronologicalIndex: 0)
        let pipeline = ThreadOrderingPipeline()
        let ordered = pipeline.ordered(groups: [groupA, groupB], pins: [])
        XCTAssertEqual(ordered.first?.id, "B")
        let pinned = pipeline.ordered(groups: [groupA, groupB], pins: ["A"])
        XCTAssertEqual(pinned.first?.id, "A")
    }

    private func makeMessage(id: String,
                             subject: String,
                             snippet: String,
                             from: String,
                             to: String,
                             date: Date) -> EmailMessage {
        EmailMessage(messageID: id,
                     mailboxID: "inbox",
                     subject: subject,
                     from: from,
                     to: to,
                     date: date,
                     snippet: snippet,
                     isUnread: true,
                     inReplyTo: nil,
                     references: [])
    }
}
#endif
