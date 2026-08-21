import Combine
import Foundation
import OSLog

internal struct GraphAutomationSnapshot {
    internal let scopeID: String
    internal let roots: [ThreadNode]
    internal let folders: [ThreadFolder]
    internal let manualGroups: [String: ManualThreadGroup]
    internal let manualGroupByMessageKey: [String: String]
    internal let manualAttachmentMessageIDs: Set<String>
    internal let jwzThreadMap: [String: String]
    internal let summariesByNodeID: [String: ThreadSummaryState]
}

@MainActor
internal final class GraphAutomationCoordinator: ObservableObject {
    @Published internal private(set) var proposals: [GraphAutomationProposal] = []
    @Published internal private(set) var topicSignalsByRawThreadID: [String: GraphTopicSignal] = [:]
    @Published internal private(set) var isEvaluating = false
    @Published internal private(set) var providerStatusMessage = ""
    @Published internal private(set) var lastEvaluatedAt: Date?

    internal let settings: GraphAutomationSettings
    internal var onOrganizationChanged: (() -> Void)?

    internal var attentionCount: Int {
        proposals.filter(\.needsAttention).count
    }

    internal var pendingProposals: [GraphAutomationProposal] {
        proposals.filter { $0.status == .pendingReview }
    }

    private let store: MessageStore
    private let mailClient: (any GraphSnipMailMoving)?
    private let relationshipCapabilityProvider: @MainActor () -> GraphRelationshipCapability
    private let topicCapabilityProvider: @MainActor () -> GraphTopicCapability
    private var currentSnapshot: GraphAutomationSnapshot?
    private var evaluationTask: Task<Void, Never>?
    private var refreshID = UUID()
    private var didLoadPersistedState = false

    internal init(
        store: MessageStore,
        settings: GraphAutomationSettings? = nil,
        mailClient: (any GraphSnipMailMoving)? = nil,
        relationshipCapabilityProvider: @escaping @MainActor () -> GraphRelationshipCapability = GraphRelationshipProviderFactory.makeCapability,
        topicCapabilityProvider: @escaping @MainActor () -> GraphTopicCapability = GraphTopicProviderFactory.makeCapability
    ) {
        self.store = store
        self.settings = settings ?? GraphAutomationSettings()
        self.mailClient = mailClient
        self.relationshipCapabilityProvider = relationshipCapabilityProvider
        self.topicCapabilityProvider = topicCapabilityProvider
    }

    deinit {
        evaluationTask?.cancel()
    }

    internal func scheduleEvaluation(snapshot: GraphAutomationSnapshot,
                                     scansCurrentMail: Bool = false) {
        currentSnapshot = snapshot
        guard !settings.isPaused else {
            evaluationTask?.cancel()
            evaluationTask = nil
            isEvaluating = false
            providerStatusMessage = Self.pausedStatusMessage
            return
        }
        refreshID = UUID()
        let requestedRefreshID = refreshID
        evaluationTask?.cancel()
        evaluationTask = Task { [weak self] in
            guard let self else { return }
            await self.evaluate(snapshot: snapshot,
                                scansCurrentMail: scansCurrentMail,
                                refreshID: requestedRefreshID)
        }
    }

    internal func scanCurrentMail() {
        guard !settings.isPaused, let currentSnapshot else { return }
        scheduleEvaluation(snapshot: currentSnapshot, scansCurrentMail: true)
    }

    internal func setPaused(_ isPaused: Bool) {
        settings.isPaused = isPaused
        if isPaused {
            refreshID = UUID()
            evaluationTask?.cancel()
            evaluationTask = nil
            isEvaluating = false
            providerStatusMessage = Self.pausedStatusMessage
        } else if let currentSnapshot {
            scheduleEvaluation(snapshot: currentSnapshot)
        }
    }

    /// Deterministic entry point for focused tests and explicit callers that
    /// must await the complete refresh-owned evaluation.
    internal func evaluateNow(snapshot: GraphAutomationSnapshot,
                              scansCurrentMail: Bool) async {
        currentSnapshot = snapshot
        evaluationTask?.cancel()
        refreshID = UUID()
        await evaluate(snapshot: snapshot,
                       scansCurrentMail: scansCurrentMail,
                       refreshID: refreshID)
    }

    internal func approve(ids: Set<String>) async {
        guard !ids.isEmpty, let snapshot = currentSnapshot else { return }
        let selected = proposals.filter { ids.contains($0.id) && $0.status == .pendingReview }
        await apply(selected, snapshot: snapshot, allowsReviewedConflicts: true)
    }

    internal func approveAll(destinationFolderID: String) async {
        await approve(ids: Set(proposals.filter {
            $0.status == .pendingReview && $0.target.folderID == destinationFolderID
        }.map(\.id)))
    }

    internal func reject(ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        let now = Date()
        var changed: [GraphAutomationProposal] = []
        for index in proposals.indices where ids.contains(proposals[index].id) {
            guard proposals[index].status == .pendingReview else { continue }
            proposals[index].status = .rejected
            proposals[index].lastError = nil
            proposals[index].updatedAt = now
            changed.append(proposals[index])
        }
        do {
            try await store.upsertGraphAutomationProposals(changed)
            try await store.pruneGraphAutomationHistory(now: now)
        } catch {
            Log.app.error("Failed to persist graph automation rejection: \(error.localizedDescription, privacy: .public)")
        }
        sortPublishedProposals()
    }

    internal func changeDestination(proposalID: String, folderID: String) async {
        guard let snapshot = currentSnapshot,
              let oldIndex = proposals.firstIndex(where: { $0.id == proposalID }),
              let folder = snapshot.folders.first(where: { $0.id == folderID }) else { return }
        let old = proposals[oldIndex]
        let folderFingerprint = Self.folderFingerprint(folder)
        let targetSource = Self.makeSources(from: snapshot).first {
            $0.effectiveThreadID == old.target.threadID
        }
        let target = GraphAutomationTarget(threadID: old.target.threadID,
                                           folderID: folder.id,
                                           title: old.action == .attachToThread ? old.target.title : folder.title,
                                           accountName: targetSource?.accountName ?? folder.mailboxAccount,
                                           fingerprint: old.action == .attachToThread
                                               ? GraphAutomationIdentity.make([targetSource?.fingerprint ?? "", folderFingerprint])
                                               : folderFingerprint)
        let newID = GraphAutomationProposal.deterministicID(
            providerVersion: old.providerVersion,
            sourceFingerprint: old.source.fingerprint,
            action: old.action,
            targetFingerprint: target.fingerprint
        )
        var superseded = old
        superseded.status = .stale
        superseded.lastError = NSLocalizedString("graph.automation.reason.destination_changed",
                                                 comment: "Automation destination was edited")
        superseded.updatedAt = Date()

        var replacement = old
        replacement = GraphAutomationProposal(
            id: newID,
            providerVersion: old.providerVersion,
            relationship: old.relationship,
            action: old.action,
            source: old.source,
            target: target,
            score: old.score,
            relationshipConfidence: old.relationshipConfidence,
            sharedAnchors: old.sharedAnchors,
            subjectActionSimilarity: old.subjectActionSimilarity,
            reason: old.reason,
            isAmbiguous: old.isAmbiguous,
            hasExistingFolderConflict: Self.folderID(for: old.source.effectiveThreadID,
                                                     in: snapshot.folders).map { $0 != folder.id } ?? false,
            hasManualGroupMergeConflict: old.hasManualGroupMergeConflict,
            steps: Self.steps(action: old.action,
                              source: old.source,
                              targetThreadID: old.target.threadID,
                              resultingThreadID: Self.resultingThreadID(for: old),
                              folder: folder,
                              followsMailboxMapping: settings.followsFolderMailboxMapping),
            status: .pendingReview,
            mailStatus: .notRequired,
            retryCount: 0,
            nextRetryAt: nil,
            lastError: nil,
            mutationDelta: nil,
            movedMessages: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        proposals[oldIndex] = superseded
        proposals.append(replacement)
        do {
            try await store.upsertGraphAutomationProposals([superseded, replacement])
        } catch {
            Log.app.error("Failed to persist edited automation destination: \(error.localizedDescription, privacy: .public)")
        }
        sortPublishedProposals()
    }

    internal func retry(_ proposalID: String) async {
        guard let proposal = proposals.first(where: { $0.id == proposalID }) else { return }
        if proposal.status == .recoveryNeeded ||
            (proposal.status == .undoing && !proposal.movedMessages.isEmpty) {
            await finishUndoMail(for: proposal)
            return
        }
        if proposal.mutationDelta != nil {
            await executeMailboxPhase(for: proposal, isManualRetry: true)
        } else {
            guard let snapshot = currentSnapshot else { return }
            var reviewable = proposal
            reviewable.status = .pendingReview
            await apply([reviewable], snapshot: snapshot, allowsReviewedConflicts: true)
        }
    }

    internal func undo(_ proposalID: String) async {
        guard let proposal = proposals.first(where: { $0.id == proposalID }),
              proposal.mutationDelta != nil,
              [.applied, .failed, .recoveryNeeded].contains(proposal.status) else { return }
        do {
            let result = try await store.undoGraphAutomationMembership(proposal)
            mergePersisted(result.proposals)
            onOrganizationChanged?()
            if let undoing = result.proposals.first {
                await finishUndoMail(for: undoing)
            }
        } catch {
            await mark(proposal, status: .recoveryNeeded, error: error.localizedDescription)
        }
    }

    internal func resetHistory(includeObservations: Bool) async {
        do {
            try await store.resetGraphAutomationHistory(includeObservations: includeObservations)
            proposals = []
            if includeObservations, let currentSnapshot {
                scheduleEvaluation(snapshot: currentSnapshot)
            }
        } catch {
            Log.app.error("Failed to reset graph automation history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func evaluate(snapshot: GraphAutomationSnapshot,
                          scansCurrentMail: Bool,
                          refreshID requestedRefreshID: UUID) async {
        isEvaluating = true
        defer {
            if self.refreshID == requestedRefreshID {
                isEvaluating = false
                evaluationTask = nil
            }
        }
        do {
            try await loadPersistedStateIfNeeded()
            try Task.checkCancellation()
            guard self.refreshID == requestedRefreshID else { return }
            guard !settings.isPaused else {
                providerStatusMessage = Self.pausedStatusMessage
                return
            }

            let sources = Self.makeSources(from: snapshot)
            let topicCapability = topicCapabilityProvider()
            topicSignalsByRawThreadID = await loadAndGenerateTopics(
                sources: sources,
                capability: topicCapability,
                refreshID: requestedRefreshID
            )
            try Task.checkCancellation()
            guard self.refreshID == requestedRefreshID else { return }

            let observations = try await store.fetchGraphAutomationObservations(scopeID: snapshot.scopeID)
            let observationsBySourceID = Dictionary(uniqueKeysWithValues: observations.map { ($0.sourceID, $0) })
            let now = Date()
            if observations.isEmpty && !scansCurrentMail {
                let baseline = sources.map {
                    GraphAutomationObservation(scopeID: snapshot.scopeID,
                                               sourceID: $0.effectiveThreadID,
                                               fingerprint: $0.fingerprint,
                                               providerVersion: "baseline",
                                               wasBaseline: true,
                                               evaluatedAt: now)
                }
                try await store.upsertGraphAutomationObservations(baseline)
                providerStatusMessage = NSLocalizedString("graph.automation.status.baseline_created",
                                                          comment: "Automation baseline created")
                lastEvaluatedAt = now
                await retryDueMailboxOperations(now: now)
                return
            }

            let currentSourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.effectiveThreadID, $0) })
            let sourcesWithChangedTargets = Set(proposals.compactMap { proposal -> String? in
                guard proposal.status == .pendingReview,
                      !Self.targetFingerprintMatches(proposal,
                                                     sourcesByID: currentSourcesByID,
                                                     folders: snapshot.folders) else { return nil }
                return proposal.source.effectiveThreadID
            })
            let eligibleSources = sources.filter { source in
                if scansCurrentMail { return true }
                if sourcesWithChangedTargets.contains(source.effectiveThreadID) { return true }
                guard let observed = observationsBySourceID[source.effectiveThreadID] else { return true }
                return observed.fingerprint != source.fingerprint
            }
            let relationshipCapability = relationshipCapabilityProvider()
            providerStatusMessage = relationshipCapability.statusMessage
            guard let relationshipProvider = relationshipCapability.provider else {
                await retryDueMailboxOperations(now: now)
                return
            }

            let candidates = try await generateProposals(
                eligibleSources: eligibleSources,
                allSources: sources,
                snapshot: snapshot,
                provider: relationshipProvider,
                providerVersion: relationshipCapability.providerVersion,
                refreshID: requestedRefreshID
            )
            guard self.refreshID == requestedRefreshID else { return }
            let updatedObservations = eligibleSources.map {
                GraphAutomationObservation(scopeID: snapshot.scopeID,
                                           sourceID: $0.effectiveThreadID,
                                           fingerprint: $0.fingerprint,
                                           providerVersion: relationshipCapability.providerVersion,
                                           wasBaseline: false,
                                           evaluatedAt: now)
            }
            try await store.upsertGraphAutomationObservations(updatedObservations)
            try await mergeGenerated(
                candidates,
                evaluatedSourceIDs: Set(eligibleSources.map(\.effectiveThreadID)),
                currentSourceIDs: Set(sources.map(\.effectiveThreadID))
            )
            lastEvaluatedAt = now

            let automatic = candidates.filter { proposal in
                guard settings.mode(for: proposal.action) == .automatic,
                      !settings.isPaused,
                      !proposal.isAmbiguous,
                      !proposal.hasExistingFolderConflict,
                      !proposal.hasManualGroupMergeConflict else { return false }
                return proposal.score >= settings.automaticThreshold(for: proposal.action)
            }
            await apply(automatic, snapshot: snapshot, allowsReviewedConflicts: false)
            await retryDueMailboxOperations(now: now)
            try await store.pruneGraphAutomationHistory(now: now)
        } catch is CancellationError {
            return
        } catch {
            providerStatusMessage = error.localizedDescription
            Log.app.error("Graph automation evaluation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadPersistedStateIfNeeded() async throws {
        guard !didLoadPersistedState else { return }
        proposals = try await store.fetchGraphAutomationProposals()
        didLoadPersistedState = true
        sortPublishedProposals()
    }

    private func loadAndGenerateTopics(
        sources: [GraphAutomationSource],
        capability initialCapability: GraphTopicCapability,
        refreshID requestedRefreshID: UUID
    ) async -> [String: GraphTopicSignal] {
        let inputs = Dictionary(uniqueKeysWithValues: sources.map { source in
            let fingerprint = ThreadSummaryFingerprint.makeGraphTopic(
                subject: source.subject,
                threadSummary: source.summary,
                representativeContent: source.representativeContent,
                providerID: initialCapability.providerID
            )
            return (source.rawThreadID, (source: source, fingerprint: fingerprint))
        })
        var signals: [String: GraphTopicSignal] = [:]
        var pending: [(source: GraphAutomationSource, fingerprint: String)] = []
        let cached: [SummaryCacheEntry]
        do {
            cached = try await store.fetchSummaries(scope: .graphTopic, ids: Array(inputs.keys))
        } catch {
            Log.app.error("Failed to load refresh-owned graph topic cache: \(error.localizedDescription, privacy: .public)")
            return signals
        }
        let cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.scopeID, $0) })
        for (rawThreadID, input) in inputs.sorted(by: { $0.key < $1.key }) {
            if let entry = cachedByID[rawThreadID],
               entry.fingerprint == input.fingerprint,
               entry.provider == initialCapability.providerID,
               let data = entry.summaryText.data(using: .utf8),
               let record = try? JSONDecoder().decode(GraphTopicCacheRecord.self, from: data) {
                if let signal = record.signal { signals[rawThreadID] = signal }
            } else {
                pending.append(input)
            }
        }
        guard let provider = initialCapability.provider else { return signals }
        for input in pending {
            guard self.refreshID == requestedRefreshID, !Task.isCancelled else { return signals }
            do {
                let signal = try await provider.generateTopic(
                    GraphTopicRequest(subject: input.source.subject,
                                      threadSummary: input.source.summary,
                                      representativeContent: input.source.representativeContent)
                )
                let record = GraphTopicCacheRecord(signal: signal)
                let data = try JSONEncoder().encode(record)
                let entry = SummaryCacheEntry(scope: .graphTopic,
                                              scopeID: input.source.rawThreadID,
                                              summaryText: String(decoding: data, as: UTF8.self),
                                              generatedAt: Date(),
                                              fingerprint: input.fingerprint,
                                              provider: initialCapability.providerID)
                try await store.upsertSummaries([entry])
                if let signal { signals[input.source.rawThreadID] = signal }
            } catch is CancellationError {
                return signals
            } catch {
                Log.app.error("Refresh-owned graph topic generation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return signals
    }

    private func generateProposals(
        eligibleSources: [GraphAutomationSource],
        allSources: [GraphAutomationSource],
        snapshot: GraphAutomationSnapshot,
        provider: GraphRelationshipProviding,
        providerVersion: String,
        refreshID requestedRefreshID: UUID
    ) async throws -> [GraphAutomationProposal] {
        guard !eligibleSources.isEmpty else { return [] }
        let sourceByID = Dictionary(uniqueKeysWithValues: allSources.map { ($0.effectiveThreadID, $0) })
        let folderProfiles = snapshot.folders.map { folder in
            Self.makeFolderProfile(folder: folder, sourceByID: sourceByID)
        }
        var generated: [GraphAutomationProposal] = []

        for source in eligibleSources.sorted(by: { $0.effectiveThreadID < $1.effectiveThreadID }) {
            try Task.checkCancellation()
            guard self.refreshID == requestedRefreshID else { throw CancellationError() }
            let sourceFolderID = Self.folderID(for: source.effectiveThreadID, in: snapshot.folders)

            let shortlistedFolders = Self.shortlistFolders(source: source,
                                                           profiles: folderProfiles,
                                                           topicSignals: topicSignalsByRawThreadID)
            let shortlistedFolderIDs = Set(shortlistedFolders.map(\.folder.id))
            let shortlistedThreads = Self.shortlistThreads(source: source,
                                                           allSources: allSources,
                                                           preferredFolderIDs: shortlistedFolderIDs,
                                                           folders: snapshot.folders,
                                                           topicSignals: topicSignalsByRawThreadID)

            var attachMatches: [RelationshipMatch] = []
            if settings.mode(for: .attachToThread) != .off,
               !source.accountName.isEmpty {
                for targetSource in shortlistedThreads {
                    guard targetSource.effectiveThreadID != source.effectiveThreadID,
                          !targetSource.accountName.isEmpty,
                          targetSource.accountName.caseInsensitiveCompare(source.accountName) == .orderedSame,
                          Self.shouldPreferAttachmentTarget(targetSource,
                                                           over: source,
                                                           folders: snapshot.folders) else {
                        continue
                    }
                    let signal = try await provider.relationship(for: GraphAutomationRelationshipRequest(
                        sourceSubject: source.subject,
                        sourceSummary: source.summary,
                        sourceContent: source.representativeContent,
                        targetTitle: targetSource.subject,
                        targetSummary: targetSource.summary,
                        targetContent: targetSource.representativeContent,
                        targetIsFolderProfile: false
                    ))
                    guard signal.relationship == .sameConversation,
                          signal.hasSharedNamedTopic,
                          signal.hasSameConcreteActionOrEvent else { continue }
                    let scoring = GraphAutomationScorer.score(
                        signal: signal,
                        sourceText: source.subject + " " + source.summary + " " + source.representativeContent,
                        targetText: targetSource.subject + " " + targetSource.summary + " " + targetSource.representativeContent
                    )
                    attachMatches.append(RelationshipMatch(source: targetSource,
                                                           folderProfile: nil,
                                                           signal: signal,
                                                           score: scoring.score,
                                                           anchorOverlap: scoring.anchorOverlap,
                                                           subjectSimilarity: scoring.subjectSimilarity))
                }
            }

            let attachThresholds = settings.strictness(for: .attachToThread).thresholds
            let orderedAttach = attachMatches.sorted { lhs, rhs in
                Self.matchComesFirst(lhs, rhs, folders: snapshot.folders)
            }
            if let winner = orderedAttach.first, winner.score >= attachThresholds.reviewFloor,
               let targetSource = winner.source {
                let winnerPriority = Self.attachmentPriority(targetSource, folders: snapshot.folders)
                let runnerUpScore = orderedAttach.dropFirst().first(where: { match in
                    guard let candidate = match.source else { return false }
                    return Self.attachmentPriority(candidate, folders: snapshot.folders) == winnerPriority
                })?.score ?? 0
                let isAmbiguous = winner.score - runnerUpScore < attachThresholds.winnerMargin
                let targetFolderID = Self.folderID(for: targetSource.effectiveThreadID, in: snapshot.folders)
                let folder = targetFolderID.flatMap { id in snapshot.folders.first { $0.id == id } }
                let manualMergeConflict = source.manualGroupID != nil &&
                    targetSource.manualGroupID != nil &&
                    source.manualGroupID != targetSource.manualGroupID
                let existingFolderConflict = sourceFolderID.map { $0 != targetFolderID } ?? false
                generated.append(Self.makeProposal(
                    action: .attachToThread,
                    relationship: .sameConversation,
                    source: source,
                    targetSource: targetSource,
                    folder: folder,
                    match: winner,
                    providerVersion: providerVersion,
                    isAmbiguous: isAmbiguous,
                    hasExistingFolderConflict: existingFolderConflict,
                    hasManualGroupMergeConflict: manualMergeConflict,
                    followsMailboxMapping: settings.followsFolderMailboxMapping
                ))
                continue
            }

            guard settings.mode(for: .appendToFolder) != .off else { continue }
            var topicMatches: [RelationshipMatch] = []
            for profile in shortlistedFolders where profile.folder.id != sourceFolderID {
                if let destination = profile.folder.mailboxDestination,
                   (source.accountName.isEmpty || destination.account.caseInsensitiveCompare(source.accountName) != .orderedSame) {
                    continue
                }
                let signal = try await provider.relationship(for: GraphAutomationRelationshipRequest(
                    sourceSubject: source.subject,
                    sourceSummary: source.summary,
                    sourceContent: source.representativeContent,
                    targetTitle: profile.folder.title,
                    targetSummary: profile.summary,
                    targetContent: profile.content,
                    targetIsFolderProfile: true
                ))
                guard signal.relationship == .sameTopic else { continue }
                let scoring = GraphAutomationScorer.score(
                    signal: signal,
                    sourceText: source.subject + " " + source.summary + " " + source.representativeContent,
                    targetText: profile.folder.title + " " + profile.summary + " " + profile.content
                )
                topicMatches.append(RelationshipMatch(source: nil,
                                                      folderProfile: profile,
                                                      signal: signal,
                                                      score: scoring.score,
                                                      anchorOverlap: scoring.anchorOverlap,
                                                      subjectSimilarity: scoring.subjectSimilarity))
            }
            let folderThresholds = settings.strictness(for: .appendToFolder).thresholds
            let orderedTopics = topicMatches.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return ($0.folderProfile?.folder.id ?? "") < ($1.folderProfile?.folder.id ?? "")
            }
            guard let winner = orderedTopics.first,
                  winner.score >= folderThresholds.reviewFloor,
                  let profile = winner.folderProfile else { continue }
            let runnerUpScore = orderedTopics.dropFirst().first?.score ?? 0
            generated.append(Self.makeProposal(
                action: .appendToFolder,
                relationship: .sameTopic,
                source: source,
                targetSource: nil,
                folder: profile.folder,
                match: winner,
                providerVersion: providerVersion,
                isAmbiguous: winner.score - runnerUpScore < folderThresholds.winnerMargin,
                hasExistingFolderConflict: sourceFolderID != nil && sourceFolderID != profile.folder.id,
                hasManualGroupMergeConflict: false,
                followsMailboxMapping: settings.followsFolderMailboxMapping
            ))
        }
        return generated
    }

    private func mergeGenerated(_ generated: [GraphAutomationProposal],
                                evaluatedSourceIDs: Set<String>,
                                currentSourceIDs: Set<String>) async throws {
        let newIDs = Set(generated.map(\.id))
        var changed: [GraphAutomationProposal] = []
        for index in proposals.indices {
            let sourceID = proposals[index].source.effectiveThreadID
            guard (evaluatedSourceIDs.contains(sourceID) || !currentSourceIDs.contains(sourceID)),
                  !newIDs.contains(proposals[index].id),
                  proposals[index].status == .pendingReview else { continue }
            proposals[index].status = .stale
            proposals[index].lastError = NSLocalizedString("graph.automation.reason.evidence_changed",
                                                           comment: "Automation evidence changed")
            proposals[index].updatedAt = Date()
            changed.append(proposals[index])
        }
        let existingByID = Dictionary(uniqueKeysWithValues: proposals.map { ($0.id, $0) })
        for proposal in generated {
            if let existing = existingByID[proposal.id],
               [.rejected, .applied, .failed, .recoveryNeeded, .undone].contains(existing.status) {
                continue
            }
            if let index = proposals.firstIndex(where: { $0.id == proposal.id }) {
                proposals[index] = proposal
            } else {
                proposals.append(proposal)
            }
            changed.append(proposal)
        }
        try await store.upsertGraphAutomationProposals(changed)
        sortPublishedProposals()
    }

    private func apply(_ selected: [GraphAutomationProposal],
                       snapshot: GraphAutomationSnapshot,
                       allowsReviewedConflicts: Bool) async {
        guard !selected.isEmpty else { return }
        let currentSources = Self.makeSources(from: snapshot)
        let sourceByID = Dictionary(uniqueKeysWithValues: currentSources.map { ($0.effectiveThreadID, $0) })
        var seenSourceIDs = Set<String>()
        var valid: [GraphAutomationProposal] = []
        var invalid: [GraphAutomationProposal] = []

        for original in selected.sorted(by: Self.proposalComesFirst) {
            var proposal = original
            guard seenSourceIDs.insert(proposal.source.effectiveThreadID).inserted else { continue }
            guard let currentSource = sourceByID[proposal.source.effectiveThreadID],
                  currentSource.fingerprint == proposal.source.fingerprint else {
                proposal.status = .pendingReview
                proposal.lastError = GraphAutomationPersistenceError.staleMutation.localizedDescription
                proposal.updatedAt = Date()
                invalid.append(proposal)
                continue
            }
            proposal.source = currentSource
            if proposal.action == .appendToFolder {
                guard let folderID = proposal.target.folderID,
                      let folder = snapshot.folders.first(where: { $0.id == folderID }),
                      Self.folderFingerprint(folder) == proposal.target.fingerprint else {
                    proposal.status = .pendingReview
                    proposal.lastError = GraphAutomationPersistenceError.staleMutation.localizedDescription
                    proposal.updatedAt = Date()
                    invalid.append(proposal)
                    continue
                }
                if let destination = folder.mailboxDestination,
                   (currentSource.accountName.isEmpty || destination.account.caseInsensitiveCompare(currentSource.accountName) != .orderedSame) {
                    proposal.status = .pendingReview
                    proposal.lastError = NSLocalizedString("graph.automation.error.mixed_accounts",
                                                           comment: "Automation action crosses Mail accounts")
                    proposal.updatedAt = Date()
                    invalid.append(proposal)
                    continue
                }
            } else {
                guard let targetID = proposal.target.threadID,
                      let targetSource = sourceByID[targetID],
                      Self.targetFingerprintMatches(proposal,
                                                     sourcesByID: sourceByID,
                                                     folders: snapshot.folders),
                      !currentSource.accountName.isEmpty,
                      currentSource.accountName.caseInsensitiveCompare(targetSource.accountName) == .orderedSame else {
                    proposal.status = .pendingReview
                    proposal.lastError = GraphAutomationPersistenceError.staleMutation.localizedDescription
                    proposal.updatedAt = Date()
                    invalid.append(proposal)
                    continue
                }
                if let folderID = proposal.target.folderID,
                   let folder = snapshot.folders.first(where: { $0.id == folderID }),
                   let destination = folder.mailboxDestination,
                   destination.account.caseInsensitiveCompare(currentSource.accountName) != .orderedSame {
                    proposal.status = .pendingReview
                    proposal.lastError = NSLocalizedString("graph.automation.error.mixed_accounts",
                                                           comment: "Automation action crosses Mail accounts")
                    proposal.updatedAt = Date()
                    invalid.append(proposal)
                    continue
                }
            }
            if !allowsReviewedConflicts &&
                (proposal.hasExistingFolderConflict || proposal.hasManualGroupMergeConflict || proposal.isAmbiguous) {
                continue
            }
            valid.append(proposal)
        }

        if !invalid.isEmpty {
            mergePersisted(invalid)
            try? await store.upsertGraphAutomationProposals(invalid)
        }
        guard !valid.isEmpty else { return }
        do {
            let result = try await store.applyGraphAutomationBatch(valid)
            mergePersisted(result.proposals)
            for applied in result.proposals {
                if let delta = applied.mutationDelta,
                   let groupID = delta.resultingManualGroupID {
                    mailboxRuleRemap?(Set([delta.sourceThreadIDBefore,
                                          delta.targetThreadIDBefore].compactMap { $0 }),
                                      groupID,
                                      delta.targetThreadIDBefore)
                }
            }
            onOrganizationChanged?()
            for applied in result.proposals where applied.mailStatus == .pending {
                await executeMailboxPhase(for: applied, isManualRetry: false)
            }
        } catch {
            var failures = valid
            for index in failures.indices {
                failures[index].status = .failed
                failures[index].lastError = error.localizedDescription
                failures[index].updatedAt = Date()
            }
            mergePersisted(failures)
            try? await store.upsertGraphAutomationProposals(failures)
        }
    }

    /// Hook kept outside Core Data because the pre-existing mailbox rules are
    /// UserDefaults-backed. It runs only after the organization transaction
    /// commits and is deterministic/idempotent.
    internal var mailboxRuleRemap: ((Set<String>, String, String?) -> Void)?

    private func executeMailboxPhase(for original: GraphAutomationProposal,
                                     isManualRetry: Bool) async {
        var proposal = original
        guard proposal.steps.contains(where: {
            if case .mailbox = $0 { return true }
            return false
        }) else {
            proposal.mailStatus = .notRequired
            proposal.status = .applied
            await persistAndMerge(proposal)
            return
        }
        guard let mailClient else {
            proposal.status = .failed
            proposal.mailStatus = .failed
            proposal.retryCount = 3
            proposal.nextRetryAt = nil
            proposal.lastError = NSLocalizedString("graph.automation.error.mail_unavailable",
                                                   comment: "Mail movement is unavailable")
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        guard case .mailbox(_, let destinationAccount, let destinationPath) = proposal.steps.first(where: {
            if case .mailbox = $0 { return true }
            return false
        }) else { return }

        proposal.mailStatus = .moving
        proposal.lastError = nil
        proposal.updatedAt = Date()
        await persistAndMerge(proposal)

        let destination = MailLocation(account: destinationAccount, mailbox: destinationPath)
        let sourceMessages = Dictionary(grouping: proposal.source.messages.filter {
            !$0.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !destination.matches(account: $0.accountName, mailbox: $0.mailboxPath)
        }, by: { MailLocation(account: $0.accountName, mailbox: $0.mailboxPath) })
        var moved: [GraphSnipMovedMessage] = []
        for (source, messages) in sourceMessages.sorted(by: { $0.key.id < $1.key.id }) {
            do {
                let result = try await mailClient.moveMessages(messageIDs: messages.map(\.messageID),
                                                               toMailboxPath: destination.mailbox,
                                                               account: destination.account,
                                                               sourceMailboxPath: source.mailbox,
                                                               sourceAccount: source.account)
                moved.append(contentsOf: messages.filter { result.contains($0.messageID) }.map {
                    GraphSnipMovedMessage(messageID: $0.messageID,
                                          sourceMailboxPath: $0.mailboxPath,
                                          sourceAccountName: $0.accountName,
                                          destinationMailboxPath: destination.mailbox,
                                          destinationAccountName: destination.account)
                })
            } catch {
                Log.app.error("Graph automation Mail move failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let requiredIDs = Set(sourceMessages.values.flatMap { $0 }.map {
            GraphSnipMessage.locationIdentity(messageID: $0.messageID,
                                              accountName: $0.accountName,
                                              mailboxPath: $0.mailboxPath)
        })
        let movedIDs = Set(moved.map(\.id))
        if requiredIDs.isSubset(of: movedIDs) {
            proposal.status = .applied
            proposal.mailStatus = .moved
            proposal.movedMessages = moved.sorted { $0.id < $1.id }
            proposal.retryCount = 0
            proposal.nextRetryAt = nil
            proposal.lastError = nil
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        if !moved.isEmpty {
            proposal.mailStatus = .compensating
            await persistAndMerge(proposal)
            let displaced = await restoreMovedMessages(moved, with: mailClient)
            if !displaced.isEmpty {
                proposal.status = .recoveryNeeded
                proposal.mailStatus = .recoveryNeeded
                proposal.movedMessages = displaced
                proposal.nextRetryAt = nil
                proposal.lastError = NSLocalizedString("graph.automation.error.partial_recovery",
                                                       comment: "Mail compensation was incomplete")
                proposal.updatedAt = Date()
                await persistAndMerge(proposal)
                return
            }
        }
        proposal.status = .failed
        proposal.mailStatus = .failed
        proposal.movedMessages = []
        proposal.retryCount = min(3, proposal.retryCount + 1)
        proposal.nextRetryAt = Self.nextRetryDate(count: proposal.retryCount,
                                                  now: Date(),
                                                  manualRetry: isManualRetry)
        proposal.lastError = NSLocalizedString("graph.automation.error.mail_move_failed",
                                               comment: "Mail move failed but app grouping was retained")
        proposal.updatedAt = Date()
        await persistAndMerge(proposal)
    }

    private func retryDueMailboxOperations(now: Date) async {
        let due = proposals.filter {
            $0.status == .failed &&
                $0.mutationDelta != nil &&
                $0.retryCount < 3 &&
                ($0.nextRetryAt.map { $0 <= now } ?? false)
        }
        for proposal in due {
            await executeMailboxPhase(for: proposal, isManualRetry: false)
        }
    }

    private func finishUndoMail(for original: GraphAutomationProposal) async {
        var proposal = original
        guard !proposal.movedMessages.isEmpty else {
            proposal.status = .undone
            proposal.mailStatus = .restored
            proposal.lastError = nil
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        guard let mailClient else {
            proposal.status = .recoveryNeeded
            proposal.mailStatus = .recoveryNeeded
            proposal.lastError = NSLocalizedString("graph.automation.error.mail_unavailable",
                                                   comment: "Mail movement is unavailable")
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        let remaining = await restoreMovedMessages(proposal.movedMessages, with: mailClient)
        proposal.movedMessages = remaining
        proposal.status = remaining.isEmpty ? .undone : .recoveryNeeded
        proposal.mailStatus = remaining.isEmpty ? .restored : .recoveryNeeded
        proposal.lastError = remaining.isEmpty ? nil : NSLocalizedString(
            "graph.automation.error.undo_recovery",
            comment: "Automation undo requires Mail recovery"
        )
        proposal.updatedAt = Date()
        await persistAndMerge(proposal)
    }

    private func restoreMovedMessages(
        _ movedMessages: [GraphSnipMovedMessage],
        with mailClient: any GraphSnipMailMoving
    ) async -> [GraphSnipMovedMessage] {
        let grouped = Dictionary(grouping: movedMessages) { message in
            MailRestoreRoute(destination: MailLocation(account: message.destinationAccountName,
                                                       mailbox: message.destinationMailboxPath),
                             origin: MailLocation(account: message.sourceAccountName,
                                                  mailbox: message.sourceMailboxPath))
        }
        var restored = Set<String>()
        for (route, messages) in grouped.sorted(by: { $0.key.id < $1.key.id }) {
            do {
                let result = try await mailClient.moveMessages(messageIDs: messages.map(\.messageID),
                                                               toMailboxPath: route.origin.mailbox,
                                                               account: route.origin.account,
                                                               sourceMailboxPath: route.destination.mailbox,
                                                               sourceAccount: route.destination.account)
                for message in messages where result.contains(message.messageID) {
                    restored.insert(message.id)
                }
            } catch {
                Log.app.error("Graph automation Mail restore failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return movedMessages.filter { !restored.contains($0.id) }
    }

    private func mark(_ original: GraphAutomationProposal,
                      status: GraphAutomationExecutionStatus,
                      error: String?) async {
        var proposal = original
        proposal.status = status
        proposal.lastError = error
        proposal.updatedAt = Date()
        await persistAndMerge(proposal)
    }

    private func persistAndMerge(_ proposal: GraphAutomationProposal) async {
        do {
            try await store.upsertGraphAutomationProposals([proposal])
        } catch {
            Log.app.error("Failed to persist graph automation state: \(error.localizedDescription, privacy: .public)")
        }
        mergePersisted([proposal])
    }

    private func mergePersisted(_ changed: [GraphAutomationProposal]) {
        for proposal in changed {
            if let index = proposals.firstIndex(where: { $0.id == proposal.id }) {
                proposals[index] = proposal
            } else {
                proposals.append(proposal)
            }
        }
        sortPublishedProposals()
    }

    private func sortPublishedProposals() {
        proposals.sort { lhs, rhs in
            let lhsRank = Self.statusRank(lhs.status)
            let rhsRank = Self.statusRank(rhs.status)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    private static func statusRank(_ status: GraphAutomationExecutionStatus) -> Int {
        switch status {
        case .pendingReview: 0
        case .failed: 1
        case .recoveryNeeded: 2
        case .applying, .undoing: 3
        case .applied: 4
        case .rejected: 5
        case .undone: 6
        case .stale: 7
        }
    }

    private static func makeSources(from snapshot: GraphAutomationSnapshot) -> [GraphAutomationSource] {
        snapshot.roots.compactMap { root in
            let rawThreadID = GraphData.rawThreadID(for: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawThreadID.isEmpty else { return nil }
            let nodes = flatten(root).sorted {
                if $0.message.date != $1.message.date { return $0.message.date < $1.message.date }
                return $0.id < $1.id
            }
            guard !nodes.isEmpty else { return nil }
            let accounts = Set(nodes.map { $0.message.physicalSource.accountName.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
            let accountName = accounts.count == 1 ? accounts.first ?? "" : ""
            let manualGroup = snapshot.manualGroups[rawThreadID]
            let automaticThreadIDs = Set(nodes.compactMap { snapshot.jwzThreadMap[$0.message.threadKey] })
            let isBranch = manualGroup != nil || nodes.count > 1
            let jwzThreadIDs: Set<String>
            let manualMessageKeys: Set<String>
            if let manualGroup {
                jwzThreadIDs = manualGroup.jwzThreadIDs
                manualMessageKeys = manualGroup.manualMessageKeys
            } else if isBranch {
                jwzThreadIDs = automaticThreadIDs.isEmpty ? [rawThreadID] : automaticThreadIDs
                manualMessageKeys = []
            } else {
                jwzThreadIDs = []
                manualMessageKeys = [nodes[0].message.threadKey]
            }
            var seenPhysicalSources = Set<String>()
            let messages = nodes.compactMap { node -> GraphAutomationMessageSource? in
                let physical = node.message.physicalSource
                let identity = GraphAutomationIdentity.make([
                    physical.accountName.lowercased(),
                    physical.mailboxID.lowercased(),
                    physical.internalMailID ?? "",
                    physical.messageID.lowercased()
                ])
                guard seenPhysicalSources.insert(identity).inserted else { return nil }
                return GraphAutomationMessageSource(messageID: physical.messageID,
                                                    messageKey: node.message.threadKey,
                                                    internalMailID: physical.internalMailID,
                                                    accountName: physical.accountName,
                                                    mailboxPath: physical.mailboxID,
                                                    date: physical.date)
            }
            let summary = nodes.reversed().compactMap { node -> String? in
                let value = (snapshot.summariesByNodeID[node.id]
                    ?? snapshot.summariesByNodeID[GraphData.messageNodeID(for: node.id)])?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : value
            }.first ?? ""
            let content = representativeContent(nodes)
            let fingerprintComponents = [
                "graph-automation-source-v1",
                rawThreadID,
                manualGroup?.id ?? "",
                jwzThreadIDs.sorted().joined(separator: ","),
                manualMessageKeys.sorted().joined(separator: ",")
            ] + nodes.map { node in
                let message = node.message
                return [
                    message.physicalSource.accountName.lowercased(),
                    message.physicalSource.messageID.lowercased(),
                    String(message.physicalSource.date.timeIntervalSinceReferenceDate),
                    message.subject,
                    message.snippet,
                    message.inReplyTo ?? "",
                    message.references.joined(separator: ",")
                ].joined(separator: "|")
            }
            return GraphAutomationSource(rawThreadID: rawThreadID,
                                         effectiveThreadID: rawThreadID,
                                         manualGroupID: manualGroup?.id,
                                         subject: root.message.subject.trimmingCharacters(in: .whitespacesAndNewlines),
                                         summary: summary,
                                         representativeContent: content,
                                         accountName: accountName,
                                         jwzThreadIDs: jwzThreadIDs,
                                         manualMessageKeys: manualMessageKeys,
                                         messages: messages,
                                         fingerprint: GraphAutomationIdentity.make(fingerprintComponents))
        }
    }

    private static func makeFolderProfile(
        folder: ThreadFolder,
        sourceByID: [String: GraphAutomationSource]
    ) -> FolderProfile {
        let members = folder.threadIDs.compactMap { sourceByID[$0] }
            .sorted { $0.effectiveThreadID < $1.effectiveThreadID }
        let summary = members.compactMap { $0.summary.isEmpty ? nil : $0.summary }
            .prefix(6).joined(separator: "\n")
        let content = members.map { $0.subject + " " + $0.representativeContent }
            .prefix(6).joined(separator: "\n")
        return FolderProfile(folder: folder,
                             summary: summary,
                             content: content,
                             fingerprint: folderFingerprint(folder))
    }

    private static func shortlistFolders(
        source: GraphAutomationSource,
        profiles: [FolderProfile],
        topicSignals: [String: GraphTopicSignal]
    ) -> [FolderProfile] {
        // Candidate generation deliberately excludes representativeContent. That
        // payload contains useful semantic evidence for the provider, but also
        // repeated labels, sender domains, and message formatting that make
        // unrelated mail look lexically similar and multiply model calls.
        let sourceText = source.subject + " " + source.summary
        let sourceTokens = GraphAutomationScorer.significantTokens(sourceText)
        let sourceTopic = topicSignals[source.rawThreadID]?.normalizedTopic
        return profiles.compactMap { profile -> (FolderProfile, Double)? in
            let profileText = profile.folder.title + " " + profile.summary
            let profileTokens = GraphAutomationScorer.significantTokens(profileText)
            let overlap = Self.jaccard(sourceTokens, profileTokens)
            let title = GraphTopicNormalizer.normalize(profile.folder.title)
            let titleMatch = !title.isEmpty && GraphTopicNormalizer.normalize(sourceText).contains(title)
            let memberTopicMatch = sourceTopic.map { topic in
                profile.folder.threadIDs.contains { topicSignals[$0]?.normalizedTopic == topic }
            } ?? false
            guard overlap >= 0.06 || titleMatch || memberTopicMatch else { return nil }
            let score = max(overlap, titleMatch ? 0.85 : 0, memberTopicMatch ? 0.90 : 0)
            return (profile, score)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.folder.id < rhs.0.folder.id
        }.prefix(3).map(\.0)
    }

    private static func shortlistThreads(
        source: GraphAutomationSource,
        allSources: [GraphAutomationSource],
        preferredFolderIDs: Set<String>,
        folders: [ThreadFolder],
        topicSignals: [String: GraphTopicSignal]
    ) -> [GraphAutomationSource] {
        let sourceText = source.subject + " " + source.summary
        let sourceTokens = GraphAutomationScorer.significantTokens(sourceText)
        let sourceTopic = topicSignals[source.rawThreadID]?.normalizedTopic
        return allSources.compactMap { candidate -> (GraphAutomationSource, Double, Bool)? in
            guard candidate.effectiveThreadID != source.effectiveThreadID else { return nil }
            let candidateText = candidate.subject + " " + candidate.summary
            let overlap = jaccard(sourceTokens, GraphAutomationScorer.significantTokens(candidateText))
            let topicMatch = sourceTopic != nil && sourceTopic == topicSignals[candidate.rawThreadID]?.normalizedTopic
            let folderID = folderID(for: candidate.effectiveThreadID, in: folders)
            let preferred = folderID.map(preferredFolderIDs.contains) ?? false
            guard overlap >= 0.06 || topicMatch || (preferred && overlap >= 0.035) else { return nil }
            let score = max(overlap, topicMatch ? 0.90 : 0, preferred ? 0.35 : 0)
            return (candidate, score, preferred)
        }.sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 && !rhs.2 }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if (lhs.0.manualGroupID != nil) != (rhs.0.manualGroupID != nil) {
                return lhs.0.manualGroupID != nil
            }
            if lhs.0.oldestMessageDate != rhs.0.oldestMessageDate {
                return lhs.0.oldestMessageDate < rhs.0.oldestMessageDate
            }
            return lhs.0.effectiveThreadID < rhs.0.effectiveThreadID
        }.prefix(4).map(\.0)
    }

    private static func makeProposal(
        action: GraphAutomationAction,
        relationship: GraphAutomationRelationship,
        source: GraphAutomationSource,
        targetSource: GraphAutomationSource?,
        folder: ThreadFolder?,
        match: RelationshipMatch,
        providerVersion: String,
        isAmbiguous: Bool,
        hasExistingFolderConflict: Bool,
        hasManualGroupMergeConflict: Bool,
        followsMailboxMapping: Bool
    ) -> GraphAutomationProposal {
        let targetFingerprint: String
        let targetTitle: String
        let targetThreadID: String?
        if let targetSource {
            targetThreadID = targetSource.effectiveThreadID
            targetTitle = targetSource.subject
            targetFingerprint = GraphAutomationIdentity.make([
                targetSource.fingerprint,
                folder.map(folderFingerprint) ?? ""
            ])
        } else if let folder {
            targetThreadID = nil
            targetTitle = folder.title
            targetFingerprint = folderFingerprint(folder)
        } else {
            targetThreadID = nil
            targetTitle = ""
            targetFingerprint = ""
        }
        let target = GraphAutomationTarget(threadID: targetThreadID,
                                           folderID: folder?.id,
                                           title: targetTitle,
                                           accountName: targetSource?.accountName ?? folder?.mailboxAccount,
                                           fingerprint: targetFingerprint)
        let resultThreadID: String?
        if action == .attachToThread {
            resultThreadID = targetSource?.manualGroupID
                ?? source.manualGroupID
                ?? "manual-auto-" + String(GraphAutomationIdentity.make([targetFingerprint]).prefix(24))
        } else {
            resultThreadID = nil
        }
        let id = GraphAutomationProposal.deterministicID(providerVersion: providerVersion,
                                                         sourceFingerprint: source.fingerprint,
                                                         action: action,
                                                         targetFingerprint: targetFingerprint)
        return GraphAutomationProposal(
            id: id,
            providerVersion: providerVersion,
            relationship: relationship,
            action: action,
            source: source,
            target: target,
            score: match.score,
            relationshipConfidence: match.signal.confidence,
            sharedAnchors: match.signal.sharedAnchors,
            subjectActionSimilarity: match.subjectSimilarity,
            reason: match.signal.reason,
            isAmbiguous: isAmbiguous,
            hasExistingFolderConflict: hasExistingFolderConflict,
            hasManualGroupMergeConflict: hasManualGroupMergeConflict,
            steps: steps(action: action,
                         source: source,
                         targetThreadID: targetThreadID,
                         resultingThreadID: resultThreadID,
                         folder: folder,
                         followsMailboxMapping: followsMailboxMapping),
            status: .pendingReview,
            mailStatus: .notRequired,
            retryCount: 0,
            nextRetryAt: nil,
            lastError: nil,
            mutationDelta: nil,
            movedMessages: [],
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private static func steps(action: GraphAutomationAction,
                              source: GraphAutomationSource,
                              targetThreadID: String?,
                              resultingThreadID: String?,
                              folder: ThreadFolder?,
                              followsMailboxMapping: Bool) -> [GraphAutomationStep] {
        var result: [GraphAutomationStep] = []
        switch action {
        case .attachToThread:
            if let targetThreadID, let resultingThreadID {
                result.append(.attach(sourceThreadID: source.effectiveThreadID,
                                      targetThreadID: targetThreadID,
                                      resultingThreadID: resultingThreadID))
                if let folder {
                    result.append(.append(threadID: resultingThreadID, folderID: folder.id))
                }
            }
        case .appendToFolder:
            if let folder {
                result.append(.append(threadID: source.effectiveThreadID, folderID: folder.id))
            }
        }
        if followsMailboxMapping,
           let destination = folder?.mailboxDestination {
            result.append(.mailbox(messageIDs: source.messages.map(\.messageID),
                                   account: destination.account,
                                   mailboxPath: destination.path))
        }
        return result
    }

    private static func resultingThreadID(for proposal: GraphAutomationProposal) -> String? {
        proposal.steps.compactMap { step -> String? in
            guard case .attach(_, _, let resultingThreadID) = step else { return nil }
            return resultingThreadID
        }.first
    }

    private static func folderFingerprint(_ folder: ThreadFolder) -> String {
        GraphAutomationIdentity.make([
            "graph-automation-folder-v1",
            folder.id,
            folder.title,
            String(folder.color.red),
            String(folder.color.green),
            String(folder.color.blue),
            String(folder.color.alpha),
            folder.parentID ?? "",
            folder.mailboxAccount ?? "",
            folder.mailboxPath ?? "",
            folder.threadIDs.sorted().joined(separator: ",")
        ])
    }

    private static func folderID(for threadID: String, in folders: [ThreadFolder]) -> String? {
        folders.first { $0.threadIDs.contains(threadID) }?.id
    }

    private static func targetFingerprintMatches(
        _ proposal: GraphAutomationProposal,
        sourcesByID: [String: GraphAutomationSource],
        folders: [ThreadFolder]
    ) -> Bool {
        switch proposal.action {
        case .appendToFolder:
            guard let folderID = proposal.target.folderID,
                  let folder = folders.first(where: { $0.id == folderID }) else { return false }
            return folderFingerprint(folder) == proposal.target.fingerprint
        case .attachToThread:
            guard let targetThreadID = proposal.target.threadID,
                  let target = sourcesByID[targetThreadID] else { return false }
            let folderFingerprintValue = proposal.target.folderID.flatMap { folderID in
                folders.first(where: { $0.id == folderID }).map(folderFingerprint)
            } ?? ""
            return GraphAutomationIdentity.make([target.fingerprint, folderFingerprintValue]) == proposal.target.fingerprint
        }
    }

    private static func shouldPreferAttachmentTarget(
        _ target: GraphAutomationSource,
        over source: GraphAutomationSource,
        folders: [ThreadFolder]
    ) -> Bool {
        let targetIsConfirmed = folderID(for: target.effectiveThreadID, in: folders) != nil
        let sourceIsConfirmed = folderID(for: source.effectiveThreadID, in: folders) != nil
        if targetIsConfirmed != sourceIsConfirmed { return targetIsConfirmed }
        let targetIsManual = target.manualGroupID != nil
        let sourceIsManual = source.manualGroupID != nil
        if targetIsManual != sourceIsManual { return targetIsManual }
        if target.oldestMessageDate != source.oldestMessageDate {
            return target.oldestMessageDate < source.oldestMessageDate
        }
        return target.effectiveThreadID < source.effectiveThreadID
    }

    private static func attachmentPriority(
        _ source: GraphAutomationSource,
        folders: [ThreadFolder]
    ) -> Int {
        if folderID(for: source.effectiveThreadID, in: folders) != nil { return 2 }
        if source.manualGroupID != nil { return 1 }
        return 0
    }

    private static func matchComesFirst(_ lhs: RelationshipMatch,
                                        _ rhs: RelationshipMatch,
                                        folders: [ThreadFolder]) -> Bool {
        guard let lhsSource = lhs.source, let rhsSource = rhs.source else { return lhs.score > rhs.score }
        let lhsInFolder = folderID(for: lhsSource.effectiveThreadID, in: folders) != nil
        let rhsInFolder = folderID(for: rhsSource.effectiveThreadID, in: folders) != nil
        if lhsInFolder != rhsInFolder { return lhsInFolder }
        if (lhsSource.manualGroupID != nil) != (rhsSource.manualGroupID != nil) {
            return lhsSource.manualGroupID != nil
        }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhsSource.oldestMessageDate != rhsSource.oldestMessageDate {
            return lhsSource.oldestMessageDate < rhsSource.oldestMessageDate
        }
        return lhsSource.effectiveThreadID < rhsSource.effectiveThreadID
    }

    private static func proposalComesFirst(_ lhs: GraphAutomationProposal,
                                           _ rhs: GraphAutomationProposal) -> Bool {
        if lhs.action != rhs.action { return lhs.action == .attachToThread }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.id < rhs.id
    }

    private static func flatten(_ node: ThreadNode) -> [ThreadNode] {
        [node] + node.children.flatMap(flatten)
    }

    private static func representativeContent(_ nodes: [ThreadNode]) -> String {
        let indices: [Int]
        if nodes.count <= 4 {
            indices = Array(nodes.indices)
        } else {
            indices = Array(Set([0, nodes.count / 3, (nodes.count * 2) / 3, nodes.count - 1])).sorted()
        }
        return indices.enumerated().map { offset, index in
            let message = nodes[index].message
            return "\(offset + 1). Subject: \(String(message.subject.prefix(200))) | From: \(String(message.from.prefix(120))) | Content: \(String(message.snippet.prefix(600)))"
        }.joined(separator: "\n")
    }

    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs)
        guard !union.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union.count)
    }

    private static func nextRetryDate(count: Int,
                                      now: Date,
                                      manualRetry: Bool) -> Date? {
        if manualRetry || count >= 3 { return nil }
        let delays: [TimeInterval] = [60, 300, 1_800]
        return now.addingTimeInterval(delays[max(0, min(count - 1, delays.count - 1))])
    }

    private static var pausedStatusMessage: String {
        NSLocalizedString("graph.automation.status.paused",
                          comment: "Graph automation is paused")
    }
}

private struct FolderProfile {
    let folder: ThreadFolder
    let summary: String
    let content: String
    let fingerprint: String
}

private struct RelationshipMatch {
    let source: GraphAutomationSource?
    let folderProfile: FolderProfile?
    let signal: GraphAutomationRelationshipSignal
    let score: Double
    let anchorOverlap: Double
    let subjectSimilarity: Double
}

private struct MailLocation: Hashable {
    let account: String
    let mailbox: String

    var id: String { "\(account.lowercased())|\(mailbox.lowercased())" }

    func matches(account candidateAccount: String, mailbox candidateMailbox: String) -> Bool {
        account.caseInsensitiveCompare(candidateAccount) == .orderedSame &&
            mailbox.caseInsensitiveCompare(candidateMailbox) == .orderedSame
    }
}

private struct MailRestoreRoute: Hashable {
    let destination: MailLocation
    let origin: MailLocation

    var id: String { destination.id + "->" + origin.id }
}
