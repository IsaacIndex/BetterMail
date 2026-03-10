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

    func testReconcileFolderThreadIdentities_mapsJWZFolderMembershipToManualGroupID() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let messageA = EmailMessage(messageID: "msg-a",
                                    mailboxID: "Inbox",
                                    accountName: "Work",
                                    subject: "A",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: older,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let messageB = EmailMessage(messageID: "msg-b",
                                    mailboxID: "Inbox",
                                    accountName: "Work",
                                    subject: "B",
                                    from: "b@example.com",
                                    to: "me@example.com",
                                    date: newer,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])

        let threader = JWZThreader()
        let baseResult = threader.buildThreads(from: [messageA, messageB])
        let threadAID = baseResult.jwzThreadMap[messageA.threadKey]!
        let threadBID = baseResult.jwzThreadMap[messageB.threadKey]!
        let manualGroup = ManualThreadGroup(id: "manual-group",
                                            jwzThreadIDs: [threadAID, threadBID],
                                            manualMessageKeys: [])
        let applied = threader.applyManualGroups([manualGroup], to: baseResult)

        let folder = ThreadFolder(id: "folder-1",
                                  title: "Projects",
                                  color: ThreadFolderColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                  threadIDs: [threadAID, threadBID],
                                  parentID: nil,
                                  mailboxAccount: "Work",
                                  mailboxPath: "Projects/Acme")

        let update = ThreadCanvasViewModel.reconcileFolderThreadIdentities(folders: [folder],
                                                                           roots: applied.result.roots,
                                                                           jwzThreadMap: applied.result.jwzThreadMap)

        XCTAssertEqual(update?.folders.first?.threadIDs, [manualGroup.id])
        XCTAssertEqual(update?.membership[manualGroup.id], folder.id)
    }

    func testRemapThreadIDsInFolders_reusesTargetFolderForGroupedThread() {
        let folder = ThreadFolder(id: "folder-1",
                                  title: "Projects",
                                  color: ThreadFolderColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                  threadIDs: ["thread-a", "thread-b"],
                                  parentID: nil,
                                  mailboxAccount: "Work",
                                  mailboxPath: "Projects/Acme")

        let update = ThreadCanvasViewModel.remapThreadIDsInFolders(["thread-a", "thread-b"],
                                                                   to: "manual-group",
                                                                   preferredSourceThreadID: "thread-a",
                                                                   folders: [folder])

        XCTAssertEqual(update?.folders.first?.threadIDs, ["manual-group"])
        XCTAssertEqual(update?.membership["manual-group"], folder.id)
    }

    func testAddFolderForSelection_setsMailboxDestinationWhenSelectionMatches() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderMailboxTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(), store: store)
        let now = Date()
        let messageA = EmailMessage(messageID: "msg-a",
                                    mailboxID: "Projects/Acme",
                                    accountName: "Work",
                                    subject: "A",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: now,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [],
                                    threadID: "thread-a")
        let messageB = EmailMessage(messageID: "msg-b",
                                    mailboxID: "Projects/Acme",
                                    accountName: "Work",
                                    subject: "B",
                                    from: "b@example.com",
                                    to: "me@example.com",
                                    date: now.addingTimeInterval(60),
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [],
                                    threadID: "thread-b")

        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: messageA), ThreadNode(message: messageB)])
        viewModel.selectNode(id: messageA.messageID)
        viewModel.selectNode(id: messageB.messageID, additive: true)
        viewModel.addFolderForSelection()
        try await Task.sleep(nanoseconds: 250_000_000)

        let folders = try await store.fetchThreadFolders()
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first?.mailboxAccount, "Work")
        XCTAssertEqual(folders.first?.mailboxPath, "Projects/Acme")
    }

    func testAddFolderForSelection_leavesMailboxDestinationUnsetWhenSelectionDiffers() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderMailboxTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(), store: store)
        let now = Date()
        let messageA = EmailMessage(messageID: "msg-a",
                                    mailboxID: "Projects/Acme",
                                    accountName: "Work",
                                    subject: "A",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: now,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [],
                                    threadID: "thread-a")
        let messageB = EmailMessage(messageID: "msg-b",
                                    mailboxID: "Archive",
                                    accountName: "Work",
                                    subject: "B",
                                    from: "b@example.com",
                                    to: "me@example.com",
                                    date: now.addingTimeInterval(60),
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [],
                                    threadID: "thread-b")

        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: messageA), ThreadNode(message: messageB)])
        viewModel.selectNode(id: messageA.messageID)
        viewModel.selectNode(id: messageB.messageID, additive: true)
        viewModel.addFolderForSelection()
        try await Task.sleep(nanoseconds: 250_000_000)

        let folders = try await store.fetchThreadFolders()
        XCTAssertEqual(folders.count, 1)
        XCTAssertNil(folders.first?.mailboxAccount)
        XCTAssertNil(folders.first?.mailboxPath)
    }
}
