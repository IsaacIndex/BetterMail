import XCTest
@testable import BetterMail

final class OrganizerProjectionTests: XCTestCase {
    func test_workspaceLayout_collapsesOnlyBelowNarrowThreshold() {
        XCTAssertTrue(OrganizerWorkspaceLayout.shouldCollapseRail(workspaceWidth: 659))
        XCTAssertFalse(OrganizerWorkspaceLayout.shouldCollapseRail(workspaceWidth: 660))
        XCTAssertTrue(OrganizerWorkspaceLayout.shouldCollapseRail(workspaceWidth: 900,
                                                                   isUserCollapsed: true))
    }

    func test_workspaceLayout_allowsOrganizerToReachNarrowThreshold() {
        XCTAssertEqual(OrganizerWorkspaceLayout.detailMinimumWidth(isOrganizerMode: true), 480)
        XCTAssertEqual(OrganizerWorkspaceLayout.detailMinimumWidth(isOrganizerMode: false), 720)
        XCTAssertLessThan(OrganizerWorkspaceLayout.organizerDetailMinimumWidth,
                          OrganizerWorkspaceLayout.narrowWorkspaceThreshold)
    }

    func test_projection_deduplicatesRootsByEffectiveConversationID() {
        let first = makeRoot(id: "message-a",
                             threadID: "automatic-a",
                             subject: "Manual batch",
                             date: 100)
        let second = makeRoot(id: "message-b",
                              threadID: "automatic-b",
                              subject: "Manual batch",
                              date: 200)
        let foldered = makeRoot(id: "message-c",
                                threadID: "automatic-c",
                                subject: "Already grouped",
                                date: 300)
        let folder = ThreadFolder(id: "confirmed-folder",
                                  title: "Confirmed",
                                  color: .defaultNewFolder,
                                  threadIDs: ["automatic-c"],
                                  parentID: nil)

        let projection = OrganizerProjection.make(
            scopeID: "scope-inbox",
            roots: [first, second, foldered],
            folders: [folder],
            manualGroupByMessageKey: [first.message.threadKey: "manual-conversation",
                                      second.message.threadKey: "manual-conversation"]
        )

        XCTAssertEqual(projection.scopeID, "scope-inbox")
        XCTAssertEqual(projection.unorganized.map(\.id), ["manual-conversation"])
        XCTAssertEqual(projection.unorganized.first?.messageCount, 2)
        XCTAssertEqual(projection.unorganized.first?.lastUpdated,
                       Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(projection.confirmedGroups.map(\.conversationIDs), [["automatic-c"]])
    }

    func test_projection_excludesArchiveAndKeepsSuggestionUnconfirmed() {
        let unorganized = makeRoot(id: "message-b",
                                   threadID: "conversation-b",
                                   subject: "Beta rollout",
                                   date: 200)
        let archived = makeRoot(id: "message-c",
                                threadID: "conversation-c",
                                subject: "Archived rollout",
                                date: 300)
        let suggestion = makeSuggestion(id: "suggestion:rollout",
                                        title: "Rollout",
                                        rawThreadIDs: ["conversation-b", "conversation-c"])

        let projection = OrganizerProjection.make(
            roots: [archived, unorganized],
            archivedThreadIDs: ["thread:conversation-c"],
            suggestedGroupings: [suggestion]
        )

        XCTAssertEqual(projection.unorganized.map(\.id), ["conversation-b"])
        XCTAssertEqual(projection.suggestedGroups.map(\.id), ["suggestion:rollout"])
        XCTAssertEqual(projection.suggestedGroups.first?.conversationIDs, ["conversation-b"])
        XCTAssertTrue(projection.confirmedGroups.isEmpty)
    }

    func test_projection_isStableWhenInputOrderChanges() {
        let newer = makeRoot(id: "newer", threadID: "conversation-b", subject: "Same", date: 200)
        let older = makeRoot(id: "older", threadID: "conversation-a", subject: "Same", date: 100)
        let folder = ThreadFolder(id: "folder",
                                  title: "Folder",
                                  color: .defaultNewFolder,
                                  threadIDs: ["conversation-a", "conversation-b"],
                                  parentID: nil)

        let first = OrganizerProjection.make(scopeID: "stable",
                                             roots: [newer, older],
                                             folders: [folder])
        let second = OrganizerProjection.make(scopeID: "stable",
                                              roots: [older, newer],
                                              folders: [folder])

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.cacheKey, second.cacheKey)
        XCTAssertEqual(first.confirmedGroups.first?.conversationIDs,
                       ["conversation-b", "conversation-a"])
    }

    func test_duplicateSuggestionIDUsesCompleteDeterministicTieBreak() {
        let first = makeRoot(id: "first",
                             threadID: "conversation-a",
                             subject: "Rollout",
                             date: 200)
        let second = makeRoot(id: "second",
                              threadID: "conversation-b",
                              subject: "Rollout",
                              date: 100)
        let laterReason = makeSuggestion(id: "suggestion:rollout",
                                         title: "Rollout",
                                         rawThreadIDs: ["conversation-a", "conversation-b"],
                                         supportingReason: "Zulu reason")
        let earlierReason = makeSuggestion(id: "suggestion:rollout",
                                           title: "Rollout",
                                           rawThreadIDs: ["conversation-a", "conversation-b"],
                                           supportingReason: "Alpha reason")

        let forward = OrganizerProjection.make(
            roots: [first, second],
            suggestedGroupings: [laterReason, earlierReason]
        )
        let reversed = OrganizerProjection.make(
            roots: [first, second],
            suggestedGroupings: [earlierReason, laterReason]
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.cacheKey, reversed.cacheKey)
        XCTAssertEqual(forward.suggestedGroups.first?.supportingReason, "Alpha reason")
    }

    func test_projection_appliesSearchToUnorganizedRowsAndGroupMembers() {
        let matching = makeRoot(id: "matching",
                                threadID: "conversation-a",
                                subject: "Deployment handoff",
                                date: 200)
        let nonMatching = makeRoot(id: "other",
                                   threadID: "conversation-b",
                                   subject: "Budget review",
                                   date: 100)
        let folder = ThreadFolder(id: "folder",
                                  title: "Operations",
                                  color: .defaultNewFolder,
                                  threadIDs: ["conversation-a", "conversation-b"],
                                  parentID: nil)

        let projection = OrganizerProjection.make(roots: [nonMatching, matching],
                                                   folders: [folder],
                                                   query: "deployment")

        XCTAssertTrue(projection.unorganized.isEmpty)
        XCTAssertEqual(projection.confirmedGroups.first?.conversationIDs, ["conversation-a"])
        XCTAssertEqual(projection.visibleConversations.map(\.id), ["conversation-a"])
    }

    func test_projection_ownsSearchAcrossRawScopedRoots() {
        let matching = makeRoot(id: "account-match",
                                threadID: "conversation-a",
                                subject: "Quarterly review",
                                date: 200,
                                accountName: "Synthetic Benchmark")
        let nonMatching = makeRoot(id: "other",
                                   threadID: "conversation-b",
                                   subject: "Budget review",
                                   date: 100)

        let projection = OrganizerProjection.make(
            roots: [nonMatching, matching],
            query: "synthetic benchmark"
        )

        XCTAssertEqual(projection.unorganized.map(\.id), ["conversation-a"])
        XCTAssertEqual(projection.normalizedQuery, "synthetic benchmark")
    }

    func test_projectionSelectionNormalizerUsesTheSameManualGroupSnapshot() {
        let reply = makeRoot(id: "reply-a",
                             threadID: "automatic-a",
                             subject: "Re: Deployment handoff",
                             date: 100)
        var root = makeRoot(id: "message-a",
                            threadID: "automatic-a",
                            subject: "Deployment handoff",
                            date: 200)
        root.children = [reply]
        let oldProjection = OrganizerProjection.make(
            roots: [root],
            manualGroupByMessageKey: [root.message.threadKey: "manual-old"]
        )
        let newProjection = OrganizerProjection.make(
            roots: [root],
            manualGroupByMessageKey: [root.message.threadKey: "manual-new"]
        )

        XCTAssertEqual(oldProjection.visibleConversations.map(\.id), ["manual-old"])
        XCTAssertEqual(newProjection.visibleConversations.map(\.id), ["manual-new"])
        XCTAssertEqual(newProjection.selectionNormalizer.normalize(root.id), "manual-new")
        XCTAssertEqual(newProjection.selectionNormalizer.graphConversationID(from: root.id),
                       "manual-new")
        XCTAssertEqual(newProjection.selectionNormalizer.graphConversationID(
            from: GraphData.messageNodeID(for: reply.id)
        ), "manual-new")
        XCTAssertNil(newProjection.selectionNormalizer.normalize("manual-old"))
    }

    func test_workspaceSourceCarriesPublishedPayloadsIntoProjectionAndSelection() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("BetterMail/Sources/UI/OrganizerWorkspaceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(".onReceive(threadViewModel.$searchQuery) { query in"))
        XCTAssertTrue(source.contains("refreshProjectionAndSelection(query: query)"))
        XCTAssertTrue(source.contains("roots: roots ?? threadViewModel.roots"))
        XCTAssertTrue(source.contains(".onReceive(threadViewModel.$selectedNodeIDs) { selectedNodeIDs in"))
        XCTAssertTrue(source.contains("reconcileSelection(selectedNodeIDs: selectedNodeIDs)"))
        XCTAssertTrue(source.contains("let normalizer = currentProjection.selectionNormalizer"))
        XCTAssertFalse(source.contains("roots: threadViewModel.filteredRoots"))
    }

    func test_groupTitleSearchRevealsAllMembersWhileMemberSearchNarrowsMembers() {
        let deployment = makeRoot(id: "deployment",
                                  threadID: "conversation-a",
                                  subject: "Deployment handoff",
                                  date: 200)
        let budget = makeRoot(id: "budget",
                              threadID: "conversation-b",
                              subject: "Budget review",
                              date: 100)
        let folder = ThreadFolder(id: "folder",
                                  title: "Operations",
                                  color: .defaultNewFolder,
                                  threadIDs: ["conversation-a", "conversation-b"],
                                  parentID: nil)

        let titleMatch = OrganizerProjection.make(roots: [deployment, budget],
                                                  folders: [folder],
                                                  query: "operations")
        let memberMatch = OrganizerProjection.make(roots: [deployment, budget],
                                                   folders: [folder],
                                                   query: "deployment")

        XCTAssertEqual(titleMatch.confirmedGroups.first?.conversationIDs,
                       ["conversation-a", "conversation-b"])
        XCTAssertEqual(titleMatch.visibleConversations.map(\.id),
                       ["conversation-a", "conversation-b"])
        XCTAssertEqual(memberMatch.confirmedGroups.first?.conversationIDs,
                       ["conversation-a"])
        XCTAssertEqual(memberMatch.visibleConversations.map(\.id), ["conversation-a"])
    }

    func test_effectiveConversationIDUsesManualThenJWZThenMessageThenNodePrecedence() {
        let manual = makeRoot(id: "manual-node", threadID: "message-thread", subject: "Manual", date: 100)
        let jwz = makeRoot(id: "jwz-node", threadID: "message-thread", subject: "JWZ", date: 90)
        let message = makeRoot(id: "message-node", threadID: "message-thread", subject: "Message", date: 80)
        let fallback = makeRoot(id: "fallback-node", threadID: "", subject: "Fallback", date: 70)

        XCTAssertEqual(OrganizerProjection.effectiveConversationID(
            for: manual,
            manualGroupByMessageKey: [manual.message.threadKey: "manual-id"],
            jwzThreadMap: [manual.message.threadKey: "jwz-id"]
        ), "manual-id")
        XCTAssertEqual(OrganizerProjection.effectiveConversationID(
            for: jwz,
            jwzThreadMap: [jwz.message.threadKey: "jwz-id"]
        ), "jwz-id")
        XCTAssertEqual(OrganizerProjection.effectiveConversationID(for: message), "message-thread")
        XCTAssertEqual(OrganizerProjection.effectiveConversationID(for: fallback), "fallback-node")
    }

    func test_selectionControllerUsesRailFirstFocusOrderAndCommandToggle() {
        let order = OrganizerSelectionController.focusOrder(
            railConversationIDs: ["a", "b", "a"],
            graphConversationIDs: ["b", "c"]
        )
        var controller = OrganizerSelectionController(focusOrder: order)

        controller = controller.selectingConversation(id: "b", command: false)
        XCTAssertEqual(controller.selectedConversationIDs, ["b"])
        XCTAssertEqual(controller.rangeAnchorID, "b")

        controller = controller.selectingConversation(id: "c", command: true)
        XCTAssertEqual(controller.selectedConversationIDs, ["b", "c"])
        XCTAssertEqual(controller.selectedCount, 2)

        controller = controller.selectingConversation(id: "b", command: true)
        XCTAssertEqual(controller.selectedConversationIDs, ["c"])
        XCTAssertEqual(controller.focusID, "b")
    }

    func test_selectionControllerExtendsInclusiveDeterministicRange() {
        var controller = OrganizerSelectionController(
            focusOrder: ["conversation-a", "conversation-b", "conversation-c", "conversation-d"]
        )
        controller = controller.selectingConversation(id: "conversation-b", command: false)
        controller = controller.selectingRange(to: "conversation-d")

        XCTAssertEqual(controller.selectedIDsInFocusOrder,
                       ["conversation-b", "conversation-c", "conversation-d"])
        XCTAssertEqual(controller.rangeAnchorID, "conversation-b")
        XCTAssertEqual(controller.focusID, "conversation-d")
    }

    func test_selectionControllerNormalizesGraphNodesAndAppliesLasso() {
        let normalizer = OrganizerSelectionController.Normalizer(
            validConversationIDs: ["conversation-a", "conversation-b"],
            graphNodeToConversationID: [
                "thread:raw-a": "conversation-a",
                "message:reply-b": "conversation-b"
            ]
        )
        var controller = OrganizerSelectionController(focusOrder: ["conversation-a", "conversation-b"])
        controller = controller.applyingLassoGraphNodeIDs(
            ["message:reply-b", "thread:raw-a", "folder:confirmed"],
            normalizingWith: normalizer,
            focusGraphNodeID: "message:reply-b"
        )

        XCTAssertEqual(controller.selectedIDsInFocusOrder,
                       ["conversation-a", "conversation-b"])
        XCTAssertEqual(controller.focusID, "conversation-b")
        XCTAssertNil(normalizer.graphConversationID(from: "folder:confirmed"))
    }

    func test_selectionControllerCommandLassoAddsWithoutDroppingExistingSelection() {
        let normalizer = OrganizerSelectionController.Normalizer(
            validConversationIDs: ["conversation-a", "conversation-b", "conversation-c"],
            graphNodeToConversationID: [
                "thread:raw-b": "conversation-b",
                "thread:raw-c": "conversation-c"
            ]
        )
        var controller = OrganizerSelectionController(focusOrder: [
            "conversation-a", "conversation-b", "conversation-c"
        ])
        controller = controller.selectingConversation(id: "conversation-a", command: false)
        controller = controller.applyingLassoGraphNodeIDs(
            ["thread:raw-b", "thread:raw-c"],
            normalizingWith: normalizer,
            focusGraphNodeID: "thread:raw-c",
            additive: true
        )

        XCTAssertEqual(controller.selectedIDsInFocusOrder,
                       ["conversation-a", "conversation-b", "conversation-c"])
        XCTAssertEqual(controller.focusID, "conversation-c")
    }

    func test_selectionControllerReconcilesStaleSelectionAndAnchor() {
        var controller = OrganizerSelectionController(focusOrder: ["a", "b", "c"])
        controller = controller.selectingConversation(id: "a", command: false)
        controller = controller.selectingConversation(id: "b", command: true)
        controller = controller.reconciled(availableConversationIDs: ["b", "c"],
                                           focusOrder: ["c", "b"])

        XCTAssertEqual(controller.selectedConversationIDs, ["b"])
        XCTAssertEqual(controller.selectedCount, 1)
        XCTAssertEqual(controller.focusID, "b")
        XCTAssertEqual(controller.rangeAnchorID, "b")
        XCTAssertEqual(controller.focusOrder, ["c", "b"])
    }
}

private func makeRoot(id: String,
                      threadID: String,
                      subject: String,
                      date: TimeInterval,
                      accountName: String = "account@example.com") -> ThreadNode {
    ThreadNode(message: EmailMessage(messageID: id,
                                     mailboxID: "INBOX",
                                     accountName: accountName,
                                     subject: subject,
                                     from: "sender@example.com",
                                     to: "recipient@example.com",
                                     date: Date(timeIntervalSinceReferenceDate: date),
                                     snippet: "Snippet for \(subject)",
                                     isUnread: false,
                                     inReplyTo: nil,
                                     references: [],
                                     threadID: threadID))
}

private func makeSuggestion(id: String,
                            title: String,
                            rawThreadIDs: [String],
                            supportingReason: String = "Shared rollout language") -> GraphGrouping {
    let members = rawThreadIDs.map { rawThreadID in
        GraphTopicMember(rawThreadID: rawThreadID,
                         graphThreadID: "thread:\(rawThreadID)",
                         fullTitle: title,
                         existingFolderID: nil,
                         existingFolderTitle: nil)
    }
    return GraphGrouping(id: id,
                         title: title,
                         kind: .suggestedTopic,
                         threadIDs: members.map(\.graphThreadID),
                         rawThreadIDs: rawThreadIDs,
                         sourceFolderID: nil,
                         sourceTag: nil,
                         normalizedTopic: title,
                         supportingReason: supportingReason,
                         reviewMembers: members)
}
