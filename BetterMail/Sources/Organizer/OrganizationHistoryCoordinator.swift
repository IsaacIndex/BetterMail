import Combine
import Foundation

internal enum OrganizationHistorySource: String, Codable, Hashable, Sendable {
    case ledger
    case legacyGraphArchive
    case legacySnip
    case legacyGraphAutomation
}

internal enum OrganizationHistoryStatus: String, Codable, Hashable, Sendable {
    case prepared
    case applying
    case completed
    case partial
    case recovery
    case undone
    case rejected
    case stale
}

internal struct OrganizationHistoryItem: Identifiable, Equatable, Sendable {
    internal let id: String
    internal let source: OrganizationHistorySource
    internal let kind: OrganizationOperationKind
    internal let effect: OrganizationOperationEffect
    internal let status: OrganizationHistoryStatus
    internal let affectedCount: Int
    internal let titleLocalizationKey: String
    internal let createdAt: Date
    internal let updatedAt: Date
    internal let canUndo: Bool
    internal let needsRecovery: Bool
    internal let retryCount: Int
}

internal enum OrganizationHistoryProjection {
    internal static func make(operations: [OrganizationOperation],
                              legacyCompost: [GraphCompostEntry],
                              legacyAutomation: [GraphAutomationProposal]) -> [OrganizationHistoryItem] {
        let ledgerItems = operations.map(item(from:))
        let ledgerIDs = Set(operations.map(\.id))
        let compostItems = legacyCompost.compactMap { entry -> OrganizationHistoryItem? in
            let legacyID = "legacy-compost:\(entry.id)"
            guard !ledgerIDs.contains(legacyID) else { return nil }
            return item(from: entry, id: legacyID)
        }
        let automationItems = legacyAutomation.compactMap { proposal -> OrganizationHistoryItem? in
            let legacyID = "legacy-automation:\(proposal.id)"
            guard !ledgerIDs.contains(legacyID) else { return nil }
            return item(from: proposal, id: legacyID)
        }
        return (ledgerItems + compostItems + automationItems).sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    private static func item(from operation: OrganizationOperation) -> OrganizationHistoryItem {
        let status: OrganizationHistoryStatus
        switch operation.phase {
        case .prepared:
            status = .prepared
        case .appApplied, .layoutPending, .mailApplying:
            status = .applying
        case .completed:
            status = .completed
        case .partial:
            status = .partial
        case .recovery:
            status = .recovery
        case .undone:
            status = .undone
        }
        // The durable command service currently owns conditional inverse tokens
        // only for completed manual Group/ungroup mutations. Mail, suggestion,
        // archive, automation, and partial operations expose recovery/legacy
        // controls elsewhere; advertising ledger undo here would promise a route
        // the command service cannot execute.
        let canUndo = operation.phase == .completed
            && (operation.kind == .manualGroup || operation.kind == .manualUngroup)
        return OrganizationHistoryItem(
            id: operation.id,
            source: .ledger,
            kind: operation.kind,
            effect: effect(for: operation),
            status: status,
            affectedCount: max(operation.opaqueSourceFingerprints.count,
                               operation.receipts.map(\.expectedCount).max() ?? 0),
            titleLocalizationKey: "organizer.history.\(operation.kind.rawValue).title",
            createdAt: operation.createdAt,
            updatedAt: operation.updatedAt,
            canUndo: canUndo,
            needsRecovery: operation.phase == .partial || operation.phase == .recovery,
            retryCount: operation.retryCount
        )
    }

    private static func effect(for operation: OrganizationOperation) -> OrganizationOperationEffect {
        if let authorizationEffect = operation.authorizationReference?.effect {
            return authorizationEffect
        }
        switch operation.kind {
        case .manualGroup, .manualUngroup, .suggestionAcceptance, .graphArchive:
            return .betterMailOnly
        case .snip, .mailMove:
            return .messageMove
        case .mailboxCreation:
            return .mailboxCreation
        case .automation:
            return operation.mailRouteEnvelope == nil ? .betterMailOnly : .mixed
        case .retry, .recovery, .undo:
            return operation.mailRouteEnvelope == nil ? .betterMailOnly : .restore
        }
    }

    private static func item(from entry: GraphCompostEntry,
                             id: String) -> OrganizationHistoryItem {
        let isArchive = entry.action == .archive
        return OrganizationHistoryItem(
            id: id,
            source: isArchive ? .legacyGraphArchive : .legacySnip,
            kind: isArchive ? .graphArchive : .snip,
            effect: isArchive ? .betterMailOnly : .messageMove,
            status: entry.requiresRecovery ? .recovery : .completed,
            affectedCount: max(entry.messageIDs.count, entry.movedMessages.count),
            titleLocalizationKey: isArchive
                ? "organizer.history.graphArchive.title"
                : "organizer.history.snip.title",
            createdAt: entry.createdAt,
            updatedAt: entry.createdAt,
            canUndo: true,
            needsRecovery: entry.requiresRecovery,
            retryCount: 0
        )
    }

    private static func item(from proposal: GraphAutomationProposal,
                             id: String) -> OrganizationHistoryItem {
        let status: OrganizationHistoryStatus
        switch proposal.status {
        case .pendingReview:
            status = .prepared
        case .applying, .undoing:
            status = .applying
        case .applied:
            status = .completed
        case .failed:
            status = .partial
        case .recoveryNeeded:
            status = .recovery
        case .undone:
            status = .undone
        case .rejected:
            status = .rejected
        case .stale:
            status = .stale
        }
        let hasMailEffect = proposal.steps.contains { step in
            if case .mailbox = step { return true }
            return false
        }
        return OrganizationHistoryItem(
            id: id,
            source: .legacyGraphAutomation,
            kind: .automation,
            effect: hasMailEffect ? .mixed : .betterMailOnly,
            status: status,
            affectedCount: proposal.source.messageCount,
            titleLocalizationKey: "organizer.history.automation.title",
            createdAt: proposal.createdAt,
            updatedAt: proposal.updatedAt,
            canUndo: [.applied, .failed, .recoveryNeeded].contains(proposal.status),
            needsRecovery: proposal.status == .recoveryNeeded,
            retryCount: proposal.retryCount
        )
    }
}

/// Dismissal is presentation-only. The ledger and legacy recovery records are
/// never deleted when a row is hidden.
@MainActor
internal final class OrganizationHistoryCoordinator: ObservableObject {
    @Published internal private(set) var visibleItems: [OrganizationHistoryItem] = []
    private var allItems: [OrganizationHistoryItem] = []
    private var dismissedIDs: Set<String> = []

    internal func refresh(operations: [OrganizationOperation],
                          legacyCompost: [GraphCompostEntry],
                          legacyAutomation: [GraphAutomationProposal]) {
        allItems = OrganizationHistoryProjection.make(operations: operations,
                                                      legacyCompost: legacyCompost,
                                                      legacyAutomation: legacyAutomation)
        publish()
    }

    internal func dismiss(id: String) {
        dismissedIDs.insert(id)
        publish()
    }

    internal func revealAll() {
        dismissedIDs.removeAll()
        publish()
    }

    private func publish() {
        visibleItems = allItems.filter { !dismissedIDs.contains($0.id) }
    }
}
