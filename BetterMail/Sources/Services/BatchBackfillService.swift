import Foundation

internal protocol MailMessageFetching {
    func countMessages(in range: DateInterval, mailbox: String, account: String?) async throws -> Int
    func fetchMessages(in range: DateInterval,
                       limit: Int,
                       mailbox: String,
                       account: String?,
                       snippetLineLimit: Int) async throws -> [EmailMessage]
    func countMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                       mailbox: String,
                       account: String?) async throws -> Int
    func fetchMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                       limit: Int,
                       mailbox: String,
                       account: String?,
                       snippetLineLimit: Int) async throws -> [EmailMessage]
}

extension MailAppleScriptClient: MailMessageFetching {}

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
    func countMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                       mailbox: String,
                       account: String?) async throws -> Int
    func fetchMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                       mailbox: String,
                       account: String?,
                       limit: Int,
                       snippetLineLimit: Int) async throws -> [EmailMessage]
}

internal struct BatchBackfillProgress {
    internal enum State {
        case running
        case splitting
        case retrying
        case finished
    }

    internal let total: Int
    internal let completed: Int
    internal let currentBatchSize: Int
    internal let currentRange: DateInterval?
    internal let rangeMessageCount: Int?
    internal let state: State
    internal let errorMessage: String?
}

internal struct BatchBackfillResult {
    internal let total: Int
    internal let fetched: Int
}

private enum BatchBackfillServiceError: LocalizedError {
    case incompleteFetch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case let .incompleteFetch(expected, actual):
            return "Fetched \(actual) of \(expected) messages for the current interval."
        }
    }
}

internal actor BatchBackfillService: BatchBackfillServicing {
    nonisolated internal static let maximumFetchCount = 4

    private let client: any MailMessageFetching
    private let store: MessageStore
    private let calendar: Calendar

    internal init(client: any MailMessageFetching = MailAppleScriptClient(),
                  store: MessageStore = .shared,
                  calendar: Calendar = .current) {
        self.client = client
        self.store = store
        self.calendar = calendar
    }

    internal func countMessages(in range: DateInterval,
                                mailbox: String = "inbox",
                                account: String? = nil) async throws -> Int {
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        let now = Date()
        if range.start > now || totalExpected == 0 {
            progressHandler(BatchBackfillProgress(total: totalExpected,
                                                  completed: 0,
                                                  currentBatchSize: max(1, preferredBatchSize),
                                                  currentRange: nil,
                                                  rangeMessageCount: nil,
                                                  state: .finished,
                                                  errorMessage: nil))
            return BatchBackfillResult(total: totalExpected, fetched: 0)
        }
        let clampedStart = min(range.start, now)
        let clampedEnd = min(range.end, now)
        let clampedRange = DateInterval(start: clampedStart, end: clampedEnd)
        var pendingRanges = makeInitialRanges(for: clampedRange)
        var completed = 0
        var currentBatchSize = max(1, preferredBatchSize)
        var seenMessageIDs = Set<String>()

        while completed < totalExpected && !pendingRanges.isEmpty {
            try Task.checkCancellation()
            let nextRange = pendingRanges.removeFirst()
            do {
                let expectedCount = try await client.countMessages(in: nextRange,
                                                                   mailbox: mailbox,
                                                                   account: account)
                try Task.checkCancellation()
                guard expectedCount > 0 else { continue }

                if expectedCount > Self.maximumFetchCount {
                    try splitAndRetry(range: nextRange,
                                      totalExpected: totalExpected,
                                      completed: completed,
                                      expectedCount: expectedCount,
                                      currentBatchSize: &currentBatchSize,
                                      progressHandler: progressHandler,
                                      pendingRanges: &pendingRanges,
                                      state: .splitting,
                                      error: nil)
                    continue
                }

                currentBatchSize = expectedCount
                let messages = try await client.fetchMessages(in: nextRange,
                                                              limit: expectedCount,
                                                              mailbox: mailbox,
                                                              account: account,
                                                              snippetLineLimit: snippetLineLimit)
                try Task.checkCancellation()
                guard !messages.isEmpty else { continue }

                let uniqueMessages = messages.filter { seenMessageIDs.insert($0.messageID).inserted }
                guard uniqueMessages.count == expectedCount else {
                    try splitAndRetry(range: nextRange,
                                      totalExpected: totalExpected,
                                      completed: completed,
                                      expectedCount: expectedCount,
                                      currentBatchSize: &currentBatchSize,
                                      progressHandler: progressHandler,
                                      pendingRanges: &pendingRanges,
                                      state: .retrying,
                                      error: BatchBackfillServiceError.incompleteFetch(expected: expectedCount,
                                                                                      actual: uniqueMessages.count))
                    continue
                }

                try await store.upsert(messages: uniqueMessages)
                try Task.checkCancellation()
                completed += uniqueMessages.count

                progressHandler(BatchBackfillProgress(total: totalExpected,
                                                      completed: min(completed, totalExpected),
                                                      currentBatchSize: currentBatchSize,
                                                      currentRange: nextRange,
                                                      rangeMessageCount: expectedCount,
                                                      state: .running,
                                                      errorMessage: nil))
            } catch {
                do {
                    try splitAndRetry(range: nextRange,
                                      totalExpected: totalExpected,
                                      completed: completed,
                                      expectedCount: currentBatchSize,
                                      currentBatchSize: &currentBatchSize,
                                      progressHandler: progressHandler,
                                      pendingRanges: &pendingRanges,
                                      state: .retrying,
                                      error: error)
                } catch {
                    progressHandler(BatchBackfillProgress(total: totalExpected,
                                                          completed: min(completed, totalExpected),
                                                          currentBatchSize: currentBatchSize,
                                                          currentRange: nextRange,
                                                          rangeMessageCount: nil,
                                                          state: .finished,
                                                          errorMessage: error.localizedDescription))
                    throw error
                }
            }
        }

        progressHandler(BatchBackfillProgress(total: totalExpected,
                                              completed: min(completed, totalExpected),
                                              currentBatchSize: currentBatchSize,
                                              currentRange: nil,
                                              rangeMessageCount: nil,
                                              state: .finished,
                                              errorMessage: nil))
        return BatchBackfillResult(total: totalExpected, fetched: completed)
    }

    internal func countMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                                mailbox: String = "inbox",
                                account: String? = nil) async throws -> Int {
        let filteredSubjects = normalizedSubjects
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !filteredSubjects.isEmpty else { return 0 }
        try Task.checkCancellation()
        return try await client.countMessages(matchingNormalizedSubjects: filteredSubjects,
                                              mailbox: mailbox,
                                              account: account)
    }

    internal func fetchMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                                mailbox: String = "inbox",
                                account: String? = nil,
                                limit: Int,
                                snippetLineLimit: Int) async throws -> [EmailMessage] {
        let filteredSubjects = normalizedSubjects
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !filteredSubjects.isEmpty, limit > 0 else { return [] }
        try Task.checkCancellation()
        return try await client.fetchMessages(matchingNormalizedSubjects: filteredSubjects,
                                              limit: limit,
                                              mailbox: mailbox,
                                              account: account,
                                              snippetLineLimit: snippetLineLimit)
    }

    private func splitAndRetry(range: DateInterval,
                               totalExpected: Int,
                               completed: Int,
                               expectedCount: Int,
                               currentBatchSize: inout Int,
                               progressHandler: @Sendable (BatchBackfillProgress) -> Void,
                               pendingRanges: inout [DateInterval],
                               state: BatchBackfillProgress.State,
                               error: Error?) throws {
        guard let splitRanges = split(range: range) else {
            throw error ?? BatchBackfillServiceError.incompleteFetch(expected: expectedCount, actual: 0)
        }

        currentBatchSize = min(Self.maximumFetchCount, max(1, expectedCount / 2))
        pendingRanges.insert(contentsOf: splitRanges, at: 0)
        progressHandler(BatchBackfillProgress(total: totalExpected,
                                              completed: min(completed, totalExpected),
                                              currentBatchSize: currentBatchSize,
                                              currentRange: range,
                                              rangeMessageCount: expectedCount,
                                              state: state,
                                              errorMessage: error?.localizedDescription))
    }

    private func makeInitialRanges(for range: DateInterval) -> [DateInterval] {
        guard range.duration > 0 else { return [] }

        var ranges: [DateInterval] = []
        var bucketEnd = range.end
        while bucketEnd > range.start {
            let anchor = bucketEnd.addingTimeInterval(-1)
            let bucketStart = max(range.start, calendar.startOfDay(for: anchor))
            ranges.append(DateInterval(start: bucketStart, end: bucketEnd))
            bucketEnd = bucketStart
        }
        return ranges
    }

    private func split(range: DateInterval) -> [DateInterval]? {
        guard range.duration > 1 else { return nil }

        let midpoint = range.start.addingTimeInterval(range.duration / 2)
        let flooredMidpoint = Date(timeIntervalSinceReferenceDate: floor(midpoint.timeIntervalSinceReferenceDate))
        let splitPoint: Date
        if flooredMidpoint <= range.start {
            splitPoint = range.start.addingTimeInterval(1)
        } else if flooredMidpoint >= range.end {
            splitPoint = range.end.addingTimeInterval(-1)
        } else {
            splitPoint = flooredMidpoint
        }

        guard splitPoint > range.start && splitPoint < range.end else { return nil }
        return [
            DateInterval(start: splitPoint, end: range.end),
            DateInterval(start: range.start, end: splitPoint)
        ]
    }
}
