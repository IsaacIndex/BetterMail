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
        let service = SummaryRegenerationService(store: store) {
            EmailSummaryCapability(provider: provider,
                                   statusMessage: "Ready",
                                   providerID: "test")
        }

        let range = DateInterval(start: Calendar.current.date(byAdding: .day, value: -10, to: now)!,
                                 end: now)
        let total = try await service.countMessages(in: range, mailbox: "inbox")
        XCTAssertEqual(total, 7)

        var progressEvents: [SummaryRegenerationProgress] = []
        let result = try await service.runRegeneration(range: range,
                                                       mailbox: "inbox",
                                                       preferredBatchSize: 3,
                                                       totalExpected: total,
                                                       snippetLineLimit: 4,
                                                       stopPhrases: []) { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(result.regenerated, 7)
        XCTAssertEqual(provider.emailCallCount, 7)
        XCTAssertEqual(progressEvents.last?.state, .finished)
        XCTAssertEqual(progressEvents.last?.completed, 7)
    }

    @MainActor
    func testRegenerationStatusMappingInViewModel() async throws {
        let regenService = StubRegenerationService()
        regenService.totalCount = 2

        let viewModel = BatchBackfillSettingsViewModel(regenerationService: regenService,
                                                       snippetLineLimitProvider: { 2 },
                                                       stopPhrasesProvider: { [] })
        viewModel.startRegeneration()

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(viewModel.totalCount, 2)
        XCTAssertEqual(viewModel.completedCount, 2)
        XCTAssertEqual(viewModel.statusText,
                       String.localizedStringWithFormat(
                        NSLocalizedString("settings.regenai.status.finished", comment: ""),
                        2
                       ))
    }
}

private final class TestSummaryProvider: EmailSummaryProviding {
    private(set) var emailCallCount = 0
    private let emailResult: String

    init(emailResult: String) {
        self.emailResult = emailResult
    }

    func summarize(subjects: [String]) async throws -> String {
        ""
    }

    func summarizeEmail(_ request: EmailSummaryRequest) async throws -> String {
        emailCallCount += 1
        return emailResult
    }

    func summarizeFolder(_ request: FolderSummaryRequest) async throws -> String {
        ""
    }
}

private actor StubRegenerationService: SummaryRegenerationServicing {
    var totalCount: Int = 0

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
        return SummaryRegenerationResult(total: totalExpected, regenerated: totalExpected)
    }
}
