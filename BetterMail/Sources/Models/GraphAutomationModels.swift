import CryptoKit
import Foundation

internal nonisolated enum GraphAutomationRelationship: String, Codable, CaseIterable, Sendable {
    case sameConversation
    case sameTopic
    case unrelated
}

internal nonisolated enum GraphAutomationAction: String, Codable, CaseIterable, Sendable {
    case attachToThread
    case appendToFolder

    internal var localizedTitle: String {
        switch self {
        case .attachToThread:
            return NSLocalizedString("graph.automation.action.attach",
                                     comment: "Automation action that attaches mail to a thread")
        case .appendToFolder:
            return NSLocalizedString("graph.automation.action.append",
                                     comment: "Automation action that appends a thread to a folder")
        }
    }
}

internal nonisolated enum GraphAutomationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case review
    case automatic

    internal var id: String { rawValue }

    internal var localizedTitle: String {
        switch self {
        case .off:
            return NSLocalizedString("graph.automation.mode.off", comment: "Automation mode disabled")
        case .review:
            return NSLocalizedString("graph.automation.mode.review", comment: "Automation mode requiring review")
        case .automatic:
            return NSLocalizedString("graph.automation.mode.automatic", comment: "Automatic automation mode")
        }
    }
}

internal nonisolated enum GraphAutomationStrictness: String, Codable, CaseIterable, Identifiable, Sendable {
    case conservative
    case balanced
    case aggressive

    internal var id: String { rawValue }

    internal var localizedTitle: String {
        switch self {
        case .conservative:
            return NSLocalizedString("graph.automation.strictness.conservative",
                                     comment: "Conservative automation strictness")
        case .balanced:
            return NSLocalizedString("graph.automation.strictness.balanced",
                                     comment: "Balanced automation strictness")
        case .aggressive:
            return NSLocalizedString("graph.automation.strictness.aggressive",
                                     comment: "Aggressive automation strictness")
        }
    }

    internal var thresholds: GraphAutomationThresholds {
        switch self {
        case .conservative:
            return GraphAutomationThresholds(autoAttach: 0.94,
                                             autoFolder: 0.90,
                                             reviewFloor: 0.78,
                                             winnerMargin: 0.10)
        case .balanced:
            return GraphAutomationThresholds(autoAttach: 0.90,
                                             autoFolder: 0.85,
                                             reviewFloor: 0.70,
                                             winnerMargin: 0.08)
        case .aggressive:
            return GraphAutomationThresholds(autoAttach: 0.85,
                                             autoFolder: 0.80,
                                             reviewFloor: 0.62,
                                             winnerMargin: 0.05)
        }
    }
}

internal nonisolated struct GraphAutomationThresholds: Codable, Hashable, Sendable {
    internal let autoAttach: Double
    internal let autoFolder: Double
    internal let reviewFloor: Double
    internal let winnerMargin: Double
}

internal nonisolated enum GraphAutomationExecutionStatus: String, Codable, CaseIterable, Sendable {
    case pendingReview
    case applying
    case applied
    case rejected
    case failed
    case recoveryNeeded
    case undoing
    case undone
    case stale

    internal var needsAttention: Bool {
        switch self {
        case .pendingReview, .failed, .recoveryNeeded:
            return true
        case .applying, .applied, .rejected, .undoing, .undone, .stale:
            return false
        }
    }

    internal var localizedTitle: String {
        switch self {
        case .pendingReview:
            return NSLocalizedString("graph.automation.status.pending", comment: "Pending automation status")
        case .applying:
            return NSLocalizedString("graph.automation.status.applying", comment: "Applying automation status")
        case .applied:
            return NSLocalizedString("graph.automation.status.applied", comment: "Applied automation status")
        case .rejected:
            return NSLocalizedString("graph.automation.status.rejected", comment: "Rejected automation status")
        case .failed:
            return NSLocalizedString("graph.automation.status.failed", comment: "Failed automation status")
        case .recoveryNeeded:
            return NSLocalizedString("graph.automation.status.recovery", comment: "Recovery needed automation status")
        case .undoing:
            return NSLocalizedString("graph.automation.status.undoing", comment: "Undoing automation status")
        case .undone:
            return NSLocalizedString("graph.automation.status.undone", comment: "Undone automation status")
        case .stale:
            return NSLocalizedString("graph.automation.status.stale", comment: "Stale automation status")
        }
    }
}

internal nonisolated enum GraphAutomationMailStatus: String, Codable, Sendable {
    case notRequired
    case pending
    case moving
    case moved
    case failed
    case compensating
    case recoveryNeeded
    case restoring
    case restored
}

internal nonisolated enum GraphAutomationStep: Codable, Hashable, Sendable {
    case attach(sourceThreadID: String, targetThreadID: String, resultingThreadID: String)
    case append(threadID: String, folderID: String)
    case mailbox(messageIDs: [String], account: String, mailboxPath: String)
}

internal nonisolated struct GraphAutomationMessageSource: Identifiable, Codable, Hashable, Sendable {
    internal let messageID: String
    internal let messageKey: String
    internal let internalMailID: String?
    internal let accountName: String
    internal let mailboxPath: String
    internal let date: Date

    internal var id: String {
        GraphAutomationIdentity.make([
            accountName.lowercased(),
            mailboxPath.lowercased(),
            internalMailID ?? "",
            messageID.lowercased()
        ])
    }
}

internal nonisolated struct GraphAutomationSource: Identifiable, Codable, Hashable, Sendable {
    internal let rawThreadID: String
    internal let effectiveThreadID: String
    internal let manualGroupID: String?
    internal let subject: String
    internal let summary: String
    internal let representativeContent: String
    internal let accountName: String
    internal let jwzThreadIDs: Set<String>
    internal let manualMessageKeys: Set<String>
    internal let messages: [GraphAutomationMessageSource]
    internal let fingerprint: String

    internal var id: String { fingerprint }
    internal var messageCount: Int { messages.count }
    internal var isJWZBranch: Bool { !jwzThreadIDs.isEmpty }
    internal var oldestMessageDate: Date { messages.map(\.date).min() ?? .distantFuture }
}

internal nonisolated struct GraphAutomationTarget: Codable, Hashable, Sendable {
    internal let threadID: String?
    internal let folderID: String?
    internal let title: String
    internal let accountName: String?
    internal let fingerprint: String
}

internal nonisolated struct GraphAutomationMutationDelta: Codable, Hashable, Sendable {
    internal let resultingManualGroupID: String?
    internal let manualGroupBefore: ManualThreadGroup?
    internal let removedSourceManualGroup: ManualThreadGroup?
    internal let resultingManualGroupWasPreexisting: Bool
    internal let addedJWZThreadIDs: Set<String>
    internal let addedManualMessageKeys: Set<String>
    internal let sourceThreadIDBefore: String
    internal let targetThreadIDBefore: String?
    internal let sourceFolderIDBefore: String?
    internal let targetFolderIDBefore: String?
    internal let destinationFolderID: String?
}

internal nonisolated struct GraphAutomationProposal: Identifiable, Codable, Hashable, Sendable {
    internal let id: String
    internal let providerVersion: String
    internal let relationship: GraphAutomationRelationship
    internal let action: GraphAutomationAction
    internal var source: GraphAutomationSource
    internal var target: GraphAutomationTarget
    internal var score: Double
    internal var relationshipConfidence: Double
    internal var sharedAnchors: [String]
    internal var subjectActionSimilarity: Double
    internal var reason: String
    internal var isAmbiguous: Bool
    internal var hasExistingFolderConflict: Bool
    internal var hasManualGroupMergeConflict: Bool
    internal var steps: [GraphAutomationStep]
    internal var status: GraphAutomationExecutionStatus
    internal var mailStatus: GraphAutomationMailStatus
    internal var retryCount: Int
    internal var nextRetryAt: Date?
    internal var lastError: String?
    internal var mutationDelta: GraphAutomationMutationDelta?
    internal var movedMessages: [GraphSnipMovedMessage]
    internal let createdAt: Date
    internal var updatedAt: Date

    internal var destinationFolderID: String? { target.folderID }
    internal var destinationThreadID: String? { target.threadID }
    internal var needsAttention: Bool { status.needsAttention }

    internal var confidenceBand: String {
        if score >= 0.90 {
            return NSLocalizedString("graph.automation.confidence.high", comment: "High automation confidence")
        }
        if score >= 0.78 {
            return NSLocalizedString("graph.automation.confidence.medium", comment: "Medium automation confidence")
        }
        return NSLocalizedString("graph.automation.confidence.low", comment: "Low automation confidence")
    }

    internal var actionLabel: String {
        switch action {
        case .attachToThread:
            return String.localizedStringWithFormat(
                NSLocalizedString("graph.automation.label.attach",
                                  comment: "Automation proposal label for attaching messages"),
                source.messageCount,
                target.title
            )
        case .appendToFolder:
            return String.localizedStringWithFormat(
                NSLocalizedString("graph.automation.label.append",
                                  comment: "Automation proposal label for adding threads to a folder"),
                1,
                target.title
            )
        }
    }

    internal static func deterministicID(providerVersion: String,
                                         sourceFingerprint: String,
                                         action: GraphAutomationAction,
                                         targetFingerprint: String) -> String {
        "graph-automation-" + GraphAutomationIdentity.make([
            providerVersion,
            sourceFingerprint,
            action.rawValue,
            targetFingerprint
        ])
    }
}

internal nonisolated struct GraphAutomationObservation: Codable, Hashable, Sendable {
    internal let scopeID: String
    internal let sourceID: String
    internal let fingerprint: String
    internal let providerVersion: String
    internal let wasBaseline: Bool
    internal let evaluatedAt: Date

    internal var id: String { "\(scopeID)|\(sourceID)" }
}

internal nonisolated struct GraphAutomationBatchPersistenceResult: Sendable {
    internal let proposals: [GraphAutomationProposal]
    internal let manualGroups: [ManualThreadGroup]
    internal let folders: [ThreadFolder]
}

internal enum GraphAutomationPersistenceError: LocalizedError {
    case missingTargetFolder(String)
    case missingTargetThread(String)
    case manualGroupMergeRequired
    case invalidProposal
    case staleMutation

    internal var errorDescription: String? {
        switch self {
        case .missingTargetFolder:
            return NSLocalizedString("graph.automation.error.missing_folder",
                                     comment: "Automation target folder no longer exists")
        case .missingTargetThread:
            return NSLocalizedString("graph.automation.error.missing_thread",
                                     comment: "Automation target thread no longer exists")
        case .manualGroupMergeRequired:
            return NSLocalizedString("graph.automation.error.manual_merge",
                                     comment: "Automation would merge manual groups")
        case .invalidProposal:
            return NSLocalizedString("graph.automation.error.invalid_proposal",
                                     comment: "Automation proposal is invalid")
        case .staleMutation:
            return NSLocalizedString("graph.automation.error.stale",
                                     comment: "Automation proposal is stale")
        }
    }
}

internal nonisolated struct GraphAutomationRelationshipSignal: Codable, Hashable, Sendable {
    internal let relationship: GraphAutomationRelationship
    internal let confidence: Double
    internal let sharedAnchors: [String]
    internal let hasSharedNamedTopic: Bool
    internal let hasSameConcreteActionOrEvent: Bool
    internal let reason: String

    internal init(relationship: GraphAutomationRelationship,
                  confidence: Double,
                  sharedAnchors: [String],
                  hasSharedNamedTopic: Bool,
                  hasSameConcreteActionOrEvent: Bool,
                  reason: String) {
        self.relationship = relationship
        self.confidence = min(max(confidence, 0), 1)
        self.sharedAnchors = Array(Set(sharedAnchors.map(GraphTopicNormalizer.displayTitle)
            .filter { !$0.isEmpty })).sorted()
        self.hasSharedNamedTopic = hasSharedNamedTopic
        self.hasSameConcreteActionOrEvent = hasSameConcreteActionOrEvent
        self.reason = GraphTopicNormalizer.supportingReason(reason)
    }
}

internal nonisolated struct GraphAutomationRelationshipRequest: Hashable, Sendable {
    internal let sourceSubject: String
    internal let sourceSummary: String
    internal let sourceContent: String
    internal let targetTitle: String
    internal let targetSummary: String
    internal let targetContent: String
    internal let targetIsFolderProfile: Bool
}

internal nonisolated enum GraphAutomationScorer {
    internal static func score(signal: GraphAutomationRelationshipSignal,
                               sourceText: String,
                               targetText: String) -> (score: Double, anchorOverlap: Double, subjectSimilarity: Double) {
        let sourceTokens = significantTokens(sourceText)
        let targetTokens = significantTokens(targetText)
        let anchorTokens = significantTokens(signal.sharedAnchors.joined(separator: " "))
        let sharedTokens = sourceTokens.intersection(targetTokens)
        let anchorDenominator = max(1, anchorTokens.count)
        let anchorOverlap = min(1, Double(sharedTokens.intersection(anchorTokens).count) / Double(anchorDenominator))
        let unionCount = sourceTokens.union(targetTokens).count
        let lexicalSubjectSimilarity = unionCount == 0
            ? 0
            : Double(sharedTokens.count) / Double(unionCount)
        // The local relationship provider evaluates the concrete action/event
        // semantically. Count that positive signal as the action half of this
        // score so name substitutions in otherwise identical invitations do
        // not make a conservative same-conversation match impossible.
        let subjectSimilarity = signal.hasSameConcreteActionOrEvent
            ? max(lexicalSubjectSimilarity, 1)
            : lexicalSubjectSimilarity
        let weighted = signal.confidence * 0.60 + anchorOverlap * 0.25 + subjectSimilarity * 0.15
        return (rounded(weighted), rounded(anchorOverlap), rounded(subjectSimilarity))
    }

    internal static func significantTokens(_ rawValue: String) -> Set<String> {
        let ignored: Set<String> = [
            "a", "an", "and", "are", "at", "be", "by", "for", "from", "in", "is", "it",
            "join", "mail", "of", "on", "or", "re", "team", "the", "to", "with", "you"
        ]
        return Set(GraphTopicNormalizer.normalize(rawValue)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !ignored.contains($0) })
    }

    private static func rounded(_ value: Double) -> Double {
        (min(max(value, 0), 1) * 1_000_000).rounded() / 1_000_000
    }
}

internal nonisolated enum GraphAutomationIdentity {
    internal static func make(_ components: [String]) -> String {
        let digest = SHA256.hash(data: Data(components.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
