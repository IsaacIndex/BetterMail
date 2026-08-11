import Foundation

internal struct GraphFolderSuggestionImpact: Equatable {
    internal struct AffectedFolder: Identifiable, Equatable {
        internal let id: String
        internal let title: String
        internal let movedThreadCount: Int
        internal let willBeRemoved: Bool
    }

    internal let affectedFolders: [AffectedFolder]

    internal var requiresConfirmation: Bool {
        !affectedFolders.isEmpty
    }

    internal var movedThreadCount: Int {
        affectedFolders.reduce(0) { $0 + $1.movedThreadCount }
    }

    internal var removedFolderCount: Int {
        affectedFolders.filter(\.willBeRemoved).count
    }

    internal static let none = GraphFolderSuggestionImpact(affectedFolders: [])
}
