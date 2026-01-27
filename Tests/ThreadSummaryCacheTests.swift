import CoreData
import XCTest
@testable import BetterMail

final class ThreadSummaryCacheTests: XCTestCase {
    func testScopedSummaryCachePersistsAndFetches() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let nodeEntry = SummaryCacheEntry(scope: .emailNode,
                                          scopeID: "node-1",
                                          summaryText: "Cached node summary",
                                          generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                          fingerprint: "fingerprint-a",
                                          provider: "foundation-models")
        let folderEntry = SummaryCacheEntry(scope: .folder,
                                            scopeID: "folder-1",
                                            summaryText: "Cached folder summary",
                                            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                            fingerprint: "fingerprint-b",
                                            provider: "foundation-models")

        try await store.upsertSummaries([nodeEntry, folderEntry])
        let fetchedNodes = try await store.fetchSummaries(scope: .emailNode, ids: [nodeEntry.scopeID])
        let fetchedFolders = try await store.fetchSummaries(scope: .folder, ids: [folderEntry.scopeID])

        XCTAssertEqual(fetchedNodes.count, 1)
        XCTAssertEqual(fetchedNodes.first?.summaryText, nodeEntry.summaryText)
        XCTAssertEqual(fetchedFolders.count, 1)
        XCTAssertEqual(fetchedFolders.first?.summaryText, folderEntry.summaryText)

        try await store.deleteSummaries(scope: .emailNode, ids: [nodeEntry.scopeID])
        let afterDelete = try await store.fetchSummaries(scope: .emailNode, ids: [nodeEntry.scopeID])
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testNodeSummaryFingerprintChangesWhenInputsChange() {
        let base = ThreadSummaryFingerprint.makeNode(subject: "Invoice",
                                                     body: "Paid on Friday",
                                                     priorEntries: [NodeSummaryFingerprintEntry(messageID: "a",
                                                                                                subject: "Invoice",
                                                                                                bodySnippet: "Draft")])
        let changedBody = ThreadSummaryFingerprint.makeNode(subject: "Invoice",
                                                            body: "Paid on Monday",
                                                            priorEntries: [NodeSummaryFingerprintEntry(messageID: "a",
                                                                                                       subject: "Invoice",
                                                                                                       bodySnippet: "Draft")])
        let changedPrior = ThreadSummaryFingerprint.makeNode(subject: "Invoice",
                                                             body: "Paid on Friday",
                                                             priorEntries: [NodeSummaryFingerprintEntry(messageID: "b",
                                                                                                        subject: "Invoice",
                                                                                                        bodySnippet: "Updated")])
        XCTAssertNotEqual(base, changedBody)
        XCTAssertNotEqual(base, changedPrior)
    }

    func testFolderFingerprintChangesWhenEntriesChange() {
        let base = ThreadSummaryFingerprint.makeFolder(nodeEntries: [FolderSummaryFingerprintEntry(nodeID: "a",
                                                                                                   nodeFingerprint: "one")])
        let changed = ThreadSummaryFingerprint.makeFolder(nodeEntries: [FolderSummaryFingerprintEntry(nodeID: "a",
                                                                                                      nodeFingerprint: "two")])
        XCTAssertNotEqual(base, changed)
    }

    @MainActor
    func testNodeSummaryUsesPriorContext() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestSummaryProvider(emailResult: "Generated")
        let capability = EmailSummaryCapability(provider: provider,
                                                statusMessage: "Ready",
                                                providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              store: store,
                                              summaryCapability: capability,
                                              folderSummaryDebounceInterval: 0)

        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messageB = EmailMessage(messageID: "<b>",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "Older",
                                    from: "b@example.com",
                                    to: "me@example.com",
                                    date: calendar.date(byAdding: .day, value: -1, to: now)!,
                                    snippet: "Body B",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let messageA = EmailMessage(messageID: "<a>",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "Latest",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: now,
                                    snippet: "Body A",
                                    isUnread: false,
                                    inReplyTo: messageB.messageID,
                                    references: [messageB.messageID])
        let threader = JWZThreader()
        let result = threader.buildThreads(from: [messageA, messageB])
        guard let root = result.roots.first else {
            XCTFail("Expected a thread root")
            return
        }

        viewModel.applyRethreadResultForTesting(roots: [root])
        try await Task.sleep(nanoseconds: 300_000_000)

        let latestRequest = provider.emailRequests.first { $0.subject == "Latest" }
        XCTAssertNotNil(latestRequest)
        XCTAssertEqual(latestRequest?.priorMessages.first?.subject, "Older")

        let state = viewModel.summaryState(for: root.id)
        XCTAssertNotNil(state)
    }

    @MainActor
    func testCachedNodeSummaryBypassesGenerationOnSecondRun() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestSummaryProvider(emailResult: "Generated")
        let capability = EmailSummaryCapability(provider: provider,
                                                statusMessage: "Ready",
                                                providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              store: store,
                                              summaryCapability: capability,
                                              folderSummaryDebounceInterval: 0)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let message = EmailMessage(messageID: "<a>",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "Latest",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: now,
                                   snippet: "Body",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [])
        let threader = JWZThreader()
        let result = threader.buildThreads(from: [message])
        guard let root = result.roots.first else {
            XCTFail("Expected a thread root")
            return
        }

        viewModel.applyRethreadResultForTesting(roots: [root])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(provider.emailCallCount, 1)

        provider.resetCounts()
        viewModel.applyRethreadResultForTesting(roots: [root])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(provider.emailCallCount, 0)
    }

    @MainActor
    func testNodeSummaryRegeneratesWhenPriorContextChanges() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestSummaryProvider(emailResult: "Generated")
        let capability = EmailSummaryCapability(provider: provider,
                                                statusMessage: "Ready",
                                                providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              store: store,
                                              summaryCapability: capability,
                                              folderSummaryDebounceInterval: 0)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let latest = EmailMessage(messageID: "<a>",
                                  mailboxID: "inbox",
                                  accountName: "",
                                  subject: "Latest",
                                  from: "a@example.com",
                                  to: "me@example.com",
                                  date: now,
                                  snippet: "Body",
                                  isUnread: false,
                                  inReplyTo: nil,
                                  references: [])
        let threader = JWZThreader()
        let firstResult = threader.buildThreads(from: [latest])
        guard let firstRoot = firstResult.roots.first else {
            XCTFail("Expected a thread root")
            return
        }

        viewModel.applyRethreadResultForTesting(roots: [firstRoot])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(provider.emailCallCount, 1)

        let older = EmailMessage(messageID: "<b>",
                                 mailboxID: "inbox",
                                 accountName: "",
                                 subject: "Older",
                                 from: "b@example.com",
                                 to: "me@example.com",
                                 date: Calendar.current.date(byAdding: .day, value: -1, to: now)!,
                                 snippet: "Earlier body",
                                 isUnread: false,
                                 inReplyTo: nil,
                                 references: [])
        let latestWithReply = EmailMessage(messageID: "<a>",
                                           mailboxID: "inbox",
                                           accountName: "",
                                           subject: "Latest",
                                           from: "a@example.com",
                                           to: "me@example.com",
                                           date: now,
                                           snippet: "Body",
                                           isUnread: false,
                                           inReplyTo: older.messageID,
                                           references: [older.messageID])
        let secondResult = threader.buildThreads(from: [latestWithReply, older])
        guard let secondRoot = secondResult.roots.first else {
            XCTFail("Expected a thread root")
            return
        }

        viewModel.applyRethreadResultForTesting(roots: [secondRoot])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(provider.emailCallCount, 3)
    }

    @MainActor
    func testFolderSummaryDebounceCancelsInFlight() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestSummaryProvider(emailResult: "Node summary", folderResult: "Folder summary")
        let capability = EmailSummaryCapability(provider: provider,
                                                statusMessage: "Ready",
                                                providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              store: store,
                                              summaryCapability: capability,
                                              folderSummaryDebounceInterval: 0.1)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messageA = EmailMessage(messageID: "<a>",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "Latest",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: now,
                                    snippet: "Body",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let threader = JWZThreader()
        let result = threader.buildThreads(from: [messageA])
        guard let root = result.roots.first else {
            XCTFail("Expected a thread root")
            return
        }

        let nodeCache = SummaryCacheEntry(scope: .emailNode,
                                          scopeID: root.id,
                                          summaryText: "Node summary",
                                          generatedAt: now,
                                          fingerprint: "node-fingerprint",
                                          provider: "test")
        try await store.upsertSummaries([nodeCache])

        let folderID = "folder-1"
        let effectiveThreadID = root.message.threadID ?? root.id
        let folderA = ThreadFolder(id: folderID,
                                   title: "First",
                                   color: ThreadFolderColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                   threadIDs: Set([effectiveThreadID]),
                                   parentID: nil)
        viewModel.applyRethreadResultForTesting(roots: [root],
                                                folders: [folderA])

        try await Task.sleep(nanoseconds: 50_000_000)

        let folderB = ThreadFolder(id: folderID,
                                   title: "Second",
                                   color: folderA.color,
                                   threadIDs: folderA.threadIDs,
                                   parentID: nil)
        viewModel.applyRethreadResultForTesting(roots: [root],
                                                folders: [folderB])

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(provider.folderCallCount, 1)
        XCTAssertEqual(provider.folderRequests.last?.title, "Second")
        XCTAssertEqual(viewModel.folderSummaryState(for: folderID)?.text, "Folder summary")
    }
}

private final class TestSummaryProvider: EmailSummaryProviding {
    private(set) var emailCallCount = 0
    private(set) var folderCallCount = 0
    private(set) var emailRequests: [EmailSummaryRequest] = []
    private(set) var folderRequests: [FolderSummaryRequest] = []

    private let emailResult: String
    private let folderResult: String

    init(emailResult: String, folderResult: String = "") {
        self.emailResult = emailResult
        self.folderResult = folderResult
    }

    func resetCounts() {
        emailCallCount = 0
        folderCallCount = 0
        emailRequests = []
        folderRequests = []
    }

    func summarize(subjects: [String]) async throws -> String {
        return ""
    }

    func summarizeEmail(_ request: EmailSummaryRequest) async throws -> String {
        emailCallCount += 1
        emailRequests.append(request)
        return emailResult
    }

    func summarizeFolder(_ request: FolderSummaryRequest) async throws -> String {
        folderCallCount += 1
        folderRequests.append(request)
        return folderResult
    }
}
