import Foundation

struct EmailThread: Identifiable, Hashable {
    let id: String
    let rootMessageID: String?
    let subject: String
    let lastUpdated: Date
    let unreadCount: Int
    let messageCount: Int
}

struct ThreadNode: Identifiable {
    let id: String
    let message: EmailMessage
    var children: [ThreadNode]

    init(message: EmailMessage, children: [ThreadNode] = []) {
        self.id = message.messageID
        self.message = message
        self.children = children
    }

    var childNodes: [ThreadNode]? {
        children.isEmpty ? nil : children
    }
}
