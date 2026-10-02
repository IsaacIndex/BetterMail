import CoreData
import XCTest
@testable import BetterMail

final class MessageStoreBoundaryTests: XCTestCase {
    func testFetchBoundaryMessageReturnsNewestAndOldest() async throws {
        let defaults = UserDefaults(suiteName: "MessageStoreBoundaryTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let oldest = EmailMessage(messageID: "msg-oldest",
                                  mailboxID: "inbox",
                                  accountName: "test",
                                  subject: "Oldest",
                                  from: "a@example.com",
                                  to: "me@example.com",
                                  date: calendar.date(byAdding: .day, value: -20, to: baseDate)!,
                                  snippet: "",
                                  isUnread: false,
                                  inReplyTo: nil,
                                  references: [],
                                  threadID: "thread-1")
        let newest = EmailMessage(messageID: "msg-newest",
                                  mailboxID: "inbox",
                                  accountName: "test",
                                  subject: "Newest",
                                  from: "b@example.com",
                                  to: "me@example.com",
                                  date: calendar.date(byAdding: .day, value: -1, to: baseDate)!,
                                  snippet: "",
                                  isUnread: false,
                                  inReplyTo: nil,
                                  references: [],
                                  threadID: "thread-1")
        let ignored = EmailMessage(messageID: "msg-ignored",
                                   mailboxID: "inbox",
                                   accountName: "test",
                                   subject: "Ignored",
                                   from: "c@example.com",
                                   to: "me@example.com",
                                   date: calendar.date(byAdding: .day, value: -50, to: baseDate)!,
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-2")

        try await store.upsert(messages: [oldest, newest, ignored])

        let newestMatch = try await store.fetchBoundaryMessage(threadIDs: ["thread-1"], boundary: .newest)
        let oldestMatch = try await store.fetchBoundaryMessage(threadIDs: ["thread-1"], boundary: .oldest)

        XCTAssertEqual(newestMatch?.messageID, newest.messageID)
        XCTAssertEqual(oldestMatch?.messageID, oldest.messageID)
    }

    func testFetchBoundaryMessageReturnsNilForEmptyScope() async throws {
        let defaults = UserDefaults(suiteName: "MessageStoreBoundaryTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)

        let result = try await store.fetchBoundaryMessage(threadIDs: [], boundary: .newest)

        XCTAssertNil(result)
    }

    func testFetchBoundaryMessageNewestPrefersHighestMessageIDForEqualDates() async throws {
        let defaults = UserDefaults(suiteName: "MessageStoreBoundaryTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let sharedDate = Date(timeIntervalSince1970: 1_700_000_000)

        let lowerID = EmailMessage(messageID: "msg-001",
                                   mailboxID: "inbox",
                                   accountName: "test",
                                   subject: "Lower ID",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: sharedDate,
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-tie")
        let higherID = EmailMessage(messageID: "msg-999",
                                    mailboxID: "inbox",
                                    accountName: "test",
                                    subject: "Higher ID",
                                    from: "b@example.com",
                                    to: "me@example.com",
                                    date: sharedDate,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [],
                                    threadID: "thread-tie")

        try await store.upsert(messages: [lowerID, higherID])

        let newestMatch = try await store.fetchBoundaryMessage(threadIDs: ["thread-tie"], boundary: .newest)

        XCTAssertEqual(newestMatch?.messageID, higherID.messageID)
    }

    func testFetchMessages_withAllInboxesAliases_matchesInboxAndAllInboxes() async throws {
        let defaults = UserDefaults(suiteName: "MessageStoreBoundaryTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date()
        let inboxMessage = EmailMessage(messageID: "msg-inbox",
                                        mailboxID: "Inbox",
                                        accountName: "work",
                                        subject: "Inbox",
                                        from: "a@example.com",
                                        to: "me@example.com",
                                        date: now,
                                        snippet: "",
                                        isUnread: false,
                                        inReplyTo: nil,
                                        references: [])
        let allInboxesMessage = EmailMessage(messageID: "msg-all-inboxes",
                                             mailboxID: "All Inboxes",
                                             accountName: "work",
                                             subject: "All Inboxes",
                                             from: "a@example.com",
                                             to: "me@example.com",
                                             date: now,
                                             snippet: "",
                                             isUnread: false,
                                             inReplyTo: nil,
                                             references: [])
        let folderMessage = EmailMessage(messageID: "msg-folder",
                                         mailboxID: "Projects/Acme",
                                         accountName: "work",
                                         subject: "Folder",
                                         from: "a@example.com",
                                         to: "me@example.com",
                                         date: now,
                                         snippet: "",
                                         isUnread: false,
                                         inReplyTo: nil,
                                         references: [])
        try await store.upsert(messages: [inboxMessage, allInboxesMessage, folderMessage])

        let results = try await store.fetchMessages(since: nil,
                                                    limit: nil,
                                                    mailbox: "inbox",
                                                    account: nil,
                                                    includeAllInboxesAliases: true)

        XCTAssertEqual(Set(results.map(\.messageID)), Set(["msg-inbox", "msg-all-inboxes"]))
    }

    func testCountMessages_withFolderScope_matchesOnlyExactPath() async throws {
        let defaults = UserDefaults(suiteName: "MessageStoreBoundaryTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date()
        let inRangeDate = now.addingTimeInterval(-60)
        let start = now.addingTimeInterval(-3600)
        let range = DateInterval(start: start, end: now)

        let expected = EmailMessage(messageID: "msg-count-expected",
                                    mailboxID: "Projects/Acme",
                                    accountName: "Work",
                                    subject: "Expected",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: inRangeDate,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let sameLeafDifferentPath = EmailMessage(messageID: "msg-count-other-path",
                                                 mailboxID: "Clients/Acme",
                                                 accountName: "Work",
                                                 subject: "Other path",
                                                 from: "a@example.com",
                                                 to: "me@example.com",
                                                 date: inRangeDate,
                                                 snippet: "",
                                                 isUnread: false,
                                                 inReplyTo: nil,
                                                 references: [])
        try await store.upsert(messages: [expected, sameLeafDifferentPath])

        let count = try await store.countMessages(in: range, mailbox: "Projects/Acme")

        XCTAssertEqual(count, 1)
    }

    func testFetchMessages_withFolderScope_usesFullPathAndAccount() async throws {
        let defaults = UserDefaults(suiteName: "MessageStoreBoundaryTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date()
        let expected = EmailMessage(messageID: "msg-expected",
                                    mailboxID: "Projects/Acme",
                                    accountName: "Work",
                                    subject: "Expected",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: now,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let sameLeafDifferentPath = EmailMessage(messageID: "msg-other-path",
                                                 mailboxID: "Clients/Acme",
                                                 accountName: "Work",
                                                 subject: "Other path",
                                                 from: "a@example.com",
                                                 to: "me@example.com",
                                                 date: now,
                                                 snippet: "",
                                                 isUnread: false,
                                                 inReplyTo: nil,
                                                 references: [])
        let samePathDifferentAccount = EmailMessage(messageID: "msg-other-account",
                                                    mailboxID: "Projects/Acme",
                                                    accountName: "Personal",
                                                    subject: "Other account",
                                                    from: "a@example.com",
                                                    to: "me@example.com",
                                                    date: now,
                                                    snippet: "",
                                                    isUnread: false,
                                                    inReplyTo: nil,
                                                    references: [])
        try await store.upsert(messages: [expected, sameLeafDifferentPath, samePathDifferentAccount])

        let results = try await store.fetchMessages(since: nil,
                                                    limit: nil,
                                                    mailbox: "Projects/Acme",
                                                    account: "Work",
                                                    includeAllInboxesAliases: false)

        XCTAssertEqual(results.map(\.messageID), ["msg-expected"])
    }

    func testPruneCachedMail_keepsOnlySelectedAccountRows() async throws {
        let suiteName = "MessageStoreBoundaryTests-Prune-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date()
        let work = makeMessage(id: "work", account: "Work", date: now)
        let personal = makeMessage(id: "personal", account: "Personal", date: now)
        let legacy = makeMessage(id: "legacy", account: "", date: now)
        try await store.upsert(messages: [work, personal, legacy])
        await store.addActionItem(for: work, folderID: nil, tags: [])
        await store.addActionItem(for: personal, folderID: nil, tags: [])
        await store.addActionItem(for: legacy, folderID: nil, tags: [])

        let calendar = Calendar(identifier: .gregorian)
        let dayInterval = calendar.dateInterval(of: .day, for: now)!
        try await store.beginDayFetchCoverage(
            scope: DayFetchScope(mailbox: "inbox", account: "Work", displayName: "Work / Inbox"),
            dayInterval: dayInterval,
            attemptedAt: now
        )
        try await store.beginDayFetchCoverage(
            scope: DayFetchScope(mailbox: "inbox", account: "Personal", displayName: "Personal / Inbox"),
            dayInterval: dayInterval,
            attemptedAt: now
        )
        try await store.beginDayFetchCoverage(
            scope: DayFetchScope(mailbox: "inbox",
                                 account: nil,
                                 displayName: "All Inboxes",
                                 includesAllInboxAliases: true),
            dayInterval: dayInterval,
            attemptedAt: now
        )

        let result = try await store.pruneCachedMail(keepingAccount: "work")

        XCTAssertEqual(result.removedMessageCount, 2)
        XCTAssertEqual(result.removedActionItemCount, 2)
        XCTAssertEqual(result.removedCoverageCount, 2)
        let retainedMessages = try await store.fetchMessages()
        let retainedActionItems = await store.fetchActionItems()
        XCTAssertEqual(retainedMessages.map(\.accountName), ["Work"])
        XCTAssertEqual(retainedActionItems.map(\.accountName), ["Work"])
        let workCoverage = try await store.fetchDayFetchCoverages(
            scope: DayFetchScope(mailbox: "inbox", account: "Work", displayName: "Work / Inbox")
        )
        let personalCoverage = try await store.fetchDayFetchCoverages(
            scope: DayFetchScope(mailbox: "inbox", account: "Personal", displayName: "Personal / Inbox")
        )
        XCTAssertEqual(workCoverage.count, 1)
        XCTAssertTrue(personalCoverage.isEmpty)
    }

    func testFetchMessagesForThreading_selectedAccountConstrainsPinnedThreadIDs() async throws {
        let defaults = UserDefaults(suiteName: "MessageStoreBoundaryTests-ThreadScope-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let oldDate = Date(timeIntervalSinceNow: -86_400)
        let work = makeMessage(id: "work-pinned", account: "Work", date: oldDate, threadID: "shared")
        let personal = makeMessage(id: "personal-pinned",
                                   account: "Personal",
                                   date: oldDate,
                                   threadID: "shared")
        try await store.upsert(messages: [work, personal])

        let messages = try await store.fetchMessagesForThreading(
            since: Date(),
            account: "Work",
            includeThreadIDs: ["shared"]
        )

        XCTAssertEqual(messages.map(\.messageID), ["work-pinned"])
    }

    private func makeMessage(id: String,
                             account: String,
                             date: Date,
                             threadID: String? = nil) -> EmailMessage {
        EmailMessage(messageID: id,
                     mailboxID: "Inbox",
                     accountName: account,
                     subject: "Subject \(id)",
                     from: "sender@example.com",
                     to: "me@example.com",
                     date: date,
                     snippet: "",
                     isUnread: false,
                     inReplyTo: nil,
                     references: [],
                     threadID: threadID ?? "thread-\(id)")
    }

}
