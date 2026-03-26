import XCTest
@testable import BetterMail

@MainActor
final class NeedsAttentionTests: XCTestCase {

    private let calendar = Calendar.current
    private let now = Date()

    private func makeMessage(
        id: String = UUID().uuidString,
        from: String = "other@example.com",
        to: String = "me@example.com",
        date: Date? = nil
    ) -> EmailMessage {
        EmailMessage(messageID: id,
                     mailboxID: "inbox",
                     accountName: "Test",
                     subject: "Subject",
                     from: from,
                     to: to,
                     date: date ?? now,
                     snippet: "",
                     isUnread: false,
                     inReplyTo: nil,
                     references: [])
    }

    private func makeNode(
        from: String = "other@example.com",
        to: String = "me@example.com",
        date: Date? = nil,
        children: [ThreadNode] = []
    ) -> ThreadNode {
        ThreadNode(message: makeMessage(from: from, to: to, date: date), children: children)
    }

    // MARK: - extractEmailAddress

    func test_extractEmailAddress_angleBrackets_returnsAddress() {
        let result = ThreadCanvasViewModel.extractEmailAddress(from: "John <john@example.com>")
        XCTAssertEqual(result, "john@example.com")
    }

    func test_extractEmailAddress_plainAddress_returnsLowercased() {
        let result = ThreadCanvasViewModel.extractEmailAddress(from: "JOHN@Example.COM")
        XCTAssertEqual(result, "john@example.com")
    }

    func test_extractEmailAddress_emptyString_returnsEmpty() {
        let result = ThreadCanvasViewModel.extractEmailAddress(from: "")
        XCTAssertEqual(result, "")
    }

    // MARK: - newestMessage

    func test_newestMessage_singleNode_returnsRootMessage() {
        let node = makeNode(date: now)
        let newest = ThreadCanvasViewModel.newestMessage(in: node)
        XCTAssertEqual(newest.date, now)
    }

    func test_newestMessage_childIsNewer_returnsChildMessage() {
        let earlier = calendar.date(byAdding: .hour, value: -2, to: now)!
        let child = makeNode(from: "child@example.com", date: now)
        let root = makeNode(from: "root@example.com", date: earlier, children: [child])
        let newest = ThreadCanvasViewModel.newestMessage(in: root)
        XCTAssertEqual(newest.from, "child@example.com")
    }

    // MARK: - buildUserAddresses

    func test_buildUserAddresses_collectsToFieldAddresses() {
        let node = makeNode(to: "Me <me@example.com>")
        let addresses = ThreadCanvasViewModel.buildUserAddresses(from: [node])
        XCTAssertTrue(addresses.contains("me@example.com"))
    }

    func test_buildUserAddresses_multipleRecipients_collectsAll() {
        let msg = makeMessage(to: "a@example.com, B <b@example.com>")
        let node = ThreadNode(message: msg)
        let addresses = ThreadCanvasViewModel.buildUserAddresses(from: [node])
        XCTAssertTrue(addresses.contains("a@example.com"))
        XCTAssertTrue(addresses.contains("b@example.com"))
    }

    // MARK: - computeNeedsAttentionCount

    func test_computeNeedsAttention_inboundRecentThread_counts() {
        let root = makeNode(from: "other@example.com", to: "me@example.com", date: now)
        let count = ThreadCanvasViewModel.computeNeedsAttentionCount(
            roots: [root],
            actionItemThreadIDs: [],
            userAddresses: ["me@example.com"],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(count, 1)
    }

    func test_computeNeedsAttention_outboundLatestMessage_doesNotCount() {
        let earlier = calendar.date(byAdding: .hour, value: -1, to: now)!
        let inbound = makeNode(from: "other@example.com", to: "me@example.com", date: earlier)
        let outbound = makeNode(from: "me@example.com", to: "other@example.com", date: now)
        let root = ThreadNode(
            message: makeMessage(from: "other@example.com", to: "me@example.com", date: earlier),
            children: [outbound]
        )
        // Root is inbound but newest child is outbound (from me)
        _ = inbound // silence warning
        let count = ThreadCanvasViewModel.computeNeedsAttentionCount(
            roots: [root],
            actionItemThreadIDs: [],
            userAddresses: ["me@example.com"],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(count, 0)
    }

    func test_computeNeedsAttention_staleThread_doesNotCount() {
        let staleDate = calendar.date(byAdding: .day, value: -10, to: now)!
        let root = makeNode(from: "other@example.com", to: "me@example.com", date: staleDate)
        let count = ThreadCanvasViewModel.computeNeedsAttentionCount(
            roots: [root],
            actionItemThreadIDs: [],
            userAddresses: ["me@example.com"],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(count, 0)
    }

    func test_computeNeedsAttention_actionItemThread_doesNotCount() {
        let root = makeNode(from: "other@example.com", to: "me@example.com", date: now)
        let threadID = root.message.threadKey
        let count = ThreadCanvasViewModel.computeNeedsAttentionCount(
            roots: [root],
            actionItemThreadIDs: [threadID],
            userAddresses: ["me@example.com"],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(count, 0)
    }

    func test_computeNeedsAttention_identityMatchIsCaseInsensitive() {
        let root = makeNode(from: "Me@Example.COM", to: "other@example.com", date: now)
        let count = ThreadCanvasViewModel.computeNeedsAttentionCount(
            roots: [root],
            actionItemThreadIDs: [],
            userAddresses: ["me@example.com"],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(count, 0, "Case-insensitive from-me match should exclude the thread")
    }
}
