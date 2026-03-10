import XCTest
@testable import BetterMail

@MainActor
final class ThreadFolderMailboxTests: XCTestCase {
    func testFetchThreadFolders_persistsMailboxDestination() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderMailboxTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let folder = ThreadFolder(id: "folder-1",
                                  title: "Projects",
                                  color: ThreadFolderColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                  threadIDs: ["thread-1"],
                                  parentID: nil,
                                  mailboxAccount: "Work",
                                  mailboxPath: "Projects/Acme")

        try await store.upsertThreadFolders([folder])
        let restored = try await store.fetchThreadFolders()

        XCTAssertEqual(restored.first?.mailboxAccount, "Work")
        XCTAssertEqual(restored.first?.mailboxPath, "Projects/Acme")
    }

    func testFolderMailboxLeafName_returnsLeafPath() {
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings())
        let folder = ThreadFolder(id: "folder-1",
                                  title: "Projects",
                                  color: ThreadFolderColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                  threadIDs: ["thread-1"],
                                  parentID: nil,
                                  mailboxAccount: "Work",
                                  mailboxPath: "Projects/Acme")

        viewModel.applyRethreadResultForTesting(roots: [], folders: [folder])

        XCTAssertEqual(viewModel.folderMailboxLeafName(for: "folder-1"), "Acme")
    }

    func testSaveFolderEdits_rejectsMixedAccountMailboxAssignment() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderMailboxTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = AutoRefreshSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings, store: store)
        let now = Date()
        let workMessage = EmailMessage(messageID: "msg-work",
                                       mailboxID: "Inbox",
                                       accountName: "Work",
                                       subject: "Work",
                                       from: "a@example.com",
                                       to: "me@example.com",
                                       date: now,
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [],
                                       threadID: "thread-work")
        let personalMessage = EmailMessage(messageID: "msg-personal",
                                           mailboxID: "Inbox",
                                           accountName: "Personal",
                                           subject: "Personal",
                                           from: "b@example.com",
                                           to: "me@example.com",
                                           date: now,
                                           snippet: "",
                                           isUnread: false,
                                           inReplyTo: nil,
                                           references: [],
                                           threadID: "thread-personal")
        try await store.upsert(messages: [workMessage, personalMessage])

        let folder = ThreadFolder(id: "folder-1",
                                  title: "Mixed",
                                  color: ThreadFolderColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                  threadIDs: ["thread-work", "thread-personal"],
                                  parentID: nil)
        try await store.upsertThreadFolders([folder])
        viewModel.applyRethreadResultForTesting(roots: [], folders: [folder])

        viewModel.saveFolderEdits(id: "folder-1",
                                  title: "Mixed",
                                  color: folder.color,
                                  mailboxAccount: "Work",
                                  mailboxPath: "Projects/Acme")
        try await Task.sleep(nanoseconds: 250_000_000)

        let restored = try await store.fetchThreadFolders()
        XCTAssertNil(restored.first?.mailboxAccount)
        XCTAssertNil(restored.first?.mailboxPath)
        XCTAssertEqual(viewModel.mailboxActionStatusMessage,
                       NSLocalizedString("threadcanvas.folder.mailbox.mixed_accounts",
                                         comment: "Reason a folder mailbox destination cannot be set for mixed-account folders"))
    }
}
