import XCTest
@testable import BetterMail

final class ManualThreadOverrideTests: XCTestCase {
    func testManualOverrideMergesThreads() {
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
        let targetThreadID = result.messageThreadMap[messageA.threadKey]
        XCTAssertNotNil(targetThreadID)

        let overrides = [messageB.threadKey: targetThreadID!]
        let applied = threader.applyManualOverrides(overrides, to: result)

        XCTAssertEqual(applied.result.threads.count, 1)
        XCTAssertEqual(applied.result.messageThreadMap[messageB.threadKey], targetThreadID)
        XCTAssertTrue(applied.result.manualOverrideMessageIDs.contains(messageB.messageID))
        XCTAssertTrue(applied.invalidKeys.isEmpty)
    }

    func testManualOverrideRemovalRestoresThreads() {
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
        let targetThreadID = baseResult.messageThreadMap[messageA.threadKey]
        let overrides = [messageB.threadKey: targetThreadID!]
        let applied = threader.applyManualOverrides(overrides, to: baseResult)

        XCTAssertEqual(applied.result.threads.count, 1)

        let ungrouped = threader.applyManualOverrides([:], to: baseResult)
        XCTAssertEqual(ungrouped.result.threads.count, 2)
        XCTAssertTrue(ungrouped.result.manualOverrideMessageIDs.isEmpty)
    }
}
