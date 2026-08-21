import Foundation

internal nonisolated struct EmailThread: Identifiable, Hashable, Sendable {
    internal let id: String
    internal let rootMessageID: String?
    internal let subject: String
    internal let lastUpdated: Date
    internal let unreadCount: Int
    internal let messageCount: Int
}

internal nonisolated struct ThreadNode: Identifiable, Sendable {
    internal let id: String
    internal let message: EmailMessage
    internal var children: [ThreadNode]

    internal init(message: EmailMessage, children: [ThreadNode] = []) {
        self.id = message.messageID
        self.message = message
        self.children = children
    }

    internal var childNodes: [ThreadNode]? {
        children.isEmpty ? nil : children
    }
}
