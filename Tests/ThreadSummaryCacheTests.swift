import CoreData
import XCTest
@testable import BetterMail

final class ThreadSummaryCacheTests: XCTestCase {
    func testThreadSummaryCachePersistsAndFetches() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let entry = ThreadSummaryCacheEntry(threadID: "thread-1",
                                            summaryText: "Cached summary",
                                            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                            fingerprint: "fingerprint-a",
                                            provider: "foundation-models")

        try await store.upsertThreadSummaries([entry])
        let fetched = try await store.fetchThreadSummaries(for: [entry.threadID])

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.summaryText, entry.summaryText)
        XCTAssertEqual(fetched.first?.fingerprint, entry.fingerprint)

        try await store.deleteThreadSummaries(for: [entry.threadID])
        let afterDelete = try await store.fetchThreadSummaries(for: [entry.threadID])
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testThreadSummaryFingerprintChangesWhenInputsChange() {
        let base = ThreadSummaryFingerprint.make(subjects: ["Invoice", "Meeting"],
                                                 messageCount: 2,
                                                 manualGroupID: nil)
        let changedCount = ThreadSummaryFingerprint.make(subjects: ["Invoice", "Meeting"],
                                                         messageCount: 3,
                                                         manualGroupID: nil)
        let changedSubjects = ThreadSummaryFingerprint.make(subjects: ["Invoice", "Follow up"],
                                                            messageCount: 2,
                                                            manualGroupID: nil)
        XCTAssertNotEqual(base, changedCount)
        XCTAssertNotEqual(base, changedSubjects)
    }

    @MainActor
    func testCachedSummaryBypassesGeneration() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestSummaryProvider(result: "Generated")
        let capability = EmailSummaryCapability(provider: provider,
                                                statusMessage: "Ready",
                                                providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              store: store,
                                              summaryCapability: capability)

        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messageA = EmailMessage(messageID: "<a>",
                                    mailboxID: "inbox",
                                    subject: "Latest",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: now,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let messageB = EmailMessage(messageID: "<b>",
                                    mailboxID: "inbox",
                                    subject: "Older",
                                    from: "b@example.com",
                                    to: "me@example.com",
                                    date: calendar.date(byAdding: .day, value: -1, to: now)!,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let threader = JWZThreader()
        let result = threader.buildThreads(from: [messageA, messageB])
        guard let root = result.roots.first else {
            XCTFail("Expected a thread root")
            return
        }
        let subjects = ["Latest", "Older"]
        let cacheKey = root.message.threadID ?? JWZThreader.threadIdentifier(for: root)
        let fingerprint = ThreadSummaryFingerprint.make(subjects: subjects,
                                                        messageCount: 2,
                                                        manualGroupID: nil)
        let cached = ThreadSummaryCacheEntry(threadID: cacheKey,
                                             summaryText: "Cached summary",
                                             generatedAt: now,
                                             fingerprint: fingerprint,
                                             provider: "test")
        try await store.upsertThreadSummaries([cached])

        viewModel.applyRethreadResultForTesting(roots: [root])
        try await Task.sleep(nanoseconds: 200_000_000)

        let state = viewModel.summaryState(for: root.id)
        XCTAssertEqual(state?.text, cached.summaryText)
        XCTAssertEqual(provider.callCount, 0)
    }

    @MainActor
    func testSummaryRegeneratesWhenFingerprintChanges() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestSummaryProvider(result: "Generated")
        let capability = EmailSummaryCapability(provider: provider,
                                                statusMessage: "Ready",
                                                providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              store: store,
                                              summaryCapability: capability)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messageA = EmailMessage(messageID: "<a>",
                                    mailboxID: "inbox",
                                    subject: "Latest",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: now,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let threader = JWZThreader()
        let result = threader.buildThreads(from: [messageA])
        guard let root = result.roots.first else {
            XCTFail("Expected a thread root")
            return
        }
        let cacheKey = root.message.threadID ?? JWZThreader.threadIdentifier(for: root)
        let fingerprint = ThreadSummaryFingerprint.make(subjects: ["Old"],
                                                        messageCount: 1,
                                                        manualGroupID: nil)
        let cached = ThreadSummaryCacheEntry(threadID: cacheKey,
                                             summaryText: "Cached summary",
                                             generatedAt: now,
                                             fingerprint: fingerprint,
                                             provider: "test")
        try await store.upsertThreadSummaries([cached])

        viewModel.applyRethreadResultForTesting(roots: [root])
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(provider.callCount, 1)
        let updated = try await store.fetchThreadSummaries(for: [cacheKey])
        XCTAssertEqual(updated.first?.summaryText, "Generated")
        XCTAssertNotEqual(updated.first?.fingerprint, cached.fingerprint)
    }
}

private final class TestSummaryProvider: EmailSummaryProviding {
    private(set) var callCount = 0
    private let result: String

    init(result: String) {
        self.result = result
    }

    func summarize(subjects: [String]) async throws -> String {
        callCount += 1
        return result
    }
}
