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
    @Published internal private(set) var estimatedTimeRemainingText: String?
    @Published internal private(set) var isStopping = false
    @Published internal private(set) var errorMessage: String?
    @Published internal private(set) var currentAction: Action?

    private let service: any BatchBackfillServicing
    private let regenerationService: SummaryRegenerationServicing
    private let snippetLineLimitProvider: () -> Int
    private let stopPhrasesProvider: () -> [String]
    private let backfillMailbox: String = "inbox"
    private let regenerationMailbox: String? = nil
    private let defaultBatchSize = 5
    private var runTask: Task<Void, Never>?
    private var lastProgressDate: Date?
    private var lastCompletedCount: Int?
    private var secondsPerMessageSamples: [TimeInterval] = []
    private let logger = Log.refresh
    private static let rangeFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private static let etaFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    internal init(service: any BatchBackfillServicing = BatchBackfillService(),
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

    internal func cancelCurrentRun() {
        guard isRunning else { return }
        isStopping = true
        estimatedTimeRemainingText = nil
        errorMessage = nil
        statusText = NSLocalizedString(stoppingStatusKey(for: currentAction),
                                       comment: "Status while waiting for the current batch operation to stop")
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
                try Task.checkCancellation()
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
                try Task.checkCancellation()

                await MainActor.run {
                    self.isRunning = false
                    self.isStopping = false
                    self.currentAction = nil
                    self.progressValue = total > 0 ? 1.0 : nil
                    self.estimatedTimeRemainingText = nil
                    self.statusText = String.localizedStringWithFormat(
                        NSLocalizedString("settings.backfill.status.finished", comment: "Status after backfill completes"),
                        result.fetched
                    )
                    self.runTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isRunning = false
                    self.isStopping = false
                    self.statusText = NSLocalizedString(self.cancelledStatusKey(for: self.currentAction),
                                                   comment: "Status when the current batch operation is stopped")
                    self.estimatedTimeRemainingText = nil
                    self.errorMessage = nil
                    self.currentAction = nil
                    self.runTask = nil
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.isStopping = false
                    self.estimatedTimeRemainingText = nil
                    self.errorMessage = error.localizedDescription
                    self.statusText = String.localizedStringWithFormat(
                        NSLocalizedString("settings.backfill.status.error", comment: "Status when backfill fails"),
                        error.localizedDescription
                    )
                    self.currentAction = nil
                    self.runTask = nil
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
                try Task.checkCancellation()
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
                try Task.checkCancellation()

                await MainActor.run {
                    self.isRunning = false
                    self.isStopping = false
                    self.currentAction = nil
                    self.progressValue = total > 0 ? 1.0 : nil
                    self.estimatedTimeRemainingText = nil
                    self.statusText = String.localizedStringWithFormat(
                        NSLocalizedString("settings.regenai.status.finished", comment: "Status after Re-GenAI completes"),
                        result.regenerated
                    )
                    self.runTask = nil
                }
                logger.info("RegenAI finished: regenerated=\(result.regenerated, privacy: .public) total=\(total, privacy: .public)")
            } catch is CancellationError {
                await MainActor.run {
                    self.isRunning = false
                    self.isStopping = false
                    self.statusText = NSLocalizedString(self.cancelledStatusKey(for: self.currentAction),
                                                   comment: "Status when the current batch operation is stopped")
                    self.estimatedTimeRemainingText = nil
                    self.errorMessage = nil
                    self.currentAction = nil
                    self.runTask = nil
                }
                logger.info("RegenAI cancelled")
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.isStopping = false
                    self.estimatedTimeRemainingText = nil
                    self.errorMessage = error.localizedDescription
                    self.statusText = String.localizedStringWithFormat(
                        NSLocalizedString("settings.regenai.status.error", comment: "Status when Re-GenAI fails"),
                        error.localizedDescription
                    )
                    self.currentAction = nil
                    self.runTask = nil
                }
                logger.error("RegenAI failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handle(progress: BatchBackfillProgress) {
        guard currentAction == .backfill else { return }
        guard !isStopping else { return }
        totalCount = progress.total
        completedCount = progress.completed
        currentBatchSize = progress.currentBatchSize
        progressValue = progress.total > 0 ? Double(progress.completed) / Double(progress.total) : nil
        updateEstimatedTimeRemaining(completed: progress.completed, total: progress.total)

        switch progress.state {
        case .running:
            statusText = String.localizedStringWithFormat(
                NSLocalizedString("settings.backfill.status.running", comment: "Status while backfill is running"),
                progress.completed,
                progress.total,
                runningDetail(for: progress)
            )
            errorMessage = nil
        case .splitting:
            statusText = String.localizedStringWithFormat(
                NSLocalizedString("settings.backfill.status.splitting", comment: "Status when backfill splits a range into smaller slices"),
                rangeDescription(progress.currentRange),
                progress.rangeMessageCount ?? progress.currentBatchSize,
                BatchBackfillService.maximumFetchCount
            )
            errorMessage = nil
        case .retrying:
            statusText = String.localizedStringWithFormat(
                NSLocalizedString("settings.backfill.status.retry", comment: "Status when backfill retries a slice after an error"),
                rangeDescription(progress.currentRange),
                progress.errorMessage ?? ""
            )
            errorMessage = progress.errorMessage
        case .finished:
            break
        }
    }

    private func handle(regeneration progress: SummaryRegenerationProgress) {
        guard currentAction == .regeneration else { return }
        guard !isStopping else { return }
        totalCount = progress.total
        completedCount = progress.completed
        currentBatchSize = progress.currentBatchSize
        progressValue = progress.total > 0 ? Double(progress.completed) / Double(progress.total) : nil
        updateEstimatedTimeRemaining(completed: progress.completed, total: progress.total)

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
            estimatedTimeRemainingText = nil
            isStopping = false
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
        estimatedTimeRemainingText = nil
        isStopping = false
        currentBatchSize = action == .backfill ? BatchBackfillService.maximumFetchCount : defaultBatchSize
        lastProgressDate = nil
        lastCompletedCount = nil
        secondsPerMessageSamples.removeAll(keepingCapacity: true)
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

    private func runningDetail(for progress: BatchBackfillProgress) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("settings.backfill.status.running.slice", comment: "Detail for the current backfill slice"),
            progress.rangeMessageCount ?? progress.currentBatchSize,
            rangeDescription(progress.currentRange)
        )
    }

    private func rangeDescription(_ range: DateInterval?) -> String {
        guard let range else {
            return NSLocalizedString("settings.backfill.status.range.selected", comment: "Fallback label for the selected backfill range")
        }
        return Self.rangeFormatter.string(from: range.start, to: range.end)
    }

    private func cancelledStatusKey(for action: Action?) -> String {
        switch action {
        case .regeneration:
            return "settings.regenai.status.cancelled"
        case .backfill, .none:
            return "settings.backfill.status.cancelled"
        }
    }

    private func stoppingStatusKey(for action: Action?) -> String {
        switch action {
        case .regeneration:
            return "settings.regenai.status.stopping"
        case .backfill, .none:
            return "settings.backfill.status.stopping"
        }
    }

    private func updateEstimatedTimeRemaining(completed: Int, total: Int) {
        if completed <= 0 || completed >= total {
            estimatedTimeRemainingText = nil
            lastProgressDate = Date()
            lastCompletedCount = completed
            return
        }

        let now = Date()
        defer {
            lastProgressDate = now
            lastCompletedCount = completed
        }

        guard let lastProgressDate, let lastCompletedCount else {
            estimatedTimeRemainingText = nil
            return
        }

        let deltaCompleted = completed - lastCompletedCount
        let deltaSeconds = now.timeIntervalSince(lastProgressDate)
        guard deltaCompleted > 0, deltaSeconds > 0 else { return }

        secondsPerMessageSamples.append(deltaSeconds / Double(deltaCompleted))
        if secondsPerMessageSamples.count > 5 {
            secondsPerMessageSamples.removeFirst(secondsPerMessageSamples.count - 5)
        }

        let averageSecondsPerMessage = secondsPerMessageSamples.reduce(0, +) / Double(secondsPerMessageSamples.count)
        let remainingSeconds = averageSecondsPerMessage * Double(total - completed)
        guard remainingSeconds.isFinite,
              remainingSeconds > 0,
              let formatted = Self.etaFormatter.string(from: remainingSeconds) else {
            estimatedTimeRemainingText = nil
            return
        }

        estimatedTimeRemainingText = String.localizedStringWithFormat(
            NSLocalizedString("settings.batch.eta", comment: "Estimated time remaining label for batch operations"),
            formatted
        )
    }
}
