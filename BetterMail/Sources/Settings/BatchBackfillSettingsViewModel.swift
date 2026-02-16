import Combine
import Foundation
import OSLog

@MainActor
internal final class BatchBackfillSettingsViewModel: ObservableObject {
    internal enum Action {
        case backfill
        case regeneration
    }

    @Published internal var startDate: Date
    @Published internal var endDate: Date
    @Published internal private(set) var statusText: String = ""
    @Published internal private(set) var isRunning = false
    @Published internal private(set) var progressValue: Double?
    @Published internal private(set) var totalCount: Int?
    @Published internal private(set) var completedCount: Int = 0
    @Published internal private(set) var currentBatchSize: Int = 5
    @Published internal private(set) var errorMessage: String?
    @Published internal private(set) var currentAction: Action?

    private let service: BatchBackfillService
    private let regenerationService: SummaryRegenerationServicing
    private let snippetLineLimitProvider: () -> Int
    private let stopPhrasesProvider: () -> [String]
    private let backfillMailbox: String = "inbox"
    private let regenerationMailbox: String? = nil
    private let defaultBatchSize = 5
    private var runTask: Task<Void, Never>?
    private let logger = Log.refresh

    internal init(service: BatchBackfillService = BatchBackfillService(),
                  regenerationService: SummaryRegenerationServicing = SummaryRegenerationService(),
                  snippetLineLimitProvider: @escaping () -> Int = { InspectorViewSettings.defaultSnippetLineLimit },
                  stopPhrasesProvider: @escaping () -> [String] = { [] },
                  calendar: Calendar = .current) {
        self.service = service
        self.regenerationService = regenerationService
        self.snippetLineLimitProvider = snippetLineLimitProvider
        self.stopPhrasesProvider = stopPhrasesProvider
        let now = Date()
        let startOfYear = calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 1, day: 1)) ?? now
        self.startDate = startOfYear
        self.endDate = now
    }

    deinit {
        runTask?.cancel()
    }

    internal func startBackfill() {
        guard !isRunning else { return }
        runTask?.cancel()
        prepareForRun(action: .backfill)

        let orderedRange = startDate <= endDate
            ? DateInterval(start: startDate, end: endDate)
            : DateInterval(start: endDate, end: startDate)
        let snippetLimit = snippetLineLimitProvider()

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let backfillAccount: String? = nil
                let total = try await service.countMessages(in: orderedRange,
                                                            mailbox: backfillMailbox,
                                                            account: backfillAccount)
                await handleCountResult(total)
                guard total > 0 else { return }

                let result = try await service.runBackfill(range: orderedRange,
                                                           mailbox: backfillMailbox,
                                                           account: backfillAccount,
                                                           preferredBatchSize: defaultBatchSize,
                                                           totalExpected: total,
                                                           snippetLineLimit: snippetLimit) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.handle(progress: progress)
                    }
                }

                await MainActor.run {
                    isRunning = false
                    currentAction = nil
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
                    currentAction = nil
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
                    currentAction = nil
                    runTask = nil
                }
            }
        }
    }

    internal func startRegeneration() {
        guard !isRunning else { return }
        runTask?.cancel()
        prepareForRun(action: .regeneration)

        let orderedRange = startDate <= endDate
            ? DateInterval(start: startDate, end: endDate)
            : DateInterval(start: endDate, end: startDate)
        let snippetLimit = snippetLineLimitProvider()
        let stopPhrases = stopPhrasesProvider()

        let mailboxLabel = regenerationMailbox ?? "all-mailboxes"
        logger.info("RegenAI start: mailbox=\(mailboxLabel, privacy: .public) rangeStart=\(orderedRange.start, privacy: .private) rangeEnd=\(orderedRange.end, privacy: .private) snippetLimit=\(snippetLimit, privacy: .public) stopPhrases=\(stopPhrases.count, privacy: .public)")

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let total = try await regenerationService.countMessages(in: orderedRange, mailbox: regenerationMailbox)
                logger.info("RegenAI count: total=\(total, privacy: .public) mailbox=\(mailboxLabel, privacy: .public)")
                await handleCountResult(total)
                guard total > 0 else { return }

                let result = try await regenerationService.runRegeneration(range: orderedRange,
                                                                           mailbox: regenerationMailbox,
                                                                           preferredBatchSize: defaultBatchSize,
                                                                           totalExpected: total,
                                                                           snippetLineLimit: snippetLimit,
                                                                           stopPhrases: stopPhrases) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.handle(regeneration: progress)
                    }
                }

                await MainActor.run {
                    isRunning = false
                    currentAction = nil
                    progressValue = total > 0 ? 1.0 : nil
                    statusText = String.localizedStringWithFormat(
                        NSLocalizedString("settings.regenai.status.finished", comment: "Status after Re-GenAI completes"),
                        result.regenerated
                    )
                    runTask = nil
                }
                logger.info("RegenAI finished: regenerated=\(result.regenerated, privacy: .public) total=\(total, privacy: .public)")
            } catch is CancellationError {
                await MainActor.run {
                    isRunning = false
                    currentAction = nil
                    runTask = nil
                }
                logger.info("RegenAI cancelled")
            } catch {
                await MainActor.run {
                    isRunning = false
                    errorMessage = error.localizedDescription
                    statusText = String.localizedStringWithFormat(
                        NSLocalizedString("settings.regenai.status.error", comment: "Status when Re-GenAI fails"),
                        error.localizedDescription
                    )
                    currentAction = nil
                    runTask = nil
                }
                logger.error("RegenAI failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handle(progress: BatchBackfillProgress) {
        guard currentAction == .backfill else { return }
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

    private func handle(regeneration progress: SummaryRegenerationProgress) {
        guard currentAction == .regeneration else { return }
        totalCount = progress.total
        completedCount = progress.completed
        currentBatchSize = progress.currentBatchSize
        progressValue = progress.total > 0 ? Double(progress.completed) / Double(progress.total) : nil

        switch progress.state {
        case .running:
            statusText = String.localizedStringWithFormat(
                NSLocalizedString("settings.regenai.status.running", comment: "Status while Re-GenAI is running"),
                progress.completed,
                progress.total,
                progress.currentBatchSize
            )
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
                let action = currentAction
                let orderedRange = startDate <= endDate
                    ? DateInterval(start: startDate, end: endDate)
                    : DateInterval(start: endDate, end: startDate)
                isRunning = false
                statusText = NSLocalizedString(statusKey(for: .empty),
                                               comment: "Status when no messages are found for the selected range")
                currentAction = nil
                runTask = nil
                logger.info("Backfill/Regen count empty: action=\(String(describing: action), privacy: .public) rangeStart=\(orderedRange.start, privacy: .private) rangeEnd=\(orderedRange.end, privacy: .private)")
            } else {
                statusText = String.localizedStringWithFormat(
                    NSLocalizedString(statusKey(for: .counted),
                                      comment: "Status after counting messages for the selected action"),
                    total
                )
            }
        }
    }

    private func prepareForRun(action: Action) {
        errorMessage = nil
        isRunning = true
        currentAction = action
        statusText = NSLocalizedString(statusKey(for: .counting),
                                       comment: "Status while counting messages for the selected action")
        totalCount = nil
        completedCount = 0
        progressValue = nil
        currentBatchSize = defaultBatchSize
    }

    internal var progressAccessibilityLabel: String {
        switch currentAction {
        case .regeneration:
            return NSLocalizedString("settings.regenai.accessibility.progress",
                                     comment: "Accessibility label for Re-GenAI progress")
        case .backfill:
            return NSLocalizedString("settings.backfill.accessibility.progress",
                                     comment: "Accessibility label for backfill progress")
        case .none:
            return NSLocalizedString("settings.backfill.accessibility.progress",
                                     comment: "Accessibility label for backfill progress")
        }
    }

    private enum StatusKey {
        case counting
        case counted
        case running
        case empty
    }

    private func statusKey(for key: StatusKey) -> String {
        let prefix: String
        switch currentAction {
        case .regeneration:
            prefix = "settings.regenai.status"
        case .backfill, .none:
            prefix = "settings.backfill.status"
        }
        switch key {
        case .counting:
            return "\(prefix).counting"
        case .counted:
            return "\(prefix).counted"
        case .running:
            return "\(prefix).running"
        case .empty:
            return "\(prefix).empty"
        }
    }
}
