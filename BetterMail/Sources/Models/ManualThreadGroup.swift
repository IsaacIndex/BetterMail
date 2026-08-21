import Foundation

internal nonisolated struct ManualThreadGroup: Identifiable, Codable, Hashable, Sendable {
    internal let id: String
    internal var jwzThreadIDs: Set<String>
    internal var manualMessageKeys: Set<String>
}
