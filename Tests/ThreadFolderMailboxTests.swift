import XCTest
@testable import BetterMail

@MainActor
final class ThreadFolderMailboxTests: XCTestCase {
    func testGroupingActionTerminology_hasFullCompactAndBoundaryCopy() {
        XCTAssertEqual(NSLocalizedString("threadlist.selection.group", comment: ""), "Join Thread")
        XCTAssertEqual(NSLocalizedString("threadlist.selection.group.verb", comment: ""), "Join")
        XCTAssertEqual(NSLocalizedString("threadlist.selection.add_folder", comment: ""), "Create Group")
        XCTAssertEqual(NSLocalizedString("threadlist.selection.add_folder.verb", comment: ""), "Group")
        XCTAssertEqual(NSLocalizedString("threadlist.selection.move_mailbox_folder", comment: ""), "Move")
        XCTAssertEqual(NSLocalizedString("threadlist.selection.ungroup", comment: ""), "Remove from Thread")
        XCTAssertEqual(NSLocalizedString("threadlist.selection.ungroup.verb", comment: ""), "Remove")
        XCTAssertTrue(NSLocalizedString("threadlist.selection.add_folder.help", comment: "")
            .contains("Mailbox Folder"))
        XCTAssertEqual(NSLocalizedString("mailbox.sidebar.all_folders", comment: ""), "All Groups")
    }

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

    func testAddFolderForSelection_keepsMailboxDestinationExplicitWhenSelectionMatches() async throws {
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

        try await store.upsert(messages: [messageA, messageB])
        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: messageA), ThreadNode(message: messageB)])
        viewModel.selectNode(id: messageA.messageID)
        viewModel.selectNode(id: messageB.messageID, additive: true)
        viewModel.addFolderForSelection()
        try await Task.sleep(nanoseconds: 250_000_000)

        let folders = try await store.fetchThreadFolders()
        XCTAssertEqual(folders.count, 1)
        XCTAssertNil(folders.first?.mailboxAccount)
        XCTAssertNil(folders.first?.mailboxPath)
        let persistedMessages = try await store.fetchMessages()
        XCTAssertEqual(Set(persistedMessages.map(\.mailboxID)), ["Projects/Acme"],
                       "Create Group must not move messages in Mail or alter their cached mailbox")
    }

    func testAddFolderForSelection_supportsOneThreadWithoutMovingIt() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderMailboxTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(), store: store)
        let message = EmailMessage(messageID: "msg-one",
                                   mailboxID: "Inbox",
                                   accountName: "Work",
                                   subject: "One thread group",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: Date(),
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-one")
        try await store.upsert(messages: [message])
        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: message)])
        viewModel.selectNode(id: message.messageID)

        viewModel.addFolderForSelection()
        try await Task.sleep(nanoseconds: 250_000_000)

        let groups = try await store.fetchThreadFolders()
        let persistedMessages = try await store.fetchMessages()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.threadIDs, ["thread-one"])
        XCTAssertEqual(persistedMessages.first?.mailboxID, "Inbox")
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

    func testRecoverFolderDestinationForTesting_keepsExactMatchUnchanged() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderMailboxTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(), store: store)
        let message = EmailMessage(messageID: "msg-a",
                                   mailboxID: "Projects/Acme",
                                   accountName: "Work",
                                   subject: "A",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: Date(),
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-a")
        let folder = ThreadFolder(id: "folder-1",
                                  title: "Projects",
                                  color: ThreadFolderColor.defaultNewFolder,
                                  threadIDs: ["thread-a"],
                                  parentID: nil,
                                  mailboxAccount: "Work",
                                  mailboxPath: "Projects/Acme")
        try await store.upsert(messages: [message])
        try await store.upsertThreadFolders([folder])
        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: message)], folders: [folder])
        viewModel.applyMailboxHierarchyForTesting([
            MailboxAccount(name: "Work",
                           folders: [
                            MailboxFolderNode(account: "Work",
                                              path: "Projects",
                                              name: "Projects",
                                              parentPath: nil,
                                              children: [
                                                MailboxFolderNode(account: "Work",
                                                                  path: "Projects/Acme",
                                                                  name: "Acme",
                                                                  parentPath: "Projects",
                                                                  children: [])
                                              ])
                           ])
        ])

        let resolution = await viewModel.recoverFolderDestinationForTesting(folderID: "folder-1")
        let restored = try await store.fetchThreadFolders()

        XCTAssertEqual(resolution, MailboxPathResolution.exact(MailboxFolderChoice(account: "Work",
                                                                                   path: "Projects/Acme",
                                                                                   displayPath: "Projects/Acme")))
        XCTAssertEqual(restored.first?.mailboxPath, "Projects/Acme")
    }

    func testRecoverFolderDestinationForTesting_persistsHeuristicRemap_whenCurrentMessagesAgree() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderMailboxTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(), store: store)
        let message = EmailMessage(messageID: "msg-a",
                                   mailboxID: "Projects/Phoenix",
                                   accountName: "Work",
                                   subject: "A",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: Date(),
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-a")
        let folder = ThreadFolder(id: "folder-1",
                                  title: "Projects",
                                  color: ThreadFolderColor.defaultNewFolder,
                                  threadIDs: ["thread-a"],
                                  parentID: nil,
                                  mailboxAccount: "Work",
                                  mailboxPath: "Projects/Acme")
        try await store.upsert(messages: [message])
        try await store.upsertThreadFolders([folder])
        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: message)], folders: [folder])
        viewModel.applyMailboxHierarchyForTesting([
            MailboxAccount(name: "Work",
                           folders: [
                            MailboxFolderNode(account: "Work",
                                              path: "Projects",
                                              name: "Projects",
                                              parentPath: nil,
                                              children: [
                                                MailboxFolderNode(account: "Work",
                                                                  path: "Projects/Phoenix",
                                                                  name: "Phoenix",
                                                                  parentPath: "Projects",
                                                                  children: [])
                                              ])
                           ])
        ])

        let resolution = await viewModel.recoverFolderDestinationForTesting(folderID: "folder-1")
        let restored = try await store.fetchThreadFolders()

        XCTAssertEqual(resolution, MailboxPathResolution.heuristic(MailboxFolderChoice(account: "Work",
                                                                                       path: "Projects/Phoenix",
                                                                                       displayPath: "Projects/Phoenix")))
        XCTAssertEqual(restored.first?.mailboxPath, "Projects/Phoenix")
    }

    func testRecoverFolderDestinationForTesting_leavesDestinationUnchanged_whenNoMatchExists() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderMailboxTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(), store: store)
        let message = EmailMessage(messageID: "msg-a",
                                   mailboxID: "Missing",
                                   accountName: "Work",
                                   subject: "A",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: Date(),
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-a")
        let folder = ThreadFolder(id: "folder-1",
                                  title: "Projects",
                                  color: ThreadFolderColor.defaultNewFolder,
                                  threadIDs: ["thread-a"],
                                  parentID: nil,
                                  mailboxAccount: "Work",
                                  mailboxPath: "Projects/Acme")
        try await store.upsert(messages: [message])
        try await store.upsertThreadFolders([folder])
        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: message)], folders: [folder])
        viewModel.applyMailboxHierarchyForTesting([
            MailboxAccount(name: "Work",
                           folders: [
                            MailboxFolderNode(account: "Work",
                                              path: "Archive",
                                              name: "Archive",
                                              parentPath: nil,
                                              children: [])
                           ])
        ])

        let resolution = await viewModel.recoverFolderDestinationForTesting(folderID: "folder-1")
        let restored = try await store.fetchThreadFolders()

        XCTAssertEqual(resolution, MailboxPathResolution.missing)
        XCTAssertEqual(restored.first?.mailboxPath, "Projects/Acme")
    }

    func testRecoverFolderDestinationForTesting_leavesDestinationUnchanged_whenMatchIsAmbiguous() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderMailboxTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(), store: store)
        let message = EmailMessage(messageID: "msg-a",
                                   mailboxID: "Inbox",
                                   accountName: "Work",
                                   subject: "A",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: Date(),
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-a")
        let folder = ThreadFolder(id: "folder-1",
                                  title: "Projects",
                                  color: ThreadFolderColor.defaultNewFolder,
                                  threadIDs: ["thread-a"],
                                  parentID: nil,
                                  mailboxAccount: "Work",
                                  mailboxPath: "Projects/Acme")
        try await store.upsert(messages: [message])
        try await store.upsertThreadFolders([folder])
        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: message)], folders: [folder])
        viewModel.applyMailboxHierarchyForTesting([
            MailboxAccount(name: "Work",
                           folders: [
                            MailboxFolderNode(account: "Work",
                                              path: "Archive",
                                              name: "Archive",
                                              parentPath: nil,
                                              children: [
                                                MailboxFolderNode(account: "Work",
                                                                  path: "Archive/Acme",
                                                                  name: "Acme",
                                                                  parentPath: "Archive",
                                                                  children: [])
                                              ]),
                            MailboxFolderNode(account: "Work",
                                              path: "Clients",
                                              name: "Clients",
                                              parentPath: nil,
                                              children: [
                                                MailboxFolderNode(account: "Work",
                                                                  path: "Clients/Acme",
                                                                  name: "Acme",
                                                                  parentPath: "Clients",
                                                                  children: [])
                                              ])
                           ])
        ])

        let resolution = await viewModel.recoverFolderDestinationForTesting(folderID: "folder-1")
        let restored = try await store.fetchThreadFolders()

        XCTAssertEqual(resolution, MailboxPathResolution.ambiguous)
        XCTAssertEqual(restored.first?.mailboxPath, "Projects/Acme")
    }

    func testBottomBarMailboxStatus_isScopedToSelectedThread() {
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings())
        let now = Date()
        let first = EmailMessage(messageID: "msg-1",
                                 mailboxID: "Inbox",
                                 accountName: "Work",
                                 subject: "First",
                                 from: "a@example.com",
                                 to: "me@example.com",
                                 date: now,
                                 snippet: "",
                                 isUnread: false,
                                 inReplyTo: nil,
                                 references: [],
                                 threadID: "thread-1")
        let second = EmailMessage(messageID: "msg-2",
                                  mailboxID: "Inbox",
                                  accountName: "Work",
                                  subject: "Second",
                                  from: "b@example.com",
                                  to: "me@example.com",
                                  date: now.addingTimeInterval(60),
                                  snippet: "",
                                  isUnread: false,
                                  inReplyTo: nil,
                                  references: [],
                                  threadID: "thread-2")

        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: first), ThreadNode(message: second)])
        viewModel.selectNode(id: first.messageID)
        viewModel.setBottomBarMailboxActionStatusForTesting("Moved first thread.",
                                                            threadID: "thread-1",
                                                            expiresAt: now.addingTimeInterval(300))

        XCTAssertEqual(viewModel.bottomBarMailboxActionStatusMessage, "Moved first thread.")

        viewModel.selectNode(id: second.messageID)

        XCTAssertNil(viewModel.bottomBarMailboxActionStatusMessage)
    }

    func testPrepareMailboxMoveConfirmation_disclosesExactMultiMailboxEffect() async throws {
        let suiteName = "ThreadFolderMailboxDisclosure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let viewModel = ThreadCanvasViewModel(
            settings: AutoRefreshSettings(userDefaults: defaults),
            store: store,
            performsInitialSourceRefresh: false
        )
        let now = Date()
        let rootMessage = EmailMessage(messageID: "message-inbox",
                                       mailboxID: "Inbox",
                                       accountName: "Work",
                                       subject: "Exact disclosure",
                                       from: "a@example.com",
                                       to: "me@example.com",
                                       date: now,
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [],
                                       threadID: "thread-exact")
        let archiveMessage = EmailMessage(messageID: "message-archive",
                                          mailboxID: "Archive",
                                          accountName: "Work",
                                          subject: "Re: Exact disclosure",
                                          from: "b@example.com",
                                          to: "me@example.com",
                                          date: now.addingTimeInterval(60),
                                          snippet: "",
                                          isUnread: false,
                                          inReplyTo: "message-inbox",
                                          references: ["message-inbox"],
                                          threadID: "thread-exact")
        try await store.upsert(messages: [rootMessage, archiveMessage])
        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: rootMessage)])
        viewModel.selectNode(id: rootMessage.messageID)

        let confirmation = try await viewModel.prepareMailboxMoveConfirmation(
            path: "Projects/Filed",
            in: "Work"
        )

        XCTAssertEqual(confirmation.messageCount, 2)
        XCTAssertEqual(confirmation.sourceRouteGroups, [
            OrganizationMailRouteGroup(account: "Work", mailboxPath: "Archive", messageCount: 1),
            OrganizationMailRouteGroup(account: "Work", mailboxPath: "Inbox", messageCount: 1)
        ])
        XCTAssertEqual(confirmation.effect?.destination,
                       .mailbox(account: "Work", path: "Projects/Filed"))
        XCTAssertEqual(confirmation.reversibility, .conditionallyReversible)
        XCTAssertTrue(confirmation.effect?.hasCompleteMailDisclosure == true)
    }

    func testMoveSelectionToMailboxFolder_revalidatesChangedSourceRouteBeforeMailService() async throws {
        let suiteName = "ThreadFolderMailboxStaleDisclosure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let mailService = ThreadFolderMailboxMailServiceSpy()
        let viewModel = ThreadCanvasViewModel(
            settings: AutoRefreshSettings(userDefaults: defaults),
            store: store,
            organizationMailService: mailService,
            performsInitialSourceRefresh: false
        )
        let original = EmailMessage(messageID: "message-stale",
                                    mailboxID: "Inbox",
                                    accountName: "Work",
                                    subject: "Stale disclosure",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: Date(),
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [],
                                    threadID: "thread-stale")
        try await store.upsert(messages: [original])
        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: original)])
        viewModel.selectNode(id: original.messageID)
        let confirmation = try await viewModel.prepareMailboxMoveConfirmation(path: "Filed",
                                                                               in: "Work")
        let movedExternally = EmailMessage(messageID: original.messageID,
                                           mailboxID: "Archive",
                                           accountName: original.accountName,
                                           subject: original.subject,
                                           from: original.from,
                                           to: original.to,
                                           date: original.date,
                                           snippet: original.snippet,
                                           isUnread: original.isUnread,
                                           inReplyTo: original.inReplyTo,
                                           references: original.references,
                                           threadID: original.threadID)
        try await store.upsert(messages: [movedExternally])

        let didComplete = await viewModel.moveSelectionToMailboxFolder(confirmation: confirmation)
        let moveCallCount = await mailService.moveCallCount()

        XCTAssertFalse(didComplete)
        XCTAssertEqual(moveCallCount, 0)
        XCTAssertEqual(viewModel.mailboxActionStatusMessage,
                       String.localizedStringWithFormat(
                        NSLocalizedString("mailbox.action.move.failed", comment: ""),
                        NSLocalizedString("mailbox.action.error.stale_confirmation", comment: "")
                       ))
    }

    func testBottomBarMailboxStatus_expiresAfterFiveMinutes() {
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings())
        let now = Date()
        let first = EmailMessage(messageID: "msg-1",
                                 mailboxID: "Inbox",
                                 accountName: "Work",
                                 subject: "First",
                                 from: "a@example.com",
                                 to: "me@example.com",
                                 date: now,
                                 snippet: "",
                                 isUnread: false,
                                 inReplyTo: nil,
                                 references: [],
                                 threadID: "thread-1")

        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: first)])
        viewModel.selectNode(id: first.messageID)
        viewModel.setBottomBarMailboxActionStatusForTesting("Moved first thread.",
                                                            threadID: "thread-1",
                                                            expiresAt: now.addingTimeInterval(300))

        XCTAssertEqual(viewModel.bottomBarMailboxActionStatusMessage, "Moved first thread.")

        viewModel.expireBottomBarMailboxActionStatusesForTesting(referenceDate: now.addingTimeInterval(301))

        XCTAssertNil(viewModel.bottomBarMailboxActionStatusMessage)
    }
}

private actor ThreadFolderMailboxMailServiceSpy: OrganizationMailExecutionServicing {
    private var moves = 0

    func move(_ request: OrganizationMailMoveExecution) async throws -> OrganizationMailGatewayOutcome {
        moves += 1
        throw ThreadFolderMailboxMailServiceSpyError.unexpectedCall
    }

    func restore(_ request: OrganizationMailRestoreExecution) async throws -> OrganizationMailGatewayOutcome {
        throw ThreadFolderMailboxMailServiceSpyError.unexpectedCall
    }

    func createMailbox(_ request: OrganizationMailboxCreationExecution) async throws -> OrganizationMailGatewayOutcome {
        throw ThreadFolderMailboxMailServiceSpyError.unexpectedCall
    }

    func moveCallCount() -> Int {
        moves
    }
}

private enum ThreadFolderMailboxMailServiceSpyError: Error {
    case unexpectedCall
}
