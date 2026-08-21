import Foundation
import OSLog

internal extension Notification.Name {
    /// Published only after a batch Re-GenAI run has committed its requested
    /// node summaries and semantic titles and refreshed affected Group summaries.
    static let summaryRegenerationDidComplete = Notification.Name(
        "SummaryRegenerationService.summaryRegenerationDidComplete"
    )
}

internal nonisolated struct SummaryRegenerationProgress: Sendable {
    internal nonisolated enum State: Sendable {
        case running
        case finished
    }

    internal let total: Int
    internal let completed: Int
    internal let currentBatchSize: Int
    internal let state: State
    internal let errorMessage: String?
}

internal nonisolated struct SummaryRegenerationResult: Sendable {
    internal let total: Int
    internal let regenerated: Int
    internal let graphTitlesRegenerated: Int

    internal init(total: Int,
                  regenerated: Int,
                  graphTitlesRegenerated: Int = 0) {
        self.total = total
        self.regenerated = regenerated
        self.graphTitlesRegenerated = graphTitlesRegenerated
    }
}

internal nonisolated protocol SummaryRegenerationServicing: Sendable {
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
    private struct FolderSummaryInput {
        let folderID: String
        let title: String
        let summaryTexts: [String]
        let fingerprint: String
    }

    private let store: MessageStore
    private let threader: JWZThreader
    private let graphTitleCapabilityProvider: @Sendable () -> GraphTitleCapability
    private let capabilityProvider: @Sendable () -> EmailSummaryCapability
    private let logger = Log.refresh

    internal init(store: MessageStore = .shared,
                  threader: JWZThreader = JWZThreader(),
                  graphTitleCapabilityProvider: @escaping @Sendable () -> GraphTitleCapability = { GraphTitleProviderFactory.makeCapability() },
                  capabilityProvider: @escaping @Sendable () -> EmailSummaryCapability = { EmailSummaryProviderFactory.makeCapability() }) {
        self.store = store
        self.threader = threader
        self.graphTitleCapabilityProvider = graphTitleCapabilityProvider
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
        let graphTitleCapability = graphTitleCapabilityProvider()
        let graphTitleProvider = graphTitleCapability.provider

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

        let targetMessages = try await store.fetchMessages(in: clampedRange, mailbox: mailbox)
        guard !targetMessages.isEmpty else {
            progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                        completed: 0,
                                                        currentBatchSize: max(1, preferredBatchSize),
                                                        state: .finished,
                                                        errorMessage: nil))
            return SummaryRegenerationResult(total: totalExpected, regenerated: 0)
        }
        guard let graphTitleProvider else {
            logger.error("RegenAI run: semantic-title provider unavailable; status=\(graphTitleCapability.statusMessage, privacy: .public)")
            throw EmailSummaryError.unavailable(graphTitleCapability.statusMessage)
        }

        // Hydrate the complete effective-thread graph so messages at a range
        // boundary still receive their true immediate neighbours. Only the
        // target range is written below.
        let allMessages = try await store.fetchMessages()
        let baseResult = threader.buildThreads(from: allMessages)
        let manualGroups = try await store.fetchManualThreadGroups()
        let appliedResult = threader.applyManualGroups(manualGroups, to: baseResult).result
        let build = Self.nodeSummaryBuild(from: appliedResult,
                                          snippetLineLimit: snippetLineLimit,
                                          stopPhrases: stopPhrases,
                                          providerID: capability.providerID)
        let targetMessageIDs = Set(targetMessages.map(\.messageID))
        let targetInputs = build.inputsByNodeID.values
            .filter { targetMessageIDs.contains($0.cacheKey) }
            .sorted {
                if $0.effectiveThreadID == $1.effectiveThreadID {
                    return $0.request.threadContext.position < $1.request.threadContext.position
                }
                return $0.effectiveThreadID < $1.effectiveThreadID
            }

        var completed = max(0, targetMessages.count - targetInputs.count)
        var regenerated = 0
        var graphTitlesRegenerated = 0
        let batchSize = max(1, preferredBatchSize)
        var didCommitNodeSummaries = false
        defer {
            if didCommitNodeSummaries {
                // Node batches are durable before Group refresh begins. Make
                // active Graph state observe those generations even if a
                // later node batch or Group summary fails.
                NotificationCenter.default.post(name: .summaryRegenerationDidComplete,
                                                object: store)
            }
        }
        for start in stride(from: 0, to: targetInputs.count, by: batchSize) {
            let end = min(start + batchSize, targetInputs.count)
            let batch = Array(targetInputs[start..<end])
            var entries: [SummaryCacheEntry] = []
            entries.reserveCapacity(batch.count * 2)
            var batchTitleCount = 0
            do {
                for input in batch {
                    try Task.checkCancellation()
                    let text = try await provider.summarizeEmail(input.request)
                    let summaryEntry = SummaryCacheEntry(scope: .emailNode,
                                                         scopeID: input.cacheKey,
                                                         summaryText: text,
                                                         generatedAt: Date(),
                                                         fingerprint: input.fingerprint,
                                                         provider: capability.providerID)
                    entries.append(summaryEntry)

                    guard let threadRevision = build.threadRevisionsByThreadID[input.effectiveThreadID] else {
                        throw EmailSummaryError.unavailable("The effective thread context could not be prepared for title generation.")
                    }
                    let titleInput = GraphTitleGenerationInputBuilder.make(
                        nodeInput: input,
                        summary: text,
                        summaryGenerationID: summaryEntry.generationID,
                        threadRevision: threadRevision,
                        providerID: graphTitleCapability.providerID
                    )
                    let generatedTitle = try await graphTitleProvider.makeGraphTitle(titleInput.request)
                    let title = GraphTitleFormatter.normalizedGeneratedTitle(
                        generatedTitle,
                        fallback: titleInput.request.subject
                    )
                    entries.append(SummaryCacheEntry(scope: .graphTitle,
                                                     scopeID: titleInput.nodeID,
                                                     summaryText: title,
                                                     generatedAt: Date(),
                                                     fingerprint: titleInput.fingerprint,
                                                     provider: graphTitleCapability.providerID))
                    batchTitleCount += 1
                }
                try Task.checkCancellation()
                try await store.upsertSummaries(entries)
                didCommitNodeSummaries = true
                completed += batch.count
                regenerated += batch.count
                graphTitlesRegenerated += batchTitleCount
                progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                            completed: completed,
                                                            currentBatchSize: batchSize,
                                                            state: .running,
                                                            errorMessage: nil))
            } catch {
                progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                            completed: completed,
                                                            currentBatchSize: batchSize,
                                                            state: .finished,
                                                            errorMessage: error.localizedDescription))
                throw error
            }
        }

        let touchedThreadIDs = Set(targetInputs.map(\.effectiveThreadID))
        let effectiveMessages = appliedResult.roots.flatMap(Self.flattenMessages)
        let effectiveThreadIDByMessageID = Dictionary(
            uniqueKeysWithValues: build.inputsByNodeID.values.map { ($0.cacheKey, $0.effectiveThreadID) }
        )
        try await refreshFolderSummaries(using: provider,
                                         providerID: capability.providerID,
                                         touchedThreadIDs: touchedThreadIDs,
                                         messages: effectiveMessages,
                                         effectiveThreadIDByMessageID: effectiveThreadIDByMessageID)

        progressHandler(SummaryRegenerationProgress(total: totalExpected,
                                                    completed: completed,
                                                    currentBatchSize: batchSize,
                                                    state: .finished,
                                                    errorMessage: nil))
        return SummaryRegenerationResult(total: totalExpected,
                                         regenerated: regenerated,
                                         graphTitlesRegenerated: graphTitlesRegenerated)
    }

    private func refreshFolderSummaries(using provider: EmailSummaryProviding,
                                        providerID: String,
                                        touchedThreadIDs: Set<String>,
                                        messages: [EmailMessage],
                                        effectiveThreadIDByMessageID: [String: String]) async throws {
        guard !touchedThreadIDs.isEmpty else { return }

        let folders = try await store.fetchThreadFolders()
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let threadIDsByFolder = Self.folderThreadIDsByFolder(folders: folders)
        let touchedFolders = folders
            .filter { folder in
                !(threadIDsByFolder[folder.id] ?? []).isDisjoint(with: touchedThreadIDs)
            }
            .sorted {
                let lhsDepth = Self.folderDepth($0, foldersByID: foldersByID)
                let rhsDepth = Self.folderDepth($1, foldersByID: foldersByID)
                if lhsDepth == rhsDepth { return $0.id < $1.id }
                return lhsDepth > rhsDepth
            }
        guard !touchedFolders.isEmpty else { return }

        let includedThreadIDs = touchedFolders.reduce(into: Set<String>()) { result, folder in
            result.formUnion(threadIDsByFolder[folder.id] ?? [])
        }
        let folderMessages = messages.filter {
            guard let effectiveThreadID = effectiveThreadIDByMessageID[$0.messageID] else { return false }
            return includedThreadIDs.contains(effectiveThreadID)
        }
        guard !folderMessages.isEmpty else { return }

        let nodeIDs = Set(folderMessages.map(\.messageID))
        let cachedNodes = try await store.fetchSummaries(scope: .emailNode, ids: Array(nodeIDs))
        let cachedByID = Dictionary(uniqueKeysWithValues: cachedNodes.map { ($0.scopeID, $0) })

        let inputs = Self.folderSummaryInputs(for: touchedFolders,
                                              messages: folderMessages,
                                              cachedNodeSummaries: cachedByID,
                                              threadIDsByFolder: threadIDsByFolder,
                                              effectiveThreadIDByMessageID: effectiveThreadIDByMessageID,
                                              providerID: providerID)

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

    private static func nodeSummaryBuild(from result: ThreadingResult,
                                         snippetLineLimit: Int,
                                         stopPhrases: [String],
                                         providerID: String) -> ThreadSummaryContextBuild {
        var sources: [ThreadSummaryMessageSource] = []
        for root in result.roots {
            let messages = flattenMessages(root)
            guard let first = messages.first else { continue }
            let effectiveThreadID = result.manualGroupByMessageKey[first.threadKey]
                ?? first.threadID
                ?? result.jwzThreadMap[first.threadKey]
                ?? first.messageID
            for message in messages {
                let messageKey = message.threadKey
                let automaticThreadID = result.jwzThreadMap[messageKey]
                    ?? (result.manualGroupByMessageKey[messageKey] == nil ? message.threadID : nil)
                    ?? message.messageID
                sources.append(ThreadSummaryMessageSourceBuilder.make(
                    message: message,
                    nodeID: message.messageID,
                    cacheKey: message.messageID,
                    effectiveThreadID: result.manualGroupByMessageKey[messageKey] ?? effectiveThreadID,
                    automaticThreadID: automaticThreadID,
                    isManualAttachment: result.manualAttachmentMessageIDs.contains(message.messageID),
                    snippetLineLimit: snippetLineLimit,
                    stopPhrases: stopPhrases
                ))
            }
        }
        return ThreadSummaryContextBuilder.build(sources: sources, providerID: providerID)
    }

    private static func flattenMessages(_ root: ThreadNode) -> [EmailMessage] {
        [root.message] + root.children.flatMap(flattenMessages)
    }

    private static func folderSummaryInputs(for folders: [ThreadFolder],
                                            messages: [EmailMessage],
                                            cachedNodeSummaries: [String: SummaryCacheEntry],
                                            threadIDsByFolder: [String: Set<String>],
                                            effectiveThreadIDByMessageID: [String: String],
                                            providerID: String) -> [FolderSummaryInput] {
        var messagesByThreadID: [String: [EmailMessage]] = [:]
        messagesByThreadID.reserveCapacity(messages.count)
        for message in messages {
            guard let threadID = effectiveThreadIDByMessageID[message.messageID] else { continue }
            messagesByThreadID[threadID, default: []].append(message)
        }

        var inputs: [FolderSummaryInput] = []
        inputs.reserveCapacity(folders.count)

        for folder in folders {
            let folderMessages = (threadIDsByFolder[folder.id] ?? folder.threadIDs)
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
            let fingerprint = ThreadSummaryFingerprint.makeFolder(title: folder.title,
                                                                  nodeEntries: fingerprintEntries,
                                                                  providerID: providerID)

            inputs.append(FolderSummaryInput(folderID: folder.id,
                                             title: folder.title,
                                             summaryTexts: Array(summaryTexts.prefix(20)),
                                             fingerprint: fingerprint))
        }

        return inputs
    }

    private static func folderDepth(_ folder: ThreadFolder,
                                    foldersByID: [String: ThreadFolder]) -> Int {
        var depth = 0
        var parentID = folder.parentID
        var visited: Set<String> = []
        while let currentID = parentID,
              !visited.contains(currentID),
              let parent = foldersByID[currentID] {
            visited.insert(currentID)
            depth += 1
            parentID = parent.parentID
        }
        return depth
    }

    private static func folderThreadIDsByFolder(folders: [ThreadFolder]) -> [String: Set<String>] {
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let childrenByParentID = Dictionary(grouping: folders.compactMap { folder -> (String, String)? in
            guard let parentID = folder.parentID else { return nil }
            return (parentID, folder.id)
        }, by: \.0).mapValues { $0.map(\.1) }

        func collect(for folderID: String) -> Set<String> {
            var result = foldersByID[folderID]?.threadIDs ?? []
            for childID in childrenByParentID[folderID] ?? [] {
                result.formUnion(collect(for: childID))
            }
            return result
        }

        return Dictionary(uniqueKeysWithValues: folders.map { ($0.id, collect(for: $0.id)) })
    }

}
