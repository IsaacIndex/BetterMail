import Foundation

struct ThreadingResult {
    let roots: [ThreadNode]
    let threads: [EmailThread]
    let messageThreadMap: [String: String]
}

final class JWZThreader {
    private let subjectMergeWindow: TimeInterval = 7 * 24 * 60 * 60
    private let contentSimilarityThreshold: Double = 0.25
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "your", "from", "have",
        "will", "need", "please", "regarding", "about", "into", "over",
        "what", "were", "when", "where", "which"
    ]

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

        let mergedRoots = mergeSubjectOnlyThreads(threadRoots)

        let sortedRoots = mergedRoots.sorted { lhs, rhs in
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

        return ThreadingResult(roots: annotatedRoots, threads: threads, messageThreadMap: messageMap)
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

    private func mergeSubjectOnlyThreads(_ roots: [ThreadNode]) -> [ThreadNode] {
        guard roots.count > 1 else { return roots }
        var passthrough: [ThreadNode] = []
        var subjectBuckets: [String: [ThreadNode]] = [:]

        for node in roots {
            guard node.message.inReplyTo == nil,
                  node.message.references.isEmpty else {
                passthrough.append(node)
                continue
            }
            let canonical = Self.canonicalSubject(node.message.subject)
            guard !canonical.isEmpty else {
                passthrough.append(node)
                continue
            }
            subjectBuckets[canonical, default: []].append(node)
        }

        for (_, bucket) in subjectBuckets {
            guard bucket.count > 1 else {
                passthrough.append(contentsOf: bucket)
                continue
            }
            passthrough.append(contentsOf: mergeSubjectBucket(bucket))
        }

        return passthrough
    }

    private func mergeSubjectBucket(_ nodes: [ThreadNode]) -> [ThreadNode] {
        var visited: Set<Int> = []
        var results: [ThreadNode] = []
        var contentCache: [String: Set<String>] = [:]

        for index in nodes.indices {
            guard !visited.contains(index) else { continue }
            var stack: [Int] = [index]
            var component: [ThreadNode] = []
            visited.insert(index)

            while let current = stack.popLast() {
                component.append(nodes[current])
                for candidate in nodes.indices where !visited.contains(candidate) {
                    if shouldMergeSubjectNodes(lhs: nodes[current],
                                               rhs: nodes[candidate],
                                               cache: &contentCache) {
                        visited.insert(candidate)
                        stack.append(candidate)
                    }
                }
            }

            if component.count == 1 {
                results.append(component[0])
            } else {
                results.append(graftSubjectComponent(component))
            }
        }

        return results
    }

    private func shouldMergeSubjectNodes(lhs: ThreadNode,
                                         rhs: ThreadNode,
                                         cache: inout [String: Set<String>]) -> Bool {
        let timeGap = abs(lhs.message.date.timeIntervalSince(rhs.message.date))
        guard timeGap <= subjectMergeWindow else { return false }
        let lhsTokens = cachedContentTokens(for: lhs, cache: &cache)
        let rhsTokens = cachedContentTokens(for: rhs, cache: &cache)
        if lhsTokens.isEmpty && rhsTokens.isEmpty {
            return true
        }
        let similarity = contentSimilarity(lhsTokens: lhsTokens, rhsTokens: rhsTokens)
        return similarity >= contentSimilarityThreshold
    }

    private func contentSimilarity(lhsTokens: Set<String>,
                                   rhsTokens: Set<String>) -> Double {
        let union = lhsTokens.union(rhsTokens)
        guard !union.isEmpty else { return 0 }
        let intersection = lhsTokens.intersection(rhsTokens)
        return Double(intersection.count) / Double(union.count)
    }

    private func cachedContentTokens(for node: ThreadNode,
                                     cache: inout [String: Set<String>]) -> Set<String> {
        if let cached = cache[node.id] {
            return cached
        }
        let tokens = Self.contentTokens(for: node.message)
        cache[node.id] = tokens
        return tokens
    }

    private func graftSubjectComponent(_ nodes: [ThreadNode]) -> ThreadNode {
        guard !nodes.isEmpty else { return ThreadNode(message: EmailMessage.placeholder) }
        let sorted = nodes.sorted { $0.message.date < $1.message.date }
        var root = sorted[0]
        var children = root.children
        for node in sorted.dropFirst() {
            children.append(node)
        }
        children.sort { $0.message.date < $1.message.date }
        root.children = children
        return root
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

    private static func canonicalSubject(_ subject: String) -> String {
        var trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        while true {
            let lower = trimmed.lowercased()
            if lower.hasPrefix("re:") {
                trimmed = trimmed.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if lower.hasPrefix("fw:") {
                trimmed = trimmed.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if lower.hasPrefix("fwd:") {
                trimmed = trimmed.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            break
        }
        if trimmed.hasPrefix("[") && trimmed.contains("]") {
            if let closing = trimmed.firstIndex(of: "]") {
                trimmed = trimmed[trimmed.index(after: closing)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed.lowercased()
    }

    private static func contentTokens(for message: EmailMessage) -> Set<String> {
        let snippetTokens = tokenize(message.snippet)
        if snippetTokens.isEmpty {
            let fallback = tokenize(canonicalSubject(message.subject))
            return Set(fallback)
        }
        return Set(snippetTokens)
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                token.count >= 3 && stopWords.contains(token) == false
            }
    }

    static func threadIdentifier(for node: ThreadNode) -> String {
        let normalized = normalizeIdentifier(node.message.messageID)
        return normalized.isEmpty ? node.message.id.uuidString.lowercased() : normalized
    }
}
