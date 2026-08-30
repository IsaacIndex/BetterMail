import Foundation

/// A pure, scope-local projection for the Organize workspace.
///
/// `ThreadCanvasViewModel` remains the application authority for mailbox
/// refreshes and mutations. This value only derives display-ready rows from a
/// snapshot, which keeps it safe to memoize by `cacheKey` and straightforward
/// to exercise without SwiftUI or Core Data.
internal nonisolated struct OrganizerProjection: Equatable, Sendable {
    internal enum GroupKind: String, Codable, Hashable, Sendable {
        case confirmed
        case suggested
    }

    internal struct Conversation: Identifiable, Hashable, Sendable {
        /// The effective conversation identity used by BetterMail selection
        /// and Thread Folder membership, rather than an individual message ID.
        internal let id: String
        internal let representativeNodeID: String
        /// Every mailbox node ID represented by this effective conversation.
        /// Keeping these aliases in the projection makes selection consume the
        /// exact same immutable snapshot as the rail and Groups.
        internal let nodeIDs: [String]
        internal let graphNodeIDs: [String]
        internal let rawConversationIDs: [String]
        internal let title: String
        internal let sender: String
        internal let snippet: String
        internal let accountName: String
        internal let mailboxID: String
        internal let lastUpdated: Date
        internal let messageCount: Int
        internal let unreadCount: Int

        internal var displayTitle: String { title }
    }

    internal struct Group: Identifiable, Hashable, Sendable {
        internal let id: String
        internal let title: String
        internal let kind: GroupKind
        /// Effective conversation IDs in deterministic visible order.
        internal let conversationIDs: [String]
        internal let sourceFolderID: String?
        internal let sourceTag: String?
        internal let normalizedTopic: String?
        internal let supportingReason: String?

        internal var memberCount: Int { conversationIDs.count }
        internal var isDropTarget: Bool { kind == .confirmed }
    }

    /// A stable, in-memory key suitable for a caller-owned projection cache.
    /// It intentionally contains only normalized identifiers and snapshot
    /// values; it is not persisted and does not grant mutation authority.
    internal struct CacheKey: Hashable, Sendable {
        internal let scopeID: String
        internal let normalizedQuery: String
        internal let conversationSignatures: [ConversationSignature]
        internal let confirmedGroupSignatures: [String]
        internal let suggestedGroupSignatures: [String]
        internal let archivedConversationIDs: [String]
    }

    internal struct ConversationSignature: Hashable, Sendable {
        internal let id: String
        internal let representativeNodeID: String
        internal let nodeIDs: [String]
        internal let graphNodeIDs: [String]
        internal let rawConversationIDs: [String]
        internal let title: String
        internal let sender: String
        internal let snippet: String
        internal let accountName: String
        internal let mailboxID: String
        internal let lastUpdated: Date
        internal let messageCount: Int
        internal let unreadCount: Int
    }

    internal let scopeID: String
    internal let normalizedQuery: String
    /// Every conversation currently visible through the rail or a rendered
    /// confirmed/suggested Group, in deterministic focus order.
    internal let visibleConversations: [Conversation]
    internal let unorganized: [Conversation]
    internal let confirmedGroups: [Group]
    internal let suggestedGroups: [Group]
    internal let cacheKey: CacheKey

    internal var groups: [Group] {
        confirmedGroups + suggestedGroups
    }

    /// Selection aliases derived from this projection's immutable source
    /// snapshot. No observable view-model state is reread while a publisher is
    /// still delivering its new value.
    internal var selectionNormalizer: OrganizerSelectionController.Normalizer {
        let validIDs = Set(visibleConversations.map(\.id))
        var aliases: [String: String] = [:]
        var graphNodeToConversationID: [String: String] = [:]

        for conversation in visibleConversations {
            Self.addSelectionAlias(conversation.id,
                                   for: conversation.id,
                                   to: &aliases)
            for nodeID in conversation.nodeIDs {
                let graphMessageNodeID = GraphData.messageNodeID(for: nodeID)
                Self.addSelectionAlias(nodeID, for: conversation.id, to: &aliases)
                Self.addSelectionAlias(graphMessageNodeID,
                                       for: conversation.id,
                                       to: &aliases)
                Self.addSelectionAlias(nodeID,
                                       for: conversation.id,
                                       to: &graphNodeToConversationID)
                Self.addSelectionAlias(graphMessageNodeID,
                                       for: conversation.id,
                                       to: &graphNodeToConversationID)
            }
            for rawID in conversation.rawConversationIDs {
                Self.addSelectionAlias(rawID, for: conversation.id, to: &aliases)
                Self.addSelectionAlias("thread:\(rawID)",
                                       for: conversation.id,
                                       to: &aliases)
                Self.addSelectionAlias("thread:\(rawID)",
                                       for: conversation.id,
                                       to: &graphNodeToConversationID)
            }
            for graphNodeID in conversation.graphNodeIDs {
                Self.addSelectionAlias(graphNodeID,
                                       for: conversation.id,
                                       to: &aliases)
                Self.addSelectionAlias(graphNodeID,
                                       for: conversation.id,
                                       to: &graphNodeToConversationID)
            }
        }

        return OrganizerSelectionController.Normalizer(
            validConversationIDs: validIDs,
            aliases: aliases,
            graphNodeToConversationID: graphNodeToConversationID
        )
    }

    /// Builds a projection from the same roots/search snapshot that feeds the
    /// canvas. `archivedThreadIDs` accepts raw IDs, effective IDs, and the
    /// existing Graph `thread:<raw-id>` form. Folder and suggestion members
    /// are normalized to effective conversation IDs before they are exposed.
    internal static func make(
        scopeID: String = "default",
        roots: [ThreadNode],
        folders: [ThreadFolder] = [],
        folderMembershipByThreadID: [String: String] = [:],
        archivedThreadIDs: Set<String> = [],
        suggestedGroupings: [GraphGrouping] = [],
        manualGroupByMessageKey: [String: String] = [:],
        jwzThreadMap: [String: String] = [:],
        query: String = ""
    ) -> OrganizerProjection {
        let normalizedScopeID = normalizedScope(scopeID)
        let normalizedQuery = normalizeSearchQuery(query)
        let candidates = buildCandidates(roots: roots,
                                         manualGroupByMessageKey: manualGroupByMessageKey,
                                         jwzThreadMap: jwzThreadMap)
        let aliasTargets = aliasTargets(for: candidates)
        let effectiveIDs = Set(candidates.map(\.id))

        let archivedConversationIDs = Set(archivedThreadIDs.compactMap {
            resolveConversationID($0,
                                  effectiveIDs: effectiveIDs,
                                  aliasTargets: aliasTargets)
        })
        let allScopedCandidates = candidates.filter {
            !archivedConversationIDs.contains($0.id)
        }
        let matchingConversationIDs = Set(allScopedCandidates.compactMap { candidate in
            matches(candidate: candidate, query: normalizedQuery) ? candidate.id : nil
        })

        var confirmedMembershipIDs = Set<String>()
        var confirmedGroupMembersByID: [String: Set<String>] = [:]
        var confirmedFolderByID: [String: ThreadFolder] = [:]
        for folder in folders.sorted(by: { stableString($0.id) < stableString($1.id) }) {
            confirmedFolderByID[folder.id] = folder
            let memberIDs = Set(folder.threadIDs.compactMap {
                resolveConversationID($0,
                                      effectiveIDs: effectiveIDs,
                                      aliasTargets: aliasTargets)
            })
            confirmedMembershipIDs.formUnion(memberIDs)
            confirmedGroupMembersByID[folder.id, default: []].formUnion(memberIDs)
        }
        for (rawThreadID, folderID) in folderMembershipByThreadID {
            guard let conversationID = resolveConversationID(rawThreadID,
                                                              effectiveIDs: effectiveIDs,
                                                              aliasTargets: aliasTargets) else {
                continue
            }
            confirmedMembershipIDs.insert(conversationID)
            confirmedGroupMembersByID[folderID, default: []].insert(conversationID)
        }

        let allScopedIDs = Set(allScopedCandidates.map(\.id))
        let unorganizedIDs = matchingConversationIDs.subtracting(confirmedMembershipIDs)
        let conversationByID = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.id, makeConversation(from: $0))
        })
        let unorganized = sortConversationIDs(unorganizedIDs,
                                              conversationByID: conversationByID).compactMap {
            conversationByID[$0]
        }

        let confirmedGroups = confirmedFolderByID.values.compactMap { folder -> Group? in
            let groupMembers = confirmedGroupMembersByID[folder.id, default: []]
                .intersection(groupVisibleIDs(groupTitle: folder.title,
                                              memberIDs: allScopedIDs,
                                              matchingIDs: matchingConversationIDs,
                                              query: normalizedQuery))
            guard !groupMembers.isEmpty else { return nil }
            return Group(id: folder.id,
                         title: cleanTitle(folder.title, fallback: folder.id),
                         kind: .confirmed,
                         conversationIDs: sortConversationIDs(groupMembers,
                                                               conversationByID: conversationByID),
                         sourceFolderID: folder.id,
                         sourceTag: nil,
                         normalizedTopic: nil,
                         supportingReason: nil)
        }
        .sorted(by: groupSort)

        let suggestedGroups = suggestedGroupings
            .filter { $0.kind == .suggestedTopic }
            .compactMap { grouping -> Group? in
                let rawMemberIDs = grouping.rawThreadIDs + grouping.threadIDs
                let memberIDs = Set(rawMemberIDs.compactMap {
                    resolveConversationID($0,
                                          effectiveIDs: effectiveIDs,
                                          aliasTargets: aliasTargets)
                })
                let visibleMembers = memberIDs.intersection(groupVisibleIDs(
                    groupTitle: grouping.title,
                    memberIDs: allScopedIDs,
                    matchingIDs: matchingConversationIDs,
                    query: normalizedQuery
                ))
                guard !visibleMembers.isEmpty else { return nil }
                return Group(id: grouping.id,
                             title: cleanTitle(grouping.title, fallback: grouping.id),
                             kind: .suggested,
                             conversationIDs: sortConversationIDs(visibleMembers,
                                                                   conversationByID: conversationByID),
                             sourceFolderID: grouping.sourceFolderID,
                             sourceTag: grouping.sourceTag,
                             normalizedTopic: grouping.normalizedTopic,
                             supportingReason: grouping.supportingReason)
            }
            .reduce(into: [String: Group]()) { result, group in
                // A repeated suggestion ID is one logical suggestion. The
                // complete lexical signature is the deterministic tie-breaker,
                // including the case where member sets are identical.
                guard let existing = result[group.id] else {
                    result[group.id] = group
                    return
                }
                if groupPrecedes(group, existing) {
                    result[group.id] = group
                }
            }
            .values
            .sorted(by: groupSort)

        let visibleConversationIDs = unorganizedIDs
            .union(confirmedGroups.flatMap(\.conversationIDs))
            .union(suggestedGroups.flatMap(\.conversationIDs))
        let visibleConversations = sortConversationIDs(
            visibleConversationIDs,
            conversationByID: conversationByID
        ).compactMap { conversationByID[$0] }

        let signatures = candidates
            .map { candidate in
                ConversationSignature(id: candidate.id,
                                      representativeNodeID: candidate.representativeNodeID,
                                      nodeIDs: candidate.nodes.map(\.id).sorted(),
                                      graphNodeIDs: candidate.graphNodeIDs.sorted(),
                                      rawConversationIDs: candidate.rawConversationIDs.sorted(),
                                      title: candidate.title,
                                      sender: candidate.sender,
                                      snippet: candidate.snippet,
                                      accountName: candidate.accountName,
                                      mailboxID: candidate.mailboxID,
                                      lastUpdated: candidate.lastUpdated,
                                      messageCount: candidate.messageCount,
                                      unreadCount: candidate.unreadCount)
            }
            .sorted { lhs, rhs in
                stableString(lhs.id) < stableString(rhs.id)
            }
        let cacheKey = CacheKey(scopeID: normalizedScopeID,
                                normalizedQuery: normalizedQuery,
                                conversationSignatures: signatures,
                                confirmedGroupSignatures: groupSignatures(confirmedGroups),
                                suggestedGroupSignatures: groupSignatures(suggestedGroups),
                                archivedConversationIDs: archivedConversationIDs.sorted())

        return OrganizerProjection(scopeID: normalizedScopeID,
                                   normalizedQuery: normalizedQuery,
                                   visibleConversations: visibleConversations,
                                   unorganized: unorganized,
                                   confirmedGroups: confirmedGroups,
                                   suggestedGroups: suggestedGroups,
                                   cacheKey: cacheKey)
    }

    /// Mirrors the effective-thread precedence in `ThreadCanvasViewModel`
    /// without taking a dependency on that actor-isolated application object.
    internal static func effectiveConversationID(
        for node: ThreadNode,
        manualGroupByMessageKey: [String: String] = [:],
        jwzThreadMap: [String: String] = [:]
    ) -> String {
        let messageKey = node.message.threadKey
        if let manualGroupID = normalizedID(manualGroupByMessageKey[messageKey]) {
            return manualGroupID
        }
        if let jwzID = normalizedID(jwzThreadMap[messageKey]) {
            return jwzID
        }
        if let threadID = normalizedID(node.message.threadID) {
            return threadID
        }
        return normalizedID(node.id) ?? node.id
    }

    internal static func normalizedID(_ rawID: String?) -> String? {
        guard let rawID else { return nil }
        let value = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private struct Candidate {
        let id: String
        var nodes: [ThreadNode]
        var seenNodeIDs: Set<String>
        var representativeNodes: [ThreadNode]
        var rawConversationIDs: Set<String>
        var graphNodeIDs: Set<String>

        var representativeNodeID: String {
            representativeNodes
                .sorted(by: OrganizerProjection.nodeSort)
                .first?.id ?? nodes.sorted(by: OrganizerProjection.nodeSort).first?.id ?? id
        }

        var title: String {
            let node = representativeNodes.sorted(by: OrganizerProjection.nodeSort).first
                ?? nodes.sorted(by: OrganizerProjection.nodeSort).first
            return OrganizerProjection.cleanTitle(node?.message.subject ?? "",
                                                  fallback: node?.message.from ?? id)
        }

        var sender: String {
            let node = representativeNodes.sorted(by: OrganizerProjection.nodeSort).first
                ?? nodes.sorted(by: OrganizerProjection.nodeSort).first
            return OrganizerProjection.normalizedText(node?.message.from ?? "")
        }

        var snippet: String {
            let node = nodes.sorted(by: OrganizerProjection.nodeSort).first
            return OrganizerProjection.normalizedText(node?.message.snippet ?? "")
        }

        var accountName: String {
            let node = representativeNodes.sorted(by: OrganizerProjection.nodeSort).first
                ?? nodes.sorted(by: OrganizerProjection.nodeSort).first
            return OrganizerProjection.normalizedText(node?.message.accountName ?? "")
        }

        var mailboxID: String {
            let node = representativeNodes.sorted(by: OrganizerProjection.nodeSort).first
                ?? nodes.sorted(by: OrganizerProjection.nodeSort).first
            return OrganizerProjection.normalizedText(node?.message.mailboxID ?? "")
        }

        var lastUpdated: Date {
            nodes.map(\.message.date).max() ?? .distantPast
        }

        var messageCount: Int { nodes.count }

        var unreadCount: Int {
            nodes.reduce(into: 0) { result, node in
                if node.message.isUnread { result += 1 }
            }
        }

        var searchableValues: [String] {
            var values = [id, title, sender, snippet, accountName, mailboxID]
            values.append(contentsOf: nodes.flatMap { node in
                [node.message.messageID,
                 node.message.threadID ?? "",
                 node.message.subject,
                 node.message.from,
                 node.message.snippet]
            })
            return values
        }
    }

    private static func buildCandidates(
        roots: [ThreadNode],
        manualGroupByMessageKey: [String: String],
        jwzThreadMap: [String: String]
    ) -> [Candidate] {
        var candidatesByID: [String: Candidate] = [:]
        for root in roots {
            let effectiveID = effectiveConversationID(for: root,
                                                       manualGroupByMessageKey: manualGroupByMessageKey,
                                                       jwzThreadMap: jwzThreadMap)
            var candidate = candidatesByID[effectiveID] ?? Candidate(
                id: effectiveID,
                nodes: [],
                seenNodeIDs: [],
                representativeNodes: [],
                rawConversationIDs: [],
                graphNodeIDs: []
            )
            let rawID = normalizedID(root.message.threadID) ?? root.id
            candidate.rawConversationIDs.insert(rawID)
            candidate.rawConversationIDs.insert(effectiveID)
            candidate.graphNodeIDs.insert(graphThreadNodeID(for: rawID))
            candidate.representativeNodes.append(root)
            for node in flatten(root) where candidate.seenNodeIDs.insert(node.id).inserted {
                candidate.nodes.append(node)
            }
            candidatesByID[effectiveID] = candidate
        }
        return candidatesByID.values.sorted { lhs, rhs in
            stableString(lhs.id) < stableString(rhs.id)
        }
    }

    private static func makeConversation(from candidate: Candidate) -> Conversation {
        Conversation(id: candidate.id,
                      representativeNodeID: candidate.representativeNodeID,
                      nodeIDs: candidate.nodes.map(\.id).sorted(),
                      graphNodeIDs: candidate.graphNodeIDs.sorted(),
                      rawConversationIDs: candidate.rawConversationIDs.sorted(),
                      title: candidate.title,
                      sender: candidate.sender,
                      snippet: candidate.snippet,
                      accountName: candidate.accountName,
                      mailboxID: candidate.mailboxID,
                      lastUpdated: candidate.lastUpdated,
                      messageCount: candidate.messageCount,
                      unreadCount: candidate.unreadCount)
    }

    private static func addSelectionAlias(_ rawID: String,
                                          for conversationID: String,
                                          to map: inout [String: String]) {
        guard let normalized = normalizedID(rawID) else { return }
        if let existing = map[normalized] {
            guard existing == conversationID || existing.isEmpty else {
                // An ambiguous alias must resolve to neither conversation.
                // Normalizer drops this empty marker when it normalizes maps.
                map[normalized] = ""
                return
            }
            return
        }
        map[normalized] = conversationID
    }

    private static func aliasTargets(for candidates: [Candidate]) -> [String: Set<String>] {
        var targets: [String: Set<String>] = [:]
        for candidate in candidates {
            addAlias(candidate.id, for: candidate.id, to: &targets)
            addAlias("thread:\(candidate.id)", for: candidate.id, to: &targets)
            for rawID in candidate.rawConversationIDs {
                addAlias(rawID, for: candidate.id, to: &targets)
                addAlias(graphThreadNodeID(for: rawID), for: candidate.id, to: &targets)
            }
            for graphNodeID in candidate.graphNodeIDs {
                addAlias(graphNodeID, for: candidate.id, to: &targets)
            }
        }
        return targets
    }

    private static func addAlias(_ rawAlias: String,
                                 for effectiveID: String,
                                 to targets: inout [String: Set<String>]) {
        guard let alias = normalizedID(rawAlias) else { return }
        targets[alias, default: []].insert(effectiveID)
        if alias.hasPrefix("thread:") {
            let stripped = String(alias.dropFirst("thread:".count))
            if let stripped = normalizedID(stripped) {
                targets[stripped, default: []].insert(effectiveID)
            }
        }
    }

    private static func resolveConversationID(
        _ rawID: String?,
        effectiveIDs: Set<String>,
        aliasTargets: [String: Set<String>]
    ) -> String? {
        guard let normalized = normalizedID(rawID) else { return nil }
        if effectiveIDs.contains(normalized) {
            return normalized
        }
        if let targets = aliasTargets[normalized], targets.count == 1 {
            return targets.first
        }
        if normalized.hasPrefix("thread:"),
           let stripped = normalizedID(String(normalized.dropFirst("thread:".count))),
           effectiveIDs.contains(stripped) {
            return stripped
        }
        return nil
    }

    private static func groupVisibleIDs(
        groupTitle: String,
        memberIDs: Set<String>,
        matchingIDs: Set<String>,
        query: String
    ) -> Set<String> {
        guard !query.isEmpty else { return memberIDs }
        return matchesText(groupTitle, query: query) ? memberIDs : memberIDs.intersection(matchingIDs)
    }

    private static func matches(candidate: Candidate, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return candidate.searchableValues.contains { matchesText($0, query: query) }
    }

    private static func matchesText(_ value: String, query: String) -> Bool {
        stableString(value).contains(stableString(query))
    }

    private static func sortConversationIDs(
        _ ids: Set<String>,
        conversationByID: [String: Conversation]
    ) -> [String] {
        ids.sorted { lhs, rhs in
            guard let left = conversationByID[lhs], let right = conversationByID[rhs] else {
                return stableString(lhs) < stableString(rhs)
            }
            return conversationSort(left, right)
        }
    }

    private static func conversationSort(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        if lhs.lastUpdated != rhs.lastUpdated {
            return lhs.lastUpdated > rhs.lastUpdated
        }
        let leftTitle = stableString(lhs.title)
        let rightTitle = stableString(rhs.title)
        if leftTitle != rightTitle {
            return leftTitle < rightTitle
        }
        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }
        return lhs.representativeNodeID < rhs.representativeNodeID
    }

    private static func groupSort(_ lhs: Group, _ rhs: Group) -> Bool {
        let leftTitle = stableString(lhs.title)
        let rightTitle = stableString(rhs.title)
        if leftTitle != rightTitle {
            return leftTitle < rightTitle
        }
        if lhs.kind != rhs.kind {
            return lhs.kind == .confirmed
        }
        return lhs.id < rhs.id
    }

    private static func groupSignatures(_ groups: [Group]) -> [String] {
        groups.map(groupSignature)
    }

    private static func groupSignature(_ group: Group) -> String {
        groupTieBreakValues(group).map { value in
            "\(value.utf8.count)#\(value)"
        }.joined()
    }

    private static func groupPrecedes(_ lhs: Group, _ rhs: Group) -> Bool {
        let left = groupTieBreakValues(lhs)
        let right = groupTieBreakValues(rhs)
        for (leftValue, rightValue) in zip(left, right) {
            guard leftValue != rightValue else { continue }
            let leftStable = stableString(leftValue)
            let rightStable = stableString(rightValue)
            if leftStable != rightStable {
                return leftStable < rightStable
            }
            return leftValue < rightValue
        }
        return left.count < right.count
    }

    private static func groupTieBreakValues(_ group: Group) -> [String] {
        var values = [group.kind.rawValue, group.id, group.title]
        for optionalValue in [group.sourceFolderID,
                              group.sourceTag,
                              group.normalizedTopic,
                              group.supportingReason] {
            values.append(optionalValue.map { "1\($0)" } ?? "0")
        }
        values.append(contentsOf: group.conversationIDs)
        return values
    }

    private static func nodeSort(_ lhs: ThreadNode, _ rhs: ThreadNode) -> Bool {
        if lhs.message.date != rhs.message.date {
            return lhs.message.date > rhs.message.date
        }
        return lhs.id < rhs.id
    }

    private static func flatten(_ node: ThreadNode) -> [ThreadNode] {
        var result = [node]
        for child in node.children {
            result.append(contentsOf: flatten(child))
        }
        return result
    }

    private static func graphThreadNodeID(for rawID: String) -> String {
        "thread:\(rawID)"
    }

    private static func cleanTitle(_ rawTitle: String, fallback: String) -> String {
        let title = normalizedText(rawTitle)
        return title.isEmpty ? (normalizedID(fallback) ?? "Untitled") : title
    }

    private static func normalizedText(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedScope(_ value: String) -> String {
        normalizedID(value) ?? "default"
    }

    private static func normalizeSearchQuery(_ value: String) -> String {
        normalizedText(value).lowercased()
    }

    private static func stableString(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
