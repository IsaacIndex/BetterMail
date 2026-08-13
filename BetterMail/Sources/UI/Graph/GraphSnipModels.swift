import Foundation

internal nonisolated enum GraphSnipPhase: Equatable, Sendable {
    case idle
    case staging
    case allocating
    case moving
}

internal nonisolated enum GraphSnipTarget: Equatable, Sendable {
    case thread(String)
    case confirmedGroup(String)
}

internal nonisolated enum GraphSnipVisualChange: Equatable, Sendable {
    case stage
    case unstage
}

internal nonisolated struct GraphSnipVisualTransition: Identifiable, Equatable, Sendable {
    internal let id: UUID
    internal let threadIDs: [String]
    internal let change: GraphSnipVisualChange
    internal let cascades: Bool

    internal init(threadIDs: [String],
                  change: GraphSnipVisualChange,
                  cascades: Bool) {
        self.id = UUID()
        self.threadIDs = threadIDs
        self.change = change
        self.cascades = cascades
    }
}

internal nonisolated enum GraphSnipNodeState: Equatable, Sendable {
    case normal
    case partial
    case staged
}

internal nonisolated struct GraphSnipMessage: Identifiable, Codable, Hashable, Sendable {
    internal let id: String
    internal let sourceMailboxPath: String
    internal let sourceAccountName: String

    internal var locationIdentity: String {
        Self.locationIdentity(messageID: id,
                              accountName: sourceAccountName,
                              mailboxPath: sourceMailboxPath)
    }

    internal static func locationIdentity(messageID: String,
                                          accountName: String,
                                          mailboxPath: String) -> String {
        let account = accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mailbox = mailboxPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(GraphMailMoveResult.normalizedMessageID(messageID))|\(account)|\(mailbox)"
    }
}

internal nonisolated struct GraphSnipItem: Identifiable, Codable, Hashable, Sendable {
    internal let threadID: String
    internal let rawThreadID: String
    internal let rootNodeID: String
    internal let subject: String
    internal let accountName: String
    internal let messages: [GraphSnipMessage]

    internal var id: String { threadID }
}

internal nonisolated struct GraphSnipAllocation: Identifiable, Codable, Hashable, Sendable {
    internal let threadID: String
    internal let destinationMailboxPath: String
    internal let destinationAccountName: String

    internal var id: String { threadID }
}

internal nonisolated struct GraphSnipBatchRequest: Identifiable, Equatable, Sendable {
    internal let id: UUID
    internal let accountName: String
    internal let items: [GraphSnipItem]

    internal init(id: UUID = UUID(),
                  accountName: String,
                  items: [GraphSnipItem]) {
        self.id = id
        self.accountName = accountName
        self.items = items
    }
}

internal nonisolated struct GraphMailMoveResult: Equatable, Sendable {
    internal let movedMessageIDs: [String]

    internal init(movedMessageIDs: [String]) {
        var seen: Set<String> = []
        self.movedMessageIDs = movedMessageIDs.compactMap { rawID in
            let normalized = Self.normalizedMessageID(rawID)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    internal static func normalizedMessageID(_ rawID: String) -> String {
        MailControl.cleanMessageIDPreservingCase(rawID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    internal func contains(_ messageID: String) -> Bool {
        movedMessageIDs.contains(Self.normalizedMessageID(messageID))
    }
}

internal nonisolated protocol GraphSnipMailMoving: Sendable {
    func moveMessages(messageIDs: [String],
                      toMailboxPath mailboxPath: String,
                      account: String?,
                      sourceMailboxPath: String?,
                      sourceAccount: String?) async throws -> GraphMailMoveResult
}

internal nonisolated struct GraphSnipMovedMessage: Identifiable, Codable, Hashable, Sendable {
    internal let messageID: String
    internal let sourceMailboxPath: String
    internal let sourceAccountName: String
    internal let destinationMailboxPath: String
    internal let destinationAccountName: String

    internal var id: String {
        GraphSnipMessage.locationIdentity(messageID: messageID,
                                          accountName: sourceAccountName,
                                          mailboxPath: sourceMailboxPath)
    }
}

internal nonisolated struct GraphSnipBatchOutcome: Identifiable, Equatable, Sendable {
    internal let item: GraphSnipItem
    internal let allocation: GraphSnipAllocation
    internal let displacedMessages: [GraphSnipMovedMessage]

    internal var id: String { item.id }
}

internal nonisolated struct GraphSnipBatchResult: Equatable, Sendable {
    internal var succeeded: [GraphSnipBatchOutcome] = []
    internal var unchanged: [GraphSnipBatchOutcome] = []
    internal var rolledBack: [GraphSnipBatchOutcome] = []
    internal var recoveryNeeded: [GraphSnipBatchOutcome] = []

    internal var attemptedCount: Int {
        succeeded.count + unchanged.count + rolledBack.count + recoveryNeeded.count
    }
}

internal nonisolated struct GraphSnipNotice: Identifiable, Equatable, Sendable {
    internal nonisolated enum Style: Equatable, Sendable {
        case information
        case success
        case error
    }

    internal let id: UUID
    internal let message: String
    internal let style: Style

    internal init(message: String, style: Style = .information) {
        self.id = UUID()
        self.message = message
        self.style = style
    }
}
