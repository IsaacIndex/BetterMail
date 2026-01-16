import Combine
import Foundation

@MainActor
final class BatchBackfillSettingsViewModel: ObservableObject {
    @Published var startDate: Date
    @Published var endDate: Date
    @Published private(set) var statusText: String = ""
    @Published private(set) var isRunning = false
    @Published private(set) var progressValue: Double?
    @Published private(set) var totalCount: Int?
    @Published private(set) var completedCount: Int = 0
    @Published private(set) var currentBatchSize: Int = 5
    @Published private(set) var errorMessage: String?

    private let service: BatchBackfillService
    private let snippetLineLimitProvider: () -> Int
    private let mailbox: String = "inbox"
    private let defaultBatchSize = 5
    private var runTask: Task<Void, Never>?

    init(service: BatchBackfillService = BatchBackfillService(),
         snippetLineLimitProvider: @escaping () -> Int = { InspectorViewSettings.defaultSnippetLineLimit },
         calendar: Calendar = .current) {
        self.service = service
        self.snippetLineLimitProvider = snippetLineLimitProvider
        let now = Date()
        let startOfYear = calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 1, day: 1)) ?? now
        self.startDate = startOfYear
        self.endDate = now
    }

    deinit {
        runTask?.cancel()
    }

    func startBackfill() {
        guard !isRunning else { return }
        runTask?.cancel()
        errorMessage = nil
        isRunning = true
        statusText = NSLocalizedString("settings.backfill.status.counting", comment: "Status while counting messages for backfill")
        totalCount = nil
        completedCount = 0
        progressValue = nil
        currentBatchSize = defaultBatchSize

        let orderedRange = startDate <= endDate
            ? DateInterval(start: startDate, end: endDate)
            : DateInterval(start: endDate, end: startDate)
        let snippetLimit = snippetLineLimitProvider()

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let total = try await service.countMessages(in: orderedRange, mailbox: mailbox)
                await handleCountResult(total)
                guard total > 0 else { return }

                let result = try await service.runBackfill(range: orderedRange,
                                                           mailbox: mailbox,
                                                           preferredBatchSize: defaultBatchSize,
                                                           totalExpected: total,
                                                           snippetLineLimit: snippetLimit) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.handle(progress: progress)
                    }
                }

                await MainActor.run {
                    isRunning = false
                    progressValue = total > 0 ? 1.0 : nil
                    statusText = String.localizedStringWithFormat(
                        NSLocalizedString("settings.backfill.status.finished", comment: "Status after backfill completes"),
                        result.fetched
                    )
                    runTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    isRunning = false
                    runTask = nil
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    errorMessage = error.localizedDescription
                    statusText = String.localizedStringWithFormat(
                        NSLocalizedString("settings.backfill.status.error", comment: "Status when backfill fails"),
                        error.localizedDescription
                    )
                    runTask = nil
                }
            }
        }
    }

    private func handle(progress: BatchBackfillProgress) {
        totalCount = progress.total
        completedCount = progress.completed
        currentBatchSize = progress.currentBatchSize
        progressValue = progress.total > 0 ? Double(progress.completed) / Double(progress.total) : nil

        switch progress.state {
        case .running:
            statusText = String.localizedStringWithFormat(
                NSLocalizedString("settings.backfill.status.running", comment: "Status while backfill is running"),
                progress.completed,
                progress.total,
                progress.currentBatchSize
            )
        case .retrying:
            statusText = String.localizedStringWithFormat(
                NSLocalizedString("settings.backfill.status.retry", comment: "Status when backfill retries with smaller batch"),
                progress.currentBatchSize,
                progress.errorMessage ?? ""
            )
            errorMessage = progress.errorMessage
        case .finished:
            break
        }
    }

    private func handleCountResult(_ total: Int) async {
        await MainActor.run {
            totalCount = total
            completedCount = 0
            progressValue = total > 0 ? 0 : nil
            if total == 0 {
                isRunning = false
                statusText = NSLocalizedString("settings.backfill.status.empty", comment: "Status when no messages are found for backfill")
                runTask = nil
            } else {
                statusText = String.localizedStringWithFormat(
                    NSLocalizedString("settings.backfill.status.counted", comment: "Status after counting messages for backfill"),
                    total
                )
            }
        }
    }
}
