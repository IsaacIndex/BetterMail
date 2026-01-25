import Foundation

internal struct ManualThreadGroup: Identifiable, Hashable {
    internal let id: String
    internal var jwzThreadIDs: Set<String>
    internal var manualMessageKeys: Set<String>
}
