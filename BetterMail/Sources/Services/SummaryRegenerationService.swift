import Foundation
import OSLog

internal struct SummaryRegenerationProgress {
    internal enum State {
        case running
        case finished
    }

    internal let total: Int
    internal let completed: Int
    internal let currentBatchSize: Int
    internal let state: State
    internal let errorMessage: String?
}

internal struct SummaryRegenerationResult {
    internal let total: Int
    internal let regenerated: Int
}

internal protocol SummaryRegenerationServicing {
    func countMessages(in range: DateInterval, mailbox: String?) async throws -> Int
    func runRegeneration(range: DateInterval,
                         mailbox: String?,
                         preferredBatchSize: Int,
                         totalExpected: Int,
                         snippetLineLimit: Int,
                         stopPhrases: [String],
                         progressHandler: @Sendable (SummaryRegenerationProgress) -> Void) async throws -> SummaryRegenerationResult
}

internal actor SummaryRegenerationService: SummaryRegenerationServicing {
    private struct NodeSummaryInput {
        let messageID: String
        let subject: String
        let body: String
        let priorMessages: [EmailSummaryContextEntry]
        let fingerprint: String
    }

    private struct FolderSummaryInput {
        let folderID: String
        let title: String
        let summaryTexts: [String]
        let fingerprint: String
    }

    private let store: MessageStore
    private let capabilityProvider: () -> EmailSummaryCapability
    private let logger = Log.refresh

    internal init(store: MessageStore = .shared,
                  capabilityProvider: @escaping () -> EmailSummaryCapability = { EmailSummaryProviderFactory.makeCapability() }) {
        self.store = store
        self.capabilityProvider = capabilityProvider
    }

    internal func countMessages(in range: DateInterval, mailbox: String?) async throws -> Int {
        let now = Date()
        if range.start > now {
            let mailboxLabel = mailbox ?? "all-mailboxes"
            logger.info("RegenAI count: rangeStart in future; mailbox=\(mailboxLabel, privacy: .public) rangeStart=\(range.start, privacy: .private) now=\(now, privacy: .private)")
            return 0
        }
        let clampedStart = min(range.start, now)
        let clampedEnd = min(range.end, now)
        let clampedRange = DateInterval(start: clampedStart, end: clampedEnd)
        let mailboxLabel = mailbox ?? "all-mailboxes"
        logger.info("RegenAI count: mailbox=\(mailboxLabel, privacy: .public) rangeStart=\(range.start, privacy: .private) rangeEnd=\(range.end, privacy: .private) clampedStart=\(clampedStart, privacy: .private) clampedEnd=\(clampedEnd, privacy: .private)")
        return try await store.countMessages(in: clampedRange, mailbox: mailbox)
    }

    internal func runRegeneration(range: DateInterval,
                                  mailbox: String?,
                                  preferredBatchSize: Int,
                                  totalExpected: Int,
                                  snippetLineLimit: Int,
                                  stopPhrases: [String],
                                  progressHandler: @Sendable (SummaryRegenerationProgress) -> Void) async throws -> SummaryRegenerationResult {
        let capability = capabilityProvider()
        guard let provider = capability.provider else {
            logger.error("RegenAI run: provider unavailable; status=\(capability.statusMessage, privacy: .public)")
            throw EmailSummaryError.unavailable(capability.statusMessage)
        }

        let now = Date()
        if range.start > now || totalExpected == 0 {
            logger.info("RegenAI run: early exit; totalExpected=\(totalExpected, privacy: .public) rangeStart=\(range.start, privacy: .private) now=\(now, privacy: .private)")
            progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                        completed: 0,
                                                        currentBatchSize: max(1, preferredBatchSize),
                                                        state: .finished,
                                                        errorMessage: nil))
            return SummaryRegenerationResult(total: totalExpected, regenerated: 0)
        }

        let clampedStart = min(range.start, now)
        let clampedEnd = min(range.end, now)
        let clampedRange = DateInterval(start: clampedStart, end: clampedEnd)
        let mailboxLabel = mailbox ?? "all-mailboxes"
        logger.info("RegenAI run: mailbox=\(mailboxLabel, privacy: .public) totalExpected=\(totalExpected, privacy: .public) preferredBatchSize=\(preferredBatchSize, privacy: .public) rangeStart=\(range.start, privacy: .private) rangeEnd=\(range.end, privacy: .private) clampedStart=\(clampedStart, privacy: .private) clampedEnd=\(clampedEnd, privacy: .private)")

        var completed = 0
        var batchSize = max(1, preferredBatchSize)
        var offset = 0

        while completed < totalExpected {
            let messages = try await store.fetchMessages(in: clampedRange,
                                                         mailbox: mailbox,
                                                         limit: batchSize,
                                                         offset: offset)
            guard !messages.isEmpty else {
                logger.info("RegenAI run: no messages from store; completed=\(completed, privacy: .public) totalExpected=\(totalExpected, privacy: .public) offset=\(offset, privacy: .public) batchSize=\(batchSize, privacy: .public)")
                break
            }

            let inputs = Self.nodeSummaryInputs(from: messages,
                                                snippetLineLimit: snippetLineLimit,
                                                stopPhrases: stopPhrases)
            for input in inputs {
                do {
                    let request = EmailSummaryRequest(subject: input.subject,
                                                      body: input.body,
                                                      priorMessages: input.priorMessages)
                    let text = try await provider.summarizeEmail(request)
                    let entry = SummaryCacheEntry(scope: .emailNode,
                                                  scopeID: input.messageID,
                                                  summaryText: text,
                                                  generatedAt: Date(),
                                                  fingerprint: input.fingerprint,
                                                  provider: capability.providerID)
                    try await store.upsertSummaries([entry])
                } catch {
                    progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                                completed: completed,
                                                                currentBatchSize: batchSize,
                                                                state: .finished,
                                                                errorMessage: error.localizedDescription))
                    throw error
                }
                completed += 1
                progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                            completed: completed,
                                                            currentBatchSize: batchSize,
                                                            state: .running,
                                                            errorMessage: nil))
            }

            let skipped = messages.count - inputs.count
            if skipped > 0 {
                completed += skipped
                progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                            completed: completed,
                                                            currentBatchSize: batchSize,
                                                            state: .running,
                                                            errorMessage: nil))
            }

            try await refreshFolderSummaries(using: provider,
                                             providerID: capability.providerID,
                                             messages: messages)
            offset += messages.count
        }

        progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                    completed: completed,
                                                    currentBatchSize: batchSize,
                                                    state: .finished,
                                                    errorMessage: nil))
        return SummaryRegenerationResult(total: totalExpected, regenerated: completed)
    }

    private func refreshFolderSummaries(using provider: EmailSummaryProviding,
                                        providerID: String,
                                        messages: [EmailMessage]) async throws {
        let threadIDs = Set(messages.compactMap { $0.threadID ?? $0.threadKey })
        guard !threadIDs.isEmpty else { return }

        let folders = try await store.fetchThreadFolders()
        let touchedFolders = folders.filter { folder in
            !folder.threadIDs.isDisjoint(with: threadIDs)
        }
        guard !touchedFolders.isEmpty else { return }

        let touchedThreadIDs = touchedFolders.reduce(into: Set<String>()) { result, folder in
            result.formUnion(folder.threadIDs)
        }
        let folderMessages = try await store.fetchMessages(threadIDs: touchedThreadIDs)
        guard !folderMessages.isEmpty else { return }

        let nodeIDs = Set(folderMessages.map(\.messageID))
        let cachedNodes = try await store.fetchSummaries(scope: .emailNode, ids: Array(nodeIDs))
        let cachedByID = Dictionary(uniqueKeysWithValues: cachedNodes.map { ($0.scopeID, $0) })

        let inputs = Self.folderSummaryInputs(for: touchedFolders,
                                              messages: folderMessages,
                                              cachedNodeSummaries: cachedByID)

        for input in inputs {
            let request = FolderSummaryRequest(title: input.title,
                                               messageSummaries: input.summaryTexts)
            let text = try await provider.summarizeFolder(request)
            let entry = SummaryCacheEntry(scope: .folder,
                                          scopeID: input.folderID,
                                          summaryText: text,
                                          generatedAt: Date(),
                                          fingerprint: input.fingerprint,
                                          provider: providerID)
            try await store.upsertSummaries([entry])
        }
    }

    private static func nodeSummaryInputs(from messages: [EmailMessage],
                                          snippetLineLimit: Int,
                                          stopPhrases: [String]) -> [NodeSummaryInput] {
        let formatter = SnippetFormatter(lineLimit: snippetLineLimit,
                                         stopPhrases: stopPhrases)
        let grouped = Dictionary(grouping: messages) { message in
            message.threadID ?? message.threadKey
        }

        var inputs: [NodeSummaryInput] = []
        inputs.reserveCapacity(messages.count)

        for (_, threadMessages) in grouped {
            let sorted = threadMessages.sorted {
                if $0.date == $1.date {
                    return $0.messageID < $1.messageID
                }
                return $0.date < $1.date
            }
            var priorEntries: [EmailSummaryContextEntry] = []
            priorEntries.reserveCapacity(sorted.count)

            for message in sorted {
                let subject = normalizedText(message.subject, maxCharacters: 140)
                let body = normalizedText(formatter.format(message.snippet), maxCharacters: 600)
                let priorContext = Array(priorEntries.suffix(8))
                if !subject.isEmpty || !body.isEmpty {
                    let fingerprintEntries = priorContext.map {
                        NodeSummaryFingerprintEntry(messageID: $0.messageID,
                                                    subject: $0.subject,
                                                    bodySnippet: $0.bodySnippet)
                    }
                    let fingerprint = ThreadSummaryFingerprint.makeNode(subject: subject,
                                                                        body: body,
                                                                        priorEntries: fingerprintEntries)
                    inputs.append(NodeSummaryInput(messageID: message.messageID,
                                                   subject: subject,
                                                   body: body,
                                                   priorMessages: priorContext,
                                                   fingerprint: fingerprint))
                }

                let priorSnippet = normalizedText(formatter.format(message.snippet), maxCharacters: 220)
                if !subject.isEmpty || !priorSnippet.isEmpty {
                    priorEntries.append(EmailSummaryContextEntry(messageID: message.messageID,
                                                                 subject: subject,
                                                                 bodySnippet: priorSnippet))
                }
            }
        }

        return inputs
    }

    private static func folderSummaryInputs(for folders: [ThreadFolder],
                                            messages: [EmailMessage],
                                            cachedNodeSummaries: [String: SummaryCacheEntry]) -> [FolderSummaryInput] {
        var messagesByThreadID: [String: [EmailMessage]] = [:]
        messagesByThreadID.reserveCapacity(messages.count)
        for message in messages {
            let threadID = message.threadID ?? message.threadKey
            messagesByThreadID[threadID, default: []].append(message)
        }

        var inputs: [FolderSummaryInput] = []
        inputs.reserveCapacity(folders.count)

        for folder in folders {
            let folderMessages = folder.threadIDs
                .compactMap { messagesByThreadID[$0] }
                .flatMap { $0 }
            let sortedMessages = folderMessages.sorted {
                if $0.date == $1.date {
                    return $0.messageID < $1.messageID
                }
                return $0.date > $1.date
            }
            let limitedMessages = sortedMessages.prefix(20)
            let summaryTexts = limitedMessages.compactMap { message in
                cachedNodeSummaries[message.messageID]?.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }

            let fingerprintEntries = limitedMessages.map { message in
                FolderSummaryFingerprintEntry(nodeID: message.messageID,
                                              nodeFingerprint: cachedNodeSummaries[message.messageID]?.fingerprint ?? "missing")
            }
            let fingerprint = ThreadSummaryFingerprint.makeFolder(nodeEntries: fingerprintEntries)

            inputs.append(FolderSummaryInput(folderID: folder.id,
                                             title: folder.title,
                                             summaryTexts: Array(summaryTexts.prefix(20)),
                                             fingerprint: fingerprint))
        }

        return inputs
    }

    private static func normalizedText(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maxCharacters else { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxCharacters)
        return String(collapsed[..<endIndex]) + "…"
    }
}
