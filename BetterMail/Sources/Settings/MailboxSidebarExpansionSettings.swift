import Combine
import Foundation
import SwiftUI

@MainActor
internal final class MailboxSidebarExpansionSettings: ObservableObject {
    @AppStorage("mailboxSidebarExpandedFolderIDs") private var storedExpandedFolderIDs = ""

    @Published internal var expandedFolderIDs: Set<String> = [] {
        didSet {
            let normalized = Self.normalizedIDs(expandedFolderIDs)
            if normalized != expandedFolderIDs {
                expandedFolderIDs = normalized
                return
            }
            storedExpandedFolderIDs = Self.encode(normalized)
        }
    }

    internal init() {
        expandedFolderIDs = Set(Self.decode(storedExpandedFolderIDs))
    }

    internal func isExpanded(_ id: String) -> Bool {
        expandedFolderIDs.contains(id)
    }

    internal func setExpanded(_ id: String, expanded: Bool) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        var updated = expandedFolderIDs
        if expanded {
            updated.insert(trimmedID)
        } else {
            updated.remove(trimmedID)
        }
        expandedFolderIDs = updated
    }

    internal func toggle(_ id: String) {
        setExpanded(id, expanded: !isExpanded(id))
    }

    internal func prune(validIDs: Set<String>) {
        let filtered = expandedFolderIDs.intersection(validIDs)
        if filtered != expandedFolderIDs {
            expandedFolderIDs = filtered
        }
    }

    private static func normalizedIDs(_ ids: Set<String>) -> Set<String> {
        var normalized: Set<String> = []
        normalized.reserveCapacity(ids.count)
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            normalized.insert(trimmed)
        }
        return normalized
    }

    private static func encode(_ ids: Set<String>) -> String {
        let ordered = ids.sorted()
        if let data = try? JSONEncoder().encode(ordered),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ordered.joined(separator: ",")
    }

    private static func decode(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        if let data = text.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            return ids
        }
        return text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
