import Foundation

internal struct ThreadSummaryCacheEntry: Hashable {
    internal let threadID: String
    internal let summaryText: String
    internal let generatedAt: Date
    internal let fingerprint: String
    internal let provider: String
}
