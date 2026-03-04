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
            let deduplicatedFolders = deduplicatedFoldersForAccount(foldersByAccount[account] ?? [])
            return MailboxAccount(name: account,
                                  folders: buildTree(from: deduplicatedFolders))
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

    internal static func filterFolderTree(_ nodes: [MailboxFolderNode], query: String) -> [MailboxFolderNode] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nodes }
        return nodes.compactMap { filterNode($0, query: trimmedQuery) }
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
            let childNodes = inboxFirst((childrenByParent[folder.path] ?? []))
                .map(buildNode)
            return MailboxFolderNode(account: folder.account,
                                     path: folder.path,
                                     name: folder.name,
                                     parentPath: folder.parentPath,
                                     children: childNodes)
        }

        let roots = inboxFirst((childrenByParent[nil] ?? []))
            .map(buildNode)

        return roots
    }

    private static func deduplicatedFoldersForAccount(_ folders: [MailboxFolder]) -> [MailboxFolder] {
        let uniqueFolders = deduplicatedByPathPreservingOrder(folders)
        guard uniqueFolders.count > 1 else { return uniqueFolders }

        let knownPaths = Set(uniqueFolders.map(\.path))
        var rootPaths: Set<String> = []
        var rootNameKeys: Set<String> = []
        var childrenByParent: [String: [MailboxFolder]] = [:]

        for folder in uniqueFolders {
            if let resolvedParent = resolvedParentPath(for: folder, knownPaths: knownPaths) {
                childrenByParent[resolvedParent, default: []].append(folder)
            } else {
                rootPaths.insert(folder.path)
                rootNameKeys.insert(normalizedFolderNameKey(folder.name))
            }
        }

        guard !rootPaths.isEmpty, !childrenByParent.isEmpty else { return uniqueFolders }

        var rootNameKeysToDrop: Set<String> = []
        for children in childrenByParent.values {
            let childNameKeys = Set(children.map { normalizedFolderNameKey($0.name) })
            let matchedNames = childNameKeys.intersection(rootNameKeys)
            guard !matchedNames.isEmpty else { continue }
            rootNameKeysToDrop.formUnion(matchedNames)
        }

        guard !rootNameKeysToDrop.isEmpty else { return uniqueFolders }

        return uniqueFolders.filter { folder in
            guard rootPaths.contains(folder.path) else { return true }
            let key = normalizedFolderNameKey(folder.name)
            return !rootNameKeysToDrop.contains(key)
        }
    }

    private static func resolvedParentPath(for folder: MailboxFolder, knownPaths: Set<String>) -> String? {
        if let explicitParent = folder.parentPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitParent.isEmpty,
           knownPaths.contains(explicitParent) {
            return explicitParent
        }
        return inferredParentPath(from: folder.path, knownPaths: knownPaths)
    }

    private static func normalizedFolderNameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func deduplicatedByPathPreservingOrder(_ folders: [MailboxFolder]) -> [MailboxFolder] {
        var seenPaths: Set<String> = []
        var deduplicated: [MailboxFolder] = []
        deduplicated.reserveCapacity(folders.count)

        for folder in folders {
            let inserted = seenPaths.insert(folder.path).inserted
            guard inserted else { continue }
            deduplicated.append(folder)
        }

        return deduplicated
    }

    private static func inboxFirst(_ folders: [MailboxFolder]) -> [MailboxFolder] {
        var inboxFolders: [MailboxFolder] = []
        var otherFolders: [MailboxFolder] = []
        inboxFolders.reserveCapacity(folders.count)
        otherFolders.reserveCapacity(folders.count)

        for folder in folders {
            if isInboxFolder(folder) {
                inboxFolders.append(folder)
            } else {
                otherFolders.append(folder)
            }
        }

        return inboxFolders + otherFolders
    }

    private static func isInboxFolder(_ folder: MailboxFolder) -> Bool {
        normalizedFolderNameKey(folder.name) == "inbox"
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

    private static func filterNode(_ node: MailboxFolderNode, query: String) -> MailboxFolderNode? {
        let normalizedQuery = query.lowercased()
        let parentMatches = node.path.lowercased().contains(normalizedQuery) || node.name.lowercased().contains(normalizedQuery)
        if parentMatches {
            return node
        }
        let filteredChildren = node.children.compactMap { filterNode($0, query: query) }
        guard !filteredChildren.isEmpty else { return nil }
        return MailboxFolderNode(account: node.account,
                                 path: node.path,
                                 name: node.name,
                                 parentPath: node.parentPath,
                                 children: filteredChildren)
    }
}
