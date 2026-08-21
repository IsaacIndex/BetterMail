import CoreData
import XCTest
@testable import BetterMail

final class SummaryRegenerationServiceTests: XCTestCase {
    func testRegenerationBatchesAndReportsProgress() async throws {
        let defaults = UserDefaults(suiteName: "SummaryRegenerationServiceTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = (0..<7).map { index in
            EmailMessage(messageID: "<\(index)>",
                         mailboxID: "inbox",
                         accountName: "",
                         subject: "Subject \(index)",
                         from: "a@example.com",
                         to: "me@example.com",
                         date: Calendar.current.date(byAdding: .day, value: -index, to: now)!,
                         snippet: "Body \(index)",
                         isUnread: false,
                         inReplyTo: nil,
                         references: [],
                         threadID: "thread-1")
        }
        try await store.upsert(messages: messages)

        let provider = TestSummaryProvider(emailResult: "Summary")
        let titleProvider = TestRegenerationGraphTitleProvider(result: "States current status")
        let service = SummaryRegenerationService(
            store: store,
            graphTitleCapabilityProvider: {
                readyGraphTitleCapability(provider: titleProvider)
            }
        ) {
            EmailSummaryCapability(provider: provider,
                                   statusMessage: "Ready",
                                   providerID: "test")
        }

        let range = DateInterval(start: Calendar.current.date(byAdding: .day, value: -10, to: now)!,
                                 end: now.addingTimeInterval(1))
        let total = try await service.countMessages(in: range, mailbox: "inbox")
        XCTAssertEqual(total, 7)
        let completionNotification = expectation(forNotification: .summaryRegenerationDidComplete,
                                                 object: store)

        var progressEvents: [SummaryRegenerationProgress] = []
        let result = try await service.runRegeneration(range: range,
                                                       mailbox: "inbox",
                                                       preferredBatchSize: 3,
                                                       totalExpected: total,
                                                       snippetLineLimit: 4,
                                                       stopPhrases: []) { progress in
            progressEvents.append(progress)
        }
        await fulfillment(of: [completionNotification], timeout: 1)

        XCTAssertEqual(result.regenerated, 7)
        XCTAssertEqual(result.graphTitlesRegenerated, 7)
        XCTAssertEqual(provider.emailCallCount, 7)
        XCTAssertEqual(progressEvents.last?.state, .finished)
        XCTAssertEqual(progressEvents.last?.completed, 7)
    }

    func testRegenerationHydratesFullThreadButWritesOnlyRequestedRange() async throws {
        let defaults = UserDefaults(suiteName: "SummaryRegenerationServiceTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let older = EmailMessage(messageID: "<older>",
                                 mailboxID: "inbox",
                                 accountName: "",
                                 subject: "Original request",
                                 from: "a@example.com",
                                 to: "me@example.com",
                                 date: now.addingTimeInterval(-86_400),
                                 snippet: "Please approve the plan.",
                                 isUnread: false,
                                 inReplyTo: nil,
                                 references: [])
        let latest = EmailMessage(messageID: "<latest>",
                                  mailboxID: "inbox",
                                  accountName: "",
                                  subject: "Approved",
                                  from: "b@example.com",
                                  to: "me@example.com",
                                  date: now,
                                  snippet: "Approved for Friday.",
                                  isUnread: false,
                                  inReplyTo: older.messageID,
                                  references: [older.messageID])
        try await store.upsert(messages: [older, latest])
        try await store.upsertSummaries([
            SummaryCacheEntry(scope: .emailNode,
                              scopeID: older.messageID,
                              summaryText: "Existing older summary",
                              generatedAt: now.addingTimeInterval(-100),
                              fingerprint: "old",
                              provider: "test")
        ])

        let provider = TestSummaryProvider(emailResult: "Range summary")
        let titleProvider = TestRegenerationGraphTitleProvider(result: "Confirms requested outcome")
        let service = SummaryRegenerationService(
            store: store,
            graphTitleCapabilityProvider: {
                readyGraphTitleCapability(provider: titleProvider)
            }
        ) {
            EmailSummaryCapability(provider: provider, statusMessage: "Ready", providerID: "test")
        }
        let range = DateInterval(start: now.addingTimeInterval(-60),
                                 end: now.addingTimeInterval(1))

        _ = try await service.runRegeneration(range: range,
                                              mailbox: "inbox",
                                              preferredBatchSize: 10,
                                              totalExpected: 1,
                                              snippetLineLimit: 4,
                                              stopPhrases: []) { _ in }

        XCTAssertEqual(provider.emailRequests.count, 1)
        let context = provider.emailRequests.first?.threadContext
        XCTAssertEqual(context?.position, 2)
        XCTAssertEqual(context?.totalMessages, 2)
        XCTAssertEqual(context?.previousMessage?.subject, "Original request")
        let cache = try await store.fetchSummaries(scope: .emailNode,
                                                   ids: [older.messageID, latest.messageID])
        let cacheByID = Dictionary(uniqueKeysWithValues: cache.map { ($0.scopeID, $0) })
        XCTAssertEqual(cacheByID[older.messageID]?.summaryText, "Existing older summary")
        XCTAssertEqual(cacheByID[latest.messageID]?.summaryText, "Range summary")
        let titleCache = try await store.fetchSummaries(scope: .graphTitle,
                                                        ids: [older.messageID, latest.messageID])
        XCTAssertEqual(titleCache.map(\.scopeID), [latest.messageID])
    }

    func testRegenerationWritesSemanticTitleForRequestedRangeUsingFullThreadContext() async throws {
        let defaults = UserDefaults(suiteName: "SummaryRegenerationServiceTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let older = EmailMessage(messageID: "<older-title>",
                                 mailboxID: "inbox",
                                 accountName: "",
                                 subject: "Request rollout approval",
                                 from: "a@example.com",
                                 to: "me@example.com",
                                 date: now.addingTimeInterval(-86_400),
                                 snippet: "Can we launch on Friday?",
                                 isUnread: false,
                                 inReplyTo: nil,
                                 references: [])
        let latest = EmailMessage(messageID: "<latest-title>",
                                  mailboxID: "inbox",
                                  accountName: "",
                                  subject: "Re: Request rollout approval",
                                  from: "b@example.com",
                                  to: "me@example.com",
                                  date: now,
                                  snippet: "Approved for Friday.",
                                  isUnread: false,
                                  inReplyTo: older.messageID,
                                  references: [older.messageID])
        try await store.upsert(messages: [older, latest])

        let summaryProvider = TestSummaryProvider(emailResult: "Approves the Friday rollout.")
        let titleProvider = TestRegenerationGraphTitleProvider(
            result: "2/2 · Confirms Friday rollout"
        )
        let service = SummaryRegenerationService(
            store: store,
            graphTitleCapabilityProvider: {
                GraphTitleCapability(provider: titleProvider,
                                     statusMessage: "Ready",
                                     providerID: "test-title-v2",
                                     shouldRetry: false)
            }
        ) {
            EmailSummaryCapability(provider: summaryProvider,
                                   statusMessage: "Ready",
                                   providerID: "test-summary-v2")
        }
        let range = DateInterval(start: now.addingTimeInterval(-60),
                                 end: now.addingTimeInterval(1))

        let result = try await service.runRegeneration(range: range,
                                                       mailbox: "inbox",
                                                       preferredBatchSize: 10,
                                                       totalExpected: 1,
                                                       snippetLineLimit: 4,
                                                       stopPhrases: []) { _ in }

        XCTAssertEqual(result.regenerated, 1)
        XCTAssertEqual(result.graphTitlesRegenerated, 1)
        let titleRequests = await titleProvider.requests
        XCTAssertEqual(titleRequests.count, 1)
        XCTAssertEqual(titleRequests.first?.summary, "Approves the Friday rollout.")
        XCTAssertEqual(titleRequests.first?.threadContext.position, 2)
        XCTAssertEqual(titleRequests.first?.threadContext.totalMessages, 2)
        XCTAssertEqual(titleRequests.first?.threadContext.previousMessage?.messageID,
                       older.messageID)
        XCTAssertEqual(titleRequests.first?.threadContext.previousMessage?.relationship,
                       .automaticReply)

        let summaries = try await store.fetchSummaries(scope: .emailNode,
                                                        ids: [older.messageID, latest.messageID])
        XCTAssertEqual(summaries.map(\.scopeID), [latest.messageID])
        let titles = try await store.fetchSummaries(scope: .graphTitle,
                                                    ids: [older.messageID, latest.messageID])
        XCTAssertEqual(titles.map(\.scopeID), [latest.messageID])
        XCTAssertEqual(titles.first?.summaryText, "Confirms Friday rollout")
        XCTAssertEqual(titles.first?.provider, "test-title-v2")
    }

    func testRegenerationTitleFailurePreservesPriorSummaryAndTitleBatch() async throws {
        let defaults = UserDefaults(suiteName: "SummaryRegenerationServiceTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let message = EmailMessage(messageID: "<atomic-title>",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "Approval update",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: now,
                                   snippet: "Approved.",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [])
        try await store.upsert(messages: [message])
        try await store.upsertSummaries([
            SummaryCacheEntry(scope: .emailNode,
                              scopeID: message.messageID,
                              summaryText: "Prior summary",
                              generatedAt: now.addingTimeInterval(-100),
                              fingerprint: "prior-summary",
                              provider: "prior"),
            SummaryCacheEntry(scope: .graphTitle,
                              scopeID: message.messageID,
                              summaryText: "Prior semantic title",
                              generatedAt: now.addingTimeInterval(-100),
                              fingerprint: "prior-title",
                              provider: "prior")
        ])

        let summaryProvider = TestSummaryProvider(emailResult: "New summary")
        let titleProvider = TestRegenerationGraphTitleProvider(
            error: TestRegenerationError.expectedTitleFailure
        )
        let service = SummaryRegenerationService(
            store: store,
            graphTitleCapabilityProvider: {
                GraphTitleCapability(provider: titleProvider,
                                     statusMessage: "Ready",
                                     providerID: "test-title-v2",
                                     shouldRetry: false)
            }
        ) {
            EmailSummaryCapability(provider: summaryProvider,
                                   statusMessage: "Ready",
                                   providerID: "test-summary-v2")
        }
        let range = DateInterval(start: now.addingTimeInterval(-60),
                                 end: now.addingTimeInterval(1))

        do {
            _ = try await service.runRegeneration(range: range,
                                                  mailbox: "inbox",
                                                  preferredBatchSize: 10,
                                                  totalExpected: 1,
                                                  snippetLineLimit: 4,
                                                  stopPhrases: []) { _ in }
            XCTFail("Expected title generation to fail")
        } catch TestRegenerationError.expectedTitleFailure {
            // Summary and title are staged together, so neither is replaced.
        }

        let summaries = try await store.fetchSummaries(scope: .emailNode,
                                                        ids: [message.messageID])
        let titles = try await store.fetchSummaries(scope: .graphTitle,
                                                    ids: [message.messageID])
        XCTAssertEqual(summaries.first?.summaryText, "Prior summary")
        XCTAssertEqual(titles.first?.summaryText, "Prior semantic title")
    }

    func testRegenerationUnavailableTitleProviderFailsBeforeReplacingSummaries() async throws {
        let defaults = UserDefaults(suiteName: "SummaryRegenerationServiceTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let message = EmailMessage(messageID: "<title-unavailable>",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "Approval update",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: now,
                                   snippet: "Approved.",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [])
        try await store.upsert(messages: [message])
        try await store.upsertSummaries([
            SummaryCacheEntry(scope: .emailNode,
                              scopeID: message.messageID,
                              summaryText: "Prior summary",
                              generatedAt: now.addingTimeInterval(-100),
                              fingerprint: "prior-summary",
                              provider: "prior")
        ])

        let summaryProvider = TestSummaryProvider(emailResult: "New summary")
        let service = SummaryRegenerationService(
            store: store,
            graphTitleCapabilityProvider: { unavailableGraphTitleCapability() }
        ) {
            EmailSummaryCapability(provider: summaryProvider,
                                   statusMessage: "Ready",
                                   providerID: "test-summary-v2")
        }

        do {
            _ = try await service.runRegeneration(
                range: DateInterval(start: now.addingTimeInterval(-60),
                                    end: now.addingTimeInterval(1)),
                mailbox: "inbox",
                preferredBatchSize: 10,
                totalExpected: 1,
                snippetLineLimit: 4,
                stopPhrases: []
            ) { _ in }
            XCTFail("Expected unavailable semantic-title generation to fail")
        } catch let error as EmailSummaryError {
            XCTAssertEqual(error.localizedDescription, "Unavailable for this test")
        }

        XCTAssertEqual(summaryProvider.emailCallCount, 0)
        let summaries = try await store.fetchSummaries(scope: .emailNode,
                                                        ids: [message.messageID])
        XCTAssertEqual(summaries.first?.summaryText, "Prior summary")
    }

    func testRegenerationRefreshesContainingGroupAndAncestorAfterNodeCommit() async throws {
        let defaults = UserDefaults(suiteName: "SummaryRegenerationServiceTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let message = EmailMessage(messageID: "<grouped>",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "Grouped message",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: now,
                                   snippet: "Group summary source.",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [])
        let threadID = try XCTUnwrap(JWZThreader().buildThreads(from: [message]).roots.first?.message.threadID)
        let parent = ThreadFolder(id: "parent",
                                  title: "Parent",
                                  color: .defaultNewFolder,
                                  threadIDs: [],
                                  parentID: nil)
        let child = ThreadFolder(id: "child",
                                 title: "Child",
                                 color: .defaultNewFolder,
                                 threadIDs: [threadID],
                                 parentID: parent.id)
        try await store.upsert(messages: [message])
        try await store.upsertThreadFolders([parent, child])

        let provider = TestSummaryProvider(emailResult: "Node summary", folderResult: "Group summary")
        let titleProvider = TestRegenerationGraphTitleProvider(result: "Introduces grouped topic")
        let service = SummaryRegenerationService(
            store: store,
            graphTitleCapabilityProvider: {
                readyGraphTitleCapability(provider: titleProvider)
            }
        ) {
            EmailSummaryCapability(provider: provider, statusMessage: "Ready", providerID: "test")
        }
        let range = DateInterval(start: now.addingTimeInterval(-60),
                                 end: now.addingTimeInterval(1))

        _ = try await service.runRegeneration(range: range,
                                              mailbox: "inbox",
                                              preferredBatchSize: 10,
                                              totalExpected: 1,
                                              snippetLineLimit: 4,
                                              stopPhrases: []) { _ in }

        XCTAssertEqual(provider.events.first, "email:Grouped message")
        XCTAssertEqual(provider.events.filter { $0.hasPrefix("folder:") },
                       ["folder:Child", "folder:Parent"])
        XCTAssertEqual(Set(provider.folderRequests.map(\.title)), ["Parent", "Child"])
        let groupCache = try await store.fetchSummaries(scope: .folder, ids: [parent.id, child.id])
        XCTAssertEqual(groupCache.count, 2)
    }

    func testRegenerationNotifiesCommittedNodesWhenGroupRefreshFails() async throws {
        let defaults = UserDefaults(suiteName: "SummaryRegenerationServiceTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let message = EmailMessage(messageID: "<group-failure>",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "Committed before group failure",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: now,
                                   snippet: "Node generation succeeds.",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [])
        let threadID = try XCTUnwrap(JWZThreader().buildThreads(from: [message]).roots.first?.message.threadID)
        let folder = ThreadFolder(id: "folder",
                                  title: "Failing Group",
                                  color: .defaultNewFolder,
                                  threadIDs: [threadID],
                                  parentID: nil)
        try await store.upsert(messages: [message])
        try await store.upsertThreadFolders([folder])

        let provider = TestSummaryProvider(emailResult: "Committed node summary",
                                           folderError: TestRegenerationError.expectedFolderFailure)
        let titleProvider = TestRegenerationGraphTitleProvider(result: "Confirms committed update")
        let service = SummaryRegenerationService(
            store: store,
            graphTitleCapabilityProvider: {
                GraphTitleCapability(provider: titleProvider,
                                     statusMessage: "Ready",
                                     providerID: "test-title-v2",
                                     shouldRetry: false)
            }
        ) {
            EmailSummaryCapability(provider: provider, statusMessage: "Ready", providerID: "test")
        }
        let completionNotification = expectation(forNotification: .summaryRegenerationDidComplete,
                                                 object: store)
        let range = DateInterval(start: now.addingTimeInterval(-60),
                                 end: now.addingTimeInterval(1))

        do {
            _ = try await service.runRegeneration(range: range,
                                                  mailbox: "inbox",
                                                  preferredBatchSize: 10,
                                                  totalExpected: 1,
                                                  snippetLineLimit: 4,
                                                  stopPhrases: []) { _ in }
            XCTFail("Expected Group summary generation to fail")
        } catch TestRegenerationError.expectedFolderFailure {
            // The node batch is already durable and must still be published.
        }
        await fulfillment(of: [completionNotification], timeout: 1)

        let nodeCache = try await store.fetchSummaries(scope: .emailNode,
                                                       ids: [message.messageID])
        XCTAssertEqual(nodeCache.first?.summaryText, "Committed node summary")
        let titleCache = try await store.fetchSummaries(scope: .graphTitle,
                                                        ids: [message.messageID])
        XCTAssertEqual(titleCache.first?.summaryText, "Confirms committed update")
        let folderCache = try await store.fetchSummaries(scope: .folder, ids: [folder.id])
        XCTAssertTrue(folderCache.isEmpty)
    }

    @MainActor
    func testRegenerationStatusMappingInViewModel() async throws {
        let regenService = StubRegenerationService(totalCount: 2)

        let viewModel = BatchBackfillSettingsViewModel(regenerationService: regenService,
                                                       snippetLineLimitProvider: { 2 },
                                                       stopPhrasesProvider: { [] })
        viewModel.startRegeneration()

        for _ in 0..<400 where viewModel.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(viewModel.totalCount, 2)
        XCTAssertEqual(viewModel.completedCount, 2)
        XCTAssertEqual(viewModel.statusText,
                       String.localizedStringWithFormat(
                        NSLocalizedString("settings.regenai.status.finished", comment: ""),
                        2,
                        2
                       ))
    }

    @MainActor
    func test_RegenerationWrappedCancellation_WhenStopped_ShowsCancelledStatus() async throws {
        let regenService = WrappedCancellationRegenerationService()
        let viewModel = BatchBackfillSettingsViewModel(regenerationService: regenService,
                                                       snippetLineLimitProvider: { 2 },
                                                       stopPhrasesProvider: { [] })

        viewModel.startRegeneration()
        for _ in 0..<400 {
            if await regenService.hasStarted() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let didStart = await regenService.hasStarted()
        XCTAssertTrue(didStart)

        viewModel.cancelCurrentRun()
        for _ in 0..<400 where viewModel.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertFalse(viewModel.isRunning)
        XCTAssertFalse(viewModel.isStopping)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.statusText,
                       NSLocalizedString("settings.regenai.status.cancelled", comment: ""))
    }
}

private nonisolated final class TestSummaryProvider: EmailSummaryProviding, @unchecked Sendable {
    private(set) var emailCallCount = 0
    private(set) var emailRequests: [EmailSummaryRequest] = []
    private(set) var folderRequests: [FolderSummaryRequest] = []
    private(set) var events: [String] = []
    private let emailResult: String
    private let folderResult: String
    private let folderError: Error?

    init(emailResult: String,
         folderResult: String = "",
         folderError: Error? = nil) {
        self.emailResult = emailResult
        self.folderResult = folderResult
        self.folderError = folderError
    }

    func summarize(subjects: [String]) async throws -> String {
        ""
    }

    func summarizeEmail(_ request: EmailSummaryRequest) async throws -> String {
        emailCallCount += 1
        emailRequests.append(request)
        events.append("email:\(request.subject)")
        return emailResult
    }

    func summarizeFolder(_ request: FolderSummaryRequest) async throws -> String {
        folderRequests.append(request)
        events.append("folder:\(request.title)")
        if let folderError {
            throw folderError
        }
        return folderResult
    }
}

private enum TestRegenerationError: Error {
    case expectedFolderFailure
    case expectedTitleFailure
}

private actor TestRegenerationGraphTitleProvider: GraphTitleProviding {
    private let result: String
    private let error: Error?
    private(set) var requests: [GraphTitleRequest] = []

    init(result: String = "", error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func makeGraphTitle(_ request: GraphTitleRequest) async throws -> String {
        requests.append(request)
        if let error {
            throw error
        }
        return result
    }
}

private nonisolated func unavailableGraphTitleCapability() -> GraphTitleCapability {
    GraphTitleCapability(provider: nil,
                         statusMessage: "Unavailable for this test",
                         providerID: "test-title-unavailable",
                         shouldRetry: false)
}

private nonisolated func readyGraphTitleCapability(
    provider: any GraphTitleProviding
) -> GraphTitleCapability {
    GraphTitleCapability(provider: provider,
                         statusMessage: "Ready",
                         providerID: "test-title-v2",
                         shouldRetry: false)
}

private actor StubRegenerationService: SummaryRegenerationServicing {
    private let totalCount: Int

    init(totalCount: Int = 0) {
        self.totalCount = totalCount
    }

    func countMessages(in range: DateInterval, mailbox: String?) async throws -> Int {
        totalCount
    }

    func runRegeneration(range: DateInterval,
                         mailbox: String?,
                         preferredBatchSize: Int,
                         totalExpected: Int,
                         snippetLineLimit: Int,
                         stopPhrases: [String],
                         progressHandler: @Sendable (SummaryRegenerationProgress) -> Void) async throws -> SummaryRegenerationResult {
        progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                    completed: 1,
                                                    currentBatchSize: preferredBatchSize,
                                                    state: .running,
                                                    errorMessage: nil))
        progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                    completed: totalExpected,
                                                    currentBatchSize: preferredBatchSize,
                                                    state: .finished,
                                                    errorMessage: nil))
        return SummaryRegenerationResult(total: totalExpected,
                                         regenerated: totalExpected,
                                         graphTitlesRegenerated: totalExpected)
    }
}

private actor WrappedCancellationRegenerationService: SummaryRegenerationServicing {
    private var didStart = false

    func hasStarted() -> Bool {
        didStart
    }

    func countMessages(in range: DateInterval, mailbox: String?) async throws -> Int {
        1
    }

    func runRegeneration(range: DateInterval,
                         mailbox: String?,
                         preferredBatchSize: Int,
                         totalExpected: Int,
                         snippetLineLimit: Int,
                         stopPhrases: [String],
                         progressHandler: @Sendable (SummaryRegenerationProgress) -> Void) async throws -> SummaryRegenerationResult {
        didStart = true
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                break
            }
        }
        throw WrappedCancellationError()
    }
}

private struct WrappedCancellationError: LocalizedError {
    var errorDescription: String? {
        "The operation couldn’t be completed. (Swift.CancellationError error 1.)"
    }
}
