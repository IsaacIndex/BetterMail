import Foundation

internal nonisolated struct ThreadingResult: Sendable {
    internal let roots: [ThreadNode]
    internal let threads: [EmailThread]
    internal let messageThreadMap: [String: String]
    internal let jwzThreadMap: [String: String]
    internal let manualGroupByMessageKey: [String: String]
    internal let manualAttachmentMessageIDs: Set<String>
}

internal nonisolated final class JWZThreader: @unchecked Sendable {
    private struct ScopedMessageID: Hashable {
        let account: String
        let messageID: String
    }

    private final class Container: Hashable {
        let identifier: String
        weak var parent: Container?
        var children: [Container] = []
        var message: EmailMessage?

        init(identifier: String) {
            self.identifier = identifier
        }

        func adopt(_ child: Container) {
            // Real-world clients occasionally append an In-Reply-To value that
            // already appears earlier in References. Without this ancestry
            // check, a chain such as A -> B -> A creates a parent cycle, so the
            // component has no structural root and every email in it vanishes
            // from threading, Graph, and retrospective regeneration.
            guard child !== self, !isDescendant(of: child) else { return }
            guard !children.contains(where: { $0 === child }) else { return }
            child.parent?.remove(child: child)
            child.parent = self
            children.append(child)
        }

        private func isDescendant(of candidateAncestor: Container) -> Bool {
            var cursor: Container? = self
            while let container = cursor {
                if container === candidateAncestor { return true }
                cursor = container.parent
            }
            return false
        }

        func remove(child: Container) {
            children.removeAll { $0 === child }
        }

        static func == (lhs: Container, rhs: Container) -> Bool {
            lhs === rhs
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }
    }

    internal func buildThreads(from messages: [EmailMessage]) -> ThreadingResult {
        var containers: [String: Container] = [:]
        let physicalMessageIDs = Set(messages.compactMap { message -> ScopedMessageID? in
            let normalizedID = Self.normalizeIdentifier(message.messageID)
            guard !normalizedID.isEmpty else { return nil }
            return ScopedMessageID(account: Self.normalizeAccount(message.accountName),
                                   messageID: normalizedID)
        })

        func container(for identifier: String) -> Container {
            if let existing = containers[identifier] { return existing }
            let container = Container(identifier: identifier)
            containers[identifier] = container
            return container
        }

        // Suppressed attendance replies still participate in the container
        // graph so their descendants retain the real References ancestry.
        for message in messages {
            let normalizedID = Self.normalizeIdentifier(message.messageID)
            let identifier = normalizedID.isEmpty ? message.id.uuidString.lowercased() : normalizedID
            let messageContainer = container(for: identifier)
            messageContainer.message = message

            let parentChain = message.references + (message.inReplyTo.map { [$0] } ?? [])
            var previous: Container?
            for ref in parentChain {
                let normalized = Self.normalizeIdentifier(ref)
                guard !normalized.isEmpty else { continue }
                let refContainer = container(for: normalized)
                if let previous {
                    if refContainer === previous { continue }
                    previous.adopt(refContainer)
                }
                previous = refContainer
            }

            if let previous, previous !== messageContainer {
                previous.adopt(messageContainer)
            }
        }

        let structuralRoots = containers.values.filter { $0.parent == nil }
        var materializedComponents: [(container: Container, root: ThreadNode)] = []
        var hiddenOnlyComponents: [Container] = []
        for structuralRoot in structuralRoots {
            let visibleRoots = flatten(container: structuralRoot)
            guard let root = coalescedRoot(from: visibleRoots) else {
                hiddenOnlyComponents.append(structuralRoot)
                continue
            }
            materializedComponents.append((structuralRoot,
                                           addingEmbeddedHistory(to: root,
                                                                 excluding: physicalMessageIDs)))
        }
        materializedComponents.sort { lhs, rhs in
            if lhs.root.message.date == rhs.root.message.date {
                return lhs.root.message.subject.localizedCaseInsensitiveCompare(rhs.root.message.subject) == .orderedAscending
            }
            return lhs.root.message.date > rhs.root.message.date
        }

        var annotatedRoots: [ThreadNode] = []
        var messageMap: [String: String] = [:]
        var threads: [EmailThread] = []

        for component in materializedComponents {
            let root = component.root
            let threadID = Self.threadIdentifier(for: root)
            let summary = annotate(node: root, threadID: threadID, map: &messageMap)
            mapStructuralMembership(from: component.container,
                                    threadID: threadID,
                                    into: &messageMap)
            annotatedRoots.append(summary.node)
            let thread = EmailThread(id: threadID,
                                     rootMessageID: root.message.messageID,
                                     subject: root.message.subject,
                                     lastUpdated: summary.lastUpdated,
                                     unreadCount: summary.unreadCount,
                                     messageCount: summary.count)
            threads.append(thread)
        }

        // Hidden-only RSVP chains do not materialize a thread or Graph node,
        // but their source records still keep a stable structural membership.
        for component in hiddenOnlyComponents {
            let threadID = structuralThreadIdentifier(for: component)
            mapStructuralMembership(from: component,
                                    threadID: threadID,
                                    into: &messageMap)
        }

        return ThreadingResult(roots: annotatedRoots,
                               threads: threads,
                               messageThreadMap: messageMap,
                               jwzThreadMap: messageMap,
                               manualGroupByMessageKey: [:],
                               manualAttachmentMessageIDs: [])
    }

    private func flatten(container: Container) -> [ThreadNode] {
        let childNodes = container.children.flatMap { flatten(container: $0) }
        guard let message = container.message, !message.isCalendarRSVP else {
            return childNodes
        }
        let sortedChildren = childNodes.sorted { $0.message.date < $1.message.date }
        return [ThreadNode(message: message, children: sortedChildren)]
    }

    private func addingEmbeddedHistory(to node: ThreadNode,
                                       excluding physicalMessageIDs: Set<ScopedMessageID>) -> ThreadNode {
        var children = node.children.map {
            addingEmbeddedHistory(to: $0, excluding: physicalMessageIDs)
        }
        let history = node.message.embeddedMessages
            .filter { embedded in
                guard let originalMessageID = embedded.originalMessageID else { return true }
                let scopedID = ScopedMessageID(
                    account: Self.normalizeAccount(node.message.accountName),
                    messageID: Self.normalizeIdentifier(originalMessageID)
                )
                return !physicalMessageIDs.contains(scopedID)
            }
            .sorted { lhs, rhs in
                if lhs.sourceOrder == rhs.sourceOrder { return lhs.id < rhs.id }
                return lhs.sourceOrder < rhs.sourceOrder
            }

        var chain: ThreadNode?
        for embedded in history.reversed() {
            let projected = projectedMessage(from: embedded, parent: node.message)
            chain = ThreadNode(message: projected,
                               children: chain.map { [$0] } ?? [])
        }
        if let chain {
            children.append(chain)
        }
        return ThreadNode(message: node.message, children: children)
    }

    private func projectedMessage(from embedded: EmbeddedEmailMessage,
                                  parent: EmailMessage) -> EmailMessage {
        let fallbackDate = parent.date.addingTimeInterval(-Double(embedded.sourceOrder + 1))
        return EmailMessage(id: Self.deterministicUUID(for: embedded.id),
                            messageID: embedded.id,
                            internalMailID: nil,
                            mailboxID: parent.mailboxID,
                            accountName: parent.accountName,
                            subject: embedded.subject,
                            from: embedded.from,
                            to: embedded.to,
                            date: embedded.date ?? fallbackDate,
                            snippet: embedded.snippet,
                            isUnread: false,
                            calendarMessageKind: .ordinaryMessage,
                            inReplyTo: nil,
                            references: [],
                            embeddedSource: parent.physicalSource)
    }

    private static func deterministicUUID(for value: String) -> UUID {
        let first = stableHash(value)
        let second = stableHash("embedded|\(value)")
        let hex = String(format: "%016llx%016llx", first, second)
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID()
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    /// A missing or hidden root can expose several visible descendants. Keep
    /// them in one structural thread by using the oldest visible message as a
    /// temporary root until the real invitation is recovered.
    private func coalescedRoot(from roots: [ThreadNode]) -> ThreadNode? {
        guard !roots.isEmpty else { return nil }
        guard roots.count > 1 else { return roots[0] }
        let ordered = roots.sorted { lhs, rhs in
            if lhs.message.date == rhs.message.date {
                return lhs.message.messageID < rhs.message.messageID
            }
            return lhs.message.date < rhs.message.date
        }
        let root = ordered[0]
        let children = (root.children + Array(ordered.dropFirst())).sorted { lhs, rhs in
            if lhs.message.date == rhs.message.date {
                return lhs.message.messageID < rhs.message.messageID
            }
            return lhs.message.date < rhs.message.date
        }
        return ThreadNode(message: root.message, children: children)
    }

    private func mapStructuralMembership(from container: Container,
                                         threadID: String,
                                         into map: inout [String: String]) {
        if let message = container.message {
            let key = message.normalizedMessageID.isEmpty
                ? message.id.uuidString.lowercased()
                : message.normalizedMessageID
            map[key] = threadID
        }
        for child in container.children {
            mapStructuralMembership(from: child, threadID: threadID, into: &map)
        }
    }

    private func structuralThreadIdentifier(for container: Container) -> String {
        if let message = container.message {
            let normalized = Self.normalizeIdentifier(message.messageID)
            if !normalized.isEmpty { return normalized }
            return message.id.uuidString.lowercased()
        }
        return container.identifier
    }

    private func annotate(node: ThreadNode, threadID: String, map: inout [String: String]) -> (node: ThreadNode, lastUpdated: Date, unreadCount: Int, count: Int) {
        var latest = node.message.date
        var unread = node.message.isUnread ? 1 : 0
        var total = 1
        var annotatedChildren: [ThreadNode] = []

        for child in node.children {
            let summary = annotate(node: child, threadID: threadID, map: &map)
            latest = max(latest, summary.lastUpdated)
            unread += summary.unreadCount
            total += summary.count
            annotatedChildren.append(summary.node)
        }

        let updatedMessage = node.message.assigning(threadID: threadID)
        let mapKey = node.message.normalizedMessageID.isEmpty ? node.message.id.uuidString.lowercased() : node.message.normalizedMessageID
        map[mapKey] = threadID
        let updatedNode = ThreadNode(message: updatedMessage, children: annotatedChildren)
        return (updatedNode, latest, unread, total)
    }

    internal nonisolated static func normalizeIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var candidate = trimmed
        if candidate.hasPrefix("<") && candidate.hasSuffix(">") {
            candidate = String(candidate.dropFirst().dropLast())
        }
        return candidate.lowercased()
    }

    private nonisolated static func normalizeAccount(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    internal static func threadIdentifier(for node: ThreadNode) -> String {
        let normalized = normalizeIdentifier(node.message.messageID)
        return normalized.isEmpty ? node.message.id.uuidString.lowercased() : normalized
    }
}

extension JWZThreader {
    internal nonisolated struct ManualGroupApplication: Sendable {
        internal let result: ThreadingResult
        internal let updatedGroups: [ManualThreadGroup]
    }

    internal nonisolated func applyManualGroups(_ groups: [ManualThreadGroup],
                                                to result: ThreadingResult) -> ManualGroupApplication {
        guard !groups.isEmpty else {
            let updatedResult = ThreadingResult(roots: result.roots,
                                                threads: result.threads,
                                                messageThreadMap: result.messageThreadMap,
                                                jwzThreadMap: result.jwzThreadMap,
                                                manualGroupByMessageKey: [:],
                                                manualAttachmentMessageIDs: [])
            return ManualGroupApplication(result: updatedResult, updatedGroups: [])
        }

        let allNodes = result.roots.flatMap { Self.flattenNodes(from: $0) }
        let baseThreadMap = result.jwzThreadMap
        var messageKeyToMessageID: [String: String] = [:]
        let visibleThreadIDs = Set(baseThreadMap.values)
        let linkedThreadIDs = Self.linkedJWZThreadIDs(for: allNodes, baseThreadMap: baseThreadMap)

        for node in allNodes {
            let key = node.message.threadKey
            messageKeyToMessageID[key] = node.message.messageID
        }

        var manualGroupByMessageKey: [String: String] = [:]
        var manualAttachmentMessageIDs: Set<String> = []
        var updatedGroups: [ManualThreadGroup] = []
        updatedGroups.reserveCapacity(groups.count)

        for group in groups {
            let manualKeysInCurrentWindow = group.manualMessageKeys.filter { baseThreadMap[$0] != nil }
            let seedThreadIDs = group.jwzThreadIDs.intersection(visibleThreadIDs)
                .union(manualKeysInCurrentWindow.compactMap { baseThreadMap[$0] })
            let expandedThreadIDs = group.jwzThreadIDs.union(
                Self.expandLinkedThreadIDs(startingFrom: seedThreadIDs,
                                           linkedThreadIDs: linkedThreadIDs)
            )
            let updatedGroup = ManualThreadGroup(id: group.id,
                                                 jwzThreadIDs: expandedThreadIDs,
                                                 manualMessageKeys: group.manualMessageKeys)
            updatedGroups.append(updatedGroup)

            for (messageKey, jwzThreadID) in baseThreadMap where expandedThreadIDs.contains(jwzThreadID) {
                if manualGroupByMessageKey[messageKey] == nil {
                    manualGroupByMessageKey[messageKey] = group.id
                }
            }

            for messageKey in manualKeysInCurrentWindow {
                if manualGroupByMessageKey[messageKey] == nil {
                    manualGroupByMessageKey[messageKey] = group.id
                }
                if let messageID = messageKeyToMessageID[messageKey] {
                    manualAttachmentMessageIDs.insert(messageID)
                }
            }
        }

        var updatedMap = baseThreadMap
        for (messageKey, groupID) in manualGroupByMessageKey {
            updatedMap[messageKey] = groupID
        }

        let preferredRootIDsByThreadID = result.threads.reduce(into: [String: String]()) { result, thread in
            guard let rootID = thread.rootMessageID else { return }
            result[thread.id] = rootID
        }

        var messagesByThreadID: [String: [EmailMessage]] = [:]
        for node in allNodes {
            let key = node.message.threadKey
            let threadID = updatedMap[key] ?? node.message.threadID ?? key
            let updatedMessage = node.message.assigning(threadID: threadID)
            messagesByThreadID[threadID, default: []].append(updatedMessage)
        }

        var rebuiltRoots: [ThreadNode] = []
        var rebuiltThreads: [EmailThread] = []
        rebuiltRoots.reserveCapacity(messagesByThreadID.count)
        rebuiltThreads.reserveCapacity(messagesByThreadID.count)

        for (threadID, messages) in messagesByThreadID {
            guard let rootMessage = Self.selectRootMessage(from: messages,
                                                           preferredRootID: preferredRootIDsByThreadID[threadID]) else {
                continue
            }
            let children = messages
                .filter { $0.messageID != rootMessage.messageID }
                .sorted { $0.date < $1.date }
                .map { ThreadNode(message: $0) }
            let rootNode = ThreadNode(message: rootMessage, children: children)
            rebuiltRoots.append(rootNode)

            let lastUpdated = messages.map(\.date).max() ?? rootMessage.date
            let unreadCount = messages.reduce(0) { $0 + ($1.isUnread ? 1 : 0) }
            let thread = EmailThread(id: threadID,
                                     rootMessageID: rootMessage.messageID,
                                     subject: rootMessage.subject,
                                     lastUpdated: lastUpdated,
                                     unreadCount: unreadCount,
                                     messageCount: messages.count)
            rebuiltThreads.append(thread)
        }

        let updatedResult = ThreadingResult(roots: rebuiltRoots,
                                            threads: rebuiltThreads,
                                            messageThreadMap: updatedMap,
                                            jwzThreadMap: result.jwzThreadMap,
                                            manualGroupByMessageKey: manualGroupByMessageKey,
                                            manualAttachmentMessageIDs: manualAttachmentMessageIDs)
        return ManualGroupApplication(result: updatedResult, updatedGroups: updatedGroups)
    }

    private static func flattenNodes(from node: ThreadNode) -> [ThreadNode] {
        var results = [node]
        for child in node.children {
            results.append(contentsOf: flattenNodes(from: child))
        }
        return results
    }

    private static func selectRootMessage(from messages: [EmailMessage],
                                          preferredRootID: String?) -> EmailMessage? {
        if let preferredRootID, let preferred = messages.first(where: { $0.messageID == preferredRootID }) {
            return preferred
        }
        return messages.min { $0.date < $1.date }
    }

    private static func linkedJWZThreadIDs(for nodes: [ThreadNode],
                                           baseThreadMap: [String: String]) -> [String: Set<String>] {
        var links: [String: Set<String>] = [:]

        func addLink(_ lhs: String, _ rhs: String) {
            guard lhs != rhs else { return }
            links[lhs, default: []].insert(rhs)
            links[rhs, default: []].insert(lhs)
        }

        for node in nodes {
            let messageKey = node.message.threadKey
            guard let threadID = baseThreadMap[messageKey] else { continue }
            let referenceKeys = node.message.references.map(normalizeIdentifier)
            let replyKey = node.message.inReplyTo.map(normalizeIdentifier)
            for referenceKey in referenceKeys + (replyKey.map { [$0] } ?? []) {
                guard let referenceThreadID = baseThreadMap[referenceKey] else { continue }
                addLink(threadID, referenceThreadID)
            }
        }

        return links
    }

    private static func expandLinkedThreadIDs(startingFrom seedThreadIDs: Set<String>,
                                              linkedThreadIDs: [String: Set<String>]) -> Set<String> {
        guard !seedThreadIDs.isEmpty else { return [] }

        var visited: Set<String> = []
        var pending = Array(seedThreadIDs)

        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            for linkedThreadID in linkedThreadIDs[current] ?? [] where !visited.contains(linkedThreadID) {
                pending.append(linkedThreadID)
            }
        }

        return visited
    }
}
