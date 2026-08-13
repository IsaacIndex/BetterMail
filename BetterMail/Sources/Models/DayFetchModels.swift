import Foundation

internal struct DayFetchScope: Hashable, Sendable {
    internal let mailbox: String
    internal let account: String?
    internal let displayName: String
    internal let includesAllInboxAliases: Bool

    internal init(mailbox: String,
                  account: String?,
                  displayName: String,
                  includesAllInboxAliases: Bool = false) {
        self.mailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.account = trimmedAccount.isEmpty ? nil : trimmedAccount
        self.displayName = displayName
        self.includesAllInboxAliases = includesAllInboxAliases
    }

    internal var key: String {
        let accountKey = account?.lowercased() ?? "*"
        return "\(accountKey)|\(mailbox.lowercased())"
    }
}

internal struct MessageReference: Hashable, Sendable {
    internal let internalMailID: String?
    internal let messageID: String
    internal let mailbox: String
    internal let account: String
    internal let subject: String
    internal let date: Date
    internal let isUnread: Bool

    internal init(internalMailID: String?,
                  messageID: String,
                  mailbox: String,
                  account: String,
                  subject: String,
                  date: Date,
                  isUnread: Bool) {
        let trimmedInternalID = internalMailID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.internalMailID = trimmedInternalID.isEmpty ? nil : trimmedInternalID
        self.messageID = messageID
        self.mailbox = mailbox
        self.account = account
        self.subject = subject
        self.date = date
        self.isUnread = isUnread
    }

    internal init(message: EmailMessage) {
        self.init(internalMailID: message.internalMailID,
                  messageID: message.messageID,
                  mailbox: message.mailboxID,
                  account: message.accountName,
                  subject: message.subject,
                  date: message.date,
                  isUnread: message.isUnread)
    }

    internal var stableIdentity: String {
        if let internalMailID {
            return "mail|\(normalized(account))|\(normalized(mailbox))|\(internalMailID)"
        }
        return normalizedMessageIdentity
    }

    internal var normalizedMessageIdentity: String {
        "message|\(normalized(account))|\(normalized(mailbox))|\(normalized(messageID))"
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

internal enum DayCoverageState: String, CaseIterable, Codable, Sendable {
    case unknown
    case fetching
    case partial
    case verified
    case failed
}

internal struct DayFetchCoverage: Identifiable, Hashable, Sendable {
    internal let id: String
    internal let scopeKey: String
    internal let mailbox: String
    internal let account: String?
    internal let dayStart: Date
    internal let dayEnd: Date
    internal let firstTouchedAt: Date
    internal let lastAttemptAt: Date
    internal let lastSuccessAt: Date?
    internal let coveredThrough: Date?
    internal let expectedCount: Int
    internal let fetchedCount: Int
    internal let absentCount: Int
    internal let state: DayCoverageState
    internal let errorMessage: String?
}

internal enum DayFetchMode: Equatable, Sendable {
    case refresh
    case full

    internal var profile: MailFetchProfile {
        switch self {
        case .refresh:
            return .refresh
        case .full:
            return .full
        }
    }
}

internal struct DayFetchProgress: Sendable {
    internal enum Phase: Sendable {
        case manifest
        case payloads
        case verifying
        case reconciling
    }

    internal let dayInterval: DateInterval
    internal let phase: Phase
    internal let completed: Int
    internal let total: Int
}

internal struct DayFetchResult: Sendable {
    internal let dayInterval: DateInterval
    internal let coveredThrough: Date
    internal let expectedCount: Int
    internal let fetchedCount: Int
    internal let downloadedCount: Int
    internal let absentCount: Int
    internal let coverage: DayFetchCoverage
}
