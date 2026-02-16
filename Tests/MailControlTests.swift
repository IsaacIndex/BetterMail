import XCTest
@testable import BetterMail

final class MailControlTests: XCTestCase {
    func test_normalizedMessageID_whenBracketsAndWhitespace_stripsAndLowercases() throws {
        let normalized = try MailControl.normalizedMessageID(" <Test@Example.com> ")
        XCTAssertEqual(normalized, "test@example.com")
    }

    func test_cleanMessageIDPreservingCase_stripsBracketsAndWhitespace() {
        let cleaned = MailControl.cleanMessageIDPreservingCase("  <CaseSensitive@Host.COM> ")
        XCTAssertEqual(cleaned, "CaseSensitive@Host.COM")
    }

    func test_resolveTargetingPath_whenMessageIDOpens_returnsMessageID() throws {
        let metadata = MailControl.OpenMessageMetadata(subject: "Subject",
                                                       sender: "a@example.com",
                                                       date: Date(),
                                                       mailbox: "Inbox",
                                                       account: "iCloud")
        var filteredFallbackCalled = false

        let result = try MailControl.resolveTargetingPath(messageID: "Test@Example.com",
                                                          metadata: metadata,
                                                          openViaAppleScript: { _ in true },
                                                          openViaFilteredFallback: { _ in
                                                              filteredFallbackCalled = true
                                                              return .notFound
                                                          })

        XCTAssertEqual(result, .openedMessageID)
        XCTAssertFalse(filteredFallbackCalled)
    }

    func test_resolveTargetingPath_whenMessageIDFails_usesFilteredFallback() throws {
        let metadata = MailControl.OpenMessageMetadata(subject: "Subject",
                                                       sender: "a@example.com",
                                                       date: Date(),
                                                       mailbox: "Inbox",
                                                       account: "iCloud")
        var failureNotified = false

        let result = try MailControl.resolveTargetingPath(messageID: "Test@Example.com",
                                                          metadata: metadata,
                                                          openViaAppleScript: { _ in false },
                                                          openViaFilteredFallback: { _ in .opened },
                                                          onMessageIDFailure: { failureNotified = true })

        XCTAssertEqual(result, .openedFilteredFallback)
        XCTAssertTrue(failureNotified)
    }

    func test_resolveTargetingPath_whenNoMatch_returnsNotFound() throws {
        let metadata = MailControl.OpenMessageMetadata(subject: "Subject",
                                                       sender: "a@example.com",
                                                       date: Date(),
                                                       mailbox: "",
                                                       account: "")

        let result = try MailControl.resolveTargetingPath(messageID: "Test@Example.com",
                                                          metadata: metadata,
                                                          openViaAppleScript: { _ in false },
                                                          openViaFilteredFallback: { _ in .notFound })

        XCTAssertEqual(result, .notFound)
    }

    func test_buildMoveMessagesScript_includesDestinationAndMessageIDs() {
        let script = MailControl.buildMoveMessagesScript(messageIDs: ["abc@example.com", "def@example.com"],
                                                         mailboxPath: "Projects/Acme",
                                                         account: "Work")

        XCTAssertTrue(script.contains("set _messageIDs to {\"abc@example.com\", \"def@example.com\"}"))
        XCTAssertTrue(script.contains("mailbox \"Acme\" of mailbox \"Projects\" of account \"Work\""))
    }

    func test_buildCreateMailboxScript_withParent_usesParentMailboxReference() {
        let script = MailControl.buildCreateMailboxScript(folderName: "Follow Up",
                                                          account: "Work",
                                                          parentPath: "Projects/Acme")

        XCTAssertTrue(script.contains("set _container to mailbox \"Acme\" of mailbox \"Projects\" of account \"Work\""))
        XCTAssertTrue(script.contains("name:\"Follow Up\""))
    }

    func test_buildCreateMailboxScript_withoutParent_targetsAccountRoot() {
        let script = MailControl.buildCreateMailboxScript(folderName: "Receipts",
                                                          account: "Work",
                                                          parentPath: nil)

        XCTAssertTrue(script.contains("set _container to account \"Work\""))
        XCTAssertTrue(script.contains("name:\"Receipts\""))
    }
}
