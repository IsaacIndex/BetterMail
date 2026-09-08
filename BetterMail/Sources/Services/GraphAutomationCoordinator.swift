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

internal nonisolated struct GraphAutomationApprovalPlan: Equatable, Sendable {
    internal let pendingIDs: Set<String>
    internal let betterMailOnlyCount: Int
    internal let mailChangingCount: Int
    internal let conflictingProposalIDs: Set<String>

    internal var conflictCount: Int { conflictingProposalIDs.count }
    internal var requiresMailConfirmation: Bool { mailChangingCount > 0 }
}

internal nonisolated enum GraphAutomationApprovalPlanner {
    internal static func make(proposals: [GraphAutomationProposal],
                              restrictingTo requestedIDs: Set<String>? = nil) -> GraphAutomationApprovalPlan {
        let pending = proposals.filter { proposal in
            proposal.status == .pendingReview
                && (requestedIDs?.contains(proposal.id) ?? true)
        }
        let sourceCounts = Dictionary(grouping: pending, by: { $0.source.effectiveThreadID })
            .mapValues(\.count)
        let conflictingIDs = Set(pending.compactMap { proposal in
            (sourceCounts[proposal.source.effectiveThreadID] ?? 0) > 1 ? proposal.id : nil
        })
        let mailChangingCount = pending.filter { proposal in
            proposal.steps.contains { step in
                if case .mailbox = step { return true }
                return false
            }
        }.count
        return GraphAutomationApprovalPlan(
            pendingIDs: Set(pending.map(\.id)),
            betterMailOnlyCount: pending.count - mailChangingCount,
            mailChangingCount: mailChangingCount,
            conflictingProposalIDs: conflictingIDs
        )
    }
}

@MainActor
internal final class GraphAutomationCoordinator: ObservableObject {
    private enum MailRestorePurpose: Equatable {
        case compensation
        case undo
    }

    private struct MailRestoreAttempt {
        let remaining: [GraphSnipMovedMessage]
        let requiresManualRecovery: Bool
    }

    @Published internal private(set) var proposals: [GraphAutomationProposal] = []
    @Published internal private(set) var topicSignalsByRawThreadID: [String: GraphTopicSignal] = [:]
    @Published internal private(set) var isEvaluating = false
    @Published internal private(set) var providerStatusMessage = ""
    @Published internal private(set) var lastEvaluatedAt: Date?
    @Published internal private(set) var mailAutomationConsentStatus: OrganizationMailAutomationConsentStatus = .absent

    internal let settings: GraphAutomationSettings
    internal var onOrganizationChanged: (() -> Void)?

    internal var attentionCount: Int {
        proposals.filter(\.needsAttention).count
    }

    internal var pendingProposals: [GraphAutomationProposal] {
        proposals.filter { $0.status == .pendingReview }
    }

    private let store: MessageStore
    private let organizationMailService: (any OrganizationMailExecutionServicing)?
    private let metricsRecorder: OrganizerMetricsRecorder?
    private let mailAutomationConsentProvider: @MainActor () -> OrganizationMailAutomationConsentResolution
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
        organizationOperationStore: OrganizationOperationStore = .shared,
        organizationMailService: (any OrganizationMailExecutionServicing)? = nil,
        metricsRecorder: OrganizerMetricsRecorder? = nil,
        mailAutomationConsentProvider: @escaping @MainActor () -> OrganizationMailAutomationConsentResolution = {
            OrganizationMailAutomationConsent.resolve(from: .standard)
        },
        relationshipCapabilityProvider: @escaping @MainActor () -> GraphRelationshipCapability = GraphRelationshipProviderFactory.makeCapability,
        topicCapabilityProvider: @escaping @MainActor () -> GraphTopicCapability = GraphTopicProviderFactory.makeCapability
    ) {
        self.store = store
        self.settings = settings ?? GraphAutomationSettings()
        self.metricsRecorder = metricsRecorder
        if let organizationMailService {
            self.organizationMailService = organizationMailService
        } else if let mailClient {
            self.organizationMailService = OrganizationMailExecutionService(
                operationStore: organizationOperationStore,
                transport: DefaultOrganizationMailGatewayTransport(mailClient: mailClient),
                metricsRecorder: metricsRecorder
            )
        } else {
            self.organizationMailService = nil
        }
        self.mailAutomationConsentProvider = mailAutomationConsentProvider
        self.relationshipCapabilityProvider = relationshipCapabilityProvider
        self.topicCapabilityProvider = topicCapabilityProvider
        self.mailAutomationConsentStatus = mailAutomationConsentProvider().status
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

    internal func approvalPlanForAllPending() -> GraphAutomationApprovalPlan {
        GraphAutomationApprovalPlanner.make(proposals: proposals)
    }

    /// Applies the exact pending set captured when Approve All was invoked.
    /// A batch containing physical Mail work cannot start unless the caller
    /// records a separate confirmation for that disclosed category.
    internal func approveAll(plan: GraphAutomationApprovalPlan? = nil,
                             mailEffectsConfirmed: Bool = false) async {
        let frozenPlan = plan ?? approvalPlanForAllPending()
        guard !frozenPlan.pendingIDs.isEmpty else { return }
        guard !frozenPlan.requiresMailConfirmation || mailEffectsConfirmed else { return }
        await approve(ids: frozenPlan.pendingIDs)
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
            if !changed.isEmpty {
                await metricsRecorder?.recordEvent(.suggestionDecision,
                                                   count: changed.count,
                                                   status: .success)
            }
        } catch {
            if !changed.isEmpty {
                await metricsRecorder?.recordEvent(.suggestionDecision,
                                                   count: changed.count,
                                                   status: .failure)
            }
            Log.app.error("Failed to persist graph automation rejection: \(error.localizedDescription, privacy: .private)")
        }
        sortPublishedProposals()
    }

    internal func changeDestination(proposalID: String, folderID: String) async {
        guard let snapshot = currentSnapshot,
              let oldIndex = proposals.firstIndex(where: { $0.id == proposalID }),
              let folder = snapshot.folders.first(where: { $0.id == folderID }) else { return }
        let old = proposals[oldIndex]
        let folderFingerprint = Self.folderFingerprint(folder)
        let targetSource = OrganizationSourceSnapshotBuilder.build(from: snapshot).first {
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
            Log.app.error("Failed to persist edited automation destination: \(error.localizedDescription, privacy: .private)")
        }
        sortPublishedProposals()
    }

    internal func retry(_ proposalID: String) async {
        guard let proposal = proposals.first(where: { $0.id == proposalID }) else { return }
        if proposal.status == .recoveryNeeded {
            switch proposal.mailStatus {
            case .compensating:
                await finishMailRestore(for: proposal, purpose: .compensation)
            case .restoring:
                await finishMailRestore(for: proposal, purpose: .undo)
            default:
                // Unknown external outcomes require reconciliation and must not
                // be repeated through an ordinary Retry action.
                return
            }
            return
        }
        if proposal.status == .undoing, !proposal.movedMessages.isEmpty {
            await finishMailRestore(for: proposal, purpose: .undo)
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
                await finishMailRestore(for: undoing, purpose: .undo)
            }
            await metricsRecorder?.recordEvent(.undo,
                                               count: 1,
                                               status: .success)
        } catch {
            await metricsRecorder?.recordEvent(.undo,
                                               count: 1,
                                               status: .failure)
            await metricsRecorder?.recordEvent(.recovery,
                                               count: 1,
                                               status: .failure)
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
            Log.app.error("Failed to reset graph automation history: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func evaluate(snapshot: GraphAutomationSnapshot,
                          scansCurrentMail: Bool,
                          refreshID requestedRefreshID: UUID) async {
        mailAutomationConsentStatus = mailAutomationConsentProvider().status
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

            let sources = OrganizationSourceSnapshotBuilder.build(from: snapshot)
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
                guard settings.mode(for: proposal.action) == .automatic else { return false }
                return OrganizationPlacementPolicy.allowsAutomatic(
                    score: proposal.score,
                    automaticThreshold: settings.automaticThreshold(for: proposal.action),
                    isPaused: settings.isPaused,
                    isAmbiguous: proposal.isAmbiguous,
                    hasExistingFolderConflict: proposal.hasExistingFolderConflict,
                    hasManualGroupMergeConflict: proposal.hasManualGroupMergeConflict
                )
            }
            await apply(automatic, snapshot: snapshot, allowsReviewedConflicts: false)
            await retryDueMailboxOperations(now: now)
            try await store.pruneGraphAutomationHistory(now: now)
        } catch is CancellationError {
            return
        } catch {
            providerStatusMessage = error.localizedDescription
            Log.app.error("Graph automation evaluation failed: \(error.localizedDescription, privacy: .private)")
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
            Log.app.error("Failed to load refresh-owned graph topic cache: \(error.localizedDescription, privacy: .private)")
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
                Log.app.error("Refresh-owned graph topic generation failed: \(error.localizedDescription, privacy: .private)")
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
            if let winner = orderedAttach.first,
               OrganizationPlacementPolicy.isReviewable(score: winner.score,
                                                        thresholds: attachThresholds),
               let targetSource = winner.source {
                let winnerPriority = Self.attachmentPriority(targetSource, folders: snapshot.folders)
                let runnerUpScore = orderedAttach.dropFirst().first(where: { match in
                    guard let candidate = match.source else { return false }
                    return Self.attachmentPriority(candidate, folders: snapshot.folders) == winnerPriority
                })?.score ?? 0
                let isAmbiguous = OrganizationPlacementPolicy.isAmbiguous(
                    winnerScore: winner.score,
                    runnerUpScore: runnerUpScore,
                    thresholds: attachThresholds
                )
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
                  OrganizationPlacementPolicy.isReviewable(score: winner.score,
                                                           thresholds: folderThresholds),
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
                isAmbiguous: OrganizationPlacementPolicy.isAmbiguous(
                    winnerScore: winner.score,
                    runnerUpScore: runnerUpScore,
                    thresholds: folderThresholds
                ),
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
        let currentSources = OrganizationSourceSnapshotBuilder.build(from: snapshot)
        let sourceByID = Dictionary(uniqueKeysWithValues: currentSources.map { ($0.effectiveThreadID, $0) })
        let sourceCounts = Dictionary(grouping: selected, by: { $0.source.effectiveThreadID })
            .mapValues(\.count)
        var valid: [GraphAutomationProposal] = []
        var invalid: [GraphAutomationProposal] = []

        for original in selected.sorted(by: Self.proposalComesFirst) {
            var proposal = original
            if (sourceCounts[proposal.source.effectiveThreadID] ?? 0) > 1 {
                proposal.status = .pendingReview
                proposal.lastError = NSLocalizedString(
                    "graph.automation.error.duplicate_source_conflict",
                    comment: "Approve All conflict when multiple proposals use the same source"
                )
                proposal.updatedAt = Date()
                invalid.append(proposal)
                continue
            }
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
            await metricsRecorder?.recordEvent(.suggestionDecision,
                                               count: invalid.count,
                                               status: .failure)
        }
        guard !valid.isEmpty else { return }
        await metricsRecorder?.recordEvent(.actionStart,
                                           count: 1)
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
            await metricsRecorder?.recordEvent(.suggestionDecision,
                                               count: result.proposals.count,
                                               status: .success)
            await metricsRecorder?.recordEvent(.groupCommitted,
                                               count: result.proposals.count,
                                               status: .success)
            await metricsRecorder?.recordEvent(.betterMailCommit,
                                               count: 1,
                                               status: .success)
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
            await metricsRecorder?.recordEvent(.suggestionDecision,
                                               count: failures.count,
                                               status: .failure)
            await metricsRecorder?.recordEvent(.groupCommitted,
                                               count: failures.count,
                                               status: .failure,
                                               failureReason: .actionFailure)
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
        guard let currentConsent = currentMailAutomationConsent(allows: .messageMove) else {
            proposal.status = .failed
            proposal.mailStatus = .failed
            proposal.retryCount = 0
            proposal.nextRetryAt = nil
            proposal.lastError = NSLocalizedString(
                "graph.automation.error.mail_consent_required",
                comment: "Automatic Mail movement requires separate current consent"
            )
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        guard let organizationMailService else {
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
        let messagesRequiringMove = proposal.source.messages.filter {
            !$0.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !destination.matches(account: $0.accountName, mailbox: $0.mailboxPath)
        }
        guard !messagesRequiringMove.isEmpty else {
            proposal.status = .applied
            proposal.mailStatus = .moved
            proposal.movedMessages = []
            proposal.retryCount = 0
            proposal.nextRetryAt = nil
            proposal.lastError = nil
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        let exactRoutes = messagesRequiringMove.map {
            OrganizationMailRoute(messageID: $0.messageID,
                                  account: $0.accountName,
                                  mailboxPath: $0.mailboxPath)
        }
        let disclosedEffect = OrganizationEffect.mixed(
            operation: .mappedAutomation,
            betterMailChange: .groupMembership,
            mailMutations: [.messageMove],
            messageCount: exactRoutes.count,
            sourceRoutes: exactRoutes,
            destination: .mailbox(account: destination.account, path: destination.mailbox),
            reversibility: .conditionallyReversible
        )
        let authorization: OrganizationMailAuthorization
        do {
            authorization = try OrganizationMailAuthorization.fromCurrentConsent(
                effect: disclosedEffect,
                consent: currentConsent
            )
        } catch {
            proposal.status = .failed
            proposal.mailStatus = .failed
            proposal.retryCount = 0
            proposal.nextRetryAt = nil
            proposal.lastError = NSLocalizedString(
                "graph.automation.error.mail_disclosure_incomplete",
                comment: "Automatic Mail movement requires complete exact source routes"
            )
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        let gatewayOutcome: OrganizationMailGatewayOutcome
        do {
            gatewayOutcome = try await organizationMailService.move(
                OrganizationMailMoveExecution(
                    operationID: OrganizationMailOperationIdentifier.make(
                        namespace: "graph-automation-move",
                        seed: "\(proposal.id)|attempt:\(proposal.retryCount)"
                    ),
                    kind: .automation,
                    effect: disclosedEffect,
                    authorization: authorization,
                    currentConsent: currentConsent,
                    routes: exactRoutes,
                    destination: .mailbox(account: destination.account,
                                          path: destination.mailbox),
                    now: Date()
                )
            )
        } catch {
            Log.app.error("Graph automation Mail move failed. messageCount=\(exactRoutes.count, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)")
            proposal.movedMessages = []
            if Self.requiresManualMailRecovery(error) {
                proposal.status = .recoveryNeeded
                proposal.mailStatus = .recoveryNeeded
                proposal.nextRetryAt = nil
                proposal.lastError = NSLocalizedString(
                    "graph.automation.error.mail_recovery_required",
                    comment: "Mail outcome is unknown and requires manual recovery"
                )
            } else {
                proposal.status = .failed
                proposal.mailStatus = .failed
                proposal.retryCount = min(3, proposal.retryCount + 1)
                proposal.nextRetryAt = Self.nextRetryDate(count: proposal.retryCount,
                                                          now: Date(),
                                                          manualRetry: isManualRetry)
                proposal.lastError = NSLocalizedString(
                    "graph.automation.error.mail_move_failed",
                    comment: "Mail move failed but app grouping was retained"
                )
            }
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        let completedRoutes = Set(gatewayOutcome.completedRoutes)
        let moved = messagesRequiringMove.compactMap { message -> GraphSnipMovedMessage? in
            let route = OrganizationMailRoute(messageID: message.messageID,
                                              account: message.accountName,
                                              mailboxPath: message.mailboxPath)
            guard completedRoutes.contains(route) else { return nil }
            return GraphSnipMovedMessage(messageID: message.messageID,
                                         sourceMailboxPath: message.mailboxPath,
                                         sourceAccountName: message.accountName,
                                         destinationMailboxPath: destination.mailbox,
                                         destinationAccountName: destination.account)
        }
        let requiredIDs = Set(messagesRequiringMove.map {
            GraphSnipMessage.locationIdentity(messageID: $0.messageID,
                                              accountName: $0.accountName,
                                              mailboxPath: $0.mailboxPath)
        })
        let movedIDs = Set(moved.map(\.id))
        if gatewayOutcome.phase == .recovery {
            proposal.status = .recoveryNeeded
            proposal.mailStatus = .recoveryNeeded
            proposal.movedMessages = moved.sorted { $0.id < $1.id }
            proposal.nextRetryAt = nil
            proposal.lastError = NSLocalizedString(
                "graph.automation.error.mail_recovery_required",
                comment: "Mail outcome is unknown and requires manual recovery"
            )
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        if gatewayOutcome.isComplete, requiredIDs.isSubset(of: movedIDs) {
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
            guard currentMailAutomationConsent(allows: .messageRestore) != nil else {
                proposal.status = .recoveryNeeded
                proposal.mailStatus = .recoveryNeeded
                proposal.movedMessages = moved.sorted { $0.id < $1.id }
                proposal.nextRetryAt = nil
                proposal.lastError = NSLocalizedString(
                    "graph.automation.error.mail_restore_consent_required",
                    comment: "Automatic Mail restoration requires separate current consent"
                )
                proposal.updatedAt = Date()
                await persistAndMerge(proposal)
                return
            }
            proposal.mailStatus = .compensating
            await persistAndMerge(proposal)
            let restoreAttempt = await restoreMovedMessages(
                moved,
                operationSeed: "compensate|\(proposal.id)"
            )
            if restoreAttempt.requiresManualRecovery {
                proposal.status = .recoveryNeeded
                proposal.mailStatus = .recoveryNeeded
                proposal.movedMessages = restoreAttempt.remaining
                proposal.nextRetryAt = nil
                proposal.lastError = NSLocalizedString(
                    "graph.automation.error.mail_recovery_required",
                    comment: "Mail outcome is unknown and requires manual recovery"
                )
                proposal.updatedAt = Date()
                await persistAndMerge(proposal)
                return
            }
            if !restoreAttempt.remaining.isEmpty {
                proposal.status = .recoveryNeeded
                proposal.mailStatus = .compensating
                proposal.movedMessages = restoreAttempt.remaining
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
        await metricsRecorder?.recordEvent(.recovery,
                                           count: max(original.movedMessages.count, 1),
                                           status: proposal.status == .recoveryNeeded ? .failure : .success)
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

    private func finishMailRestore(for original: GraphAutomationProposal,
                                   purpose: MailRestorePurpose) async {
        var proposal = original
        guard !proposal.movedMessages.isEmpty else {
            proposal.status = purpose == .undo ? .undone : .failed
            proposal.mailStatus = purpose == .undo ? .restored : .failed
            proposal.lastError = nil
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        guard currentMailAutomationConsent(allows: .messageRestore) != nil else {
            proposal.status = .recoveryNeeded
            proposal.mailStatus = purpose == .undo ? .restoring : .compensating
            proposal.lastError = NSLocalizedString(
                "graph.automation.error.mail_restore_consent_required",
                comment: "Automatic Mail restoration requires separate current consent"
            )
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        guard organizationMailService != nil else {
            proposal.status = .recoveryNeeded
            proposal.mailStatus = purpose == .undo ? .restoring : .compensating
            proposal.lastError = NSLocalizedString("graph.automation.error.mail_unavailable",
                                                   comment: "Mail movement is unavailable")
            proposal.updatedAt = Date()
            await persistAndMerge(proposal)
            return
        }
        let seedPrefix = purpose == .undo ? "undo" : "compensate"
        let restoreAttempt = await restoreMovedMessages(
            proposal.movedMessages,
            operationSeed: "\(seedPrefix)|\(proposal.id)"
        )
        proposal.movedMessages = restoreAttempt.remaining
        if restoreAttempt.requiresManualRecovery {
            proposal.status = .recoveryNeeded
            proposal.mailStatus = .recoveryNeeded
            proposal.lastError = NSLocalizedString(
                "graph.automation.error.mail_recovery_required",
                comment: "Mail outcome is unknown and requires manual recovery"
            )
        } else if restoreAttempt.remaining.isEmpty {
            proposal.status = purpose == .undo ? .undone : .failed
            proposal.mailStatus = purpose == .undo ? .restored : .failed
            proposal.lastError = purpose == .undo ? nil : NSLocalizedString(
                "graph.automation.error.mail_move_failed",
                comment: "Mail move failed but app grouping was retained"
            )
        } else {
            proposal.status = .recoveryNeeded
            proposal.mailStatus = purpose == .undo ? .restoring : .compensating
            proposal.lastError = NSLocalizedString(
                purpose == .undo
                    ? "graph.automation.error.undo_recovery"
                    : "graph.automation.error.partial_recovery",
                comment: "Automation restore has exact residual routes"
            )
        }
        proposal.updatedAt = Date()
        await persistAndMerge(proposal)
    }

    private func currentMailAutomationConsent(
        allows effect: OrganizationMailAutomationEffect
    ) -> OrganizationMailAutomationConsent? {
        let resolution = mailAutomationConsentProvider()
        mailAutomationConsentStatus = resolution.status
        guard case .current(let consent) = resolution,
              consent.allows(effect) else {
            return nil
        }
        return consent
    }

    private func restoreMovedMessages(
        _ movedMessages: [GraphSnipMovedMessage],
        operationSeed: String
    ) async -> MailRestoreAttempt {
        guard let organizationMailService,
              let currentConsent = currentMailAutomationConsent(allows: .messageRestore) else {
            return MailRestoreAttempt(remaining: movedMessages,
                                      requiresManualRecovery: false)
        }
        let routes = movedMessages.map { message in
            OrganizationMailRestoreRoute(
                current: OrganizationMailRoute(messageID: message.messageID,
                                               account: message.destinationAccountName,
                                               mailboxPath: message.destinationMailboxPath),
                destination: OrganizationMailRoute(messageID: message.messageID,
                                                   account: message.sourceAccountName,
                                                   mailboxPath: message.sourceMailboxPath)
            )
        }
        let now = Date()
        let effect = OrganizationEffect.appleMail(
            operation: .automationRecovery,
            mutation: .messageRestore,
            messageCount: routes.count,
            sourceRoutes: routes.map(\.current),
            destination: .originalSourceRoutes,
            reversibility: .conditionallyReversible
        )
        do {
            let authorization = try OrganizationMailAuthorization.fromCurrentConsent(
                effect: effect,
                consent: currentConsent,
                now: now
            )
            let outcome = try await organizationMailService.restore(
                OrganizationMailRestoreExecution(
                    operationID: OrganizationMailOperationIdentifier.makeRestore(
                        namespace: "graph-automation-restore",
                        seed: operationSeed,
                        routes: routes
                    ),
                    kind: .recovery,
                    effect: effect,
                    authorization: authorization,
                    currentConsent: currentConsent,
                    routes: routes,
                    now: now
                )
            )
            if outcome.phase == .recovery {
                return MailRestoreAttempt(remaining: movedMessages,
                                          requiresManualRecovery: true)
            }
            let completed = Set(outcome.completedRoutes)
            let remaining = movedMessages.filter { message in
                let current = OrganizationMailRoute(messageID: message.messageID,
                                                    account: message.destinationAccountName,
                                                    mailboxPath: message.destinationMailboxPath)
                return !completed.contains(current)
            }
            return MailRestoreAttempt(remaining: remaining,
                                      requiresManualRecovery: false)
        } catch {
            Log.app.error("Graph automation Mail restore failed. messageCount=\(routes.count, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)")
            return MailRestoreAttempt(
                remaining: movedMessages,
                requiresManualRecovery: Self.requiresManualMailRecovery(error)
            )
        }
    }

    private static func requiresManualMailRecovery(_ error: Error) -> Bool {
        if let gatewayError = error as? OrganizationMailGatewayError {
            switch gatewayError {
            case .transportFailed, .invalidTransportResult, .ledgerFailureAfterExternalCall:
                return true
            default:
                return false
            }
        }
        if let serviceError = error as? OrganizationMailExecutionServiceError,
           case .operationInFlight = serviceError {
            return true
        }
        return false
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
            Log.app.error("Failed to persist graph automation state: \(error.localizedDescription, privacy: .private)")
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
