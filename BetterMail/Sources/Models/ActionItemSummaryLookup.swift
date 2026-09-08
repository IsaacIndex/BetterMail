import Foundation

/// Builds once per list projection so each task need not traverse the canvas.
/// Bare summary keys are usable only for an unambiguous physical source.
internal struct ActionItemSummaryLookup {
    private let nodesByMessageID: [String: ThreadNode]

    internal init(roots: [ThreadNode]) {
        var nodesByID: [String: ThreadNode] = [:]
        var ambiguousIDs = Set<String>()
        func visit(_ nodes: [ThreadNode]) {
            for node in nodes {
                let id = node.message.normalizedMessageID
                if !node.message.isEmbeddedHistory, !ambiguousIDs.contains(id) {
                    if let existing = nodesByID[id],
                       ActionItem.scopedID(for: existing.message) != ActionItem.scopedID(for: node.message) {
                        ambiguousIDs.insert(id)
                        nodesByID.removeValue(forKey: id)
                    } else if nodesByID[id] == nil {
                        nodesByID[id] = node
                    }
                }
                visit(node.children)
            }
        }
        visit(roots)
        nodesByMessageID = nodesByID
    }

    internal func node(for item: ActionItem) -> ThreadNode? {
        guard let node = nodesByMessageID[JWZThreader.normalizeIdentifier(item.messageID)] else { return nil }
        let account = item.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.isEmpty || ActionItem.scopedID(for: node.message) == item.id else { return nil }
        return node
    }
}
