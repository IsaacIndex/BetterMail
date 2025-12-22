#if canImport(XCTest)
import XCTest
@testable import BetterMail

final class JWZThreaderTests: XCTestCase {
    func testSubjectOnlyMessagesMergeWhenSubjectAndContentAlign() {
        let baseDate = Date()
        let messages = [
            makeMessage(id: "msg-a",
                        subject: "RE: IBM Consulting GCG Newsletter in 2025 December preparation for [Innovation] module",
                        snippet: "Align on Innovation module talking points and newsletter summary.",
                        from: "Andy Wang <andy@example.com>",
                        to: "Isaac Wong <isaac@example.com>",
                        date: baseDate),
            makeMessage(id: "msg-b",
                        subject: "IBM Consulting GCG Newsletter in 2025 December preparation for [Innovation] module",
                        snippet: "Newsletter prep for Innovation module deliverables in December.",
                        from: "Victor Lee <victor@example.com>",
                        to: "Elisa Lin <elisa@example.com>",
                        date: baseDate.addingTimeInterval(-60 * 60 * 12))
        ]

        let result = JWZThreader().buildThreads(from: messages)

        XCTAssertEqual(result.threads.count, 1)
        XCTAssertEqual(result.threads.first?.messageCount, 2)
    }

    func testSubjectOnlyMessagesDoNotMergeWhenContentDiffers() {
        let baseDate = Date()
        let messages = [
            makeMessage(id: "msg-a",
                        subject: "Quarterly Results",
                        snippet: "Budget variance review for Q4 finance forecast and margins.",
                        from: "Finance <finance@example.com>",
                        to: "Isaac Wong <isaac@example.com>",
                        date: baseDate),
            makeMessage(id: "msg-b",
                        subject: "RE: Quarterly Results",
                        snippet: "Team offsite agenda and staffing updates unrelated to finance.",
                        from: "People Ops <people@example.com>",
                        to: "Casey <casey@example.com>",
                        date: baseDate.addingTimeInterval(-60 * 60))
        ]

        let result = JWZThreader().buildThreads(from: messages)

        XCTAssertEqual(result.threads.count, 2)
    }

    private func makeMessage(id: String,
                             subject: String,
                             snippet: String,
                             from: String,
                             to: String,
                             date: Date) -> EmailMessage {
        EmailMessage(messageID: id,
                     mailboxID: "inbox",
                     subject: subject,
                     from: from,
                     to: to,
                     date: date,
                     snippet: snippet,
                     isUnread: true,
                     inReplyTo: nil,
                     references: [])
    }
}
#endif
