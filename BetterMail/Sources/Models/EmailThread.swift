import Foundation

internal struct EmailThread: Identifiable, Hashable {
    internal let id: String
    internal let rootMessageID: String?
    internal let subject: String
    internal let lastUpdated: Date
    internal let unreadCount: Int
    internal let messageCount: Int
}

internal struct ThreadNode: Identifiable {
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
