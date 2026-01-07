import XCTest
@testable import BetterMail

@MainActor
final class ThreadCanvasLayoutTests: XCTestCase {
    func testDayIndexForLastSevenDays() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 3
        components.day = 8
        components.hour = 12
        let today = calendar.date(from: components)!

        let sameDay = today
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!
        let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        XCTAssertEqual(ThreadCanvasDateHelper.dayIndex(for: sameDay, today: today, calendar: calendar), 0)
        XCTAssertEqual(ThreadCanvasDateHelper.dayIndex(for: threeDaysAgo, today: today, calendar: calendar), 3)
        XCTAssertNil(ThreadCanvasDateHelper.dayIndex(for: eightDaysAgo, today: today, calendar: calendar))
        XCTAssertNil(ThreadCanvasDateHelper.dayIndex(for: tomorrow, today: today, calendar: calendar))
    }

    func testColumnOrderingUsesLatestThreadActivity() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 3
        components.day = 8
        components.hour = 9
        let today = calendar.date(from: components)!

        let olderRootMessage = EmailMessage(messageID: "root-older",
                                            mailboxID: "inbox",
                                            subject: "Older Thread",
                                            from: "a@example.com",
                                            to: "me@example.com",
                                            date: calendar.date(byAdding: .day, value: -5, to: today)!,
                                            snippet: "",
                                            isUnread: false,
                                            inReplyTo: nil,
                                            references: [],
                                            threadID: "thread-old")
        let newerChildMessage = EmailMessage(messageID: "child-newer",
                                             mailboxID: "inbox",
                                             subject: "Older Thread",
                                             from: "b@example.com",
                                             to: "me@example.com",
                                             date: calendar.date(byAdding: .day, value: -1, to: today)!,
                                             snippet: "",
                                             isUnread: false,
                                             inReplyTo: nil,
                                             references: [],
                                             threadID: "thread-old")
        let rootWithNewerChild = ThreadNode(message: olderRootMessage, children: [ThreadNode(message: newerChildMessage)])

        let newerRootMessage = EmailMessage(messageID: "root-newer",
                                            mailboxID: "inbox",
                                            subject: "Newer Thread",
                                            from: "c@example.com",
                                            to: "me@example.com",
                                            date: calendar.date(byAdding: .day, value: -2, to: today)!,
                                            snippet: "",
                                            isUnread: false,
                                            inReplyTo: nil,
                                            references: [],
                                            threadID: "thread-new")
        let newerRoot = ThreadNode(message: newerRootMessage)

        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0)
        let layout = ThreadSidebarViewModel.canvasLayout(for: [newerRoot, rootWithNewerChild],
                                                         metrics: metrics,
                                                         today: today,
                                                         calendar: calendar)

        XCTAssertEqual(layout.columns.first?.id, "thread-old")
        XCTAssertEqual(layout.columns.count, 2)
    }

    func testSelectionMappingFindsNestedNode() {
        let rootMessage = EmailMessage(messageID: "root",
                                       mailboxID: "inbox",
                                       subject: "Root",
                                       from: "a@example.com",
                                       to: "me@example.com",
                                       date: Date(),
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [],
                                       threadID: "thread-root")
        let childMessage = EmailMessage(messageID: "child",
                                        mailboxID: "inbox",
                                        subject: "Child",
                                        from: "b@example.com",
                                        to: "me@example.com",
                                        date: Date(),
                                        snippet: "",
                                        isUnread: false,
                                        inReplyTo: nil,
                                        references: [],
                                        threadID: "thread-root")

        let root = ThreadNode(message: rootMessage, children: [ThreadNode(message: childMessage)])
        let match = ThreadSidebarViewModel.node(matching: "child", in: [root])
        let missing = ThreadSidebarViewModel.node(matching: "missing", in: [root])

        XCTAssertEqual(match?.id, "child")
        XCTAssertNil(missing)
    }
}
