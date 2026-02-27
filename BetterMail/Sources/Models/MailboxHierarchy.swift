import Foundation

internal enum MailboxScope: Hashable {
    case allEmails
    case allFolders
    case allInboxes
    case mailboxFolder(account: String, path: String)

    internal var mailboxPath: String {
        switch self {
        case .allEmails, .allFolders, .allInboxes:
            return "inbox"
        case .mailboxFolder(_, let path):
            return path
        }
    }

    internal var accountName: String? {
        switch self {
        case .allEmails, .allFolders, .allInboxes:
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

internal enum MailboxPathFormatter {
    internal static func leafName(from path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return (parts.last ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
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
        var accountOrder: [String] = []
        var foldersByAccount: [String: [MailboxFolder]] = [:]

        for folder in folders {
            if foldersByAccount[folder.account] == nil {
                accountOrder.append(folder.account)
            }
            foldersByAccount[folder.account, default: []].append(folder)
        }

        return accountOrder.map { account in
            MailboxAccount(name: account,
                           folders: buildTree(from: foldersByAccount[account] ?? []))
        }
    }

    internal static func folderChoices(for account: MailboxAccount) -> [MailboxFolderChoice] {
        flatten(account.folders)
            .map {
                MailboxFolderChoice(account: account.name,
                                    path: $0.path,
                                    displayPath: $0.path)
            }
    }

    private static func buildTree(from folders: [MailboxFolder]) -> [MailboxFolderNode] {
        let foldersByPath = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0) })
        let knownPaths = Set(foldersByPath.keys)
        var childrenByParent: [String?: [MailboxFolder]] = [:]

        for folder in folders {
            let inferredParent = inferredParentPath(from: folder.path, knownPaths: knownPaths)
            let candidateParent = folder.parentPath ?? inferredParent
            let validParent = candidateParent.flatMap { foldersByPath[$0] == nil ? nil : $0 }
            childrenByParent[validParent, default: []].append(folder)
        }

        func buildNode(_ folder: MailboxFolder) -> MailboxFolderNode {
            let childNodes = (childrenByParent[folder.path] ?? [])
                .map(buildNode)
            return MailboxFolderNode(account: folder.account,
                                     path: folder.path,
                                     name: folder.name,
                                     parentPath: folder.parentPath,
                                     children: childNodes)
        }

        let roots = (childrenByParent[nil] ?? [])
            .map(buildNode)

        return roots
    }

    private static func inferredParentPath(from path: String, knownPaths: Set<String>) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for delimiter in ["/", ".", ":"] {
            guard let index = trimmed.lastIndex(of: Character(delimiter)) else { continue }
            let candidate = String(trimmed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if knownPaths.contains(candidate) {
                return candidate
            }
        }

        return nil
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
