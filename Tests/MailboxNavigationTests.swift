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

    func test_buildAccounts_placesInboxFirst_atRoot_preservingOrderForOthers() {
        let folders = [
            MailboxFolder(account: "Work", path: "Projects", name: "Projects", parentPath: nil),
            MailboxFolder(account: "Work", path: "Receipts", name: "Receipts", parentPath: nil),
            MailboxFolder(account: "Work", path: "Inbox", name: "Inbox", parentPath: nil),
            MailboxFolder(account: "Work", path: "Archive", name: "Archive", parentPath: nil)
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)

        XCTAssertEqual(accounts.first?.folders.map(\.name), ["Inbox", "Projects", "Receipts", "Archive"])
    }

    func test_buildAccounts_placesInboxFirst_amongChildren_preservingOrderForOthers() {
        let folders = [
            MailboxFolder(account: "Work", path: "Parent", name: "Parent", parentPath: nil),
            MailboxFolder(account: "Work", path: "Parent/Zeta", name: "Zeta", parentPath: "Parent"),
            MailboxFolder(account: "Work", path: "Parent/INBOX", name: "INBOX", parentPath: "Parent"),
            MailboxFolder(account: "Work", path: "Parent/Alpha", name: "Alpha", parentPath: "Parent")
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)

        XCTAssertEqual(accounts.first?.folders.first?.children.map(\.name), ["INBOX", "Zeta", "Alpha"])
    }

    func test_buildAccounts_dropsRootFolder_whenSameNameExistsUnderParent() {
        let folders = [
            MailboxFolder(account: "Work", path: "Azure Ignored", name: "Azure Ignored", parentPath: nil),
            MailboxFolder(account: "Work", path: "-------------------------", name: "-------------------------", parentPath: nil),
            MailboxFolder(account: "Work",
                          path: "-------------------------/Azure Ignored",
                          name: "Azure Ignored",
                          parentPath: "-------------------------")
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)
        guard let work = accounts.first(where: { $0.name == "Work" }) else {
            XCTFail("Expected Work account")
            return
        }

        XCTAssertFalse(work.folders.contains(where: { $0.path == "Azure Ignored" }))
        XCTAssertTrue(work.folders.contains(where: { $0.path == "-------------------------" }))
        XCTAssertEqual(work.folders.first(where: { $0.path == "-------------------------" })?.children.map(\.path),
                       ["-------------------------/Azure Ignored"])
    }

    func test_buildAccounts_keepsNestedFolders_afterRootMirrorRemoved() {
        let folders = [
            MailboxFolder(account: "Work", path: "Azure Ignored", name: "Azure Ignored", parentPath: nil),
            MailboxFolder(account: "Work", path: "Blue Points", name: "Blue Points", parentPath: nil),
            MailboxFolder(account: "Work", path: "Archive", name: "Archive", parentPath: nil),
            MailboxFolder(account: "Work", path: "-------------------------", name: "-------------------------", parentPath: nil),
            MailboxFolder(account: "Work",
                          path: "-------------------------/Azure Ignored",
                          name: "Azure Ignored",
                          parentPath: "-------------------------"),
            MailboxFolder(account: "Work",
                          path: "-------------------------/Blue Points",
                          name: "Blue Points",
                          parentPath: "-------------------------")
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)
        guard let work = accounts.first(where: { $0.name == "Work" }) else {
            XCTFail("Expected Work account")
            return
        }
        guard let dashed = work.folders.first(where: { $0.path == "-------------------------" }) else {
            XCTFail("Expected dashed root folder")
            return
        }

        XCTAssertFalse(work.folders.contains(where: { $0.path == "Azure Ignored" }))
        XCTAssertFalse(work.folders.contains(where: { $0.path == "Blue Points" }))
        XCTAssertTrue(work.folders.contains(where: { $0.path == "Archive" }))
        XCTAssertEqual(dashed.children.map(\.path),
                       ["-------------------------/Azure Ignored", "-------------------------/Blue Points"])
    }

    func test_buildAccounts_dedupesWithinAccount_only() {
        let folders = [
            MailboxFolder(account: "Work", path: "Azure Ignored", name: "Azure Ignored", parentPath: nil),
            MailboxFolder(account: "Work", path: "-------------------------", name: "-------------------------", parentPath: nil),
            MailboxFolder(account: "Work",
                          path: "-------------------------/Azure Ignored",
                          name: "Azure Ignored",
                          parentPath: "-------------------------"),
            MailboxFolder(account: "Personal", path: "Azure Ignored", name: "Azure Ignored", parentPath: nil)
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)
        guard let work = accounts.first(where: { $0.name == "Work" }) else {
            XCTFail("Expected Work account")
            return
        }
        guard let personal = accounts.first(where: { $0.name == "Personal" }) else {
            XCTFail("Expected Personal account")
            return
        }

        XCTAssertFalse(work.folders.contains(where: { $0.path == "Azure Ignored" }))
        XCTAssertEqual(personal.folders.map(\.path), ["Azure Ignored"])
    }

    func test_buildAccounts_preservesRootFolder_whenNoNestedNameMatch() {
        let folders = [
            MailboxFolder(account: "Work", path: "Azure Ignored", name: "Azure Ignored", parentPath: nil),
            MailboxFolder(account: "Work", path: "-------------------------", name: "-------------------------", parentPath: nil),
            MailboxFolder(account: "Work",
                          path: "-------------------------/Blue Points",
                          name: "Blue Points",
                          parentPath: "-------------------------")
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)
        guard let work = accounts.first(where: { $0.name == "Work" }) else {
            XCTFail("Expected Work account")
            return
        }

        XCTAssertTrue(work.folders.contains(where: { $0.path == "Azure Ignored" }))
        XCTAssertTrue(work.folders.contains(where: { $0.path == "-------------------------" }))
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

    func test_folderChoices_excludesRemovedRootMirrorPaths() {
        let folders = [
            MailboxFolder(account: "Work", path: "Azure Ignored", name: "Azure Ignored", parentPath: nil),
            MailboxFolder(account: "Work", path: "-------------------------", name: "-------------------------", parentPath: nil),
            MailboxFolder(account: "Work",
                          path: "-------------------------/Azure Ignored",
                          name: "Azure Ignored",
                          parentPath: "-------------------------")
        ]

        let accounts = MailboxHierarchyBuilder.buildAccounts(from: folders)
        guard let work = accounts.first(where: { $0.name == "Work" }) else {
            XCTFail("Expected Work account")
            return
        }
        let choices = MailboxHierarchyBuilder.folderChoices(for: work)
        let paths = choices.map(\.path)

        XCTAssertFalse(paths.contains("Azure Ignored"))
        XCTAssertTrue(paths.contains("-------------------------/Azure Ignored"))
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
