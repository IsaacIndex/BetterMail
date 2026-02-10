import Combine
import Foundation
import SwiftUI

@MainActor
internal final class PinnedFolderSettings: ObservableObject {
    @AppStorage("threadCanvasPinnedFolderIDs") private var storedPinnedFolderIDs = ""

    @Published internal var pinnedFolderIDs: Set<String> = [] {
        didSet {
            storedPinnedFolderIDs = Self.encode(pinnedFolderIDs)
        }
    }

    internal init() {
        pinnedFolderIDs = Set(Self.decode(storedPinnedFolderIDs))
    }

    internal func pin(_ id: String) {
        guard !id.isEmpty else { return }
        guard !pinnedFolderIDs.contains(id) else { return }
        var updated = pinnedFolderIDs
        updated.insert(id)
        pinnedFolderIDs = updated
    }

    internal func unpin(_ id: String) {
        guard pinnedFolderIDs.contains(id) else { return }
        var updated = pinnedFolderIDs
        updated.remove(id)
        pinnedFolderIDs = updated
    }

    internal func prune(validIDs: Set<String>) {
        let filtered = pinnedFolderIDs.intersection(validIDs)
        if filtered != pinnedFolderIDs {
            pinnedFolderIDs = filtered
        }
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
