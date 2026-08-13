import Foundation

internal protocol MailMessageFetching: Sendable {
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
    func fetchMessageManifest(in range: DateInterval,
                              mailbox: String,
                              account: String?) async throws -> [MessageReference]
    func fetchMessages(references: [MessageReference],
                       profile: MailFetchProfile,
                       snippetLineLimit: Int) async throws -> [EmailMessage]
    func resolveDayFetchScopes(mailbox: String,
                               account: String?) async throws -> [DayFetchScope]
}

internal enum MailMessageFetchingError: LocalizedError {
    case dayFetchUnsupported

    internal var errorDescription: String? {
        NSLocalizedString("dayfetch.error.unsupported_client",
                          comment: "Error when a mail client does not support exhaustive day fetching")
    }
}

internal extension MailMessageFetching {
    func fetchMessageManifest(in range: DateInterval,
                              mailbox: String,
                              account: String?) async throws -> [MessageReference] {
        throw MailMessageFetchingError.dayFetchUnsupported
    }

    func fetchMessages(references: [MessageReference],
                       profile: MailFetchProfile,
                       snippetLineLimit: Int) async throws -> [EmailMessage] {
        throw MailMessageFetchingError.dayFetchUnsupported
    }

    func resolveDayFetchScopes(mailbox: String,
                               account: String?) async throws -> [DayFetchScope] {
        let trimmedAccount = account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [DayFetchScope(mailbox: mailbox,
                              account: trimmedAccount.isEmpty ? nil : trimmedAccount,
                              displayName: trimmedAccount.isEmpty
                                  ? mailbox
                                  : "\(trimmedAccount) / \(mailbox)",
                              includesAllInboxAliases: trimmedAccount.isEmpty
                                  && mailbox.caseInsensitiveCompare("inbox") == .orderedSame)]
    }
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

internal actor BatchBackfillService: BatchBackfillServicing {
    nonisolated internal static let maximumFetchCount = 4

    private let client: any MailMessageFetching
    private let calendar: Calendar
    private let coordinator: any DayFetchCoordinating

    internal init(client: any MailMessageFetching = MailAppleScriptClient(),
                  store: MessageStore = .shared,
                  calendar: Calendar = .autoupdatingCurrent,
                  coordinator: (any DayFetchCoordinating)? = nil) {
        self.client = client
        self.calendar = calendar
        self.coordinator = coordinator ?? DayFetchCoordinator(client: client,
                                                               store: store,
                                                               calendar: calendar)
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
        guard clampedStart < clampedEnd else { return 0 }
        let clampedRange = DateInterval(start: clampedStart, end: clampedEnd)
        var total = 0
        var dayStart = calendar.startOfDay(for: clampedRange.start)
        while dayStart < clampedRange.end {
            try Task.checkCancellation()
            guard let dayInterval = calendar.dateInterval(of: .day, for: dayStart) else {
                break
            }
            let interval = DateInterval(start: max(dayInterval.start, clampedRange.start),
                                        end: min(dayInterval.end, clampedRange.end))
            if interval.start < interval.end {
                total += try await client.fetchMessageManifest(in: interval,
                                                               mailbox: mailbox,
                                                               account: account).count
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
                  nextDay > dayStart else {
                break
            }
            dayStart = nextDay
        }
        return total
    }

    internal func runBackfill(range: DateInterval,
                              mailbox: String = "inbox",
                              account: String? = nil,
                              preferredBatchSize: Int = DayFetchCoordinator.maximumRequestBatchSize,
                              totalExpected: Int,
                              snippetLineLimit: Int,
                              progressHandler: @Sendable (BatchBackfillProgress) -> Void) async throws -> BatchBackfillResult {
        try Task.checkCancellation()
        let now = Date()
        if range.start > now || range.start >= range.end {
            progressHandler(BatchBackfillProgress(total: totalExpected,
                                                  completed: 0,
                                                  currentBatchSize: min(Self.maximumFetchCount,
                                                                        max(1, preferredBatchSize)),
                                                  currentRange: nil,
                                                  rangeMessageCount: nil,
                                                  state: .finished,
                                                  errorMessage: nil))
            return BatchBackfillResult(total: totalExpected, fetched: 0)
        }
        let clampedStart = min(range.start, now)
        let clampedEnd = min(range.end, now)
        guard clampedStart < clampedEnd else {
            return BatchBackfillResult(total: totalExpected, fetched: 0)
        }
        let clampedRange = DateInterval(start: clampedStart, end: clampedEnd)
        let requestBatchSize = min(Self.maximumFetchCount, max(1, preferredBatchSize))
        let scope = DayFetchScope(mailbox: mailbox,
                                  account: account,
                                  displayName: account.map { "\($0) / \(mailbox)" }
                                      ?? String.localizedStringWithFormat(
                                          NSLocalizedString("dayfetch.scope.all_accounts_format",
                                                            comment: "All-account day fetch scope label"),
                                          mailbox
                                      ),
                                  includesAllInboxAliases: account == nil
                                      && mailbox.caseInsensitiveCompare("inbox") == .orderedSame)

        let results: [DayFetchResult]
        do {
            results = try await coordinator.fetchRange(clampedRange,
                                                       scope: scope,
                                                       mode: .full,
                                                       requestBatchSize: requestBatchSize,
                                                       snippetLineLimit: snippetLineLimit,
                                                       referenceDate: now) { progress in
                progressHandler(BatchBackfillProgress(
                    total: max(totalExpected, progress.total),
                    completed: progress.completed,
                    currentBatchSize: requestBatchSize,
                    currentRange: progress.dayInterval,
                    rangeMessageCount: progress.total,
                    state: .running,
                    errorMessage: nil
                ))
            }
        } catch {
            progressHandler(BatchBackfillProgress(total: totalExpected,
                                                  completed: 0,
                                                  currentBatchSize: requestBatchSize,
                                                  currentRange: clampedRange,
                                                  rangeMessageCount: nil,
                                                  state: .finished,
                                                  errorMessage: error.localizedDescription))
            throw error
        }
        let completed = results.reduce(0) { $0 + $1.fetchedCount }

        progressHandler(BatchBackfillProgress(total: totalExpected,
                                              completed: completed,
                                              currentBatchSize: requestBatchSize,
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

}
