import CoreData
import XCTest
@testable import BetterMail

@MainActor
final class BatchBackfillServiceTests: XCTestCase {
    func test_DayFetch_MoreThanFourMessages_UsesFourFourRemainderWithoutTotalCap() async throws {
        let calendar = Self.utcCalendar
        let store = makeStore(name: #function)
        let day = Self.date(year: 2026, month: 2, day: 1)
        let timestamp = Self.date(year: 2026, month: 2, day: 1, hour: 12)
        let references = (1...10).map { Self.reference(id: "message-\($0)", date: timestamp) }
        let client = ExhaustiveMailClient(references: references)
        let coordinator = DayFetchCoordinator(client: client, store: store, calendar: calendar)

        let result = try await coordinator.fetchDay(containing: day,
                                                    scope: Self.inboxScope,
                                                    mode: .full,
                                                    requestBatchSize: 4,
                                                    snippetLineLimit: 8,
                                                    referenceDate: Self.date(year: 2026, month: 2, day: 2),
                                                    progressHandler: { _ in })

        XCTAssertEqual(result.expectedCount, 10)
        XCTAssertEqual(result.downloadedCount, 10)
        let batchSizes = await client.payloadBatchSizes()
        let storedMessageIDs = Set(try await store.fetchMessages().map(\.messageID))
        XCTAssertEqual(batchSizes, [4, 4, 2])
        XCTAssertEqual(storedMessageIDs, Set(references.map(\.messageID)))
        XCTAssertEqual(result.coverage.state, .verified)
        XCTAssertEqual(result.coverage.coveredThrough, result.dayInterval.end)
    }

    func test_RefreshProfile_DownloadsOnlyNewOrChangedPayloads_ButReconcilesWholeManifest() async throws {
        let calendar = Self.utcCalendar
        let store = makeStore(name: #function)
        let day = Self.date(year: 2026, month: 2, day: 3)
        let timestamp = Self.date(year: 2026, month: 2, day: 3, hour: 9)
        let references = (1...10).map { Self.reference(id: "refresh-\($0)", date: timestamp) }
        try await store.upsert(messages: references.prefix(8).map(Self.message(from:)))
        let client = ExhaustiveMailClient(references: references)
        let coordinator = DayFetchCoordinator(client: client, store: store, calendar: calendar)

        let result = try await coordinator.fetchDay(containing: day,
                                                    scope: Self.inboxScope,
                                                    mode: .refresh,
                                                    requestBatchSize: 4,
                                                    snippetLineLimit: 8,
                                                    referenceDate: Self.date(year: 2026, month: 2, day: 4),
                                                    progressHandler: { _ in })

        XCTAssertEqual(result.expectedCount, 10)
        XCTAssertEqual(result.downloadedCount, 2)
        let batchSizes = await client.payloadBatchSizes()
        let storedCount = try await store.fetchMessages().count
        let profiles = await client.payloadProfiles()
        XCTAssertEqual(batchSizes, [2])
        XCTAssertEqual(storedCount, 10)
        XCTAssertEqual(profiles, [.refresh])
    }

    func test_RefreshNow_LeavesLegacyCheckpointUntouchedAndExhaustsToday() async throws {
        let store = makeStore(name: #function)
        let calendar = Calendar.current
        let now = Date()
        let timestamp = calendar.date(byAdding: .minute, value: -5, to: now)!
        let references = (1...9).map { Self.reference(id: "today-\($0)", date: timestamp) }
        let client = ExhaustiveMailCanvasClient(references: references)
        let coordinator = DayFetchCoordinator(client: client, store: store, calendar: calendar)
        let settings = AutoRefreshSettings()
        settings.isEnabled = false
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: InspectorViewSettings(),
                                              store: store,
                                              client: client,
                                              dayFetchCoordinator: coordinator)
        let legacyCheckpoint = now.addingTimeInterval(-86_400)
        store.lastSyncDate = legacyCheckpoint
        viewModel.fetchLimit = 99

        viewModel.refreshNow()
        try await waitForRefreshCompletion(viewModel)

        let batchSizes = await client.payloadBatchSizes()
        let storedCount = try await store.fetchMessages().count
        XCTAssertEqual(batchSizes, [4, 4, 1])
        XCTAssertEqual(storedCount, 9)
        XCTAssertEqual(store.lastSyncDate, legacyCheckpoint)
        XCTAssertFalse(viewModel.status.localizedCaseInsensitiveContains("failed"))
    }

    func test_BatchBackfill_RecordsSuccessfulZeroMessageDay() async throws {
        let calendar = Self.utcCalendar
        let store = makeStore(name: #function)
        let start = Self.date(year: 2026, month: 2, day: 5)
        let end = Self.date(year: 2026, month: 2, day: 6)
        let client = ExhaustiveMailClient(references: [])
        let coordinator = DayFetchCoordinator(client: client, store: store, calendar: calendar)
        let service = BatchBackfillService(client: client,
                                           store: store,
                                           calendar: calendar,
                                           coordinator: coordinator)

        let result = try await service.runBackfill(range: DateInterval(start: start, end: end),
                                                   mailbox: "inbox",
                                                   account: nil,
                                                   preferredBatchSize: 100,
                                                   totalExpected: 0,
                                                   snippetLineLimit: 8,
                                                   progressHandler: { _ in })
        let coverages = try await store.fetchDayFetchCoverages(scope: Self.inboxScope)
        let coverage = try XCTUnwrap(coverages.first)
        let batchSizes = await client.payloadBatchSizes()

        XCTAssertEqual(result.fetched, 0)
        XCTAssertEqual(coverage.expectedCount, 0)
        XCTAssertEqual(coverage.state, .verified)
        XCTAssertEqual(batchSizes, [])
    }

    func test_BatchBackfillCount_EnumeratesTheRangeOneCalendarDayAtATime() async throws {
        let start = Self.date(year: 2026, month: 2, day: 5)
        let end = Self.date(year: 2026, month: 2, day: 7)
        let references = [
            Self.reference(id: "count-day-one", date: Self.date(year: 2026, month: 2, day: 5, hour: 8)),
            Self.reference(id: "count-day-two", date: Self.date(year: 2026, month: 2, day: 6, hour: 8))
        ]
        let client = ExhaustiveMailClient(references: references)
        let service = BatchBackfillService(client: client,
                                           store: makeStore(name: #function),
                                           calendar: Self.utcCalendar)

        let total = try await service.countMessages(in: DateInterval(start: start, end: end),
                                                     mailbox: "inbox",
                                                     account: nil)

        let ranges = await client.manifestRanges()
        XCTAssertEqual(total, 2)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertTrue(ranges.allSatisfy { abs($0.duration - 86_400) < 0.1 })
    }

    func test_DayFetch_DSTDays_UsesCalendarBoundariesInsteadOfFixedSeconds() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let store = makeStore(name: #function)
        let client = ExhaustiveMailClient(references: [])
        let coordinator = DayFetchCoordinator(client: client, store: store, calendar: calendar)
        let springDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let fallDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))

        _ = try await coordinator.fetchDay(containing: springDay,
                                           scope: Self.inboxScope,
                                           mode: .full,
                                           requestBatchSize: 4,
                                           snippetLineLimit: 8,
                                           referenceDate: try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: springDay)),
                                           progressHandler: { _ in })
        _ = try await coordinator.fetchDay(containing: fallDay,
                                           scope: Self.inboxScope,
                                           mode: .full,
                                           requestBatchSize: 4,
                                           snippetLineLimit: 8,
                                           referenceDate: try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: fallDay)),
                                           progressHandler: { _ in })

        let requested = await client.manifestRanges()
        XCTAssertTrue(requested.contains { abs($0.duration - (23 * 3_600)) < 0.1 })
        XCTAssertTrue(requested.contains { abs($0.duration - (25 * 3_600)) < 0.1 })
    }

    func test_AuthoritativeManifest_HidesOnlyAbsentScopeMessages_AndRestoresReappearingMessage() async throws {
        let calendar = Self.utcCalendar
        let store = makeStore(name: #function)
        let day = Self.date(year: 2026, month: 2, day: 7)
        let timestamp = Self.date(year: 2026, month: 2, day: 7, hour: 10)
        let present = Self.reference(id: "present", date: timestamp)
        let absent = Self.reference(id: "absent", date: timestamp)
        let otherScope = MessageReference(internalMailID: "other-internal",
                                          messageID: "other",
                                          mailbox: "Archive",
                                          account: "Work",
                                          subject: "other",
                                          date: timestamp,
                                          isUnread: false)
        try await store.upsert(messages: [present, absent, otherScope].map(Self.message(from:)))
        let client = ExhaustiveMailClient(references: [present])
        let coordinator = DayFetchCoordinator(client: client, store: store, calendar: calendar)

        let first = try await coordinator.fetchDay(containing: day,
                                                   scope: Self.inboxScope,
                                                   mode: .full,
                                                   requestBatchSize: 4,
                                                   snippetLineLimit: 8,
                                                   referenceDate: Self.date(year: 2026, month: 2, day: 8),
                                                   progressHandler: { _ in })

        XCTAssertEqual(first.absentCount, 1)
        let firstVisibleIDs = Set(try await store.fetchMessages().map(\.messageID))
        let reconciliationIDs = Set(try await store.fetchMessagesForReconciliation(
            in: first.dayInterval,
            scope: Self.inboxScope
        ).map(\.messageID))
        XCTAssertEqual(firstVisibleIDs, Set(["present", "other"]))
        XCTAssertEqual(reconciliationIDs, Set(["present", "absent"]))

        await client.setReferences([present, absent])
        let second = try await coordinator.fetchDay(containing: day,
                                                    scope: Self.inboxScope,
                                                    mode: .full,
                                                    requestBatchSize: 4,
                                                    snippetLineLimit: 8,
                                                    referenceDate: Self.date(year: 2026, month: 2, day: 8),
                                                    progressHandler: { _ in })

        XCTAssertEqual(second.absentCount, 0)
        let restoredIDs = Set(try await store.fetchMessages().map(\.messageID))
        XCTAssertEqual(restoredIDs, Set(["present", "absent", "other"]))
    }

    func test_UnstableManifest_DoesNotReconcileAndMarksCoverageFailed() async throws {
        let calendar = Self.utcCalendar
        let store = makeStore(name: #function)
        let day = Self.date(year: 2026, month: 2, day: 9)
        let timestamp = Self.date(year: 2026, month: 2, day: 9, hour: 8)
        let cached = Self.reference(id: "cached", date: timestamp)
        let first = Self.reference(id: "first", date: timestamp)
        let second = Self.reference(id: "second", date: timestamp)
        try await store.upsert(messages: [Self.message(from: cached)])
        let client = ExhaustiveMailClient(references: [],
                                          manifestSequence: [[first], [second], [first], [second]])
        let coordinator = DayFetchCoordinator(client: client, store: store, calendar: calendar)

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.fetchDay(containing: day,
                                               scope: Self.inboxScope,
                                               mode: .full,
                                               requestBatchSize: 4,
                                               snippetLineLimit: 8,
                                               referenceDate: Self.date(year: 2026, month: 2, day: 10),
                                               progressHandler: { _ in })
        }

        let visibleIDs = try await store.fetchMessages().map(\.messageID)
        let coverages = try await store.fetchDayFetchCoverages(scope: Self.inboxScope)
        let coverage = try XCTUnwrap(coverages.first)
        XCTAssertEqual(visibleIDs, ["cached"])
        XCTAssertEqual(coverage.state, .failed)
    }

    func test_PartialPayloadFailure_DoesNotChangeExistingAbsenceFlags() async throws {
        let calendar = Self.utcCalendar
        let store = makeStore(name: #function)
        let day = Self.date(year: 2026, month: 2, day: 11)
        let timestamp = Self.date(year: 2026, month: 2, day: 11, hour: 8)
        let cached = Self.reference(id: "cached-partial", date: timestamp)
        let references = (1...5).map { Self.reference(id: "partial-\($0)", date: timestamp) }
        try await store.upsert(messages: [Self.message(from: cached)])
        let client = ExhaustiveMailClient(references: references, droppedPayloadIDs: ["partial-5"])
        let coordinator = DayFetchCoordinator(client: client, store: store, calendar: calendar)

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.fetchDay(containing: day,
                                               scope: Self.inboxScope,
                                               mode: .full,
                                               requestBatchSize: 4,
                                               snippetLineLimit: 8,
                                               referenceDate: Self.date(year: 2026, month: 2, day: 12),
                                               progressHandler: { _ in })
        }

        let cachedRemainsVisible = try await store.fetchMessages().contains { $0.messageID == cached.messageID }
        let state = try await store.fetchDayFetchCoverages(scope: Self.inboxScope).first?.state
        XCTAssertTrue(cachedRemainsVisible)
        XCTAssertEqual(state, .failed)
    }

    func test_CancelAndConcurrentRequests_StopBetweenBatchesAndRemainSerialized() async throws {
        let calendar = Self.utcCalendar
        let store = makeStore(name: #function)
        let firstDay = Self.date(year: 2026, month: 2, day: 13)
        let secondDay = Self.date(year: 2026, month: 2, day: 14)
        let references = [
            Self.reference(id: "serial-1", date: Self.date(year: 2026, month: 2, day: 13, hour: 2)),
            Self.reference(id: "serial-2", date: Self.date(year: 2026, month: 2, day: 14, hour: 2))
        ]
        let client = ExhaustiveMailClient(references: references, operationDelayNanoseconds: 80_000_000)
        let coordinator = DayFetchCoordinator(client: client, store: store, calendar: calendar)

        async let firstResult = coordinator.fetchDay(containing: firstDay,
                                                     scope: Self.inboxScope,
                                                     mode: .full,
                                                     requestBatchSize: 1,
                                                     snippetLineLimit: 8,
                                                     referenceDate: Self.date(year: 2026, month: 2, day: 15),
                                                     progressHandler: { _ in })
        async let secondResult = coordinator.fetchDay(containing: secondDay,
                                                      scope: Self.inboxScope,
                                                      mode: .full,
                                                      requestBatchSize: 1,
                                                      snippetLineLimit: 8,
                                                      referenceDate: Self.date(year: 2026, month: 2, day: 15),
                                                      progressHandler: { _ in })
        _ = try await (firstResult, secondResult)
        let maximumConcurrentOperations = await client.maximumConcurrentOperations()
        XCTAssertEqual(maximumConcurrentOperations, 1)

        let cancelClient = ExhaustiveMailClient(references: references,
                                                operationDelayNanoseconds: 80_000_000)
        let cancelCoordinator = DayFetchCoordinator(client: cancelClient, store: makeStore(name: "cancel"), calendar: calendar)
        let task = Task {
            try await cancelCoordinator.fetchDay(containing: firstDay,
                                                 scope: Self.inboxScope,
                                                 mode: .full,
                                                 requestBatchSize: 1,
                                                 snippetLineLimit: 8,
                                                 referenceDate: Self.date(year: 2026, month: 2, day: 15),
                                                 progressHandler: { _ in })
        }
        try await Task.sleep(nanoseconds: 25_000_000)
        await cancelCoordinator.cancelCurrentFetch()
        await XCTAssertThrowsErrorAsync { _ = try await task.value }
    }

    func test_DayFetch_UsesHalfOpenMidnightBoundary() async throws {
        let dayStart = Self.date(year: 2026, month: 2, day: 15)
        let nextDayStart = Self.date(year: 2026, month: 2, day: 16)
        let references = [
            Self.reference(id: "at-start", date: dayStart),
            Self.reference(id: "before-end", date: nextDayStart.addingTimeInterval(-0.5)),
            Self.reference(id: "at-end", date: nextDayStart)
        ]
        let store = makeStore(name: #function)
        let coordinator = DayFetchCoordinator(client: ExhaustiveMailClient(references: references),
                                              store: store,
                                              calendar: Self.utcCalendar)

        let result = try await coordinator.fetchDay(containing: dayStart,
                                                    scope: Self.inboxScope,
                                                    mode: .full,
                                                    requestBatchSize: 4,
                                                    snippetLineLimit: 8,
                                                    referenceDate: nextDayStart,
                                                    progressHandler: { _ in })

        XCTAssertEqual(result.expectedCount, 2)
        let storedMessageIDs = Set(try await store.fetchMessages().map(\.messageID))
        XCTAssertEqual(storedMessageIDs, Set(["at-start", "before-end"]))
    }

    func test_OpenDay_IsPartialAndFutureDayIsRejected() async throws {
        let dayStart = Self.date(year: 2026, month: 2, day: 22)
        let noon = Self.date(year: 2026, month: 2, day: 22, hour: 12)
        let references = [
            Self.reference(id: "morning", date: Self.date(year: 2026, month: 2, day: 22, hour: 8)),
            Self.reference(id: "afternoon", date: Self.date(year: 2026, month: 2, day: 22, hour: 16))
        ]
        let store = makeStore(name: #function)
        let coordinator = DayFetchCoordinator(client: ExhaustiveMailClient(references: references),
                                              store: store,
                                              calendar: Self.utcCalendar)

        let result = try await coordinator.fetchDay(containing: dayStart,
                                                    scope: Self.inboxScope,
                                                    mode: .full,
                                                    requestBatchSize: 4,
                                                    snippetLineLimit: 8,
                                                    referenceDate: noon,
                                                    progressHandler: { _ in })
        XCTAssertEqual(result.coverage.state, .partial)
        XCTAssertEqual(result.expectedCount, 1)
        XCTAssertEqual(result.coveredThrough, noon)

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.fetchDay(containing: Self.date(year: 2026, month: 2, day: 23),
                                               scope: Self.inboxScope,
                                               mode: .full,
                                               requestBatchSize: 4,
                                               snippetLineLimit: 8,
                                               referenceDate: noon,
                                               progressHandler: { _ in })
        }
    }

    func test_LegacyCheckpoint_DoesNotInferHistoricalCoverage() async throws {
        let store = makeStore(name: #function)
        store.lastSyncDate = Self.date(year: 2025, month: 1, day: 1)

        let coverages = try await store.fetchDayFetchCoverages(scope: Self.inboxScope)

        XCTAssertTrue(coverages.isEmpty)
    }

    func test_Coverage_PersistsAcrossStoreRelaunch() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterMailCoverage-\(UUID().uuidString).sqlite")
        let defaults = UserDefaults(suiteName: "BatchBackfillServiceTests-persistence-\(UUID().uuidString)")!
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
        }

        let day = Self.date(year: 2026, month: 2, day: 16)
        let reference = Self.reference(id: "persisted",
                                       date: Self.date(year: 2026, month: 2, day: 16, hour: 8))
        let concreteScope = DayFetchScope(mailbox: "inbox",
                                          account: "Work",
                                          displayName: "Work / inbox")
        let firstStore = MessageStore(userDefaults: defaults, storeURL: storeURL)
        let coordinator = DayFetchCoordinator(client: ExhaustiveMailClient(references: [reference]),
                                              store: firstStore,
                                              calendar: Self.utcCalendar)
        _ = try await coordinator.fetchDay(containing: day,
                                           scope: concreteScope,
                                           mode: .full,
                                           requestBatchSize: 4,
                                           snippetLineLimit: 8,
                                           referenceDate: Self.date(year: 2026, month: 2, day: 17),
                                           progressHandler: { _ in })

        let relaunchedStore = MessageStore(userDefaults: defaults, storeURL: storeURL)
        let relaunchedCoverages = try await relaunchedStore.fetchDayFetchCoverages(scope: concreteScope)
        let coverage = try XCTUnwrap(relaunchedCoverages.first)
        XCTAssertEqual(coverage.state, .verified)
        XCTAssertEqual(coverage.expectedCount, 1)
        XCTAssertEqual(coverage.absentCount, 0)
    }

    func test_AggregateInbox_RecordsEveryAccountAndReportsLeastCompleteChild() async throws {
        let day = Self.date(year: 2026, month: 2, day: 18)
        let timestamp = Self.date(year: 2026, month: 2, day: 18, hour: 8)
        let workReference = Self.reference(id: "work", date: timestamp)
        let personalReference = MessageReference(internalMailID: "internal-personal",
                                                 messageID: "personal",
                                                 mailbox: "inbox",
                                                 account: "Personal",
                                                 subject: "personal",
                                                 date: timestamp,
                                                 isUnread: false)
        let workScope = DayFetchScope(mailbox: "inbox", account: "Work", displayName: "Work / inbox")
        let personalScope = DayFetchScope(mailbox: "inbox", account: "Personal", displayName: "Personal / inbox")
        let concreteScopes = [workScope, personalScope]
        let store = makeStore(name: #function)
        let client = ExhaustiveMailClient(references: [workReference, personalReference])
        let coordinator = DayFetchCoordinator(client: client, store: store, calendar: Self.utcCalendar)

        let result = try await coordinator.fetchDay(containing: day,
                                                    scope: Self.inboxScope,
                                                    mode: .full,
                                                    requestBatchSize: 4,
                                                    snippetLineLimit: 8,
                                                    referenceDate: Self.date(year: 2026, month: 2, day: 19),
                                                    progressHandler: { _ in })

        XCTAssertEqual(result.expectedCount, 2)
        let workCoverage = try await store.fetchDayFetchCoverages(scope: workScope).first
        let personalCoverage = try await store.fetchDayFetchCoverages(scope: personalScope).first
        let initialAggregate = try await store.fetchDayFetchCoverages(scope: Self.inboxScope,
                                                                      concreteScopes: concreteScopes).first
        XCTAssertEqual(workCoverage?.state, .verified)
        XCTAssertEqual(personalCoverage?.state, .verified)
        XCTAssertEqual(initialAggregate?.state, .verified)

        let interval = try XCTUnwrap(Self.utcCalendar.dateInterval(of: .day, for: day))
        let removedScope = DayFetchScope(mailbox: "inbox",
                                         account: "Removed Account",
                                         displayName: "Removed Account / inbox")
        try await store.failDayFetchCoverage(scope: removedScope,
                                            dayInterval: interval,
                                            attemptedAt: Self.date(year: 2026, month: 2, day: 19),
                                            errorMessage: "Removed account failure")
        let aggregateIgnoringRemovedAccount = try await store.fetchDayFetchCoverages(
            scope: Self.inboxScope,
            concreteScopes: concreteScopes
        ).first
        XCTAssertEqual(aggregateIgnoringRemovedAccount?.state, .verified)
        XCTAssertEqual(aggregateIgnoringRemovedAccount?.expectedCount, 2)

        try await store.failDayFetchCoverage(scope: personalScope,
                                            dayInterval: interval,
                                            attemptedAt: Self.date(year: 2026, month: 2, day: 19),
                                            errorMessage: "Test failure")
        let aggregateCoverages = try await store.fetchDayFetchCoverages(scope: Self.inboxScope,
                                                                        concreteScopes: concreteScopes)
        let aggregate = try XCTUnwrap(aggregateCoverages.first)
        XCTAssertEqual(aggregate.state, .failed)
        XCTAssertEqual(aggregate.expectedCount, 2)
    }

    func test_LegacyRFCFallback_RemainsScopedByAccountAndMailbox() async throws {
        let day = Self.date(year: 2026, month: 2, day: 19)
        let timestamp = Self.date(year: 2026, month: 2, day: 19, hour: 8)
        let work = MessageReference(internalMailID: nil,
                                    messageID: "shared-rfc-id",
                                    mailbox: "inbox",
                                    account: "Work",
                                    subject: "Work copy",
                                    date: timestamp,
                                    isUnread: false)
        let personal = MessageReference(internalMailID: nil,
                                        messageID: "shared-rfc-id",
                                        mailbox: "inbox",
                                        account: "Personal",
                                        subject: "Personal copy",
                                        date: timestamp,
                                        isUnread: false)
        let store = makeStore(name: #function)
        let coordinator = DayFetchCoordinator(client: ExhaustiveMailClient(references: [work, personal]),
                                              store: store,
                                              calendar: Self.utcCalendar)

        let result = try await coordinator.fetchDay(containing: day,
                                                    scope: Self.inboxScope,
                                                    mode: .full,
                                                    requestBatchSize: 4,
                                                    snippetLineLimit: 8,
                                                    referenceDate: Self.date(year: 2026, month: 2, day: 20),
                                                    progressHandler: { _ in })

        let storedAccounts = try await store.fetchMessages().map(\.accountName).sorted()
        XCTAssertEqual(result.expectedCount, 2)
        XCTAssertEqual(storedAccounts, ["Personal", "Work"])
    }

    func test_ManifestScript_IsUncappedHalfOpenAndEnumeratesAllMatchingMailboxes() async {
        let client = MailAppleScriptClient()
        let range = DateInterval(start: Self.date(year: 2026, month: 2, day: 20),
                                 end: Self.date(year: 2026, month: 2, day: 21))

        let script = await client.buildManifestScriptForTesting(range: range,
                                                                mailbox: "inbox",
                                                                account: nil)

        XCTAssertTrue(script.contains("set _mailboxes to my resolveMailboxesByPath"))
        XCTAssertTrue(script.contains("repeat with _mailboxRef in _mailboxes"))
        XCTAssertTrue(script.contains("date received is greater than or equal to _startDate"))
        XCTAssertTrue(script.contains("date received is less than _endDate"))
        XCTAssertFalse(script.contains("set _limit to"))
    }

    func test_PayloadScript_UnresolvedFirstMailboxDoesNotAbortRemainingReferences() async throws {
        let client = MailAppleScriptClient()
        let date = Self.date(year: 2026, month: 8, day: 18)
        let unresolved = MessageReference(internalMailID: nil,
                                          messageID: "legacy-unscoped",
                                          mailbox: "All Inboxes",
                                          account: "",
                                          subject: "Legacy",
                                          date: date,
                                          isUnread: false)
        let scoped = MessageReference(internalMailID: "123",
                                      messageID: "scoped-message",
                                      mailbox: "Inbox",
                                      account: "Work",
                                      subject: "Scoped",
                                      date: date,
                                      isUnread: false)

        let script = await client.buildPayloadScriptForTesting(references: [unresolved, scoped])
        var compilationError: NSDictionary?
        let compiledScript = try XCTUnwrap(NSAppleScript(source: script))

        XCTAssertTrue(script.contains("set _sourceMailbox to my resolveMailboxByPath(_wantedAccountName, _wantedMailboxPath)"))
        XCTAssertTrue(script.contains("if ((count of _matches) is 0) and (_wantedMessageID is not \"\") then"))
        XCTAssertTrue(script.contains("set _alternateMessageID to \"<\" & _wantedMessageID & \">\""))
        XCTAssertFalse(script.contains("set _mbx to my resolveMailboxByPath"))
        XCTAssertFalse(script.contains("error \"Mailbox not found for path:"))
        XCTAssertTrue(compiledScript.compileAndReturnError(&compilationError),
                      "Generated payload AppleScript did not compile: \(String(describing: compilationError))")
    }

    func test_MessageIDLookupScript_RemainsScopedToNamedAccount() async {
        let client = MailAppleScriptClient()

        let script = await client.buildMessageIDLookupScriptForTesting(messageIDs: ["message-id"],
                                                                       account: "Work")

        XCTAssertTrue(script.contains("set _accountRef to my matchingAccount(_accountToken)"))
        XCTAssertTrue(script.contains("set _mailboxesToScan to my allMailboxes(_accountRef)"))
        XCTAssertFalse(script.contains("set _accountRefs to every account"))
    }

    func test_ReferenceLookupScript_UsesStoredInternalIDThenSameAccountMessageIDFallback() async throws {
        let client = MailAppleScriptClient()
        let reference = MessageReference(internalMailID: "987654",
                                         messageID: "calendar-response@example.com",
                                         mailbox: "All Inboxes",
                                         account: "Work",
                                         subject: "Accepted: Internal Regroup",
                                         date: Self.date(year: 2026, month: 8, day: 18),
                                         isUnread: false)

        let script = await client.buildReferenceLookupScriptForTesting(references: [reference],
                                                                        account: "Work")
        var compilationError: NSDictionary?
        let compiledScript = try XCTUnwrap(NSAppleScript(source: script))

        XCTAssertTrue(script.contains("set _wantedInternalIDs to {\"987654\"}"))
        XCTAssertTrue(script.contains("whose id is (_wantedInternalID as integer)"))
        XCTAssertTrue(script.contains("whose message id is _wantedMessageID"))
        XCTAssertTrue(script.contains("set _mailboxesToScan to my allMailboxes(_accountRef)"))
        XCTAssertFalse(script.contains("set _accountRefs to every account"))
        XCTAssertTrue(compiledScript.compileAndReturnError(&compilationError),
                      "Generated reference lookup AppleScript did not compile: \(String(describing: compilationError))")
    }

    private func makeStore(name: String) -> MessageStore {
        let defaults = UserDefaults(suiteName: "BatchBackfillServiceTests-\(name)-\(UUID().uuidString)")!
        return MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
    }

    private func waitForRefreshCompletion(_ viewModel: ThreadCanvasViewModel,
                                          timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.isRefreshing && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(viewModel.isRefreshing, "Refresh did not complete before timeout")
    }

    private static let inboxScope = DayFetchScope(mailbox: "inbox",
                                                   account: nil,
                                                   displayName: "Inbox across all accounts",
                                                   includesAllInboxAliases: true)

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func date(year: Int,
                             month: Int,
                             day: Int,
                             hour: Int = 0,
                             minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year,
                                              month: month,
                                              day: day,
                                              hour: hour,
                                              minute: minute))!
    }

    private static func reference(id: String, date: Date) -> MessageReference {
        MessageReference(internalMailID: "internal-\(id)",
                         messageID: id,
                         mailbox: "inbox",
                         account: "Work",
                         subject: id,
                         date: date,
                         isUnread: false)
    }

    fileprivate static func message(from reference: MessageReference) -> EmailMessage {
        EmailMessage(messageID: reference.messageID,
                     internalMailID: reference.internalMailID,
                     mailboxID: reference.mailbox,
                     accountName: reference.account,
                     subject: reference.subject,
                     from: "sender@example.com",
                     to: "me@example.com",
                     date: reference.date,
                     snippet: reference.subject,
                     isUnread: reference.isUnread,
                     inReplyTo: nil,
                     references: [],
                     threadID: "thread-\(reference.messageID)")
    }
}

private actor ExhaustiveMailClient: MailMessageFetching {
    private var references: [MessageReference]
    private var manifestSequence: [[MessageReference]]
    private var manifestIndex = 0
    private let droppedPayloadIDs: Set<String>
    private let operationDelayNanoseconds: UInt64
    private var recordedBatchSizes: [Int] = []
    private var recordedProfiles: [MailFetchProfile] = []
    private var recordedManifestRanges: [DateInterval] = []
    private var activeOperations = 0
    private var maximumActiveOperations = 0

    init(references: [MessageReference],
         manifestSequence: [[MessageReference]] = [],
         droppedPayloadIDs: Set<String> = [],
         operationDelayNanoseconds: UInt64 = 0) {
        self.references = references
        self.manifestSequence = manifestSequence
        self.droppedPayloadIDs = droppedPayloadIDs
        self.operationDelayNanoseconds = operationDelayNanoseconds
    }

    func setReferences(_ references: [MessageReference]) {
        self.references = references
        manifestSequence = []
        manifestIndex = 0
    }

    func fetchMessageManifest(in range: DateInterval,
                              mailbox: String,
                              account: String?) async throws -> [MessageReference] {
        beginOperation()
        defer { endOperation() }
        recordedManifestRanges.append(range)
        if operationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: operationDelayNanoseconds)
        }
        let source: [MessageReference]
        if manifestSequence.isEmpty {
            source = references
        } else {
            source = manifestSequence[min(manifestIndex, manifestSequence.count - 1)]
            manifestIndex += 1
        }
        return source.filter { reference in
            reference.date >= range.start && reference.date < range.end
                && (account == nil || reference.account.caseInsensitiveCompare(account ?? "") == .orderedSame)
        }
    }

    func fetchMessages(references: [MessageReference],
                       profile: MailFetchProfile,
                       snippetLineLimit: Int) async throws -> [EmailMessage] {
        beginOperation()
        defer { endOperation() }
        recordedBatchSizes.append(references.count)
        recordedProfiles.append(profile)
        if operationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: operationDelayNanoseconds)
        }
        return references
            .filter { !droppedPayloadIDs.contains($0.messageID) }
            .map(BatchBackfillServiceTests.message(from:))
    }

    func resolveDayFetchScopes(mailbox: String,
                               account: String?) async throws -> [DayFetchScope] {
        let source = references + manifestSequence.flatMap { $0 }
        let filtered = source.filter { reference in
            account == nil || reference.account.caseInsensitiveCompare(account ?? "") == .orderedSame
        }
        var seen = Set<String>()
        return filtered.compactMap { reference in
            let scope = DayFetchScope(mailbox: reference.mailbox,
                                      account: reference.account,
                                      displayName: "\(reference.account) / \(reference.mailbox)")
            return seen.insert(scope.key).inserted ? scope : nil
        }
    }

    func countMessages(in range: DateInterval, mailbox: String, account: String?) async throws -> Int { 0 }

    func fetchMessages(in range: DateInterval,
                       limit: Int,
                       mailbox: String,
                       account: String?,
                       snippetLineLimit: Int) async throws -> [EmailMessage] { [] }

    func countMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                       mailbox: String,
                       account: String?) async throws -> Int { 0 }

    func fetchMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                       limit: Int,
                       mailbox: String,
                       account: String?,
                       snippetLineLimit: Int) async throws -> [EmailMessage] { [] }

    func payloadBatchSizes() -> [Int] { recordedBatchSizes }
    func payloadProfiles() -> [MailFetchProfile] { recordedProfiles }
    func manifestRanges() -> [DateInterval] { recordedManifestRanges }
    func maximumConcurrentOperations() -> Int { maximumActiveOperations }

    private func beginOperation() {
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
    }

    private func endOperation() {
        activeOperations -= 1
    }
}

@MainActor
private final class ExhaustiveMailCanvasClient: MailCanvasClient {
    private let base: ExhaustiveMailClient

    init(references: [MessageReference]) {
        base = ExhaustiveMailClient(references: references)
    }

    func fetchMessageManifest(in range: DateInterval,
                              mailbox: String,
                              account: String?) async throws -> [MessageReference] {
        try await base.fetchMessageManifest(in: range, mailbox: mailbox, account: account)
    }

    func fetchMessages(references: [MessageReference],
                       profile: MailFetchProfile,
                       snippetLineLimit: Int) async throws -> [EmailMessage] {
        try await base.fetchMessages(references: references,
                                     profile: profile,
                                     snippetLineLimit: snippetLineLimit)
    }

    func resolveDayFetchScopes(mailbox: String,
                               account: String?) async throws -> [DayFetchScope] {
        try await base.resolveDayFetchScopes(mailbox: mailbox, account: account)
    }

    func fetchMessages(since date: Date?,
                       limit: Int,
                       mailbox: String,
                       account: String?,
                       snippetLineLimit: Int,
                       profile: MailFetchProfile) async throws -> [EmailMessage] { [] }

    func fetchMailboxHierarchy() async throws -> [MailboxFolder] { [] }
    func countMessages(in range: DateInterval, mailbox: String, account: String?) async throws -> Int { 0 }
    func fetchMessages(in range: DateInterval, limit: Int, mailbox: String, account: String?, snippetLineLimit: Int) async throws -> [EmailMessage] { [] }
    func countMessages(matchingNormalizedSubjects normalizedSubjects: [String], mailbox: String, account: String?) async throws -> Int { 0 }
    func fetchMessages(matchingNormalizedSubjects normalizedSubjects: [String], limit: Int, mailbox: String, account: String?, snippetLineLimit: Int) async throws -> [EmailMessage] { [] }
    func payloadBatchSizes() async -> [Int] { await base.payloadBatchSizes() }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: () async throws -> T,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
