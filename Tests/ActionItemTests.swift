import XCTest
@testable import BetterMail

final class ActionItemTests: XCTestCase {

    // Matches the pattern used throughout the test suite (e.g. MessageStoreBoundaryTests).
    // A unique UserDefaults suite name isolates each test from shared defaults state.
    private func makeStore() -> MessageStore {
        let defaults = UserDefaults(suiteName: "ActionItemTests-\(UUID().uuidString)")!
        return MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
    }

    private func makeMessage(id: String = "msg-1", accountName: String = "Test",
                             date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> EmailMessage {
        EmailMessage(messageID: id,
                     mailboxID: "inbox",
                     accountName: accountName,
                     subject: "Test subject",
                     from: "sender@example.com",
                     to: "me@example.com",
                     date: date,
                     snippet: "snippet",
                     isUnread: true,
                     inReplyTo: nil,
                     references: [])
    }

    func test_addActionItem_newMessage_persistsRecord() async throws {
        let store = makeStore()
        let msg = makeMessage()
        await store.addActionItem(for: msg, folderID: "folder-1", tags: ["Tag A", "Tag B", "Tag C"])
        let items = await store.fetchActionItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].messageID, msg.messageID)
        XCTAssertEqual(items[0].accountName, msg.accountName)
        XCTAssertEqual(items[0].id, ActionItem.scopedID(for: msg))
        XCTAssertEqual(items[0].folderID, "folder-1")
        XCTAssertEqual(items[0].tags, ["Tag A", "Tag B", "Tag C"])
        XCTAssertFalse(items[0].isDone)
    }

    func test_addActionItem_duplicateMessage_isIdempotent() async throws {
        let store = makeStore()
        let msg = makeMessage()
        await store.addActionItem(for: msg, folderID: nil, tags: [])
        await store.addActionItem(for: msg, folderID: nil, tags: [])
        let items = await store.fetchActionItems()
        XCTAssertEqual(items.count, 1)
    }

    func test_toggleActionItemDone_existingItem_flipsFlag() async throws {
        let store = makeStore()
        let msg = makeMessage()
        await store.addActionItem(for: msg, folderID: nil, tags: [])
        let initialItems = await store.fetchActionItems()
        let item = try XCTUnwrap(initialItems.first)
        await store.toggleActionItemDone(item)
        let items = await store.fetchActionItems()
        XCTAssertTrue(items[0].isDone)
        // Toggle back
        await store.toggleActionItemDone(item)
        let items2 = await store.fetchActionItems()
        XCTAssertFalse(items2[0].isDone)
    }

    func test_removeActionItem_existingItem_deletesRecord() async throws {
        let store = makeStore()
        let msg = makeMessage()
        await store.addActionItem(for: msg, folderID: nil, tags: [])
        await store.removeActionItem(for: msg)
        let items = await store.fetchActionItems()
        XCTAssertTrue(items.isEmpty)
    }

    func test_fetchActionItems_groupedByFolder_correctGroups() async throws {
        let store = makeStore()
        let msg1 = makeMessage(id: "msg-1")
        let msg2 = makeMessage(id: "msg-2")
        let msg3 = makeMessage(id: "msg-3")
        await store.addActionItem(for: msg1, folderID: "folder-A", tags: [])
        await store.addActionItem(for: msg2, folderID: "folder-A", tags: [])
        await store.addActionItem(for: msg3, folderID: "folder-B", tags: [])
        let items = await store.fetchActionItems()
        let groupA = items.filter { $0.folderID == "folder-A" }
        let groupB = items.filter { $0.folderID == "folder-B" }
        XCTAssertEqual(groupA.count, 2)
        XCTAssertEqual(groupB.count, 1)
    }

    func test_actionItemTags_snapshotAtTagTime_arePreserved() async throws {
        let store = makeStore()
        let msg = makeMessage()
        let originalTags = ["Alpha", "Beta", "Gamma"]
        await store.addActionItem(for: msg, folderID: nil, tags: originalTags)
        let items = await store.fetchActionItems()
        XCTAssertEqual(items[0].tags, originalTags)
    }

    func test_sameMessageIDInDifferentAccounts_actionItemsRemainIndependent() async throws {
        let store = makeStore()
        let work = makeMessage(id: "shared-message-id", accountName: "Work")
        let personal = makeMessage(id: "shared-message-id", accountName: "Personal")

        await store.addActionItem(for: work, folderID: "work-folder", tags: ["Work"])
        await store.addActionItem(for: personal, folderID: "personal-folder", tags: ["Personal"])

        var items = await store.fetchActionItems()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.id)),
                       Set([ActionItem.scopedID(for: work), ActionItem.scopedID(for: personal)]))

        let workItem = try XCTUnwrap(items.first { $0.accountName == "Work" })
        await store.toggleActionItemDone(workItem)
        items = await store.fetchActionItems()
        XCTAssertTrue(try XCTUnwrap(items.first { $0.accountName == "Work" }).isDone)
        XCTAssertFalse(try XCTUnwrap(items.first { $0.accountName == "Personal" }).isDone)

        await store.removeActionItem(for: work)
        items = await store.fetchActionItems()
        XCTAssertEqual(items.map(\.accountName), ["Personal"])
    }

    private func makeItem(id: String = "msg-1", account: String = "Test",
                          folderID: String? = nil, isDone: Bool = false) -> ActionItem {
        ActionItem(messageID: id, accountName: account, threadID: "thread-1",
                   subject: "Café renewal", from: "Alex <alex@example.com>",
                   date: Date(timeIntervalSince1970: 1_700_000_000),
                   folderID: folderID, tags: ["Invoice"], isDone: isDone,
                   addedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    func test_fetchMessage_duplicateMessageIDs_resolvesSavedAccount() async throws {
        let store = makeStore()
        let work = makeMessage(id: "<shared>", accountName: "Work")
        let personal = makeMessage(id: "<shared>", accountName: "Personal")
        try await store.upsert(messages: [work, personal])

        let result = try await store.fetchMessage(forActionItem: makeItem(id: "shared", account: " work "))

        XCTAssertEqual(result?.id, work.id)
        XCTAssertEqual(result?.accountName, "Work")
    }

    func test_fetchMessage_savedAccountMissing_doesNotUseAnotherAccount() async throws {
        let store = makeStore()
        try await store.upsert(messages: [makeMessage(accountName: "Personal")])

        let result = try await store.fetchMessage(forActionItem: makeItem(account: "Work"))

        XCTAssertNil(result)
    }

    func test_fetchMessage_legacyItemWithMultipleAccounts_reportsAmbiguity() async throws {
        let store = makeStore()
        try await store.upsert(messages: [makeMessage(accountName: "Work"),
                                          makeMessage(accountName: "Personal")])
        do {
            _ = try await store.fetchMessage(forActionItem: makeItem(account: ""))
            XCTFail("An account must not be guessed for a legacy record")
        } catch ActionItemSourceError.ambiguousAccount {
            // Expected: the inspector explains why this source cannot be chosen.
        }
    }

    func test_fetchMessage_legacyItemWithOneAccount_resolvesCachedSource() async throws {
        let store = makeStore()
        let message = makeMessage(accountName: "Work")
        try await store.upsert(messages: [message])

        let result = try await store.fetchMessage(forActionItem: makeItem(account: ""))

        XCTAssertEqual(result?.id, message.id)
    }

    func test_fetchMessage_reconciledAbsentSource_returnsNil() async throws {
        let store = makeStore()
        let message = makeMessage()
        try await store.upsert(messages: [message])
        _ = try await store.reconcileSourcePresence(
            in: DateInterval(start: message.date.addingTimeInterval(-1), duration: 2),
            scope: DayFetchScope(mailbox: "inbox", account: "Test", displayName: "Test"),
            manifest: [], checkedAt: message.date.addingTimeInterval(3)
        )

        let result = try await store.fetchMessage(forActionItem: makeItem())

        XCTAssertNil(result)
    }

    func test_summaryNode_duplicateAccounts_doesNotReuseBareSummaryKey() {
        let work = ThreadNode(message: makeMessage(accountName: "Work"))
        let personal = ThreadNode(message: makeMessage(accountName: "Personal"))

        XCTAssertNil(ActionItemSummaryLookup(roots: [work, personal]).node(for: makeItem(account: "Work")))
        XCTAssertNil(ActionItemSummaryLookup(roots: [personal]).node(for: makeItem(account: "Work")))
        XCTAssertEqual(ActionItemSummaryLookup(roots: [work]).node(for: makeItem(account: "Work"))?.message.id,
                       work.message.id)
    }

    func test_listProjection_searchMatchesMetadataAndGroup_ignoresCaseAndDiacritics() {
        let folder = ThreadFolder(id: "group-1", title: "Finance", color: .defaultNewFolder,
                                  threadIDs: [], parentID: nil)
        let item = makeItem(account: "Work", folderID: folder.id)
        for query in [" CAFE ", "ALEX@EXAMPLE.COM", "work", "invoice", "finance"] {
            let projection = ActionItemListProjection(items: [item], folders: [folder],
                                                      showDone: false, query: query)
            XCTAssertEqual(projection.visibleItems.map(\.id), [item.id], query)
            XCTAssertNil(projection.emptyState, query)
        }
    }

    func test_listProjection_completedItemRequiresShowDone_evenWhenSearchMatches() {
        let item = makeItem(isDone: true)
        let hidden = ActionItemListProjection(items: [item], folders: [], showDone: false, query: "renewal")
        let shown = ActionItemListProjection(items: [item], folders: [], showDone: true, query: "renewal")

        XCTAssertEqual(hidden.emptyState, .noMatches)
        XCTAssertEqual(shown.visibleItems.map(\.id), [item.id])
        XCTAssertEqual(shown.openCount, 0)
    }

    func test_listProjection_emptyAndCompletedLists_haveDistinctRecoveryStates() {
        let empty = ActionItemListProjection(items: [], folders: [], showDone: false, query: "")
        let completed = ActionItemListProjection(items: [makeItem(isDone: true)], folders: [],
                                                 showDone: false, query: "  ")
        let shown = ActionItemListProjection(items: [makeItem(isDone: true)], folders: [],
                                            showDone: true, query: "")

        XCTAssertEqual(empty.emptyState, .noItems)
        XCTAssertEqual(completed.emptyState, .allDone)
        XCTAssertNil(shown.emptyState)
    }

    func test_listProjection_deletedGroup_becomesUnfiledWithoutLosingTasks() {
        let orphan = makeItem(id: "orphan", folderID: "deleted-group")
        let unfiled = makeItem(id: "unfiled")
        let projection = ActionItemListProjection(items: [orphan, unfiled], folders: [],
                                                  showDone: false, query: "")

        XCTAssertEqual(projection.groups.count, 1)
        XCTAssertNil(projection.groups.first?.folderID)
        XCTAssertEqual(Set(projection.groups.flatMap(\.items).map(\.id)), [orphan.id, unfiled.id])
        XCTAssertEqual(projection.openCount, 2)
        XCTAssertEqual(projection.openGroupCount, 0)
    }

    func test_listProjection_equalDatesAndTitles_usesStableOrdering() {
        let folders = ["a", "b"].map {
            ThreadFolder(id: $0, title: "Same", color: .defaultNewFolder, threadIDs: [], parentID: nil)
        }
        let items = [makeItem(id: "b", folderID: "b"), makeItem(id: "c", folderID: "a"),
                     makeItem(id: "a", folderID: "a"), makeItem(id: "unfiled")]
        let first = ActionItemListProjection(items: items, folders: folders, showDone: false, query: "")
        let second = ActionItemListProjection(items: Array(items.reversed()), folders: folders,
                                              showDone: false, query: "")

        XCTAssertEqual(first.groups.map(\.folderID), ["a", "b", nil])
        XCTAssertEqual(first.groups.flatMap(\.items).map(\.id), second.groups.flatMap(\.items).map(\.id))
    }

    @MainActor
    private func makeViewModel(store: MessageStore) throws -> ThreadCanvasViewModel {
        let suiteName = "ActionItemSelectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return ThreadCanvasViewModel(
            settings: AutoRefreshSettings(userDefaults: defaults),
            inspectorSettings: InspectorViewSettings(userDefaults: defaults),
            pinnedFolderSettings: PinnedFolderSettings(userDefaults: defaults),
            store: store,
            organizationOperationStore: OrganizationOperationStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName).json")
            ),
            performsInitialSourceRefresh: false
        )
    }

    @MainActor
    func test_selectActionItem_outsideCanvasWindow_loadsCorrectCachedAccount() async throws {
        let store = makeStore()
        let work = makeMessage(accountName: "Work", date: Date(timeIntervalSince1970: 1_000))
        let personal = makeMessage(accountName: "Personal")
        try await store.upsert(messages: [work, personal])
        await store.addActionItem(for: work, folderID: nil, tags: [])
        let viewModel = try makeViewModel(store: store)
        await viewModel.refreshActionItemIDs()
        XCTAssertTrue(viewModel.roots.isEmpty)

        viewModel.selectActionItem(id: ActionItem.scopedID(for: work))
        await viewModel.loadSelectedActionItem()

        XCTAssertEqual(viewModel.selectedNode?.message.id, work.id)
        XCTAssertEqual(viewModel.selectedActionItemID, ActionItem.scopedID(for: work))
        XCTAssertNil(viewModel.actionItemSelectionError)
        viewModel.selectNode(id: nil)
        XCTAssertNil(viewModel.selectedActionItemNode)
        XCTAssertNil(viewModel.selectedActionItemID)
    }

    @MainActor
    func test_selectActionItem_missingSource_showsErrorAndKeepsTask() async throws {
        let store = makeStore()
        let message = makeMessage()
        await store.addActionItem(for: message, folderID: nil, tags: [])
        let viewModel = try makeViewModel(store: store)
        await viewModel.refreshActionItemIDs()

        viewModel.selectActionItem(id: ActionItem.scopedID(for: message))
        await viewModel.loadSelectedActionItem()

        XCTAssertNil(viewModel.selectedActionItemNode)
        XCTAssertNotNil(viewModel.actionItemSelectionError)
        XCTAssertEqual(viewModel.actionItems.count, 1)
    }

    @MainActor
    func test_loadSelectedActionItem_cancelledTask_doesNotPublishDetails() async throws {
        let store = makeStore()
        let message = makeMessage()
        try await store.upsert(messages: [message])
        await store.addActionItem(for: message, folderID: nil, tags: [])
        let viewModel = try makeViewModel(store: store)
        await viewModel.refreshActionItemIDs()
        viewModel.selectActionItem(id: ActionItem.scopedID(for: message))
        let task = Task { await viewModel.loadSelectedActionItem() }
        task.cancel()
        await task.value

        XCTAssertNil(viewModel.selectedActionItemNode)
        XCTAssertNil(viewModel.actionItemSelectionError)
    }

    @MainActor
    func test_selectActionItem_sameRowAfterFailedLoad_advancesRequestAndAllowsRetry() async throws {
        let store = makeStore()
        let message = makeMessage()
        await store.addActionItem(for: message, folderID: nil, tags: [])
        let viewModel = try makeViewModel(store: store)
        await viewModel.refreshActionItemIDs()
        let id = ActionItem.scopedID(for: message)
        viewModel.selectActionItem(id: id)
        await viewModel.loadSelectedActionItem()
        let previousRevision = viewModel.actionItemSelectionRevision
        XCTAssertNotNil(viewModel.actionItemSelectionError)

        try await store.upsert(messages: [message])
        viewModel.selectActionItem(id: id)
        XCTAssertNotEqual(viewModel.actionItemSelectionRevision, previousRevision)
        XCTAssertNil(viewModel.actionItemSelectionError)
        await viewModel.loadSelectedActionItem()

        XCTAssertEqual(viewModel.selectedActionItemNode?.message.id, message.id)
    }
}
