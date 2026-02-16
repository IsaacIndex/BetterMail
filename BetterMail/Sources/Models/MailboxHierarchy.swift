import Foundation

internal enum MailboxScope: Hashable {
    case allInboxes
    case mailboxFolder(account: String, path: String)

    internal var mailboxPath: String {
        switch self {
        case .allInboxes:
            return "inbox"
        case .mailboxFolder(_, let path):
            return path
        }
    }

    internal var accountName: String? {
        switch self {
        case .allInboxes:
            return nil
        case .mailboxFolder(let account, _):
            return account
        }
    }

    internal var mailboxLeafName: String {
        let parts = mailboxPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return parts.last ?? mailboxPath
    }

    internal var usesAllInboxAliases: Bool {
        if case .allInboxes = self {
            return true
        }
        return false
    }
}

internal struct MailboxFolder: Identifiable, Hashable {
    internal let account: String
    internal let path: String
    internal let name: String
    internal let parentPath: String?

    internal var id: String {
        "\(account)|\(path)"
    }
}

internal struct MailboxFolderNode: Identifiable, Hashable {
    internal let account: String
    internal let path: String
    internal let name: String
    internal let parentPath: String?
    internal var children: [MailboxFolderNode]

    internal var id: String {
        "\(account)|\(path)"
    }

    internal var childNodes: [MailboxFolderNode]? {
        children.isEmpty ? nil : children
    }
}

internal struct MailboxAccount: Identifiable, Hashable {
    internal let name: String
    internal let folders: [MailboxFolderNode]

    internal var id: String {
        name
    }
}

internal struct MailboxFolderChoice: Identifiable, Hashable {
    internal let account: String
    internal let path: String
    internal let displayPath: String

    internal var id: String {
        "\(account)|\(path)"
    }
}

internal enum MailboxHierarchyBuilder {
    internal static func buildAccounts(from folders: [MailboxFolder]) -> [MailboxAccount] {
        let grouped = Dictionary(grouping: folders) { $0.account }
        return grouped
            .map { account, accountFolders in
                MailboxAccount(name: account,
                               folders: buildTree(from: accountFolders))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    internal static func folderChoices(for account: MailboxAccount) -> [MailboxFolderChoice] {
        flatten(account.folders)
            .map {
                MailboxFolderChoice(account: account.name,
                                    path: $0.path,
                                    displayPath: $0.path)
            }
            .sorted { $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending }
    }

    private static func buildTree(from folders: [MailboxFolder]) -> [MailboxFolderNode] {
        let foldersByPath = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0) })
        var childrenByParent: [String?: [MailboxFolder]] = [:]

        for folder in folders {
            let validParent = folder.parentPath.flatMap { foldersByPath[$0] == nil ? nil : $0 }
            childrenByParent[validParent, default: []].append(folder)
        }

        func buildNode(_ folder: MailboxFolder) -> MailboxFolderNode {
            let sortedChildren = (childrenByParent[folder.path] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map(buildNode)
            return MailboxFolderNode(account: folder.account,
                                     path: folder.path,
                                     name: folder.name,
                                     parentPath: folder.parentPath,
                                     children: sortedChildren)
        }

        let roots = (childrenByParent[nil] ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(buildNode)

        return roots
    }

    private static func flatten(_ nodes: [MailboxFolderNode]) -> [MailboxFolderNode] {
        var results: [MailboxFolderNode] = []
        results.reserveCapacity(nodes.count)
        for node in nodes {
            results.append(node)
            results.append(contentsOf: flatten(node.children))
        }
        return results
    }
}
