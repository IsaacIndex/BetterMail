import Foundation

struct ThreadingResult {
    let roots: [ThreadNode]
    let threads: [EmailThread]
    let messageThreadMap: [String: String]
    let manualOverrideMessageIDs: Set<String>
}

final class JWZThreader {
    private final class Container: Hashable {
        let identifier: String
        weak var parent: Container?
        var children: [Container] = []
        var message: EmailMessage?

        init(identifier: String) {
            self.identifier = identifier
        }

        func adopt(_ child: Container) {
            guard !children.contains(where: { $0 === child }) else { return }
            child.parent?.remove(child: child)
            child.parent = self
            children.append(child)
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

    func buildThreads(from messages: [EmailMessage]) -> ThreadingResult {
        var containers: [String: Container] = [:]

        func container(for identifier: String) -> Container {
            if let existing = containers[identifier] { return existing }
            let container = Container(identifier: identifier)
            containers[identifier] = container
            return container
        }

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

        let roots = containers.values.filter { $0.parent == nil }
        var threadRoots: [ThreadNode] = []
        for root in roots {
            threadRoots.append(contentsOf: flatten(container: root))
        }

        let sortedRoots = threadRoots.sorted { lhs, rhs in
            if lhs.message.date == rhs.message.date {
                return lhs.message.subject.localizedCaseInsensitiveCompare(rhs.message.subject) == .orderedAscending
            }
            return lhs.message.date > rhs.message.date
        }

        var annotatedRoots: [ThreadNode] = []
        var messageMap: [String: String] = [:]
        var threads: [EmailThread] = []

        for root in sortedRoots {
            let threadID = Self.threadIdentifier(for: root)
            let summary = annotate(node: root, threadID: threadID, map: &messageMap)
            annotatedRoots.append(summary.node)
            let thread = EmailThread(id: threadID,
                                     rootMessageID: root.message.messageID,
                                     subject: root.message.subject,
                                     lastUpdated: summary.lastUpdated,
                                     unreadCount: summary.unreadCount,
                                     messageCount: summary.count)
            threads.append(thread)
        }

        return ThreadingResult(roots: annotatedRoots,
                               threads: threads,
                               messageThreadMap: messageMap,
                               manualOverrideMessageIDs: [])
    }

    private func flatten(container: Container) -> [ThreadNode] {
        let childNodes = container.children.flatMap { flatten(container: $0) }
        guard let message = container.message else {
            return childNodes
        }
        let sortedChildren = childNodes.sorted { $0.message.date < $1.message.date }
        return [ThreadNode(message: message, children: sortedChildren)]
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

    static func normalizeIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var candidate = trimmed
        if candidate.hasPrefix("<") && candidate.hasSuffix(">") {
            candidate = String(candidate.dropFirst().dropLast())
        }
        return candidate.lowercased()
    }

    static func threadIdentifier(for node: ThreadNode) -> String {
        let normalized = normalizeIdentifier(node.message.messageID)
        return normalized.isEmpty ? node.message.id.uuidString.lowercased() : normalized
    }
}

extension JWZThreader {
    struct ManualOverrideApplication {
        let result: ThreadingResult
        let invalidKeys: [String]
    }

    func applyManualOverrides(_ overrides: [String: String],
                              to result: ThreadingResult) -> ManualOverrideApplication {
        guard !overrides.isEmpty else {
            return ManualOverrideApplication(result: result, invalidKeys: [])
        }

        let allNodes = result.roots.flatMap { Self.flattenNodes(from: $0) }
        var messageKeyToMessageID: [String: String] = [:]

        for node in allNodes {
            let key = node.message.threadKey
            messageKeyToMessageID[key] = node.message.messageID
        }

        var updatedMap = result.messageThreadMap
        var appliedOverrideKeys: Set<String> = []
        var invalidKeys: [String] = []
        var parentByThreadID: [String: String] = [:]

        func findThreadID(_ id: String) -> String {
            if let parent = parentByThreadID[id] {
                if parent == id { return parent }
                let root = findThreadID(parent)
                parentByThreadID[id] = root
                return root
            }
            parentByThreadID[id] = id
            return id
        }

        func mergeThread(_ source: String, into target: String) {
            let sourceRoot = findThreadID(source)
            let targetRoot = findThreadID(target)
            guard sourceRoot != targetRoot else { return }
            parentByThreadID[sourceRoot] = targetRoot
        }

        for (messageKey, targetThreadID) in overrides {
            guard updatedMap[messageKey] != nil else {
                invalidKeys.append(messageKey)
                continue
            }
            guard let sourceThreadID = updatedMap[messageKey], sourceThreadID != targetThreadID else {
                invalidKeys.append(messageKey)
                continue
            }
            mergeThread(sourceThreadID, into: targetThreadID)
            appliedOverrideKeys.insert(messageKey)
        }

        guard !appliedOverrideKeys.isEmpty else {
            return ManualOverrideApplication(result: result, invalidKeys: invalidKeys)
        }

        for (key, threadID) in updatedMap {
            updatedMap[key] = findThreadID(threadID)
        }

        let manualOverrideMessageIDs = Set(appliedOverrideKeys.compactMap { messageKeyToMessageID[$0] })
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
                                            manualOverrideMessageIDs: manualOverrideMessageIDs)
        return ManualOverrideApplication(result: updatedResult, invalidKeys: invalidKeys)
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
}
