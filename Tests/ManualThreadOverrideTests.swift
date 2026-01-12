import XCTest
@testable import BetterMail

final class ManualThreadOverrideTests: XCTestCase {
    func testManualGroupMergesJWZThreads() {
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!

        let messageA = EmailMessage(messageID: "a1",
                                    mailboxID: "inbox",
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
}
