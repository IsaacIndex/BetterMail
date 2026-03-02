import CoreData
import XCTest
@testable import BetterMail

@MainActor
final class ThreadCanvasBackfillTests: XCTestCase {
    func test_UpdateVisibleDayRange_AllFolders_DoesNotExpandDayWindow() async throws {
        let defaults = UserDefaults(suiteName: "ThreadCanvasBackfillTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let pinnedFolderSettings = PinnedFolderSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
                                              store: store)
        viewModel.selectMailboxScope(.allFolders)
        let initialDayCount = viewModel.dayWindowCount
        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0, dayCount: initialDayCount, showsDayAxis: false)
        let today = Date()
        let layout = viewModel.canvasLayout(metrics: metrics,
                                            viewMode: .default,
                                            today: today,
                                            calendar: .current)
        let nearBottomOffset = max(layout.contentSize.height - 1, 0)
        for _ in 0..<3 {
            viewModel.updateVisibleDayRange(scrollOffset: nearBottomOffset,
                                            viewportHeight: 1,
                                            layout: layout,
                                            metrics: metrics,
                                            today: today,
                                            calendar: .current)
        }
        XCTAssertEqual(viewModel.dayWindowCount, initialDayCount)
    }

    func test_UpdateVisibleDayRange_AllEmails_ExpandsDayWindowNearBottom() async throws {
        let defaults = UserDefaults(suiteName: "ThreadCanvasBackfillTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let pinnedFolderSettings = PinnedFolderSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
                                              store: store)
        viewModel.selectMailboxScope(.allEmails)
        let initialDayCount = viewModel.dayWindowCount
        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0, dayCount: initialDayCount)
        let today = Date()
        let layout = viewModel.canvasLayout(metrics: metrics,
                                            viewMode: .default,
                                            today: today,
                                            calendar: .current)
        let nearBottomOffset = max(layout.contentSize.height - 1, 0)
        for _ in 0..<3 {
            viewModel.updateVisibleDayRange(scrollOffset: nearBottomOffset,
                                            viewportHeight: 1,
                                            layout: layout,
                                            metrics: metrics,
                                            today: today,
                                            calendar: .current)
        }
        XCTAssertGreaterThan(viewModel.dayWindowCount, initialDayCount)
    }

    func test_BackfillVisibleRange_UsesBackfillServiceAndRethreadsWhenFetched() async throws {
        let defaults = UserDefaults(suiteName: "ThreadCanvasBackfillTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let pinnedFolderSettings = PinnedFolderSettings()
        let backfillService = StubBatchBackfillService(
            countResult: 1,
            runResult: BatchBackfillResult(total: 1, fetched: 1),
            messageToInsert: EmailMessage(messageID: "<backfill-1>",
                                          mailboxID: "inbox",
                                          accountName: "",
                                          subject: "Backfilled",
                                          from: "sender@example.com",
                                          to: "me@example.com",
                                          date: Date(),
                                          snippet: "Body",
                                          isUnread: false,
                                          inReplyTo: nil,
                                          references: [],
                                          threadID: "thread-backfill"),
            store: store
        )

        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
                                              store: store,
                                              backfillService: backfillService)

        let range = DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
        viewModel.backfillVisibleRange(rangeOverride: range, limitOverride: 7)
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertFalse(viewModel.isBackfilling)
        XCTAssertEqual(viewModel.status,
                       String.localizedStringWithFormat(
                        NSLocalizedString("threadlist.backfill.status.complete", comment: ""),
                        1
                       ))
        XCTAssertEqual(await backfillService.recordedCountMailbox, "inbox")
        XCTAssertEqual(await backfillService.recordedRunMailbox, "inbox")
        XCTAssertNil(await backfillService.recordedCountAccount)
        XCTAssertNil(await backfillService.recordedRunAccount)
        XCTAssertEqual(await backfillService.recordedPreferredBatchSize, 7)
        XCTAssertEqual(await backfillService.recordedSnippetLineLimit, inspectorSettings.snippetLineLimit)
        XCTAssertEqual(viewModel.roots.count, 1)
    }

    func test_BackfillVisibleRange_WhenCountZero_CompletesWithoutRethread() async throws {
        let defaults = UserDefaults(suiteName: "ThreadCanvasBackfillTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let pinnedFolderSettings = PinnedFolderSettings()
        let backfillService = StubBatchBackfillService(countResult: 0)

        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
                                              store: store,
                                              backfillService: backfillService)

        let range = DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
        viewModel.backfillVisibleRange(rangeOverride: range, limitOverride: 5)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(viewModel.isBackfilling)
        XCTAssertEqual(viewModel.status,
                       String.localizedStringWithFormat(
                        NSLocalizedString("threadlist.backfill.status.complete", comment: ""),
                        0
                       ))
        XCTAssertFalse(await backfillService.didRunBackfill)
        XCTAssertTrue(viewModel.roots.isEmpty)
    }

    func test_BackfillVisibleRange_WhenServiceThrows_SetsFailedStatusAndStops() async throws {
        let defaults = UserDefaults(suiteName: "ThreadCanvasBackfillTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let pinnedFolderSettings = PinnedFolderSettings()
        let backfillService = StubBatchBackfillService(
            countResult: 2,
            runError: .boom
        )

        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
                                              store: store,
                                              backfillService: backfillService)

        let range = DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
        viewModel.backfillVisibleRange(rangeOverride: range, limitOverride: 5)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(viewModel.isBackfilling)
        XCTAssertEqual(viewModel.status,
                       String.localizedStringWithFormat(
                        NSLocalizedString("threadlist.backfill.status.failed", comment: ""),
                        "boom"
                       ))
    }

    func test_BackfillVisibleRange_WhenCancelled_ClearsIsBackfilling() async throws {
        let defaults = UserDefaults(suiteName: "ThreadCanvasBackfillTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let pinnedFolderSettings = PinnedFolderSettings()
        let backfillService = StubBatchBackfillService(shouldCancelOnCount: true)

        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
                                              store: store,
                                              backfillService: backfillService)

        let range = DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
        viewModel.backfillVisibleRange(rangeOverride: range, limitOverride: 5)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(viewModel.isBackfilling)
        XCTAssertEqual(viewModel.status,
                       NSLocalizedString("threadlist.backfill.status.fetching", comment: ""))
    }
}

private actor StubBatchBackfillService: BatchBackfillServicing {
    enum StubError: Error, LocalizedError, Sendable {
        case boom

        var errorDescription: String? {
            switch self {
            case .boom:
                return "boom"
            }
        }
    }

    private let countResult: Int
    private let runResult: BatchBackfillResult
    private let shouldCancelOnCount: Bool
    private let runError: StubError?
    private let messageToInsert: EmailMessage?
    private let store: MessageStore?

    private(set) var recordedCountMailbox: String?
    private(set) var recordedCountAccount: String?
    private(set) var recordedRunMailbox: String?
    private(set) var recordedRunAccount: String?
    private(set) var recordedPreferredBatchSize: Int?
    private(set) var recordedSnippetLineLimit: Int?
    private(set) var didRunBackfill = false

    init(countResult: Int = 0,
         runResult: BatchBackfillResult = BatchBackfillResult(total: 0, fetched: 0),
         shouldCancelOnCount: Bool = false,
         runError: StubError? = nil,
         messageToInsert: EmailMessage? = nil,
         store: MessageStore? = nil) {
        self.countResult = countResult
        self.runResult = runResult
        self.shouldCancelOnCount = shouldCancelOnCount
        self.runError = runError
        self.messageToInsert = messageToInsert
        self.store = store
    }

    func countMessages(in range: DateInterval, mailbox: String, account: String?) async throws -> Int {
        recordedCountMailbox = mailbox
        recordedCountAccount = account
        if shouldCancelOnCount {
            throw CancellationError()
        }
        return countResult
    }

    func runBackfill(range: DateInterval,
                     mailbox: String,
                     account: String?,
                     preferredBatchSize: Int,
                     totalExpected: Int,
                     snippetLineLimit: Int,
                     progressHandler: @Sendable (BatchBackfillProgress) -> Void) async throws -> BatchBackfillResult {
        didRunBackfill = true
        recordedRunMailbox = mailbox
        recordedRunAccount = account
        recordedPreferredBatchSize = preferredBatchSize
        recordedSnippetLineLimit = snippetLineLimit
        if let runError {
            throw runError
        }
        if let messageToInsert, let store {
            try await store.upsert(messages: [messageToInsert])
        }
        return runResult
    }
}
