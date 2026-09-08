import Foundation

internal nonisolated enum OrganizerSuggestionDecision: String, Codable, Hashable, Sendable {
    case accepted
    case rejected
    case abstained
}

internal nonisolated enum OrganizerSuggestionGoldLabel: String, Codable, Hashable, Sendable {
    case accepted
    case rejected
}

internal nonisolated enum OrganizerSuggestionConfidenceBand: String, Codable, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high
    case veryHigh = "very-high"
}

internal nonisolated enum OrganizerSuggestionProvenance: String, Codable, CaseIterable, Hashable, Sendable {
    case heuristic
    case foundationModel = "foundation-model"
}

internal nonisolated enum OrganizerSuggestionEvidenceOrigin: String, Codable, Hashable, Sendable {
    case productionProvider
    case frozenProductionPredictions
    case deterministicProviderDouble
    case aggregateOnly

    fileprivate var isAcceptanceEligible: Bool {
        switch self {
        case .productionProvider, .frozenProductionPredictions:
            true
        case .deterministicProviderDouble, .aggregateOnly:
            false
        }
    }
}

/// Version values exported with suggestion evidence. The failable initializer
/// keeps the shareable report limited to short, machine-like identifiers.
internal nonisolated struct OrganizerSuggestionVersionPins: Codable, Hashable, Sendable {
    internal let corpusID: String
    internal let provider: String
    internal let modelVersion: String
    internal let promptOrPolicyVersion: String
    internal let strictness: OrganizerSuggestionStrictness
    internal let appBuild: String
    internal let evidenceOrigin: OrganizerSuggestionEvidenceOrigin

    internal init?(corpusID: String,
                   provider: String,
                   modelVersion: String,
                   promptOrPolicyVersion: String,
                   strictness: OrganizerSuggestionStrictness,
                   appBuild: String,
                   evidenceOrigin: OrganizerSuggestionEvidenceOrigin) {
        let values = [corpusID, provider, modelVersion, promptOrPolicyVersion, appBuild]
        guard values.allSatisfy(Self.isSafeVersionValue) else { return nil }
        self.corpusID = corpusID
        self.provider = provider
        self.modelVersion = modelVersion
        self.promptOrPolicyVersion = promptOrPolicyVersion
        self.strictness = strictness
        self.appBuild = appBuild
        self.evidenceOrigin = evidenceOrigin
    }

    private static func isSafeVersionValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._+")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// Integrity assertions attached to independently prepared input and gold
/// artifacts. Digests bind the evaluator to exact local files without putting
/// synthetic email content into the shareable result.
internal nonisolated struct OrganizerSuggestionCorpusQuality: Codable, Hashable, Sendable {
    internal let corpusID: String
    internal let inputArtifactSHA256: String
    internal let goldArtifactSHA256: String
    internal let hasProductionRelevantInputs: Bool
    internal let keysAreOpaqueAndLabelIndependent: Bool

    internal init?(corpusID: String,
                   inputArtifactSHA256: String,
                   goldArtifactSHA256: String,
                   hasProductionRelevantInputs: Bool,
                   keysAreOpaqueAndLabelIndependent: Bool) {
        guard OrganizerSuggestionVersionPins(
            corpusID: corpusID,
            provider: "validation",
            modelVersion: "validation",
            promptOrPolicyVersion: "validation",
            strictness: .balanced,
            appBuild: "validation",
            evidenceOrigin: .aggregateOnly
        ) != nil,
        Self.isSHA256(inputArtifactSHA256),
        Self.isSHA256(goldArtifactSHA256) else { return nil }
        self.corpusID = corpusID
        self.inputArtifactSHA256 = inputArtifactSHA256.lowercased()
        self.goldArtifactSHA256 = goldArtifactSHA256.lowercased()
        self.hasProductionRelevantInputs = hasProductionRelevantInputs
        self.keysAreOpaqueAndLabelIndependent = keysAreOpaqueAndLabelIndependent
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return value.unicodeScalars.allSatisfy(hexadecimal.contains)
    }
}

/// Provider-facing input deliberately contains no gold label, expected action,
/// expected destination, relation slice, confidence band, or provenance slice.
/// Predictions can therefore be generated and frozen before the evaluator is
/// given access to adjudication data.
internal nonisolated struct OrganizerSuggestionCandidateInput: Codable, Hashable, Sendable {
    internal let candidateKey: String
    internal let sourceKey: String
    /// The opaque destination represented by this source/target candidate.
    /// It is provider-safe routing metadata, not an expected/gold destination.
    internal let targetKey: String
    internal let sourceTitle: String
    internal let sourceSummary: String
    internal let sourceContent: String
    internal let targetTitle: String
    internal let targetSummary: String
    internal let targetContent: String
    internal let targetIsFolderProfile: Bool
}

internal nonisolated struct OrganizerSuggestionGoldRecord: Codable, Hashable, Sendable {
    internal let candidateKey: String
    internal let sourceKey: String
    internal let relation: OrganizerSuggestionSlice
    internal let confidenceBand: OrganizerSuggestionConfidenceBand
    internal let provenance: OrganizerSuggestionProvenance
    internal let expectedLabel: OrganizerSuggestionGoldLabel
    internal let expectedDestinationKey: String?
}

/// A prediction artifact is generated without gold data and joined later on
/// the effective source key. Raw keys never appear in the aggregate report.
internal nonisolated struct OrganizerSuggestionPrediction: Codable, Hashable, Sendable {
    internal let candidateKey: String
    internal let sourceKey: String
    internal let decision: OrganizerSuggestionDecision
    internal let proposedDestinationKey: String?
}

internal nonisolated enum OrganizerSuggestionSliceDimension: String, Codable, Hashable, Sendable {
    case relation
    case confidenceBand
    case provenance
}

/// Placement-capable slices need an accepted-placement denominator. The
/// unrelated relation is a negative control, so requiring accepted placements
/// there would reward false positives; it instead requires evaluated
/// (non-abstained) decisions.
internal nonisolated struct OrganizerSuggestionEvaluationSliceSummary: Codable, Hashable, Sendable {
    internal let dimension: OrganizerSuggestionSliceDimension
    internal let value: String
    internal let candidateCount: Int
    internal let acceptedCount: Int
    internal let correctAcceptedCount: Int
    internal let nonAbstainedCount: Int
    internal let abstainedCount: Int
    internal let precision: Double?
    internal let coverage: Double?
    internal let denominator: OrganizerSuggestionSliceDenominator
    internal let qualifyingDecisionCount: Int
    internal let minimumQualifyingDecisionCount: Int
}

internal nonisolated enum OrganizerSuggestionEvaluationIssue: String, Codable, Hashable, Sendable {
    case missingVersionPins
    case missingCorpusQuality
    case corpusIdentifierMismatch
    case corpusInputsNotProductionRelevant
    case corpusKeysNotLabelIndependent
    case keyLabelLeakageDetected
    case nonProductionEvidenceOrigin
    case emptyGoldCorpus
    case duplicateGoldCandidateKey
    case conflictingGoldSource
    case conflictingPredictionSource
    case predictionIdentityMismatch
    case unmatchedPrediction
    case invalidAcceptedPrediction
    case malformedInputArtifact
    case malformedGoldArtifact
    case malformedPredictionArtifact
    case unreadableInputArtifact
    case unreadableGoldArtifact
    case unreadablePredictionArtifact
    case artifactSchemaMismatch
    case artifactFieldContractViolation
    case inputArtifactDigestMismatch
    case inputGoldIdentityMismatch
    case inputEvidenceInvalid
    case opaqueKeyContractViolation
    case invalidGoldAdjudication
    case invalidPredictionArtifact
    case insufficientCandidates
    case insufficientAccepted
    case insufficientDecisionPerSlice
    case precisionBelowThreshold
    case coverageBelowThreshold
}

internal nonisolated struct OrganizerSuggestionEvaluationReport: Codable, Hashable, Sendable {
    internal static let schemaVersion = "organizer-suggestion-evaluation-v1"

    internal let schemaVersion: String
    internal let pins: OrganizerSuggestionVersionPins?
    internal let corpusQuality: OrganizerSuggestionCorpusQuality?
    internal let status: OrganizerMetricEvaluationStatus
    internal let issueCodes: [OrganizerSuggestionEvaluationIssue]
    internal let candidateCount: Int
    internal let rawPredictionCount: Int
    internal let duplicateGoldSourceCount: Int
    internal let duplicatePredictionSourceCount: Int
    internal let conflictingSourceCount: Int
    internal let unmatchedPredictionCount: Int
    internal let truePositiveCount: Int
    internal let falsePositiveCount: Int
    internal let trueNegativeCount: Int
    internal let falseNegativeCount: Int
    internal let abstainedCount: Int
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
    internal let slices: [OrganizerSuggestionEvaluationSliceSummary]
}

/// Pure scorer for data that has already crossed the artifact-integrity
/// boundary. A direct call is useful for arithmetic/unit tests but cannot, by
/// itself, establish acceptance evidence; production evidence must enter
/// through `OrganizerSuggestionArtifactEvaluator`.
internal nonisolated enum OrganizerSuggestionEvaluator {
    internal static func evaluate(
        pins: OrganizerSuggestionVersionPins?,
        corpusQuality: OrganizerSuggestionCorpusQuality?,
        goldRecords: [OrganizerSuggestionGoldRecord],
        predictions: [OrganizerSuggestionPrediction],
        thresholds: OrganizerMetricsThresholds = .baseline,
        additionalIssues: Set<OrganizerSuggestionEvaluationIssue> = []
    ) -> OrganizerSuggestionEvaluationReport {
        var issues = additionalIssues
        if pins == nil { issues.insert(.missingVersionPins) }
        if corpusQuality == nil { issues.insert(.missingCorpusQuality) }
        if let pins, let corpusQuality, pins.corpusID != corpusQuality.corpusID {
            issues.insert(.corpusIdentifierMismatch)
        }
        if let corpusQuality {
            if !corpusQuality.hasProductionRelevantInputs {
                issues.insert(.corpusInputsNotProductionRelevant)
            }
            if !corpusQuality.keysAreOpaqueAndLabelIndependent {
                issues.insert(.corpusKeysNotLabelIndependent)
            }
        }
        if let pins, !pins.evidenceOrigin.isAcceptanceEligible {
            issues.insert(.nonProductionEvidenceOrigin)
        }
        if goldRecords.isEmpty { issues.insert(.emptyGoldCorpus) }
        if hasDeterministicKeyLabelLeakage(goldRecords) {
            issues.insert(.keyLabelLeakageDetected)
        }

        let candidateKeyCounts = Dictionary(grouping: goldRecords, by: \.candidateKey)
        if candidateKeyCounts.values.contains(where: { $0.count > 1 }) {
            issues.insert(.duplicateGoldCandidateKey)
        }

        let goldBySource = Dictionary(grouping: goldRecords, by: \.sourceKey)
        var canonicalGold: [OrganizerSuggestionGoldRecord] = []
        var allowedCandidateKeysBySource: [String: Set<String>] = [:]
        var duplicateGoldSourceCount = 0
        var conflictingGoldSourceCount = 0
        for sourceKey in goldBySource.keys.sorted() {
            guard let records = goldBySource[sourceKey],
                  let representative = records.sorted(by: { $0.candidateKey < $1.candidateKey }).first else {
                continue
            }
            duplicateGoldSourceCount += max(0, records.count - 1)
            allowedCandidateKeysBySource[sourceKey] = Set(records.map(\.candidateKey))
            let semantics = Set(records.map(GoldSemantics.init))
            if semantics.count > 1 {
                conflictingGoldSourceCount += 1
                issues.insert(.conflictingGoldSource)
            }
            canonicalGold.append(representative)
        }

        let predictionBySource = Dictionary(grouping: predictions, by: \.sourceKey)
        let knownSources = Set(goldBySource.keys)
        let unmatchedPredictions = predictions.filter { !knownSources.contains($0.sourceKey) }
        if !unmatchedPredictions.isEmpty { issues.insert(.unmatchedPrediction) }

        var duplicatePredictionSourceCount = 0
        var conflictingPredictionSourceCount = 0
        var counts = ConfusionCounts()
        var sliceCounts: [SliceKey: ConfusionCounts] = initializedSliceCounts()

        for gold in canonicalGold {
            let sourcePredictions = predictionBySource[gold.sourceKey] ?? []
            duplicatePredictionSourceCount += max(0, sourcePredictions.count - 1)
            let semantics = Set(sourcePredictions.map(PredictionSemantics.init))
            let hasPredictionConflict = semantics.count > 1
            if hasPredictionConflict {
                conflictingPredictionSourceCount += 1
                issues.insert(.conflictingPredictionSource)
            }

            let sortedPredictions = sourcePredictions.sorted { $0.candidateKey < $1.candidateKey }
            var prediction = hasPredictionConflict ? nil : sortedPredictions.first
            if let candidateKeys = allowedCandidateKeysBySource[gold.sourceKey],
               let selectedPrediction = prediction,
               !candidateKeys.contains(selectedPrediction.candidateKey) {
                issues.insert(.predictionIdentityMismatch)
                prediction = nil
            }
            if prediction?.decision == .accepted,
               prediction?.proposedDestinationKey?.isEmpty != false {
                issues.insert(.invalidAcceptedPrediction)
            }

            let outcome = adjudicate(gold: gold, prediction: prediction)
            counts.add(outcome)
            for key in sliceKeys(for: gold) {
                sliceCounts[key, default: ConfusionCounts()].add(outcome)
            }
        }

        let candidateCount = canonicalGold.count
        let acceptedCount = counts.truePositive + counts.falsePositive
        let correctAcceptedCount = counts.truePositive
        let nonAbstainedCount = acceptedCount + counts.trueNegative + counts.falseNegative
        let precision = acceptedCount > 0
            ? Double(correctAcceptedCount) / Double(acceptedCount)
            : nil
        let coverage = candidateCount > 0
            ? Double(nonAbstainedCount) / Double(candidateCount)
            : nil
        let minimumPrecision = pins?.strictness == .conservative
            ? thresholds.suggestionConservativeMinimumPrecision
            : thresholds.suggestionMinimumPrecision

        let slices = orderedSliceKeys().map { key in
            let slice = sliceCounts[key] ?? ConfusionCounts()
            let sliceAccepted = slice.truePositive + slice.falsePositive
            let sliceCorrectAccepted = slice.truePositive
            let sliceNonAbstained = sliceAccepted + slice.trueNegative + slice.falseNegative
            let denominator = sliceDenominator(for: key)
            let qualifyingDecisionCount = switch denominator {
            case .acceptedPlacements: sliceAccepted
            case .nonAbstainedDecisions: sliceNonAbstained
            }
            return OrganizerSuggestionEvaluationSliceSummary(
                dimension: key.dimension,
                value: key.value,
                candidateCount: slice.total,
                acceptedCount: sliceAccepted,
                correctAcceptedCount: sliceCorrectAccepted,
                nonAbstainedCount: sliceNonAbstained,
                abstainedCount: slice.abstained,
                precision: sliceAccepted > 0
                    ? Double(sliceCorrectAccepted) / Double(sliceAccepted)
                    : nil,
                coverage: slice.total > 0
                    ? Double(sliceNonAbstained) / Double(slice.total)
                    : nil,
                denominator: denominator,
                qualifyingDecisionCount: qualifyingDecisionCount,
                minimumQualifyingDecisionCount: thresholds.suggestionMinimumDecisionCountPerSlice
            )
        }

        if candidateCount < thresholds.suggestionMinimumCandidates {
            issues.insert(.insufficientCandidates)
        }
        if acceptedCount < thresholds.suggestionMinimumAccepted {
            issues.insert(.insufficientAccepted)
        }
        if slices.contains(where: {
            $0.qualifyingDecisionCount < $0.minimumQualifyingDecisionCount
        }) {
            issues.insert(.insufficientDecisionPerSlice)
        }
        if let precision, precision < minimumPrecision {
            issues.insert(.precisionBelowThreshold)
        }
        if let coverage, coverage < thresholds.suggestionMinimumCoverage {
            issues.insert(.coverageBelowThreshold)
        }

        let insufficientIssues: Set<OrganizerSuggestionEvaluationIssue> = [
            .missingVersionPins,
            .missingCorpusQuality,
            .corpusIdentifierMismatch,
            .corpusInputsNotProductionRelevant,
            .corpusKeysNotLabelIndependent,
            .keyLabelLeakageDetected,
            .nonProductionEvidenceOrigin,
            .emptyGoldCorpus,
            .duplicateGoldCandidateKey,
            .conflictingGoldSource,
            .conflictingPredictionSource,
            .predictionIdentityMismatch,
            .unmatchedPrediction,
            .invalidAcceptedPrediction,
            .malformedInputArtifact,
            .malformedGoldArtifact,
            .malformedPredictionArtifact,
            .unreadableInputArtifact,
            .unreadableGoldArtifact,
            .unreadablePredictionArtifact,
            .artifactSchemaMismatch,
            .artifactFieldContractViolation,
            .inputArtifactDigestMismatch,
            .inputGoldIdentityMismatch,
            .inputEvidenceInvalid,
            .opaqueKeyContractViolation,
            .invalidGoldAdjudication,
            .invalidPredictionArtifact,
            .insufficientCandidates,
            .insufficientAccepted,
            .insufficientDecisionPerSlice,
        ]
        let status: OrganizerMetricEvaluationStatus
        if !issues.isDisjoint(with: insufficientIssues) {
            status = .insufficientEvidence
        } else if issues.contains(.precisionBelowThreshold) || issues.contains(.coverageBelowThreshold) {
            status = .fail
        } else {
            status = .pass
        }

        return OrganizerSuggestionEvaluationReport(
            schemaVersion: OrganizerSuggestionEvaluationReport.schemaVersion,
            pins: pins,
            corpusQuality: corpusQuality,
            status: status,
            issueCodes: issues.sorted { $0.rawValue < $1.rawValue },
            candidateCount: candidateCount,
            rawPredictionCount: predictions.count,
            duplicateGoldSourceCount: duplicateGoldSourceCount,
            duplicatePredictionSourceCount: duplicatePredictionSourceCount,
            conflictingSourceCount: conflictingGoldSourceCount + conflictingPredictionSourceCount,
            unmatchedPredictionCount: unmatchedPredictions.count,
            truePositiveCount: counts.truePositive,
            falsePositiveCount: counts.falsePositive,
            trueNegativeCount: counts.trueNegative,
            falseNegativeCount: counts.falseNegative,
            abstainedCount: counts.abstained,
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
            slices: slices
        )
    }

    private enum AdjudicatedOutcome {
        case truePositive
        case falsePositive
        case trueNegative
        case falseNegative
        case abstained
    }

    private struct GoldSemantics: Hashable {
        let relation: OrganizerSuggestionSlice
        let confidenceBand: OrganizerSuggestionConfidenceBand
        let provenance: OrganizerSuggestionProvenance
        let expectedLabel: OrganizerSuggestionGoldLabel
        let expectedDestinationKey: String?

        init(_ record: OrganizerSuggestionGoldRecord) {
            relation = record.relation
            confidenceBand = record.confidenceBand
            provenance = record.provenance
            expectedLabel = record.expectedLabel
            expectedDestinationKey = record.expectedDestinationKey
        }
    }

    private struct PredictionSemantics: Hashable {
        let decision: OrganizerSuggestionDecision
        let destinationKey: String?

        init(_ prediction: OrganizerSuggestionPrediction) {
            decision = prediction.decision
            destinationKey = prediction.proposedDestinationKey
        }
    }

    private struct SliceKey: Hashable {
        let dimension: OrganizerSuggestionSliceDimension
        let value: String
    }

    private struct ConfusionCounts {
        var truePositive = 0
        var falsePositive = 0
        var trueNegative = 0
        var falseNegative = 0
        var abstained = 0

        var total: Int {
            truePositive + falsePositive + trueNegative + falseNegative + abstained
        }

        mutating func add(_ outcome: AdjudicatedOutcome) {
            switch outcome {
            case .truePositive: truePositive += 1
            case .falsePositive: falsePositive += 1
            case .trueNegative: trueNegative += 1
            case .falseNegative: falseNegative += 1
            case .abstained: abstained += 1
            }
        }
    }

    private static func adjudicate(gold: OrganizerSuggestionGoldRecord,
                                   prediction: OrganizerSuggestionPrediction?) -> AdjudicatedOutcome {
        guard let prediction, prediction.decision != .abstained else { return .abstained }
        switch prediction.decision {
        case .accepted:
            let isCorrect = gold.expectedLabel == .accepted
                && prediction.proposedDestinationKey == gold.expectedDestinationKey
                && prediction.proposedDestinationKey?.isEmpty == false
            return isCorrect ? .truePositive : .falsePositive
        case .rejected:
            return gold.expectedLabel == .rejected ? .trueNegative : .falseNegative
        case .abstained:
            return .abstained
        }
    }

    private static func sliceKeys(for gold: OrganizerSuggestionGoldRecord) -> [SliceKey] {
        [
            SliceKey(dimension: .relation, value: gold.relation.rawValue),
            SliceKey(dimension: .confidenceBand, value: gold.confidenceBand.rawValue),
            SliceKey(dimension: .provenance, value: gold.provenance.rawValue),
        ]
    }

    private static func initializedSliceCounts() -> [SliceKey: ConfusionCounts] {
        Dictionary(uniqueKeysWithValues: orderedSliceKeys().map { ($0, ConfusionCounts()) })
    }

    private static func sliceDenominator(
        for key: SliceKey
    ) -> OrganizerSuggestionSliceDenominator {
        if key.dimension == .relation,
           key.value == OrganizerSuggestionSlice.unrelated.rawValue {
            return .nonAbstainedDecisions
        }
        return .acceptedPlacements
    }

    /// Rejects the simple sequential-key label channel present in the original
    /// v1 scaffold. It is intentionally conservative: every record must have a
    /// trailing decimal key and a small modulus must perfectly determine the
    /// label before the corpus is blocked.
    internal static func hasDeterministicKeyLabelLeakage(
        _ records: [OrganizerSuggestionGoldRecord]
    ) -> Bool {
        guard records.count >= 20 else { return false }
        let keyPaths: [(OrganizerSuggestionGoldRecord) -> String] = [
            { $0.candidateKey },
            { $0.sourceKey },
        ]
        return keyPaths.contains { keyPath in
            let keyedLabels = records.compactMap { record -> (Int, OrganizerSuggestionGoldLabel)? in
                guard let suffix = trailingDecimalInteger(in: keyPath(record)) else { return nil }
                return (suffix, record.expectedLabel)
            }
            guard keyedLabels.count == records.count else { return false }
            for modulus in 2...10 {
                var labelsByResidue: [Int: Set<OrganizerSuggestionGoldLabel>] = [:]
                for (key, label) in keyedLabels {
                    labelsByResidue[key % modulus, default: []].insert(label)
                }
                let representedLabels = Set(labelsByResidue.values.flatMap { $0 })
                if representedLabels.count > 1,
                   labelsByResidue.values.allSatisfy({ $0.count == 1 }) {
                    return true
                }
            }
            return false
        }
    }

    private static func trailingDecimalInteger(in value: String) -> Int? {
        let digits = value.reversed().prefix { $0.isNumber }.reversed()
        guard !digits.isEmpty else { return nil }
        return Int(String(digits))
    }

    private static func orderedSliceKeys() -> [SliceKey] {
        OrganizerSuggestionSlice.allCases.map {
            SliceKey(dimension: .relation, value: $0.rawValue)
        } + OrganizerSuggestionConfidenceBand.allCases.map {
            SliceKey(dimension: .confidenceBand, value: $0.rawValue)
        } + OrganizerSuggestionProvenance.allCases.map {
            SliceKey(dimension: .provenance, value: $0.rawValue)
        }
    }
}
