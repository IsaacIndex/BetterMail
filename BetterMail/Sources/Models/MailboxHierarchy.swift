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

    internal static func applyFolderOrder(_ orderedFolderIDs: [String], to accounts: [MailboxAccount]) -> [MailboxAccount] {
        let rankByID = Dictionary(uniqueKeysWithValues: orderedFolderIDs.enumerated().map { ($1, $0) })
        guard !rankByID.isEmpty else { return accounts }

        return accounts.map { account in
            MailboxAccount(name: account.name,
                          folders: orderedNodes(account.folders, rankByID: rankByID))
        }
    }

    internal static func folderIDs(in accounts: [MailboxAccount]) -> [String] {
        accounts.flatMap { flattenIDs($0.folders) }
    }

    private static func buildTree(from folders: [MailboxFolder]) -> [MailboxFolderNode] {
        let foldersByPath = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0) })
        let knownPaths = Set(foldersByPath.keys)
        var childrenByParent: [String?: [MailboxFolder]] = [:]
        var resolvedParentByPath: [String: String?] = [:]

        for folder in folders {
            let inferredParent = inferredParentPath(from: folder.path, knownPaths: knownPaths)
            let candidateParent = folder.parentPath ?? inferredParent
            let validParent = candidateParent.flatMap { foldersByPath[$0] == nil ? nil : $0 }
            resolvedParentByPath[folder.path] = validParent
            childrenByParent[validParent, default: []].append(folder)
        }

        func buildNode(_ folder: MailboxFolder) -> MailboxFolderNode {
            let childNodes = inboxFirst((childrenByParent[folder.path] ?? []))
                .map(buildNode)
            return MailboxFolderNode(account: folder.account,
                                     path: folder.path,
                                     name: folder.name,
                                     parentPath: resolvedParentByPath[folder.path] ?? folder.parentPath,
                                     children: childNodes)
        }

        let roots = inboxFirst((childrenByParent[nil] ?? []))
            .map(buildNode)

        return roots
    }

    private static func deduplicatedFoldersForAccount(_ folders: [MailboxFolder]) -> [MailboxFolder] {
        // Keep only exact-path deduplication. Name-based root pruning was hiding
        // valid mailboxes for some providers/accounts (for example Outlook).
        deduplicatedByPathPreservingOrder(folders)
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

    private static func flattenIDs(_ nodes: [MailboxFolderNode]) -> [String] {
        var results: [String] = []
        results.reserveCapacity(nodes.count)
        for node in nodes {
            results.append(node.id)
            results.append(contentsOf: flattenIDs(node.children))
        }
        return results
    }

    private static func orderedNodes(_ nodes: [MailboxFolderNode], rankByID: [String: Int]) -> [MailboxFolderNode] {
        let sorted = nodes.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rankByID[lhs.element.id] ?? Int.max
                let rhsRank = rankByID[rhs.element.id] ?? Int.max
                if lhsRank == rhsRank {
                    return lhs.offset < rhs.offset
                }
                return lhsRank < rhsRank
            }
            .map(\.element)

        return sorted.map { node in
            var updated = node
            updated.children = orderedNodes(node.children, rankByID: rankByID)
            return updated
        }
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
