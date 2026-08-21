import Foundation

internal nonisolated struct EmbeddedEmailMessage: Codable, Hashable, Sendable {
    internal let id: String
    internal let originalMessageID: String?
    internal let subject: String
    internal let from: String
    internal let to: String
    internal let date: Date?
    internal let snippet: String
    internal let sourceOrder: Int
}

internal nonisolated struct EmailMessageSource: Hashable, Sendable {
    internal let messageID: String
    internal let internalMailID: String?
    internal let mailboxID: String
    internal let accountName: String
    internal let subject: String
    internal let from: String
    internal let date: Date
}

internal nonisolated struct EmailMessage: Identifiable, Hashable, Sendable {
    internal let id: UUID
    internal let messageID: String
    internal let internalMailID: String?
    internal let mailboxID: String
    internal let accountName: String
    internal let subject: String
    internal let from: String
    internal let to: String
    internal let date: Date
    internal let snippet: String
    internal let isUnread: Bool
    internal let isCalendarRSVP: Bool
    internal let calendarMessageKind: CalendarMessageKind?
    internal let inReplyTo: String?
    internal let references: [String]
    internal let threadID: String?
    internal let rawSourceLocation: URL?
    internal let embeddedMessages: [EmbeddedEmailMessage]
    internal let embeddedSource: EmailMessageSource?

    internal init(id: UUID = UUID(),
                  messageID: String,
                  internalMailID: String? = nil,
                  mailboxID: String,
                  accountName: String,
                  subject: String,
                  from: String,
                  to: String,
                  date: Date,
                  snippet: String,
                  isUnread: Bool,
                  isCalendarRSVP: Bool = false,
                  calendarMessageKind: CalendarMessageKind? = nil,
                  inReplyTo: String?,
                  references: [String],
                  threadID: String? = nil,
                  rawSourceLocation: URL? = nil,
                  embeddedMessages: [EmbeddedEmailMessage] = [],
                  embeddedSource: EmailMessageSource? = nil) {
        self.id = id
        self.messageID = messageID
        self.internalMailID = internalMailID
        self.mailboxID = mailboxID
        self.accountName = accountName
        self.subject = subject
        self.from = from
        self.to = to
        self.date = date
        self.snippet = snippet
        self.isUnread = isUnread
        let resolvedCalendarKind: CalendarMessageKind
        if let calendarMessageKind {
            resolvedCalendarKind = calendarMessageKind
        } else if isCalendarRSVP {
            resolvedCalendarKind = .attendanceOnlyResponse
        } else {
            resolvedCalendarKind = CalendarRSVPClassifier.classify(snippet).kind
        }
        self.calendarMessageKind = resolvedCalendarKind
        self.isCalendarRSVP = resolvedCalendarKind.shouldSuppress
        self.inReplyTo = inReplyTo
        self.references = references
        self.threadID = threadID
        self.rawSourceLocation = rawSourceLocation
        self.embeddedMessages = embeddedMessages
        self.embeddedSource = embeddedSource
    }

    internal var normalizedMessageID: String {
        JWZThreader.normalizeIdentifier(messageID)
    }

    internal var threadKey: String {
        let normalized = normalizedMessageID
        return normalized.isEmpty ? id.uuidString.lowercased() : normalized
    }

    internal var isEmbeddedHistory: Bool {
        embeddedSource != nil
    }

    internal var physicalSource: EmailMessageSource {
        embeddedSource ?? EmailMessageSource(messageID: messageID,
                                             internalMailID: internalMailID,
                                             mailboxID: mailboxID,
                                             accountName: accountName,
                                             subject: subject,
                                             from: from,
                                             date: date)
    }

    internal func assigning(threadID: String?) -> EmailMessage {
        EmailMessage(id: id,
                     messageID: messageID,
                     internalMailID: internalMailID,
                     mailboxID: mailboxID,
                     accountName: accountName,
                     subject: subject,
                     from: from,
                     to: to,
                     date: date,
                     snippet: snippet,
                     isUnread: isUnread,
                     isCalendarRSVP: isCalendarRSVP,
                     calendarMessageKind: calendarMessageKind,
                     inReplyTo: inReplyTo,
                     references: references,
                     threadID: threadID,
                     rawSourceLocation: rawSourceLocation,
                     embeddedMessages: embeddedMessages,
                     embeddedSource: embeddedSource)
    }

    internal func assigning(internalMailID: String?) -> EmailMessage {
        EmailMessage(id: id,
                     messageID: messageID,
                     internalMailID: internalMailID,
                     mailboxID: mailboxID,
                     accountName: accountName,
                     subject: subject,
                     from: from,
                     to: to,
                     date: date,
                     snippet: snippet,
                     isUnread: isUnread,
                     isCalendarRSVP: isCalendarRSVP,
                     calendarMessageKind: calendarMessageKind,
                     inReplyTo: inReplyTo,
                     references: references,
                     threadID: threadID,
                     rawSourceLocation: rawSourceLocation,
                     embeddedMessages: embeddedMessages,
                     embeddedSource: embeddedSource)
    }

    internal func assigning(mailboxID: String, accountName: String) -> EmailMessage {
        EmailMessage(id: id,
                     messageID: messageID,
                     internalMailID: internalMailID,
                     mailboxID: mailboxID,
                     accountName: accountName,
                     subject: subject,
                     from: from,
                     to: to,
                     date: date,
                     snippet: snippet,
                     isUnread: isUnread,
                     isCalendarRSVP: isCalendarRSVP,
                     calendarMessageKind: calendarMessageKind,
                     inReplyTo: inReplyTo,
                     references: references,
                     threadID: threadID,
                     rawSourceLocation: rawSourceLocation,
                     embeddedMessages: embeddedMessages,
                     embeddedSource: embeddedSource)
    }
}

internal extension EmailMessageSource {
    func matches(_ message: EmailMessage) -> Bool {
        let normalizedAccount = accountName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidateAccount = message.accountName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedAccount == candidateAccount else { return false }

        if let internalMailID,
           !internalMailID.isEmpty,
           internalMailID == message.internalMailID {
            return true
        }

        let normalizedMessageID = JWZThreader.normalizeIdentifier(messageID)
        guard !normalizedMessageID.isEmpty,
              normalizedMessageID == message.normalizedMessageID else {
            return false
        }
        return mailboxID.caseInsensitiveCompare(message.mailboxID) == .orderedSame
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

internal enum MailboxRefreshSubjectNormalizer {
    private static let replyPrefixes = ["re:", "fw:", "fwd:", "aw:", "sv:", "wg:"]

    internal static func normalize(_ subject: String) -> String {
        var normalized = collapseWhitespace(subject)
        guard !normalized.isEmpty else { return "" }

        for _ in 0..<12 {
            let previous = normalized
            normalized = stripLeadingBracketToken(normalized)

            let lowered = normalized.lowercased()
            if let prefix = replyPrefixes.first(where: { lowered.hasPrefix($0) }) {
                normalized = String(normalized.dropFirst(prefix.count))
            }

            normalized = collapseWhitespace(normalized)
            if normalized == previous {
                break
            }
        }

        return normalized.lowercased()
    }

    private static func stripLeadingBracketToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let closing = trimmed.firstIndex(of: "]") else {
            return trimmed
        }
        let suffix = trimmed[trimmed.index(after: closing)...]
        return String(suffix).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
