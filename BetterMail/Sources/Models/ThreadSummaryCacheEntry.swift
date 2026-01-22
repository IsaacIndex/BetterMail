import Foundation

struct ThreadSummaryCacheEntry: Hashable {
    let threadID: String
    let summaryText: String
    let generatedAt: Date
    let fingerprint: String
    let provider: String
}
