import Foundation

internal nonisolated struct ThreadSummaryMessageSource: Hashable, Sendable {
    internal let nodeID: String
    internal let cacheKey: String
    internal let effectiveThreadID: String
    internal let automaticThreadID: String
    internal let messageID: String
    internal let subject: String
    internal let body: String
    internal let contextSnippet: String
    internal let date: Date
    internal let isManualAttachment: Bool
}

/// Produces the canonical, bounded message text used by every thread-aware
/// summary and semantic-title flow. Callers supply relationship identity; this
/// builder owns content formatting so mounted Graph refreshes and date-range
/// regeneration cannot disagree about a thread revision.
internal nonisolated enum ThreadSummaryMessageSourceBuilder {
    internal static func make(message: EmailMessage,
                              nodeID: String,
                              cacheKey: String,
                              effectiveThreadID: String,
                              automaticThreadID: String,
                              isManualAttachment: Bool,
                              snippetLineLimit: Int,
                              stopPhrases: [String]) -> ThreadSummaryMessageSource {
        let formatter = SnippetFormatter(lineLimit: snippetLineLimit,
                                         stopPhrases: stopPhrases)
        let formattedBody = formatter.format(message.snippet)
        return ThreadSummaryMessageSource(
            nodeID: nodeID,
            cacheKey: cacheKey,
            effectiveThreadID: effectiveThreadID,
            automaticThreadID: automaticThreadID,
            messageID: message.messageID,
            subject: normalizedText(message.subject, maximumCharacters: 140),
            body: normalizedText(formattedBody, maximumCharacters: 600),
            contextSnippet: normalizedText(formattedBody, maximumCharacters: 220),
            date: message.date,
            isManualAttachment: isManualAttachment
        )
    }

    private static func normalizedText(_ text: String,
                                       maximumCharacters: Int) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maximumCharacters else { return collapsed }
        return String(collapsed.prefix(maximumCharacters)) + "…"
    }
}

internal nonisolated struct ThreadSummaryNodeInput: Hashable, Sendable {
    internal let nodeID: String
    internal let cacheKey: String
    internal let effectiveThreadID: String
    internal let request: EmailSummaryRequest
    internal let fingerprint: String
}

internal nonisolated struct ThreadSummaryContextBuild: Sendable {
    internal let inputsByNodeID: [String: ThreadSummaryNodeInput]
    internal let threadRevisionsByThreadID: [String: String]
    internal let nodeIDsByThreadID: [String: Set<String>]
}

/// Canonical input shared by mounted Graph refreshes, explicit title
/// regeneration, and date-range Re-GenAI. Keeping this construction in one
/// place prevents those flows from drifting on thread context or cache keys.
internal nonisolated struct GraphTitleGenerationInput: Hashable, Sendable {
    internal let nodeID: String
    internal let request: GraphTitleRequest
    internal let fingerprint: String
}

internal nonisolated enum GraphTitleGenerationInputBuilder {
    internal static func make(nodeInput: ThreadSummaryNodeInput,
                              summary: String,
                              summaryGenerationID: String?,
                              threadRevision: String,
                              providerID: String) -> GraphTitleGenerationInput {
        let subject = nodeInput.request.subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSummary = summary
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GraphTitleRequest(
            subject: subject,
            summary: normalizedSummary,
            threadContext: nodeInput.request.threadContext,
            effectiveThreadRevision: threadRevision
        )
        return GraphTitleGenerationInput(
            nodeID: nodeInput.nodeID,
            request: request,
            fingerprint: ThreadSummaryFingerprint.makeGraphTitle(
                subject: subject,
                summary: normalizedSummary,
                summaryGenerationID: summaryGenerationID,
                threadRevision: threadRevision,
                context: request.threadContext,
                providerID: providerID
            )
        )
    }
}

internal nonisolated enum ThreadSummaryContextBuilder {
    internal static func build(sources: [ThreadSummaryMessageSource],
                               providerID: String) -> ThreadSummaryContextBuild {
        let grouped = Dictionary(grouping: sources, by: \.effectiveThreadID)
        var inputsByNodeID: [String: ThreadSummaryNodeInput] = [:]
        var revisionsByThreadID: [String: String] = [:]
        var nodeIDsByThreadID: [String: Set<String>] = [:]
        inputsByNodeID.reserveCapacity(sources.count)
        revisionsByThreadID.reserveCapacity(grouped.count)
        nodeIDsByThreadID.reserveCapacity(grouped.count)

        for (threadID, threadSources) in grouped {
            let ordered = threadSources.sorted(by: chronologicalOrder)
            let revisionEntries = ordered.map {
                ThreadSummaryRevisionEntry(messageID: $0.messageID,
                                           subject: $0.subject,
                                           body: $0.body,
                                           date: $0.date,
                                           automaticThreadID: $0.automaticThreadID,
                                           isManualAttachment: $0.isManualAttachment)
            }
            let revision = ThreadSummaryFingerprint.makeThreadRevision(entries: revisionEntries)
            revisionsByThreadID[threadID] = revision
            nodeIDsByThreadID[threadID] = Set(ordered.map(\.nodeID))

            for index in ordered.indices {
                let source = ordered[index]
                guard !source.subject.isEmpty || !source.body.isEmpty else { continue }

                let previous = index > ordered.startIndex
                    ? contextEntry(for: ordered[index - 1],
                                   direction: .previous,
                                   relationship: relationship(between: ordered[index - 1], and: source))
                    : nil
                let next = index < ordered.index(before: ordered.endIndex)
                    ? contextEntry(for: ordered[index + 1],
                                   direction: .next,
                                   relationship: relationship(between: source, and: ordered[index + 1]))
                    : nil
                let context = EmailSummaryThreadContext(position: index + 1,
                                                        totalMessages: ordered.count,
                                                        previousMessage: previous,
                                                        nextMessage: next)
                let request = EmailSummaryRequest(subject: source.subject,
                                                  body: source.body,
                                                  threadContext: context)
                let fingerprint = ThreadSummaryFingerprint.makeNode(subject: source.subject,
                                                                    body: source.body,
                                                                    threadRevision: revision,
                                                                    context: context,
                                                                    providerID: providerID)
                inputsByNodeID[source.nodeID] = ThreadSummaryNodeInput(nodeID: source.nodeID,
                                                                      cacheKey: source.cacheKey,
                                                                      effectiveThreadID: threadID,
                                                                      request: request,
                                                                      fingerprint: fingerprint)
            }
        }

        return ThreadSummaryContextBuild(inputsByNodeID: inputsByNodeID,
                                         threadRevisionsByThreadID: revisionsByThreadID,
                                         nodeIDsByThreadID: nodeIDsByThreadID)
    }

    private static func chronologicalOrder(_ lhs: ThreadSummaryMessageSource,
                                           _ rhs: ThreadSummaryMessageSource) -> Bool {
        if lhs.date == rhs.date {
            return lhs.messageID < rhs.messageID
        }
        return lhs.date < rhs.date
    }

    private static func relationship(between lhs: ThreadSummaryMessageSource,
                                     and rhs: ThreadSummaryMessageSource) -> EmailSummaryRelationshipKind {
        if lhs.isManualAttachment || rhs.isManualAttachment || lhs.automaticThreadID != rhs.automaticThreadID {
            return .manualThreadLink
        }
        return .automaticReply
    }

    private static func contextEntry(for source: ThreadSummaryMessageSource,
                                     direction: EmailSummaryContextDirection,
                                     relationship: EmailSummaryRelationshipKind) -> EmailSummaryContextEntry {
        EmailSummaryContextEntry(messageID: source.messageID,
                                 subject: source.subject,
                                 bodySnippet: source.contextSnippet,
                                 direction: direction,
                                 relationship: relationship)
    }
}

internal actor ThreadSummaryRebuildCoordinator {
    private let store: MessageStore
    private var latestGeneration = 0

    internal init(store: MessageStore) {
        self.store = store
    }

    internal func beginGeneration() -> Int {
        latestGeneration += 1
        return latestGeneration
    }

    internal func invalidate() {
        latestGeneration += 1
    }

    internal func rebuildThread(inputs: [ThreadSummaryNodeInput],
                                provider: EmailSummaryProviding,
                                providerID: String,
                                generation: Int,
                                progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void) async throws -> [SummaryCacheEntry] {
        let orderedInputs = inputs.sorted {
            if $0.request.threadContext.position == $1.request.threadContext.position {
                return $0.nodeID < $1.nodeID
            }
            return $0.request.threadContext.position < $1.request.threadContext.position
        }
        var entries: [SummaryCacheEntry] = []
        entries.reserveCapacity(orderedInputs.count)

        for (index, input) in orderedInputs.enumerated() {
            try Task.checkCancellation()
            guard generation == latestGeneration else { throw CancellationError() }
            let text = try await provider.summarizeEmail(input.request)
            try Task.checkCancellation()
            guard generation == latestGeneration else { throw CancellationError() }
            entries.append(SummaryCacheEntry(scope: .emailNode,
                                             scopeID: input.cacheKey,
                                             summaryText: text,
                                             generatedAt: Date(),
                                             fingerprint: input.fingerprint,
                                             provider: providerID))
            progress(index + 1, orderedInputs.count)
        }

        try Task.checkCancellation()
        guard generation == latestGeneration else { throw CancellationError() }
        try await store.upsertSummaries(entries)
        try Task.checkCancellation()
        guard generation == latestGeneration else { throw CancellationError() }
        return entries
    }
}
