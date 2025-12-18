import Foundation

struct EmailMessage: Identifiable, Hashable {
    let id: UUID
    let messageID: String
    let mailboxID: String
    let subject: String
    let from: String
    let to: String
    let date: Date
    let snippet: String
    let isUnread: Bool
    let inReplyTo: String?
    let references: [String]
    let threadID: String?
    let rawSourceLocation: URL?

    init(id: UUID = UUID(),
         messageID: String,
         mailboxID: String,
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

    var normalizedMessageID: String {
        JWZThreader.normalizeIdentifier(messageID)
    }

    func assigning(threadID: String?) -> EmailMessage {
        EmailMessage(id: id,
                     messageID: messageID,
                     mailboxID: mailboxID,
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

extension EmailMessage {
    static let placeholder = EmailMessage(messageID: UUID().uuidString,
                                          mailboxID: "inbox",
                                          subject: "",
                                          from: "",
                                          to: "",
                                          date: Date(),
                                          snippet: "",
                                          isUnread: false,
                                          inReplyTo: nil,
                                          references: [])
}
