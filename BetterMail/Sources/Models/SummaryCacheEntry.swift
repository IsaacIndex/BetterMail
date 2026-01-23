import Foundation

enum SummaryScope: String, Hashable {
    case emailNode = "email-node"
    case folder = "folder"
}

struct SummaryCacheEntry: Hashable {
    let scope: SummaryScope
    let scopeID: String
    let summaryText: String
    let generatedAt: Date
    let fingerprint: String
    let provider: String
}
