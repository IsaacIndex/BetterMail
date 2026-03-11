import CoreData
import XCTest
@testable import BetterMail

@MainActor
final class BatchBackfillServiceTests: XCTestCase {
    func testRunBackfillFetchesEachDaySliceToExhaustion() async throws {
        let calendar = Self.utcCalendar
        let defaults = UserDefaults(suiteName: "BatchBackfillServiceTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)

        let start = Self.date(year: 2026, month: 2, day: 1, hour: 0, minute: 0)
        let middle = Self.date(year: 2026, month: 2, day: 2, hour: 0, minute: 0)
        let end = Self.date(year: 2026, month: 2, day: 3, hour: 0, minute: 0)

        let olderRange = DateInterval(start: start, end: middle)
        let newerRange = DateInterval(start: middle, end: end)
        let olderMessages = [
            Self.message(id: "older-1", date: Self.date(year: 2026, month: 2, day: 1, hour: 3, minute: 0)),
            Self.message(id: "older-2", date: Self.date(year: 2026, month: 2, day: 1, hour: 2, minute: 0)),
            Self.message(id: "older-3", date: Self.date(year: 2026, month: 2, day: 1, hour: 1, minute: 0))
        ]
        let newerMessages = [
            Self.message(id: "newer-1", date: Self.date(year: 2026, month: 2, day: 2, hour: 4, minute: 0)),
            Self.message(id: "newer-2", date: Self.date(year: 2026, month: 2, day: 2, hour: 1, minute: 0))
        ]

        let client = StubMailMessageClient(
            counts: [
                RangeKey(newerRange): newerMessages.count,
                RangeKey(olderRange): olderMessages.count
            ],
            fetchOutcomes: [
                RangeKey(newerRange): .success(newerMessages),
                RangeKey(olderRange): .success(olderMessages)
            ]
        )
        let service = BatchBackfillService(client: client, store: store, calendar: calendar)

        let recorder = ProgressRecorder()
        let result = try await service.runBackfill(range: DateInterval(start: start, end: end),
                                                   mailbox: "inbox",
                                                   account: nil,
                                                   preferredBatchSize: 5,
                                                   totalExpected: 5,
                                                   snippetLineLimit: 8) { progress in
            recorder.record(progress)
        }
        let fetchRequests = await client.fetchRequestsSnapshot()
        let progressEvents = recorder.snapshot()

        XCTAssertEqual(result.fetched, 5)
        XCTAssertEqual(fetchRequests, [
            FetchRequest(range: RangeKey(newerRange), limit: 2),
            FetchRequest(range: RangeKey(olderRange), limit: 3)
        ])
        XCTAssertTrue(fetchRequests.allSatisfy { $0.limit < 5 })
        let stored = try await store.fetchMessages(limit: nil)
        XCTAssertEqual(Set(stored.map(\.messageID)), Set(["older-1", "older-2", "older-3", "newer-1", "newer-2"]))
        XCTAssertEqual(progressEvents.last?.state, .finished)
        XCTAssertEqual(progressEvents.last?.completed, 5)
    }

    func testRunBackfillSplitsLargeSliceBeforeFetchToKeepSafeLimit() async throws {
        let calendar = Self.utcCalendar
        let defaults = UserDefaults(suiteName: "BatchBackfillServiceSafeLimitTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)

        let start = Self.date(year: 2026, month: 2, day: 1, hour: 0, minute: 0)
        let split = Self.date(year: 2026, month: 2, day: 1, hour: 12, minute: 0)
        let end = Self.date(year: 2026, month: 2, day: 2, hour: 0, minute: 0)

        let wholeDay = DateInterval(start: start, end: end)
        let newerHalf = DateInterval(start: split, end: end)
        let olderHalf = DateInterval(start: start, end: split)
        let newerMessages = [
            Self.message(id: "new-1", date: Self.date(year: 2026, month: 2, day: 1, hour: 23, minute: 0)),
            Self.message(id: "new-2", date: Self.date(year: 2026, month: 2, day: 1, hour: 21, minute: 0)),
            Self.message(id: "new-3", date: Self.date(year: 2026, month: 2, day: 1, hour: 19, minute: 0)),
            Self.message(id: "new-4", date: Self.date(year: 2026, month: 2, day: 1, hour: 17, minute: 0))
        ]
        let olderMessages = [
            Self.message(id: "old-1", date: Self.date(year: 2026, month: 2, day: 1, hour: 9, minute: 0)),
            Self.message(id: "old-2", date: Self.date(year: 2026, month: 2, day: 1, hour: 3, minute: 0))
        ]

        let client = StubMailMessageClient(
            counts: [
                RangeKey(wholeDay): 6,
                RangeKey(newerHalf): newerMessages.count,
                RangeKey(olderHalf): olderMessages.count
            ],
            fetchOutcomes: [
                RangeKey(newerHalf): .success(newerMessages),
                RangeKey(olderHalf): .success(olderMessages)
            ]
        )
        let service = BatchBackfillService(client: client, store: store, calendar: calendar)

        let recorder = ProgressRecorder()
        let result = try await service.runBackfill(range: wholeDay,
                                                   mailbox: "inbox",
                                                   account: nil,
                                                   preferredBatchSize: 5,
                                                   totalExpected: 6,
                                                   snippetLineLimit: 8) { progress in
            recorder.record(progress)
        }
        let fetchRequests = await client.fetchRequestsSnapshot()
        let progressEvents = recorder.snapshot()

        XCTAssertEqual(result.fetched, 6)
        XCTAssertEqual(fetchRequests, [
            FetchRequest(range: RangeKey(newerHalf), limit: 4),
            FetchRequest(range: RangeKey(olderHalf), limit: 2)
        ])
        XCTAssertTrue(fetchRequests.allSatisfy { $0.limit < 5 })
        XCTAssertTrue(progressEvents.contains(where: { $0.state == .splitting }))
    }

    func testRunBackfillSplitsRangeWhenFetchFails() async throws {
        let calendar = Self.utcCalendar
        let defaults = UserDefaults(suiteName: "BatchBackfillServiceSplitTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)

        let start = Self.date(year: 2026, month: 2, day: 1, hour: 0, minute: 0)
        let split = Self.date(year: 2026, month: 2, day: 1, hour: 12, minute: 0)
        let end = Self.date(year: 2026, month: 2, day: 2, hour: 0, minute: 0)

        let wholeDay = DateInterval(start: start, end: end)
        let newerHalf = DateInterval(start: split, end: end)
        let olderHalf = DateInterval(start: start, end: split)
        let newerMessages = [
            Self.message(id: "newer-half-1", date: Self.date(year: 2026, month: 2, day: 1, hour: 18, minute: 0)),
            Self.message(id: "newer-half-2", date: Self.date(year: 2026, month: 2, day: 1, hour: 16, minute: 0))
        ]
        let olderMessages = [
            Self.message(id: "older-half-1", date: Self.date(year: 2026, month: 2, day: 1, hour: 9, minute: 0)),
            Self.message(id: "older-half-2", date: Self.date(year: 2026, month: 2, day: 1, hour: 3, minute: 0))
        ]

        let client = StubMailMessageClient(
            counts: [
                RangeKey(wholeDay): 4,
                RangeKey(newerHalf): newerMessages.count,
                RangeKey(olderHalf): olderMessages.count
            ],
            fetchOutcomes: [
                RangeKey(wholeDay): .failure(.timeout),
                RangeKey(newerHalf): .success(newerMessages),
                RangeKey(olderHalf): .success(olderMessages)
            ]
        )
        let service = BatchBackfillService(client: client, store: store, calendar: calendar)

        let recorder = ProgressRecorder()
        let result = try await service.runBackfill(range: wholeDay,
                                                   mailbox: "inbox",
                                                   account: nil,
                                                   preferredBatchSize: 5,
                                                   totalExpected: 4,
                                                   snippetLineLimit: 8) { progress in
            recorder.record(progress)
        }
        let fetchRequests = await client.fetchRequestsSnapshot()
        let progressEvents = recorder.snapshot()

        XCTAssertEqual(result.fetched, 4)
        XCTAssertEqual(fetchRequests, [
            FetchRequest(range: RangeKey(wholeDay), limit: 4),
            FetchRequest(range: RangeKey(newerHalf), limit: 2),
            FetchRequest(range: RangeKey(olderHalf), limit: 2)
        ])
        XCTAssertTrue(fetchRequests.allSatisfy { $0.limit < 5 })
        XCTAssertTrue(progressEvents.contains(where: { $0.state == .retrying }))
        XCTAssertEqual(progressEvents.last?.state, .finished)
        XCTAssertEqual(progressEvents.last?.completed, 4)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: year,
                                              month: month,
                                              day: day,
                                              hour: hour,
                                              minute: minute))!
    }

    private static func message(id: String, date: Date) -> EmailMessage {
        EmailMessage(messageID: id,
                     mailboxID: "inbox",
                     accountName: "",
                     subject: id,
                     from: "a@example.com",
                     to: "me@example.com",
                     date: date,
                     snippet: id,
                     isUnread: false,
                     inReplyTo: nil,
                     references: [],
                     threadID: "thread-\(id)")
    }
}

private struct RangeKey: Hashable {
    let start: TimeInterval
    let end: TimeInterval

    init(_ range: DateInterval) {
        self.start = range.start.timeIntervalSince1970
        self.end = range.end.timeIntervalSince1970
    }
}

private struct FetchRequest: Equatable {
    let range: RangeKey
    let limit: Int
}

private enum StubFetchError: Error {
    case timeout
}

private enum FetchOutcome {
    case success([EmailMessage])
    case failure(StubFetchError)
}

private actor StubMailMessageClient: MailMessageFetching {
    private let counts: [RangeKey: Int]
    private let fetchOutcomes: [RangeKey: FetchOutcome]
    private(set) var fetchRequests: [FetchRequest] = []

    init(counts: [RangeKey: Int], fetchOutcomes: [RangeKey: FetchOutcome]) {
        self.counts = counts
        self.fetchOutcomes = fetchOutcomes
    }

    func countMessages(in range: DateInterval, mailbox: String, account: String?) async throws -> Int {
        counts[RangeKey(range), default: 0]
    }

    func fetchMessages(in range: DateInterval,
                       limit: Int,
                       mailbox: String,
                       account: String?,
                       snippetLineLimit: Int) async throws -> [EmailMessage] {
        let key = RangeKey(range)
        fetchRequests.append(FetchRequest(range: key, limit: limit))
        switch fetchOutcomes[key] ?? .success([]) {
        case let .success(messages):
            return messages
        case let .failure(error):
            throw error
        }
    }

    func fetchRequestsSnapshot() -> [FetchRequest] {
        fetchRequests
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BatchBackfillProgress] = []

    func record(_ progress: BatchBackfillProgress) {
        lock.lock()
        defer { lock.unlock() }
        events.append(progress)
    }

    func snapshot() -> [BatchBackfillProgress] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
