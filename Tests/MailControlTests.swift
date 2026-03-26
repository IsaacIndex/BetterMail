import XCTest
@testable import BetterMail

final class MailControlTests: XCTestCase {
    func test_filteredFallbackOutcome_acceptsTrueDescriptor() {
        let descriptor = NSAppleEventDescriptor(boolean: true)

        let outcome = MailControl.filteredFallbackOutcome(from: descriptor)

        XCTAssertEqual(outcome, .opened)
    }

    func test_filteredFallbackOutcome_acceptsFalseDescriptor() {
        let descriptor = NSAppleEventDescriptor(boolean: false)

        let outcome = MailControl.filteredFallbackOutcome(from: descriptor)

        XCTAssertEqual(outcome, .notFound)
    }

    func test_cleanMessageIDPreservingCase_stripsBracketsAndWhitespace() {
        let cleaned = MailControl.cleanMessageIDPreservingCase("  <CaseSensitive@Host.COM> ")
        XCTAssertEqual(cleaned, "CaseSensitive@Host.COM")
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

    func test_filteredFallbackOpenScript_searchesAllMessages_notJustInbox() {
        let script = MailControl.filteredFallbackOpenScript(subject: "Status Update",
                                                            sender: "alice@example.com",
                                                            mailbox: "Archive/Clients",
                                                            account: "Work",
                                                            year: 2026,
                                                            month: 3,
                                                            day: 10)

        XCTAssertTrue(script.contains("set _sourceMailboxPath to \"Archive/Clients\""))
        XCTAssertTrue(script.contains("set _sourceAccount to \"Work\""))
        XCTAssertTrue(script.contains("set _sourceMailbox to my resolveMailboxByPath(_sourceAccount, _sourceMailboxPath)"))
        XCTAssertTrue(script.contains("if my openFirstMatchingMessageInMailbox(_sourceMailbox, _startDate, _endDate, _targetSubject, _targetSender) then return true"))
        XCTAssertTrue(script.contains("set _accounts to my matchingAccounts(_sourceAccount)"))
        XCTAssertTrue(script.contains("set _candidateMailboxes to my collectDescendantMailboxes(_accountValue)"))
        XCTAssertFalse(script.contains("first message of inbox"))
        XCTAssertFalse(script.contains("set _matches to (every message whose subject contains _targetSubject and sender contains _targetSender"))
    }

    func test_buildMoveMessagesByInternalIDScript_includesDestinationAndInternalIDs() {
        let script = MailControl.buildMoveMessagesByInternalIDScript(internalIDs: ["101", "202"],
                                                                     mailboxPath: "Projects/Acme",
                                                                     account: "Work")

        XCTAssertTrue(script.contains("set _internalIDs to {\"101\", \"202\"}"))
        XCTAssertTrue(script.contains("set _sourceAccounts to {\"\", \"\"}"))
        XCTAssertTrue(script.contains("set _sourceMailboxPaths to {\"\", \"\"}"))
        XCTAssertTrue(script.contains("set _destinationAccount to \"Work\""))
        XCTAssertTrue(script.contains("set _destinationPath to \"Projects/Acme\""))
        XCTAssertTrue(script.contains("set _destMailbox to my resolveMailboxByPath(_destinationAccount, _destinationPath)"))
        XCTAssertTrue(script.contains("set _sourceCacheKeys to {}"))
        XCTAssertTrue(script.contains("set _sourceCacheMailboxes to {}"))
        XCTAssertTrue(script.contains("on appendResolvedMessages(_queryResults, _matches)"))
        XCTAssertTrue(script.contains("messages of _sourceMailbox whose id is _idNumber"))
        XCTAssertTrue(script.contains("messages of _sourceMailbox whose id is _idText"))
        XCTAssertTrue(script.contains("set _resolvedMessage to contents of _m"))
        XCTAssertTrue(script.contains("move _resolvedMatch to _destMailbox"))
        XCTAssertTrue(script.contains("if _sourceMailboxPath is not \"\" then"))
        XCTAssertTrue(script.contains("every message whose id is _idText"))
    }

    func test_buildResolveInternalMailIDScript_includesMailboxAndMatchingFields() {
        let receivedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let script = MailControl.buildResolveInternalMailIDScript(mailboxPath: "Inbox",
                                                                  account: "Work",
                                                                  subject: "Status Update",
                                                                  senderToken: "alice@example.com",
                                                                  receivedAt: receivedAt,
                                                                  toleranceSeconds: 120)

        XCTAssertTrue(script.contains("set _sourceAccount to \"Work\""))
        XCTAssertTrue(script.contains("set _sourceMailboxPath to \"Inbox\""))
        XCTAssertTrue(script.contains("set _accounts to my matchingAccounts(_sourceAccount)"))
        XCTAssertTrue(script.contains("set _mbx to my resolveMailboxByPath(_sourceAccount, _sourceMailboxPath)"))
        XCTAssertTrue(script.contains("set _allowAccountWideFallback to true"))
        XCTAssertTrue(script.contains("set _targetSubject to \"Status Update\""))
        XCTAssertTrue(script.contains("set _targetSender to \"alice@example.com\""))
        XCTAssertTrue(script.contains("return {_matchCount, _firstID, _usedAccountWideFallback, _fallbackMailboxCount, _fallbackMessageCount}"))
    }

    func test_buildRefreshScript_omitsBodyContentFetch() async throws {
        let client = MailAppleScriptClient()

        let script = await client.buildRefreshScriptForTesting(mailbox: "inbox",
                                                               account: nil,
                                                               limit: 4,
                                                               since: nil)

        XCTAssertTrue(script.contains("set _src to (source of m as string)"))
        XCTAssertFalse(script.contains("set _body to (content of m as string)"))
    }
}
