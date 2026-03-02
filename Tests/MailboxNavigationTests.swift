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

        XCTAssertEqual(accounts.map(\.name), ["Work", "Personal"])
        let work = accounts.first(where: { $0.name == "Work" })
        XCTAssertEqual(work?.folders.map(\.name), ["Clients", "Receipts"])
        XCTAssertEqual(work?.folders.first?.children.map(\.name), ["Acme"])
    }

    func test_buildAccounts_preservesSourceSiblingOrder() {
        let folders = [
            MailboxFolder(account: "Work", path: "Projects", name: "Projects", parentPath: nil),
            MailboxFolder(account: "Work", path: "Projects/Zeta", name: "Zeta", parentPath: "Projects"),
            MailboxFolder(account: "Work", path: "Projects/Alpha", name: "Alpha", parentPath: "Projects")
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)

        XCTAssertEqual(accounts.first?.folders.first?.children.map(\.name), ["Zeta", "Alpha"])
    }

    func test_buildAccounts_infersParentFromPath_whenParentPathMissing() {
        let folders = [
            MailboxFolder(account: "Work", path: "Projects", name: "Projects", parentPath: nil),
            MailboxFolder(account: "Work", path: "Projects/Azure", name: "Azure", parentPath: nil)
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)

        XCTAssertEqual(accounts.first?.folders.map(\.name), ["Projects"])
        XCTAssertEqual(accounts.first?.folders.first?.children.map(\.name), ["Azure"])
    }

    func test_buildAccounts_infersParentFromDotDelimitedPath_whenParentPathMissing() {
        let folders = [
            MailboxFolder(account: "Work", path: "Projects", name: "Projects", parentPath: nil),
            MailboxFolder(account: "Work", path: "Projects.Azure", name: "Azure", parentPath: nil)
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)

        XCTAssertEqual(accounts.first?.folders.map(\.name), ["Projects"])
        XCTAssertEqual(accounts.first?.folders.first?.children.map(\.name), ["Azure"])
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

    func test_filterFolderTree_emptyQuery_returnsUnchangedTree() {
        let nodes = [
            MailboxFolderNode(account: "Work",
                              path: "Clients",
                              name: "Clients",
                              parentPath: nil,
                              children: [
                                MailboxFolderNode(account: "Work",
                                                  path: "Clients/Acme",
                                                  name: "Acme",
                                                  parentPath: "Clients",
                                                  children: [])
                              ])
        ]

        let filtered = MailboxHierarchyBuilder.filterFolderTree(nodes, query: " ")

        XCTAssertEqual(filtered, nodes)
    }

    func test_filterFolderTree_matchesLeaf_preservesAncestors() {
        let nodes = [
            MailboxFolderNode(account: "Work",
                              path: "Clients",
                              name: "Clients",
                              parentPath: nil,
                              children: [
                                MailboxFolderNode(account: "Work",
                                                  path: "Clients/Acme",
                                                  name: "Acme",
                                                  parentPath: "Clients",
                                                  children: []),
                                MailboxFolderNode(account: "Work",
                                                  path: "Clients/Globex",
                                                  name: "Globex",
                                                  parentPath: "Clients",
                                                  children: [])
                              ])
        ]

        let filtered = MailboxHierarchyBuilder.filterFolderTree(nodes, query: "acme")

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name, "Clients")
        XCTAssertEqual(filtered.first?.children.map(\.name), ["Acme"])
    }

    func test_filterFolderTree_caseInsensitiveMatching() {
        let nodes = [
            MailboxFolderNode(account: "Work",
                              path: "Receipts/2025",
                              name: "2025",
                              parentPath: "Receipts",
                              children: [])
        ]

        let filtered = MailboxHierarchyBuilder.filterFolderTree(nodes, query: "RECEIPTS")

        XCTAssertEqual(filtered.map(\.path), ["Receipts/2025"])
    }

    func test_filterFolderTree_noMatches_returnsEmpty() {
        let nodes = [
            MailboxFolderNode(account: "Work",
                              path: "Projects",
                              name: "Projects",
                              parentPath: nil,
                              children: [])
        ]

        let filtered = MailboxHierarchyBuilder.filterFolderTree(nodes, query: "invoices")

        XCTAssertTrue(filtered.isEmpty)
    }

    func test_filterFolderTree_parentMatch_keepsSubtree() {
        let nodes = [
            MailboxFolderNode(account: "Work",
                              path: "Projects",
                              name: "Projects",
                              parentPath: nil,
                              children: [
                                MailboxFolderNode(account: "Work",
                                                  path: "Projects/Alpha",
                                                  name: "Alpha",
                                                  parentPath: "Projects",
                                                  children: []),
                                MailboxFolderNode(account: "Work",
                                                  path: "Projects/Beta",
                                                  name: "Beta",
                                                  parentPath: "Projects",
                                                  children: [])
                              ])
        ]

        let filtered = MailboxHierarchyBuilder.filterFolderTree(nodes, query: "projects")

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.children.map(\.name), ["Alpha", "Beta"])
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

    func test_mailboxScope_allEmails_defaultsToInboxFetchPath() {
        XCTAssertEqual(MailboxScope.allEmails.mailboxPath, "inbox")
        XCTAssertNil(MailboxScope.allEmails.accountName)
    }

    func test_mailboxScope_allFolders_defaultsToInboxFetchPath() {
        XCTAssertEqual(MailboxScope.allFolders.mailboxPath, "inbox")
        XCTAssertNil(MailboxScope.allFolders.accountName)
        XCTAssertFalse(MailboxScope.allFolders.usesAllInboxAliases)
    }

    func test_mailboxPathFormatter_leafName_returnsFinalPathSegment() {
        XCTAssertEqual(MailboxPathFormatter.leafName(from: "Projects/Acme/Invoices"), "Invoices")
        XCTAssertEqual(MailboxPathFormatter.leafName(from: "Inbox"), "Inbox")
        XCTAssertNil(MailboxPathFormatter.leafName(from: "   "))
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
