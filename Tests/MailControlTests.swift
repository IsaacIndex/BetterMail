import XCTest
@testable import BetterMail

final class MailControlTests: XCTestCase {
    func test_normalizedMessageID_whenBracketsAndWhitespace_stripsAndLowercases() throws {
        let normalized = try MailControl.normalizedMessageID(" <Test@Example.com> ")
        XCTAssertEqual(normalized, "test@example.com")
    }

    func test_messageURL_whenBareMessageID_wrapsAndEncodes() throws {
        let url = try MailControl.messageURL(for: "Test@Example.com")
        let urlString = url.absoluteString
        XCTAssertEqual(urlString, "message://%3Ctest@example.com%3E")
    }

    func test_messageSearchScript_whenGenerated_includesBracketedAndBareIDs() throws {
        let script = try MailControl.messageSearchScript(for: "Test@Example.com", limit: 3)
        XCTAssertTrue(script.contains("message id is \"<test@example.com>\""))
        XCTAssertTrue(script.contains("message id is \"test@example.com\""))
        XCTAssertTrue(script.contains("ignoring case"))
        XCTAssertTrue(script.contains("repeat with m in (every message whose message id is _id1)"))
        XCTAssertTrue(script.contains("greater than or equal to 3"))
    }

    func test_cleanMessageIDPreservingCase_stripsBracketsAndWhitespace() {
        let cleaned = MailControl.cleanMessageIDPreservingCase("  <CaseSensitive@Host.COM> ")
        XCTAssertEqual(cleaned, "CaseSensitive@Host.COM")
    }
}
