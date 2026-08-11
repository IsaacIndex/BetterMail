import Foundation

internal enum SummaryScope: String, Hashable {
    case emailNode = "email-node"
    case folder = "folder"
    case emailTag = "email-tag"
    case graphTitle = "graph-title"
    case graphTopic = "graph-topic"
}

internal struct SummaryCacheEntry: Hashable {
    internal let scope: SummaryScope
    internal let scopeID: String
    internal let summaryText: String
    internal let generatedAt: Date
    internal let fingerprint: String
    internal let provider: String
}
