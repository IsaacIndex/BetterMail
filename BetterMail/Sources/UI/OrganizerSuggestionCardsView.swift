import Foundation
import SwiftUI

internal enum OrganizerSuggestionCardAction: String, CaseIterable, Hashable, Sendable {
    case edit
    case approve
    case reject
    case hide
    case retry
    case undo
}

internal enum OrganizerSuggestionActionPolicy {
    internal static func actions(status: GraphAutomationExecutionStatus,
                                 hasMutationDelta: Bool) -> Set<OrganizerSuggestionCardAction> {
        var actions: Set<OrganizerSuggestionCardAction> = [.hide]
        switch status {
        case .pendingReview:
            actions.formUnion([.edit, .approve, .reject])
        case .failed, .recoveryNeeded:
            actions.insert(.retry)
            if hasMutationDelta { actions.insert(.undo) }
        case .applied:
            if hasMutationDelta { actions.insert(.undo) }
        case .applying, .undoing, .rejected, .undone, .stale:
            break
        }
        return actions
    }
}

internal struct OrganizerSuggestionPresentation: Equatable, Sendable {
    internal let id: String
    internal let title: String
    internal let rationale: String
    internal let sourceTitle: String
    internal let currentDestination: String
    internal let proposedDestination: String
    internal let confidencePercent: Int
    internal let provenance: String
    internal let memberCount: Int
    internal let lastEvaluatedAt: Date
    internal let effectCategory: OrganizationEffectCategory
    internal let isReviewOnlyFallback: Bool
    internal let actions: Set<OrganizerSuggestionCardAction>

    internal init(proposal: GraphAutomationProposal,
                  folders: [ThreadFolder]) {
        id = proposal.id
        title = proposal.actionLabel
        rationale = proposal.reason
        sourceTitle = proposal.source.subject
        proposedDestination = proposal.target.title
        confidencePercent = Int((proposal.score * 100).rounded())
        provenance = proposal.providerVersion
        memberCount = proposal.source.messageCount
        lastEvaluatedAt = proposal.updatedAt
        let hasMailEffect = proposal.steps.contains { step in
            if case .mailbox = step { return true }
            return false
        }
        effectCategory = hasMailEffect ? .mixed : .betterMailOnly
        let normalizedProvider = proposal.providerVersion.lowercased()
        isReviewOnlyFallback = normalizedProvider.contains("fallback")
            || normalizedProvider.contains("heuristic")
            || normalizedProvider.contains("deterministic")
        var resolvedActions = OrganizerSuggestionActionPolicy.actions(
            status: proposal.status,
            hasMutationDelta: proposal.mutationDelta != nil
        )
        if !proposal.canRetryOrganizationWork {
            resolvedActions.remove(.retry)
        }
        actions = resolvedActions
        currentDestination = folders.first { folder in
            folder.threadIDs.contains(proposal.source.effectiveThreadID)
                || folder.threadIDs.contains(proposal.source.rawThreadID)
        }?.title ?? NSLocalizedString("organizer.suggestion.destination.unorganized",
                                     comment: "Current destination when a suggestion source is unorganized")
    }
}

/// Compact, inline review surface. It reuses the existing coordinator, so the
/// queue remains the durable proposal authority while Organize exposes the
/// decision where the user is already working.
internal struct OrganizerSuggestionCardsView: View {
    @ObservedObject internal var coordinator: GraphAutomationCoordinator
    internal let folders: [ThreadFolder]

    @State private var isExpanded = true
    @State private var hiddenIDs: Set<String> = []
    @State private var isShowingMailReview = false

    private var visibleProposals: [GraphAutomationProposal] {
        coordinator.proposals
            .filter { !hiddenIDs.contains($0.id) }
            .filter { proposal in
                proposal.status == .pendingReview
                    || proposal.status == .failed
                    || proposal.status == .recoveryNeeded
                    || (proposal.status == .applied && proposal.mutationDelta != nil)
            }
            .sorted { lhs, rhs in
                if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
    }

    internal var body: some View {
        if !visibleProposals.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(visibleProposals.prefix(6)) { proposal in
                            card(proposal)
                                .frame(width: 246)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.automatic)
            } label: {
                HStack(spacing: 6) {
                    Label(NSLocalizedString("organizer.suggestion.title",
                                            comment: "Inline organizer suggestions title"),
                          systemImage: "sparkles")
                    Spacer(minLength: 4)
                    Text(String(visibleProposals.count))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .accessibilityIdentifier(AccessibilityID.organizerSuggestions)
            .sheet(isPresented: $isShowingMailReview) {
                GraphAutomationQueueSheet(coordinator: coordinator, folders: folders)
            }
        }
    }

    private func card(_ proposal: GraphAutomationProposal) -> some View {
        let presentation = OrganizerSuggestionPresentation(proposal: proposal,
                                                            folders: folders)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text("\(presentation.confidencePercent)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(presentation.rationale)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 2) {
                detailRow(key: "organizer.suggestion.members",
                          value: "\(presentation.memberCount) · \(presentation.sourceTitle)")
                detailRow(key: "organizer.suggestion.current",
                          value: presentation.currentDestination)
                detailRow(key: "organizer.suggestion.proposed",
                          value: presentation.proposedDestination)
                detailRow(key: "organizer.suggestion.evaluated",
                          value: presentation.lastEvaluatedAt.formatted(date: .abbreviated,
                                                                        time: .shortened))
                detailRow(key: "organizer.suggestion.provenance",
                          value: presentation.isReviewOnlyFallback
                            ? NSLocalizedString("organizer.suggestion.review_only",
                                                comment: "Deterministic suggestions require review")
                            : presentation.provenance)
                detailRow(key: "organizer.suggestion.effect",
                          value: NSLocalizedString(presentation.effectCategory.localizationKey,
                                                   comment: "Organization effect category"))
            }
            .font(.caption2)

            actionRow(proposal, presentation: presentation)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DesignTokens.Graph.AppTheme.panelSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.organizerSuggestionRow(proposal.id))
    }

    @ViewBuilder
    private func detailRow(key: String, value: String) -> some View {
        GridRow {
            Text(NSLocalizedString(key, comment: "Organizer suggestion detail label"))
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func actionRow(_ proposal: GraphAutomationProposal,
                           presentation: OrganizerSuggestionPresentation) -> some View {
        HStack(spacing: 5) {
            if presentation.actions.contains(.edit) {
                Menu {
                    ForEach(folders.sorted(by: { $0.title < $1.title })) { folder in
                        Button(folder.title) {
                            Task {
                                await coordinator.changeDestination(proposalID: proposal.id,
                                                                    folderID: folder.id)
                            }
                        }
                    }
                } label: {
                    Label(NSLocalizedString("organizer.suggestion.edit",
                                            comment: "Edit suggestion destination"),
                          systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
            }
            if presentation.actions.contains(.approve) {
                Button {
                    if presentation.effectCategory == .betterMailOnly {
                        Task { await coordinator.approve(ids: [proposal.id]) }
                    } else {
                        isShowingMailReview = true
                    }
                } label: {
                    Text(NSLocalizedString(presentation.effectCategory == .betterMailOnly
                                           ? "organizer.suggestion.approve"
                                           : "organizer.suggestion.review_mail",
                                           comment: "Approve or review a suggestion"))
                }
                .buttonStyle(.borderedProminent)
            }
            if presentation.actions.contains(.reject) {
                Button(NSLocalizedString("organizer.suggestion.reject",
                                         comment: "Reject a suggestion")) {
                    Task { await coordinator.reject(ids: [proposal.id]) }
                }
            }
            if presentation.actions.contains(.retry) {
                Button(NSLocalizedString("organizer.suggestion.retry",
                                         comment: "Retry a suggestion")) {
                    Task { await coordinator.retry(proposal.id) }
                }
            }
            if presentation.actions.contains(.undo) {
                Button(NSLocalizedString("organizer.suggestion.undo",
                                         comment: "Undo an accepted suggestion")) {
                    Task { await coordinator.undo(proposal.id) }
                }
            }
            Spacer(minLength: 0)
            if presentation.actions.contains(.hide) {
                Button {
                    hiddenIDs.insert(proposal.id)
                } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("organizer.suggestion.hide",
                                        comment: "Hide a suggestion card"))
                .accessibilityLabel(NSLocalizedString("organizer.suggestion.hide",
                                                       comment: "Hide a suggestion card"))
            }
        }
        .font(.caption2)
        .controlSize(.mini)
    }
}
