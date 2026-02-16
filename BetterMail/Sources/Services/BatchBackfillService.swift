import Foundation

internal protocol BatchBackfillServicing {
    func countMessages(in range: DateInterval,
                       mailbox: String,
                       account: String?) async throws -> Int
    func runBackfill(range: DateInterval,
                     mailbox: String,
                     account: String?,
                     preferredBatchSize: Int,
                     totalExpected: Int,
                     snippetLineLimit: Int,
                     progressHandler: @Sendable (BatchBackfillProgress) -> Void) async throws -> BatchBackfillResult
}

internal struct BatchBackfillProgress {
    internal enum State {
        case running
        case retrying
        case finished
    }

    internal let total: Int
    internal let completed: Int
    internal let currentBatchSize: Int
    internal let state: State
    internal let errorMessage: String?
}

internal struct BatchBackfillResult {
    internal let total: Int
    internal let fetched: Int
}

internal actor BatchBackfillService: BatchBackfillServicing {
    private let client: MailAppleScriptClient
    private let store: MessageStore

    internal init(client: MailAppleScriptClient = MailAppleScriptClient(),
                  store: MessageStore = .shared) {
        self.client = client
        self.store = store
    }

    internal func countMessages(in range: DateInterval,
                                mailbox: String = "inbox",
                                account: String? = nil) async throws -> Int {
        let now = Date()
        if range.start > now {
            return 0
        }
        let clampedStart = min(range.start, now)
        let clampedEnd = min(range.end, now)
        let clampedRange = DateInterval(start: clampedStart, end: clampedEnd)
        return try await client.countMessages(in: clampedRange, mailbox: mailbox, account: account)
    }

    internal func runBackfill(range: DateInterval,
                              mailbox: String = "inbox",
                              account: String? = nil,
                              preferredBatchSize: Int = 5,
                              totalExpected: Int,
                              snippetLineLimit: Int,
                              progressHandler: @Sendable (BatchBackfillProgress) -> Void) async throws -> BatchBackfillResult {
        let now = Date()
        if range.start > now || totalExpected == 0 {
            progressHandler(BatchBackfillProgress(total: totalExpected,
                                                  completed: 0,
                                                  currentBatchSize: max(1, preferredBatchSize),
                                                  state: .finished,
                                                  errorMessage: nil))
            return BatchBackfillResult(total: totalExpected, fetched: 0)
        }
        let clampedStart = min(range.start, now)
        let clampedEnd = min(range.end, now)
        var remainingRange = DateInterval(start: clampedStart, end: clampedEnd)
        var completed = 0
        var batchSize = max(1, preferredBatchSize)
        let maxBatchSize = max(batchSize, totalExpected)
        var seenMessageIDs = Set<String>()

        while completed < totalExpected {
            do {
                let messages = try await client.fetchMessages(in: remainingRange,
                                                              limit: batchSize,
                                                              mailbox: mailbox,
                                                              account: account,
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
                        if inclusiveEnd <= remainingRange.start {
                            remainingRange = DateInterval(start: remainingRange.start, end: remainingRange.start)
                        } else {
                            remainingRange = DateInterval(start: remainingRange.start, end: inclusiveEnd)
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
