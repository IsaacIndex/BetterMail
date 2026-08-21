import SwiftUI

internal struct GraphAutomationQueueSheet: View {
    @ObservedObject internal var coordinator: GraphAutomationCoordinator
    internal let folders: [ThreadFolder]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs = Set<String>()

    internal var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if coordinator.proposals.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("graph.automation.empty.title", comment: "Empty automation queue title"),
                    systemImage: "checkmark.circle",
                    description: Text(NSLocalizedString("graph.automation.empty.detail",
                                                        comment: "Empty automation queue detail"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(destinationGroups, id: \.id) { group in
                            destinationSection(group)
                        }
                    }
                    .padding(18)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 640)
        .background(DesignTokens.Graph.AppTheme.background)
        .accessibilityIdentifier(AccessibilityID.graphAutomationSheet)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(NSLocalizedString("graph.automation.title", comment: "Graph automation queue title"))
                    .font(.title2.bold())
                Text(coordinator.providerStatusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if coordinator.isEvaluating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(NSLocalizedString("graph.automation.evaluating",
                                                          comment: "Automation is evaluating mail"))
            }
            Button(NSLocalizedString("graph.automation.close", comment: "Close automation queue")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(String.localizedStringWithFormat(
                NSLocalizedString("graph.automation.selected_count",
                                  comment: "Number of selected automation rows"),
                selectedPendingIDs.count
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Spacer()
            Button(NSLocalizedString("graph.automation.reject_selected",
                                     comment: "Reject selected automation proposals")) {
                let ids = selectedPendingIDs
                Task {
                    await coordinator.reject(ids: ids)
                    selectedIDs.subtract(ids)
                }
            }
            .disabled(selectedPendingIDs.isEmpty)
            .accessibilityIdentifier(AccessibilityID.graphAutomationRejectSelected)
            Button(NSLocalizedString("graph.automation.approve_selected",
                                     comment: "Approve selected automation proposals")) {
                let ids = selectedPendingIDs
                Task {
                    await coordinator.approve(ids: ids)
                    selectedIDs.subtract(ids)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedPendingIDs.isEmpty)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(AccessibilityID.graphAutomationApproveSelected)
        }
        .padding(14)
    }

    private func destinationSection(_ group: DestinationGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(group.title, systemImage: group.folderID == nil ? "point.3.connected.trianglepath.dotted" : "folder.fill")
                    .font(.headline)
                Spacer()
                let pending = group.proposals.filter { $0.status == .pendingReview }
                if let folderID = group.folderID, !pending.isEmpty {
                    Button(NSLocalizedString("graph.automation.approve_all_destination",
                                             comment: "Approve every proposal for one destination")) {
                        Task { await coordinator.approveAll(destinationFolderID: folderID) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.graphAutomationApproveAll(folderID))
                }
            }
            ForEach(StatusSection.allCases) { statusSection in
                let rows = group.proposals.filter { statusSection.contains($0.status) }
                if !rows.isEmpty {
                    Text(statusSection.localizedTitle)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(rows) { proposal in
                        proposalRow(proposal)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DesignTokens.Graph.AppTheme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
    }

    private func proposalRow(_ proposal: GraphAutomationProposal) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if proposal.status == .pendingReview {
                Toggle("", isOn: selectionBinding(for: proposal.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(String.localizedStringWithFormat(
                        NSLocalizedString("graph.automation.include_source",
                                          comment: "Include source in automation batch"),
                        proposal.source.subject
                    ))
            } else {
                Image(systemName: statusIcon(proposal.status))
                    .foregroundStyle(statusColor(proposal.status))
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(proposal.actionLabel)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f%%", proposal.score * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String.localizedStringWithFormat(
                            NSLocalizedString("graph.automation.confidence_value",
                                              comment: "Automation confidence value"),
                            Int((proposal.score * 100).rounded())
                        ))
                }
                Text(proposal.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Label(proposal.action.localizedTitle,
                          systemImage: proposal.action == .attachToThread ? "link" : "folder.badge.plus")
                    Text(proposal.confidenceBand)
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("graph.automation.message_count",
                                          comment: "Message count in an automation proposal"),
                        proposal.source.messageCount
                    ))
                    if proposal.steps.contains(where: { if case .mailbox = $0 { return true }; return false }) {
                        Label(NSLocalizedString("graph.automation.mail_effect.move",
                                                comment: "Automation will move Mail messages"),
                              systemImage: "tray.and.arrow.down")
                    } else {
                        Label(NSLocalizedString("graph.automation.mail_effect.none",
                                                comment: "Automation will not move Mail messages"),
                              systemImage: "tray")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                if !proposal.sharedAnchors.isEmpty {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("graph.automation.shared_anchors",
                                          comment: "Shared evidence anchors for an automation proposal"),
                        proposal.sharedAnchors.joined(separator: ", ")
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let error = proposal.lastError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                if proposal.status == .pendingReview {
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
                        Label(NSLocalizedString("graph.automation.edit_destination",
                                                comment: "Edit automation destination"),
                              systemImage: "arrow.triangle.branch")
                    }
                    .menuStyle(.borderlessButton)
                }
                if proposal.status == .failed || proposal.status == .recoveryNeeded {
                    Button(NSLocalizedString("graph.automation.retry", comment: "Retry automation")) {
                        Task { await coordinator.retry(proposal.id) }
                    }
                }
                if proposal.mutationDelta != nil &&
                    [.applied, .failed, .recoveryNeeded].contains(proposal.status) {
                    Button(NSLocalizedString("graph.automation.undo", comment: "Undo automation")) {
                        Task { await coordinator.undo(proposal.id) }
                    }
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignTokens.Graph.AppTheme.panelSecondary)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.graphAutomationRow(proposal.id))
    }

    private var selectedPendingIDs: Set<String> {
        selectedIDs.intersection(coordinator.pendingProposals.map(\.id))
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(get: { selectedIDs.contains(id) }, set: { isSelected in
            if isSelected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        })
    }

    private var destinationGroups: [DestinationGroup] {
        Dictionary(grouping: coordinator.proposals) { proposal in
            proposal.target.folderID ?? "thread:\(proposal.target.threadID ?? "none")"
        }.map { key, proposals in
            let folderTitle = proposals.first?.target.folderID.flatMap { folderID in
                folders.first(where: { $0.id == folderID })?.title
            }
            return DestinationGroup(id: key,
                                    folderID: proposals.first?.target.folderID,
                                    title: folderTitle ?? proposals.first?.target.title ?? key,
                                    proposals: proposals)
        }.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func statusIcon(_ status: GraphAutomationExecutionStatus) -> String {
        switch status {
        case .applied: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .recoveryNeeded: "cross.case.fill"
        case .rejected, .stale: "xmark.circle"
        case .undone: "arrow.uturn.backward.circle"
        case .applying, .undoing: "hourglass"
        case .pendingReview: "circle"
        }
    }

    private func statusColor(_ status: GraphAutomationExecutionStatus) -> Color {
        switch status {
        case .applied: .green
        case .failed, .recoveryNeeded: .orange
        case .rejected, .stale, .undone: .secondary
        case .applying, .undoing, .pendingReview: .accentColor
        }
    }
}

private struct DestinationGroup: Identifiable {
    let id: String
    let folderID: String?
    let title: String
    let proposals: [GraphAutomationProposal]
}

private enum StatusSection: String, CaseIterable, Identifiable {
    case pending
    case applied
    case failed
    case recovery

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .pending:
            return NSLocalizedString("graph.automation.section.pending", comment: "Pending automation section")
        case .applied:
            return NSLocalizedString("graph.automation.section.applied", comment: "Applied automation section")
        case .failed:
            return NSLocalizedString("graph.automation.section.failed", comment: "Failed automation section")
        case .recovery:
            return NSLocalizedString("graph.automation.section.recovery", comment: "Recovery automation section")
        }
    }

    func contains(_ status: GraphAutomationExecutionStatus) -> Bool {
        switch self {
        case .pending: status == .pendingReview
        case .applied: [.applied, .applying].contains(status)
        case .failed: status == .failed
        case .recovery: [.recoveryNeeded, .undoing, .undone, .rejected, .stale].contains(status)
        }
    }
}
