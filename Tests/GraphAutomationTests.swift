import CoreData
import XCTest
@testable import BetterMail

@MainActor
final class GraphAutomationTests: XCTestCase {
    func testSettings_defaultsToAutomaticConservativeAndLockedThresholds() {
        let defaults = makeDefaults()
        let settings = GraphAutomationSettings(userDefaults: defaults)

        XCTAssertFalse(settings.isPaused)
        XCTAssertEqual(settings.attachMode, .automatic)
        XCTAssertEqual(settings.appendMode, .automatic)
        XCTAssertEqual(settings.attachStrictness, .conservative)
        XCTAssertEqual(settings.appendStrictness, .conservative)
        XCTAssertTrue(settings.followsFolderMailboxMapping)
        XCTAssertEqual(GraphAutomationStrictness.conservative.thresholds,
                       GraphAutomationThresholds(autoAttach: 0.94,
                                                 autoFolder: 0.90,
                                                 reviewFloor: 0.78,
                                                 winnerMargin: 0.10))
        XCTAssertEqual(GraphAutomationStrictness.balanced.thresholds,
                       GraphAutomationThresholds(autoAttach: 0.90,
                                                 autoFolder: 0.85,
                                                 reviewFloor: 0.70,
                                                 winnerMargin: 0.08))
        XCTAssertEqual(GraphAutomationStrictness.aggressive.thresholds,
                       GraphAutomationThresholds(autoAttach: 0.85,
                                                 autoFolder: 0.80,
                                                 reviewFloor: 0.62,
                                                 winnerMargin: 0.05))
    }

    func testScorer_sameConcreteActionCanClearConservativeAttachThreshold() {
        let signal = GraphAutomationRelationshipSignal(
            relationship: .sameConversation,
            confidence: 0.99,
            sharedAnchors: ["IBM Consulting Advantage", "Pru Feedback Loop"],
            hasSharedNamedTopic: true,
            hasSameConcreteActionOrEvent: true,
            reason: "The invitations name the same team and join action."
        )

        let score = GraphAutomationScorer.score(
            signal: signal,
            sourceText: "Invite Anthony to join the Pru Feedback Loop team on IBM Consulting Advantage",
            targetText: "Invite Angus to join the Pru Feedback Loop team on IBM Consulting Advantage"
        )

        XCTAssertGreaterThanOrEqual(score.score,
                                    GraphAutomationStrictness.conservative.thresholds.autoAttach)
        XCTAssertEqual(score.subjectSimilarity, 1)
        XCTAssertEqual(score.anchorOverlap, 1)
    }

    func testMasterPauseSkipsAndCancelsSemanticEvaluation() async {
        let defaults = makeDefaults()
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = GraphAutomationSettings(userDefaults: defaults)
        settings.isPaused = true
        let relationshipProvider = CountingUnrelatedRelationshipProvider()
        let topicProvider = CountingTopicProvider()
        let coordinator = GraphAutomationCoordinator(
            store: store,
            settings: settings,
            relationshipCapabilityProvider: {
                GraphRelationshipCapability(provider: relationshipProvider,
                                            providerVersion: "pause-test-v1",
                                            statusMessage: "Ready",
                                            shouldRetry: false)
            },
            topicCapabilityProvider: {
                GraphTopicCapability(provider: topicProvider,
                                     statusMessage: "Ready",
                                     providerID: "pause-topic-v1",
                                     shouldRetry: false)
            }
        )
        let snapshot = makeSnapshot(
            roots: [makeRoot(threadID: "paused-source",
                             messageID: "paused@example.com",
                             subject: "IBM Consulting Advantage invitation",
                             date: Date(timeIntervalSince1970: 100))],
            folders: []
        )

        await coordinator.evaluateNow(snapshot: snapshot, scansCurrentMail: true)

        let relationshipCalls = await relationshipProvider.callCount()
        let topicCalls = await topicProvider.callCount()
        XCTAssertEqual(relationshipCalls, 0)
        XCTAssertEqual(topicCalls, 0)
        XCTAssertTrue(coordinator.providerStatusMessage.localizedCaseInsensitiveContains("paused"))
    }

    func testShortlistBoundsModelCallsBeforeRelationshipComparison() async throws {
        let defaults = makeDefaults()
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = GraphAutomationSettings(userDefaults: defaults)
        settings.attachMode = .review
        settings.appendMode = .review
        let relationshipProvider = CountingUnrelatedRelationshipProvider()
        let coordinator = makeCoordinator(store: store,
                                          settings: settings,
                                          relationshipProvider: relationshipProvider)
        let target = makeRoot(threadID: "thread-established",
                              messageID: "established@example.com",
                              subject: "Join the Pru Feedback Loop team on IBM Consulting Advantage",
                              date: Date(timeIntervalSince1970: 100))
        let source = makeRoot(threadID: "thread-new-invite",
                              messageID: "invite@example.com",
                              subject: "Invite Angus to the Pru Feedback Loop on IBM Consulting Advantage",
                              date: Date(timeIntervalSince1970: 200))
        let unrelatedSubjects = [
            "Falcon budget approval", "Orchid deployment window", "Nimbus staffing forecast",
            "Quartz access audit", "Saffron venue booking", "Tundra equipment inventory",
            "Violet training roster", "Willow contract renewal", "Zephyr security patch",
            "Harbor catering quote", "Lantern office relocation", "Meadow benefits briefing"
        ]
        let unrelated = unrelatedSubjects.enumerated().map { index, subject in
            makeRoot(threadID: "unrelated-\(index)",
                     messageID: "unrelated-\(index)@example.com",
                     subject: subject,
                     date: Date(timeIntervalSince1970: Double(300 + index)))
        }
        let folder = makeFolder(threadIDs: ["thread-established"])
        try await store.upsertThreadFolders([folder])
        let snapshot = makeSnapshot(roots: [target, source] + unrelated, folders: [folder])

        await coordinator.evaluateNow(snapshot: snapshot, scansCurrentMail: false)
        await coordinator.evaluateNow(snapshot: snapshot, scansCurrentMail: true)

        let relationshipCalls = await relationshipProvider.callCount()
        XCTAssertLessThanOrEqual(relationshipCalls, 2,
                                 "Unrelated roots must be discarded before on-device model calls")
    }

    func testIBMConsultingAdvantage_scanAttachesInvitationsAndAppendsTopicThread() async throws {
        let defaults = makeDefaults()
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = GraphAutomationSettings(userDefaults: defaults)
        let relationshipProvider = IBMRelationshipProvider()
        let topicProvider = CountingTopicProvider()
        let coordinator = GraphAutomationCoordinator(
            store: store,
            settings: settings,
            relationshipCapabilityProvider: {
                GraphRelationshipCapability(provider: relationshipProvider,
                                            providerVersion: "ibm-test-v1",
                                            statusMessage: "Ready",
                                            shouldRetry: false)
            },
            topicCapabilityProvider: {
                GraphTopicCapability(provider: topicProvider,
                                     statusMessage: "Ready",
                                     providerID: "topic-test-v1",
                                     shouldRetry: false)
            }
        )
        let roots = [
            makeRoot(threadID: "thread-established",
                     messageID: "established@example.com",
                     subject: "Join the Pru Feedback Loop team on IBM Consulting Advantage",
                     date: Date(timeIntervalSince1970: 100)),
            makeRoot(threadID: "thread-angus",
                     messageID: "angus@example.com",
                     subject: "Invites Angus Lo to join the Pru Feedback Loop team on IBM Consulting Advantage",
                     date: Date(timeIntervalSince1970: 200)),
            makeRoot(threadID: "thread-anthony",
                     messageID: "anthony@example.com",
                     subject: "Invites Anthony Liu to join the Pru Feedback Loop team on IBM Consulting Advantage",
                     date: Date(timeIntervalSince1970: 300)),
            makeRoot(threadID: "thread-roadmap",
                     messageID: "roadmap@example.com",
                     subject: "IBM Consulting Advantage quarterly roadmap",
                     date: Date(timeIntervalSince1970: 400))
        ]
        let folder = makeFolder(threadIDs: ["thread-established"])
        try await store.upsertThreadFolders([folder])
        let snapshot = makeSnapshot(roots: roots, folders: [folder])

        await coordinator.evaluateNow(snapshot: snapshot, scansCurrentMail: false)
        XCTAssertTrue(coordinator.proposals.isEmpty, "First refresh must establish a baseline only")
        let firstTopicCallCount = await topicProvider.callCount()
        XCTAssertEqual(firstTopicCallCount, roots.count)

        await coordinator.evaluateNow(snapshot: snapshot, scansCurrentMail: true)

        let applied = coordinator.proposals.filter { $0.status == .applied }
        XCTAssertEqual(applied.filter { $0.action == .attachToThread }.count, 2)
        XCTAssertEqual(applied.filter { $0.action == .appendToFolder }.count, 1)
        let secondTopicCallCount = await topicProvider.callCount()
        XCTAssertEqual(secondTopicCallCount, firstTopicCallCount,
                       "Whole-conversation topic signals should be reused from cache")

        let groups = try await store.fetchManualThreadGroups()
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertTrue(group.jwzThreadIDs.contains("thread-established"))
        XCTAssertEqual(group.manualMessageKeys.count, 2,
                       "Each isolated invitation is attached as one manual message")

        let restoredFolders = try await store.fetchThreadFolders()
        let persistedFolder = try XCTUnwrap(restoredFolders.first)
        XCTAssertEqual(persistedFolder.id, folder.id)
        XCTAssertEqual(persistedFolder.title, folder.title)
        XCTAssertEqual(persistedFolder.color, folder.color)
        XCTAssertEqual(persistedFolder.parentID, folder.parentID)
        XCTAssertTrue(persistedFolder.threadIDs.contains(group.id))
        XCTAssertTrue(persistedFolder.threadIDs.contains("thread-roadmap"),
                      "Same-topic mail remains a separate thread in the confirmed folder")
        XCTAssertFalse(persistedFolder.threadIDs.contains("thread-established"))
    }

    func testExactRejectionSuppressesOnlyUnchangedEvidence() async throws {
        let defaults = makeDefaults()
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = GraphAutomationSettings(userDefaults: defaults)
        settings.attachMode = .review
        settings.appendMode = .off
        let relationshipProvider = IBMRelationshipProvider()
        let coordinator = makeCoordinator(store: store,
                                          settings: settings,
                                          relationshipProvider: relationshipProvider)
        let target = makeRoot(threadID: "thread-established",
                              messageID: "established@example.com",
                              subject: "Join the Pru Feedback Loop team on IBM Consulting Advantage",
                              date: Date(timeIntervalSince1970: 100))
        let source = makeRoot(threadID: "thread-invite",
                              messageID: "invite@example.com",
                              subject: "Invite Yi Ying Zhu to join the Pru Feedback Loop team on IBM Consulting Advantage",
                              date: Date(timeIntervalSince1970: 200))
        let folder = makeFolder(threadIDs: ["thread-established"])
        try await store.upsertThreadFolders([folder])
        let snapshot = makeSnapshot(roots: [target, source], folders: [folder])

        await coordinator.evaluateNow(snapshot: snapshot, scansCurrentMail: false)
        await coordinator.evaluateNow(snapshot: snapshot, scansCurrentMail: true)
        let original = try XCTUnwrap(coordinator.pendingProposals.first)
        await coordinator.reject(ids: [original.id])
        await coordinator.evaluateNow(snapshot: snapshot, scansCurrentMail: true)
        XCTAssertEqual(coordinator.proposals.filter { $0.id == original.id }.map(\.status), [.rejected])

        let changedSource = makeRoot(threadID: "thread-invite",
                                     messageID: "invite@example.com",
                                     subject: "Updated: Invite Yi Ying Zhu to join the Pru Feedback Loop team on IBM Consulting Advantage",
                                     date: Date(timeIntervalSince1970: 201))
        let changedSnapshot = makeSnapshot(roots: [target, changedSource], folders: [folder])
        await coordinator.evaluateNow(snapshot: changedSnapshot, scansCurrentMail: true)

        XCTAssertTrue(coordinator.proposals.contains { $0.status == .rejected && $0.id == original.id })
        XCTAssertTrue(coordinator.proposals.contains {
            $0.status == .pendingReview && $0.id != original.id && $0.source.effectiveThreadID == "thread-invite"
        })
    }

    func testBatchAttachTreatsJWZBranchAndStandaloneAsIndivisibleSources() async throws {
        let store = MessageStore(userDefaults: makeDefaults(), storeType: NSInMemoryStoreType)
        let folder = makeFolder(threadIDs: ["target-thread"])
        try await store.upsertThreadFolders([folder])
        let branch = makeSource(threadID: "branch-source",
                                jwzThreadIDs: ["jwz-a", "jwz-b"],
                                manualMessageKeys: [])
        let standalone = makeSource(threadID: "standalone-source",
                                    jwzThreadIDs: [],
                                    manualMessageKeys: ["standalone-key"])
        let resultID = "manual-auto-target"
        let branchProposal = makeAttachProposal(id: "a-branch",
                                                source: branch,
                                                targetThreadID: "target-thread",
                                                resultThreadID: resultID,
                                                folder: folder)
        let standaloneProposal = makeAttachProposal(id: "b-standalone",
                                                    source: standalone,
                                                    targetThreadID: "target-thread",
                                                    resultThreadID: resultID,
                                                    folder: folder)

        let result = try await store.applyGraphAutomationBatch([standaloneProposal, branchProposal])

        let group = try XCTUnwrap(result.manualGroups.first { $0.id == resultID })
        XCTAssertTrue(["target-thread", "jwz-a", "jwz-b"].allSatisfy(group.jwzThreadIDs.contains))
        XCTAssertEqual(group.manualMessageKeys, ["standalone-key"])
        let persistedFolder = try XCTUnwrap(result.folders.first { $0.id == folder.id })
        XCTAssertEqual(persistedFolder.threadIDs, [resultID])
    }

    func testReviewedManualGroupMergeAndUndoRestoresExactGroups() async throws {
        let store = MessageStore(userDefaults: makeDefaults(), storeType: NSInMemoryStoreType)
        let sourceGroup = ManualThreadGroup(id: "manual-source",
                                            jwzThreadIDs: ["source-jwz"],
                                            manualMessageKeys: ["source-message"])
        let targetGroup = ManualThreadGroup(id: "manual-target",
                                            jwzThreadIDs: ["target-jwz"],
                                            manualMessageKeys: [])
        try await store.upsertManualThreadGroups([sourceGroup, targetGroup])
        let folder = makeFolder(threadIDs: [targetGroup.id])
        try await store.upsertThreadFolders([folder])
        let source = makeSource(threadID: sourceGroup.id,
                                manualGroupID: sourceGroup.id,
                                jwzThreadIDs: sourceGroup.jwzThreadIDs,
                                manualMessageKeys: sourceGroup.manualMessageKeys)
        let proposal = makeAttachProposal(id: "manual-merge",
                                          source: source,
                                          targetThreadID: targetGroup.id,
                                          resultThreadID: targetGroup.id,
                                          folder: folder,
                                          manualMergeConflict: true)

        let applied = try await store.applyGraphAutomationBatch([proposal])
        XCTAssertNil(applied.manualGroups.first { $0.id == sourceGroup.id })
        let merged = try XCTUnwrap(applied.manualGroups.first { $0.id == targetGroup.id })
        XCTAssertTrue(merged.jwzThreadIDs.isSuperset(of: sourceGroup.jwzThreadIDs))
        XCTAssertEqual(applied.proposals.first?.mutationDelta?.removedSourceManualGroup, sourceGroup)

        let undo = try await store.undoGraphAutomationMembership(try XCTUnwrap(applied.proposals.first))
        XCTAssertEqual(Set(undo.manualGroups), [sourceGroup, targetGroup])
        XCTAssertEqual(undo.folders.first?.threadIDs, [targetGroup.id])
    }

    func testBatchPersistenceFailureRollsBackEarlierValidRows() async throws {
        let store = MessageStore(userDefaults: makeDefaults(), storeType: NSInMemoryStoreType)
        let folder = makeFolder(threadIDs: ["existing"])
        try await store.upsertThreadFolders([folder])
        let valid = makeAppendProposal(id: "a-valid",
                                       source: makeSource(threadID: "valid-source"),
                                       folder: folder)
        let missingFolder = ThreadFolder(id: "missing",
                                         title: "Missing",
                                         color: .defaultNewFolder,
                                         threadIDs: [],
                                         parentID: nil)
        let invalid = makeAppendProposal(id: "b-invalid",
                                         source: makeSource(threadID: "invalid-source"),
                                         folder: missingFolder)

        do {
            _ = try await store.applyGraphAutomationBatch([valid, invalid])
            XCTFail("Expected the atomic batch to fail")
        } catch GraphAutomationPersistenceError.missingTargetFolder {
            // Expected.
        }

        let restoredFolders = try await store.fetchThreadFolders()
        let restoredGroups = try await store.fetchManualThreadGroups()
        XCTAssertEqual(restoredFolders.first?.threadIDs, ["existing"])
        XCTAssertTrue(restoredGroups.isEmpty)
    }

    func testGraphProjectionAnchorsProposalToConfirmedFolderWithoutDuplicateGhostHub() {
        let established = makeRoot(threadID: "thread-established",
                                   messageID: "established@example.com",
                                   subject: "IBM Consulting Advantage",
                                   date: Date(timeIntervalSince1970: 100))
        let sourceRoot = makeRoot(threadID: "thread-new",
                                  messageID: "new@example.com",
                                  subject: "IBM Consulting Advantage Pru Feedback Loop",
                                  date: Date(timeIntervalSince1970: 200))
        let folder = makeFolder(threadIDs: ["thread-established"])
        let source = makeSource(threadID: "thread-new")
        let proposal = makeAppendProposal(id: "pending-folder", source: source, folder: folder)
        let signal = GraphTopicSignal(topic: "IBM Consulting Advantage",
                                      displayTitle: "IBM Consulting Advantage",
                                      confidence: 0.99,
                                      supportingReason: "Shared named program")

        let graph = GraphData.make(
            roots: [established, sourceRoot],
            topicSignalsByRawThreadID: ["thread-established": signal, "thread-new": signal],
            folders: [folder],
            folderMembershipByThreadID: ["thread-established": folder.id],
            automationProposals: [proposal],
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(graph.groupings.filter { $0.kind == .folder }.map(\.id), ["folder:\(folder.id)"])
        XCTAssertTrue(graph.groupings.filter { $0.kind == .suggestedTopic }.isEmpty)
        XCTAssertTrue(graph.edges.contains {
            $0.kind == .suggested &&
                $0.sourceID == "folder:\(folder.id)" &&
                $0.targetID == GraphData.threadNodeID(for: "thread-new")
        })
    }

    func testMappedMailPartialMoveWithIncompleteCompensationRequiresRecovery() async throws {
        let defaults = makeDefaults()
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let mover = ScriptedAutomationMailMover(responses: [.moved(["source-1@example.com"]), .moved([])])
        let coordinator = makeCoordinator(store: store,
                                          settings: GraphAutomationSettings(userDefaults: defaults),
                                          relationshipProvider: IBMRelationshipProvider(),
                                          mailClient: mover)
        let target = makeRoot(threadID: "target-thread",
                              messageID: "target@example.com",
                              subject: "Join the Pru Feedback Loop team on IBM Consulting Advantage",
                              date: Date(timeIntervalSince1970: 100))
        let child = makeMessage(messageID: "source-2@example.com",
                                threadID: "source-thread",
                                subject: "Invite two",
                                date: Date(timeIntervalSince1970: 210))
        let source = ThreadNode(
            message: makeMessage(messageID: "source-1@example.com",
                                 threadID: "source-thread",
                                 subject: "Invite Angus to join the Pru Feedback Loop team on IBM Consulting Advantage",
                                 date: Date(timeIntervalSince1970: 200)),
            children: [ThreadNode(message: child)]
        )
        let folder = makeFolder(threadIDs: ["target-thread"],
                                mailboxAccount: "Work",
                                mailboxPath: "Projects/IBM Consulting Advantage")
        try await store.upsertThreadFolders([folder])
        let snapshot = makeSnapshot(roots: [target, source], folders: [folder])

        await coordinator.evaluateNow(snapshot: snapshot, scansCurrentMail: false)
        await coordinator.evaluateNow(snapshot: snapshot, scansCurrentMail: true)

        let proposal = try XCTUnwrap(coordinator.proposals.first { $0.source.effectiveThreadID == "source-thread" })
        XCTAssertEqual(proposal.status, .recoveryNeeded)
        XCTAssertEqual(proposal.mailStatus, .recoveryNeeded)
        XCTAssertEqual(proposal.movedMessages.map(\.messageID), ["source-1@example.com"])
        let moveCalls = await mover.calls()
        XCTAssertEqual(moveCalls.count, 2,
                       "A partial move must immediately attempt exact-route compensation once")
        XCTAssertNotNil(proposal.mutationDelta,
                        "Mail failure must retain the committed BetterMail grouping")
    }
}

private extension GraphAutomationTests {
    func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "GraphAutomationTests-\(UUID().uuidString)")!
    }

    func makeCoordinator(store: MessageStore,
                         settings: GraphAutomationSettings,
                         relationshipProvider: GraphRelationshipProviding,
                         mailClient: (any GraphSnipMailMoving)? = nil) -> GraphAutomationCoordinator {
        GraphAutomationCoordinator(
            store: store,
            settings: settings,
            mailClient: mailClient,
            relationshipCapabilityProvider: {
                GraphRelationshipCapability(provider: relationshipProvider,
                                            providerVersion: "relationship-test-v1",
                                            statusMessage: "Ready",
                                            shouldRetry: false)
            },
            topicCapabilityProvider: {
                GraphTopicCapability(provider: nil,
                                     statusMessage: "Unavailable",
                                     providerID: "topic-test-v1",
                                     shouldRetry: false)
            }
        )
    }

    func makeSnapshot(roots: [ThreadNode], folders: [ThreadFolder]) -> GraphAutomationSnapshot {
        let map = roots.flatMap(flatten).reduce(into: [String: String]()) { result, node in
            if let threadID = node.message.threadID {
                result[node.message.threadKey] = threadID
            }
        }
        return GraphAutomationSnapshot(scopeID: "account:work",
                                       roots: roots,
                                       folders: folders,
                                       manualGroups: [:],
                                       manualGroupByMessageKey: [:],
                                       manualAttachmentMessageIDs: [],
                                       jwzThreadMap: map,
                                       summariesByNodeID: [:])
    }

    func flatten(_ node: ThreadNode) -> [ThreadNode] {
        [node] + node.children.flatMap(flatten)
    }

    func makeRoot(threadID: String,
                  messageID: String,
                  subject: String,
                  date: Date) -> ThreadNode {
        ThreadNode(message: makeMessage(messageID: messageID,
                                        threadID: threadID,
                                        subject: subject,
                                        date: date))
    }

    func makeMessage(messageID: String,
                     threadID: String,
                     subject: String,
                     date: Date) -> EmailMessage {
        EmailMessage(messageID: messageID,
                     mailboxID: "Inbox",
                     accountName: "Work",
                     subject: subject,
                     from: "sender@example.com",
                     to: "me@example.com",
                     date: date,
                     snippet: subject,
                     isUnread: false,
                     inReplyTo: nil,
                     references: [],
                     threadID: threadID)
    }

    func makeFolder(threadIDs: Set<String>,
                    mailboxAccount: String? = nil,
                    mailboxPath: String? = nil) -> ThreadFolder {
        ThreadFolder(id: "folder-ibm",
                     title: "IBM Consulting Advantage",
                     color: ThreadFolderColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1),
                     threadIDs: threadIDs,
                     parentID: "folder-work",
                     mailboxAccount: mailboxAccount,
                     mailboxPath: mailboxPath)
    }

    func makeSource(threadID: String,
                    manualGroupID: String? = nil,
                    jwzThreadIDs: Set<String> = [],
                    manualMessageKeys: Set<String> = ["message-key"]) -> GraphAutomationSource {
        GraphAutomationSource(rawThreadID: threadID,
                              effectiveThreadID: threadID,
                              manualGroupID: manualGroupID,
                              subject: threadID,
                              summary: "",
                              representativeContent: threadID,
                              accountName: "Work",
                              jwzThreadIDs: jwzThreadIDs,
                              manualMessageKeys: manualMessageKeys,
                              messages: [GraphAutomationMessageSource(messageID: "\(threadID)@example.com",
                                                                      messageKey: "\(threadID)-key",
                                                                      internalMailID: nil,
                                                                      accountName: "Work",
                                                                      mailboxPath: "Inbox",
                                                                      date: Date(timeIntervalSince1970: 100))],
                              fingerprint: GraphAutomationIdentity.make([threadID]))
    }

    func makeAttachProposal(id: String,
                            source: GraphAutomationSource,
                            targetThreadID: String,
                            resultThreadID: String,
                            folder: ThreadFolder,
                            manualMergeConflict: Bool = false) -> GraphAutomationProposal {
        makeProposal(id: id,
                     relationship: .sameConversation,
                     action: .attachToThread,
                     source: source,
                     target: GraphAutomationTarget(threadID: targetThreadID,
                                                   folderID: folder.id,
                                                   title: "Target",
                                                   accountName: "Work",
                                                   fingerprint: GraphAutomationIdentity.make([targetThreadID, folder.id])),
                     steps: [.attach(sourceThreadID: source.effectiveThreadID,
                                     targetThreadID: targetThreadID,
                                     resultingThreadID: resultThreadID),
                             .append(threadID: resultThreadID, folderID: folder.id)],
                     manualMergeConflict: manualMergeConflict)
    }

    func makeAppendProposal(id: String,
                            source: GraphAutomationSource,
                            folder: ThreadFolder) -> GraphAutomationProposal {
        makeProposal(id: id,
                     relationship: .sameTopic,
                     action: .appendToFolder,
                     source: source,
                     target: GraphAutomationTarget(threadID: nil,
                                                   folderID: folder.id,
                                                   title: folder.title,
                                                   accountName: folder.mailboxAccount,
                                                   fingerprint: GraphAutomationIdentity.make([folder.id])),
                     steps: [.append(threadID: source.effectiveThreadID, folderID: folder.id)])
    }

    func makeProposal(id: String,
                      relationship: GraphAutomationRelationship,
                      action: GraphAutomationAction,
                      source: GraphAutomationSource,
                      target: GraphAutomationTarget,
                      steps: [GraphAutomationStep],
                      manualMergeConflict: Bool = false) -> GraphAutomationProposal {
        GraphAutomationProposal(id: id,
                                providerVersion: "test-v1",
                                relationship: relationship,
                                action: action,
                                source: source,
                                target: target,
                                score: 0.99,
                                relationshipConfidence: 0.99,
                                sharedAnchors: ["IBM Consulting Advantage"],
                                subjectActionSimilarity: 1,
                                reason: "Test relationship",
                                isAmbiguous: false,
                                hasExistingFolderConflict: false,
                                hasManualGroupMergeConflict: manualMergeConflict,
                                steps: steps,
                                status: .pendingReview,
                                mailStatus: .notRequired,
                                retryCount: 0,
                                nextRetryAt: nil,
                                lastError: nil,
                                mutationDelta: nil,
                                movedMessages: [],
                                createdAt: Date(timeIntervalSince1970: 1),
                                updatedAt: Date(timeIntervalSince1970: 1))
    }
}

private struct IBMRelationshipProvider: GraphRelationshipProviding {
    func relationship(for request: GraphAutomationRelationshipRequest) async throws -> GraphAutomationRelationshipSignal {
        let isRoadmap = request.sourceSubject.localizedCaseInsensitiveContains("roadmap")
        if isRoadmap || request.targetIsFolderProfile {
            return GraphAutomationRelationshipSignal(
                relationship: .sameTopic,
                confidence: 1,
                sharedAnchors: ["IBM Consulting Advantage"],
                hasSharedNamedTopic: true,
                hasSameConcreteActionOrEvent: false,
                reason: "The mail shares the IBM Consulting Advantage topic."
            )
        }
        return GraphAutomationRelationshipSignal(
            relationship: .sameConversation,
            confidence: 1,
            sharedAnchors: ["IBM Consulting Advantage", "Pru Feedback Loop"],
            hasSharedNamedTopic: true,
            hasSameConcreteActionOrEvent: true,
            reason: "The mail names the same team and join action."
        )
    }
}

private actor CountingUnrelatedRelationshipProvider: GraphRelationshipProviding {
    private var count = 0

    func relationship(for request: GraphAutomationRelationshipRequest) async throws -> GraphAutomationRelationshipSignal {
        count += 1
        return GraphAutomationRelationshipSignal(
            relationship: .unrelated,
            confidence: 0.99,
            sharedAnchors: [],
            hasSharedNamedTopic: false,
            hasSameConcreteActionOrEvent: false,
            reason: "The evidence does not establish a relationship."
        )
    }

    func callCount() -> Int { count }
}

private actor CountingTopicProvider: GraphTopicProviding {
    private var count = 0

    func generateTopic(_ request: GraphTopicRequest) async throws -> GraphTopicSignal? {
        count += 1
        return GraphTopicSignal(topic: "IBM Consulting Advantage",
                                displayTitle: "IBM Consulting Advantage",
                                confidence: 0.99,
                                supportingReason: "Shared named program")
    }

    func callCount() -> Int { count }
}

private actor ScriptedAutomationMailMover: GraphSnipMailMoving {
    enum Response: Sendable {
        case moved([String])
    }

    struct Call: Sendable {
        let messageIDs: [String]
        let destinationMailboxPath: String
        let account: String?
        let sourceMailboxPath: String?
        let sourceAccount: String?
    }

    private var responses: [Response]
    private var recordedCalls: [Call] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func moveMessages(messageIDs: [String],
                      toMailboxPath mailboxPath: String,
                      account: String?,
                      sourceMailboxPath: String?,
                      sourceAccount: String?) async throws -> GraphMailMoveResult {
        recordedCalls.append(Call(messageIDs: messageIDs,
                                  destinationMailboxPath: mailboxPath,
                                  account: account,
                                  sourceMailboxPath: sourceMailboxPath,
                                  sourceAccount: sourceAccount))
        guard !responses.isEmpty else { return GraphMailMoveResult(movedMessageIDs: []) }
        switch responses.removeFirst() {
        case .moved(let ids):
            return GraphMailMoveResult(movedMessageIDs: ids)
        }
    }

    func calls() -> [Call] { recordedCalls }
}
