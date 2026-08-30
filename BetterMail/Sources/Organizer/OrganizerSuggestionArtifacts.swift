import CryptoKit
import Foundation

internal nonisolated enum OrganizerSuggestionKeyPolicy: String, Codable, Hashable, Sendable {
    /// Candidate/source/destination keys are assigned before adjudication and
    /// contain 256-bit random opaque values. The declaration is bound to the
    /// exact input artifact digest and must still be supported by the corpus
    /// preparation record; it is not inferred from prediction quality.
    case randomBeforeAdjudicationV1 = "random-before-adjudication-v1"
}

internal nonisolated enum OrganizerSuggestionContentPolicy: String, Codable, Hashable, Sendable {
    case syntheticProductionRelevantV1 = "synthetic-production-relevant-v1"
}

internal nonisolated enum OrganizerSuggestionUnrelatedOutcomePolicy: String, Codable, Hashable, Sendable {
    /// Unrelated candidates are negative controls. A correct prediction is a
    /// rejection, never an accepted placement.
    case correctRejectionV1 = "correct-rejection-v1"
}

internal nonisolated struct OrganizerSuggestionInputArtifact: Codable, Hashable, Sendable {
    internal static let currentSchemaVersion = "organizer-suggestion-input-v2"

    internal let schemaVersion: String
    internal let corpusID: String
    internal let keyPolicy: OrganizerSuggestionKeyPolicy
    internal let contentPolicy: OrganizerSuggestionContentPolicy
    internal let candidates: [OrganizerSuggestionCandidateInput]

    internal init(corpusID: String,
                  candidates: [OrganizerSuggestionCandidateInput],
                  keyPolicy: OrganizerSuggestionKeyPolicy = .randomBeforeAdjudicationV1,
                  contentPolicy: OrganizerSuggestionContentPolicy = .syntheticProductionRelevantV1) {
        self.schemaVersion = Self.currentSchemaVersion
        self.corpusID = corpusID
        self.keyPolicy = keyPolicy
        self.contentPolicy = contentPolicy
        self.candidates = candidates
    }
}

internal nonisolated struct OrganizerSuggestionGoldArtifact: Codable, Hashable, Sendable {
    internal static let currentSchemaVersion = "organizer-suggestion-gold-v2"

    internal let schemaVersion: String
    internal let corpusID: String
    internal let unrelatedOutcomePolicy: OrganizerSuggestionUnrelatedOutcomePolicy
    internal let records: [OrganizerSuggestionGoldRecord]

    internal init(corpusID: String,
                  records: [OrganizerSuggestionGoldRecord],
                  unrelatedOutcomePolicy: OrganizerSuggestionUnrelatedOutcomePolicy = .correctRejectionV1) {
        self.schemaVersion = Self.currentSchemaVersion
        self.corpusID = corpusID
        self.unrelatedOutcomePolicy = unrelatedOutcomePolicy
        self.records = records
    }
}

internal nonisolated struct OrganizerSuggestionPredictionArtifact: Codable, Hashable, Sendable {
    internal static let currentSchemaVersion = "organizer-suggestion-predictions-v2"

    internal let schemaVersion: String
    internal let corpusID: String
    /// Digest of the exact provider-facing bytes used to generate predictions.
    internal let inputArtifactSHA256: String
    internal let pins: OrganizerSuggestionVersionPins
    internal let predictions: [OrganizerSuggestionPrediction]

    internal init(corpusID: String,
                  inputArtifactSHA256: String,
                  pins: OrganizerSuggestionVersionPins,
                  predictions: [OrganizerSuggestionPrediction]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.corpusID = corpusID
        self.inputArtifactSHA256 = inputArtifactSHA256.lowercased()
        self.pins = pins
        self.predictions = predictions
    }
}

/// Decodes and binds the three acceptance artifacts before the pure evaluator
/// sees gold data. Exact JSON field sets keep provider input structurally free
/// of adjudication fields; exact-byte SHA-256 binding prevents predictions from
/// being joined to a different provider-input file.
internal nonisolated enum OrganizerSuggestionArtifactEvaluator {
    internal static func evaluate(
        inputArtifactURL: URL,
        goldArtifactURL: URL,
        predictionArtifactURL: URL,
        thresholds: OrganizerMetricsThresholds = .baseline
    ) -> OrganizerSuggestionEvaluationReport {
        var loadIssues: Set<OrganizerSuggestionEvaluationIssue> = []
        let inputData = loadData(inputArtifactURL,
                                 issue: .unreadableInputArtifact,
                                 issues: &loadIssues)
        let goldData = loadData(goldArtifactURL,
                                issue: .unreadableGoldArtifact,
                                issues: &loadIssues)
        let predictionData = loadData(predictionArtifactURL,
                                      issue: .unreadablePredictionArtifact,
                                      issues: &loadIssues)
        return evaluate(
            inputArtifactData: inputData,
            goldArtifactData: goldData,
            predictionArtifactData: predictionData,
            thresholds: thresholds,
            initialIssues: loadIssues
        )
    }

    internal static func evaluate(
        inputArtifactData: Data,
        goldArtifactData: Data,
        predictionArtifactData: Data,
        thresholds: OrganizerMetricsThresholds = .baseline
    ) -> OrganizerSuggestionEvaluationReport {
        evaluate(
            inputArtifactData: inputArtifactData,
            goldArtifactData: goldArtifactData,
            predictionArtifactData: predictionArtifactData,
            thresholds: thresholds,
            initialIssues: []
        )
    }

    private static func evaluate(
        inputArtifactData: Data,
        goldArtifactData: Data,
        predictionArtifactData: Data,
        thresholds: OrganizerMetricsThresholds,
        initialIssues: Set<OrganizerSuggestionEvaluationIssue>
    ) -> OrganizerSuggestionEvaluationReport {
        let decoder = JSONDecoder()
        var issues = initialIssues

        let inputArtifact: OrganizerSuggestionInputArtifact?
        do {
            inputArtifact = try decoder.decode(OrganizerSuggestionInputArtifact.self,
                                               from: inputArtifactData)
        } catch {
            inputArtifact = nil
            issues.insert(.malformedInputArtifact)
        }

        let goldArtifact: OrganizerSuggestionGoldArtifact?
        do {
            goldArtifact = try decoder.decode(OrganizerSuggestionGoldArtifact.self,
                                              from: goldArtifactData)
        } catch {
            goldArtifact = nil
            issues.insert(.malformedGoldArtifact)
        }

        let predictionArtifact: OrganizerSuggestionPredictionArtifact?
        do {
            predictionArtifact = try decoder.decode(OrganizerSuggestionPredictionArtifact.self,
                                                    from: predictionArtifactData)
        } catch {
            predictionArtifact = nil
            issues.insert(.malformedPredictionArtifact)
        }

        if inputArtifact != nil,
           !hasExactInputFieldContract(inputArtifactData) {
            issues.insert(.artifactFieldContractViolation)
        }
        if goldArtifact != nil,
           !hasExactGoldFieldContract(goldArtifactData) {
            issues.insert(.artifactFieldContractViolation)
        }
        if predictionArtifact != nil,
           !hasExactPredictionFieldContract(predictionArtifactData) {
            issues.insert(.artifactFieldContractViolation)
        }

        if let inputArtifact,
           inputArtifact.schemaVersion != OrganizerSuggestionInputArtifact.currentSchemaVersion {
            issues.insert(.artifactSchemaMismatch)
        }
        if let goldArtifact,
           goldArtifact.schemaVersion != OrganizerSuggestionGoldArtifact.currentSchemaVersion {
            issues.insert(.artifactSchemaMismatch)
        }
        if let predictionArtifact,
           predictionArtifact.schemaVersion != OrganizerSuggestionPredictionArtifact.currentSchemaVersion {
            issues.insert(.artifactSchemaMismatch)
        }

        let corpusIDs = Set([
            inputArtifact?.corpusID,
            goldArtifact?.corpusID,
            predictionArtifact?.corpusID,
            predictionArtifact?.pins.corpusID,
        ].compactMap { $0 })
        if corpusIDs.count > 1 {
            issues.insert(.corpusIdentifierMismatch)
        }

        let inputDigest = sha256Hex(inputArtifactData)
        let goldDigest = sha256Hex(goldArtifactData)
        if let predictionArtifact,
           predictionArtifact.inputArtifactSHA256.lowercased() != inputDigest {
            issues.insert(.inputArtifactDigestMismatch)
        }

        let validPins: OrganizerSuggestionVersionPins?
        if let pins = predictionArtifact?.pins,
           let validated = OrganizerSuggestionVersionPins(
               corpusID: pins.corpusID,
               provider: pins.provider,
               modelVersion: pins.modelVersion,
               promptOrPolicyVersion: pins.promptOrPolicyVersion,
               strictness: pins.strictness,
               appBuild: pins.appBuild,
               evidenceOrigin: pins.evidenceOrigin
           ), validated == pins {
            validPins = validated
        } else {
            validPins = nil
            if predictionArtifact != nil {
                issues.insert(.invalidPredictionArtifact)
            }
        }

        var inputByIdentity: [CandidateIdentity: OrganizerSuggestionCandidateInput] = [:]
        var inputIdentityIsExact = true
        var productionRelevantInputs = false
        var opaqueKeys = false
        if let inputArtifact {
            let identities = inputArtifact.candidates.map(CandidateIdentity.init)
            inputIdentityIsExact = Set(identities).count == identities.count
            if !inputIdentityIsExact {
                issues.insert(.inputGoldIdentityMismatch)
            }
            for candidate in inputArtifact.candidates {
                inputByIdentity[CandidateIdentity(candidate)] = candidate
            }

            productionRelevantInputs = inputArtifact.contentPolicy == .syntheticProductionRelevantV1
                && inputArtifact.candidates.allSatisfy(hasProductionRelevantEvidence)
            if !productionRelevantInputs {
                issues.insert(.inputEvidenceInvalid)
            }

            opaqueKeys = inputArtifact.keyPolicy == .randomBeforeAdjudicationV1
                && inputArtifact.candidates.allSatisfy {
                    isOpaqueKey($0.candidateKey, prefix: "candidate-")
                        && isOpaqueKey($0.sourceKey, prefix: "source-")
                        && isOpaqueKey($0.targetKey, prefix: "destination-")
                }
            if !opaqueKeys {
                issues.insert(.opaqueKeyContractViolation)
            }
        }

        var goldIdentityIsExact = false
        var goldAdjudicationIsValid = false
        if let inputArtifact, let goldArtifact {
            let inputIdentities = Set(inputArtifact.candidates.map(CandidateIdentity.init))
            let goldIdentities = Set(goldArtifact.records.map(CandidateIdentity.init))
            goldIdentityIsExact = inputIdentityIsExact
                && inputIdentities == goldIdentities
                && goldIdentities.count == goldArtifact.records.count
            if !goldIdentityIsExact {
                issues.insert(.inputGoldIdentityMismatch)
            }

            goldAdjudicationIsValid = goldArtifact.unrelatedOutcomePolicy == .correctRejectionV1
                && goldArtifact.records.allSatisfy { record in
                    guard let input = inputByIdentity[CandidateIdentity(record)] else { return false }
                    if record.relation == .unrelated,
                       record.expectedLabel != .rejected {
                        return false
                    }
                    switch record.expectedLabel {
                    case .accepted:
                        return record.expectedDestinationKey == input.targetKey
                    case .rejected:
                        return record.expectedDestinationKey == nil
                    }
                }
            if !goldAdjudicationIsValid {
                issues.insert(.invalidGoldAdjudication)
            }
        }

        if let predictionArtifact {
            let predictionIsValid = predictionArtifact.predictions.allSatisfy { prediction in
                guard inputByIdentity[CandidateIdentity(prediction)] != nil else { return false }
                switch prediction.decision {
                case .accepted:
                    // A well-formed but wrong destination is quality evidence:
                    // the pure evaluator must count it as a false positive.
                    guard let destinationKey = prediction.proposedDestinationKey else { return false }
                    return isOpaqueKey(destinationKey, prefix: "destination-")
                case .rejected, .abstained:
                    return prediction.proposedDestinationKey == nil
                }
            }
            if !predictionIsValid {
                issues.insert(.invalidPredictionArtifact)
            }
        }

        let goldRecords = goldArtifact?.records ?? []
        let labelIndependentKeys = opaqueKeys
            && goldIdentityIsExact
            && !OrganizerSuggestionEvaluator.hasDeterministicKeyLabelLeakage(goldRecords)
        let qualityCorpusID = inputArtifact?.corpusID ?? goldArtifact?.corpusID ?? ""
        let corpusQuality = OrganizerSuggestionCorpusQuality(
            corpusID: qualityCorpusID,
            inputArtifactSHA256: inputDigest,
            goldArtifactSHA256: goldDigest,
            hasProductionRelevantInputs: productionRelevantInputs,
            keysAreOpaqueAndLabelIndependent: labelIndependentKeys
        )

        return OrganizerSuggestionEvaluator.evaluate(
            pins: validPins,
            corpusQuality: corpusQuality,
            goldRecords: goldRecords,
            predictions: predictionArtifact?.predictions ?? [],
            thresholds: thresholds,
            additionalIssues: issues
        )
    }

    internal static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadData(
        _ url: URL,
        issue: OrganizerSuggestionEvaluationIssue,
        issues: inout Set<OrganizerSuggestionEvaluationIssue>
    ) -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            issues.insert(issue)
            return Data()
        }
    }

    private struct CandidateIdentity: Hashable {
        let candidateKey: String
        let sourceKey: String

        init(_ input: OrganizerSuggestionCandidateInput) {
            candidateKey = input.candidateKey
            sourceKey = input.sourceKey
        }

        init(_ gold: OrganizerSuggestionGoldRecord) {
            candidateKey = gold.candidateKey
            sourceKey = gold.sourceKey
        }

        init(_ prediction: OrganizerSuggestionPrediction) {
            candidateKey = prediction.candidateKey
            sourceKey = prediction.sourceKey
        }
    }

    private static func hasProductionRelevantEvidence(
        _ input: OrganizerSuggestionCandidateInput
    ) -> Bool {
        [input.sourceTitle,
         input.sourceSummary,
         input.sourceContent,
         input.targetTitle,
         input.targetSummary,
         input.targetContent].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func isOpaqueKey(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = value.dropFirst(prefix.count)
        guard suffix.count == 64 else { return false }
        return suffix.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func hasExactInputFieldContract(_ data: Data) -> Bool {
        hasExactFieldContract(
            data,
            topLevelFields: ["schemaVersion", "corpusID", "keyPolicy", "contentPolicy", "candidates"],
            recordsField: "candidates",
            requiredRecordFields: [
                "candidateKey", "sourceKey", "targetKey", "sourceTitle", "sourceSummary",
                "sourceContent", "targetTitle", "targetSummary", "targetContent",
                "targetIsFolderProfile",
            ],
            optionalRecordFields: []
        )
    }

    private static func hasExactGoldFieldContract(_ data: Data) -> Bool {
        hasExactFieldContract(
            data,
            topLevelFields: ["schemaVersion", "corpusID", "unrelatedOutcomePolicy", "records"],
            recordsField: "records",
            requiredRecordFields: [
                "candidateKey", "sourceKey", "relation", "confidenceBand", "provenance",
                "expectedLabel",
            ],
            optionalRecordFields: ["expectedDestinationKey"]
        )
    }

    private static func hasExactPredictionFieldContract(_ data: Data) -> Bool {
        guard hasExactFieldContract(
            data,
            topLevelFields: ["schemaVersion", "corpusID", "inputArtifactSHA256", "pins", "predictions"],
            recordsField: "predictions",
            requiredRecordFields: ["candidateKey", "sourceKey", "decision"],
            optionalRecordFields: ["proposedDestinationKey"]
        ),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let pins = object["pins"] as? [String: Any] else {
            return false
        }
        return Set(pins.keys) == [
            "corpusID", "provider", "modelVersion", "promptOrPolicyVersion",
            "strictness", "appBuild", "evidenceOrigin",
        ]
    }

    private static func hasExactFieldContract(
        _ data: Data,
        topLevelFields: Set<String>,
        recordsField: String,
        requiredRecordFields: Set<String>,
        optionalRecordFields: Set<String>
    ) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == topLevelFields,
              let records = object[recordsField] as? [[String: Any]] else {
            return false
        }
        let allowedRecordFields = requiredRecordFields.union(optionalRecordFields)
        return records.allSatisfy {
            let fields = Set($0.keys)
            return requiredRecordFields.isSubset(of: fields)
                && fields.isSubset(of: allowedRecordFields)
        }
    }
}
