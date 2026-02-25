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
}
