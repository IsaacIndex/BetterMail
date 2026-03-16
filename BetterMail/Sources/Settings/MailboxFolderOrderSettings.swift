import Combine
import Foundation
import SwiftUI

@MainActor
internal final class MailboxFolderOrderSettings: ObservableObject {
    @AppStorage("mailboxSidebarOrderedFolderIDs") private var storedOrderedFolderIDs = ""

    @Published internal var orderedFolderIDs: [String] = [] {
        didSet {
            let normalized = Self.normalizedIDs(orderedFolderIDs)
            if normalized != orderedFolderIDs {
                orderedFolderIDs = normalized
                return
            }
            storedOrderedFolderIDs = Self.encode(normalized)
        }
    }

    internal init() {
        orderedFolderIDs = Self.decode(storedOrderedFolderIDs)
    }

    internal func prune(validIDs: Set<String>) {
        let filtered = orderedFolderIDs.filter { validIDs.contains($0) }
        if filtered != orderedFolderIDs {
            orderedFolderIDs = filtered
        }
    }

    internal func moveRelativeToTarget(sourceID: String,
                                       targetID: String,
                                       siblingIDs: [String],
                                       insertAfterTarget: Bool) {
        guard sourceID != targetID else { return }
        guard siblingIDs.contains(sourceID), siblingIDs.contains(targetID) else { return }

        var updated = orderedFolderIDs
        for siblingID in siblingIDs where !updated.contains(siblingID) {
            updated.append(siblingID)
        }

        guard let sourceIndex = updated.firstIndex(of: sourceID),
              let targetIndex = updated.firstIndex(of: targetID),
              sourceIndex != targetIndex else {
            return
        }

        updated.remove(at: sourceIndex)
        let normalizedTargetIndex = sourceIndex < targetIndex ? (targetIndex - 1) : targetIndex
        let insertionIndex = insertAfterTarget ? (normalizedTargetIndex + 1) : normalizedTargetIndex
        updated.insert(sourceID, at: insertionIndex)
        orderedFolderIDs = updated
    }

    private static func normalizedIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        normalized.reserveCapacity(ids.count)

        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let inserted = seen.insert(trimmed).inserted
            guard inserted else { continue }
            normalized.append(trimmed)
        }

        return normalized
    }

    private static func encode(_ ids: [String]) -> String {
        if let data = try? JSONEncoder().encode(ids),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ids.joined(separator: ",")
    }

    private static func decode(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        if let data = text.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            return normalizedIDs(ids)
        }
        return normalizedIDs(
            text
                .split(separator: ",")
                .map { String($0) }
        )
    }
}
