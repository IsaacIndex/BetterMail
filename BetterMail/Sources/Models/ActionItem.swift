// BetterMail/Sources/Models/ActionItem.swift
import Foundation

// Note: subject, from, date are snapshotted at tag time so ActionItemsView
// can render the list without re-fetching EmailMessage from Core Data.
// This intentionally duplicates a small amount of message data for display convenience.
internal struct ActionItem: Identifiable, Hashable {
    internal let messageID: String
    internal let accountName: String
    internal let threadID: String
    internal let subject: String     // snapshotted at tag time
    internal let from: String        // snapshotted at tag time
    internal let date: Date          // snapshotted at tag time
    internal let folderID: String?
    internal let tags: [String]      // snapshotted at tag time, up to 3 (AI-generated)
    internal var isDone: Bool
    internal let addedAt: Date

    internal var id: String {
        Self.scopedID(messageID: messageID, accountName: accountName)
    }

    internal nonisolated static func scopedID(messageID: String, accountName: String) -> String {
        let account = accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessageID = JWZThreader.normalizeIdentifier(messageID)
        return "\(account.utf8.count):\(account)|\(normalizedMessageID)"
    }

    internal nonisolated static func scopedID(for message: EmailMessage) -> String {
        scopedID(messageID: message.physicalSource.messageID,
                 accountName: message.physicalSource.accountName)
    }
}
