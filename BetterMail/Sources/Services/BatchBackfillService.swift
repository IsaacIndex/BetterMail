import Foundation

struct BatchBackfillProgress {
    enum State {
        case running
        case retrying
        case finished
    }

    let total: Int
    let completed: Int
    let currentBatchSize: Int
    let state: State
    let errorMessage: String?
}

struct BatchBackfillResult {
    let total: Int
    let fetched: Int
}

actor BatchBackfillService {
    private let client: MailAppleScriptClient
    private let store: MessageStore

    init(client: MailAppleScriptClient = MailAppleScriptClient(),
         store: MessageStore = .shared) {
        self.client = client
        self.store = store
    }

    func countMessages(in range: DateInterval, mailbox: String = "inbox") async throws -> Int {
        let now = Date()
        let clampedEnd = min(range.end, now)
        let clampedRange = DateInterval(start: range.start, end: clampedEnd)
        return try await client.countMessages(in: clampedRange, mailbox: mailbox)
    }

    func runBackfill(range: DateInterval,
                     mailbox: String = "inbox",
                     preferredBatchSize: Int = 5,
                     totalExpected: Int,
                     snippetLineLimit: Int,
                     progressHandler: @Sendable (BatchBackfillProgress) -> Void) async throws -> BatchBackfillResult {
        let now = Date()
        let clampedEnd = min(range.end, now)
        var remainingRange = DateInterval(start: range.start, end: clampedEnd)
        var completed = 0
        var batchSize = max(1, preferredBatchSize)
        let maxBatchSize = max(batchSize, preferredBatchSize * 5)
        var seenMessageIDs = Set<String>()

        while completed < totalExpected {
            do {
                let messages = try await client.fetchMessages(in: remainingRange,
                                                              limit: batchSize,
                                                              mailbox: mailbox,
                                                              snippetLineLimit: snippetLineLimit)
                guard !messages.isEmpty else { break }
                let uniqueMessages = messages.filter { seenMessageIDs.insert($0.messageID).inserted }
                if !uniqueMessages.isEmpty {
                    try await store.upsert(messages: uniqueMessages)
                    completed += uniqueMessages.count
                }

                if let oldestDate = messages.map(\.date).min() {
                    let shouldExpandBatch = uniqueMessages.isEmpty && messages.count == batchSize && batchSize < maxBatchSize
                    if shouldExpandBatch {
                        batchSize = min(maxBatchSize, batchSize + preferredBatchSize)
                    } else {
                        let inclusiveEnd = min(remainingRange.end, oldestDate.addingTimeInterval(1))
                        let nextEnd = uniqueMessages.isEmpty ? oldestDate.addingTimeInterval(-1) : inclusiveEnd
                        if nextEnd <= remainingRange.start {
                            remainingRange = DateInterval(start: remainingRange.start, end: remainingRange.start)
                        } else {
                            remainingRange = DateInterval(start: remainingRange.start, end: nextEnd)
                        }
                    }
                }

                progressHandler(BatchBackfillProgress(total: totalExpected,
                                                      completed: completed,
                                                      currentBatchSize: batchSize,
                                                      state: .running,
                                                      errorMessage: nil))
                if !uniqueMessages.isEmpty {
                    batchSize = max(1, preferredBatchSize)
                }

                if remainingRange.duration <= 0 {
                    break
                }
            } catch {
                if batchSize > 1 {
                    batchSize = max(1, batchSize - 1)
                    progressHandler(BatchBackfillProgress(total: totalExpected,
                                                          completed: completed,
                                                          currentBatchSize: batchSize,
                                                          state: .retrying,
                                                          errorMessage: error.localizedDescription))
                    continue
                } else {
                    progressHandler(BatchBackfillProgress(total: totalExpected,
                                                          completed: completed,
                                                          currentBatchSize: batchSize,
                                                          state: .finished,
                                                          errorMessage: error.localizedDescription))
                    throw error
                }
            }
        }

        progressHandler(BatchBackfillProgress(total: totalExpected,
                                              completed: completed,
                                              currentBatchSize: batchSize,
                                              state: .finished,
                                              errorMessage: nil))
        return BatchBackfillResult(total: totalExpected, fetched: completed)
    }
}
