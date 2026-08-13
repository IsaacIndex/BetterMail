import Foundation
import OSLog

internal protocol DayFetchCoordinating: Sendable {
    func fetchDay(containing date: Date,
                  scope: DayFetchScope,
                  mode: DayFetchMode,
                  requestBatchSize: Int,
                  snippetLineLimit: Int,
                  referenceDate: Date,
                  progressHandler: @Sendable (DayFetchProgress) -> Void) async throws -> DayFetchResult
    func fetchRange(_ range: DateInterval,
                    scope: DayFetchScope,
                    mode: DayFetchMode,
                    requestBatchSize: Int,
                    snippetLineLimit: Int,
                    referenceDate: Date,
                    progressHandler: @Sendable (DayFetchProgress) -> Void) async throws -> [DayFetchResult]
    func cancelCurrentFetch() async
}

internal enum DayFetchCoordinatorError: LocalizedError, Sendable {
    case futureDay
    case invalidDay
    case unstableManifest
    case incompletePayload(expected: Int, actual: Int)

    internal var errorDescription: String? {
        switch self {
        case .futureDay:
            return NSLocalizedString("dayfetch.error.future_day",
                                     comment: "Error when attempting to fetch a future day")
        case .invalidDay:
            return NSLocalizedString("dayfetch.error.invalid_day",
                                     comment: "Error when a calendar day cannot be resolved")
        case .unstableManifest:
            return NSLocalizedString("dayfetch.error.unstable_manifest",
                                     comment: "Error when Mail changes during a day fetch")
        case let .incompletePayload(expected, actual):
            return String.localizedStringWithFormat(
                NSLocalizedString("dayfetch.error.incomplete_payload",
                                  comment: "Error when Mail returns fewer requested message payloads"),
                actual,
                expected
            )
        }
    }
}

internal actor DayFetchCoordinator: DayFetchCoordinating {
    internal static let shared = DayFetchCoordinator()
    nonisolated internal static let maximumRequestBatchSize = 4

    private let client: any MailMessageFetching
    private let store: MessageStore
    private let calendar: Calendar
    private let logger = Log.refresh
    private var operationIsHeld = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationGeneration = 0

    internal init(client: any MailMessageFetching = MailAppleScriptClient(),
                  store: MessageStore = .shared,
                  calendar: Calendar = .autoupdatingCurrent) {
        self.client = client
        self.store = store
        self.calendar = calendar
    }

    internal func fetchDay(containing date: Date,
                           scope: DayFetchScope,
                           mode: DayFetchMode,
                           requestBatchSize: Int = DayFetchCoordinator.maximumRequestBatchSize,
                           snippetLineLimit: Int,
                           referenceDate: Date = Date(),
                           progressHandler: @Sendable (DayFetchProgress) -> Void = { _ in }) async throws -> DayFetchResult {
        await acquireOperation()
        let generation = cancellationGeneration
        defer { releaseOperation() }
        return try await performFetchDay(containing: date,
                                         scope: scope,
                                         mode: mode,
                                         requestBatchSize: requestBatchSize,
                                         snippetLineLimit: snippetLineLimit,
                                         referenceDate: referenceDate,
                                         cancellationGeneration: generation,
                                         progressHandler: progressHandler)
    }

    internal func fetchRange(_ range: DateInterval,
                             scope: DayFetchScope,
                             mode: DayFetchMode,
                             requestBatchSize: Int = DayFetchCoordinator.maximumRequestBatchSize,
                             snippetLineLimit: Int,
                             referenceDate: Date = Date(),
                             progressHandler: @Sendable (DayFetchProgress) -> Void = { _ in }) async throws -> [DayFetchResult] {
        await acquireOperation()
        let generation = cancellationGeneration
        defer { releaseOperation() }
        guard range.start < range.end else { return [] }

        var results: [DayFetchResult] = []
        var day = calendar.startOfDay(for: range.start)
        while day < range.end && day <= referenceDate {
            try checkCancellation(generation: generation)
            let completedBeforeDay = results.reduce(0) { $0 + $1.fetchedCount }
            let result = try await performFetchDay(containing: day,
                                                   scope: scope,
                                                   mode: mode,
                                                   requestBatchSize: requestBatchSize,
                                                   snippetLineLimit: snippetLineLimit,
                                                   referenceDate: referenceDate,
                                                   cancellationGeneration: generation,
                                                   progressHandler: { progress in
                progressHandler(DayFetchProgress(dayInterval: progress.dayInterval,
                                                 phase: progress.phase,
                                                 completed: completedBeforeDay + progress.completed,
                                                 total: completedBeforeDay + progress.total))
            })
            results.append(result)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return results
    }

    internal func cancelCurrentFetch() async {
        cancellationGeneration &+= 1
    }

    private func performFetchDay(containing date: Date,
                                 scope: DayFetchScope,
                                 mode: DayFetchMode,
                                 requestBatchSize: Int,
                                 snippetLineLimit: Int,
                                 referenceDate: Date,
                                 cancellationGeneration generation: Int,
                                 progressHandler: @Sendable (DayFetchProgress) -> Void) async throws -> DayFetchResult {
        try checkCancellation(generation: generation)
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else {
            throw DayFetchCoordinatorError.invalidDay
        }
        guard dayInterval.start <= referenceDate else {
            throw DayFetchCoordinatorError.futureDay
        }

        let coveredThrough: Date
        if dayInterval.end <= referenceDate {
            coveredThrough = dayInterval.end
        } else {
            coveredThrough = calendar.dateInterval(of: .second, for: referenceDate)?.start ?? referenceDate
        }
        let fetchInterval = DateInterval(start: dayInterval.start, end: coveredThrough)
        let batchSize = min(Self.maximumRequestBatchSize, max(1, requestBatchSize))
        let attemptDate = Date()
        var concreteScopes = [scope]

        do {
            if scope.account == nil {
                let resolvedScopes = try await client.resolveDayFetchScopes(mailbox: scope.mailbox,
                                                                            account: scope.account)
                if !resolvedScopes.isEmpty {
                    concreteScopes = resolvedScopes
                }
            }
            for concreteScope in concreteScopes {
                try await store.beginDayFetchCoverage(scope: concreteScope,
                                                      dayInterval: dayInterval,
                                                      attemptedAt: attemptDate)
            }

            logger.info("Day fetch started. scope=\(scope.key, privacy: .private) concreteScopes=\(concreteScopes.count, privacy: .public) rangeStart=\(fetchInterval.start, privacy: .private) rangeEnd=\(fetchInterval.end, privacy: .private) mode=\(String(describing: mode), privacy: .public) requestBatchSize=\(batchSize, privacy: .public)")
            let result = try await fetchStableManifest(dayInterval: dayInterval,
                                                       fetchInterval: fetchInterval,
                                                       coveredThrough: coveredThrough,
                                                       scope: scope,
                                                       concreteScopes: concreteScopes,
                                                       mode: mode,
                                                       requestBatchSize: batchSize,
                                                       snippetLineLimit: snippetLineLimit,
                                                       cancellationGeneration: generation,
                                                       progressHandler: progressHandler)
            logger.info("Day fetch completed. scope=\(scope.key, privacy: .private) expected=\(result.expectedCount, privacy: .public) downloaded=\(result.downloadedCount, privacy: .public) absent=\(result.absentCount, privacy: .public) state=\(result.coverage.state.rawValue, privacy: .public)")
            return result
        } catch {
            let message = Self.sanitizedErrorMessage(error)
            for concreteScope in concreteScopes {
                try? await store.failDayFetchCoverage(scope: concreteScope,
                                                      dayInterval: dayInterval,
                                                      attemptedAt: Date(),
                                                      errorMessage: message)
            }
            logger.error("Day fetch failed. scope=\(scope.key, privacy: .private) error=\(message, privacy: .private)")
            throw error
        }
    }

    private func fetchStableManifest(dayInterval: DateInterval,
                                     fetchInterval: DateInterval,
                                     coveredThrough: Date,
                                     scope: DayFetchScope,
                                     concreteScopes: [DayFetchScope],
                                     mode: DayFetchMode,
                                     requestBatchSize: Int,
                                     snippetLineLimit: Int,
                                     cancellationGeneration generation: Int,
                                     progressHandler: @Sendable (DayFetchProgress) -> Void) async throws -> DayFetchResult {
        for attempt in 1...2 {
            try checkCancellation(generation: generation)
            progressHandler(DayFetchProgress(dayInterval: dayInterval,
                                             phase: .manifest,
                                             completed: 0,
                                             total: 0))
            let initialManifest = Self.deduplicated(
                try await client.fetchMessageManifest(in: fetchInterval,
                                                      mailbox: scope.mailbox,
                                                      account: scope.account)
            )
            let initialIdentitySet = Set(initialManifest.map(\.stableIdentity))
            let initialSnapshot = Set(initialManifest)
            let cachedMessages = try await store.fetchMessagesForReconciliation(in: fetchInterval,
                                                                                 scope: scope)
            let cachedByStableIdentity = Dictionary(cachedMessages.map { (MessageReference(message: $0).stableIdentity, $0) },
                                                    uniquingKeysWith: { current, _ in current })
            let cachedByMessageIdentity = Dictionary(cachedMessages.compactMap { message -> (String, EmailMessage)? in
                guard message.internalMailID == nil else { return nil }
                return (MessageReference(message: message).normalizedMessageIdentity, message)
            }, uniquingKeysWith: { current, _ in current })
            let referencesToFetch = initialManifest.filter { reference in
                if mode == .full {
                    return true
                }
                let cached = cachedByStableIdentity[reference.stableIdentity]
                    ?? cachedByMessageIdentity[reference.normalizedMessageIdentity]
                return Self.needsPayloadRefresh(reference: reference, cached: cached)
            }

            var returnedIdentitySet = Set<String>()
            var stagedMessages: [EmailMessage] = []
            var completedPayloads = 0
            for batch in referencesToFetch.chunked(into: requestBatchSize) {
                try checkCancellation(generation: generation)
                let messages = try await client.fetchMessages(references: batch,
                                                              profile: mode.profile,
                                                              snippetLineLimit: snippetLineLimit)
                try checkCancellation(generation: generation)
                stagedMessages.append(contentsOf: messages)
                completedPayloads += messages.count
                returnedIdentitySet.formUnion(messages.map { MessageReference(message: $0).stableIdentity })
                progressHandler(DayFetchProgress(dayInterval: dayInterval,
                                                 phase: .payloads,
                                                 completed: completedPayloads,
                                                 total: referencesToFetch.count))
            }

            progressHandler(DayFetchProgress(dayInterval: dayInterval,
                                             phase: .verifying,
                                             completed: completedPayloads,
                                             total: referencesToFetch.count))
            let verifiedManifest = Self.deduplicated(
                try await client.fetchMessageManifest(in: fetchInterval,
                                                      mailbox: scope.mailbox,
                                                      account: scope.account)
            )
            try checkCancellation(generation: generation)
            let verifiedIdentitySet = Set(verifiedManifest.map(\.stableIdentity))
            let verifiedSnapshot = Set(verifiedManifest)
            guard initialIdentitySet == verifiedIdentitySet,
                  initialSnapshot == verifiedSnapshot else {
                logger.info("Day manifest changed during fetch. scope=\(scope.key, privacy: .private) attempt=\(attempt, privacy: .public) initial=\(initialIdentitySet.count, privacy: .public) verified=\(verifiedIdentitySet.count, privacy: .public)")
                if attempt == 1 {
                    continue
                }
                throw DayFetchCoordinatorError.unstableManifest
            }

            let requiredIdentitySet = Set(referencesToFetch.map(\.stableIdentity))
            let unresolved = requiredIdentitySet.subtracting(returnedIdentitySet)
            if !unresolved.isEmpty {
                throw DayFetchCoordinatorError.incompletePayload(expected: requiredIdentitySet.count,
                                                                 actual: requiredIdentitySet.count - unresolved.count)
            }

            try checkCancellation(generation: generation)
            try await store.upsert(messages: stagedMessages)
            progressHandler(DayFetchProgress(dayInterval: dayInterval,
                                             phase: .reconciling,
                                             completed: verifiedManifest.count,
                                             total: verifiedManifest.count))
            let state: DayCoverageState = coveredThrough >= dayInterval.end ? .verified : .partial
            var concreteCoverages: [DayFetchCoverage] = []
            var absentCount = 0
            for concreteScope in concreteScopes {
                let concreteManifest = verifiedManifest.filter {
                    Self.reference($0, belongsTo: concreteScope)
                }
                let concreteAbsentCount = try await store.reconcileSourcePresence(
                    in: fetchInterval,
                    scope: concreteScope,
                    manifest: concreteManifest,
                    checkedAt: Date()
                )
                absentCount += concreteAbsentCount
                concreteCoverages.append(
                    try await store.completeDayFetchCoverage(scope: concreteScope,
                                                             dayInterval: dayInterval,
                                                             coveredThrough: coveredThrough,
                                                             expectedCount: concreteManifest.count,
                                                             fetchedCount: concreteManifest.count,
                                                             absentCount: concreteAbsentCount,
                                                             state: state,
                                                             completedAt: Date())
                )
            }
            let coverage = Self.aggregateCoverage(concreteCoverages,
                                                  requestedScope: scope,
                                                  dayInterval: dayInterval)
            return DayFetchResult(dayInterval: dayInterval,
                                  coveredThrough: coveredThrough,
                                  expectedCount: verifiedManifest.count,
                                  fetchedCount: verifiedManifest.count,
                                  downloadedCount: stagedMessages.count,
                                  absentCount: absentCount,
                                  coverage: coverage)
        }

        throw DayFetchCoordinatorError.unstableManifest
    }

    private func acquireOperation() async {
        if !operationIsHeld {
            operationIsHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationIsHeld = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    private func checkCancellation(generation: Int) throws {
        try Task.checkCancellation()
        if generation != cancellationGeneration {
            throw CancellationError()
        }
    }

    private static func deduplicated(_ references: [MessageReference]) -> [MessageReference] {
        var seen = Set<String>()
        return references.filter { seen.insert($0.stableIdentity).inserted }
    }

    private static func needsPayloadRefresh(reference: MessageReference,
                                            cached: EmailMessage?) -> Bool {
        guard let cached else { return true }
        return cached.internalMailID != reference.internalMailID
            || cached.mailboxID.caseInsensitiveCompare(reference.mailbox) != .orderedSame
            || cached.accountName.caseInsensitiveCompare(reference.account) != .orderedSame
            || cached.subject != reference.subject
            || abs(cached.date.timeIntervalSince(reference.date)) >= 1
            || cached.isUnread != reference.isUnread
    }

    private static func reference(_ reference: MessageReference,
                                  belongsTo scope: DayFetchScope) -> Bool {
        let accountMatches = scope.account.map {
            reference.account.caseInsensitiveCompare($0) == .orderedSame
        } ?? true
        guard accountMatches else { return false }
        if scope.includesAllInboxAliases {
            return ["inbox", "all inboxes"].contains {
                reference.mailbox.caseInsensitiveCompare($0) == .orderedSame
            }
        }
        return reference.mailbox.caseInsensitiveCompare(scope.mailbox) == .orderedSame
    }

    private static func aggregateCoverage(_ coverages: [DayFetchCoverage],
                                          requestedScope: DayFetchScope,
                                          dayInterval: DateInterval) -> DayFetchCoverage {
        guard !coverages.isEmpty else {
            let now = Date()
            return DayFetchCoverage(id: "\(requestedScope.key)|\(Int64(dayInterval.start.timeIntervalSinceReferenceDate))",
                                    scopeKey: requestedScope.key,
                                    mailbox: requestedScope.mailbox,
                                    account: requestedScope.account,
                                    dayStart: dayInterval.start,
                                    dayEnd: dayInterval.end,
                                    firstTouchedAt: now,
                                    lastAttemptAt: now,
                                    lastSuccessAt: nil,
                                    coveredThrough: nil,
                                    expectedCount: 0,
                                    fetchedCount: 0,
                                    absentCount: 0,
                                    state: .unknown,
                                    errorMessage: nil)
        }
        if coverages.count == 1,
           coverages[0].scopeKey == requestedScope.key {
            return coverages[0]
        }

        let state = aggregateState(coverages.map(\.state), hasMissingScope: false)
        let allSucceeded = coverages.allSatisfy { $0.lastSuccessAt != nil }
        return DayFetchCoverage(
            id: "\(requestedScope.key)|\(Int64(dayInterval.start.timeIntervalSinceReferenceDate))",
            scopeKey: requestedScope.key,
            mailbox: requestedScope.mailbox,
            account: requestedScope.account,
            dayStart: dayInterval.start,
            dayEnd: dayInterval.end,
            firstTouchedAt: coverages.map(\.firstTouchedAt).min() ?? Date(),
            lastAttemptAt: coverages.map(\.lastAttemptAt).max() ?? Date(),
            lastSuccessAt: allSucceeded ? coverages.compactMap(\.lastSuccessAt).min() : nil,
            coveredThrough: allSucceeded ? coverages.compactMap(\.coveredThrough).min() : nil,
            expectedCount: coverages.reduce(0) { $0 + $1.expectedCount },
            fetchedCount: coverages.reduce(0) { $0 + $1.fetchedCount },
            absentCount: coverages.reduce(0) { $0 + $1.absentCount },
            state: state,
            errorMessage: coverages
                .filter { $0.state == .failed }
                .max(by: { $0.lastAttemptAt < $1.lastAttemptAt })?
                .errorMessage
        )
    }

    nonisolated internal static func aggregateState(_ states: [DayCoverageState],
                                                    hasMissingScope: Bool) -> DayCoverageState {
        if states.contains(.failed) { return .failed }
        if states.contains(.fetching) { return .fetching }
        if hasMissingScope || states.isEmpty || states.contains(.unknown) { return .unknown }
        if states.contains(.partial) { return .partial }
        return .verified
    }

    private static func sanitizedErrorMessage(_ error: Error) -> String {
        let collapsed = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(500))
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
