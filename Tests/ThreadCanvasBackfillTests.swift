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

    func test_FolderRefreshPlan_groupsByMailboxAndNormalizedSubject() {
        let inboxFirst = EmailMessage(messageID: "msg-1",
                                      mailboxID: "All Inboxes",
                                      accountName: "",
                                      subject: "RE: [EXTERNAL] Inbox A",
                                      from: "a@example.com",
                                      to: "me@example.com",
                                      date: Date(timeIntervalSince1970: 1_707_069_600),
                                      snippet: "",
                                      isUnread: false,
                                      inReplyTo: nil,
                                      references: [],
                                      threadID: "thread-a")
        let inboxSecond = EmailMessage(messageID: "msg-2",
                                       mailboxID: "All Inboxes",
                                       accountName: "",
                                       subject: "Fwd: Inbox A",
                                       from: "b@example.com",
                                       to: "me@example.com",
                                       date: Date(timeIntervalSince1970: 1_707_148_800),
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [],
                                       threadID: "thread-b")
        let projectMessage = EmailMessage(messageID: "msg-3",
                                          mailboxID: "Projects/Acme",
                                          accountName: "Work",
                                          subject: "[EXTERNAL] Re: Project",
                                          from: "c@example.com",
                                          to: "me@example.com",
                                          date: Date(timeIntervalSince1970: 1_707_523_200),
                                          snippet: "",
                                          isUnread: false,
                                          inReplyTo: nil,
                                          references: [],
                                          threadID: "thread-c")

        let plan = ThreadCanvasViewModel.folderRefreshPlanForTesting(messages: [inboxFirst, inboxSecond, projectMessage])

        XCTAssertEqual(plan.count, 2)

        let inboxPlan = try XCTUnwrap(plan.first(where: { $0.mailbox == "inbox" }))
        XCTAssertNil(inboxPlan.account)
        XCTAssertEqual(inboxPlan.normalizedSubjects, ["inbox a"])

        let projectPlan = try XCTUnwrap(plan.first(where: { $0.mailbox == "Projects/Acme" }))
        XCTAssertEqual(projectPlan.account, "Work")
        XCTAssertEqual(projectPlan.normalizedSubjects, ["project"])
    }

    func test_MailboxRefreshSubjectNormalizer_stripsPrefixesAndBracketTags() {
        XCTAssertEqual(MailboxRefreshSubjectNormalizer.normalize("RE: [EXTERNAL] Example Subject"), "example subject")
        XCTAssertEqual(MailboxRefreshSubjectNormalizer.normalize(" Fwd:   Re: Example Subject "), "example subject")
        XCTAssertEqual(MailboxRefreshSubjectNormalizer.normalize("[Notice] FW: Test"), "test")
    }

    func test_RefreshFolderThreads_refreshesSelectedFolderAndChildFolderThreads() async throws {
        let defaults = UserDefaults(suiteName: "ThreadCanvasBackfillFolderRefreshTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let parentMessage = EmailMessage(messageID: "parent-msg",
                                         mailboxID: "Projects/Acme",
                                         accountName: "Work",
                                         subject: "Parent",
                                         from: "a@example.com",
                                         to: "me@example.com",
                                         date: Date(timeIntervalSince1970: 1_707_566_400),
                                         snippet: "",
                                         isUnread: false,
                                         inReplyTo: nil,
                                         references: [],
                                         threadID: "thread-parent")
        let childMessage = EmailMessage(messageID: "child-msg",
                                        mailboxID: "Archive/Child",
                                        accountName: "Work",
                                        subject: "Child",
                                        from: "b@example.com",
                                        to: "me@example.com",
                                        date: Date(timeIntervalSince1970: 1_707_652_800),
                                        snippet: "",
                                        isUnread: false,
                                        inReplyTo: nil,
                                        references: [],
                                        threadID: "thread-child")
        let backfillService = StubBatchBackfillService(countResult: 1,
                                                       runResult: BatchBackfillResult(total: 1, fetched: 1))
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              store: store,
                                              backfillService: backfillService)
        let parentFolder = ThreadFolder(id: "folder-parent",
                                        title: "Parent",
                                        color: ThreadFolderColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                        threadIDs: ["thread-parent"],
                                        parentID: nil)
        let childFolder = ThreadFolder(id: "folder-child",
                                       title: "Child",
                                       color: ThreadFolderColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1),
                                       threadIDs: ["thread-child"],
                                       parentID: "folder-parent")

        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: parentMessage), ThreadNode(message: childMessage)],
                                                folders: [parentFolder, childFolder])
        viewModel.refreshFolderThreads(for: "folder-parent", limit: 3)
        try await Task.sleep(nanoseconds: 500_000_000)

        let countCalls = await backfillService.subjectCountCalls
        let fetchCalls = await backfillService.subjectFetchCalls
        XCTAssertEqual(Set(countCalls.map(\.mailbox)), Set(["Projects/Acme", "Archive/Child"]))
        XCTAssertEqual(Set(fetchCalls.map(\.mailbox)), Set(["Projects/Acme", "Archive/Child"]))
        XCTAssertEqual(Set(fetchCalls.compactMap(\.account)), Set(["Work"]))
        XCTAssertEqual(Set(fetchCalls.flatMap(\.subjects)), Set(["parent", "child"]))
        XCTAssertFalse(viewModel.isRefreshingFolderThreads(for: "folder-parent"))
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
    private(set) var countCalls: [(mailbox: String, account: String?)] = []
    private(set) var runCalls: [(mailbox: String, account: String?)] = []
    private(set) var subjectCountCalls: [(mailbox: String, account: String?, subjects: [String])] = []
    private(set) var subjectFetchCalls: [(mailbox: String, account: String?, subjects: [String], limit: Int)] = []

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
        countCalls.append((mailbox: mailbox, account: account))
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
        runCalls.append((mailbox: mailbox, account: account))
        if let runError {
            throw runError
        }
        if let messageToInsert, let store {
            try await store.upsert(messages: [messageToInsert])
        }
        return runResult
    }

    func countMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                       mailbox: String,
                       account: String?) async throws -> Int {
        subjectCountCalls.append((mailbox: mailbox, account: account, subjects: normalizedSubjects))
        if shouldCancelOnCount {
            throw CancellationError()
        }
        return countResult
    }

    func fetchMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                       mailbox: String,
                       account: String?,
                       limit: Int,
                       snippetLineLimit: Int) async throws -> [EmailMessage] {
        subjectFetchCalls.append((mailbox: mailbox, account: account, subjects: normalizedSubjects, limit: limit))
        recordedPreferredBatchSize = limit
        recordedSnippetLineLimit = snippetLineLimit
        if let runError {
            throw runError
        }
        if let messageToInsert, let store {
            try await store.upsert(messages: [messageToInsert])
            return [messageToInsert]
        }
        return []
    }
}
