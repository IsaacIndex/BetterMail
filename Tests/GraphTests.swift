import CoreGraphics
import CoreData
import SpriteKit
import XCTest
@testable import BetterMail

final class GraphMappingTests: XCTestCase {
    func test_mapping_withFixtureInbox_preservesEdgeAndInboundInvariants() {
        let roots = (0..<9).map { index in
            makeThread(rootID: "root-\(index)", messageCount: 3 + index)
        }

        let graph = GraphData.make(roots: roots, now: Date(timeIntervalSince1970: 10_000))
        let messageCount = graph.messages.count

        XCTAssertEqual(graph.threads.count, 9)
        XCTAssertEqual(graph.visibleEmailNodeCount, (3...11).reduce(0, +))
        XCTAssertEqual(graph.edges.count, graph.threads.count + messageCount)
        XCTAssertEqual(graph.allNodeIDs.count, graph.threads.count + graph.messages.count + 1)

        let inboundCounts = graph.edges.reduce(into: [String: Int]()) { counts, edge in
            counts[edge.targetID, default: 0] += 1
        }
        for message in graph.messages {
            XCTAssertEqual(inboundCounts[message.id], 1, "message \(message.id) should have one inbound edge")
            XCTAssertNotNil(graph.threadByID[message.threadID])
        }
        let reachableIDs = Set(graph.edges.flatMap { [$0.sourceID, $0.targetID] })
        XCTAssertTrue(Set(graph.messages.map(\.id)).isSubset(of: reachableIDs))
        XCTAssertTrue(Set(graph.threads.map(\.id)).isSubset(of: reachableIDs))
    }

    func test_mapping_withNodeSummaries_attachesSummaryPreviewToMessages() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   summariesByNodeID: [
                                       "root-msg-1": GraphMessageSummary(text: "Confirm the deployment window and owner handoff.",
                                                                         statusMessage: "Updated now",
                                                                         isSummarizing: false)
                                   ],
                                   now: Date(timeIntervalSince1970: 10_000))

        let message = graph.messages.first { $0.rawMessageID == "root-msg-1" }
        XCTAssertEqual(message?.summaryPreviewText, "Confirm the deployment window and owner handoff.")
        XCTAssertTrue(graph.matchingNodeIDs(query: "deployment").contains(GraphData.messageNodeID(for: "root-msg-1")))
    }

    func test_mapping_usesRootSummaryAsThreadDisplayTitle() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   summariesByNodeID: [
                                       "root": GraphMessageSummary(text: "Approve the release plan and confirm its owner.",
                                                                   statusMessage: "Ready",
                                                                   isSummarizing: false)
                                   ],
                                   now: Date(timeIntervalSince1970: 10_000))

        XCTAssertEqual(graph.threads.first?.displayTitle,
                       "Approve the release plan and confirm its owner.")
        XCTAssertTrue(graph.matchingNodeIDs(query: "release plan")
            .contains(GraphData.threadNodeID(for: "root")))
    }

    func test_mapping_prefersConciseGraphTitlesWithoutReplacingFullSummaries() {
        let summary = GraphMessageSummary(
            text: "Confirm the booking-flow walkthrough scope, owner, and review-material sequence.",
            statusMessage: "Ready",
            isSummarizing: false
        )
        let graph = GraphData.make(
            roots: [makeThread(rootID: "root", messageCount: 2)],
            summariesByNodeID: ["root": summary, "root-msg-1": summary],
            titlesByNodeID: ["root": "CR60 Booking Flow", "root-msg-1": "Review Materials"],
            now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(graph.threads.first?.displayTitle, "CR60 Booking Flow")
        XCTAssertEqual(graph.messages.first?.displayTitle, "Review Materials")
        XCTAssertEqual(graph.messages.first?.summaryPreviewText, summary.text)
        XCTAssertTrue(graph.matchingNodeIDs(query: "review materials")
            .contains(GraphData.messageNodeID(for: "root-msg-1")))
    }

    func test_mapping_emailNodeCountMatchesActualEmailCountWithoutSyntheticRootLeaf() {
        let single = GraphData.make(roots: [makeThread(rootID: "single", messageCount: 1)],
                                    now: Date(timeIntervalSince1970: 10_000))
        let three = GraphData.make(roots: [makeThread(rootID: "three", messageCount: 3)],
                                   now: Date(timeIntervalSince1970: 10_000))

        XCTAssertEqual(single.visibleEmailNodeCount, 1)
        XCTAssertEqual(single.threads.count, 1)
        XCTAssertTrue(single.messages.isEmpty)
        XCTAssertEqual(three.visibleEmailNodeCount, 3)
        XCTAssertEqual(three.threads.count, 1)
        XCTAssertEqual(three.messages.count, 2)
        XCTAssertFalse(three.messages.contains { $0.rawMessageID == "three" })
    }

    func test_mapping_whenBranchLimitIsSmallerThanThreadCount_addsRemainingBranch() {
        let roots = (0..<25).map { index in
            makeThread(rootID: "root-\(index)", messageCount: 1)
        }

        let graph = GraphData.make(roots: roots,
                                   branchLimit: 10,
                                   branchBatchSize: 10,
                                   now: Date(timeIntervalSince1970: 10_000))

        XCTAssertEqual(graph.threads.count, 10)
        XCTAssertEqual(graph.visibleEmailNodeCount, 10)
        XCTAssertTrue(graph.messages.isEmpty)
        XCTAssertEqual(graph.rootRemainingBranch?.hiddenCount, 15)
        XCTAssertEqual(graph.rootRemainingBranch?.nextBatchCount, 10)
        XCTAssertTrue(graph.allNodeIDs.contains(GraphRemainingBranch.graphID))
        let remainingEdges = graph.edges.filter { $0.targetID == GraphRemainingBranch.graphID }
        XCTAssertEqual(remainingEdges.count, 1)
        XCTAssertEqual(remainingEdges.first?.kind, .remaining)
    }

    func test_mapping_whenFinalRemainingPageIsSmaller_reportsFinalBatchCount() {
        let roots = (0..<25).map { index in
            makeThread(rootID: "root-\(index)", messageCount: 1)
        }

        let graph = GraphData.make(roots: roots,
                                   branchLimit: 20,
                                   branchBatchSize: 10,
                                   now: Date(timeIntervalSince1970: 10_000))

        XCTAssertEqual(graph.threads.count, 20)
        XCTAssertEqual(graph.rootRemainingBranch?.hiddenCount, 5)
        XCTAssertEqual(graph.rootRemainingBranch?.nextBatchCount, 5)
    }

    func test_mapping_whenMessageLimitIsSet_capsRenderedMessagesButKeepsThreadActionsComplete() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 25)],
                                   branchLimit: 10,
                                   messageLimitPerBranch: 10,
                                   now: Date(timeIntervalSince1970: 10_000))

        XCTAssertEqual(graph.threads.first?.messageCount, 25)
        XCTAssertEqual(graph.threads.first?.messageIDs.count, 25)
        XCTAssertEqual(graph.visibleEmailNodeCount, 10)
        XCTAssertEqual(graph.messages.count, 9)
        XCTAssertEqual(graph.edges.count, 10)
    }

    func test_mapping_withConfirmedFolder_routesThreadsThroughFolderBranch() {
        let folder = ThreadFolder(id: "folder-work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: ["root-a", "root-b"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [makeThread(rootID: "root-a", messageCount: 1),
                                           makeThread(rootID: "root-b", messageCount: 1)],
                                   folders: [folder],
                                   folderMembershipByThreadID: ["root-a": folder.id, "root-b": folder.id],
                                   now: Date(timeIntervalSince1970: 10_000))

        let grouping = graph.groupings.first { $0.kind == .folder }
        XCTAssertEqual(grouping?.title, "Work")
        XCTAssertEqual(Set(grouping?.rawThreadIDs ?? []), ["root-a", "root-b"])
        XCTAssertTrue(graph.edges.contains {
            $0.sourceID == GraphCenter.you.id && $0.targetID == grouping?.id && $0.kind == .trunk
        })
        for rawThreadID in ["root-a", "root-b"] {
            let threadID = GraphData.threadNodeID(for: rawThreadID)
            XCTAssertTrue(graph.edges.contains {
                $0.sourceID == grouping?.id && $0.targetID == threadID && $0.kind == .grouping
            })
            XCTAssertFalse(graph.edges.contains {
                $0.sourceID == GraphCenter.you.id && $0.targetID == threadID && $0.kind == .trunk
            })
        }
    }

    func test_mapping_withConfirmedFolderAndOneVisibleMember_keepsFolderBranchVisible() {
        let folder = ThreadFolder(id: "folder-cr60",
                                  title: "CR60 Walkthrough",
                                  color: .defaultNewFolder,
                                  threadIDs: ["root-a", "root-b"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [makeThread(rootID: "root-a", messageCount: 1),
                                           makeThread(rootID: "root-b", messageCount: 1)],
                                   folders: [folder],
                                   folderMembershipByThreadID: ["root-a": folder.id, "root-b": folder.id],
                                   branchLimit: 1,
                                   now: Date(timeIntervalSince1970: 10_000))

        let grouping = graph.groupings.first { $0.sourceFolderID == folder.id }
        let visibleThreadID = GraphData.threadNodeID(for: "root-a")
        XCTAssertEqual(grouping?.title, "CR60 Walkthrough")
        XCTAssertEqual(grouping?.rawThreadIDs, ["root-a", "root-b"])
        XCTAssertEqual(grouping?.threadIDs, [GraphData.threadNodeID(for: "root-a"),
                                             GraphData.threadNodeID(for: "root-b")])
        XCTAssertEqual(graph.visiblePrimaryBranchCount, 1)
        XCTAssertEqual(graph.totalPrimaryBranchCount, 1)
        XCTAssertNil(graph.rootRemainingBranch)
        XCTAssertTrue(graph.edges.contains {
            $0.sourceID == GraphCenter.you.id && $0.targetID == grouping?.id && $0.kind == .trunk
        })
        XCTAssertTrue(graph.edges.contains {
            $0.sourceID == grouping?.id && $0.targetID == visibleThreadID && $0.kind == .grouping
        })
        XCTAssertFalse(graph.edges.contains {
            $0.sourceID == GraphCenter.you.id && $0.targetID == visibleThreadID && $0.kind == .trunk
        })
    }

    func test_mapping_withWhitespaceInConfirmedFolderMembership_resolvesVisibleThread() {
        let folder = ThreadFolder(id: "folder-normalized",
                                  title: "Normalized Folder",
                                  color: .defaultNewFolder,
                                  threadIDs: ["  root-a\n"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [makeThread(rootID: "root-a", messageCount: 1)],
                                   folders: [folder],
                                   folderMembershipByThreadID: ["\troot-a ": folder.id],
                                   now: Date(timeIntervalSince1970: 10_000))

        let grouping = graph.groupings.first { $0.sourceFolderID == folder.id }
        XCTAssertEqual(grouping?.rawThreadIDs, ["root-a"])
        XCTAssertEqual(grouping?.threadIDs, [GraphData.threadNodeID(for: "root-a")])
    }

    func test_mapping_withSharedWholeConversationTopic_createsConfirmableGhostBranch() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root-a", messageCount: 1),
                                           makeThread(rootID: "root-b", messageCount: 1),
                                           makeThread(rootID: "root-c", messageCount: 1)],
                                   topicSignalsByRawThreadID: [
                                    "root-a": makeTopicSignal("CR60 booking rollout", confidence: 0.90),
                                    "root-b": makeTopicSignal("CR60 Booking Rollout", confidence: 0.86),
                                    "root-c": makeTopicSignal("Finance planning", confidence: 0.90)
                                   ],
                                   now: Date(timeIntervalSince1970: 10_000))

        let suggestion = graph.groupings.first { $0.kind == .suggestedTopic }
        XCTAssertEqual(suggestion?.title, "CR60 booking rollout")
        XCTAssertEqual(Set(suggestion?.rawThreadIDs ?? []), ["root-a", "root-b"])
        XCTAssertEqual(suggestion?.reviewMembers.map(\.fullTitle), ["Subject root-a", "Subject root-b"])
        XCTAssertTrue(suggestion?.isSuggestion == true)
        XCTAssertTrue(graph.edges.contains { $0.sourceID == suggestion?.id && $0.kind == .suggested })
    }

    func test_mapping_confirmedFolderConsumesOneRootSlotAndPagesItsChildrenInSourceOrder() throws {
        let folder = ThreadFolder(id: "folder-topic",
                                  title: "Handled Topic",
                                  color: .defaultNewFolder,
                                  threadIDs: ["grouped-0", "grouped-1", "grouped-2"],
                                  parentID: nil)
        let graph = GraphData.make(
            roots: [makeThread(rootID: "grouped-0", messageCount: 1),
                    makeThread(rootID: "grouped-1", messageCount: 1),
                    makeThread(rootID: "grouped-2", messageCount: 1),
                    makeThread(rootID: "unhandled-0", messageCount: 1),
                    makeThread(rootID: "unhandled-1", messageCount: 1)],
            folders: [folder],
            folderMembershipByThreadID: ["grouped-0": folder.id,
                                         "grouped-1": folder.id,
                                         "grouped-2": folder.id],
            branchLimit: 2,
            branchBatchSize: 2,
            perNodeBranchPageSize: 2,
            now: Date(timeIntervalSince1970: 10_000)
        )

        let grouping = try XCTUnwrap(graph.groupings.first { $0.sourceFolderID == folder.id })
        XCTAssertEqual(graph.visiblePrimaryBranchCount, 2)
        XCTAssertEqual(graph.totalPrimaryBranchCount, 3)
        XCTAssertEqual(grouping.threadIDs, [GraphData.threadNodeID(for: "grouped-0"),
                                            GraphData.threadNodeID(for: "grouped-1")])
        XCTAssertTrue(graph.threads.contains { $0.rawThreadID == "unhandled-0" })
        XCTAssertFalse(graph.threads.contains { $0.rawThreadID == "unhandled-1" })
        XCTAssertEqual(graph.rootRemainingBranch?.hiddenCount, 1)
        let childRemainder = try XCTUnwrap(graph.remainingBranch(forParentID: grouping.id))
        XCTAssertEqual(childRemainder.id, GraphRemainingBranch.graphID(for: grouping.id))
        XCTAssertEqual(childRemainder.hiddenCount, 1)
        XCTAssertEqual(childRemainder.nextBatchCount, 1)
        XCTAssertTrue(childRemainder.accessibilityLabel.contains(grouping.title))
    }

    func test_mapping_suggestionStaysOutsideRootQuotaAndPreviewsHiddenThreadWithoutDuplication() throws {
        let roots = (0..<8).map { makeThread(rootID: "root-\($0)", messageCount: 1) }
        let graph = GraphData.make(
            roots: roots,
            topicSignalsByRawThreadID: [
                "root-0": makeTopicSignal("CR60 hidden inbox rollout", confidence: 0.92),
                "root-7": makeTopicSignal("CR60 hidden inbox rollout", confidence: 0.90)
            ],
            branchLimit: 2,
            branchBatchSize: 2,
            perNodeBranchPageSize: 6,
            now: Date(timeIntervalSince1970: 10_000)
        )

        let suggestion = try XCTUnwrap(graph.groupings.first(where: \.isSuggestion))
        let sharedThreadID = GraphData.threadNodeID(for: "root-0")
        let otherwiseHiddenThreadID = GraphData.threadNodeID(for: "root-7")
        XCTAssertEqual(graph.visiblePrimaryBranchCount, 2)
        XCTAssertEqual(graph.totalPrimaryBranchCount, 8)
        XCTAssertEqual(graph.rootRemainingBranch?.hiddenCount, 6)
        XCTAssertEqual(graph.threads.filter { $0.id == sharedThreadID }.count, 1)
        XCTAssertNotNil(graph.threadByID[otherwiseHiddenThreadID])
        XCTAssertTrue(graph.edges.contains {
            $0.sourceID == GraphCenter.you.id && $0.targetID == sharedThreadID && $0.kind == .trunk
        })
        XCTAssertTrue(graph.edges.contains {
            $0.sourceID == suggestion.id && $0.targetID == sharedThreadID && $0.kind == .suggested
        })
        XCTAssertTrue(graph.edges.contains {
            $0.sourceID == suggestion.id && $0.targetID == otherwiseHiddenThreadID && $0.kind == .suggested
        })
    }

    func test_mapping_suggestionPreviewCapsAtSixAndPagesItsStableRemainder() throws {
        let roots = (0..<8).map { makeThread(rootID: "topic-\($0)", messageCount: 1) }
        let signals = Dictionary(uniqueKeysWithValues: (0..<8).map {
            ("topic-\($0)", makeTopicSignal("CR60 inbox coverage rollout", confidence: 0.90))
        })
        let suggestionID = "suggestion:\(GraphTopicNormalizer.identifierComponent("CR60 inbox coverage rollout"))"
        let initial = GraphData.make(
            roots: roots,
            topicSignalsByRawThreadID: signals,
            branchLimit: 2,
            perNodeBranchPageSize: 12,
            now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(initial.groupingByID[suggestionID]?.threadIDs.count, 6)
        let initialRemainder = try XCTUnwrap(initial.remainingBranch(forParentID: suggestionID))
        XCTAssertEqual(initialRemainder.id, GraphRemainingBranch.graphID(for: suggestionID))
        XCTAssertEqual(initialRemainder.hiddenCount, 2)
        XCTAssertEqual(initialRemainder.nextBatchCount, 2)

        let expanded = GraphData.make(
            roots: roots,
            topicSignalsByRawThreadID: signals,
            branchLimit: 2,
            perNodeBranchPageSize: 12,
            visibleChildLimitsByParentID: [suggestionID: 18],
            now: Date(timeIntervalSince1970: 10_000)
        )
        XCTAssertEqual(expanded.groupingByID[suggestionID]?.threadIDs.count, 8)
        XCTAssertNil(expanded.remainingBranch(forParentID: suggestionID))
    }

    func test_mapping_archivedThreadsAreExcludedFromPrimaryAndChildBudgets() {
        let folder = ThreadFolder(id: "folder-archive",
                                  title: "Archive Check",
                                  color: .defaultNewFolder,
                                  threadIDs: ["kept", "archived"],
                                  parentID: nil)
        let graph = GraphData.make(
            roots: [makeThread(rootID: "kept", messageCount: 1),
                    makeThread(rootID: "archived", messageCount: 1),
                    makeThread(rootID: "unhandled", messageCount: 1)],
            archivedThreadIDs: [GraphData.threadNodeID(for: "archived")],
            folders: [folder],
            folderMembershipByThreadID: ["kept": folder.id, "archived": folder.id],
            branchLimit: 2,
            perNodeBranchPageSize: 2,
            now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(graph.visiblePrimaryBranchCount, 2)
        XCTAssertEqual(graph.totalPrimaryBranchCount, 2)
        XCTAssertNil(graph.rootRemainingBranch)
        XCTAssertNil(graph.threadByID[GraphData.threadNodeID(for: "archived")])
        XCTAssertNil(graph.groupings.first.flatMap { graph.remainingBranch(forParentID: $0.id) })
    }

    func test_mapping_whenSuggestedTopicIsDismissed_hidesEquivalentNormalizedSuggestion() {
        let roots = [makeThread(rootID: "root-a", messageCount: 1),
                     makeThread(rootID: "root-b", messageCount: 1),
                     makeThread(rootID: "root-c", messageCount: 1),
                     makeThread(rootID: "root-d", messageCount: 1)]
        let originalSignals = [
            "root-a": makeTopicSignal("CR60 booking rollout", confidence: 0.90),
            "root-b": makeTopicSignal("CR60 Booking Rollout", confidence: 0.86),
            "root-c": makeTopicSignal("Finance planning", confidence: 0.90),
            "root-d": makeTopicSignal("Finance Planning", confidence: 0.86)
        ]
        let initialGraph = GraphData.make(roots: roots,
                                          topicSignalsByRawThreadID: originalSignals,
                                          now: Date(timeIntervalSince1970: 10_000))
        guard let rolloutSuggestion = initialGraph.groupings.first(where: { grouping in
            grouping.isSuggestion && Set(grouping.rawThreadIDs) == ["root-a", "root-b"]
        }), let dismissalID = rolloutSuggestion.suggestionDismissalID else {
            return XCTFail("Expected a dismissible rollout topic suggestion")
        }

        let remappedGraph = GraphData.make(
            roots: roots,
            topicSignalsByRawThreadID: originalSignals,
            dismissedSuggestedTopicIDs: [dismissalID],
            now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertFalse(remappedGraph.groupings.contains { grouping in
            grouping.isSuggestion && Set(grouping.rawThreadIDs) == ["root-a", "root-b"]
        })
        XCTAssertTrue(remappedGraph.groupings.contains { grouping in
            grouping.isSuggestion && Set(grouping.rawThreadIDs) == ["root-c", "root-d"]
        })
    }
}

final class GraphSuggestionDismissalSettingsTests: XCTestCase {
    @MainActor
    func test_dismissSuggestedTopic_whenSettingsAreRecreated_persistsDismissal() throws {
        let suiteName = "GraphSuggestionDismissalSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dismissalID = "suggestion:launch:root-a.root-b"

        let firstSettings = GraphCanvasSettings(userDefaults: defaults)
        firstSettings.dismissSuggestedTopic(id: dismissalID)

        let recreatedSettings = GraphCanvasSettings(userDefaults: defaults)
        XCTAssertTrue(recreatedSettings.dismissedSuggestedTopicIDs.contains(dismissalID))
    }

    @MainActor
    func test_topicPreferences_whenPersistedAndReset_remainIndependent() throws {
        let suiteName = "GraphSuggestionPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let exactID = try XCTUnwrap(GraphTopicPreferenceID.exact(
            normalizedTopic: "CR60 booking rollout",
            rawThreadIDs: ["root-a", "root-b"]
        ))

        let firstSettings = GraphCanvasSettings(userDefaults: defaults)
        firstSettings.rejectSuggestedGroup(id: exactID)
        firstSettings.hideSuggestedTopic(" Finance Planning ")

        let recreatedSettings = GraphCanvasSettings(userDefaults: defaults)
        XCTAssertEqual(recreatedSettings.dismissedSuggestedTopicIDs, [exactID])
        XCTAssertEqual(recreatedSettings.hiddenSuggestedTopics, ["finance planning"])

        recreatedSettings.resetSuggestedTopicPreferences()
        let resetSettings = GraphCanvasSettings(userDefaults: defaults)
        XCTAssertTrue(resetSettings.dismissedSuggestedTopicIDs.isEmpty)
        XCTAssertTrue(resetSettings.hiddenSuggestedTopics.isEmpty)
        XCTAssertFalse(resetSettings.hasSuggestedTopicPreferences)
    }

    @MainActor
    func test_visibleBranchesPerNode_defaultsClampsAndPersists() throws {
        let suiteName = "GraphVisibleBranchesPerNodeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(GraphCanvasSettings.visibleBranchesPerNodeRange, 2...12)
        XCTAssertEqual(GraphCanvasSettings.defaultVisibleBranchesPerNode, 6)
        let settings = GraphCanvasSettings(userDefaults: defaults)
        XCTAssertEqual(settings.visibleBranchesPerNode, 6)

        settings.visibleBranchesPerNode = 99
        XCTAssertEqual(settings.visibleBranchesPerNode, 12)
        XCTAssertEqual(GraphCanvasSettings(userDefaults: defaults).visibleBranchesPerNode, 12)

        defaults.set(-3, forKey: "graphCanvasVisibleBranchesPerNode")
        XCTAssertEqual(GraphCanvasSettings(userDefaults: defaults).visibleBranchesPerNode, 2)
    }
}

final class GraphTopicQualityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func test_normalization_isLocaleInvariantAndCanonical() {
        XCTAssertEqual(GraphTopicNormalizer.normalize("  CR60—Bóóking / ROLLOUT!  "),
                       "cr60 booking rollout")
        XCTAssertEqual(GraphTopicNormalizer.normalize("ＣＲ６０ booking.rollout"),
                       "cr60 booking rollout")
    }

    func test_genericTopicRejection_rejectsWorkflowLabelsButKeepsSpecificTopic() {
        for topic in ["Update", "Review", "Meeting", "Weekly meeting", "Status"] {
            XCTAssertTrue(GraphTopicQualityPolicy.isGeneric(topic), topic)
            XCTAssertEqual(GraphTopicQualityPolicy.specificity(of: topic), 0, topic)
        }
        XCTAssertFalse(GraphTopicQualityPolicy.isGeneric("CR60 booking rollout"))
        XCTAssertGreaterThanOrEqual(GraphTopicQualityPolicy.specificity(of: "CR60 booking rollout"),
                                    GraphTopicRanker.minimumSpecificity)
    }

    func test_thresholds_rejectLowConfidenceAndLowOverallQuality() {
        let recent = [
            makeTopicConversation("a", date: now.addingTimeInterval(-3_600)),
            makeTopicConversation("b", date: now.addingTimeInterval(-7_200))
        ]
        let lowConfidence = GraphTopicRanker.rank(
            conversations: recent,
            signalsByRawThreadID: [
                "a": makeTopicSignal("CR60 booking rollout", confidence: 0.67),
                "b": makeTopicSignal("CR60 booking rollout", confidence: 0.67)
            ],
            now: now
        )
        XCTAssertTrue(lowConfidence.isEmpty)

        let oldFoldered = [
            makeTopicConversation("a", date: now.addingTimeInterval(-400 * 86_400), folderID: "folder-a"),
            makeTopicConversation("b", date: now.addingTimeInterval(-250 * 86_400), folderID: "folder-b")
        ]
        let lowQuality = GraphTopicRanker.rank(
            conversations: oldFoldered,
            signalsByRawThreadID: [
                "a": makeTopicSignal("booking rollout", confidence: 0.68),
                "b": makeTopicSignal("booking rollout", confidence: 0.68)
            ],
            now: now
        )
        XCTAssertTrue(lowQuality.isEmpty)
    }

    func test_scoringOrder_prioritizesSpecificConfidentCohesiveUsefulTopic() {
        let conversations = [
            makeTopicConversation("a", date: now.addingTimeInterval(-3_600)),
            makeTopicConversation("b", date: now.addingTimeInterval(-7_200)),
            makeTopicConversation("c", date: now.addingTimeInterval(-300 * 86_400)),
            makeTopicConversation("d", date: now.addingTimeInterval(-240 * 86_400))
        ]
        let ranked = GraphTopicRanker.rank(
            conversations: conversations,
            signalsByRawThreadID: [
                "a": makeTopicSignal("CR60 booking rollout", confidence: 0.82),
                "b": makeTopicSignal("CR60 booking rollout", confidence: 0.82),
                "c": makeTopicSignal("budget planning", confidence: 0.95),
                "d": makeTopicSignal("budget planning", confidence: 0.95)
            ],
            now: now
        )

        XCTAssertEqual(ranked.map(\.normalizedTopic), ["cr60 booking rollout", "budget planning"])
        XCTAssertGreaterThan(ranked[0].qualityScore, ranked[1].qualityScore)
    }

    func test_topThree_returnsOnlyThreePassingCandidatesWithStableTieBreak() {
        var conversations: [GraphTopicConversation] = []
        var signals: [String: GraphTopicSignal] = [:]
        for index in 1...4 {
            for suffix in ["a", "b"] {
                let threadID = "\(index)-\(suffix)"
                conversations.append(makeTopicConversation(threadID,
                                                            date: now.addingTimeInterval(Double(-index * 60))))
                signals[threadID] = makeTopicSignal("A\(index) rollout stream", confidence: 0.90)
            }
        }

        let ranked = GraphTopicRanker.rank(conversations: conversations,
                                           signalsByRawThreadID: signals,
                                           now: now)

        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(ranked.map(\.normalizedTopic),
                       ["a1 rollout stream", "a2 rollout stream", "a3 rollout stream"])
    }

    func test_zeroResult_whenSignalsAreMissingGenericOrSingleThread() {
        let conversations = [
            makeTopicConversation("a", date: now),
            makeTopicConversation("b", date: now)
        ]
        XCTAssertTrue(GraphTopicRanker.rank(conversations: conversations,
                                            signalsByRawThreadID: [:],
                                            now: now).isEmpty)
        XCTAssertTrue(GraphTopicRanker.rank(
            conversations: conversations,
            signalsByRawThreadID: [
                "a": makeTopicSignal("Meeting", confidence: 0.99),
                "b": makeTopicSignal("meeting", confidence: 0.99)
            ],
            now: now
        ).isEmpty)
        XCTAssertTrue(GraphTopicRanker.rank(
            conversations: conversations,
            signalsByRawThreadID: ["a": makeTopicSignal("CR60 booking rollout", confidence: 0.99)],
            now: now
        ).isEmpty)
    }

    func test_deduplication_mergesCanonicalTopicVariantsIntoOneCandidate() {
        let ranked = GraphTopicRanker.rank(
            conversations: [makeTopicConversation("a", date: now),
                            makeTopicConversation("b", date: now)],
            signalsByRawThreadID: [
                "a": makeTopicSignal("CR60—Booking Rollout", confidence: 0.88),
                "b": makeTopicSignal("cr60 booking rollout", confidence: 0.90)
            ],
            now: now
        )

        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.normalizedTopic, "cr60 booking rollout")
        XCTAssertEqual(Set(ranked.first?.members.map(\.rawThreadID) ?? []), ["a", "b"])
    }

    func test_visibleScopeStability_keepsRankedMembersIndependentOfInitialPage() throws {
        let roots = [makeThread(rootID: "root-a", messageCount: 1),
                     makeThread(rootID: "root-b", messageCount: 1),
                     makeThread(rootID: "root-c", messageCount: 1),
                     makeThread(rootID: "root-d", messageCount: 1)]
        let signals = [
            "root-c": makeTopicSignal("CR60 booking rollout", confidence: 0.90),
            "root-d": makeTopicSignal("CR60 booking rollout", confidence: 0.88)
        ]
        let initialPage = GraphData.make(roots: roots,
                                         topicSignalsByRawThreadID: signals,
                                         branchLimit: 2,
                                         now: Date(timeIntervalSince1970: 10_000))
        let expandedPage = GraphData.make(roots: roots,
                                          topicSignalsByRawThreadID: signals,
                                          branchLimit: 4,
                                          now: Date(timeIntervalSince1970: 10_000))
        let initialSuggestion = try XCTUnwrap(initialPage.groupings.first(where: \.isSuggestion))
        let expandedSuggestion = try XCTUnwrap(expandedPage.groupings.first(where: \.isSuggestion))

        XCTAssertEqual(initialSuggestion.id, expandedSuggestion.id)
        XCTAssertEqual(initialSuggestion.rawThreadIDs, expandedSuggestion.rawThreadIDs)
        XCTAssertEqual(initialSuggestion.reviewMembers, expandedSuggestion.reviewMembers)
        XCTAssertTrue(initialSuggestion.threadIDs.isEmpty)
        XCTAssertEqual(Set(expandedSuggestion.threadIDs),
                       [GraphData.threadNodeID(for: "root-c"), GraphData.threadNodeID(for: "root-d")])
    }

    func test_rejectionModes_exactRejectionAllowsChangedMembershipButHiddenTopicDoesNot() throws {
        let baseConversations = [makeTopicConversation("a", date: now),
                                 makeTopicConversation("b", date: now)]
        let baseSignals = [
            "a": makeTopicSignal("CR60 booking rollout", confidence: 0.90),
            "b": makeTopicSignal("CR60 booking rollout", confidence: 0.88)
        ]
        let initial = try XCTUnwrap(GraphTopicRanker.rank(conversations: baseConversations,
                                                          signalsByRawThreadID: baseSignals,
                                                          now: now).first)
        let exactID = try XCTUnwrap(initial.exactPreferenceID)
        XCTAssertTrue(GraphTopicRanker.rank(
            conversations: baseConversations,
            signalsByRawThreadID: baseSignals,
            dismissedExactPreferenceIDs: [exactID],
            now: now
        ).isEmpty)

        let changedConversations = baseConversations + [makeTopicConversation("c", date: now)]
        let changedSignals = baseSignals.merging([
            "c": makeTopicSignal("CR60 booking rollout", confidence: 0.86)
        ], uniquingKeysWith: { _, new in new })
        let changedMembership = GraphTopicRanker.rank(
            conversations: changedConversations,
            signalsByRawThreadID: changedSignals,
            dismissedExactPreferenceIDs: [exactID],
            now: now
        )
        XCTAssertEqual(changedMembership.first?.members.count, 3)
        XCTAssertTrue(GraphTopicRanker.rank(
            conversations: changedConversations,
            signalsByRawThreadID: changedSignals,
            dismissedExactPreferenceIDs: [exactID],
            hiddenNormalizedTopics: ["CR60 BOOKING ROLLOUT"],
            now: now
        ).isEmpty)
    }

    func test_exactPreferenceIdentity_preservesMemberIDsAndHonorsLegacyDismissals() throws {
        let punctuationID = try XCTUnwrap(GraphTopicPreferenceID.exact(
            normalizedTopic: "CR60 booking rollout",
            rawThreadIDs: ["thread-a-b", "thread-c"]
        ))
        let whitespaceID = try XCTUnwrap(GraphTopicPreferenceID.exact(
            normalizedTopic: "CR60 booking rollout",
            rawThreadIDs: ["thread-a b", "thread-c"]
        ))
        XCTAssertNotEqual(punctuationID, whitespaceID,
                          "Exact member sets must not collide after identifier sanitization")

        let conversations = [makeTopicConversation("a", date: now),
                             makeTopicConversation("b", date: now)]
        let signals = [
            "a": makeTopicSignal("CR60 booking rollout", confidence: 0.90),
            "b": makeTopicSignal("CR60 booking rollout", confidence: 0.88)
        ]
        let legacyID = try XCTUnwrap(GraphTopicPreferenceID.legacyExact(
            normalizedTopic: "CR60 booking rollout",
            rawThreadIDs: ["a", "b"]
        ))
        XCTAssertTrue(GraphTopicRanker.rank(
            conversations: conversations,
            signalsByRawThreadID: signals,
            dismissedExactPreferenceIDs: [legacyID],
            now: now
        ).isEmpty)
    }
}

final class GraphSuggestionReviewViewModelTests: XCTestCase {
    @MainActor
    func test_create_passesEditedNameAndOnlySelectedMembersExactly() async {
        var capturedName: String?
        var capturedThreadIDs: Set<String>?
        let viewModel = GraphSuggestionReviewViewModel(
            grouping: makeReviewGrouping(),
            impactProvider: { _ in .none },
            confirmFolder: { name, threadIDs in
                capturedName = name
                capturedThreadIDs = threadIDs
            }
        )
        viewModel.folderName = "Edited CR60 rollout"
        viewModel.setSelected(false, member: viewModel.members[2])

        await viewModel.requestCreate()

        XCTAssertEqual(capturedName, "Edited CR60 rollout")
        XCTAssertEqual(capturedThreadIDs, ["root-a", "root-b"])
        XCTAssertTrue(viewModel.didCreateFolder)
    }

    @MainActor
    func test_existingFolderImpact_requiresConfirmationAndCancellationDoesNotMutate() async {
        var confirmationCount = 0
        let impact = GraphFolderSuggestionImpact(affectedFolders: [
            .init(id: "folder-a", title: "Existing", movedThreadCount: 2, willBeRemoved: true)
        ])
        let viewModel = GraphSuggestionReviewViewModel(
            grouping: makeReviewGrouping(),
            impactProvider: { _ in impact },
            confirmFolder: { _, _ in confirmationCount += 1 }
        )

        await viewModel.requestCreate()
        XCTAssertTrue(viewModel.isImpactConfirmationPresented)
        XCTAssertEqual(confirmationCount, 0)

        viewModel.cancelExistingFolderImpact()
        XCTAssertFalse(viewModel.isImpactConfirmationPresented)
        XCTAssertEqual(confirmationCount, 0)

        await viewModel.requestCreate()
        await viewModel.confirmExistingFolderImpact()
        XCTAssertEqual(confirmationCount, 1)
        XCTAssertTrue(viewModel.didCreateFolder)
    }

    @MainActor
    func test_existingFolderImpact_preservesParentWithChildrenAndFlagsOnlyEmptiedLeaves() throws {
        let suiteName = "GraphFolderSuggestionImpactTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let threadViewModel = ThreadCanvasViewModel(
            settings: AutoRefreshSettings(),
            inspectorSettings: InspectorViewSettings(),
            store: store,
            summaryCapability: EmailSummaryCapability(provider: nil,
                                                      statusMessage: "Unavailable",
                                                      providerID: "test-none"),
            tagCapability: EmailTagCapability(provider: nil,
                                              statusMessage: "Unavailable",
                                              providerID: "test-none")
        )
        let parent = ThreadFolder(id: "folder-parent",
                                  title: "Parent",
                                  color: .defaultNewFolder,
                                  threadIDs: ["root-a"],
                                  parentID: nil)
        let emptiedChild = ThreadFolder(id: "folder-child",
                                        title: "Child",
                                        color: .defaultNewFolder,
                                        threadIDs: ["root-b"],
                                        parentID: parent.id)
        let partiallyMovedLeaf = ThreadFolder(id: "folder-partial",
                                              title: "Partial",
                                              color: .defaultNewFolder,
                                              threadIDs: ["root-c", "root-d"],
                                              parentID: nil)
        threadViewModel.applyRethreadResultForTesting(
            roots: [],
            folders: [parent, emptiedChild, partiallyMovedLeaf]
        )

        let impact = threadViewModel.graphFolderSuggestionImpact(
            for: ["root-a", "root-b", "root-c"]
        )
        let impactByID = Dictionary(uniqueKeysWithValues: impact.affectedFolders.map { ($0.id, $0) })

        XCTAssertEqual(impact.movedThreadCount, 3)
        XCTAssertFalse(try XCTUnwrap(impactByID[parent.id]).willBeRemoved,
                       "A parent with a child folder must remain even when its direct membership empties")
        XCTAssertTrue(try XCTUnwrap(impactByID[emptiedChild.id]).willBeRemoved)
        XCTAssertFalse(try XCTUnwrap(impactByID[partiallyMovedLeaf.id]).willBeRemoved)
    }
}

final class GraphBranchPagingTests: XCTestCase {
    func test_expandRemainingBranches_revealsNextTenAtATime() async {
        await MainActor.run {
            let suiteName = "GraphBranchPagingTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
            let viewModel = GraphCanvasViewModel(store: store)
            let roots = (0..<25).map { index in
                makeThread(rootID: "root-\(index)", messageCount: 1)
            }

            viewModel.update(roots: roots,
                             searchQuery: "",
                             tagsByNodeID: [:],
                             summariesByNodeID: [:])

            XCTAssertEqual(viewModel.data.threads.count, 10)
            XCTAssertEqual(viewModel.data.rootRemainingBranch?.hiddenCount, 15)

            viewModel.expandRemainingBranches(parentID: GraphCenter.you.id)
            XCTAssertEqual(viewModel.data.threads.count, 20)
            XCTAssertEqual(viewModel.data.rootRemainingBranch?.hiddenCount, 5)

            viewModel.expandRemainingBranches(parentID: GraphCenter.you.id)
            XCTAssertEqual(viewModel.data.threads.count, 25)
            XCTAssertNil(viewModel.data.rootRemainingBranch)
        }
    }

    func test_update_withConfiguredBranchPageSize_usesThatCountForPaging() async {
        await MainActor.run {
            let suiteName = "GraphBranchPagingConfiguredTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
            let viewModel = GraphCanvasViewModel(store: store)
            let roots = (0..<17).map { index in
                makeThread(rootID: "root-\(index)", messageCount: 1)
            }

            viewModel.update(roots: roots,
                             searchQuery: "",
                             tagsByNodeID: [:],
                             summariesByNodeID: [:],
                             branchPageSize: 6)

            XCTAssertEqual(viewModel.data.threads.count, 6)
            XCTAssertEqual(viewModel.data.rootRemainingBranch?.nextBatchCount, 6)
            viewModel.expandRemainingBranches(parentID: GraphCenter.you.id)
            XCTAssertEqual(viewModel.data.threads.count, 12)
            XCTAssertEqual(viewModel.data.rootRemainingBranch?.hiddenCount, 5)
        }
    }

    func test_expandRemainingBranches_targetsOnlyClickedParentAndRetainsExpansionAcrossMetadataRefresh() async {
        await MainActor.run {
            let suiteName = "GraphChildBranchPagingTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let viewModel = GraphCanvasViewModel(
                store: MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
            )
            let firstIDs = (0..<8).map { "first-\($0)" }
            let secondIDs = (0..<8).map { "second-\($0)" }
            let roots = (firstIDs + secondIDs).map { makeThread(rootID: $0, messageCount: 1) }
            let firstFolder = ThreadFolder(id: "folder-first",
                                           title: "First Topic",
                                           color: .defaultNewFolder,
                                           threadIDs: Set(firstIDs),
                                           parentID: nil)
            let secondFolder = ThreadFolder(id: "folder-second",
                                            title: "Second Topic",
                                            color: .defaultNewFolder,
                                            threadIDs: Set(secondIDs),
                                            parentID: nil)
            let membership = Dictionary(uniqueKeysWithValues:
                firstIDs.map { ($0, firstFolder.id) } + secondIDs.map { ($0, secondFolder.id) })

            viewModel.update(roots: roots,
                             searchQuery: "",
                             tagsByNodeID: [:],
                             summariesByNodeID: [:],
                             folders: [firstFolder, secondFolder],
                             folderMembershipByThreadID: membership,
                             perNodeBranchPageSize: 6)

            let firstParentID = "folder:\(firstFolder.id)"
            let secondParentID = "folder:\(secondFolder.id)"
            XCTAssertEqual(viewModel.data.groupingByID[firstParentID]?.threadIDs.count, 6)
            XCTAssertEqual(viewModel.data.groupingByID[secondParentID]?.threadIDs.count, 6)
            XCTAssertEqual(viewModel.data.remainingBranch(forParentID: firstParentID)?.hiddenCount, 2)
            XCTAssertEqual(viewModel.data.remainingBranch(forParentID: secondParentID)?.hiddenCount, 2)

            viewModel.expandRemainingBranches(parentID: firstParentID)
            XCTAssertEqual(viewModel.data.groupingByID[firstParentID]?.threadIDs.count, 8)
            XCTAssertNil(viewModel.data.remainingBranch(forParentID: firstParentID))
            XCTAssertEqual(viewModel.data.groupingByID[secondParentID]?.threadIDs.count, 6)
            XCTAssertEqual(viewModel.data.remainingBranch(forParentID: secondParentID)?.hiddenCount, 2)

            viewModel.update(roots: roots,
                             searchQuery: "",
                             tagsByNodeID: ["first-0": ["Refreshed"]],
                             summariesByNodeID: [:],
                             folders: [firstFolder, secondFolder],
                             folderMembershipByThreadID: membership,
                             perNodeBranchPageSize: 6)
            XCTAssertEqual(viewModel.data.groupingByID[firstParentID]?.threadIDs.count, 8)

            viewModel.update(roots: roots,
                             searchQuery: "",
                             tagsByNodeID: [:],
                             summariesByNodeID: [:],
                             folders: [firstFolder, secondFolder],
                             folderMembershipByThreadID: membership,
                             perNodeBranchPageSize: 4)
            XCTAssertEqual(viewModel.data.groupingByID[firstParentID]?.threadIDs.count, 4)
            XCTAssertEqual(viewModel.data.groupingByID[secondParentID]?.threadIDs.count, 4)
        }
    }
}

final class GraphViewportTests: XCTestCase {
    func test_clampedZoom_keepsExpandedGraphRange() {
        XCTAssertEqual(GraphViewport.clampedZoom(0.01), 0.2)
        XCTAssertEqual(GraphViewport.clampedZoom(1.25), 1.25)
        XCTAssertEqual(GraphViewport.clampedZoom(8), 5.0)
    }

    func test_scrollInput_pansPreciseTrackpadUnlessZoomModifierIsPressed() {
        XCTAssertFalse(GraphScene.shouldZoomScroll(hasPreciseScrollingDeltas: true,
                                                   hasZoomModifier: false))
        XCTAssertTrue(GraphScene.shouldZoomScroll(hasPreciseScrollingDeltas: false,
                                                  hasZoomModifier: true))
        XCTAssertFalse(GraphScene.shouldZoomScroll(hasPreciseScrollingDeltas: false,
                                                   hasZoomModifier: false))
    }

    func test_graphScene_cameraAcceptsUnboundedPanAndPreservesItAcrossResize() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let scene = GraphScene(size: CGSize(width: 960, height: 640))
        let panOffset = CGPoint(x: -1_800, y: 1_400)
        scene.configure(data: graph,
                        selectedGraphNodeID: nil,
                        pruneMode: .idle,
                        filteredNodeIDs: graph.allNodeIDs,
                        wateredCounts: [:],
                        reduceMotion: true,
                        sproutingMessageIDs: [],
                        forceConfig: GraphForceConstants.defaults,
                        theme: DesignTokens.Graph.AppTheme.Palette(isDark: false),
                        zoomScale: 1,
                        panOffset: panOffset)

        assertPointsEqual(scene.camera?.position,
                          CGPoint(x: 480 + panOffset.x, y: 320 + panOffset.y))

        scene.size = CGSize(width: 1_200, height: 800)

        assertPointsEqual(scene.camera?.position,
                          CGPoint(x: 600 + panOffset.x, y: 400 + panOffset.y))
    }
}

final class GraphForceSimulatorTests: XCTestCase {
    func test_forceSimulator_initialLayout_centersRootAndGrowsBranchesOutward() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 4)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        let size = CGSize(width: 800, height: 600)
        simulator.reset(data: graph, size: size)
        let center = simulator.nodesByID[GraphCenter.you.id]?.position ?? .zero
        let threadID = GraphData.threadNodeID(for: "root")
        let threadPosition = simulator.nodesByID[threadID]?.position ?? .zero
        let messageDistances = graph.messages
            .sorted { $0.index < $1.index }
            .compactMap { message in
                simulator.nodesByID[message.id].map { pointDistance(center, $0.position) }
            }

        assertPointsEqual(center, CGPoint(x: size.width / 2, y: size.height / 2))
        XCTAssertGreaterThan(pointDistance(center, threadPosition), 200)
        XCTAssertTrue(messageDistances.allSatisfy { $0 > pointDistance(center, threadPosition) })
        XCTAssertEqual(Set(messageDistances.map { Int($0.rounded()) }).count,
                       messageDistances.count,
                       "Fanned message leaves should remain spatially discoverable")
    }

    func test_forceSimulator_threadAnchors_spreadBranchesAroundRoot() {
        let graph = GraphData.make(roots: (0..<16).map { makeThread(rootID: "root-\($0)", messageCount: 1) },
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        let size = CGSize(width: 1200, height: 800)
        simulator.reset(data: graph, size: size)
        let center = GraphForceSimulator.rootAnchor(in: size)
        let threadIDs = graph.threads.map(\.id)
        let threadPositions = threadIDs.compactMap { simulator.nodesByID[$0]?.position }

        XCTAssertTrue(threadPositions.contains { $0.x < center.x && $0.y < center.y })
        XCTAssertTrue(threadPositions.contains { $0.x < center.x && $0.y > center.y })
        XCTAssertTrue(threadPositions.contains { $0.x > center.x && $0.y < center.y })
        XCTAssertTrue(threadPositions.contains { $0.x > center.x && $0.y > center.y })

        var minimumPairDistance = CGFloat.greatestFiniteMagnitude
        for leftIndex in 0..<(threadPositions.count - 1) {
            for rightIndex in (leftIndex + 1)..<threadPositions.count {
                minimumPairDistance = min(minimumPairDistance,
                                          pointDistance(threadPositions[leftIndex],
                                                        threadPositions[rightIndex]))
            }
        }
        XCTAssertGreaterThan(minimumPairDistance, 80)
        XCTAssertTrue(threadPositions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func test_forceSimulator_afterSettling_keepsBranchesSeparatedAndMessagesGrowingOutward() {
        let graph = GraphData.make(roots: (0..<12).map {
            makeThread(rootID: "root-\($0)", messageCount: 3)
        }, now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 1_200, height: 900))

        for tick in 1...360 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true,
                           labelOccluderFrame: { node in
                               let halfSize: CGFloat = node.kind == .thread ? 108 : 18
                               return CGRect(x: node.position.x - halfSize,
                                             y: node.position.y - halfSize,
                                             width: halfSize * 2,
                                             height: halfSize * 2)
                           })
        }

        let center = GraphForceSimulator.rootAnchor(in: simulator.size)
        let threadPositions = graph.threads.compactMap { simulator.nodesByID[$0.id]?.position }
        var minimumPairDistance = CGFloat.greatestFiniteMagnitude
        for leftIndex in 0..<(threadPositions.count - 1) {
            for rightIndex in (leftIndex + 1)..<threadPositions.count {
                minimumPairDistance = min(minimumPairDistance,
                                          pointDistance(threadPositions[leftIndex], threadPositions[rightIndex]))
            }
        }
        XCTAssertGreaterThan(minimumPairDistance, 96)

        for thread in graph.threads {
            guard let threadPosition = simulator.nodesByID[thread.id]?.position else {
                return XCTFail("Missing thread node \(thread.id)")
            }
            let branch = CGVector(dx: threadPosition.x - center.x,
                                  dy: threadPosition.y - center.y)
            for message in graph.messages where message.threadID == thread.id {
                guard let messagePosition = simulator.nodesByID[message.id]?.position else {
                    return XCTFail("Missing message node \(message.id)")
                }
                let messageVector = CGVector(dx: messagePosition.x - center.x,
                                             dy: messagePosition.y - center.y)
                let projection = messageVector.dx * branch.dx + messageVector.dy * branch.dy
                let threadDepth = branch.dx * branch.dx + branch.dy * branch.dy
                XCTAssertGreaterThan(projection, threadDepth,
                                     "Message \(message.id) should remain outward from its thread")
            }
        }
    }

    func test_forceSimulator_resize_translatesPreservedTreeWithoutInjectingVelocity() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 800, height: 600))
        let before = simulator.positionsByID()
        let threadID = GraphData.threadNodeID(for: "root")

        simulator.reset(data: graph,
                        size: CGSize(width: 1_000, height: 600),
                        preserving: before)

        guard let oldPosition = before[threadID],
              let resizedNode = simulator.nodesByID[threadID] else {
            return XCTFail("Missing resized thread")
        }
        assertPointsEqual(resizedNode.position,
                          CGPoint(x: oldPosition.x + 100, y: oldPosition.y))
        XCTAssertEqual(resizedNode.velocity.dx, 0)
        XCTAssertEqual(resizedNode.velocity.dy, 0)
    }

    func test_branchConfig_usesOrganicLimbDefaults() {
        let config = GraphForceConstants.defaults.branchConfig

        XCTAssertEqual(config.trunkWidth, 2.6)
        XCTAssertEqual(config.chainWidth, 1.6)
        XCTAssertEqual(config.taper, 0.6)
        XCTAssertEqual(config.tipMin, 0.5)
        XCTAssertEqual(config.taperPow, 1.8)
        XCTAssertEqual(config.jointRadiusTrunk, 1.8)
        XCTAssertEqual(config.jointRadiusChain, 1.4)
        XCTAssertTrue(config.asymmetricArc)
        XCTAssertTrue(config.outwardArcAnchorEnabled)
        XCTAssertEqual(config.ribbonSamples, 36)
    }

    func test_forceSimulator_withFixedFixture_energyDecreasesAcrossSettlingWindow() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 6)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 800, height: 600))

        for tick in 1...60 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true)
        }

        var sampledEnergies: [CGFloat] = []
        for tick in 61...185 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true)
            if tick.isMultiple(of: 25) {
                sampledEnergies.append(simulator.totalEnergy())
            }
        }

        XCTAssertGreaterThanOrEqual(sampledEnergies.count, 4)
        XCTAssertLessThanOrEqual(sampledEnergies.last ?? .greatestFiniteMagnitude,
                                 sampledEnergies.first ?? 0)
        for (previous, next) in zip(sampledEnergies, sampledEnergies.dropFirst()) {
            XCTAssertLessThanOrEqual(next, max(previous * 1.05, 0.0001))
        }
    }

    func test_forceSimulator_dragUsesPointerOffsetAlignmentBeforeRelease() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 4)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 960, height: 640))
        let threadID = GraphData.threadNodeID(for: "root")
        guard let start = simulator.nodesByID[threadID]?.position else {
            return XCTFail("Missing thread node")
        }
        let pointer = CGPoint(x: 700, y: 500)
        let cursorOffset = CGPoint(x: start.x - pointer.x, y: start.y - pointer.y)
        let dragPointer = CGPoint(x: 760, y: 540)
        let pinnedPosition = CGPoint(x: dragPointer.x + cursorOffset.x, y: dragPointer.y + cursorOffset.y)

        simulator.setPosition(pinnedPosition, for: threadID, pinned: true)
        for tick in 1...4 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true)
        }

        assertPointsEqual(simulator.nodesByID[threadID]?.position, pinnedPosition)
    }

    func test_forceSimulator_releaseNode_keepsDropPointAsNewRestingPosition() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 960, height: 640))
        let threadID = GraphData.threadNodeID(for: "root")
        let dropPoint = CGPoint(x: 710, y: 170)

        simulator.setPosition(dropPoint, for: threadID, pinned: true)
        simulator.releaseNode(at: dropPoint, for: threadID)

        assertPointsEqual(simulator.nodesByID[threadID]?.position, dropPoint)
        assertPointsEqual(simulator.nodesByID[threadID]?.restingPosition, dropPoint)
        XCTAssertFalse(simulator.nodesByID[threadID]?.isPinned ?? true)
    }

    func test_forceSimulator_commitDrag_canMoveBranchBeyondSceneBounds() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        let size = CGSize(width: 800, height: 600)
        simulator.reset(data: graph, size: size)
        let threadID = GraphData.threadNodeID(for: "root")
        guard let startPosition = simulator.nodesByID[threadID]?.position,
              let messageID = simulator.nodesByID[GraphData.messageNodeID(for: "root-msg-1")]?.id else {
            return XCTFail("Missing dragged thread/message")
        }
        let initialPositions = simulator.positionsByID()
        let initialRestingPositions = simulator.restingPositionsByID()
        let requestedDelta = CGVector(dx: 2_000, dy: -1_800)
        let releasePoint = CGPoint(x: startPosition.x + requestedDelta.dx,
                                  y: startPosition.y + requestedDelta.dy)

        let movedNodeIDs = simulator.commitDrag(nodeID: threadID,
                                               from: startPosition,
                                               to: releasePoint,
                                               initialPositions: initialPositions,
                                               initialRestingPositions: initialRestingPositions)
        let branchNodeIDs = simulator.descendantNodeIDs(from: threadID)
        XCTAssertEqual(movedNodeIDs, branchNodeIDs)
        assertPointsEqual(simulator.nodesByID[threadID]?.position, releasePoint)
        assertPointsEqual(simulator.nodesByID[threadID]?.restingPosition, releasePoint)

        guard let movedMessageID = branchNodeIDs.first(where: { $0 == messageID }),
              let messagePosition = simulator.nodesByID[movedMessageID]?.position,
              let messageInitialPosition = initialPositions[movedMessageID] else {
            return XCTFail("Missing moved message")
        }
        XCTAssertEqual(messagePosition.x - messageInitialPosition.x,
                       requestedDelta.dx,
                       accuracy: 0.001)
        XCTAssertEqual(messagePosition.y - messageInitialPosition.y,
                       requestedDelta.dy,
                       accuracy: 0.001)
    }

    func test_forceSimulator_nonDataRebuild_preservesCommittedRestingPositions() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 3)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        let size = CGSize(width: 960, height: 640)
        simulator.reset(data: graph, size: size)
        let threadID = GraphData.threadNodeID(for: "root")
        let initialPositions = simulator.positionsByID()
        let initialRestingPositions = simulator.restingPositionsByID()
        guard let startPosition = initialPositions[threadID] else {
            return XCTFail("Missing dragged thread")
        }
        let releasePosition = CGPoint(x: startPosition.x + 30,
                                      y: startPosition.y - 36)
        let movedNodeIDs = simulator.commitDrag(nodeID: threadID,
                                                from: startPosition,
                                                to: releasePosition,
                                                initialPositions: initialPositions,
                                                initialRestingPositions: initialRestingPositions)
        let committedPositions = simulator.positionsByID()

        simulator.reset(data: graph,
                        size: size,
                        preserving: committedPositions)

        for nodeID in movedNodeIDs {
            assertPointsEqual(simulator.nodesByID[nodeID]?.position,
                              committedPositions[nodeID])
            assertPointsEqual(simulator.nodesByID[nodeID]?.restingPosition,
                              committedPositions[nodeID])
        }
    }

    func test_forceSimulator_previewDrag_movesEntireLogicalBranchAsOneShape() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 4)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 800, height: 600))
        let threadID = GraphData.threadNodeID(for: "root")
        let initialPositions = simulator.positionsByID()
        let branchNodeIDs = simulator.descendantNodeIDs(from: threadID)
        guard let startPosition = initialPositions[threadID] else {
            return XCTFail("Missing dragged thread")
        }
        let requestedDelta = CGVector(dx: 30, dy: -40)
        let dragPoint = CGPoint(x: startPosition.x + requestedDelta.dx,
                                y: startPosition.y + requestedDelta.dy)

        let previewedNodeIDs = simulator.previewDrag(nodeID: threadID,
                                                     from: startPosition,
                                                     to: dragPoint,
                                                     initialPositions: initialPositions)
        simulator.step(deltaTime: 0.016,
                       elapsedTime: 16,
                       reduceMotion: true,
                       scope: .dragging(activeNodeID: threadID,
                                        branchNodeIDs: branchNodeIDs,
                                        obstacleOrigins: initialPositions))

        XCTAssertEqual(previewedNodeIDs, branchNodeIDs)
        assertPointsEqual(simulator.nodesByID[threadID]?.position, dragPoint)
        let appliedDelta = CGVector(dx: (simulator.nodesByID[threadID]?.position.x ?? startPosition.x) - startPosition.x,
                                    dy: (simulator.nodesByID[threadID]?.position.y ?? startPosition.y) - startPosition.y)
        XCTAssertEqual(appliedDelta.dx, requestedDelta.dx, accuracy: 0.001)
        XCTAssertEqual(appliedDelta.dy, requestedDelta.dy, accuracy: 0.001)
        for nodeID in branchNodeIDs {
            guard let initialPosition = initialPositions[nodeID] else {
                return XCTFail("Missing initial branch position for \(nodeID)")
            }
            assertPointsEqual(simulator.nodesByID[nodeID]?.position,
                              CGPoint(x: initialPosition.x + appliedDelta.dx,
                                      y: initialPosition.y + appliedDelta.dy))
        }
        assertPairwiseGeometryPreserved(nodeIDs: branchNodeIDs,
                                        before: initialPositions,
                                        after: simulator.positionsByID())
    }

    func test_forceSimulator_duringScopedDrag_reactsOnlyNearbyObstacleWithinSmallBudget() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root-a", messageCount: 4),
                                           makeThread(rootID: "root-b", messageCount: 2),
                                           makeThread(rootID: "root-c", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 1_000, height: 760))
        simulator.stopMotion()
        let draggedID = GraphData.messageNodeID(for: "root-a-msg-1")
        let nearbyObstacleID = GraphData.threadNodeID(for: "root-b")
        let distantNodeID = GraphData.threadNodeID(for: "root-c")
        guard let startPosition = simulator.nodesByID[draggedID]?.position else {
            return XCTFail("Missing dragged message")
        }
        let delta = CGVector(dx: 120, dy: -24)
        let dragPoint = CGPoint(x: startPosition.x + delta.dx,
                                y: startPosition.y + delta.dy)
        simulator.setPosition(dragPoint, for: nearbyObstacleID)
        simulator.setPosition(CGPoint(x: 80, y: 80), for: distantNodeID)
        let initialPositions = simulator.positionsByID()
        let branchNodeIDs = simulator.descendantNodeIDs(from: draggedID)
        let nearbyStart = initialPositions[nearbyObstacleID]
        let distantStart = initialPositions[distantNodeID]

        simulator.previewDrag(nodeID: draggedID,
                              from: startPosition,
                              to: dragPoint,
                              initialPositions: initialPositions)
        simulator.step(deltaTime: 0.016,
                       elapsedTime: 16,
                       reduceMotion: true,
                       scope: .dragging(activeNodeID: draggedID,
                                        branchNodeIDs: branchNodeIDs,
                                        obstacleOrigins: initialPositions))

        for nodeID in branchNodeIDs {
            guard let initialPosition = initialPositions[nodeID] else { continue }
            assertPointsEqual(simulator.nodesByID[nodeID]?.position,
                              CGPoint(x: initialPosition.x + delta.dx,
                                      y: initialPosition.y + delta.dy),
                              accuracy: 0.001)
        }
        let nearbyDisplacement = pointDistance(nearbyStart, simulator.nodesByID[nearbyObstacleID]?.position)
        XCTAssertGreaterThan(nearbyDisplacement, 0.01)
        XCTAssertLessThanOrEqual(nearbyDisplacement, 1.251)
        XCTAssertLessThan(pointDistance(distantStart, simulator.nodesByID[distantNodeID]?.position), 0.001)
        XCTAssertTrue(simulator.lastDragReactiveNodeIDs.contains(nearbyObstacleID))
    }

    func test_forceSimulator_commitThreadDrag_translatesOnlyThreadBranchAndPreservesGeometry() {
        let graph = GraphData.make(roots: (0..<4).map {
            makeThread(rootID: "root-\($0)", messageCount: 4)
        }, now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 1_000, height: 760))
        simulator.stopMotion()
        let threadID = GraphData.threadNodeID(for: "root-0")
        let initialPositions = simulator.positionsByID()
        let initialRestingPositions = simulator.restingPositionsByID()
        guard let startPosition = initialPositions[threadID] else {
            return XCTFail("Missing dragged thread")
        }
        let delta = CGVector(dx: 30, dy: -36)
        let releasePosition = CGPoint(x: startPosition.x + delta.dx,
                                      y: startPosition.y + delta.dy)

        simulator.setPosition(releasePosition, for: threadID, pinned: true)
        let movedNodeIDs = simulator.commitDrag(nodeID: threadID,
                                                from: startPosition,
                                                to: releasePosition,
                                                initialPositions: initialPositions,
                                                initialRestingPositions: initialRestingPositions)

        let expectedMovedNodeIDs = simulator.descendantNodeIDs(from: threadID)
        XCTAssertEqual(movedNodeIDs, expectedMovedNodeIDs)
        assertPointsEqual(simulator.nodesByID[threadID]?.position, releasePosition)
        for nodeID in simulator.nodesByID.keys where !movedNodeIDs.contains(nodeID) {
            assertPointsEqual(simulator.nodesByID[nodeID]?.position, initialPositions[nodeID], accuracy: 0.0001)
        }
        for nodeID in movedNodeIDs {
            guard let initialPosition = initialPositions[nodeID] else {
                return XCTFail("Missing initial position for \(nodeID)")
            }
            assertPointsEqual(simulator.nodesByID[nodeID]?.position,
                              CGPoint(x: initialPosition.x + delta.dx,
                                      y: initialPosition.y + delta.dy))
        }
        assertPairwiseGeometryPreserved(nodeIDs: movedNodeIDs,
                                        before: initialPositions,
                                        after: simulator.positionsByID())
    }

    func test_forceSimulator_commitGroupDrag_translatesCompleteGroupedBranch() {
        let folder = ThreadFolder(id: "folder-work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: ["root-a", "root-b"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [makeThread(rootID: "root-a", messageCount: 3),
                                           makeThread(rootID: "root-b", messageCount: 3),
                                           makeThread(rootID: "root-c", messageCount: 3)],
                                   folders: [folder],
                                   folderMembershipByThreadID: ["root-a": folder.id, "root-b": folder.id],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 1_000, height: 760))
        simulator.stopMotion()
        guard let groupID = graph.groupings.first(where: { $0.kind == .folder })?.id else {
            return XCTFail("Missing folder group")
        }
        let initialPositions = simulator.positionsByID()
        let initialRestingPositions = simulator.restingPositionsByID()
        guard let startPosition = initialPositions[groupID] else {
            return XCTFail("Missing group node")
        }
        let delta = CGVector(dx: 24, dy: -30)
        let releasePosition = CGPoint(x: startPosition.x + delta.dx,
                                      y: startPosition.y + delta.dy)

        simulator.setPosition(releasePosition, for: groupID, pinned: true)
        let movedNodeIDs = simulator.commitDrag(nodeID: groupID,
                                                from: startPosition,
                                                to: releasePosition,
                                                initialPositions: initialPositions,
                                                initialRestingPositions: initialRestingPositions)

        XCTAssertEqual(movedNodeIDs, simulator.descendantNodeIDs(from: groupID))
        XCTAssertTrue(movedNodeIDs.contains(GraphData.threadNodeID(for: "root-a")))
        XCTAssertTrue(movedNodeIDs.contains(GraphData.threadNodeID(for: "root-b")))
        XCTAssertTrue(movedNodeIDs.contains(GraphData.messageNodeID(for: "root-a-msg-2")))
        XCTAssertFalse(movedNodeIDs.contains(GraphData.threadNodeID(for: "root-c")))
        assertPointsEqual(simulator.nodesByID[GraphData.threadNodeID(for: "root-c")]?.position,
                          initialPositions[GraphData.threadNodeID(for: "root-c")])
        for nodeID in movedNodeIDs {
            guard let initialPosition = initialPositions[nodeID] else {
                return XCTFail("Missing initial position for \(nodeID)")
            }
            assertPointsEqual(simulator.nodesByID[nodeID]?.position,
                              CGPoint(x: initialPosition.x + delta.dx,
                                      y: initialPosition.y + delta.dy))
        }
        assertPairwiseGeometryPreserved(nodeIDs: movedNodeIDs,
                                        before: initialPositions,
                                        after: simulator.positionsByID())
    }

    func test_forceSimulator_commitMessageDrag_translatesOnlyOutwardChain() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 5)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 900, height: 640))
        simulator.stopMotion()
        let messageID = GraphData.messageNodeID(for: "root-msg-2")
        let initialPositions = simulator.positionsByID()
        let initialRestingPositions = simulator.restingPositionsByID()
        guard let startPosition = initialPositions[messageID] else {
            return XCTFail("Missing dragged message")
        }
        let delta = CGVector(dx: 42, dy: -31)
        let releasePosition = CGPoint(x: startPosition.x + delta.dx,
                                      y: startPosition.y + delta.dy)

        simulator.setPosition(releasePosition, for: messageID, pinned: true)
        let movedNodeIDs = simulator.commitDrag(nodeID: messageID,
                                                from: startPosition,
                                                to: releasePosition,
                                                initialPositions: initialPositions,
                                                initialRestingPositions: initialRestingPositions)

        XCTAssertEqual(movedNodeIDs,
                       [GraphData.messageNodeID(for: "root-msg-2"),
                        GraphData.messageNodeID(for: "root-msg-3"),
                        GraphData.messageNodeID(for: "root-msg-4")])
        for nodeID in movedNodeIDs {
            guard let initial = initialPositions[nodeID] else {
                return XCTFail("Missing initial position for \(nodeID)")
            }
            assertPointsEqual(simulator.nodesByID[nodeID]?.position,
                              CGPoint(x: initial.x + delta.dx, y: initial.y + delta.dy))
        }
        let fixedParentID = GraphData.messageNodeID(for: "root-msg-1")
        assertPointsEqual(simulator.nodesByID[fixedParentID]?.position, initialPositions[fixedParentID])
        assertPointsEqual(simulator.nodesByID[GraphData.threadNodeID(for: "root")]?.position,
                          initialPositions[GraphData.threadNodeID(for: "root")])
    }

    func test_forceSimulator_localSettle_keepsCommittedAndUnrelatedBranchesFixed() {
        let graph = GraphData.make(roots: (0..<12).map {
            makeThread(rootID: "root-\($0)", messageCount: 3)
        }, now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 1_200, height: 900))
        for tick in 1...180 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true)
        }
        simulator.stopMotion()
        let threadID = GraphData.threadNodeID(for: "root-0")
        let initialPositions = simulator.positionsByID()
        let initialRestingPositions = simulator.restingPositionsByID()
        guard let startPosition = initialPositions[threadID] else {
            return XCTFail("Missing dragged thread")
        }
        let releasePosition = CGPoint(x: startPosition.x + 30,
                                      y: startPosition.y - 36)
        simulator.setPosition(releasePosition, for: threadID, pinned: true)
        let movedNodeIDs = simulator.commitDrag(nodeID: threadID,
                                                from: startPosition,
                                                to: releasePosition,
                                                initialPositions: initialPositions,
                                                initialRestingPositions: initialRestingPositions)
        let fixedNodeIDs = Set(simulator.nodesByID.keys).subtracting(movedNodeIDs)
        let fixedPositions = simulator.positionsByID()
        let committedPositions = simulator.positionsByID()

        for tick in 1...30 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true,
                           scope: .localSettling(branchNodeIDs: movedNodeIDs,
                                                 returningNodeOrigins: [:]))
        }

        for nodeID in fixedNodeIDs {
            XCTAssertLessThan(pointDistance(fixedPositions[nodeID], simulator.nodesByID[nodeID]?.position),
                              0.01,
                              "Fixed obstacle \(nodeID) moved during local settling")
        }
        for nodeID in movedNodeIDs {
            assertPointsEqual(simulator.nodesByID[nodeID]?.position,
                              committedPositions[nodeID],
                              accuracy: 0.001)
            assertPointsEqual(simulator.nodesByID[nodeID]?.restingPosition,
                              committedPositions[nodeID],
                              accuracy: 0.001)
        }
        XCTAssertLessThanOrEqual(simulator.totalEnergy(for: movedNodeIDs) / CGFloat(max(1, movedNodeIDs.count)),
                                 0.04)
    }

    func test_forceSimulator_localSettle_withoutCollisionDoesNotSpringBackFromCommittedPose() {
        let graph = GraphData.make(roots: (0..<4).map {
            makeThread(rootID: "root-\($0)", messageCount: 4)
        }, now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 1_100, height: 820))
        simulator.stopMotion()
        let threadID = GraphData.threadNodeID(for: "root-0")
        let initialPositions = simulator.positionsByID()
        let initialRestingPositions = simulator.restingPositionsByID()
        guard let startPosition = initialPositions[threadID] else {
            return XCTFail("Missing dragged thread")
        }
        let releasePosition = CGPoint(x: startPosition.x + 30,
                                      y: startPosition.y - 36)
        let movedNodeIDs = simulator.commitDrag(nodeID: threadID,
                                                from: startPosition,
                                                to: releasePosition,
                                                initialPositions: initialPositions,
                                                initialRestingPositions: initialRestingPositions)
        let committedPositions = simulator.positionsByID()

        for tick in 1...12 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true,
                           scope: .localSettling(branchNodeIDs: movedNodeIDs,
                                                 returningNodeOrigins: [:]))
        }

        for nodeID in movedNodeIDs {
            assertPointsEqual(simulator.nodesByID[nodeID]?.position,
                              committedPositions[nodeID],
                              accuracy: 0.001)
        }
        XCTAssertEqual(simulator.totalEnergy(for: movedNodeIDs), 0, accuracy: 0.0001)
    }

    func test_forceSimulator_localSettle_returnsReactiveObstacleMonotonically() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root-a", messageCount: 4),
                                           makeThread(rootID: "root-b", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        let size = CGSize(width: 900, height: 680)
        simulator.reset(data: graph, size: size)
        let draggedID = GraphData.messageNodeID(for: "root-a-msg-1")
        let obstacleID = GraphData.threadNodeID(for: "root-b")
        guard let startPosition = simulator.nodesByID[draggedID]?.position else {
            return XCTFail("Missing dragged message")
        }
        let dragPoint = CGPoint(x: startPosition.x + 20, y: startPosition.y - 20)
        simulator.setPosition(dragPoint, for: obstacleID)
        let initialPositions = simulator.positionsByID()
        let initialRestingPositions = simulator.restingPositionsByID()
        let branchNodeIDs = simulator.descendantNodeIDs(from: draggedID)
        simulator.previewDrag(nodeID: draggedID,
                              from: startPosition,
                              to: dragPoint,
                              initialPositions: initialPositions)
        simulator.step(deltaTime: 0.016,
                       elapsedTime: 16,
                       reduceMotion: true,
                       scope: .dragging(activeNodeID: draggedID,
                                        branchNodeIDs: branchNodeIDs,
                                        obstacleOrigins: initialPositions))
        let reactiveNodeIDs = simulator.lastDragReactiveNodeIDs
        let movedNodeIDs = simulator.commitDrag(nodeID: draggedID,
                                                from: startPosition,
                                                to: dragPoint,
                                                initialPositions: initialPositions,
                                                initialRestingPositions: initialRestingPositions)
        let returningOrigins = Dictionary(uniqueKeysWithValues: reactiveNodeIDs.compactMap { nodeID in
            initialPositions[nodeID].map { (nodeID, $0) }
        })
        var previousDistance = pointDistance(simulator.nodesByID[obstacleID]?.position,
                                             returningOrigins[obstacleID])

        for tick in 1...30 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true,
                           scope: .localSettling(branchNodeIDs: movedNodeIDs,
                                                 returningNodeOrigins: returningOrigins))
            let distance = pointDistance(simulator.nodesByID[obstacleID]?.position,
                                         returningOrigins[obstacleID])
            XCTAssertLessThanOrEqual(distance, previousDistance + 0.0001)
            previousDistance = distance
        }

        XCTAssertLessThan(previousDistance, 0.02)
    }

    func test_forceSimulator_branchDrag_movesWholeBranchBeyondViewportAndPreservesGeometry() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 6)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        let size = CGSize(width: 800, height: 600)
        simulator.reset(data: graph, size: size)
        let threadID = GraphData.threadNodeID(for: "root")
        let branchNodeIDs = simulator.descendantNodeIDs(from: threadID)
        let initialPositions = simulator.positionsByID()
        guard let startPosition = initialPositions[threadID] else {
            return XCTFail("Missing dragged thread")
        }

        let target = CGPoint(x: -2_000, y: 2_000)
        simulator.previewDrag(nodeID: threadID,
                              from: startPosition,
                              to: target,
                              initialPositions: initialPositions)

        let finalPositions = simulator.positionsByID()
        assertPointsEqual(finalPositions[threadID], target)
        assertPairwiseGeometryPreserved(nodeIDs: branchNodeIDs,
                                        before: initialPositions,
                                        after: finalPositions)
        let viewport = CGRect(origin: .zero, size: size)
        XCTAssertTrue(branchNodeIDs.compactMap { finalPositions[$0] }.allSatisfy { !viewport.contains($0) })
    }

    func test_forceSimulator_initialAndSettledLayout_canExtendBeyondViewport() {
        let graph = GraphData.make(roots: (0..<24).map {
            makeThread(rootID: "root-\($0)", messageCount: 6)
        }, now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        let size = CGSize(width: 1_280, height: 900)
        simulator.reset(data: graph, size: size)

        XCTAssertEqual(simulator.nodes.count, 145)
        let viewport = CGRect(origin: .zero, size: size)
        XCTAssertTrue(simulator.nodes.contains { !viewport.contains($0.position) })
        XCTAssertTrue(simulator.nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })

        for tick in 1...240 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true)
        }

        XCTAssertTrue(simulator.nodes.contains { !viewport.contains($0.position) })
        XCTAssertTrue(simulator.nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    func test_forceSimulator_recordedScaleDrag_checksOnlyNearbyCandidates() {
        let graph = GraphData.make(roots: (0..<24).map {
            makeThread(rootID: "root-\($0)", messageCount: 6)
        }, now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 1_280, height: 900))
        simulator.stopMotion()
        XCTAssertEqual(simulator.nodes.count, 145)

        let draggedID = GraphData.messageNodeID(for: "root-0-msg-4")
        let obstacleID = GraphData.threadNodeID(for: "root-1")
        guard let startPosition = simulator.nodesByID[draggedID]?.position else {
            return XCTFail("Missing recorded-scale drag node")
        }
        let target = CGPoint(x: startPosition.x + 20,
                             y: startPosition.y - 20)
        simulator.setPosition(target, for: obstacleID)
        let initialPositions = simulator.positionsByID()
        let branchNodeIDs = simulator.descendantNodeIDs(from: draggedID)
        simulator.previewDrag(nodeID: draggedID,
                              from: startPosition,
                              to: target,
                              initialPositions: initialPositions)

        simulator.step(deltaTime: 0.016,
                       elapsedTime: 16,
                       reduceMotion: true,
                       scope: .dragging(activeNodeID: draggedID,
                                        branchNodeIDs: branchNodeIDs,
                                        obstacleOrigins: initialPositions))

        let exhaustivePairCount = branchNodeIDs.count * (simulator.nodes.count - branchNodeIDs.count)
        XCTAssertGreaterThan(simulator.lastDragCollisionCheckCount, 0)
        XCTAssertLessThan(simulator.lastDragCollisionCheckCount,
                          exhaustivePairCount / 3,
                          "Drag collision work should be spatially bounded, not all-node pairwise")
    }

    func test_forceSimulator_whenLabelRepelIsOff_ignoresLabelProvider() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var baseline = GraphForceSimulator()
        var labeled = GraphForceSimulator()
        baseline.reset(data: graph, size: CGSize(width: 600, height: 420))
        labeled.reset(data: graph, size: CGSize(width: 600, height: 420))
        let config = GraphForceConfig(center: GraphForceConstants.defaults.center,
                                      repel: GraphForceConstants.defaults.repel,
                                      repelCutoff: GraphForceConstants.defaults.repelCutoff,
                                      linkSpring: GraphForceConstants.defaults.linkSpring,
                                      trunkLength: GraphForceConstants.defaults.trunkLength,
                                      chainLength: GraphForceConstants.defaults.chainLength,
                                      damping: GraphForceConstants.defaults.damping,
                                      breezeAmplitude: GraphForceConstants.defaults.breezeAmplitude,
                                      curl: GraphForceConstants.defaults.curl,
                                      curlVariability: GraphForceConstants.defaults.curlVariability,
                                      splineTension: GraphForceConstants.defaults.splineTension,
                                      curlFalloff: GraphForceConstants.defaults.curlFalloff,
                                      labelRepelOn: false,
                                      labelRepelStrength: 0.4)

        baseline.step(deltaTime: 0.016, elapsedTime: 16, reduceMotion: true, config: config)
        labeled.step(deltaTime: 0.016,
                     elapsedTime: 16,
                     reduceMotion: true,
                     config: config,
                     labelOccluderFrame: { node in
                         CGRect(x: node.position.x - 250,
                                y: node.position.y - 250,
                                width: 500,
                                height: 500)
                     })

        for id in graph.allNodeIDs {
            assertPointsEqual(baseline.nodesByID[id]?.position, labeled.nodesByID[id]?.position)
        }
    }
}

final class ObsidianGraphForceSimulatorTests: XCTestCase {
    func test_defaultForces_areRoomierThanBothHistoricalDefaultSets() {
        XCTAssertGreaterThan(ObsidianGraphForceConfig.defaults.repelStrength,
                             ObsidianGraphForceConfig.legacyCompactDefaults.repelStrength)
        XCTAssertGreaterThan(ObsidianGraphForceConfig.defaults.linkDistance,
                             ObsidianGraphForceConfig.legacyCompactDefaults.linkDistance)
        XCTAssertGreaterThan(ObsidianGraphForceConfig.defaults.repelStrength,
                             ObsidianGraphForceConfig.legacyRoomierDefaults.repelStrength)
        XCTAssertGreaterThan(ObsidianGraphForceConfig.defaults.linkDistance,
                             ObsidianGraphForceConfig.legacyRoomierDefaults.linkDistance)
    }

    func test_forceMigration_updatesHistoricalDefaultsButPreservesCustomization() {
        XCTAssertEqual(ObsidianGraphForceConfig.migratingHistoricalDefaults(.legacyCompactDefaults),
                       .defaults)
        XCTAssertEqual(ObsidianGraphForceConfig.migratingHistoricalDefaults(.legacyRoomierDefaults),
                       .defaults)

        var customized = ObsidianGraphForceConfig.legacyRoomierDefaults
        customized.linkDistance += 1
        XCTAssertEqual(ObsidianGraphForceConfig.migratingHistoricalDefaults(customized), customized)
    }

    func test_expandedSpacingMigration_raisesOnlyCompactSpacingDimensions() {
        let compactCustom = ObsidianGraphForceConfig(centerStrength: 0.0025,
                                                     repelStrength: 2_800,
                                                     linkStrength: 0.05,
                                                     linkDistance: 78,
                                                     damping: 0.84)
        let migrated = ObsidianGraphForceConfig.migratingToExpandedSpacing(compactCustom)

        XCTAssertEqual(migrated.centerStrength, compactCustom.centerStrength)
        XCTAssertEqual(migrated.linkStrength, compactCustom.linkStrength)
        XCTAssertEqual(migrated.damping, compactCustom.damping)
        XCTAssertEqual(migrated.repelStrength, ObsidianGraphForceConfig.defaults.repelStrength)
        XCTAssertEqual(migrated.linkDistance, ObsidianGraphForceConfig.defaults.linkDistance)
    }

    func test_reset_centersMovableYouNodeAndCreatesFiniteDeterministicLayout() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root-a", messageCount: 3),
                                           makeThread(rootID: "root-b", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var first = ObsidianGraphForceSimulator()
        var second = ObsidianGraphForceSimulator()
        let size = CGSize(width: 800, height: 520)

        first.reset(data: graph, size: size)
        second.reset(data: graph, size: size)

        assertPointsEqual(first.nodesByID[GraphCenter.you.id]?.position,
                          CGPoint(x: 400, y: 260))
        XCTAssertFalse(first.nodesByID[GraphCenter.you.id]?.isPinned ?? true)
        XCTAssertEqual(first.positionsByID(), second.positionsByID())
        XCTAssertTrue(first.nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    func test_resetAndSettling_placeNewerThreadsFartherFromGraphCenter() throws {
        let oldestDate = Date(timeIntervalSince1970: 1_000)
        let newestDate = Date(timeIntervalSince1970: 9_000)
        let graph = GraphData.make(roots: [
            makeThread(rootID: "newest", messageCount: 1, rootDate: newestDate),
            makeThread(rootID: "oldest", messageCount: 1, rootDate: oldestDate)
        ], now: Date(timeIntervalSince1970: 10_000))
        let oldestID = GraphData.threadNodeID(for: "oldest")
        let newestID = GraphData.threadNodeID(for: "newest")
        var simulator = ObsidianGraphForceSimulator()

        simulator.reset(data: graph, size: CGSize(width: 900, height: 620))

        XCTAssertEqual(simulator.nodesByID[oldestID]?.chronologyRank, 0)
        XCTAssertEqual(simulator.nodesByID[newestID]?.chronologyRank, 1)
        XCTAssertGreaterThan(pointDistance(simulator.nodesByID[GraphCenter.you.id]?.position,
                                           simulator.nodesByID[newestID]?.position),
                             pointDistance(simulator.nodesByID[GraphCenter.you.id]?.position,
                                           simulator.nodesByID[oldestID]?.position))

        for _ in 0..<240 {
            simulator.step(deltaTime: 1.0 / 60.0,
                           reduceMotion: false,
                           config: .defaults)
        }

        XCTAssertGreaterThan(pointDistance(simulator.nodesByID[GraphCenter.you.id]?.position,
                                           simulator.nodesByID[newestID]?.position),
                             pointDistance(simulator.nodesByID[GraphCenter.you.id]?.position,
                                           simulator.nodesByID[oldestID]?.position))
    }

    func test_repelForce_pushesFolderCorpusBeyondNormalRepulsionRange() throws {
        let folder = ThreadFolder(id: "folder-work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: ["grouped-a", "grouped-b"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [makeThread(rootID: "grouped-a", messageCount: 2),
                                           makeThread(rootID: "grouped-b", messageCount: 2),
                                           makeThread(rootID: "ungrouped", messageCount: 2)],
                                   folders: [folder],
                                   folderMembershipByThreadID: ["grouped-a": folder.id,
                                                                "grouped-b": folder.id],
                                   now: Date(timeIntervalSince1970: 10_000))
        let groupedAID = GraphData.messageNodeID(for: "grouped-a-msg-1")
        let groupedBID = GraphData.messageNodeID(for: "grouped-b-msg-1")
        let ungroupedID = GraphData.messageNodeID(for: "ungrouped-msg-1")
        let groupedAStart = CGPoint(x: 1_000, y: 1_000)
        var preservedPositions = Dictionary(uniqueKeysWithValues: graph.allNodeIDs.sorted().enumerated().map {
            ($0.element, CGPoint(x: 10_000 + CGFloat($0.offset) * 2_000, y: 10_000))
        })
        preservedPositions[groupedAID] = groupedAStart
        preservedPositions[groupedBID] = CGPoint(x: 1_000, y: 1_600)
        preservedPositions[ungroupedID] = CGPoint(x: 1_600, y: 1_000)
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph,
                        size: CGSize(width: 100_000, height: 20_000),
                        preserving: preservedPositions)
        let config = ObsidianGraphForceConfig(centerStrength: 0,
                                              repelStrength: 2_400,
                                              linkStrength: 0,
                                              linkDistance: 92,
                                              damping: 1)

        simulator.step(deltaTime: 1.0 / 60.0,
                       reduceMotion: false,
                       config: config)

        let groupedAAfter = try XCTUnwrap(simulator.nodesByID[groupedAID]?.position)
        XCTAssertEqual(simulator.nodesByID[groupedAID]?.branchID, folder.id)
        XCTAssertNil(simulator.nodesByID[ungroupedID]?.branchID)
        XCTAssertLessThan(groupedAAfter.x, groupedAStart.x - 0.001)
        XCTAssertEqual(groupedAAfter.y, groupedAStart.y, accuracy: 0.0001)
    }

    func test_linkForce_movesSeparatedNodesTowardConfiguredDistance() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 1)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let threadID = GraphData.threadNodeID(for: "root")
        let size = CGSize(width: 600, height: 400)
        let center = CGPoint(x: 300, y: 200)
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph,
                        size: size,
                        preserving: [GraphCenter.you.id: center,
                                     threadID: CGPoint(x: 560, y: 200)])
        let before = pointDistance(simulator.nodesByID[GraphCenter.you.id]?.position,
                                   simulator.nodesByID[threadID]?.position)
        let config = ObsidianGraphForceConfig(centerStrength: 0,
                                              repelStrength: 0,
                                              linkStrength: 0.06,
                                              linkDistance: 80,
                                              damping: 0.82)

        for _ in 0..<90 {
            simulator.step(deltaTime: 1.0 / 60.0, reduceMotion: false, config: config)
        }

        let after = pointDistance(simulator.nodesByID[GraphCenter.you.id]?.position,
                                  simulator.nodesByID[threadID]?.position)
        XCTAssertLessThan(after, before)
        XCTAssertLessThan(abs(after - config.linkDistance * 1.25),
                          abs(before - config.linkDistance * 1.25))
        XCTAssertTrue(simulator.totalEnergy().isFinite)
    }

    func test_drag_movesOnlyPinnedNodeBeforeNeighborsReact() throws {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 3)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let threadID = GraphData.threadNodeID(for: "root")
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 700, height: 480))
        let before = simulator.positionsByID()
        let start = try XCTUnwrap(before[threadID])
        let target = CGPoint(x: start.x + 120, y: start.y - 40)

        simulator.beginDragging(nodeID: threadID)
        simulator.drag(nodeID: threadID, to: target)

        assertPointsEqual(simulator.nodesByID[threadID]?.position, target)
        for messageID in graph.messages.map(\.id) {
            assertPointsEqual(simulator.nodesByID[messageID]?.position, before[messageID])
        }
        simulator.endDragging(nodeID: threadID, at: target)
        XCTAssertFalse(simulator.nodesByID[threadID]?.isPinned ?? true)
    }

    func test_drag_keepingFolderStationary_pinsTargetUntilRelease() throws {
        let folder = ThreadFolder(id: "folder-meetings",
                                  title: "Meetings",
                                  color: .defaultNewFolder,
                                  threadIDs: ["foldered-thread"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [
            makeThread(rootID: "foldered-thread", messageCount: 1),
            makeThread(rootID: "unfiled-thread", messageCount: 1)
        ],
        folders: [folder],
        folderMembershipByThreadID: ["foldered-thread": folder.id],
        now: Date(timeIntervalSince1970: 10_000))
        let grouping = try XCTUnwrap(graph.groupings.first { $0.sourceFolderID == folder.id })
        let draggedNodeID = GraphData.threadNodeID(for: "unfiled-thread")
        let folderStart = CGPoint(x: 1_000, y: 1_000)
        let dragTarget = CGPoint(x: 1_018, y: 1_000)
        var preservedPositions = Dictionary(uniqueKeysWithValues: graph.allNodeIDs.sorted().enumerated().map {
            ($0.element, CGPoint(x: 10_000 + CGFloat($0.offset) * 2_000, y: 10_000))
        })
        preservedPositions[grouping.id] = folderStart
        preservedPositions[draggedNodeID] = CGPoint(x: 1_080, y: 1_000)
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph,
                        size: CGSize(width: 100_000, height: 20_000),
                        preserving: preservedPositions)

        simulator.beginDragging(nodeID: draggedNodeID,
                                keepingStationary: [grouping.id])
        simulator.drag(nodeID: draggedNodeID, to: dragTarget)
        for _ in 0..<30 {
            simulator.step(deltaTime: 1.0 / 60.0,
                           reduceMotion: false,
                           config: .defaults)
        }

        assertPointsEqual(simulator.nodesByID[grouping.id]?.position, folderStart)
        assertPointsEqual(simulator.nodesByID[draggedNodeID]?.position, dragTarget)
        XCTAssertTrue(simulator.nodesByID[grouping.id]?.isPinned ?? false)
        XCTAssertTrue(simulator.nodesByID[draggedNodeID]?.isPinned ?? false)

        simulator.endDragging(nodeID: draggedNodeID, at: dragTarget)

        XCTAssertFalse(simulator.nodesByID[grouping.id]?.isPinned ?? true)
        XCTAssertFalse(simulator.nodesByID[draggedNodeID]?.isPinned ?? true)
    }

    func test_drag_youNode_movesAndReleasesLikeAnyOtherNode() throws {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 1)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let youID = GraphCenter.you.id
        let threadID = GraphData.threadNodeID(for: "root")
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 700, height: 480))
        let threadStart = try XCTUnwrap(simulator.nodesByID[threadID]?.position)
        let target = CGPoint(x: 190, y: 150)
        let config = ObsidianGraphForceConfig(centerStrength: 0,
                                              repelStrength: 0,
                                              linkStrength: 0.08,
                                              linkDistance: 80,
                                              damping: 0.82)

        simulator.beginDragging(nodeID: youID)
        simulator.drag(nodeID: youID, to: target)
        XCTAssertTrue(simulator.nodesByID[youID]?.isPinned ?? false)

        for _ in 0..<5 {
            simulator.step(deltaTime: 1.0 / 60.0, reduceMotion: false, config: config)
        }

        assertPointsEqual(simulator.nodesByID[youID]?.position, target)
        XCTAssertGreaterThan(pointDistance(threadStart,
                                           simulator.nodesByID[threadID]?.position),
                             0.001)

        simulator.endDragging(nodeID: youID, at: target)

        assertPointsEqual(simulator.nodesByID[youID]?.position, target)
        XCTAssertFalse(simulator.nodesByID[youID]?.isPinned ?? true)

        simulator.reset(data: graph,
                        size: CGSize(width: 700, height: 480),
                        preserving: simulator.positionsByID(),
                        config: config)

        assertPointsEqual(simulator.nodesByID[youID]?.position, target)
        XCTAssertFalse(simulator.nodesByID[youID]?.isPinned ?? true)
    }

    func test_reset_preservesExistingNodePositions() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = ObsidianGraphForceSimulator()
        let size = CGSize(width: 700, height: 480)
        simulator.reset(data: graph, size: size)
        for _ in 0..<10 {
            simulator.step(deltaTime: 1.0 / 60.0,
                           reduceMotion: false,
                           config: .defaults)
        }
        let positions = simulator.positionsByID()

        simulator.reset(data: graph, size: size, preserving: positions)

        for id in graph.allNodeIDs {
            assertPointsEqual(simulator.nodesByID[id]?.position, positions[id])
        }
    }

    func test_labelAlpha_increasesWithZoomAndCanBeShiftedByThreshold() {
        let far = ObsidianGraphSceneNode.labelAlpha(zoomScale: 0.2, threshold: -0.4)
        let normal = ObsidianGraphSceneNode.labelAlpha(zoomScale: 1, threshold: -0.4)
        let earlierFade = ObsidianGraphSceneNode.labelAlpha(zoomScale: 0.5, threshold: -1.2)
        let laterFade = ObsidianGraphSceneNode.labelAlpha(zoomScale: 0.5, threshold: 0.2)

        XCTAssertLessThan(far, normal)
        XCTAssertGreaterThan(earlierFade, laterFade)
        XCTAssertGreaterThanOrEqual(far, 0)
        XCTAssertLessThanOrEqual(normal, 1)
    }
}

final class GraphTitleFormatterTests: XCTestCase {
    func test_normalizedGeneratedTitle_removesResponseDecorationAndExtraLines() {
        let title = GraphTitleFormatter.normalizedGeneratedTitle(
            "Title: Re: CR#60 Booking Flow Review.\nThis line must not appear.",
            fallback: "Original subject"
        )

        XCTAssertEqual(title, "CR#60 Booking Flow Review")
    }

    func test_normalizedGeneratedTitle_enforcesOneLineCharacterLimit() {
        let title = GraphTitleFormatter.normalizedGeneratedTitle(
            "Booking Flow Walkthrough Review Materials and Prioritization Discussion",
            fallback: "Original subject"
        )

        XCTAssertLessThanOrEqual(title.count, GraphTitleFormatter.maximumCharacterCount)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.contains("\n"))
    }

    func test_normalizedGeneratedTitle_enforcesWordLimitAndPreservesTrailingIdentifier() {
        let title = GraphTitleFormatter.normalizedGeneratedTitle(
            "HKJC CRC - Review Materials For CR#60",
            fallback: "Original subject"
        )

        XCTAssertEqual(title, "HKJC CRC Review Materials CR#60")
        XCTAssertLessThanOrEqual(title.split(whereSeparator: \.isWhitespace).count,
                                 GraphTitleFormatter.maximumWordCount)
        XCTAssertLessThanOrEqual(title.count, GraphTitleFormatter.maximumCharacterCount)
    }

    func test_normalizedGeneratedTitle_usesCleanedSubjectWhenModelReturnsEmptyText() {
        let title = GraphTitleFormatter.normalizedGeneratedTitle("   ", fallback: "Re: HKJC CRC Review")

        XCTAssertEqual(title, "HKJC CRC Review")
    }
}

final class GraphTitleGenerationTests: XCTestCase {
    @MainActor
    func test_viewModel_generatesAndCachesConciseGraphTitle() async throws {
        let suiteName = "GraphTitleGenerationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestGraphTitleProvider(title: "CR60 Booking Flow")
        let capability = GraphTitleCapability(provider: provider,
                                              statusMessage: "Ready",
                                              providerID: "test-graph-title-v1",
                                              shouldRetry: false)
        let viewModel = GraphCanvasViewModel(store: store,
                                             graphTitleCapabilityProvider: { capability })
        viewModel.setGraphTitleGenerationActive(true)
        let summary = ThreadSummaryState(
            text: "Confirm the CR#60 booking-flow walkthrough scope and review materials.",
            statusMessage: "Ready",
            isSummarizing: false
        )

        viewModel.update(roots: [makeThread(rootID: "root", messageCount: 1)],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: ["root": summary])

        var generatedTitle: String?
        for _ in 0..<150 {
            generatedTitle = viewModel.data.threads.first?.displayTitle
            if generatedTitle == "CR60 Booking Flow" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(generatedTitle, "CR60 Booking Flow")
        XCTAssertEqual(viewModel.generatedGraphTitle(for: "root"), "CR60 Booking Flow")
        let firstCallCount = await provider.callCount
        XCTAssertEqual(firstCallCount, 1)

        let cached = try await store.fetchSummaries(scope: .graphTitle, ids: ["root"])
        XCTAssertEqual(cached.first?.summaryText, "CR60 Booking Flow")
        XCTAssertEqual(cached.first?.provider, "test-graph-title-v1")

        viewModel.update(roots: [makeThread(rootID: "root", messageCount: 1)],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: ["root": summary])
        try await Task.sleep(for: .milliseconds(100))
        let finalCallCount = await provider.callCount
        XCTAssertEqual(finalCallCount, 1)
    }

    @MainActor
    func test_viewModel_regenerateGraphTitle_bypassesMatchingCachedTitle() async throws {
        let suiteName = "GraphTitleGenerationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = SequentialGraphTitleProvider(titles: [
            "HKJC CRC Review Materials CR#60",
            "HKJC CRC Booking Review CR#60"
        ])
        let capability = GraphTitleCapability(provider: provider,
                                              statusMessage: "Ready",
                                              providerID: "test-graph-title-v1",
                                              shouldRetry: false)
        let viewModel = GraphCanvasViewModel(store: store,
                                             graphTitleCapabilityProvider: { capability })
        viewModel.setGraphTitleGenerationActive(true)
        let summary = ThreadSummaryState(text: "Confirm the CR#60 booking-flow walkthrough scope and review materials.",
                                         statusMessage: "Ready",
                                         isSummarizing: false)

        viewModel.update(roots: [makeThread(rootID: "root", messageCount: 1)],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: ["root": summary])
        for _ in 0..<150 {
            if viewModel.generatedGraphTitle(for: "root") == "HKJC CRC Review Materials CR#60" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(viewModel.generatedGraphTitle(for: "root"), "HKJC CRC Review Materials CR#60")

        viewModel.regenerateGraphTitle(for: "root")
        for _ in 0..<150 {
            if viewModel.generatedGraphTitle(for: "root") == "HKJC CRC Booking Review CR#60" { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(viewModel.generatedGraphTitle(for: "root"), "HKJC CRC Booking Review CR#60")
        let regenerationCallCount = await provider.callCount
        XCTAssertEqual(regenerationCallCount, 2)
        let cached = try await store.fetchSummaries(scope: .graphTitle, ids: ["root"])
        XCTAssertEqual(cached.first?.summaryText, "HKJC CRC Booking Review CR#60")
    }

    @MainActor
    func test_viewModel_regenerateGraphTitle_withoutSummary_isNoOp() async throws {
        let suiteName = "GraphTitleGenerationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestGraphTitleProvider(title: "Unused title")
        let capability = GraphTitleCapability(provider: provider,
                                              statusMessage: "Ready",
                                              providerID: "test-graph-title-v1",
                                              shouldRetry: false)
        let viewModel = GraphCanvasViewModel(store: store,
                                             graphTitleCapabilityProvider: { capability })
        viewModel.setGraphTitleGenerationActive(true)
        viewModel.update(roots: [makeThread(rootID: "root", messageCount: 1)],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: [:])

        viewModel.regenerateGraphTitle(for: "root")
        try await Task.sleep(for: .milliseconds(100))

        let noOpCallCount = await provider.callCount
        XCTAssertEqual(noOpCallCount, 0)
        XCTAssertFalse(viewModel.canRegenerateGraphTitle(for: "root"))
    }

    @MainActor
    func test_viewModel_regenerateGraphTitle_replacesAnInFlightTitleRequest() async throws {
        let suiteName = "GraphTitleGenerationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = SequentialGraphTitleProvider(titles: [
            "Initial title CR#60",
            "Regenerated title CR#60"
        ], delayFirstTitle: .seconds(5))
        let capability = GraphTitleCapability(provider: provider,
                                              statusMessage: "Ready",
                                              providerID: "test-graph-title-v1",
                                              shouldRetry: false)
        let viewModel = GraphCanvasViewModel(store: store,
                                             graphTitleCapabilityProvider: { capability })
        viewModel.setGraphTitleGenerationActive(true)
        let summary = ThreadSummaryState(text: "Confirm the CR#60 booking-flow walkthrough scope and review materials.",
                                         statusMessage: "Ready",
                                         isSummarizing: false)

        viewModel.update(roots: [makeThread(rootID: "root", messageCount: 1)],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: ["root": summary])
        for _ in 0..<150 {
            if await provider.callCount == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let initialCallCount = await provider.callCount
        XCTAssertEqual(initialCallCount, 1)

        viewModel.regenerateGraphTitle(for: "root")
        for _ in 0..<150 {
            if viewModel.generatedGraphTitle(for: "root") == "Regenerated title CR#60" { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(viewModel.generatedGraphTitle(for: "root"), "Regenerated title CR#60")
        XCTAssertFalse(viewModel.isRegeneratingGraphTitle(for: "root"))
        let regenerationCallCount = await provider.callCount
        XCTAssertEqual(regenerationCallCount, 2)
    }

    @MainActor
    func test_viewModel_withoutSummary_doesNotGenerateTitleFromSubjectAlone() async throws {
        let suiteName = "GraphTitleGenerationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestGraphTitleProvider(title: "Generated Subject Label")
        let capability = GraphTitleCapability(provider: provider,
                                              statusMessage: "Ready",
                                              providerID: "test-graph-title-v1",
                                              shouldRetry: false)
        let viewModel = GraphCanvasViewModel(store: store,
                                             graphTitleCapabilityProvider: { capability })
        viewModel.setGraphTitleGenerationActive(true)

        viewModel.update(roots: [makeThread(rootID: "root", messageCount: 1)],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: [:])
        try await Task.sleep(for: .milliseconds(100))

        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(viewModel.data.threads.first?.displayTitle, "Subject root")
    }

    @MainActor
    func test_viewModel_whenGraphDisappears_cancelsInFlightTitleGeneration() async throws {
        let suiteName = "GraphTitleGenerationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestGraphTitleProvider(title: "Late Generated Label",
                                              delay: .seconds(5))
        let capability = GraphTitleCapability(provider: provider,
                                              statusMessage: "Ready",
                                              providerID: "test-graph-title-v1",
                                              shouldRetry: false)
        let viewModel = GraphCanvasViewModel(store: store,
                                             graphTitleCapabilityProvider: { capability })
        viewModel.setGraphTitleGenerationActive(true)
        let summary = ThreadSummaryState(text: "A summary used for the graph label.",
                                         statusMessage: "Ready",
                                         isSummarizing: false)

        viewModel.update(roots: [makeThread(rootID: "root", messageCount: 1)],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: ["root": summary])
        var attempts = 0
        while await provider.callCount == 0, attempts < 50 {
            try await Task.sleep(for: .milliseconds(20))
            attempts += 1
        }
        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 1)

        viewModel.setGraphTitleGenerationActive(false)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(viewModel.data.threads.first?.displayTitle, summary.text)
        let cached = try await store.fetchSummaries(scope: .graphTitle, ids: ["root"])
        XCTAssertTrue(cached.isEmpty)
    }
}

final class GraphTopicGenerationTests: XCTestCase {
    @MainActor
    func test_viewModel_generatesOneWholeConversationSignalPerThreadAndReusesCache() async throws {
        let suiteName = "GraphTopicGenerationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestGraphTopicProvider(signal: makeTopicSignal(
            "CR60 booking rollout",
            confidence: 0.90,
            reason: "Both conversations cover the CR60 booking rollout scope."
        ))
        let capability = GraphTopicCapability(provider: provider,
                                              statusMessage: "Ready",
                                              providerID: "test-graph-topic-v1",
                                              shouldRetry: false)
        let roots = [makeThread(rootID: "root-a", messageCount: 3),
                     makeThread(rootID: "root-b", messageCount: 3)]
        let summaries = [
            "root-a": ThreadSummaryState(text: "CR60 rollout scope and booking sequence.",
                                         statusMessage: "Ready",
                                         isSummarizing: false),
            "root-b": ThreadSummaryState(text: "CR60 booking rollout owner and timing.",
                                         statusMessage: "Ready",
                                         isSummarizing: false)
        ]

        let firstViewModel = GraphCanvasViewModel(
            store: store,
            graphTopicCapabilityProvider: { capability }
        )
        firstViewModel.setGraphEnrichmentActive(true)
        firstViewModel.update(roots: roots,
                              searchQuery: "",
                              tagsByNodeID: [:],
                              summariesByNodeID: summaries,
                              branchPageSize: 4)

        for _ in 0..<150 {
            if firstViewModel.data.groupings.contains(where: \.isSuggestion) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let firstSuggestion = try XCTUnwrap(
            firstViewModel.data.groupings.first(where: \.isSuggestion)
        )
        XCTAssertEqual(Set(firstSuggestion.rawThreadIDs), ["root-a", "root-b"])
        XCTAssertEqual(firstSuggestion.reviewMembers.count, 2)
        XCTAssertEqual(firstSuggestion.threadIDs.count, 2)
        let generatedCallCount = await provider.callCount
        XCTAssertEqual(generatedCallCount, 2)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { !$0.threadSummary.isEmpty })
        XCTAssertTrue(requests.allSatisfy { $0.representativeContent.contains("Content:") })

        let cached = try await store.fetchSummaries(scope: .graphTopic,
                                                    ids: ["root-a", "root-b"])
        XCTAssertEqual(cached.count, 2)
        XCTAssertTrue(cached.allSatisfy { $0.provider == "test-graph-topic-v1" })
        firstViewModel.setGraphEnrichmentActive(false)

        let cachedViewModel = GraphCanvasViewModel(
            store: store,
            graphTopicCapabilityProvider: { capability }
        )
        cachedViewModel.setGraphEnrichmentActive(true)
        cachedViewModel.update(roots: roots,
                               searchQuery: "",
                               tagsByNodeID: [:],
                               summariesByNodeID: summaries,
                               branchPageSize: 4)
        for _ in 0..<150 {
            if cachedViewModel.data.groupings.contains(where: \.isSuggestion) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(cachedViewModel.data.groupings.contains(where: \.isSuggestion))
        let cachedCallCount = await provider.callCount
        XCTAssertEqual(cachedCallCount, 2,
                       "Matching whole-conversation fingerprints should reuse the dedicated cache")
        cachedViewModel.setGraphEnrichmentActive(false)
    }

    @MainActor
    func test_viewModel_whenGraphDisappears_cancelsInFlightTopicGeneration() async throws {
        let suiteName = "GraphTopicGenerationCancellationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestGraphTopicProvider(
            signal: makeTopicSignal("CR60 booking rollout", confidence: 0.90),
            delay: .seconds(5)
        )
        let capability = GraphTopicCapability(provider: provider,
                                              statusMessage: "Ready",
                                              providerID: "test-graph-topic-cancel-v1",
                                              shouldRetry: false)
        let viewModel = GraphCanvasViewModel(
            store: store,
            graphTopicCapabilityProvider: { capability }
        )
        viewModel.setGraphEnrichmentActive(true)
        viewModel.update(roots: [makeThread(rootID: "root-a", messageCount: 2),
                                 makeThread(rootID: "root-b", messageCount: 2)],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: [:])

        var attempts = 0
        while await provider.callCount == 0, attempts < 50 {
            try await Task.sleep(for: .milliseconds(20))
            attempts += 1
        }
        let startedCallCount = await provider.callCount
        XCTAssertEqual(startedCallCount, 1)

        viewModel.setGraphEnrichmentActive(false)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(viewModel.data.groupings.contains(where: \.isSuggestion))
        let cached = try await store.fetchSummaries(scope: .graphTopic,
                                                    ids: ["root-a", "root-b"])
        XCTAssertTrue(cached.isEmpty)
    }
}

final class ObsidianGraphSceneTests: XCTestCase {
    func test_remainingNodeActivation_invokesOwningParentExactlyOnce() throws {
        let groupedIDs = ["grouped-0", "grouped-1", "grouped-2"]
        let folder = ThreadFolder(id: "folder-paged",
                                  title: "Paged Topic",
                                  color: .defaultNewFolder,
                                  threadIDs: Set(groupedIDs),
                                  parentID: nil)
        let graph = GraphData.make(
            roots: (groupedIDs + ["unhandled-0", "unhandled-1"]).map {
                makeThread(rootID: $0, messageCount: 1)
            },
            folders: [folder],
            folderMembershipByThreadID: Dictionary(uniqueKeysWithValues: groupedIDs.map { ($0, folder.id) }),
            branchLimit: 2,
            branchBatchSize: 2,
            perNodeBranchPageSize: 2,
            now: Date(timeIntervalSince1970: 10_000)
        )
        let childParentID = "folder:\(folder.id)"
        let childRemainderID = GraphRemainingBranch.graphID(for: childParentID)
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        var expandedParentIDs: [String] = []
        scene.onExpandRemainingBranches = { expandedParentIDs.append($0) }

        let remainingNodes = scene.children.compactMap { $0 as? ObsidianGraphSceneNode }
            .filter { $0.kind == .remaining }
        XCTAssertEqual(remainingNodes.count, 2)
        let childRemainderNode = try XCTUnwrap(remainingNodes.first { $0.graphID == childRemainderID })
        let childRemainder = try XCTUnwrap(graph.remainingBranchByID[childRemainderID])
        XCTAssertEqual(childRemainderNode.accessibilityRole, NSAccessibility.Role.button.rawValue)
        XCTAssertEqual(childRemainderNode.accessibilityLabel, childRemainder.accessibilityLabel)
        XCTAssertTrue(childRemainderNode.accessibilityPerformPress())
        XCTAssertEqual(expandedParentIDs, [childParentID])
        expandedParentIDs.removeAll()

        XCTAssertTrue(scene.expandRemainingBranchIfPresent(nodeID: GraphRemainingBranch.graphID))
        XCTAssertTrue(scene.expandRemainingBranchIfPresent(nodeID: childRemainderID))
        XCTAssertFalse(scene.expandRemainingBranchIfPresent(nodeID: GraphData.threadNodeID(for: "unhandled-0")))
        XCTAssertEqual(expandedParentIDs, [GraphCenter.you.id, childParentID])
    }

    func test_hitTest_whenPointerIsOnLabel_selectsOnlyTheNodeShape() throws {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 1)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let threadID = GraphData.threadNodeID(for: "root")
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        let sceneNode = try XCTUnwrap(scene.children.compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == threadID })
        let label = try XCTUnwrap(sceneNode.children.compactMap { $0 as? SKLabelNode }.first)
        let labelPoint = sceneNode.convert(CGPoint(x: label.frame.maxX - 1,
                                                   y: label.frame.midY),
                                           to: scene)

        XCTAssertEqual(scene.hitTestNodeID(at: sceneNode.position), threadID)
        XCTAssertNil(scene.hitTestNodeID(at: labelPoint))
    }

    func test_labelNode_withLongTitle_preservesFullText() throws {
        let title = Array(repeating: "Confirm the booking flow owner and rollout sequence", count: 5)
            .joined(separator: " ")
        let node = ObsidianGraphSceneNode(
            graphID: "thread:long-summary",
            kind: .thread,
            threadID: "long-summary",
            radius: 14,
            title: title,
            fillColor: .white,
            strokeColor: .gray,
            textScale: 1,
            theme: DesignTokens.Graph.AppTheme.Palette(isDark: false)
        )
        let label = try XCTUnwrap(node.children.compactMap { $0 as? SKLabelNode }.first)

        XCTAssertEqual(label.text, title)
        XCTAssertGreaterThan(label.frame.width, 214)
        XCTAssertFalse(label.text?.contains("\n") == true)
    }

    func test_actionItemContextMenu_whenThreadNodeIsActionItem_selectsAndTogglesNode() throws {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 1)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let threadID = GraphData.threadNodeID(for: "root")
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        var selectedNodeID: String?
        var selectedAdditively = true
        var toggledNodeID: String?
        scene.onSelectGraphNode = { graphNodeID, isAdditive in
            selectedNodeID = graphNodeID
            selectedAdditively = isAdditive
        }
        scene.isActionItem = { $0 == threadID }
        scene.onToggleActionItem = { toggledNodeID = $0 }

        let menu = try XCTUnwrap(scene.actionItemContextMenu(forGraphNodeID: threadID))
        let item = try XCTUnwrap(menu.items.first)
        let action = try XCTUnwrap(item.representedObject as? GraphContextMenuAction)

        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(selectedNodeID, threadID)
        XCTAssertFalse(selectedAdditively)
        XCTAssertEqual(item.title,
                       NSLocalizedString("graph.actions.remove_action_item",
                                         comment: "Remove selected graph email from action items"))
        action.perform(item)
        XCTAssertEqual(toggledNodeID, threadID)
    }

    func test_actionItemContextMenu_whenNodeIsNotActionable_returnsNil() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 1)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        scene.onToggleActionItem = { _ in }

        XCTAssertNil(scene.actionItemContextMenu(forGraphNodeID: GraphCenter.you.id))
    }

    func test_folderDropTarget_threadOverConfirmedFolder_returnsPersistedIDs() throws {
        let folder = ThreadFolder(id: "folder-meetings",
                                  title: "Meetings",
                                  color: .defaultNewFolder,
                                  threadIDs: ["foldered-thread"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [
            makeThread(rootID: "foldered-thread", messageCount: 1),
            makeThread(rootID: "unfiled-thread", messageCount: 1)
        ],
        folders: [folder],
        folderMembershipByThreadID: ["foldered-thread": folder.id],
        now: Date(timeIntervalSince1970: 10_000))
        let grouping = try XCTUnwrap(graph.groupings.first { $0.sourceFolderID == folder.id })
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        let folderNode = try XCTUnwrap(scene.children.compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == grouping.id })

        let target = try XCTUnwrap(scene.folderDropTarget(
            at: folderNode.position,
            draggedGraphNodeID: GraphData.threadNodeID(for: "unfiled-thread")
        ))

        XCTAssertEqual(target.graphNodeID, grouping.id)
        XCTAssertEqual(target.rawThreadID, "unfiled-thread")
        XCTAssertEqual(target.folderID, folder.id)
        XCTAssertEqual(
            scene.stationaryFolderDropNodeIDs(
                forDraggedGraphNodeID: GraphData.threadNodeID(for: "unfiled-thread")
            ),
            [grouping.id]
        )
    }

    func test_folderDropTarget_nearConfirmedFolder_usesZoomAwareMagnet() throws {
        let folder = ThreadFolder(id: "folder-meetings",
                                  title: "Meetings",
                                  color: .defaultNewFolder,
                                  threadIDs: ["foldered-thread"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [
            makeThread(rootID: "foldered-thread", messageCount: 1),
            makeThread(rootID: "unfiled-thread", messageCount: 1)
        ],
        folders: [folder],
        folderMembershipByThreadID: ["foldered-thread": folder.id],
        now: Date(timeIntervalSince1970: 10_000))
        let grouping = try XCTUnwrap(graph.groupings.first { $0.sourceFolderID == folder.id })
        let draggedNodeID = GraphData.threadNodeID(for: "unfiled-thread")
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        let folderNode = try XCTUnwrap(scene.children.compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == grouping.id })

        XCTAssertNotNil(scene.folderDropTarget(
            at: CGPoint(x: folderNode.position.x + 36, y: folderNode.position.y),
            draggedGraphNodeID: draggedNodeID
        ))
        XCTAssertNil(scene.folderDropTarget(
            at: CGPoint(x: folderNode.position.x + 70, y: folderNode.position.y),
            draggedGraphNodeID: draggedNodeID
        ))

        let zoomedOutScene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(zoomedOutScene, data: graph, zoomScale: 0.5)
        let zoomedOutFolderNode = try XCTUnwrap(
            zoomedOutScene.children.compactMap { $0 as? ObsidianGraphSceneNode }
                .first { $0.graphID == grouping.id }
        )
        XCTAssertNotNil(zoomedOutScene.folderDropTarget(
            at: CGPoint(x: zoomedOutFolderNode.position.x + 70,
                        y: zoomedOutFolderNode.position.y),
            draggedGraphNodeID: draggedNodeID
        ))
    }

    func test_performFolderDrop_messageOverConfirmedFolder_movesOwningThread() throws {
        let folder = ThreadFolder(id: "folder-meetings",
                                  title: "Meetings",
                                  color: .defaultNewFolder,
                                  threadIDs: ["foldered-thread"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [
            makeThread(rootID: "foldered-thread", messageCount: 1),
            makeThread(rootID: "unfiled-thread", messageCount: 2)
        ],
        folders: [folder],
        folderMembershipByThreadID: ["foldered-thread": folder.id],
        now: Date(timeIntervalSince1970: 10_000))
        let grouping = try XCTUnwrap(graph.groupings.first { $0.sourceFolderID == folder.id })
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        let folderNode = try XCTUnwrap(scene.children.compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == grouping.id })
        var movedThreadID: String?
        var destinationFolderID: String?
        scene.onMoveThreadToFolder = { threadID, folderID in
            movedThreadID = threadID
            destinationFolderID = folderID
        }

        let didMove = scene.performFolderDrop(
            at: folderNode.position,
            draggedGraphNodeID: GraphData.messageNodeID(for: "unfiled-thread-msg-1")
        )

        XCTAssertTrue(didMove)
        XCTAssertEqual(movedThreadID, "unfiled-thread")
        XCTAssertEqual(destinationFolderID, folder.id)
    }

    func test_folderDropTarget_threadAlreadyInFolder_returnsNil() throws {
        let folder = ThreadFolder(id: "folder-meetings",
                                  title: "Meetings",
                                  color: .defaultNewFolder,
                                  threadIDs: ["foldered-thread"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [makeThread(rootID: "foldered-thread", messageCount: 1)],
                                   folders: [folder],
                                   folderMembershipByThreadID: ["foldered-thread": folder.id],
                                   now: Date(timeIntervalSince1970: 10_000))
        let grouping = try XCTUnwrap(graph.groupings.first { $0.sourceFolderID == folder.id })
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        let folderNode = try XCTUnwrap(scene.children.compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == grouping.id })

        XCTAssertNil(scene.folderDropTarget(
            at: folderNode.position,
            draggedGraphNodeID: GraphData.threadNodeID(for: "foldered-thread")
        ))
        XCTAssertTrue(
            scene.stationaryFolderDropNodeIDs(
                forDraggedGraphNodeID: GraphData.threadNodeID(for: "foldered-thread")
            ).isEmpty
        )
    }

    func test_folderDropTarget_threadOverSuggestedTopic_returnsNil() throws {
        let graph = GraphData.make(roots: [
            makeThread(rootID: "root-a", messageCount: 1),
            makeThread(rootID: "root-b", messageCount: 1)
        ],
        topicSignalsByRawThreadID: [
            "root-a": makeTopicSignal("CR60 booking rollout", confidence: 0.90),
            "root-b": makeTopicSignal("CR60 booking rollout", confidence: 0.86)
        ],
        now: Date(timeIntervalSince1970: 10_000))
        let suggestion = try XCTUnwrap(graph.groupings.first(where: \.isSuggestion))
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        let suggestionNode = try XCTUnwrap(scene.children.compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == suggestion.id })

        XCTAssertNil(scene.folderDropTarget(
            at: suggestionNode.position,
            draggedGraphNodeID: GraphData.threadNodeID(for: "root-a")
        ))
    }

    func test_teardownForRemoval_releasesGraphAndStopsSceneWork() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 3)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        var positionReportCount = 0
        scene.onPositionsChanged = { _ in positionReportCount += 1 }

        scene.teardownForRemoval()
        scene.update(1)

        XCTAssertTrue(scene.isPaused)
        XCTAssertTrue(scene.children.isEmpty)
        XCTAssertNil(scene.hitTestNodeID(at: CGPoint(x: 400, y: 300)))
        XCTAssertEqual(positionReportCount, 0)
    }

    func test_configure_whenHoveredNodeDisappears_clearsHoverCallback() {
        let firstGraph = GraphData.make(roots: [makeThread(rootID: "first", messageCount: 1)],
                                        now: Date(timeIntervalSince1970: 10_000))
        let secondGraph = GraphData.make(roots: [makeThread(rootID: "second", messageCount: 1)],
                                         now: Date(timeIntervalSince1970: 10_000))
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: firstGraph)
        var hoverEvents: [Bool] = []
        scene.onHoverItem = { hoverEvents.append($0 != nil) }

        scene.applyHoverCandidate(GraphData.threadNodeID(for: "first"),
                                  at: CGPoint(x: 400, y: 300))
        configure(scene, data: secondGraph)

        XCTAssertEqual(hoverEvents, [true, false])
    }

    func test_hoverCallback_convertsWorldPointIntoOverlayCoordinates() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 1)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene,
                  data: graph,
                  zoomScale: 2,
                  panOffset: CGPoint(x: 40, y: -20))
        var overlayPoint: CGPoint?
        scene.onHoverItem = { item in
            guard case .thread(_, let point) = item else { return }
            overlayPoint = point
        }

        scene.applyHoverCandidate(GraphData.threadNodeID(for: "root"),
                                  at: CGPoint(x: 450, y: 290))

        assertPointsEqual(overlayPoint, CGPoint(x: 420, y: 320))
    }

    func test_recenter_withReduceMotion_publishesResetViewportImmediately() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 1)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene,
                  data: graph,
                  reduceMotion: true,
                  zoomScale: 2,
                  panOffset: CGPoint(x: 40, y: -20))
        var publishedViewport: (zoom: CGFloat, pan: CGPoint)?
        scene.onViewportChanged = { zoom, pan in
            publishedViewport = (zoom, pan)
        }

        scene.recenterCamera(animated: true)

        XCTAssertEqual(publishedViewport?.zoom ?? -1, 1, accuracy: 0.001)
        assertPointsEqual(publishedViewport?.pan, .zero)
    }

    func test_snipTargetResolver_mapsWholeThreadsAndConfirmedFolderTrunksOnly() throws {
        let folder = ThreadFolder(id: "folder-snip",
                                  title: "Snip Folder",
                                  color: .defaultNewFolder,
                                  threadIDs: ["foldered"],
                                  parentID: nil)
        let graph = GraphData.make(
            roots: [makeThread(rootID: "foldered", messageCount: 2)],
            folders: [folder],
            folderMembershipByThreadID: ["foldered": folder.id],
            now: Date(timeIntervalSince1970: 10_000)
        )
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(scene, data: graph)
        let grouping = try XCTUnwrap(graph.groupings.first { $0.kind == .folder })
        let threadID = GraphData.threadNodeID(for: "foldered")
        let replyID = GraphData.messageNodeID(for: "foldered-msg-1")
        let trunk = try XCTUnwrap(graph.edges.first {
            $0.kind == .trunk && $0.targetID == grouping.id
        })
        let replyEdge = try XCTUnwrap(graph.edges.first { $0.targetID == replyID })

        XCTAssertEqual(scene.snipTarget(forGraphNodeID: grouping.id),
                       .confirmedGroup(grouping.id))
        XCTAssertEqual(scene.snipTarget(for: trunk), .confirmedGroup(grouping.id))
        XCTAssertEqual(scene.snipTarget(forGraphNodeID: threadID), .thread(threadID))
        XCTAssertEqual(scene.snipTarget(forGraphNodeID: replyID), .thread(threadID))
        XCTAssertEqual(scene.snipTarget(for: replyEdge), .thread(threadID))
        XCTAssertNil(scene.snipTarget(forGraphNodeID: GraphCenter.you.id))

        let suggestedGraph = GraphData.make(
            roots: [makeThread(rootID: "suggested-a", messageCount: 1),
                    makeThread(rootID: "suggested-b", messageCount: 1)],
            topicSignalsByRawThreadID: [
                "suggested-a": makeTopicSignal("Shared rollout", confidence: 0.91),
                "suggested-b": makeTopicSignal("Shared rollout", confidence: 0.88)
            ],
            now: Date(timeIntervalSince1970: 10_000)
        )
        let suggestedScene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(suggestedScene, data: suggestedGraph)
        let suggestion = try XCTUnwrap(suggestedGraph.groupings.first(where: \.isSuggestion))
        let suggestedEdge = try XCTUnwrap(suggestedGraph.edges.first { $0.kind == .suggested })
        XCTAssertNil(suggestedScene.snipTarget(forGraphNodeID: suggestion.id))
        XCTAssertNil(suggestedScene.snipTarget(for: suggestedEdge))

        let pagedGraph = GraphData.make(
            roots: (1...3).map { makeThread(rootID: "paged-\($0)", messageCount: 1) },
            branchLimit: 1,
            branchBatchSize: 1,
            now: Date(timeIntervalSince1970: 10_000)
        )
        let pagedScene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        configure(pagedScene, data: pagedGraph)
        let remainingEdge = try XCTUnwrap(pagedGraph.edges.first { $0.kind == .remaining })
        XCTAssertNil(pagedScene.snipTarget(forGraphNodeID: GraphRemainingBranch.graphID))
        XCTAssertNil(pagedScene.snipTarget(for: remainingEdge))
    }

    func test_snipNodeState_ghostsAndReversesInPlaceIncludingReduceMotion() {
        let node = ObsidianGraphSceneNode(
            graphID: "thread:snip",
            kind: .thread,
            threadID: "thread:snip",
            radius: 14,
            title: "Snip",
            fillColor: .white,
            strokeColor: .gray,
            textScale: 1,
            theme: DesignTokens.Graph.AppTheme.Palette(isDark: false)
        )
        let originalPosition = CGPoint(x: 120, y: 240)
        node.position = originalPosition

        node.applyFocus(isSelected: false,
                        isHovered: false,
                        isNeighbor: false,
                        isDimmed: false,
                        hasFocusedNode: false,
                        snipState: .staged)
        XCTAssertEqual(node.alpha, 0.34, accuracy: 0.001)
        assertPointsEqual(node.position, originalPosition)

        node.applyFocus(isSelected: false,
                        isHovered: false,
                        isNeighbor: false,
                        isDimmed: false,
                        hasFocusedNode: false,
                        snipState: .partial)
        XCTAssertEqual(node.alpha, 0.68, accuracy: 0.001)

        node.runSnipTransition(.unstage, reduceMotion: true, delay: 0)
        XCTAssertNotNil(node.action(forKey: "obsidian-snip-transition"))
        assertPointsEqual(node.position, originalPosition)

        node.applyFocus(isSelected: false,
                        isHovered: false,
                        isNeighbor: false,
                        isDimmed: false,
                        hasFocusedNode: false,
                        snipState: .normal)
        XCTAssertEqual(node.alpha, 1, accuracy: 0.001)
    }

    private func configure(_ scene: ObsidianGraphScene,
                           data: GraphData,
                           reduceMotion: Bool = false,
                           zoomScale: CGFloat = 1,
                           panOffset: CGPoint = .zero) {
        scene.configure(data: data,
                        selectedGraphNodeID: nil,
                        pruneMode: .idle,
                        filteredNodeIDs: data.allNodeIDs,
                        wateredCounts: [:],
                        reduceMotion: reduceMotion,
                        sproutingMessageIDs: [],
                        forceConfig: .defaults,
                        displayConfig: .defaults,
                        theme: DesignTokens.Graph.AppTheme.Palette(isDark: false),
                        zoomScale: zoomScale,
                        panOffset: panOffset)
    }
}

final class GraphSceneStabilityTests: XCTestCase {
    func test_graphScene_interactionSuspendsHoverUntilNextPointerCandidate() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let scene = GraphScene(size: CGSize(width: 960, height: 640))
        scene.configure(data: graph,
                        selectedGraphNodeID: nil,
                        pruneMode: .idle,
                        filteredNodeIDs: graph.allNodeIDs,
                        wateredCounts: [:],
                        reduceMotion: true,
                        sproutingMessageIDs: [],
                        forceConfig: GraphForceConstants.defaults,
                        theme: DesignTokens.Graph.AppTheme.Palette(isDark: false),
                        zoomScale: 1,
                        panOffset: .zero)
        var hoverEvents: [Bool] = []
        scene.onHoverItem = { hoverEvents.append($0 != nil) }
        let threadID = GraphData.threadNodeID(for: "root")

        scene.applyHoverCandidate(threadID, at: CGPoint(x: 300, y: 300))
        scene.suspendHoverForInteraction()
        scene.suspendHoverForInteraction()

        XCTAssertEqual(hoverEvents, [true, false])

        scene.applyHoverCandidate(threadID, at: CGPoint(x: 320, y: 310))

        XCTAssertEqual(hoverEvents, [true, false, true])
    }

    func test_graphScene_hoverPresentation_doesNotMoveGraphGeometry() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 3)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let scene = GraphScene(size: CGSize(width: 960, height: 640))
        scene.configure(data: graph,
                        selectedGraphNodeID: nil,
                        pruneMode: .idle,
                        filteredNodeIDs: graph.allNodeIDs,
                        wateredCounts: [:],
                        reduceMotion: true,
                        sproutingMessageIDs: [],
                        forceConfig: GraphForceConstants.defaults,
                        theme: DesignTokens.Graph.AppTheme.Palette(isDark: false),
                        zoomScale: 1,
                        panOffset: .zero)
        for frame in 1...200 {
            scene.update(Double(frame) * 0.016)
        }

        let graphNodes = scene.children.compactMap { $0 as? GraphSceneNode }
        let positionsBefore = Dictionary(uniqueKeysWithValues: graphNodes.map { ($0.graphID, $0.position) })
        let labelCentersBefore = Dictionary(uniqueKeysWithValues: graphNodes.compactMap { node in
            node.labelFrame(in: scene).map { (node.graphID, CGPoint(x: $0.midX, y: $0.midY)) }
        })
        let calloutPositionsBefore: [String: CGPoint] = Dictionary(
            uniqueKeysWithValues: scene.children.compactMap { child -> (String, CGPoint)? in
                guard let callout = child as? SummaryCalloutNode else { return nil }
                return (callout.graphID, callout.position)
            }
        )

        scene.applyHoverCandidate(GraphData.threadNodeID(for: "root"),
                                  at: CGPoint(x: 320, y: 280))
        scene.update(201 * 0.016)

        let graphNodesAfter = scene.children.compactMap { $0 as? GraphSceneNode }
        let positionsAfter = Dictionary(uniqueKeysWithValues: graphNodesAfter.map { ($0.graphID, $0.position) })
        let labelCentersAfter = Dictionary(uniqueKeysWithValues: graphNodesAfter.compactMap { node in
            node.labelFrame(in: scene).map { (node.graphID, CGPoint(x: $0.midX, y: $0.midY)) }
        })
        let calloutPositionsAfter: [String: CGPoint] = Dictionary(
            uniqueKeysWithValues: scene.children.compactMap { child -> (String, CGPoint)? in
                guard let callout = child as? SummaryCalloutNode else { return nil }
                return (callout.graphID, callout.position)
            }
        )

        XCTAssertFalse(labelCentersBefore.isEmpty)
        for id in positionsBefore.keys {
            assertPointsEqual(positionsBefore[id], positionsAfter[id])
        }
        for id in labelCentersBefore.keys {
            assertPointsEqual(labelCentersBefore[id], labelCentersAfter[id])
        }
        for id in calloutPositionsBefore.keys {
            assertPointsEqual(calloutPositionsBefore[id], calloutPositionsAfter[id])
        }
    }

    func test_graphScene_labelResolution_avoidsNodeAndCalloutOccludersWithinBoundedMotion() {
        let labelFrame = CGRect(x: 100, y: 100, width: 120, height: 30)
        let occluders = [
            CGRect(x: 100, y: 100, width: 120, height: 30),
            CGRect(x: 248, y: 90, width: 80, height: 90)
        ]
        let offset = GraphScene.resolvedLabelOffset(
            frame: labelFrame,
            branchUnit: CGVector(dx: 1, dy: 0),
            occluders: occluders,
            viewport: CGRect(x: 0, y: 0, width: 500, height: 400)
        )
        let resolvedFrame = labelFrame.offsetBy(dx: offset.dx, dy: offset.dy)

        XCTAssertTrue(occluders.allSatisfy {
            !resolvedFrame.insetBy(dx: -6, dy: -4).intersects($0)
        })
        XCTAssertLessThanOrEqual(hypot(offset.dx, offset.dy), 64.001)
    }

    func test_graphScene_afterSettling_stopsPublishingPositionsWithoutInput() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 8)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let scene = GraphScene(size: CGSize(width: 960, height: 640))
        var reportCount = 0
        scene.onPositionsChanged = { _ in
            reportCount += 1
        }

        scene.configure(data: graph,
                        selectedGraphNodeID: nil,
                        pruneMode: .idle,
                        filteredNodeIDs: graph.allNodeIDs,
                        wateredCounts: [:],
                        reduceMotion: true,
                        sproutingMessageIDs: [],
                        forceConfig: GraphForceConstants.defaults,
                        theme: DesignTokens.Graph.AppTheme.Palette(isDark: false),
                        zoomScale: 1,
                        panOffset: .zero)

        for frame in 1...200 {
            scene.update(Double(frame) * 0.016)
        }
        let settledReportCount = reportCount

        for frame in 201...260 {
            scene.update(Double(frame) * 0.016)
        }

        XCTAssertGreaterThan(settledReportCount, 0)
        XCTAssertEqual(reportCount, settledReportCount)
    }

    func test_graphScene_selectionOnlyChange_doesNotRestartPhysics() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 5)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let scene = GraphScene(size: CGSize(width: 960, height: 640))
        var reportCount = 0
        scene.onPositionsChanged = { _ in reportCount += 1 }
        let configure: (String?) -> Void = { selectedID in
            scene.configure(data: graph,
                            selectedGraphNodeID: selectedID,
                            pruneMode: .idle,
                            filteredNodeIDs: graph.allNodeIDs,
                            wateredCounts: [:],
                            reduceMotion: false,
                            sproutingMessageIDs: [],
                            forceConfig: GraphForceConstants.defaults,
                            theme: DesignTokens.Graph.AppTheme.Palette(isDark: false),
                            zoomScale: 1,
                            panOffset: .zero)
        }

        configure(nil)
        for frame in 1...220 {
            scene.update(Double(frame) * 0.016)
        }
        let settledReportCount = reportCount

        configure(graph.threads.first?.id)
        for frame in 221...280 {
            scene.update(Double(frame) * 0.016)
        }

        XCTAssertGreaterThan(settledReportCount, 0)
        XCTAssertEqual(reportCount, settledReportCount)
    }
}

final class GraphSceneNodeLabelTests: XCTestCase {
    func test_longThreadLabel_isAnchoredNearNodeAndUsesBoundedChip() {
        let theme = DesignTokens.Graph.AppTheme.Palette(isDark: false)
        let node = GraphSceneNode(graphID: "thread:test",
                                  kind: .thread,
                                  threadID: "thread:test",
                                  radius: 28,
                                  title: "FW: [SQ0545-4600 / SQ0545-4027] Login Name Exceptional Handling",
                                  fillColor: theme.panelNS,
                                  strokeColor: theme.inkNS,
                                  strokeWidth: 1,
                                  showsLabel: true,
                                  theme: theme)

        node.setBranchGeometry(angle: 0, incomingDistance: 300)

        guard let frame = node.labelFrame(in: node) else {
            return XCTFail("Missing branch label")
        }
        XCTAssertEqual(frame.midY, 0, accuracy: 0.5)
        XCTAssertLessThan(frame.maxX, -28)
        XCTAssertGreaterThan(frame.midX, -150)
        XCTAssertLessThan(frame.midX, -100)
        XCTAssertLessThanOrEqual(frame.width, 190.5)
        XCTAssertGreaterThan(frame.width, 116)
    }

    func test_graphLabelsAndSummaryCallouts_honorTextScale() {
        let theme = DesignTokens.Graph.AppTheme.Palette(isDark: false)
        let normalNode = GraphSceneNode(graphID: "thread:normal",
                                        kind: .thread,
                                        threadID: "thread:normal",
                                        radius: 28,
                                        title: "A readable graph label",
                                        fillColor: theme.panelNS,
                                        strokeColor: theme.inkNS,
                                        strokeWidth: 1,
                                        showsLabel: true,
                                        textScale: 1,
                                        theme: theme)
        let largeNode = GraphSceneNode(graphID: "thread:large",
                                       kind: .thread,
                                       threadID: "thread:large",
                                       radius: 28,
                                       title: "A readable graph label",
                                       fillColor: theme.panelNS,
                                       strokeColor: theme.inkNS,
                                       strokeWidth: 1,
                                       showsLabel: true,
                                       textScale: 1.4,
                                       theme: theme)
        normalNode.setBranchGeometry(angle: 0, incomingDistance: 300)
        largeNode.setBranchGeometry(angle: 0, incomingDistance: 300)

        guard let normalFrame = normalNode.labelFrame(in: normalNode),
              let largeFrame = largeNode.labelFrame(in: largeNode) else {
            return XCTFail("Missing scaled graph labels")
        }
        XCTAssertGreaterThan(largeFrame.width, normalFrame.width)
        XCTAssertGreaterThan(largeFrame.height, normalFrame.height)

        let normalCallout = SummaryCalloutNode(graphID: "message:normal",
                                               text: "A readable summary callout",
                                               textScale: 1,
                                               theme: theme)
        let largeCallout = SummaryCalloutNode(graphID: "message:large",
                                              text: "A readable summary callout",
                                              textScale: 1.4,
                                              theme: theme)
        XCTAssertGreaterThan(largeCallout.boxSize.width, normalCallout.boxSize.width)
        XCTAssertGreaterThan(largeCallout.boxSize.height, normalCallout.boxSize.height)
    }
}

final class GraphSplineTests: XCTestCase {
    func test_splinePath_withCurl_startsAndEndsAtEdgeEndpointsAndStaysInEnvelope() {
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 210, y: 20)
        let config = GraphCurlConfig(curl: 6, curlVariability: 0.2, splineTension: 0.35, curlFalloff: 0.45)

        let points = GraphSpline.points(from: start, to: end, seed: 42, config: config)
        assertPointsEqual(points.first, start)
        assertPointsEqual(points.last, end)
        for point in points {
            XCTAssertLessThanOrEqual(abs(point.y - start.y), config.curl * (1 + config.curlVariability) + 4)
        }

        let path = splinePath(from: start, to: end, seed: 42, config: config)
        assertPointsEqual(path.currentPoint, end)
    }

    func test_ribbonPoints_withTaper_preserveRequestedEndpointWidths() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 120, y: 0)
        let config = GraphCurlConfig(curl: 0, curlVariability: 0, splineTension: 0.35, curlFalloff: 0.45)

        let ribbon = GraphSpline.ribbonPoints(from: start,
                                              to: end,
                                              seed: 7,
                                              config: config,
                                              anchor: nil,
                                              widthStart: 8,
                                              widthEnd: 2,
                                              tipMin: 1,
                                              taperPow: 1.8,
                                              samples: 36)

        XCTAssertEqual(pointDistance(ribbon.left.first, ribbon.right.first), 8, accuracy: 0.001)
        XCTAssertEqual(pointDistance(ribbon.left.last, ribbon.right.last), 2, accuracy: 0.001)
    }

    func test_outwardArcSign_whenMidpointIsPositiveNormalSide_returnsPositive() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 0)
        let anchor = CGPoint(x: 50, y: -20)
        let config = GraphCurlConfig(curl: 9,
                                     curlVariability: 0,
                                     splineTension: 0.35,
                                     curlFalloff: 0.45,
                                     asymmetricArc: true)

        let sign = GraphSpline.outwardArcSign(from: start, to: end, anchor: anchor, fallbackSign: -1)
        let points = GraphSpline.points(from: start, to: end, seed: 9, config: config, anchor: anchor)

        XCTAssertEqual(sign, 1)
        XCTAssertGreaterThan(points[2].y, 0)
    }
}

final class GraphSummaryPlacementTests: XCTestCase {
    func test_autoPlacement_picksCardinalWithGreatestFreeSpace() {
        let origin = CGPoint(x: 0, y: 0)
        let boxSize = CGSize(width: 120, height: 40)
        let occluders = [
            GraphSummaryOccluder(id: "right", position: CGPoint(x: 56, y: 0), radius: 24),
            GraphSummaryOccluder(id: "up", position: CGPoint(x: 0, y: 56), radius: 24),
            GraphSummaryOccluder(id: "down", position: CGPoint(x: 0, y: -56), radius: 24),
            GraphSummaryOccluder(id: "upper-right", position: CGPoint(x: 40, y: 40), radius: 24),
            GraphSummaryOccluder(id: "lower-right", position: CGPoint(x: 40, y: -40), radius: 24)
        ]

        let angle = GraphSummaryPlacement.preferredAngle(origin: origin,
                                                        boxSize: boxSize,
                                                        occluders: occluders,
                                                        previousAngle: nil)

        XCTAssertEqual(angle, .pi, accuracy: 0.001)
    }

    func test_smoothedAngle_whenEffectivelyAtPickedAngle_snapsToPickedAngle() {
        let picked = CGFloat.pi / 2
        let smoothed = GraphSummaryPlacement.smoothedAngle(previous: picked - 0.0005,
                                                          picked: picked)

        XCTAssertEqual(smoothed, picked, accuracy: 0.000001)
    }
}

final class GraphSelectionTests: XCTestCase {
    func test_nearestNodeID_whenMovingInEachDirection_picksDirectionalNeighbor() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 5)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 500, height: 500))
        let rootID = GraphData.threadNodeID(for: "root")
        let upID = GraphData.messageNodeID(for: "root-msg-1")
        let downID = GraphData.messageNodeID(for: "root-msg-2")
        let leftID = GraphData.messageNodeID(for: "root-msg-3")
        let rightID = GraphData.messageNodeID(for: "root-msg-4")
        simulator.setPosition(CGPoint(x: 250, y: 250), for: rootID)
        simulator.setPosition(CGPoint(x: 250, y: 340), for: upID)
        simulator.setPosition(CGPoint(x: 250, y: 160), for: downID)
        simulator.setPosition(CGPoint(x: 140, y: 250), for: leftID)
        simulator.setPosition(CGPoint(x: 360, y: 250), for: rightID)

        XCTAssertEqual(simulator.nearestNodeID(from: rootID, direction: .up), upID)
        XCTAssertEqual(simulator.nearestNodeID(from: rootID, direction: .down), downID)
        XCTAssertEqual(simulator.nearestNodeID(from: rootID, direction: .left), leftID)
        XCTAssertEqual(simulator.nearestNodeID(from: rootID, direction: .right), rightID)
    }

    func test_actionTarget_resolvesThreadAndMessageSelectionsToSameThread() async {
        await MainActor.run {
            let suiteName = "GraphSelectionTests-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                return XCTFail("Expected isolated defaults")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
            let viewModel = GraphCanvasViewModel(store: store)
            viewModel.update(roots: [makeThread(rootID: "root", messageCount: 3)],
                             searchQuery: "",
                             tagsByNodeID: ["root-msg-1": ["Follow up"]],
                             summariesByNodeID: [:])

            let threadTarget = viewModel.actionTarget(for: "root")
            let messageTarget = viewModel.actionTarget(for: "root-msg-1")

            XCTAssertEqual(threadTarget?.threadID, GraphData.threadNodeID(for: "root"))
            XCTAssertEqual(threadTarget?.rawMessageID, "root")
            XCTAssertEqual(messageTarget?.threadID, threadTarget?.threadID)
            XCTAssertEqual(messageTarget?.rawMessageID, "root-msg-1")
            XCTAssertEqual(messageTarget?.tags, ["Follow up"])
        }
    }

    func test_graphNodeIDs_mapsEverySelectedThreadAndMessageNode() async {
        await MainActor.run {
            let suiteName = "GraphSelectionTests-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                return XCTFail("Expected isolated defaults")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
            let viewModel = GraphCanvasViewModel(store: store)
            viewModel.update(roots: [makeThread(rootID: "root", messageCount: 3)],
                             searchQuery: "",
                             tagsByNodeID: [:],
                             summariesByNodeID: [:])

            let selectedGraphNodeIDs = viewModel.graphNodeIDs(
                for: ["root", "root-msg-1", "missing"]
            )

            XCTAssertEqual(selectedGraphNodeIDs,
                           Set([
                               GraphData.threadNodeID(for: "root"),
                               GraphData.messageNodeID(for: "root-msg-1")
                           ]))
        }
    }

    func test_requestSnip_whenArchiveModeWasActive_createsSnipRequest() async {
        await MainActor.run {
            let suiteName = "GraphSelectionTests-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                return XCTFail("Expected isolated defaults")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
            let viewModel = GraphCanvasViewModel(store: store)
            viewModel.update(roots: [makeThread(rootID: "root", messageCount: 2)],
                             searchQuery: "",
                             tagsByNodeID: [:],
                             summariesByNodeID: [:])
            let threadID = GraphData.threadNodeID(for: "root")

            viewModel.toggleArchiveMode()
            viewModel.requestSnip(threadID: threadID)

            XCTAssertEqual(viewModel.pruneMode, .snip)
            XCTAssertEqual(viewModel.snipPhase, .staging)
            XCTAssertEqual(viewModel.stagedSnipThreadIDs, [threadID])
            XCTAssertNil(viewModel.snipBatchRequest)
        }
    }

    func test_activateSnip_whenNothingIsSelected_entersBranchPickingMode() async {
        await MainActor.run {
            let suiteName = "GraphSelectionTests-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                return XCTFail("Expected isolated defaults")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
            let viewModel = GraphCanvasViewModel(store: store)

            viewModel.activateSnip(selectedThreadID: nil)

            XCTAssertEqual(viewModel.pruneMode, .snip)
            XCTAssertEqual(viewModel.snipPhase, .staging)
            XCTAssertTrue(viewModel.stagedSnipItems.isEmpty)
            XCTAssertNil(viewModel.snipBatchRequest)
        }
    }

    func test_archiveThread_keepsBranchUntilPruneAnimationFinishes() async {
        let suiteName = "GraphSelectionTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Expected isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = await MainActor.run {
            let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
            let viewModel = GraphCanvasViewModel(store: store)
            viewModel.update(roots: [makeThread(rootID: "root", messageCount: 2)],
                             searchQuery: "",
                             tagsByNodeID: [:],
                             summariesByNodeID: [:])
            return viewModel
        }
        let threadID = GraphData.threadNodeID(for: "root")

        await viewModel.archiveThread(threadID: threadID)

        let request = await MainActor.run { viewModel.pruneAnimationRequest }
        XCTAssertEqual(request?.threadID, threadID)
        XCTAssertEqual(request?.action, .archive)
        await MainActor.run {
            XCTAssertNotNil(viewModel.data.threadByID[threadID])
            if let request {
                viewModel.finishPruneAnimation(id: request.id)
            }
            XCTAssertNil(viewModel.data.threadByID[threadID])
            XCTAssertNil(viewModel.pruneAnimationRequest)
        }
    }
}

final class GraphBatchSnipTests: XCTestCase {
    func test_firstSnipClick_entersStagingWithoutConsumingSelection() async {
        let mover = TestGraphSnipMailMover([])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   mailMover: mover)
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let threadID = GraphData.threadNodeID(for: "root")

        await MainActor.run {
            setup.viewModel.activateSnip(selectedThreadID: threadID)

            XCTAssertEqual(setup.viewModel.snipPhase, .staging)
            XCTAssertEqual(setup.viewModel.pruneMode, .snip)
            XCTAssertTrue(setup.viewModel.stagedSnipItems.isEmpty)
            XCTAssertEqual(setup.viewModel.snipActionTitle,
                           NSLocalizedString("graph.toolbar.snip", comment: "Graph snip mode"))

            setup.viewModel.activateSnip()
            XCTAssertEqual(setup.viewModel.snipPhase, .idle)
        }
    }

    func test_threadToggling_deduplicatesAndClearsAccountLockAfterLastUnstage() async {
        let mover = TestGraphSnipMailMover([])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(
                roots: [makeThread(rootID: "one", messageCount: 2, accountName: "Work"),
                        makeThread(rootID: "two", messageCount: 1, accountName: "Work")],
                mailMover: mover
            )
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let one = GraphData.threadNodeID(for: "one")
        let two = GraphData.threadNodeID(for: "two")

        await MainActor.run {
            setup.viewModel.activateSnip()
            setup.viewModel.toggleSnipTarget(.thread(one))
            setup.viewModel.toggleSnipTarget(.thread(two))
            XCTAssertEqual(setup.viewModel.stagedSnipThreadIDs, [one, two])
            XCTAssertEqual(setup.viewModel.stagedSnipCount, 2)
            XCTAssertTrue(setup.viewModel.snipActionTitle.contains("2"))
            XCTAssertEqual(setup.viewModel.snipLockedAccountName, "Work")
            XCTAssertTrue(setup.viewModel.isArchiveDisabledForSnip)

            setup.viewModel.toggleSnipTarget(.thread(one))
            setup.viewModel.toggleSnipTarget(.thread(two))
            XCTAssertTrue(setup.viewModel.stagedSnipItems.isEmpty)
            XCTAssertNil(setup.viewModel.snipLockedAccountName)
        }
    }

    func test_confirmedGroupToggle_includesPagedOutDescendantsAndTogglesAsOneSet() async throws {
        let mover = TestGraphSnipMailMover([])
        let rawIDs = (1...3).map { "root-\($0)" }
        let roots = rawIDs.map { makeThread(rootID: $0, messageCount: 1, accountName: "Work") }
        let folder = ThreadFolder(id: "folder-work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: Set(rawIDs),
                                  parentID: nil)
        let membership = Dictionary(uniqueKeysWithValues: rawIDs.map { ($0, folder.id) })
        let setup = await MainActor.run {
            makeGraphSnipViewModel(roots: roots,
                                   mailMover: mover,
                                   folders: [folder],
                                   folderMembershipByThreadID: membership,
                                   perNodeBranchPageSize: 2)
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }

        try await MainActor.run {
            let grouping = try XCTUnwrap(setup.viewModel.data.groupings.first { $0.kind == .folder })
            XCTAssertEqual(grouping.rawThreadIDs.count, 3)
            XCTAssertEqual(setup.viewModel.data.threads.count, 2)

            setup.viewModel.activateSnip()
            setup.viewModel.toggleSnipTarget(.confirmedGroup(grouping.id))
            XCTAssertEqual(setup.viewModel.stagedSnipCount, 3)
            XCTAssertEqual(setup.viewModel.fullyStagedSnipGroupingIDs, [grouping.id])

            setup.viewModel.toggleSnipTarget(.confirmedGroup(grouping.id))
            XCTAssertTrue(setup.viewModel.stagedSnipItems.isEmpty)
            XCTAssertNil(setup.viewModel.snipLockedAccountName)

            setup.viewModel.toggleSnipTarget(.thread(GraphData.threadNodeID(for: "root-1")))
            XCTAssertEqual(setup.viewModel.partiallyStagedSnipGroupingIDs, [grouping.id])
            setup.viewModel.toggleSnipTarget(.confirmedGroup(grouping.id))
            XCTAssertEqual(setup.viewModel.stagedSnipCount, 3)
            XCTAssertEqual(setup.viewModel.fullyStagedSnipGroupingIDs, [grouping.id])
        }
    }

    func test_mixedAccountGroup_requiresThreadLockThenStagesOnlyMatchingDescendants() async throws {
        let mover = TestGraphSnipMailMover([])
        let roots = [makeThread(rootID: "work-1", messageCount: 1, accountName: "Work"),
                     makeThread(rootID: "work-2", messageCount: 1, accountName: "Work"),
                     makeThread(rootID: "personal", messageCount: 1, accountName: "Personal")]
        let rawIDs = ["work-1", "work-2", "personal"]
        let folder = ThreadFolder(id: "folder-mixed",
                                  title: "Mixed",
                                  color: .defaultNewFolder,
                                  threadIDs: Set(rawIDs),
                                  parentID: nil)
        let setup = await MainActor.run {
            makeGraphSnipViewModel(
                roots: roots,
                mailMover: mover,
                folders: [folder],
                folderMembershipByThreadID: Dictionary(uniqueKeysWithValues: rawIDs.map { ($0, folder.id) })
            )
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }

        try await MainActor.run {
            let grouping = try XCTUnwrap(setup.viewModel.data.groupings.first { $0.kind == .folder })
            setup.viewModel.activateSnip()
            setup.viewModel.toggleSnipTarget(.confirmedGroup(grouping.id))
            XCTAssertTrue(setup.viewModel.stagedSnipItems.isEmpty)
            XCTAssertNil(setup.viewModel.snipLockedAccountName)
            XCTAssertEqual(setup.viewModel.snipNotice?.style, .error)

            setup.viewModel.toggleSnipTarget(.thread(GraphData.threadNodeID(for: "work-1")))
            setup.viewModel.toggleSnipTarget(.confirmedGroup(grouping.id))
            XCTAssertEqual(setup.viewModel.stagedSnipThreadIDs,
                           [GraphData.threadNodeID(for: "work-1"),
                            GraphData.threadNodeID(for: "work-2")])
            XCTAssertEqual(setup.viewModel.snipLockedAccountName, "Work")
            XCTAssertFalse(setup.viewModel.stagedSnipThreadIDs
                .contains(GraphData.threadNodeID(for: "personal")))

            setup.viewModel.toggleSnipTarget(.thread(GraphData.threadNodeID(for: "personal")))
            XCTAssertEqual(setup.viewModel.stagedSnipCount, 2)
            XCTAssertEqual(setup.viewModel.snipNotice?.style, .error)
        }
    }

    func test_sheetBackPreservesGhostsAndDrafts_whileDiscardClearsSession() async throws {
        let mover = TestGraphSnipMailMover([])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(
                roots: [makeThread(rootID: "one", messageCount: 1),
                        makeThread(rootID: "two", messageCount: 1)],
                mailMover: mover
            )
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }

        try await MainActor.run {
            setup.viewModel.activateSnip()
            setup.viewModel.toggleSnipTarget(.thread(GraphData.threadNodeID(for: "one")))
            setup.viewModel.toggleSnipTarget(.thread(GraphData.threadNodeID(for: "two")))
            setup.viewModel.activateSnip()
            let request = try XCTUnwrap(setup.viewModel.snipBatchRequest)
            setup.viewModel.setSnipAllocation(threadID: request.items[0].threadID,
                                              destinationPath: "Archive/One")

            setup.viewModel.returnToSnipStaging()
            XCTAssertEqual(setup.viewModel.snipPhase, .staging)
            XCTAssertEqual(setup.viewModel.stagedSnipCount, 2)
            XCTAssertEqual(setup.viewModel.snipAllocations.count, 1)

            setup.viewModel.presentSnipAllocation()
            setup.viewModel.applySnipDestinationToAll("Archive/All")
            XCTAssertTrue(setup.viewModel.canConfirmSnipAllocations)
            XCTAssertEqual(Set(setup.viewModel.snipAllocations.values.map(\.destinationMailboxPath)),
                           ["Archive/All"])

            setup.viewModel.discardSnipSession()
            XCTAssertEqual(setup.viewModel.snipPhase, .idle)
            XCTAssertTrue(setup.viewModel.stagedSnipItems.isEmpty)
            XCTAssertTrue(setup.viewModel.snipAllocations.isEmpty)
            XCTAssertNil(setup.viewModel.snipBatchRequest)
        }
    }

    func test_canvasEscapeWhileAllocationSheetOwnsEvent_preservesBatchAndDrafts() async throws {
        let mover = TestGraphSnipMailMover([])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(
                roots: [makeThread(rootID: "one", messageCount: 1)],
                mailMover: mover
            )
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }

        try await MainActor.run {
            setup.viewModel.activateSnip()
            setup.viewModel.toggleSnipTarget(.thread(GraphData.threadNodeID(for: "one")))
            setup.viewModel.activateSnip()
            let request = try XCTUnwrap(setup.viewModel.snipBatchRequest)
            setup.viewModel.setSnipAllocation(threadID: request.items[0].threadID,
                                              destinationPath: "Archive/One")

            setup.viewModel.exitPruneMode()
            XCTAssertEqual(setup.viewModel.snipPhase, .allocating)
            XCTAssertEqual(setup.viewModel.stagedSnipCount, 1)
            XCTAssertEqual(setup.viewModel.snipAllocations.count, 1)
            XCTAssertNotNil(setup.viewModel.snipBatchRequest)

            setup.viewModel.returnToSnipStaging()
            XCTAssertEqual(setup.viewModel.snipPhase, .staging)
            XCTAssertEqual(setup.viewModel.stagedSnipCount, 1)
            XCTAssertEqual(setup.viewModel.snipAllocations.count, 1)
        }
    }

    func test_batchMove_fullSuccessRecordsExactLocationsAndRestoreIsSourceScoped() async throws {
        let mover = TestGraphSnipMailMover([
            .moved(["<ROOT@EXAMPLE.COM>", "child@example.com"]),
            .moved(["root@example.com", "CHILD@EXAMPLE.COM"])
        ])
        let child = ThreadNode(message: makeMessage(id: "child@example.com",
                                                    date: Date(timeIntervalSince1970: 9_940),
                                                    threadID: "root@example.com",
                                                    mailboxID: "Inbox",
                                                    accountName: "Work"),
                               children: [])
        let root = ThreadNode(message: makeMessage(id: "root@example.com",
                                                   date: Date(timeIntervalSince1970: 10_000),
                                                   threadID: "root@example.com",
                                                   mailboxID: "Inbox",
                                                   accountName: "Work"),
                              children: [child])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(roots: [root], mailMover: mover)
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let request = try await MainActor.run {
            try stageGraphSnipBatch(setup.viewModel,
                                    destinations: [GraphData.threadNodeID(for: "root@example.com"): "Filed/Done"])
        }

        let batchResult = await setup.viewModel.confirmSnipBatch(request: request)
        let result = try XCTUnwrap(batchResult)
        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(result.attemptedCount, 1)
        let entry = try await MainActor.run { try XCTUnwrap(setup.viewModel.compostEntries.first) }
        XCTAssertEqual(Set(entry.movedMessages.map(\.messageID)),
                       ["root@example.com", "child@example.com"])
        XCTAssertEqual(Set(entry.movedMessages.map(\.sourceMailboxPath)), ["Inbox"])
        XCTAssertEqual(Set(entry.movedMessages.map(\.destinationMailboxPath)), ["Filed/Done"])
        XCTAssertFalse(entry.requiresRecovery)

        try await setup.viewModel.restore(entry)
        let calls = await mover.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].messageIDs, ["child@example.com", "root@example.com"])
        XCTAssertEqual(calls[1].sourceMailboxPath, "Filed/Done")
        XCTAssertEqual(calls[1].destinationMailboxPath, "Inbox")
        let compostIsEmpty = await MainActor.run { setup.viewModel.compostEntries.isEmpty }
        XCTAssertTrue(compostIsEmpty)
    }

    func test_batchMove_partialMoveWithSuccessfulCompensationRollsBack() async throws {
        let mover = TestGraphSnipMailMover([
            .moved(["root"]),
            .moved(["root"])
        ])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   mailMover: mover)
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let request = try await MainActor.run {
            try stageGraphSnipBatch(setup.viewModel,
                                    destinations: [GraphData.threadNodeID(for: "root"): "Filed"])
        }

        let batchResult = await setup.viewModel.confirmSnipBatch(request: request)
        let result = try XCTUnwrap(batchResult)
        XCTAssertEqual(result.rolledBack.count, 1)
        XCTAssertTrue(result.recoveryNeeded.isEmpty)
        let compostIsEmpty = await MainActor.run { setup.viewModel.compostEntries.isEmpty }
        XCTAssertTrue(compostIsEmpty)
        let calls = await mover.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].messageIDs, ["root"])
        XCTAssertEqual(calls[1].sourceMailboxPath, "Filed")
        XCTAssertEqual(calls[1].destinationMailboxPath, "Inbox")
    }

    func test_batchMove_incompleteCompensationKeepsRecoveryBranchAndOnlyDisplacedIDs() async throws {
        let mover = TestGraphSnipMailMover([
            .moved(["root"]),
            .moved([])
        ])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   mailMover: mover)
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let threadID = GraphData.threadNodeID(for: "root")
        let request = try await MainActor.run {
            try stageGraphSnipBatch(setup.viewModel, destinations: [threadID: "Filed"])
        }

        let batchResult = await setup.viewModel.confirmSnipBatch(request: request)
        let result = try XCTUnwrap(batchResult)
        XCTAssertEqual(result.recoveryNeeded.count, 1)
        let entry = try await MainActor.run { try XCTUnwrap(setup.viewModel.compostEntries.first) }
        XCTAssertTrue(entry.requiresRecovery)
        XCTAssertEqual(entry.messageIDs, ["root"])
        XCTAssertEqual(entry.movedMessages.map(\.messageID), ["root"])
        let branchRemainsVisible = await MainActor.run {
            setup.viewModel.data.threadByID[threadID] != nil
        }
        let pruneAnimationRequest = await MainActor.run { setup.viewModel.pruneAnimationRequest }
        XCTAssertTrue(branchRemainsVisible)
        XCTAssertNil(pruneAnimationRequest)
    }

    func test_batchMove_zeroMoveContinuesToLaterDestination() async throws {
        let mover = TestGraphSnipMailMover([
            .moved([]),
            .moved(["second"])
        ])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(
                roots: [makeThread(rootID: "first", messageCount: 1),
                        makeThread(rootID: "second", messageCount: 1)],
                mailMover: mover
            )
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let firstID = GraphData.threadNodeID(for: "first")
        let secondID = GraphData.threadNodeID(for: "second")
        let request = try await MainActor.run {
            try stageGraphSnipBatch(setup.viewModel,
                                    destinations: [firstID: "Filed/A", secondID: "Filed/B"])
        }

        let batchResult = await setup.viewModel.confirmSnipBatch(request: request)
        let result = try XCTUnwrap(batchResult)
        XCTAssertEqual(result.unchanged.map(\.item.threadID), [firstID])
        XCTAssertEqual(result.succeeded.map(\.item.threadID), [secondID])
        XCTAssertEqual(result.attemptedCount, 2)
        let calls = await mover.recordedCalls()
        XCTAssertEqual(calls.map(\.destinationMailboxPath), ["Filed/A", "Filed/B"])
    }

    func test_batchMove_multipleSuccessesShareOneCompletionAnimation() async throws {
        let mover = TestGraphSnipMailMover([
            .moved(["first"]),
            .moved(["second"])
        ])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(
                roots: [makeThread(rootID: "first", messageCount: 1),
                        makeThread(rootID: "second", messageCount: 1)],
                mailMover: mover
            )
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let firstID = GraphData.threadNodeID(for: "first")
        let secondID = GraphData.threadNodeID(for: "second")
        let request = try await MainActor.run {
            try stageGraphSnipBatch(setup.viewModel,
                                    destinations: [firstID: "Filed", secondID: "Filed"])
        }

        let batchResult = await setup.viewModel.confirmSnipBatch(request: request)
        let result = try XCTUnwrap(batchResult)
        XCTAssertEqual(result.succeeded.count, 2)
        let completionRequest = await MainActor.run { setup.viewModel.pruneAnimationRequest }
        XCTAssertEqual(completionRequest?.threadIDs, [firstID, secondID])
        XCTAssertEqual(completionRequest?.action, .snip)
    }

    func test_batchMove_mixedSuccessAndRecoveryPrunesOnlySucceededBranch() async throws {
        let mover = TestGraphSnipMailMover([
            .moved(["success", "success-msg-1"]),
            .moved(["recovery"]),
            .moved([])
        ])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(
                roots: [makeThread(rootID: "success", messageCount: 2),
                        makeThread(rootID: "recovery", messageCount: 2)],
                mailMover: mover
            )
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let successID = GraphData.threadNodeID(for: "success")
        let recoveryID = GraphData.threadNodeID(for: "recovery")
        let request = try await MainActor.run {
            try stageGraphSnipBatch(setup.viewModel,
                                    destinations: [successID: "Filed", recoveryID: "Filed"])
        }

        let batchResult = await setup.viewModel.confirmSnipBatch(request: request)
        let result = try XCTUnwrap(batchResult)
        XCTAssertEqual(result.succeeded.map(\.item.threadID), [successID])
        XCTAssertEqual(result.recoveryNeeded.map(\.item.threadID), [recoveryID])
        let state = await MainActor.run {
            (setup.viewModel.pruneAnimationRequest,
             setup.viewModel.compostEntries,
             setup.viewModel.data.threadByID[recoveryID] != nil)
        }
        XCTAssertEqual(state.0?.threadIDs, [successID])
        XCTAssertEqual(state.1.count, 2)
        XCTAssertEqual(state.1.filter(\.requiresRecovery).map(\.threadID), [recoveryID])
        XCTAssertTrue(state.2)
    }

    func test_batchMove_ignoresDismissAndDiscardWhileExecutionIsFrozen() async throws {
        let mover = BlockingGraphSnipMailMover(movedMessageIDs: ["root"])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(roots: [makeThread(rootID: "root", messageCount: 1)],
                                   mailMover: mover)
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let request = try await MainActor.run {
            try stageGraphSnipBatch(setup.viewModel,
                                    destinations: [GraphData.threadNodeID(for: "root"): "Filed"])
        }

        let execution = Task { await setup.viewModel.confirmSnipBatch(request: request) }
        await mover.waitUntilStarted()
        await MainActor.run {
            XCTAssertEqual(setup.viewModel.snipPhase, .moving)
            setup.viewModel.returnToSnipStaging()
            setup.viewModel.discardSnipSession()
            XCTAssertEqual(setup.viewModel.snipPhase, .moving)
            XCTAssertEqual(setup.viewModel.stagedSnipCount, 1)
            XCTAssertNotNil(setup.viewModel.snipBatchRequest)
        }

        await mover.release()
        let batchResult = await execution.value
        let result = try XCTUnwrap(batchResult)
        XCTAssertEqual(result.succeeded.count, 1)
        await MainActor.run {
            XCTAssertEqual(setup.viewModel.snipPhase, .idle)
            XCTAssertNil(setup.viewModel.snipBatchRequest)
        }
    }

    func test_restore_sameNormalizedIDInTwoSourceMailboxesKeepsOnlyFailedLocation() async throws {
        let mover = TestGraphSnipMailMover([
            .moved(["duplicate@example.com"]),
            .moved(["DUPLICATE@EXAMPLE.COM"]),
            .moved(["duplicate@example.com"]),
            .moved([])
        ])
        let setup = await MainActor.run { () -> GraphSnipTestSetup in
            let inboxCopy = ThreadNode(
                message: makeMessage(id: "duplicate@example.com",
                                     date: Date(timeIntervalSince1970: 9_940),
                                     threadID: "root",
                                     mailboxID: "Inbox",
                                     accountName: "Work")
            )
            let archiveCopy = ThreadNode(
                message: makeMessage(id: "DUPLICATE@EXAMPLE.COM",
                                     date: Date(timeIntervalSince1970: 9_880),
                                     threadID: "root",
                                     mailboxID: "Archive",
                                     accountName: "Work")
            )
            let root = ThreadNode(
                message: makeMessage(id: "root",
                                     date: Date(timeIntervalSince1970: 10_000),
                                     threadID: "root",
                                     mailboxID: "Filed",
                                     accountName: "Work"),
                children: [inboxCopy, archiveCopy]
            )
            return makeGraphSnipViewModel(roots: [root], mailMover: mover)
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let request = try await MainActor.run {
            try stageGraphSnipBatch(setup.viewModel,
                                    destinations: [GraphData.threadNodeID(for: "root"): "Filed"])
        }

        let batchResult = await setup.viewModel.confirmSnipBatch(request: request)
        let result = try XCTUnwrap(batchResult)
        XCTAssertEqual(result.succeeded.count, 1)
        let entry = try await MainActor.run { try XCTUnwrap(setup.viewModel.compostEntries.first) }
        XCTAssertEqual(entry.movedMessages.count, 2)
        XCTAssertEqual(Set(entry.movedMessages.map(\.sourceMailboxPath)), ["Archive", "Inbox"])

        do {
            try await setup.viewModel.restore(entry)
            XCTFail("Expected an incomplete source-scoped restore")
        } catch {
            // The residual Compost entry is the user-visible recovery contract.
        }
        let residual = try await MainActor.run {
            try XCTUnwrap(setup.viewModel.compostEntries.first)
        }
        XCTAssertTrue(residual.requiresRecovery)
        XCTAssertEqual(residual.movedMessages.count, 1)
        XCTAssertEqual(residual.movedMessages.first?.sourceMailboxPath, "Inbox")
    }

    func test_mailMoveResult_normalizesAndDeduplicatesCaseInsensitively() {
        let result = GraphMailMoveResult(movedMessageIDs: [
            " <ABC@Example.com> ",
            "abc@example.COM",
            "<other@example.com>"
        ])

        XCTAssertEqual(result.movedMessageIDs, ["abc@example.com", "other@example.com"])
        XCTAssertTrue(result.contains("<ABC@EXAMPLE.COM>"))
    }

    func test_allocationValidation_requiresEveryCurrentFolderInLockedAccount() async throws {
        let mover = TestGraphSnipMailMover([])
        let setup = await MainActor.run {
            makeGraphSnipViewModel(roots: [makeThread(rootID: "root",
                                                       messageCount: 1,
                                                       accountName: "Work")],
                                   mailMover: mover)
        }
        defer { removeGraphSnipTestDefaults(setup.suiteName) }
        let request = try await MainActor.run {
            try stageGraphSnipBatch(setup.viewModel,
                                    destinations: [GraphData.threadNodeID(for: "root"): "Filed"])
        }
        let allocations = await MainActor.run { setup.viewModel.snipAllocations }

        let valid = await MainActor.run {
            SnipMoveSheet.allocationsAreValid(items: request.items,
                                              allocations: allocations,
                                              accountName: " work ",
                                              validPaths: ["Filed"])
        }
        let staleFolder = await MainActor.run {
            SnipMoveSheet.allocationsAreValid(items: request.items,
                                              allocations: allocations,
                                              accountName: "Work",
                                              validPaths: ["Archive"])
        }
        var wrongAccountAllocations = allocations
        let item = try XCTUnwrap(request.items.first)
        wrongAccountAllocations[item.threadID] = GraphSnipAllocation(
            threadID: item.threadID,
            destinationMailboxPath: "Filed",
            destinationAccountName: "Personal"
        )
        let wrongAccount = await MainActor.run {
            SnipMoveSheet.allocationsAreValid(items: request.items,
                                              allocations: wrongAccountAllocations,
                                              accountName: "Work",
                                              validPaths: ["Filed"])
        }

        XCTAssertTrue(valid)
        XCTAssertFalse(staleFolder)
        XCTAssertFalse(wrongAccount)
    }
}

final class GraphSnipMailboxTests: XCTestCase {
    func test_folderTree_whenPreferredParentIsMissing_fallsBackToAllFolders() {
        let nodes = [
            MailboxFolderNode(account: "Isaac IBM",
                              path: "Inbox",
                              name: "Inbox",
                              parentPath: nil,
                              children: []),
            MailboxFolderNode(account: "Isaac IBM",
                              path: "Important",
                              name: "Important",
                              parentPath: nil,
                              children: [])
        ]

        let visible = MailboxHierarchyBuilder.folderTree(nodes, preferredParentPath: "Unimportant")

        XCTAssertEqual(visible.map(\.path), ["Inbox", "Important"])
    }

    func test_folderTree_whenPreferredParentExists_keepsPreferredSubtree() {
        let nodes = [
            MailboxFolderNode(account: "Isaac IBM",
                              path: "Inbox",
                              name: "Inbox",
                              parentPath: nil,
                              children: []),
            MailboxFolderNode(account: "Isaac IBM",
                              path: "Important",
                              name: "Important",
                              parentPath: nil,
                              children: [
                                MailboxFolderNode(account: "Isaac IBM",
                                                  path: "Important/HKJC - B&V",
                                                  name: "HKJC - B&V",
                                                  parentPath: "Important",
                                                  children: [])
                              ])
        ]

        let visible = MailboxHierarchyBuilder.folderTree(nodes, preferredParentPath: "Important")

        XCTAssertEqual(visible.map(\.path), ["Important"])
        XCTAssertEqual(visible.first?.children.map(\.path), ["Important/HKJC - B&V"])
    }

    func test_accountMatching_ignoresWhitespaceAndCase() {
        let accounts = [
            MailboxAccount(name: "Isaac IBM", folders: []),
            MailboxAccount(name: "Personal", folders: [])
        ]

        let account = MailboxHierarchyBuilder.account(matching: "  isaac ibm ", in: accounts)

        XCTAssertEqual(account?.name, "Isaac IBM")
    }
}

final class GraphPruneStateMachineTests: XCTestCase {
    func test_pruneStateMachine_snipAndRestore_roundTripsToIdle() {
        var machine = GraphPruneStateMachine()

        XCTAssertEqual(machine.send(.enterSnip), .snipMode)
        XCTAssertEqual(machine.send(.edgeClicked(threadID: "thread-1")), .pickingFolder(threadID: "thread-1"))
        XCTAssertEqual(machine.send(.folderPicked), .wilting(threadID: "thread-1"))
        XCTAssertEqual(machine.send(.animationFinished), .composted(threadID: "thread-1"))
        XCTAssertEqual(machine.send(.restore(threadID: "thread-1")), .restoring(threadID: "thread-1"))
        XCTAssertEqual(machine.send(.restoreFinished), .idle)
    }

    func test_pruneStateMachine_archiveAndCancel_returnsToIdle() {
        var machine = GraphPruneStateMachine()

        XCTAssertEqual(machine.send(.enterArchive), .archiveMode)
        XCTAssertEqual(machine.send(.edgeClicked(threadID: "thread-1")), .settling(threadID: "thread-1"))
        XCTAssertEqual(machine.send(.cancel), .idle)
    }
}

private actor TestGraphSnipMailMover: GraphSnipMailMoving {
    nonisolated enum Response: Sendable {
        case moved([String])
        case failure
    }

    nonisolated struct Call: Equatable, Sendable {
        let messageIDs: [String]
        let destinationMailboxPath: String
        let account: String?
        let sourceMailboxPath: String?
        let sourceAccount: String?
    }

    private var responses: [Response]
    private var calls: [Call] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func moveMessages(messageIDs: [String],
                      toMailboxPath mailboxPath: String,
                      account: String?,
                      sourceMailboxPath: String?,
                      sourceAccount: String?) async throws -> GraphMailMoveResult {
        calls.append(Call(messageIDs: messageIDs,
                          destinationMailboxPath: mailboxPath,
                          account: account,
                          sourceMailboxPath: sourceMailboxPath,
                          sourceAccount: sourceAccount))
        guard !responses.isEmpty else { return GraphMailMoveResult(movedMessageIDs: []) }
        switch responses.removeFirst() {
        case .moved(let movedMessageIDs):
            return GraphMailMoveResult(movedMessageIDs: movedMessageIDs)
        case .failure:
            throw TestGraphSnipMailMoverError.moveFailed
        }
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

private actor BlockingGraphSnipMailMover: GraphSnipMailMoving {
    private let movedMessageIDs: [String]
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(movedMessageIDs: [String]) {
        self.movedMessageIDs = movedMessageIDs
    }

    func moveMessages(messageIDs: [String],
                      toMailboxPath mailboxPath: String,
                      account: String?,
                      sourceMailboxPath: String?,
                      sourceAccount: String?) async throws -> GraphMailMoveResult {
        hasStarted = true
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return GraphMailMoveResult(movedMessageIDs: movedMessageIDs)
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private nonisolated enum TestGraphSnipMailMoverError: Error {
    case moveFailed
}

private struct GraphSnipTestSetup {
    let viewModel: GraphCanvasViewModel
    let suiteName: String
}

@MainActor
private func makeGraphSnipViewModel(
    roots: [ThreadNode],
    mailMover: any GraphSnipMailMoving,
    folders: [ThreadFolder] = [],
    folderMembershipByThreadID: [String: String] = [:],
    perNodeBranchPageSize: Int = 6
) -> GraphSnipTestSetup {
    let suiteName = "GraphBatchSnipTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Expected isolated defaults")
    }
    let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
    let viewModel = GraphCanvasViewModel(store: store, mailClient: mailMover)
    viewModel.update(roots: roots,
                     searchQuery: "",
                     tagsByNodeID: [:],
                     summariesByNodeID: [:],
                     folders: folders,
                     folderMembershipByThreadID: folderMembershipByThreadID,
                     perNodeBranchPageSize: perNodeBranchPageSize)
    return GraphSnipTestSetup(viewModel: viewModel, suiteName: suiteName)
}

@MainActor
private func stageGraphSnipBatch(
    _ viewModel: GraphCanvasViewModel,
    destinations: [String: String]
) throws -> GraphSnipBatchRequest {
    viewModel.activateSnip()
    for thread in viewModel.data.threads where destinations[thread.id] != nil {
        viewModel.toggleSnipTarget(.thread(thread.id))
    }
    viewModel.presentSnipAllocation()
    let request = try XCTUnwrap(viewModel.snipBatchRequest)
    for item in request.items {
        viewModel.setSnipAllocation(threadID: item.threadID,
                                    destinationPath: destinations[item.threadID])
    }
    XCTAssertTrue(viewModel.canConfirmSnipAllocations)
    return request
}

private func removeGraphSnipTestDefaults(_ suiteName: String) {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
}

private func assertPointsEqual(_ lhs: CGPoint?,
                               _ rhs: CGPoint?,
                               accuracy: CGFloat = 0.001,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
    guard let lhs, let rhs else {
        XCTFail("Expected both points to be non-nil", file: file, line: line)
        return
    }
    XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
}

private func pointDistance(_ lhs: CGPoint?, _ rhs: CGPoint?) -> CGFloat {
    guard let lhs, let rhs else { return .greatestFiniteMagnitude }
    return hypot(lhs.x - rhs.x, lhs.y - rhs.y)
}

private actor TestGraphTitleProvider: GraphTitleProviding {
    private let title: String
    private let delay: Duration?
    private(set) var callCount = 0

    init(title: String, delay: Duration? = nil) {
        self.title = title
        self.delay = delay
    }

    func makeGraphTitle(_ request: GraphTitleRequest) async throws -> String {
        callCount += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        return title
    }
}

private actor SequentialGraphTitleProvider: GraphTitleProviding {
    private let titles: [String]
    private let delayFirstTitle: Duration?
    private(set) var callCount = 0

    init(titles: [String], delayFirstTitle: Duration? = nil) {
        precondition(!titles.isEmpty)
        self.titles = titles
        self.delayFirstTitle = delayFirstTitle
    }

    func makeGraphTitle(_ request: GraphTitleRequest) async throws -> String {
        let titleIndex = callCount
        callCount += 1
        if titleIndex == 0, let delayFirstTitle {
            try await Task.sleep(for: delayFirstTitle)
        }
        return titles[min(titleIndex, titles.count - 1)]
    }
}

private actor TestGraphTopicProvider: GraphTopicProviding {
    private let signal: GraphTopicSignal?
    private let delay: Duration?
    private(set) var requests: [GraphTopicRequest] = []

    init(signal: GraphTopicSignal?, delay: Duration? = nil) {
        self.signal = signal
        self.delay = delay
    }

    var callCount: Int { requests.count }

    func generateTopic(_ request: GraphTopicRequest) async throws -> GraphTopicSignal? {
        requests.append(request)
        if let delay {
            try await Task.sleep(for: delay)
        }
        return signal
    }
}

private func makeTopicSignal(_ topic: String,
                             confidence: Double,
                             reason: String = "These conversations discuss the same specific workstream.") -> GraphTopicSignal {
    GraphTopicSignal(topic: topic,
                     displayTitle: topic,
                     confidence: confidence,
                     supportingReason: reason)
}

private func makeTopicConversation(_ rawThreadID: String,
                                   date: Date,
                                   folderID: String? = nil) -> GraphTopicConversation {
    GraphTopicConversation(rawThreadID: rawThreadID,
                           graphThreadID: GraphData.threadNodeID(for: rawThreadID),
                           fullTitle: "Full title \(rawThreadID)",
                           lastUpdated: date,
                           existingFolderID: folderID,
                           existingFolderTitle: folderID.map { "Folder \($0)" })
}

private func makeReviewGrouping() -> GraphGrouping {
    let members = ["root-a", "root-b", "root-c"].map { rawThreadID in
        GraphTopicMember(rawThreadID: rawThreadID,
                         graphThreadID: GraphData.threadNodeID(for: rawThreadID),
                         fullTitle: "Full title \(rawThreadID)",
                         existingFolderID: nil,
                         existingFolderTitle: nil)
    }
    return GraphGrouping(id: "suggestion:cr60-booking-rollout:root-a.root-b.root-c",
                         title: "CR60 booking rollout",
                         kind: .suggestedTopic,
                         threadIDs: members.map(\.graphThreadID),
                         rawThreadIDs: members.map(\.rawThreadID),
                         sourceFolderID: nil,
                         sourceTag: nil,
                         normalizedTopic: "cr60 booking rollout",
                         supportingReason: "These conversations discuss the CR60 booking rollout.",
                         reviewMembers: members)
}

private func assertPairwiseGeometryPreserved(nodeIDs: Set<String>,
                                             before: [String: CGPoint],
                                             after: [String: CGPoint],
                                             file: StaticString = #filePath,
                                             line: UInt = #line) {
    let sortedNodeIDs = nodeIDs.sorted()
    for leftIndex in sortedNodeIDs.indices {
        for rightIndex in sortedNodeIDs.indices where rightIndex > leftIndex {
            let leftID = sortedNodeIDs[leftIndex]
            let rightID = sortedNodeIDs[rightIndex]
            XCTAssertEqual(pointDistance(before[leftID], before[rightID]),
                           pointDistance(after[leftID], after[rightID]),
                           accuracy: 0.001,
                           "Relative geometry changed between \(leftID) and \(rightID)",
                           file: file,
                           line: line)
        }
    }
}

private func makeThread(rootID: String,
                        messageCount: Int,
                        rootDate: Date = Date(timeIntervalSince1970: 10_000),
                        mailboxID: String = "Inbox",
                        accountName: String = "Account") -> ThreadNode {
    var child: ThreadNode?
    for index in stride(from: messageCount - 1, through: 1, by: -1) {
        let node = ThreadNode(message: makeMessage(id: "\(rootID)-msg-\(index)",
                                                   subject: "Subject \(rootID)",
                                                   date: rootDate.addingTimeInterval(Double(index) * -60),
                                                   threadID: rootID,
                                                   mailboxID: mailboxID,
                                                   accountName: accountName),
                              children: child.map { [$0] } ?? [])
        child = node
    }
    return ThreadNode(message: makeMessage(id: rootID,
                                           subject: "Subject \(rootID)",
                                           date: rootDate,
                                           threadID: rootID,
                                           mailboxID: mailboxID,
                                           accountName: accountName),
                      children: child.map { [$0] } ?? [])
}

private func makeMessage(id: String,
                         subject: String = "Subject",
                         date: Date,
                         threadID: String,
                         mailboxID: String = "Inbox",
                         accountName: String = "Account") -> EmailMessage {
    EmailMessage(messageID: id,
                 internalMailID: "internal-\(id)",
                 mailboxID: mailboxID,
                 accountName: accountName,
                 subject: subject,
                 from: "sender@example.com",
                 to: "me@example.com",
                 date: date,
                 snippet: "Snippet \(id)",
                 isUnread: id.hasSuffix("1"),
                 inReplyTo: nil,
                 references: [],
                 threadID: threadID)
}
