import Foundation

/// The benchmark strata used by the organizer acceptance contract.
internal nonisolated enum OrganizerMetricStratum: String, Codable, CaseIterable, Hashable, Sendable {
    case warm
    case coldRelaunch = "cold-relaunch"
    case aggregate
}

internal nonisolated enum OrganizerMetricEvidenceType: String, Codable, CaseIterable, Hashable, Sendable {
    case automatedLogic = "automated-logic"
    case build
    case installedAppLaunch = "installed-app-launch"
    case livePointer = "live-pointer"
    case accessibilityAudit = "accessibility-audit"
    case timedHumanTask = "timed-human-task"
}

internal nonisolated enum OrganizerTimedMetricKind: String, Codable, CaseIterable, Hashable, Sendable {
    case firstAction
    case fiveConversation
    case retrieval
}

internal nonisolated enum OrganizerDropSource: String, Codable, CaseIterable, Hashable, Sendable {
    case deterministicMatrix
    case livePointer
}

internal nonisolated enum OrganizerMetricOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case failure
    case invalid
    case cancelled
}

/// The complete privacy-safe vocabulary emitted by the visual organizer.
/// Callers can supply counts and coarse outcomes, but there is deliberately no
/// free-form metadata field that could carry Mail content, routes, or IDs.
internal nonisolated enum OrganizerMetricEventKind: String, Codable, CaseIterable, Hashable, Sendable {
    case workspaceReady = "workspace-ready"
    case taskVisible = "task-visible"
    case taskReady = "task-ready"
    case searchStart = "search-start"
    case actionStart = "action-start"
    case selection
    case dropIntent = "drop-intent"
    case dropHighlight = "drop-highlight"
    case dropRelease = "drop-release"
    case dropOutcome = "drop-outcome"
    case groupCommitted = "group-committed"
    case betterMailCommit = "bettermail-commit"
    case groupRethreaded = "group-rethreaded"
    case rethreadComplete = "rethread-complete"
    case groupVisible = "group-visible"
    case visibleResult = "visible-result"
    case suggestionDecision = "suggestion-decision"
    case mailAuthorization = "mail-authorization"
    case mailResult = "mail-result"
    case undo
    case recovery
    case retrievalVisible = "retrieval-visible"
    case cancelled
    case failure
}

internal nonisolated enum OrganizerMetricEventPhase: String, Codable, Hashable, Sendable {
    case instant
    case started
    case finished
}

/// A sanitized event relative to the recorder session's monotonic origin.
internal nonisolated struct OrganizerMetricEventRecord: Codable, Hashable, Sendable {
    internal let sequence: Int
    internal let event: OrganizerMetricEventKind
    internal let phase: OrganizerMetricEventPhase
    internal let stratum: OrganizerMetricStratum?
    internal let count: Int
    internal let status: OrganizerMetricOutcome?
    internal let offsetMilliseconds: Int64
    internal let durationMilliseconds: Int64?
}

/// Type-erased monotonic source. The live factory owns a `ContinuousClock` and
/// its origin; tests may inject a deterministic millisecond source without
/// sleeping or consulting wall-clock time.
internal nonisolated struct OrganizerMetricsMonotonicClock: Sendable {
    private let readMilliseconds: @Sendable () -> Int64

    internal init(readMilliseconds: @escaping @Sendable () -> Int64) {
        self.readMilliseconds = readMilliseconds
    }

    internal static func continuous() -> OrganizerMetricsMonotonicClock {
        let clock = ContinuousClock()
        let origin = clock.now
        return OrganizerMetricsMonotonicClock {
            let components = origin.duration(to: clock.now).components
            return components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        }
    }

    internal func nowMilliseconds() -> Int64 {
        readMilliseconds()
    }
}

internal nonisolated enum OrganizerSuggestionStrictness: String, Codable, CaseIterable, Hashable, Sendable {
    case conservative
    case balanced
    case aggressive
}

internal nonisolated enum OrganizerSuggestionSlice: String, Codable, CaseIterable, Hashable, Sendable {
    case attach
    case append
    case unrelated
}

internal nonisolated enum OrganizerMetricEvaluationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pass
    case fail
    case invalid
    case pending
    case insufficientEvidence = "insufficient-evidence"
}

internal nonisolated enum OrganizerMetricCoarseFailureReason: String, Codable, CaseIterable, Hashable, Sendable {
    case instrumentationBeforeTaskReady = "instrumentation-before-task-ready"
    case cancelled
    case actionFailure = "action-failure"
    case wrongCompletion = "wrong-completion"
    case appTermination = "app-termination"
    case missingRethread = "missing-rethread"
    case missingVisibleConfirmation = "missing-visible-confirmation"
    case missingRetrieval = "missing-retrieval"
    case unresolvedOutcome = "unresolved-outcome"
    case invalidTarget = "invalid-target"
}

internal nonisolated enum OrganizerMetricTargetOutcome: String, Codable, Hashable, Sendable {
    case organization
    case retrieval
    case pointerDrop = "pointer-drop"
    case placement
    case accessibility
}

/// Frozen, synthetic task identity carried into each sanitized trial. These
/// keys describe benchmark fixtures only; they never contain Mail-derived IDs.
internal nonisolated enum OrganizerMetricTaskID: String, Codable, Hashable, Sendable {
    case diagnostic
    case livePointer = "live-pointer"
    case placementSet = "placement-set"
    case firstOrganization = "first-organization"
    case fiveConversationOrganization = "five-conversation-organization"
    case retrieval
}

internal nonisolated struct OrganizerMetricTaskContract: Codable, Hashable, Sendable {
    internal let taskID: OrganizerMetricTaskID
    internal let sourceNodeKeys: [String]
    internal let destinationGroupKeys: [String]
    internal let queryKey: String?

    internal static let diagnostic = OrganizerMetricTaskContract(
        taskID: .diagnostic,
        sourceNodeKeys: [],
        destinationGroupKeys: [],
        queryKey: nil
    )
}

/// Process-local identity used to prove that a timed benchmark completed the
/// exact requested organization outcome. Unlike `OrganizerMetricTaskContract`,
/// these raw synthetic conversation IDs are never encoded into result files.
internal nonisolated struct OrganizerMetricExpectedMembership: Hashable, Sendable {
    internal let rawThreadID: String
    internal let destinationGroupKey: String
}

internal nonisolated struct OrganizerMetricRuntimeTaskContract: Hashable, Sendable {
    internal let expectedMemberships: [OrganizerMetricExpectedMembership]
    internal let placementSetID: String?
    internal let allowsRetrievalTiming: Bool

    internal static let diagnostic = OrganizerMetricRuntimeTaskContract(
        expectedMemberships: [],
        placementSetID: nil,
        allowsRetrievalTiming: false
    )

    internal func isAccessibilityReady(
        for snapshot: OrganizerRenderedGraphSnapshot
    ) -> Bool {
        guard snapshot.isLayoutSettled else { return false }
        let expectedConversationIDs = Set(expectedMemberships.map(\.rawThreadID))
        let expectedGroupKeys = Set(expectedMemberships.map(\.destinationGroupKey))
        if expectedConversationIDs.isEmpty || expectedGroupKeys.isEmpty {
            return !snapshot.accessibleConversationRawThreadIDs.isEmpty
                && !snapshot.accessibleConfirmedGroupKeys.isEmpty
        }
        return expectedConversationIDs.isSubset(of: snapshot.accessibleConversationRawThreadIDs)
            && expectedGroupKeys.isSubset(of: snapshot.accessibleConfirmedGroupKeys)
    }
}

internal nonisolated enum OrganizerMetricsRecorderError: Error, Equatable, Sendable {
    case invalidSyntheticIdentifier
    case duplicateSampleIdentifier
    case duplicateSetIdentifier
    case invalidDuration
    case invalidCount
    case invalidSuggestionCounts
    case exportFailed
}

/// A small validation boundary preventing raw Mail identifiers from entering
/// the local aggregate recorder. Values are deliberately synthetic fixture/run
/// keys, never message IDs, account names, mailbox paths, or routes.
private nonisolated enum OrganizerMetricsPrivacy {
    static let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    static func validate(_ value: String, prefixes: [String]) -> Bool {
        !value.isEmpty
            && value.count <= 128
            && prefixes.contains(where: value.hasPrefix)
            && value.unicodeScalars.allSatisfy(allowedCharacters.contains)
    }

    static func validateRunID(_ value: String) -> Bool {
        validate(value, prefixes: ["synthetic-", "run-"])
    }

    static func validateFixtureID(_ value: String) -> Bool {
        validate(value, prefixes: ["fixture-", "organizer-"])
    }

    static func validateProtocolID(_ value: String) -> Bool {
        validate(value, prefixes: ["protocol-", "visual-email-organizer-"])
    }

    static func validateSampleID(_ value: String) -> Bool {
        validate(value, prefixes: ["synthetic-", "run-", "drop-", "placement-"])
    }

    static func validateSetID(_ value: String) -> Bool {
        validate(value, prefixes: ["set-", "placement-set-"])
    }

    static func validateAppBuild(_ value: String) -> Bool {
        validate(value, prefixes: ["build-", "synthetic-"])
    }
}

internal nonisolated struct OrganizerMetricsThresholds: Codable, Hashable, Sendable {
    internal var firstActionP80Milliseconds: Int64
    internal var firstActionMinimumSamplesPerStratum: Int
    internal var fiveConversationP80Milliseconds: Int64
    internal var fiveConversationMinimumSamplesPerStratum: Int
    internal var retrievalP80Milliseconds: Int64
    internal var retrievalMinimumSamplesPerStratum: Int
    internal var deterministicDropMinimumSuccessRate: Double
    internal var deterministicDropPerStratumMinimumSuccessRate: Double
    internal var deterministicDropMinimumAttemptsPerStratum: Int
    internal var livePointerDropMinimumSuccessRate: Double
    internal var wrongPlacementMinimumSets: Int
    internal var wrongPlacementMaximumPerSet: Int
    internal var suggestionMinimumCandidates: Int
    internal var suggestionMinimumAccepted: Int
    internal var suggestionMinimumDecisionCountPerSlice: Int
    internal var suggestionMinimumPrecision: Double
    internal var suggestionConservativeMinimumPrecision: Double
    internal var suggestionMinimumCoverage: Double

    nonisolated internal static let baseline = OrganizerMetricsThresholds(
        firstActionP80Milliseconds: 30_000,
        firstActionMinimumSamplesPerStratum: 10,
        fiveConversationP80Milliseconds: 120_000,
        fiveConversationMinimumSamplesPerStratum: 10,
        retrievalP80Milliseconds: 5_000,
        retrievalMinimumSamplesPerStratum: 20,
        deterministicDropMinimumSuccessRate: 0.95,
        deterministicDropPerStratumMinimumSuccessRate: 0.90,
        deterministicDropMinimumAttemptsPerStratum: 10,
        livePointerDropMinimumSuccessRate: 0.95,
        wrongPlacementMinimumSets: 5,
        wrongPlacementMaximumPerSet: 1,
        suggestionMinimumCandidates: 200,
        suggestionMinimumAccepted: 100,
        suggestionMinimumDecisionCountPerSlice: 25,
        suggestionMinimumPrecision: 0.80,
        suggestionConservativeMinimumPrecision: 0.85,
        suggestionMinimumCoverage: 0.50
    )
}

internal nonisolated struct OrganizerTimingSummary: Codable, Hashable, Sendable {
    internal let kind: OrganizerTimedMetricKind
    internal let stratum: OrganizerMetricStratum
    internal let sampleCount: Int
    internal let validTrialCount: Int
    internal let successCount: Int
    internal let failureCount: Int
    internal let invalidCount: Int
    internal let cancelledCount: Int
    internal let medianMilliseconds: Int64?
    internal let p80Milliseconds: Int64?
    internal let p90Milliseconds: Int64?
    internal let thresholdMilliseconds: Int64
    internal let withinThresholdCount: Int
    internal let withinThresholdRate: Double?
    internal let minimumWithinThresholdRate: Double?
    internal let status: OrganizerMetricEvaluationStatus
}

internal nonisolated struct OrganizerDropSummary: Codable, Hashable, Sendable {
    internal let source: OrganizerDropSource
    internal let stratum: OrganizerMetricStratum
    internal let attemptCount: Int
    internal let successCount: Int
    internal let invalidTargetMutationCount: Int
    internal let successRate: Double?
    internal let minimumSuccessRate: Double
    internal let status: OrganizerMetricEvaluationStatus
}

internal nonisolated struct OrganizerWrongPlacementSetSummary: Codable, Hashable, Sendable {
    internal let setID: String
    internal let attemptCount: Int
    internal let wrongPlacementCount: Int
}

internal nonisolated struct OrganizerWrongPlacementSummary: Codable, Hashable, Sendable {
    internal let stratum: OrganizerMetricStratum
    internal let setCount: Int
    internal let totalAttemptCount: Int
    internal let totalWrongPlacementCount: Int
    internal let maximumWrongPlacementCountPerSet: Int
    internal let minimumSetCount: Int
    internal let maximumWrongPlacementCountPerSetThreshold: Int
    internal let sets: [OrganizerWrongPlacementSetSummary]
    internal let status: OrganizerMetricEvaluationStatus
}

/// Placement-capable slices need an accepted-placement denominator. The
/// unrelated relation is a negative control, so it qualifies on evaluated
/// (non-abstained) decisions instead of rewarding false-positive placements.
internal nonisolated enum OrganizerSuggestionSliceDenominator: String, Codable, Hashable, Sendable {
    case acceptedPlacements
    case nonAbstainedDecisions
}

internal nonisolated struct OrganizerSuggestionSliceSummary: Codable, Hashable, Sendable {
    internal let slice: OrganizerSuggestionSlice
    internal let candidateCount: Int
    internal let acceptedCount: Int
    internal let correctAcceptedCount: Int
    internal let nonAbstainedCount: Int
    internal let denominator: OrganizerSuggestionSliceDenominator
    internal let qualifyingDecisionCount: Int
    internal let minimumQualifyingDecisionCount: Int
}

internal nonisolated struct OrganizerSuggestionSummary: Codable, Hashable, Sendable {
    internal let strictness: OrganizerSuggestionStrictness
    internal let candidateCount: Int
    internal let acceptedCount: Int
    internal let correctAcceptedCount: Int
    internal let nonAbstainedCount: Int
    internal let precision: Double?
    internal let coverage: Double?
    internal let minimumCandidateCount: Int
    internal let minimumAcceptedCount: Int
    internal let minimumDecisionCountPerSlice: Int
    internal let minimumPrecision: Double
    internal let minimumCoverage: Double
    internal let slices: [OrganizerSuggestionSliceSummary]
    internal let status: OrganizerMetricEvaluationStatus
}

internal nonisolated struct OrganizerMetricTrialRecord: Codable, Hashable, Sendable {
    internal let trialID: String
    internal let taskID: OrganizerMetricTaskID
    internal let sourceNodeKeys: [String]
    internal let destinationGroupKeys: [String]
    internal let queryKey: String?
    internal let stratum: String
    internal let status: OrganizerMetricEvaluationStatus
    internal let durationMilliseconds: Int64?
    internal let eventSummary: [OrganizerMetricEventRecord]
    internal let coarseFailureReason: OrganizerMetricCoarseFailureReason?
    internal let targetOutcome: OrganizerMetricTargetOutcome
    internal let mailCallCount: Int
    internal let normalizedCommandCount: Int

    private enum CodingKeys: String, CodingKey {
        case trialID = "trialId"
        case taskID = "taskId"
        case sourceNodeKeys
        case destinationGroupKeys
        case queryKey
        case stratum
        case status
        case durationMilliseconds
        case eventSummary
        case coarseFailureReason
        case targetOutcome
        case mailCallCount
        case normalizedCommandCount
    }
}

internal nonisolated struct OrganizerMetricsReport: Codable, Hashable, Sendable {
    internal let schemaVersion: String
    internal let runID: String
    internal let fixtureID: String
    internal let protocolID: String
    internal let appBuild: String
    internal let evidenceType: OrganizerMetricEvidenceType
    internal let generatedAt: Date
    internal let status: OrganizerMetricEvaluationStatus
    internal let records: [OrganizerMetricTrialRecord]
    internal let eventSummary: [OrganizerMetricEventRecord]
    internal let timing: [OrganizerTimingSummary]
    internal let drops: [OrganizerDropSummary]
    internal let wrongPlacements: [OrganizerWrongPlacementSummary]
    internal let suggestions: [OrganizerSuggestionSummary]

    internal var overallStatus: OrganizerMetricEvaluationStatus { status }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID = "runId"
        case fixtureID = "fixtureId"
        case protocolID = "protocolId"
        case appBuild
        case evidenceType
        case generatedAt
        case status
        case records
        case eventSummary
        case timing
        case drops
        case wrongPlacements
        case suggestions
    }
}

private nonisolated struct OrganizerTimedSample: Hashable, Sendable {
    let sampleID: String
    let kind: OrganizerTimedMetricKind
    let stratum: OrganizerMetricStratum
    let durationMilliseconds: Int64?
    let outcome: OrganizerMetricOutcome
    let recordedAt: Date
}

private nonisolated struct OrganizerDropSample: Hashable, Sendable {
    let sampleID: String
    let source: OrganizerDropSource
    let stratum: OrganizerMetricStratum
    let attemptCount: Int
    let successCount: Int
    let invalidTargetMutationCount: Int
    let outcome: OrganizerMetricOutcome
    let recordedAt: Date
}

private nonisolated struct OrganizerWrongPlacementSample: Hashable, Sendable {
    let sampleID: String
    let setID: String
    let stratum: OrganizerMetricStratum
    let attemptCount: Int
    let wrongPlacementCount: Int
    let outcome: OrganizerMetricOutcome
    let recordedAt: Date
}

private nonisolated struct OrganizerSuggestionSample: Hashable, Sendable {
    let sampleID: String
    let strictness: OrganizerSuggestionStrictness
    let slice: OrganizerSuggestionSlice
    let candidateCount: Int
    let acceptedCount: Int
    let correctAcceptedCount: Int
    let nonAbstainedCount: Int
    let recordedAt: Date
}

private nonisolated struct OrganizerActiveTimedMetric: Hashable, Sendable {
    let startedAtMilliseconds: Int64
    let stratum: OrganizerMetricStratum
}

private nonisolated enum OrganizerDropProtocolPhase: Sendable {
    case idle
    case intended
    case highlighted
    case released
}

/// Local, aggregate-only acceptance evidence recorder.
///
/// Individual samples retain only synthetic IDs, timestamps, durations, and
/// coarse outcomes. The exported report contains aggregate samples plus a
/// fixed-vocabulary event summary and never exports sample IDs or Mail-derived
/// values. Runtime durations are calculated exclusively from this actor's
/// monotonic clock; the caller-supplied API remains only for frozen fixtures.
internal actor OrganizerMetricsRecorder {
    internal static let schemaVersion = "visual-email-organizer-metrics-v1"
    internal nonisolated static let frozenRetrievalQuery = "synthetic-query-organized-0004"
    /// Process-local identity paired with the frozen query. It must never be
    /// serialized into the sanitized metrics artifact.
    internal nonisolated static let frozenRetrievalRawThreadID = "conversation-100-0004"

    private let runID: String
    private let fixtureID: String
    private let protocolID: String
    private let appBuild: String
    private let evidenceType: OrganizerMetricEvidenceType
    private let generatedAt: Date
    private let defaultStratum: OrganizerMetricStratum?
    private let targetOutcome: OrganizerMetricTargetOutcome
    private let taskContract: OrganizerMetricTaskContract
    private let runtimeTaskContract: OrganizerMetricRuntimeTaskContract
    private let monotonicClock: OrganizerMetricsMonotonicClock
    private let sessionStartedAtMilliseconds: Int64
    private let outputURL: URL?
    private var usedSampleIDs: Set<String> = []
    private var usedSetIDs: Set<String> = []
    private var nextRuntimeSampleIndex = 1
    private var nextEventSequence = 1
    private var eventSummary: [OrganizerMetricEventRecord] = []
    private var activeTimedMetrics: [OrganizerTimedMetricKind: OrganizerActiveTimedMetric] = [:]
    private var latestRetrievalGeneration = 0
    private var activeRetrievalGeneration: Int?
    private var protocolEventCounts: [OrganizerMetricEventKind: Int] = [:]
    private var dropProtocolPhase: OrganizerDropProtocolPhase = .idle
    private var sessionStatus: OrganizerMetricEvaluationStatus = .pending
    private var coarseFailureReason: OrganizerMetricCoarseFailureReason?
    private var mailCallCount = 0
    private var normalizedCommandCount = 0
    private var timedSamples: [OrganizerTimedSample] = []
    private var dropSamples: [OrganizerDropSample] = []
    private var wrongPlacementSamples: [OrganizerWrongPlacementSample] = []
    private var suggestionSamples: [OrganizerSuggestionSample] = []
    private var pendingRenderedGroupVisibleCount = 0
    private var pendingUnsettledRenderedGroupVisibleCount = 0
    private var exactRenderedMembershipCount = 0
    private var didRecordPlacementSet = false
    private var didFailRuntimeTaskOutcome = false

    internal init(runID: String,
                  fixtureID: String,
                  protocolID: String,
                  appBuild: String = "build-unknown",
                  evidenceType: OrganizerMetricEvidenceType = .automatedLogic,
                  generatedAt: Date = Date(),
                  defaultStratum: OrganizerMetricStratum? = nil,
                  targetOutcome: OrganizerMetricTargetOutcome = .organization,
                  taskContract: OrganizerMetricTaskContract = .diagnostic,
                  runtimeTaskContract: OrganizerMetricRuntimeTaskContract = .diagnostic,
                  monotonicClock: OrganizerMetricsMonotonicClock = .continuous(),
                  outputURL: URL? = nil) throws {
        guard OrganizerMetricsPrivacy.validateRunID(runID),
              OrganizerMetricsPrivacy.validateFixtureID(fixtureID),
              OrganizerMetricsPrivacy.validateProtocolID(protocolID),
              OrganizerMetricsPrivacy.validateAppBuild(appBuild) else {
            throw OrganizerMetricsRecorderError.invalidSyntheticIdentifier
        }
        self.runID = runID
        self.fixtureID = fixtureID
        self.protocolID = protocolID
        self.appBuild = appBuild
        self.evidenceType = evidenceType
        self.generatedAt = generatedAt
        self.defaultStratum = defaultStratum
        self.targetOutcome = targetOutcome
        self.taskContract = taskContract
        self.runtimeTaskContract = runtimeTaskContract
        self.monotonicClock = monotonicClock
        self.outputURL = outputURL
        self.sessionStartedAtMilliseconds = monotonicClock.nowMilliseconds()
    }

    /// Records one instantaneous coarse event. A non-positive count or a clock
    /// reading before the session origin is rejected without mutating state.
    @discardableResult
    internal func recordEvent(_ event: OrganizerMetricEventKind,
                              stratum: OrganizerMetricStratum? = nil,
                              count: Int = 1,
                              status: OrganizerMetricOutcome? = nil,
                              failureReason: OrganizerMetricCoarseFailureReason? = nil,
                              externalMailCallCount: Int = 0) -> Bool {
        guard count > 0,
              externalMailCallCount >= 0,
              let offset = currentSessionOffsetMilliseconds(),
              canRecordProtocolEvent(event) else {
            return false
        }
        appendEvent(event,
                    phase: .instant,
                    stratum: stratum ?? defaultStratum,
                    count: count,
                    status: status,
                    offsetMilliseconds: offset,
                    durationMilliseconds: nil)
        noteProtocolEvent(event)
        updateSessionState(event: event,
                           status: status,
                           failureReason: failureReason,
                           externalMailCallCount: externalMailCallCount)
        if event == .failure || event == .cancelled {
            pendingRenderedGroupVisibleCount = 0
            pendingUnsettledRenderedGroupVisibleCount = 0
        }
        let didPersist = persistIfConfigured()
        guard event == .rethreadComplete else { return didPersist }
        return flushPendingRenderedGroupVisibleIfEligible() && didPersist
    }

    /// Starts one or more recorder-owned monotonic intervals at the exact same
    /// protocol boundary. This is used at `task-ready`, where the first-action
    /// and five-conversation timers share a single visible start event.
    @discardableResult
    internal func beginTimedEvents(kinds: Set<OrganizerTimedMetricKind>,
                                   stratum: OrganizerMetricStratum,
                                   event: OrganizerMetricEventKind,
                                   count: Int = 1) -> Bool {
        guard !kinds.isEmpty,
              count > 0,
              kinds.allSatisfy({ activeTimedMetrics[$0] == nil }),
              kinds.allSatisfy({ Self.isValidStart(event: event, for: $0) }),
              canRecordProtocolEvent(event) else {
            return false
        }
        let now = monotonicClock.nowMilliseconds()
        guard now >= sessionStartedAtMilliseconds else { return false }
        for kind in kinds {
            activeTimedMetrics[kind] = OrganizerActiveTimedMetric(startedAtMilliseconds: now,
                                                                  stratum: stratum)
        }
        appendEvent(event,
                    phase: .started,
                    stratum: stratum,
                    count: count,
                    status: nil,
                    offsetMilliseconds: now - sessionStartedAtMilliseconds,
                    durationMilliseconds: nil)
        noteProtocolEvent(event)
        return persistIfConfigured()
    }

    @discardableResult
    internal func beginTimedEvent(kind: OrganizerTimedMetricKind,
                                  stratum: OrganizerMetricStratum,
                                  event: OrganizerMetricEventKind,
                                  count: Int = 1) -> Bool {
        beginTimedEvents(kinds: [kind],
                         stratum: stratum,
                         event: event,
                         count: count)
    }

    @discardableResult
    internal func beginDefaultRetrievalTimedEvent(generation: Int) -> Bool {
        guard generation > latestRetrievalGeneration,
              runtimeTaskContract.allowsRetrievalTiming,
              let defaultStratum else { return false }
        latestRetrievalGeneration = generation
        let didStart = beginTimedEvent(kind: .retrieval,
                                       stratum: defaultStratum,
                                       event: .searchStart)
        if didStart {
            activeRetrievalGeneration = generation
        }
        return didStart
    }

    /// A cleared or abandoned frozen query is a failed trial under the frozen
    /// protocol. End every active interval belonging to the same task so a
    /// later query cannot accidentally reuse the original start instant.
    @discardableResult
    internal func cancelDefaultRetrievalTimedEvent(generation: Int) -> Bool {
        guard generation > latestRetrievalGeneration,
              runtimeTaskContract.allowsRetrievalTiming else { return false }
        latestRetrievalGeneration = generation
        if activeTimedMetrics[.retrieval] == nil {
            guard let defaultStratum,
                  beginTimedEvent(kind: .retrieval,
                                  stratum: defaultStratum,
                                  event: .searchStart) else {
                activeRetrievalGeneration = nil
                return false
            }
            activeRetrievalGeneration = generation
        }
        let kinds = Set([OrganizerTimedMetricKind.retrieval, .fiveConversation])
            .intersection(Set(activeTimedMetrics.keys))
        let didFinish = finishTimedEvents(kinds: kinds,
                                          event: .cancelled,
                                          outcome: .cancelled,
                                          failureReason: .cancelled)
        if didFinish {
            activeRetrievalGeneration = nil
        }
        return didFinish
    }

    /// Finishes one or more active intervals at one visible protocol boundary.
    /// Failed and cancelled trials retain an over-threshold duration, as the
    /// frozen contract requires, instead of disappearing from percentile math.
    @discardableResult
    internal func finishTimedEvents(kinds: Set<OrganizerTimedMetricKind>,
                                    event: OrganizerMetricEventKind,
                                    outcome: OrganizerMetricOutcome,
                                    count: Int = 1,
                                    failureReason: OrganizerMetricCoarseFailureReason? = nil) -> Bool {
        guard !kinds.isEmpty,
              count > 0,
              kinds.allSatisfy({ activeTimedMetrics[$0] != nil }),
              kinds.allSatisfy({ Self.isValidFinish(event: event, for: $0) }),
              canRecordProtocolEvent(event) else {
            return false
        }
        let now = monotonicClock.nowMilliseconds()
        guard now >= sessionStartedAtMilliseconds,
              kinds.allSatisfy({ kind in
                  guard let active = activeTimedMetrics[kind] else { return false }
                  return now >= active.startedAtMilliseconds
              }) else {
            return false
        }
        let offset = now - sessionStartedAtMilliseconds
        let durations = kinds.compactMap { kind -> Int64? in
            guard let active = activeTimedMetrics[kind] else { return nil }
            return runtimeDuration(kind: kind,
                                   elapsed: now - active.startedAtMilliseconds,
                                   outcome: outcome)
        }
        appendEvent(event,
                    phase: .finished,
                    stratum: kinds.compactMap { activeTimedMetrics[$0]?.stratum }.first,
                    count: count,
                    status: outcome,
                    offsetMilliseconds: offset,
                    durationMilliseconds: durations.max())
        noteProtocolEvent(event)
        updateSessionState(event: event,
                           status: outcome,
                           failureReason: failureReason,
                           externalMailCallCount: 0)
        if outcome == .failure || outcome == .cancelled {
            pendingRenderedGroupVisibleCount = 0
            pendingUnsettledRenderedGroupVisibleCount = 0
        }
        for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let active = activeTimedMetrics.removeValue(forKey: kind) else { continue }
            let elapsed = now - active.startedAtMilliseconds
            timedSamples.append(OrganizerTimedSample(
                sampleID: nextRuntimeSampleID(),
                kind: kind,
                stratum: active.stratum,
                durationMilliseconds: runtimeDuration(kind: kind,
                                                      elapsed: elapsed,
                                                      outcome: outcome),
                outcome: outcome,
                recordedAt: generatedAt
            ))
        }
        if kinds.contains(.retrieval) {
            activeRetrievalGeneration = nil
        }
        return persistIfConfigured()
    }

    @discardableResult
    internal func finishTimedEvent(kind: OrganizerTimedMetricKind,
                                   event: OrganizerMetricEventKind,
                                   outcome: OrganizerMetricOutcome,
                                   count: Int = 1,
                                   failureReason: OrganizerMetricCoarseFailureReason? = nil) -> Bool {
        finishTimedEvents(kinds: [kind],
                          event: event,
                          outcome: outcome,
                          count: count,
                          failureReason: failureReason)
    }

    @discardableResult
    internal func failActiveTimedEvents(outcome: OrganizerMetricOutcome,
                                        failureReason: OrganizerMetricCoarseFailureReason) -> Bool {
        guard outcome == .failure || outcome == .cancelled,
              !activeTimedMetrics.isEmpty else { return false }
        return finishTimedEvents(kinds: Set(activeTimedMetrics.keys),
                                 event: outcome == .cancelled ? .cancelled : .failure,
                                 outcome: outcome,
                                 failureReason: failureReason)
    }

    @discardableResult
    internal func recordRenderedGroupVisible(count: Int) -> Bool {
        guard count > 0 else {
            return false
        }
        let visibleResultCount = protocolEventCounts[.visibleResult, default: 0]
        guard hasActiveOrganizationAction else {
            // Reject startup and ordinary graph rendering. A positive delta is
            // retained only while an explicit organization action is active.
            return false
        }
        guard protocolEventCounts[.betterMailCommit, default: 0] == visibleResultCount + 1 else {
            // A new Group can render before the serialized BetterMail commit
            // callback reaches this actor. Keep that one-shot render evidence
            // until the canonical commit/rethread boundary instead of losing
            // it after the graph visibility tracker advances its baseline.
            pendingRenderedGroupVisibleCount += count
            return persistIfConfigured()
        }
        guard canRecordProtocolEvent(.visibleResult) else {
            pendingRenderedGroupVisibleCount += count
            return persistIfConfigured()
        }
        return recordRenderedGroupVisibleNow(count: count)
    }

    /// Applies the process-local exact task contract to a rendered graph. Raw
    /// synthetic conversation identities are inspected only in memory and are
    /// never copied into the exported event or trial records.
    @discardableResult
    internal func recordRenderedOrganizerSnapshot(
        _ snapshot: OrganizerRenderedGraphSnapshot,
        newlyVisibleCount: Int,
        isStillCurrent: @MainActor @Sendable () -> Bool = { true }
    ) async -> Bool {
        guard newlyVisibleCount >= 0 else { return false }
        guard await isStillCurrent() else { return true }
        switch taskContract.taskID {
        case .firstOrganization, .fiveConversationOrganization:
            guard runtimeTaskContract.isAccessibilityReady(for: snapshot) else {
                return true
            }
            return recordExactTimedOrganization(
                confirmedRawThreadIDsByGroupKey: snapshot.confirmedRawThreadIDsByGroupKey,
                newlyVisibleCount: newlyVisibleCount
            )
        case .placementSet:
            guard snapshot.isLayoutSettled else {
                guard newlyVisibleCount > 0 else { return true }
                guard hasActiveOrganizationAction else { return false }
                pendingUnsettledRenderedGroupVisibleCount += newlyVisibleCount
                return persistIfConfigured()
            }
            let eligibleVisibleCount = newlyVisibleCount
                + pendingUnsettledRenderedGroupVisibleCount
            pendingUnsettledRenderedGroupVisibleCount = 0
            let didRecordVisibility = eligibleVisibleCount == 0
                || recordRenderedGroupVisible(count: eligibleVisibleCount)
            if !didRecordVisibility, eligibleVisibleCount > 0, hasActiveOrganizationAction {
                pendingUnsettledRenderedGroupVisibleCount = eligibleVisibleCount
            }
            let didAdjudicate = recordPlacementSetIfComplete(
                confirmedRawThreadIDsByGroupKey: snapshot.confirmedRawThreadIDsByGroupKey
            )
            return didRecordVisibility && didAdjudicate
        case .diagnostic, .livePointer, .retrieval:
            guard newlyVisibleCount > 0 else { return true }
            return recordRenderedGroupVisible(count: newlyVisibleCount)
        }
    }

    private func recordExactTimedOrganization(
        confirmedRawThreadIDsByGroupKey: [String: Set<String>],
        newlyVisibleCount: Int
    ) -> Bool {
        guard !didFailRuntimeTaskOutcome else { return false }
        let expected = runtimeTaskContract.expectedMemberships
        guard !expected.isEmpty else {
            didFailRuntimeTaskOutcome = true
            return failActiveTimedEvents(outcome: .failure,
                                         failureReason: .unresolvedOutcome)
        }
        let correctCount = expected.filter { membership in
            confirmedRawThreadIDsByGroupKey[membership.destinationGroupKey]?
                .contains(membership.rawThreadID) == true
        }.count
        let misplacedCount = expected.filter { membership in
            confirmedRawThreadIDsByGroupKey.contains { groupKey, rawThreadIDs in
                groupKey != membership.destinationGroupKey
                    && rawThreadIDs.contains(membership.rawThreadID)
            }
        }.count

        if misplacedCount > 0 || (newlyVisibleCount > 0 && correctCount <= exactRenderedMembershipCount) {
            didFailRuntimeTaskOutcome = true
            return failActiveTimedEvents(outcome: .failure,
                                         failureReason: .wrongCompletion)
        }
        guard correctCount > exactRenderedMembershipCount else { return true }
        let newlyCorrectCount = correctCount - exactRenderedMembershipCount
        exactRenderedMembershipCount = correctCount
        return recordRenderedGroupVisible(count: newlyCorrectCount)
    }

    private func recordPlacementSetIfComplete(
        confirmedRawThreadIDsByGroupKey: [String: Set<String>]
    ) -> Bool {
        guard !didRecordPlacementSet,
              let setID = runtimeTaskContract.placementSetID,
              !runtimeTaskContract.expectedMemberships.isEmpty else {
            return true
        }
        let expected = runtimeTaskContract.expectedMemberships
        let containingGroupsByRawThreadID = confirmedRawThreadIDsByGroupKey.reduce(
            into: [String: Set<String>]()
        ) { result, entry in
            for rawThreadID in entry.value {
                result[rawThreadID, default: []].insert(entry.key)
            }
        }
        let adjudicated = expected.filter {
            containingGroupsByRawThreadID[$0.rawThreadID]?.isEmpty == false
        }
        guard adjudicated.count == expected.count else { return true }
        let wrongCount = expected.filter { membership in
            containingGroupsByRawThreadID[membership.rawThreadID] != [membership.destinationGroupKey]
        }.count
        do {
            try recordWrongPlacement(
                stratum: defaultStratum ?? .warm,
                sampleID: "placement-runtime-\(setID)",
                setID: setID,
                attemptCount: expected.count,
                wrongPlacementCount: wrongCount,
                outcome: wrongCount <= OrganizerMetricsThresholds.baseline
                    .wrongPlacementMaximumPerSet ? .success : .failure
            )
            didRecordPlacementSet = true
            return true
        } catch {
            return false
        }
    }

    private func recordRenderedGroupVisibleNow(count: Int) -> Bool {
        guard recordEvent(.groupVisible,
                          count: count,
                          status: .success) else { return false }
        if activeTimedMetrics[.firstAction] != nil {
            return finishTimedEvent(kind: .firstAction,
                                    event: .visibleResult,
                                    outcome: .success,
                                    count: count)
        }
        return recordEvent(.visibleResult,
                           count: count,
                           status: .success)
    }

    private var hasActiveOrganizationAction: Bool {
        protocolEventCounts[.actionStart, default: 0]
            == protocolEventCounts[.visibleResult, default: 0] + 1
    }

    private func flushPendingRenderedGroupVisibleIfEligible() -> Bool {
        guard pendingRenderedGroupVisibleCount > 0,
              canRecordProtocolEvent(.visibleResult) else {
            return true
        }
        let count = pendingRenderedGroupVisibleCount
        pendingRenderedGroupVisibleCount = 0
        guard recordRenderedGroupVisibleNow(count: count) else {
            pendingRenderedGroupVisibleCount = count
            return false
        }
        return true
    }

    @discardableResult
    internal func recordRenderedRetrievalVisible(count: Int,
                                                 generation: Int,
                                                 isStillCurrent: @MainActor @Sendable () -> Bool = { true }) async -> Bool {
        guard generation == latestRetrievalGeneration,
              activeRetrievalGeneration == generation,
              runtimeTaskContract.allowsRetrievalTiming,
              activeTimedMetrics[.retrieval] != nil,
              count > 0,
              canRecordProtocolEvent(.retrievalVisible) else { return false }
        guard await isStillCurrent(),
              generation == latestRetrievalGeneration,
              activeRetrievalGeneration == generation,
              activeTimedMetrics[.retrieval] != nil else {
            return false
        }
        let finishKinds = Set([OrganizerTimedMetricKind.fiveConversation, .retrieval])
            .intersection(Set(activeTimedMetrics.keys))
        if !finishKinds.isEmpty {
            return finishTimedEvents(kinds: finishKinds,
                                     event: .retrievalVisible,
                                     outcome: .success,
                                     count: count)
        }
        return recordEvent(.retrievalVisible,
                           count: count,
                           status: .success)
    }

    internal func recordTimed(kind: OrganizerTimedMetricKind,
                              stratum: OrganizerMetricStratum,
                              sampleID: String,
                              durationMilliseconds: Int64?,
                              outcome: OrganizerMetricOutcome,
                              recordedAt: Date? = nil) throws {
        if let durationMilliseconds, durationMilliseconds < 0 {
            throw OrganizerMetricsRecorderError.invalidDuration
        }
        if outcome == .success && durationMilliseconds == nil {
            throw OrganizerMetricsRecorderError.invalidDuration
        }
        try reserve(sampleID)
        let recordedDuration: Int64?
        switch outcome {
        case .success:
            recordedDuration = durationMilliseconds
        case .failure, .cancelled:
            recordedDuration = max(durationMilliseconds ?? 0,
                                   timingThreshold(kind: kind, thresholds: .baseline) + 1)
        case .invalid:
            recordedDuration = nil
        }
        timedSamples.append(OrganizerTimedSample(sampleID: sampleID,
                                                 kind: kind,
                                                 stratum: stratum,
                                                 durationMilliseconds: recordedDuration,
                                                 outcome: outcome,
                                                 recordedAt: recordedAt ?? generatedAt))
        guard persistIfConfigured() else {
            throw OrganizerMetricsRecorderError.exportFailed
        }
    }

    internal func recordDrop(source: OrganizerDropSource,
                             stratum: OrganizerMetricStratum,
                             sampleID: String,
                             attemptCount: Int,
                             successCount: Int,
                             invalidTargetMutationCount: Int = 0,
                             outcome: OrganizerMetricOutcome,
                             recordedAt: Date? = nil) throws {
        guard attemptCount > 0,
              successCount >= 0,
              successCount <= attemptCount,
              invalidTargetMutationCount >= 0,
              invalidTargetMutationCount <= attemptCount else {
            throw OrganizerMetricsRecorderError.invalidCount
        }
        try reserve(sampleID)
        dropSamples.append(OrganizerDropSample(sampleID: sampleID,
                                               source: source,
                                               stratum: stratum,
                                               attemptCount: attemptCount,
                                               successCount: successCount,
                                               invalidTargetMutationCount: invalidTargetMutationCount,
                                               outcome: outcome,
                                               recordedAt: recordedAt ?? generatedAt))
        guard persistIfConfigured() else {
            throw OrganizerMetricsRecorderError.exportFailed
        }
    }

    internal func recordRuntimeDrop(source: OrganizerDropSource,
                                    stratum: OrganizerMetricStratum? = nil,
                                    attemptCount: Int = 1,
                                    successCount: Int,
                                    invalidTargetMutationCount: Int = 0,
                                    outcome: OrganizerMetricOutcome) throws {
        guard attemptCount > 0,
              successCount >= 0,
              successCount <= attemptCount,
              invalidTargetMutationCount >= 0,
              invalidTargetMutationCount <= attemptCount else {
            throw OrganizerMetricsRecorderError.invalidCount
        }
        dropSamples.append(OrganizerDropSample(sampleID: nextRuntimeSampleID(),
                                               source: source,
                                               stratum: stratum ?? defaultStratum ?? .warm,
                                               attemptCount: attemptCount,
                                               successCount: successCount,
                                               invalidTargetMutationCount: invalidTargetMutationCount,
                                               outcome: outcome,
                                               recordedAt: generatedAt))
        guard persistIfConfigured() else {
            throw OrganizerMetricsRecorderError.exportFailed
        }
    }

    internal func recordWrongPlacement(stratum: OrganizerMetricStratum,
                                       sampleID: String,
                                       setID: String,
                                       attemptCount: Int,
                                       wrongPlacementCount: Int,
                                       outcome: OrganizerMetricOutcome,
                                       recordedAt: Date? = nil) throws {
        guard OrganizerMetricsPrivacy.validateSetID(setID),
              attemptCount > 0,
              wrongPlacementCount >= 0,
              wrongPlacementCount <= attemptCount else {
            throw OrganizerMetricsRecorderError.invalidCount
        }
        guard !usedSetIDs.contains(setID) else {
            throw OrganizerMetricsRecorderError.duplicateSetIdentifier
        }
        try reserve(sampleID)
        usedSetIDs.insert(setID)
        wrongPlacementSamples.append(OrganizerWrongPlacementSample(sampleID: sampleID,
                                                                    setID: setID,
                                                                    stratum: stratum,
                                                                    attemptCount: attemptCount,
                                                                    wrongPlacementCount: wrongPlacementCount,
                                                                    outcome: outcome,
                                                                    recordedAt: recordedAt ?? generatedAt))
        guard persistIfConfigured() else {
            throw OrganizerMetricsRecorderError.exportFailed
        }
    }

    internal func recordSuggestion(strictness: OrganizerSuggestionStrictness,
                                   slice: OrganizerSuggestionSlice,
                                   sampleID: String,
                                   candidateCount: Int,
                                   acceptedCount: Int,
                                   correctAcceptedCount: Int,
                                   nonAbstainedCount: Int,
                                   recordedAt: Date? = nil) throws {
        guard candidateCount > 0,
              acceptedCount >= 0,
              acceptedCount <= candidateCount,
              correctAcceptedCount >= 0,
              correctAcceptedCount <= acceptedCount,
              nonAbstainedCount >= 0,
              nonAbstainedCount <= candidateCount,
              acceptedCount <= nonAbstainedCount else {
            throw OrganizerMetricsRecorderError.invalidSuggestionCounts
        }
        try reserve(sampleID)
        suggestionSamples.append(OrganizerSuggestionSample(sampleID: sampleID,
                                                            strictness: strictness,
                                                            slice: slice,
                                                            candidateCount: candidateCount,
                                                            acceptedCount: acceptedCount,
                                                            correctAcceptedCount: correctAcceptedCount,
                                                            nonAbstainedCount: nonAbstainedCount,
                                                            recordedAt: recordedAt ?? generatedAt))
        guard persistIfConfigured() else {
            throw OrganizerMetricsRecorderError.exportFailed
        }
    }

    internal func report(thresholds: OrganizerMetricsThresholds = .baseline) -> OrganizerMetricsReport {
        let timing = OrganizerTimedMetricKind.allCases.flatMap { kind in
            [OrganizerMetricStratum.warm, .coldRelaunch].map { stratum in
                timingSummary(kind: kind, stratum: stratum, thresholds: thresholds)
            }
        }
        let drops = OrganizerDropSource.allCases.flatMap { source in
            let sourceSamples = dropSamples.filter { $0.source == source }
            let strata = Set(sourceSamples.map(\.stratum)).sorted { $0.rawValue < $1.rawValue }
            let summaries = strata.map { stratum in
                dropSummary(source: source,
                            stratum: stratum,
                            samples: sourceSamples.filter { $0.stratum == stratum },
                            thresholds: thresholds)
            }
            guard !sourceSamples.isEmpty else { return summaries }
            return summaries + [dropSummary(source: source,
                                             stratum: .aggregate,
                                             samples: sourceSamples,
                                             thresholds: thresholds)]
        }
        let wrongPlacements = OrganizerMetricStratum.allCases
            .filter { $0 != .aggregate }
            .compactMap { stratum -> OrganizerWrongPlacementSummary? in
                let samples = wrongPlacementSamples.filter { $0.stratum == stratum }
                guard !samples.isEmpty else { return nil }
                return wrongPlacementSummary(stratum: stratum, samples: samples, thresholds: thresholds)
            }
        let suggestions = OrganizerSuggestionStrictness.allCases.compactMap { strictness -> OrganizerSuggestionSummary? in
            let samples = suggestionSamples.filter { $0.strictness == strictness }
            guard !samples.isEmpty else { return nil }
            return suggestionSummary(strictness: strictness, samples: samples, thresholds: thresholds)
        }
        let statuses = timing.map(\.status) + drops.map(\.status) + wrongPlacements.map(\.status) + suggestions.map(\.status)
        let aggregateStatus = Self.overallStatus(statuses)
        let overallStatus: OrganizerMetricEvaluationStatus
        switch sessionStatus {
        case .fail, .invalid:
            overallStatus = sessionStatus
        case .pass, .pending, .insufficientEvidence:
            overallStatus = aggregateStatus
        }
        let primaryTimedKind: OrganizerTimedMetricKind?
        switch taskContract.taskID {
        case .firstOrganization:
            primaryTimedKind = .firstAction
        case .fiveConversationOrganization:
            primaryTimedKind = .fiveConversation
        case .retrieval:
            primaryTimedKind = .retrieval
        case .diagnostic, .livePointer, .placementSet:
            primaryTimedKind = nil
        }
        let latestDuration = primaryTimedKind.flatMap { kind in
            timedSamples.last(where: {
                $0.kind == kind && $0.outcome != .invalid
            })?.durationMilliseconds
        }
        let trial = OrganizerMetricTrialRecord(
            trialID: runID,
            taskID: taskContract.taskID,
            sourceNodeKeys: taskContract.sourceNodeKeys,
            destinationGroupKeys: taskContract.destinationGroupKeys,
            queryKey: taskContract.queryKey,
            stratum: (defaultStratum ?? .aggregate).rawValue,
            status: overallStatus,
            durationMilliseconds: latestDuration,
            eventSummary: eventSummary,
            coarseFailureReason: coarseFailureReason,
            targetOutcome: targetOutcome,
            mailCallCount: mailCallCount,
            normalizedCommandCount: normalizedCommandCount
        )
        return OrganizerMetricsReport(schemaVersion: Self.schemaVersion,
                                      runID: runID,
                                      fixtureID: fixtureID,
                                      protocolID: protocolID,
                                      appBuild: appBuild,
                                      evidenceType: evidenceType,
                                      generatedAt: generatedAt,
                                      status: overallStatus,
                                      records: [trial],
                                      eventSummary: eventSummary,
                                      timing: timing,
                                      drops: drops,
                                      wrongPlacements: wrongPlacements,
                                      suggestions: suggestions)
    }

    internal func exportJSON(thresholds: OrganizerMetricsThresholds = .baseline) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report(thresholds: thresholds))
    }

    private func reserve(_ sampleID: String) throws {
        guard OrganizerMetricsPrivacy.validateSampleID(sampleID) else {
            throw OrganizerMetricsRecorderError.invalidSyntheticIdentifier
        }
        guard usedSampleIDs.insert(sampleID).inserted else {
            throw OrganizerMetricsRecorderError.duplicateSampleIdentifier
        }
    }

    private func canRecordProtocolEvent(_ event: OrganizerMetricEventKind) -> Bool {
        let count: (OrganizerMetricEventKind) -> Int = { self.protocolEventCounts[$0, default: 0] }
        switch event {
        case .taskReady:
            return count(.taskReady) == 0
                && eventSummary.contains(where: { $0.event == .workspaceReady })
                && eventSummary.contains(where: { $0.event == .taskVisible })
        case .actionStart:
            return count(.taskReady) == 1
                && count(.actionStart) == count(.visibleResult)
        case .dropIntent:
            return dropProtocolPhase == .idle
                && count(.actionStart) == count(.dropIntent) + 1
        case .dropHighlight:
            return dropProtocolPhase == .intended
        case .dropRelease:
            return dropProtocolPhase == .intended
                || dropProtocolPhase == .highlighted
        case .dropOutcome:
            return dropProtocolPhase == .released
        case .betterMailCommit:
            return count(.actionStart) == count(.betterMailCommit) + 1
        case .rethreadComplete:
            return count(.betterMailCommit) == count(.rethreadComplete) + 1
        case .visibleResult:
            return count(.rethreadComplete) == count(.visibleResult) + 1
        case .searchStart:
            return count(.taskReady) == 1 && count(.searchStart) == 0
        case .retrievalVisible:
            return count(.searchStart) == 1 && count(.retrievalVisible) == 0
        case .cancelled, .failure:
            return count(.taskReady) == 1 && count(event) == 0
        case .workspaceReady, .taskVisible:
            return !eventSummary.contains(where: { $0.event == event })
        case .selection, .groupCommitted, .groupRethreaded, .groupVisible, .suggestionDecision,
             .mailAuthorization, .mailResult, .undo, .recovery:
            return true
        }
    }

    private func noteProtocolEvent(_ event: OrganizerMetricEventKind) {
        switch event {
        case .taskReady, .searchStart, .actionStart, .dropIntent,
             .dropHighlight, .dropRelease, .dropOutcome, .betterMailCommit,
             .rethreadComplete, .visibleResult, .retrievalVisible,
             .cancelled, .failure:
            protocolEventCounts[event, default: 0] += 1
            switch event {
            case .dropIntent:
                dropProtocolPhase = .intended
            case .dropHighlight:
                dropProtocolPhase = .highlighted
            case .dropRelease:
                dropProtocolPhase = .released
            case .dropOutcome:
                dropProtocolPhase = .idle
            default:
                break
            }
        case .workspaceReady, .taskVisible, .selection, .groupCommitted,
             .groupRethreaded, .groupVisible, .suggestionDecision,
             .mailAuthorization, .mailResult, .undo, .recovery:
            break
        }
    }

    private func updateSessionState(event: OrganizerMetricEventKind,
                                    status: OrganizerMetricOutcome?,
                                    failureReason: OrganizerMetricCoarseFailureReason?,
                                    externalMailCallCount: Int) {
        mailCallCount += externalMailCallCount
        if event == .groupCommitted, status == .success {
            normalizedCommandCount += 1
        }
        switch status {
        case .invalid:
            sessionStatus = .invalid
            coarseFailureReason = failureReason ?? .instrumentationBeforeTaskReady
        case .failure:
            sessionStatus = .fail
            coarseFailureReason = failureReason ?? coarseFailureReason ?? .actionFailure
        case .cancelled:
            sessionStatus = .fail
            coarseFailureReason = failureReason ?? coarseFailureReason ?? .cancelled
        case .success:
            if sessionStatus == .pending {
                sessionStatus = .pass
            }
        case nil:
            break
        }
    }

    private func runtimeDuration(kind: OrganizerTimedMetricKind,
                                 elapsed: Int64,
                                 outcome: OrganizerMetricOutcome) -> Int64? {
        switch outcome {
        case .success:
            return elapsed
        case .failure, .cancelled:
            return max(elapsed,
                       timingThreshold(kind: kind, thresholds: .baseline) + 1)
        case .invalid:
            return nil
        }
    }

    private static func isValidStart(event: OrganizerMetricEventKind,
                                     for kind: OrganizerTimedMetricKind) -> Bool {
        switch kind {
        case .firstAction, .fiveConversation:
            return event == .taskReady
        case .retrieval:
            return event == .searchStart
        }
    }

    private static func isValidFinish(event: OrganizerMetricEventKind,
                                      for kind: OrganizerTimedMetricKind) -> Bool {
        if event == .failure || event == .cancelled {
            return true
        }
        switch kind {
        case .firstAction:
            return event == .visibleResult
        case .fiveConversation, .retrieval:
            return event == .retrievalVisible
        }
    }

    private func persistIfConfigured() -> Bool {
        guard let outputURL else { return true }
        do {
            let parent = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent,
                                                    withIntermediateDirectories: true)
            try exportJSON().write(to: outputURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func currentSessionOffsetMilliseconds() -> Int64? {
        let now = monotonicClock.nowMilliseconds()
        guard now >= sessionStartedAtMilliseconds else { return nil }
        return now - sessionStartedAtMilliseconds
    }

    private func appendEvent(_ event: OrganizerMetricEventKind,
                             phase: OrganizerMetricEventPhase,
                             stratum: OrganizerMetricStratum?,
                             count: Int,
                             status: OrganizerMetricOutcome?,
                             offsetMilliseconds: Int64,
                             durationMilliseconds: Int64?) {
        eventSummary.append(OrganizerMetricEventRecord(sequence: nextEventSequence,
                                                       event: event,
                                                       phase: phase,
                                                       stratum: stratum,
                                                       count: count,
                                                       status: status,
                                                       offsetMilliseconds: offsetMilliseconds,
                                                       durationMilliseconds: durationMilliseconds))
        nextEventSequence += 1
    }

    private func nextRuntimeSampleID() -> String {
        while true {
            let candidate = "synthetic-runtime-\(nextRuntimeSampleIndex)"
            nextRuntimeSampleIndex += 1
            if usedSampleIDs.insert(candidate).inserted {
                return candidate
            }
        }
    }

    private func timingSummary(kind: OrganizerTimedMetricKind,
                               stratum: OrganizerMetricStratum,
                               thresholds: OrganizerMetricsThresholds) -> OrganizerTimingSummary {
        let samples = timedSamples.filter { $0.kind == kind && $0.stratum == stratum }
        let successCount = samples.filter { $0.outcome == .success }.count
        let failureCount = samples.filter { $0.outcome == .failure }.count
        let invalidCount = samples.filter { $0.outcome == .invalid }.count
        let cancelledCount = samples.filter { $0.outcome == .cancelled }.count
        let validSamples = samples.filter { $0.outcome != .invalid }
        let durations = validSamples.compactMap(\.durationMilliseconds).sorted()
        let threshold = timingThreshold(kind: kind, thresholds: thresholds)
        let minimumSamples = timingMinimumSamples(kind: kind, thresholds: thresholds)
        let median = Self.nearestRankPercentile(durations, percentile: 0.50)
        let p80 = Self.nearestRankPercentile(durations, percentile: 0.80)
        let p90 = Self.nearestRankPercentile(durations, percentile: 0.90)
        let withinThresholdCount = durations.filter { $0 <= threshold }.count
        let withinThresholdRate = validSamples.isEmpty
            ? nil
            : Double(withinThresholdCount) / Double(validSamples.count)
        let minimumWithinThresholdRate: Double? = kind == .retrieval ? 0.95 : nil
        let status: OrganizerMetricEvaluationStatus
        if samples.isEmpty {
            status = .pending
        } else if validSamples.count < minimumSamples {
            status = .insufficientEvidence
        } else if kind == .retrieval {
            status = (withinThresholdRate ?? 0) >= 0.95 ? .pass : .fail
        } else if let p80 {
            status = p80 <= threshold ? .pass : .fail
        } else {
            status = .fail
        }
        return OrganizerTimingSummary(kind: kind,
                                      stratum: stratum,
                                      sampleCount: samples.count,
                                      validTrialCount: validSamples.count,
                                      successCount: successCount,
                                      failureCount: failureCount,
                                      invalidCount: invalidCount,
                                      cancelledCount: cancelledCount,
                                      medianMilliseconds: median,
                                      p80Milliseconds: p80,
                                      p90Milliseconds: p90,
                                      thresholdMilliseconds: threshold,
                                      withinThresholdCount: withinThresholdCount,
                                      withinThresholdRate: withinThresholdRate,
                                      minimumWithinThresholdRate: minimumWithinThresholdRate,
                                      status: status)
    }

    private func dropSummary(source: OrganizerDropSource,
                              stratum: OrganizerMetricStratum,
                              samples: [OrganizerDropSample],
                              thresholds: OrganizerMetricsThresholds) -> OrganizerDropSummary {
        let attempts = samples.reduce(0) { $0 + $1.attemptCount }
        let successes = samples.reduce(0) { $0 + $1.successCount }
        let invalidMutations = samples.reduce(0) { $0 + $1.invalidTargetMutationCount }
        let rate = attempts > 0 ? Double(successes) / Double(attempts) : nil
        let minimumRate: Double
        let minimumAttempts: Int
        switch source {
        case .deterministicMatrix:
            minimumRate = stratum == .aggregate
                ? thresholds.deterministicDropMinimumSuccessRate
                : thresholds.deterministicDropPerStratumMinimumSuccessRate
            minimumAttempts = stratum == .aggregate
                ? thresholds.deterministicDropMinimumAttemptsPerStratum * 12
                : thresholds.deterministicDropMinimumAttemptsPerStratum
        case .livePointer:
            minimumRate = thresholds.livePointerDropMinimumSuccessRate
            minimumAttempts = 40
        }
        let status: OrganizerMetricEvaluationStatus
        if samples.isEmpty {
            status = .pending
        } else if attempts < minimumAttempts {
            status = .insufficientEvidence
        } else if invalidMutations > 0 {
            status = .fail
        } else if let rate, rate >= minimumRate {
            status = .pass
        } else {
            status = .fail
        }
        return OrganizerDropSummary(source: source,
                                    stratum: stratum,
                                    attemptCount: attempts,
                                    successCount: successes,
                                    invalidTargetMutationCount: invalidMutations,
                                    successRate: rate,
                                    minimumSuccessRate: minimumRate,
                                    status: status)
    }

    private func wrongPlacementSummary(stratum: OrganizerMetricStratum,
                                       samples: [OrganizerWrongPlacementSample],
                                       thresholds: OrganizerMetricsThresholds) -> OrganizerWrongPlacementSummary {
        let sets = samples.map {
            OrganizerWrongPlacementSetSummary(setID: $0.setID,
                                              attemptCount: $0.attemptCount,
                                              wrongPlacementCount: $0.wrongPlacementCount)
        }.sorted { $0.setID < $1.setID }
        let totalAttempts = sets.reduce(0) { $0 + $1.attemptCount }
        let totalWrong = sets.reduce(0) { $0 + $1.wrongPlacementCount }
        let maximumWrong = sets.map(\.wrongPlacementCount).max() ?? 0
        let hasFailure = samples.contains { $0.outcome != .success }
        let status: OrganizerMetricEvaluationStatus
        if sets.count < thresholds.wrongPlacementMinimumSets {
            status = .insufficientEvidence
        } else if hasFailure || maximumWrong > thresholds.wrongPlacementMaximumPerSet {
            status = .fail
        } else {
            status = .pass
        }
        return OrganizerWrongPlacementSummary(stratum: stratum,
                                               setCount: sets.count,
                                               totalAttemptCount: totalAttempts,
                                               totalWrongPlacementCount: totalWrong,
                                               maximumWrongPlacementCountPerSet: maximumWrong,
                                               minimumSetCount: thresholds.wrongPlacementMinimumSets,
                                               maximumWrongPlacementCountPerSetThreshold: thresholds.wrongPlacementMaximumPerSet,
                                               sets: sets,
                                               status: status)
    }

    private func suggestionSummary(strictness: OrganizerSuggestionStrictness,
                                   samples: [OrganizerSuggestionSample],
                                   thresholds: OrganizerMetricsThresholds) -> OrganizerSuggestionSummary {
        let candidateCount = samples.reduce(0) { $0 + $1.candidateCount }
        let acceptedCount = samples.reduce(0) { $0 + $1.acceptedCount }
        let correctAcceptedCount = samples.reduce(0) { $0 + $1.correctAcceptedCount }
        let nonAbstainedCount = samples.reduce(0) { $0 + $1.nonAbstainedCount }
        let precision = acceptedCount > 0 ? Double(correctAcceptedCount) / Double(acceptedCount) : nil
        let coverage = candidateCount > 0 ? Double(nonAbstainedCount) / Double(candidateCount) : nil
        let slices = OrganizerSuggestionSlice.allCases.map { slice in
            let sliceSamples = samples.filter { $0.slice == slice }
            let acceptedCount = sliceSamples.reduce(0) { $0 + $1.acceptedCount }
            let nonAbstainedCount = sliceSamples.reduce(0) { $0 + $1.nonAbstainedCount }
            let denominator: OrganizerSuggestionSliceDenominator = slice == .unrelated
                ? .nonAbstainedDecisions
                : .acceptedPlacements
            let qualifyingDecisionCount = denominator == .acceptedPlacements
                ? acceptedCount
                : nonAbstainedCount
            return OrganizerSuggestionSliceSummary(slice: slice,
                                                   candidateCount: sliceSamples.reduce(0) { $0 + $1.candidateCount },
                                                   acceptedCount: acceptedCount,
                                                   correctAcceptedCount: sliceSamples.reduce(0) { $0 + $1.correctAcceptedCount },
                                                   nonAbstainedCount: nonAbstainedCount,
                                                   denominator: denominator,
                                                   qualifyingDecisionCount: qualifyingDecisionCount,
                                                   minimumQualifyingDecisionCount: thresholds.suggestionMinimumDecisionCountPerSlice)
        }
        let minimumPrecision = strictness == .conservative
            ? thresholds.suggestionConservativeMinimumPrecision
            : thresholds.suggestionMinimumPrecision
        let hasAllSlices = slices.allSatisfy {
            $0.qualifyingDecisionCount >= $0.minimumQualifyingDecisionCount
        }
        let status: OrganizerMetricEvaluationStatus
        if candidateCount == 0 {
            status = .pending
        } else if candidateCount < thresholds.suggestionMinimumCandidates
                    || acceptedCount < thresholds.suggestionMinimumAccepted
                    || !hasAllSlices {
            status = .insufficientEvidence
        } else {
            // Aggregate counts cannot establish suggestion precision: they do
            // not bind predictions to gold records, version pins, effective
            // sources, or duplicate/conflict adjudication. Only
            // OrganizerSuggestionEvaluator can emit acceptance-eligible
            // suggestion evidence.
            status = .insufficientEvidence
        }
        return OrganizerSuggestionSummary(strictness: strictness,
                                          candidateCount: candidateCount,
                                          acceptedCount: acceptedCount,
                                          correctAcceptedCount: correctAcceptedCount,
                                          nonAbstainedCount: nonAbstainedCount,
                                          precision: precision,
                                          coverage: coverage,
                                          minimumCandidateCount: thresholds.suggestionMinimumCandidates,
                                          minimumAcceptedCount: thresholds.suggestionMinimumAccepted,
                                          minimumDecisionCountPerSlice: thresholds.suggestionMinimumDecisionCountPerSlice,
                                          minimumPrecision: minimumPrecision,
                                          minimumCoverage: thresholds.suggestionMinimumCoverage,
                                          slices: slices,
                                          status: status)
    }

    private func timingThreshold(kind: OrganizerTimedMetricKind,
                                 thresholds: OrganizerMetricsThresholds) -> Int64 {
        switch kind {
        case .firstAction: thresholds.firstActionP80Milliseconds
        case .fiveConversation: thresholds.fiveConversationP80Milliseconds
        case .retrieval: thresholds.retrievalP80Milliseconds
        }
    }

    private func timingMinimumSamples(kind: OrganizerTimedMetricKind,
                                      thresholds: OrganizerMetricsThresholds) -> Int {
        switch kind {
        case .firstAction: thresholds.firstActionMinimumSamplesPerStratum
        case .fiveConversation: thresholds.fiveConversationMinimumSamplesPerStratum
        case .retrieval: thresholds.retrievalMinimumSamplesPerStratum
        }
    }

    private static func nearestRankPercentile(_ values: [Int64], percentile: Double) -> Int64? {
        guard !values.isEmpty else { return nil }
        let rank = max(1, Int(ceil(percentile * Double(values.count))))
        return values[min(rank, values.count) - 1]
    }

    private static func overallStatus(_ statuses: [OrganizerMetricEvaluationStatus]) -> OrganizerMetricEvaluationStatus {
        guard !statuses.isEmpty else { return .pending }
        if statuses.contains(.fail) { return .fail }
        if statuses.contains(.invalid) { return .invalid }
        if statuses.contains(.insufficientEvidence) { return .insufficientEvidence }
        if statuses.allSatisfy({ $0 == .pass }) { return .pass }
        return .pending
    }
}
