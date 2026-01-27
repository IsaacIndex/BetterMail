import Foundation

internal struct EmailMessage: Identifiable, Hashable {
    internal let id: UUID
    internal let messageID: String
    internal let mailboxID: String
    internal let accountName: String
    internal let subject: String
    internal let from: String
    internal let to: String
    internal let date: Date
    internal let snippet: String
    internal let isUnread: Bool
    internal let inReplyTo: String?
    internal let references: [String]
    internal let threadID: String?
    internal let rawSourceLocation: URL?

    internal init(id: UUID = UUID(),
                  messageID: String,
                  mailboxID: String,
                  accountName: String,
                  subject: String,
                  from: String,
                  to: String,
                  date: Date,
                  snippet: String,
                  isUnread: Bool,
                  inReplyTo: String?,
                  references: [String],
                  threadID: String? = nil,
                  rawSourceLocation: URL? = nil) {
        self.id = id
        self.messageID = messageID
        self.mailboxID = mailboxID
        self.accountName = accountName
        self.subject = subject
        self.from = from
        self.to = to
        self.date = date
        self.snippet = snippet
        self.isUnread = isUnread
        self.inReplyTo = inReplyTo
        self.references = references
        self.threadID = threadID
        self.rawSourceLocation = rawSourceLocation
    }

    internal var normalizedMessageID: String {
        JWZThreader.normalizeIdentifier(messageID)
    }

    internal var threadKey: String {
        let normalized = normalizedMessageID
        return normalized.isEmpty ? id.uuidString.lowercased() : normalized
    }

    internal func assigning(threadID: String?) -> EmailMessage {
        EmailMessage(id: id,
                     messageID: messageID,
                     mailboxID: mailboxID,
                     accountName: accountName,
                     subject: subject,
                     from: from,
                     to: to,
                     date: date,
                     snippet: snippet,
                     isUnread: isUnread,
                     inReplyTo: inReplyTo,
                     references: references,
                     threadID: threadID,
                     rawSourceLocation: rawSourceLocation)
    }
}

internal extension EmailMessage {
    static let placeholder = EmailMessage(messageID: UUID().uuidString,
                                          mailboxID: "inbox",
                                          accountName: "",
                                          subject: "",
                                          from: "",
                                          to: "",
                                          date: Date(),
                                          snippet: "",
                                          isUnread: false,
                                          inReplyTo: nil,
                                          references: [])
}
