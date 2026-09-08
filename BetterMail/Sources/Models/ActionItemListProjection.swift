import Foundation

/// The same projection drives rows, counts, empty states, and selection pruning.
internal struct ActionItemListProjection {
    internal enum EmptyState: Equatable {
        case noItems
        case allDone
        case noMatches
    }

    internal struct Group: Identifiable {
        internal var id: String { folderID.map { "folder:\($0)" } ?? "unfiled" }
        internal let folderID: String?
        internal let title: String?
        internal let items: [ActionItem]
    }

    internal let groups: [Group]
    internal let visibleItems: [ActionItem]
    internal let openCount: Int
    internal let openGroupCount: Int
    internal let emptyState: EmptyState?

    internal init(items: [ActionItem],
                  folders: [ThreadFolder],
                  showDone: Bool,
                  query: String) {
        let titles = Dictionary(folders.map { ($0.id, $0.title) },
                                uniquingKeysWith: { first, _ in first })
        let openItems = items.filter { !$0.isDone }
        openCount = openItems.count
        openGroupCount = Set(openItems.compactMap { item in
            item.folderID.flatMap { titles[$0] == nil ? nil : $0 }
        }).count
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleItems = items.filter { item in
            guard showDone || !item.isDone else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            let values = [item.subject, item.from, item.accountName,
                          item.folderID.flatMap { titles[$0] } ?? ""] + item.tags
            return values.contains {
                $0.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        let grouped = Dictionary(grouping: visibleItems) { item -> String? in
            // A deleted group is an unfiled task, not a raw identifier in the UI.
            item.folderID.flatMap { titles[$0] == nil ? nil : $0 }
        }
        groups = grouped.map { folderID, groupItems in
            Group(folderID: folderID,
                  title: folderID.flatMap { titles[$0] },
                  items: groupItems.sorted {
                      $0.addedAt == $1.addedAt ? $0.id < $1.id : $0.addedAt > $1.addedAt
                  })
        }.sorted {
            if $0.folderID == nil { return false }
            if $1.folderID == nil { return true }
            let comparison = ($0.title ?? "").localizedStandardCompare($1.title ?? "")
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        if items.isEmpty {
            emptyState = .noItems
        } else if !visibleItems.isEmpty {
            emptyState = nil
        } else if !trimmedQuery.isEmpty {
            emptyState = .noMatches
        } else {
            emptyState = .allDone
        }
    }
}
