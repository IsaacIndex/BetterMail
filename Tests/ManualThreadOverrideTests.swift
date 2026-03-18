import XCTest
@testable import BetterMail

final class ManualThreadOverrideTests: XCTestCase {
    func testManualGroupMergesJWZThreads() {
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!

        let messageA = EmailMessage(messageID: "a1",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "A",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: calendar.date(byAdding: .day, value: -2, to: baseDate)!,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let messageB = EmailMessage(messageID: "b1",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "B",
                                    from: "b@example.com",
                                    to: "me@example.com",
                                    date: calendar.date(byAdding: .day, value: -1, to: baseDate)!,
                                    snippet: "",
                                    isUnread: true,
                                    inReplyTo: nil,
                                    references: [])

        let threader = JWZThreader()
        let result = threader.buildThreads(from: [messageA, messageB])
        let threadAID = result.jwzThreadMap[messageA.threadKey]
        let threadBID = result.jwzThreadMap[messageB.threadKey]
        XCTAssertNotNil(threadAID)
        XCTAssertNotNil(threadBID)

        let manualGroup = ManualThreadGroup(id: "manual-test",
                                            jwzThreadIDs: [threadAID!, threadBID!],
                                            manualMessageKeys: [])
        let applied = threader.applyManualGroups([manualGroup], to: result)

        XCTAssertEqual(applied.result.threads.count, 1)
        XCTAssertEqual(applied.result.messageThreadMap[messageB.threadKey], manualGroup.id)
        XCTAssertTrue(applied.result.manualAttachmentMessageIDs.isEmpty)
    }

    func testManualAttachmentsTrackSelection() {
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!

        let messageA = EmailMessage(messageID: "a1",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "A",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: calendar.date(byAdding: .day, value: -2, to: baseDate)!,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let messageB = EmailMessage(messageID: "b1",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "B",
                                    from: "b@example.com",
                                    to: "me@example.com",
                                    date: calendar.date(byAdding: .day, value: -1, to: baseDate)!,
                                    snippet: "",
                                    isUnread: true,
                                    inReplyTo: nil,
                                    references: [])

        let threader = JWZThreader()
        let baseResult = threader.buildThreads(from: [messageA, messageB])
        let threadAID = baseResult.jwzThreadMap[messageA.threadKey]!
        let manualGroup = ManualThreadGroup(id: "manual-attach",
                                            jwzThreadIDs: [threadAID],
                                            manualMessageKeys: [messageB.threadKey])
        let applied = threader.applyManualGroups([manualGroup], to: baseResult)

        XCTAssertEqual(applied.result.threads.count, 1)
        XCTAssertTrue(applied.result.manualAttachmentMessageIDs.contains(messageB.messageID))
    }

    func testManualGroupExpandsAcrossLinkedJWZThreadsInCurrentWindow() {
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 18, hour: 12))!

        let rootMessage = EmailMessage(messageID: "root-a",
                                       mailboxID: "inbox",
                                       accountName: "",
                                       subject: "Meeting summary",
                                       from: "a@example.com",
                                       to: "me@example.com",
                                       date: calendar.date(byAdding: .day, value: -6, to: baseDate)!,
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [],
                                       threadID: "thread-a")
        let linkedRootMessage = EmailMessage(messageID: "root-b",
                                             mailboxID: "inbox",
                                             accountName: "",
                                             subject: "Re: Meeting summary",
                                             from: "b@example.com",
                                             to: "me@example.com",
                                             date: calendar.date(byAdding: .day, value: -1, to: baseDate)!,
                                             snippet: "",
                                             isUnread: true,
                                             inReplyTo: rootMessage.messageID,
                                             references: [rootMessage.messageID],
                                             threadID: "thread-b")
        let quickWalkthrough = EmailMessage(messageID: "thread-c",
                                            mailboxID: "inbox",
                                            accountName: "",
                                            subject: "Quick walkthrough",
                                            from: "c@example.com",
                                            to: "me@example.com",
                                            date: calendar.date(byAdding: .day, value: -2, to: baseDate)!,
                                            snippet: "",
                                            isUnread: false,
                                            inReplyTo: nil,
                                            references: [],
                                            threadID: "thread-c")

        let result = ThreadingResult(roots: [ThreadNode(message: rootMessage),
                                             ThreadNode(message: linkedRootMessage),
                                             ThreadNode(message: quickWalkthrough)],
                                     threads: [
                                        EmailThread(id: "thread-a",
                                                    rootMessageID: rootMessage.messageID,
                                                    subject: rootMessage.subject,
                                                    lastUpdated: rootMessage.date,
                                                    unreadCount: 0,
                                                    messageCount: 1),
                                        EmailThread(id: "thread-b",
                                                    rootMessageID: linkedRootMessage.messageID,
                                                    subject: linkedRootMessage.subject,
                                                    lastUpdated: linkedRootMessage.date,
                                                    unreadCount: 1,
                                                    messageCount: 1),
                                        EmailThread(id: "thread-c",
                                                    rootMessageID: quickWalkthrough.messageID,
                                                    subject: quickWalkthrough.subject,
                                                    lastUpdated: quickWalkthrough.date,
                                                    unreadCount: 0,
                                                    messageCount: 1)
                                     ],
                                     messageThreadMap: [
                                        rootMessage.threadKey: "thread-a",
                                        linkedRootMessage.threadKey: "thread-b",
                                        quickWalkthrough.threadKey: "thread-c"
                                     ],
                                     jwzThreadMap: [
                                        rootMessage.threadKey: "thread-a",
                                        linkedRootMessage.threadKey: "thread-b",
                                        quickWalkthrough.threadKey: "thread-c"
                                     ],
                                     manualGroupByMessageKey: [:],
                                     manualAttachmentMessageIDs: [])

        let manualGroup = ManualThreadGroup(id: "manual-test",
                                            jwzThreadIDs: ["thread-a", "thread-c"],
                                            manualMessageKeys: [])
        let applied = JWZThreader().applyManualGroups([manualGroup], to: result)

        XCTAssertEqual(applied.updatedGroups.first?.jwzThreadIDs, Set(["thread-a", "thread-b", "thread-c"]))
        XCTAssertEqual(applied.result.messageThreadMap[rootMessage.threadKey], manualGroup.id)
        XCTAssertEqual(applied.result.messageThreadMap[linkedRootMessage.threadKey], manualGroup.id)
        XCTAssertEqual(applied.result.messageThreadMap[quickWalkthrough.threadKey], manualGroup.id)
        XCTAssertEqual(applied.result.threads.count, 1)
    }
}
