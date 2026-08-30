import CoreData
import CoreGraphics
import Foundation
import SpriteKit
import XCTest
@testable import BetterMail

@MainActor
final class GraphSpatialIntegrationTests: XCTestCase {
    func testViewModel_scenePositionReportsCoalesceUntilSettled_withoutRepublishing() async throws {
        GraphSpatialSceneBridge.clear()
        defer { GraphSpatialSceneBridge.clear() }
        let fileAccessor = IntegrationGraphSpatialFileAccessor()
        let spatialStore = GraphSpatialStateStore(
            fileAccessor: fileAccessor,
            secretProvider: IntegrationGraphSpatialSecretProvider()
        )
        let suiteName = "GraphSpatialNoOp-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let messageStore = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let folder = ThreadFolder(id: "folder-work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: ["root"],
                                  parentID: nil)
        let root = spatialFixtureThread(rootID: "root", messageCount: 1)
        let viewModel = GraphCanvasViewModel(store: messageStore,
                                             graphSpatialStore: spatialStore)

        viewModel.update(roots: [root],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: [:],
                         folders: [folder],
                         folderMembershipByThreadID: ["root": folder.id],
                         mailboxScopeID: "mailbox:work|inbox")
        await viewModel.awaitSpatialStateLoadForTesting()
        GraphSpatialSceneBridge.clear()

        let positions = [
            GraphData.threadNodeID(for: "root"): CGPoint(x: 120, y: 80),
            "folder:\(folder.id)": CGPoint(x: 420, y: 260)
        ]
        viewModel.recordSceneNodePositions(positions, isSettled: false)
        XCTAssertTrue(viewModel.nodePositions.isEmpty)
        XCTAssertNil(GraphSpatialSceneBridge.consume(for: viewModel.data))

        viewModel.recordSceneNodePositions(positions, isSettled: true)
        XCTAssertEqual(viewModel.nodePositions, positions)
        XCTAssertNil(GraphSpatialSceneBridge.consume(for: viewModel.data))
        await viewModel.awaitSpatialStatePersistenceForTesting()

        let restored = await spatialStore.load(
            scopeID: "mailbox:work|inbox",
            sourceNodeIDs: [GraphData.threadNodeID(for: "root")],
            confirmedGroupIDs: [folder.id]
        )
        XCTAssertEqual(restored.nodePositions[GraphData.threadNodeID(for: "root")],
                       GraphSpatialPoint(x: 120, y: 80))
        XCTAssertEqual(restored.confirmedGroupAnchors[folder.id],
                       GraphSpatialPoint(x: 420, y: 260))
    }

    func testViewModel_persistsMergedPositionsViewportAndConfirmedAnchorPerScope() async throws {
        GraphSpatialSceneBridge.clear()
        defer { GraphSpatialSceneBridge.clear() }
        let fileAccessor = IntegrationGraphSpatialFileAccessor()
        let spatialStore = GraphSpatialStateStore(fileAccessor: fileAccessor,
                                                  secretProvider: IntegrationGraphSpatialSecretProvider())
        let suiteName = "GraphSpatialIntegration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let messageStore = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let folder = ThreadFolder(id: "folder-work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: ["root"],
                                  parentID: nil)
        let root = spatialFixtureThread(rootID: "root", messageCount: 2)
        let viewModel = GraphCanvasViewModel(store: messageStore,
                                             graphSpatialStore: spatialStore)

        viewModel.update(roots: [root],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: [:],
                         folders: [folder],
                         folderMembershipByThreadID: ["root": folder.id],
                         mailboxScopeID: "mailbox:work|inbox")
        await viewModel.awaitSpatialStateLoadForTesting()

        let threadID = GraphData.threadNodeID(for: "root")
        let groupNodeID = "folder:\(folder.id)"
        let positions: [String: CGPoint] = [
            threadID: CGPoint(x: 120, y: 80),
            groupNodeID: CGPoint(x: 420, y: 260),
            GraphData.messageNodeID(for: "root-msg-1"): CGPoint(x: 220, y: 160),
            GraphData.messageNodeID(for: "hidden-message"): CGPoint(x: 720, y: 460),
            GraphRemainingBranch.graphID: CGPoint(x: 999, y: 999)
        ]
        viewModel.setNodePositions(positions)
        viewModel.setZoom(1.75)
        viewModel.setPanOffset(CGPoint(x: -80, y: 42))
        viewModel.flushSpatialStatePersistence()
        await viewModel.awaitSpatialStatePersistenceForTesting()

        let restored = await spatialStore.load(
            scopeID: "mailbox:work|inbox",
            sourceNodeIDs: [threadID,
                            GraphData.messageNodeID(for: "root-msg-1"),
                            GraphData.messageNodeID(for: "hidden-message")],
            confirmedGroupIDs: [folder.id]
        )
        XCTAssertEqual(restored.nodePositions[threadID], GraphSpatialPoint(x: 120, y: 80))
        XCTAssertEqual(restored.nodePositions[GraphData.messageNodeID(for: "root-msg-1")],
                       GraphSpatialPoint(x: 220, y: 160))
        XCTAssertEqual(restored.nodePositions[GraphData.messageNodeID(for: "hidden-message")],
                       GraphSpatialPoint(x: 720, y: 460))
        XCTAssertEqual(restored.confirmedGroupAnchors[folder.id], GraphSpatialPoint(x: 420, y: 260))
        XCTAssertEqual(restored.zoomScale, 1.75)
        XCTAssertEqual(restored.panOffset, GraphSpatialPoint(x: -80, y: 42))
        let serializedText = String(data: fileAccessor.data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedText.contains(GraphRemainingBranch.graphID))

        let restoredViewModel = GraphCanvasViewModel(store: messageStore,
                                                      graphSpatialStore: spatialStore)
        restoredViewModel.update(roots: [root],
                                 searchQuery: "",
                                 tagsByNodeID: [:],
                                 summariesByNodeID: [:],
                                 folders: [folder],
                                 folderMembershipByThreadID: ["root": folder.id],
                                 mailboxScopeID: "mailbox:work|inbox")
        await restoredViewModel.awaitSpatialStateLoadForTesting()
        XCTAssertEqual(restoredViewModel.nodePositions[threadID], CGPoint(x: 120, y: 80))
        XCTAssertEqual(restoredViewModel.confirmedGroupAnchors[folder.id],
                       CGPoint(x: 420, y: 260))
        XCTAssertEqual(restoredViewModel.zoomScale, 1.75)
        XCTAssertEqual(restoredViewModel.panOffset, CGPoint(x: -80, y: 42))
    }

    func testViewModel_resetSpatialLayout_canUndoOnlyWithinActiveScopeAndRestoresDurably() async throws {
        GraphSpatialSceneBridge.clear()
        defer { GraphSpatialSceneBridge.clear() }
        let fileAccessor = IntegrationGraphSpatialFileAccessor()
        let spatialStore = GraphSpatialStateStore(fileAccessor: fileAccessor,
                                                  secretProvider: IntegrationGraphSpatialSecretProvider())
        let suiteName = "GraphSpatialResetUndo-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let messageStore = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let root = spatialFixtureThread(rootID: "root", messageCount: 1)
        let viewModel = GraphCanvasViewModel(store: messageStore,
                                             graphSpatialStore: spatialStore)
        let scopeID = "mailbox:work|inbox"
        let threadID = GraphData.threadNodeID(for: "root")

        viewModel.update(roots: [root],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: [:],
                         mailboxScopeID: scopeID)
        await viewModel.awaitSpatialStateLoadForTesting()
        viewModel.setNodePositions([threadID: CGPoint(x: 150, y: 90)])
        viewModel.setZoom(1.6)
        viewModel.setPanOffset(CGPoint(x: -20, y: 35))
        viewModel.flushSpatialStatePersistence()
        await viewModel.awaitSpatialStatePersistenceForTesting()

        viewModel.resetSpatialLayout()
        XCTAssertTrue(viewModel.canUndoSpatialLayoutReset)
        XCTAssertTrue(viewModel.nodePositions.isEmpty)
        XCTAssertEqual(viewModel.zoomScale, 1)
        XCTAssertEqual(viewModel.panOffset, .zero)

        viewModel.recordSceneNodePositions(
            [threadID: CGPoint(x: 20, y: 15)],
            isSettled: true
        )
        XCTAssertTrue(viewModel.canUndoSpatialLayoutReset)

        viewModel.undoSpatialLayoutReset()
        XCTAssertFalse(viewModel.canUndoSpatialLayoutReset)
        XCTAssertEqual(viewModel.nodePositions[threadID], CGPoint(x: 150, y: 90))
        XCTAssertEqual(viewModel.zoomScale, 1.6)
        XCTAssertEqual(viewModel.panOffset, CGPoint(x: -20, y: 35))
        await viewModel.awaitSpatialStatePersistenceForTesting()

        let restored = await spatialStore.load(scopeID: scopeID,
                                                sourceNodeIDs: [threadID],
                                                confirmedGroupIDs: [])
        XCTAssertEqual(restored.nodePositions[threadID], GraphSpatialPoint(x: 150, y: 90))
        XCTAssertEqual(restored.zoomScale, 1.6)
        XCTAssertEqual(restored.panOffset, GraphSpatialPoint(x: -20, y: 35))

        viewModel.resetSpatialLayout()
        viewModel.update(roots: [root],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: [:],
                         mailboxScopeID: "mailbox:personal|inbox")
        XCTAssertFalse(viewModel.canUndoSpatialLayoutReset)
        viewModel.undoSpatialLayoutReset()
        XCTAssertTrue(viewModel.nodePositions.isEmpty)
    }

    func testScene_consumesRestoredNodeAndConfirmedGroupAnchorBeforeRebuild() {
        let folder = ThreadFolder(id: "folder-release",
                                  title: "Release",
                                  color: .defaultNewFolder,
                                  threadIDs: ["root"],
                                  parentID: nil)
        let graph = GraphData.make(
            roots: [spatialFixtureThread(rootID: "root", messageCount: 1)],
            folders: [folder],
            folderMembershipByThreadID: ["root": folder.id],
            now: Date(timeIntervalSince1970: 10_000)
        )
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        let threadID = GraphData.threadNodeID(for: "root")
        let groupNodeID = "folder:\(folder.id)"
        let threadPosition = CGPoint(x: 140, y: 110)
        let groupPosition = CGPoint(x: 510, y: 330)
        GraphSpatialSceneBridge.publish(nodePositions: [threadID: threadPosition],
                                        confirmedGroupAnchors: [folder.id: groupPosition])

        configure(scene, data: graph)

        XCTAssertEqual(scene.position(of: threadID), threadPosition)
        XCTAssertEqual(scene.position(of: groupNodeID), groupPosition)
        GraphSpatialSceneBridge.clear()
    }

    func testScene_emitsSettledPositionReportWithoutChangingExistingDragCallbacks() {
        GraphSpatialSceneBridge.clear()
        let scene = ObsidianGraphScene(size: CGSize(width: 800, height: 600))
        var positionReports = 0
        var settledReports = 0
        scene.onPositionsChanged = { _ in positionReports += 1 }
        scene.onLayoutSettled = { _ in settledReports += 1 }

        configure(scene, data: .empty)
        scene.update(1.0)

        XCTAssertEqual(positionReports, 1)
        XCTAssertEqual(settledReports, 1)
    }

    func testViewModel_replaysResolvedAnchorIntentAndReportsReceiptAfterSpatialWrite() async throws {
        GraphSpatialSceneBridge.clear()
        defer { GraphSpatialSceneBridge.clear() }
        let fileAccessor = IntegrationGraphSpatialFileAccessor()
        let spatialStore = GraphSpatialStateStore(fileAccessor: fileAccessor,
                                                  secretProvider: IntegrationGraphSpatialSecretProvider())
        let suiteName = "GraphSpatialReplay-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let messageStore = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let replayProbe = SpatialReplayProbe()
        let seam = GraphSpatialAnchorReplaySeam(
            pendingIntent: { scopeID in
                replayProbe.notePendingLookup(scopeID: scopeID)
                guard scopeID == "mailbox:work|inbox" else { return nil }
                return GraphSpatialAnchorReplayIntent(intentID: "intent-1",
                                                      groupID: "folder-work",
                                                      x: 300,
                                                      y: 180,
                                                      zoom: 1.4)
            },
            recordReceipt: { receipt in
                replayProbe.set(receipt)
            }
        )
        let viewModel = GraphCanvasViewModel(store: messageStore,
                                             graphSpatialStore: spatialStore,
                                             graphSpatialAnchorReplay: seam)
        let folder = ThreadFolder(id: "folder-work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: ["root"],
                                  parentID: nil)
        viewModel.update(roots: [spatialFixtureThread(rootID: "root", messageCount: 1)],
                         searchQuery: "",
                         tagsByNodeID: [:],
                         summariesByNodeID: [:],
                         folders: [folder],
                         folderMembershipByThreadID: ["root": folder.id],
                         mailboxScopeID: "mailbox:work|inbox")
        await viewModel.awaitSpatialStateLoadForTesting()
        await viewModel.awaitSpatialStatePersistenceForTesting()

        XCTAssertEqual(viewModel.lastSpatialLoadDispositionForTesting, "applied")
        XCTAssertEqual(viewModel.confirmedGroupAnchors[folder.id], CGPoint(x: 300, y: 180))
        XCTAssertEqual(viewModel.zoomScale, 1.4)
        let pendingLookupCount = replayProbe.pendingLookupCount()
        XCTAssertEqual(pendingLookupCount, 1)
        XCTAssertEqual(replayProbe.lastPendingLookupScopeID(), "mailbox:work|inbox")
        XCTAssertEqual(viewModel.lastSpatialReplayIntentIDForTesting, "intent-1")
        XCTAssertEqual(viewModel.lastSpatialReplayAnchorForTesting, CGPoint(x: 300, y: 180))
        let receipt = replayProbe.value()
        XCTAssertEqual(receipt?.intentID, "intent-1")
    }

    func testProductionAnchorReplaySeam_relaunchesPendingCreateAndCompletesReceiptIdempotently() async throws {
        GraphSpatialSceneBridge.clear()
        defer { GraphSpatialSceneBridge.clear() }
        let suiteName = "GraphSpatialProductionReplay-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let messageStore = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let operationStore = makeInMemoryOrganizationOperationStore(label: suiteName)
        let spatialStore = GraphSpatialStateStore(
            fileAccessor: IntegrationGraphSpatialFileAccessor(),
            secretProvider: IntegrationGraphSpatialSecretProvider()
        )
        let threadViewModel = ThreadCanvasViewModel(
            settings: AutoRefreshSettings(userDefaults: defaults),
            inspectorSettings: InspectorViewSettings(userDefaults: defaults),
            pinnedFolderSettings: PinnedFolderSettings(userDefaults: defaults),
            mailboxFolderOrderSettings: MailboxFolderOrderSettings(userDefaults: defaults),
            mailboxThreadAutoMoveSettings: MailboxThreadAutoMoveSettings(userDefaults: defaults),
            store: messageStore,
            organizationOperationStore: operationStore,
            graphAutomationSettings: GraphAutomationSettings(userDefaults: defaults),
            performsInitialSourceRefresh: false
        )
        let scopeID = "mailbox:work|inbox"
        let anchor = CGPoint(x: 312, y: 184)
        let created = try await threadViewModel.createOrganizationGroup(
            title: "Work",
            threadIDs: ["root"],
            scopeID: scopeID,
            anchor: anchor,
            zoom: 1.45
        )
        let groupID = created.mutation.groupID
        XCTAssertEqual(created.operation.phase, .layoutPending)
        let folder = try XCTUnwrap(threadViewModel.threadFolders.first(where: { $0.id == groupID }))
        let root = spatialFixtureThread(rootID: "root", messageCount: 1)

        let firstGraphViewModel = GraphCanvasViewModel(
            store: messageStore,
            organizationOperationStore: operationStore,
            graphSpatialStore: spatialStore,
            graphSpatialAnchorReplay: threadViewModel.makeGraphSpatialAnchorReplaySeam()
        )
        firstGraphViewModel.update(
            roots: [root],
            searchQuery: "",
            tagsByNodeID: [:],
            summariesByNodeID: [:],
            folders: [folder],
            folderMembershipByThreadID: ["root": groupID],
            mailboxScopeID: scopeID
        )
        await firstGraphViewModel.awaitSpatialStateLoadForTesting()
        await firstGraphViewModel.awaitSpatialStatePersistenceForTesting()

        XCTAssertEqual(firstGraphViewModel.confirmedGroupAnchors[groupID], anchor)
        XCTAssertEqual(firstGraphViewModel.zoomScale, 1.45)
        XCTAssertEqual(firstGraphViewModel.lastSpatialReplayIntentIDForTesting,
                       created.operation.spatialAnchorIntent?.intentID)
        let storedCompleted = try await operationStore.operation(id: created.operation.id)
        let completed = try XCTUnwrap(storedCompleted)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertNotNil(completed.spatialAnchorReceipt)
        XCTAssertEqual(completed.receipts.filter { $0.kind == .spatialAnchor }.count, 1)

        let relaunchedGraphViewModel = GraphCanvasViewModel(
            store: messageStore,
            organizationOperationStore: operationStore,
            graphSpatialStore: spatialStore,
            graphSpatialAnchorReplay: threadViewModel.makeGraphSpatialAnchorReplaySeam()
        )
        relaunchedGraphViewModel.update(
            roots: [root],
            searchQuery: "",
            tagsByNodeID: [:],
            summariesByNodeID: [:],
            folders: [folder],
            folderMembershipByThreadID: ["root": groupID],
            mailboxScopeID: scopeID
        )
        await relaunchedGraphViewModel.awaitSpatialStateLoadForTesting()
        await relaunchedGraphViewModel.awaitSpatialStatePersistenceForTesting()

        XCTAssertNil(relaunchedGraphViewModel.lastSpatialReplayIntentIDForTesting)
        XCTAssertEqual(relaunchedGraphViewModel.confirmedGroupAnchors[groupID], anchor)
        let storedReplayed = try await operationStore.operation(id: created.operation.id)
        let replayed = try XCTUnwrap(storedReplayed)
        XCTAssertEqual(replayed.phase, .completed)
        XCTAssertEqual(replayed.receipts.filter { $0.kind == .spatialAnchor }.count, 1)
    }

    private func configure(_ scene: ObsidianGraphScene, data: GraphData) {
        scene.configure(data: data,
                        selectedGraphNodeID: nil,
                        pruneMode: .idle,
                        filteredNodeIDs: data.allNodeIDs,
                        wateredCounts: [:],
                        reduceMotion: true,
                        sproutingMessageIDs: [],
                        forceConfig: ObsidianGraphForceConfig.defaults,
                        displayConfig: ObsidianGraphDisplayConfig.defaults,
                        theme: DesignTokens.Graph.AppTheme.Palette(isDark: false),
                        zoomScale: 1,
                        panOffset: .zero)
    }

    private func spatialFixtureThread(rootID: String, messageCount: Int) -> ThreadNode {
        var children: [ThreadNode] = []
        if messageCount > 1 {
            for index in stride(from: messageCount - 1, through: 1, by: -1) {
                let child = ThreadNode(message: EmailMessage(
                    messageID: "\(rootID)-msg-\(index)",
                    mailboxID: "Inbox",
                    accountName: "Account",
                    subject: "Subject \(rootID)",
                    from: "sender@example.com",
                    to: "me@example.com",
                    date: Date(timeIntervalSince1970: 10_000 - Double(index * 60)),
                    snippet: "Snippet \(rootID)-msg-\(index)",
                    isUnread: false,
                    inReplyTo: nil,
                    references: [],
                    threadID: rootID),
                                  children: children)
                children = [child]
            }
        }
        return ThreadNode(message: EmailMessage(
            messageID: rootID,
            mailboxID: "Inbox",
            accountName: "Account",
            subject: "Subject \(rootID)",
            from: "sender@example.com",
            to: "me@example.com",
            date: Date(timeIntervalSince1970: 10_000),
            snippet: "Snippet \(rootID)",
            isUnread: false,
            inReplyTo: nil,
            references: [],
            threadID: rootID),
                          children: children)
    }
}

@MainActor
private final class SpatialReplayProbe {
    private var receipt: GraphSpatialAnchorReplayReceipt?
    private var pendingLookups = 0
    private var pendingLookupScopeID: String?

    func notePendingLookup(scopeID: String) {
        pendingLookups += 1
        pendingLookupScopeID = scopeID
    }

    func pendingLookupCount() -> Int {
        pendingLookups
    }

    func lastPendingLookupScopeID() -> String? {
        pendingLookupScopeID
    }

    func set(_ receipt: GraphSpatialAnchorReplayReceipt) {
        self.receipt = receipt
    }

    func value() -> GraphSpatialAnchorReplayReceipt? {
        receipt
    }
}

private struct IntegrationGraphSpatialSecretProvider: GraphSpatialSecretProviding {
    let secret = Data(repeating: 0x71, count: 32)

    func loadOrCreateSecret() throws -> Data {
        secret
    }
}

private final class IntegrationGraphSpatialFileAccessor: GraphSpatialFileAccessing, @unchecked Sendable {
    var data: Data?

    func read() throws -> Data {
        guard let data else { throw GraphSpatialFileAccessError.notFound }
        return data
    }

    func writeAtomically(_ data: Data) throws {
        self.data = data
    }
}

private extension ObsidianGraphScene {
    func position(of nodeID: String) -> CGPoint? {
        children.compactMap { child in
            guard let node = child as? ObsidianGraphSceneNode,
                  node.graphID == nodeID else { return nil }
            return node.position
        }.first
    }
}
