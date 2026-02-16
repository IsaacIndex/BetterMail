import XCTest
@testable import BetterMail

final class MailboxNavigationTests: XCTestCase {
    func test_buildAccounts_createsNestedFolderTreePerAccount() {
        let folders = [
            MailboxFolder(account: "Work", path: "Clients", name: "Clients", parentPath: nil),
            MailboxFolder(account: "Work", path: "Clients/Acme", name: "Acme", parentPath: "Clients"),
            MailboxFolder(account: "Work", path: "Receipts", name: "Receipts", parentPath: nil),
            MailboxFolder(account: "Personal", path: "Archive", name: "Archive", parentPath: nil)
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)

        XCTAssertEqual(accounts.map(\.name), ["Personal", "Work"])
        let work = accounts.first(where: { $0.name == "Work" })
        XCTAssertEqual(work?.folders.map(\.name), ["Clients", "Receipts"])
        XCTAssertEqual(work?.folders.first?.children.map(\.name), ["Acme"])
    }

    func test_folderChoices_returnsFullPathChoices() {
        let account = MailboxAccount(name: "Work",
                                     folders: [
                                        MailboxFolderNode(account: "Work",
                                                          path: "Clients",
                                                          name: "Clients",
                                                          parentPath: nil,
                                                          children: [MailboxFolderNode(account: "Work",
                                                                                       path: "Clients/Acme",
                                                                                       name: "Acme",
                                                                                       parentPath: "Clients",
                                                                                       children: [])])
                                     ])

        let choices = MailboxHierarchyBuilder.folderChoices(for: account)

        XCTAssertEqual(choices.map(\.displayPath), ["Clients", "Clients/Acme"])
    }

    func test_selectedMailboxActionAccount_whenSingleAccount_returnsAccount() {
        let nodes = [
            makeNode(messageID: "m1", account: "Work"),
            makeNode(messageID: "m2", account: "Work")
        ]

        XCTAssertEqual(ThreadCanvasViewModel.selectedMailboxActionAccount(for: nodes), "Work")
    }

    func test_selectedMailboxActionAccount_whenMixedAccounts_returnsNil() {
        let nodes = [
            makeNode(messageID: "m1", account: "Work"),
            makeNode(messageID: "m2", account: "Personal")
        ]

        XCTAssertNil(ThreadCanvasViewModel.selectedMailboxActionAccount(for: nodes))
    }
}

private extension MailboxNavigationTests {
    func makeNode(messageID: String, account: String) -> ThreadNode {
        let message = EmailMessage(messageID: messageID,
                                   mailboxID: "Inbox",
                                   accountName: account,
                                   subject: "Subject \(messageID)",
                                   from: "sender@example.com",
                                   to: "me@example.com",
                                   date: Date(),
                                   snippet: "Snippet",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-\(messageID)")
        return ThreadNode(message: message)
    }
}
