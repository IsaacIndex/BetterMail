// BetterMail/Sources/Models/ActionItem.swift
import Foundation

// Note: subject, from, date are snapshotted at tag time so ActionItemsView
// can render the list without re-fetching EmailMessage from Core Data.
// This intentionally duplicates a small amount of message data for display convenience.
internal struct ActionItem: Identifiable, Hashable {
    internal let id: String          // matches EmailMessage.messageID
    internal let threadID: String
    internal let subject: String     // snapshotted at tag time
    internal let from: String        // snapshotted at tag time
    internal let date: Date          // snapshotted at tag time
    internal let folderID: String?
    internal let tags: [String]      // snapshotted at tag time, up to 3 (AI-generated)
    internal var isDone: Bool
    internal let addedAt: Date
}
