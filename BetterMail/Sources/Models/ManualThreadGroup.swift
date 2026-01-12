import Foundation

struct ManualThreadGroup: Identifiable, Hashable {
    let id: String
    var jwzThreadIDs: Set<String>
    var manualMessageKeys: Set<String>
}
