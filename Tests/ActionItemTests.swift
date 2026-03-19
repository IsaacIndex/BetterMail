import XCTest
@testable import BetterMail

final class ActionItemTests: XCTestCase {

    // Matches the pattern used throughout the test suite (e.g. MessageStoreBoundaryTests).
    // A unique UserDefaults suite name isolates each test from shared defaults state.
    private func makeStore() -> MessageStore {
        let defaults = UserDefaults(suiteName: "ActionItemTests-\(UUID().uuidString)")!
        return MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
    }

    private func makeMessage(id: String = "msg-1") -> EmailMessage {
        EmailMessage(messageID: id,
                     mailboxID: "inbox",
                     accountName: "Test",
                     subject: "Test subject",
                     from: "sender@example.com",
                     to: "me@example.com",
                     date: Date(),
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
        XCTAssertEqual(items[0].id, msg.messageID)
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
        await store.toggleActionItemDone(msg.messageID)
        let items = await store.fetchActionItems()
        XCTAssertTrue(items[0].isDone)
        // Toggle back
        await store.toggleActionItemDone(msg.messageID)
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
}
