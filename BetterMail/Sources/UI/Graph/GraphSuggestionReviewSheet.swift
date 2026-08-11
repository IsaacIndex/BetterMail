import Combine
import SwiftUI

@MainActor
internal final class GraphSuggestionReviewViewModel: ObservableObject {
    internal typealias ConfirmFolder = @MainActor (String, Set<String>) async throws -> Void
    internal typealias ImpactProvider = @MainActor (Set<String>) -> GraphFolderSuggestionImpact

    @Published internal var folderName: String
    @Published internal var selectedThreadIDs: Set<String>
    @Published internal private(set) var isSubmitting = false
    @Published internal private(set) var errorMessage: String?
    @Published internal var isImpactConfirmationPresented = false
    @Published internal private(set) var pendingImpact: GraphFolderSuggestionImpact = .none
    @Published internal private(set) var didCreateFolder = false

    internal let normalizedTopic: String
    internal let supportingReason: String
    internal let members: [GraphTopicMember]

    private let impactProvider: ImpactProvider
    private let confirmFolder: ConfirmFolder
    private var pendingFolderName: String?
    private var pendingThreadIDs: Set<String>?

    internal init(grouping: GraphGrouping,
                  impactProvider: @escaping ImpactProvider,
                  confirmFolder: @escaping ConfirmFolder) {
        folderName = grouping.title
        normalizedTopic = grouping.normalizedTopic ?? GraphTopicNormalizer.normalize(grouping.title)
        supportingReason = grouping.supportingReason ?? ""
        members = grouping.reviewMembers
        selectedThreadIDs = Set(grouping.reviewMembers.map(\.rawThreadID))
        self.impactProvider = impactProvider
        self.confirmFolder = confirmFolder
    }

    internal var isCreateEnabled: Bool {
        !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            selectedThreadIDs.count >= GraphTopicRanker.minimumDistinctThreadCount &&
            !isSubmitting
    }

    internal var selectedImpact: GraphFolderSuggestionImpact {
        impactProvider(selectedThreadIDs)
    }

    internal func isSelected(_ member: GraphTopicMember) -> Bool {
        selectedThreadIDs.contains(member.rawThreadID)
    }

    internal func setSelected(_ isSelected: Bool, member: GraphTopicMember) {
        if isSelected {
            selectedThreadIDs.insert(member.rawThreadID)
        } else {
            selectedThreadIDs.remove(member.rawThreadID)
        }
        errorMessage = nil
    }

    internal func requestCreate() async {
        guard isCreateEnabled else { return }
        let impact = selectedImpact
        if impact.requiresConfirmation {
            pendingFolderName = folderName
            pendingThreadIDs = selectedThreadIDs
            pendingImpact = impact
            isImpactConfirmationPresented = true
            return
        }
        await submit(folderName: folderName, threadIDs: selectedThreadIDs)
    }

    internal func confirmExistingFolderImpact() async {
        guard let pendingFolderName, let pendingThreadIDs else { return }
        isImpactConfirmationPresented = false
        clearPendingConfirmation(keepImpact: true)
        await submit(folderName: pendingFolderName, threadIDs: pendingThreadIDs)
    }

    internal func cancelExistingFolderImpact() {
        isImpactConfirmationPresented = false
        clearPendingConfirmation(keepImpact: false)
    }

    private func submit(folderName: String, threadIDs: Set<String>) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try await confirmFolder(folderName, threadIDs)
            didCreateFolder = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }

    private func clearPendingConfirmation(keepImpact: Bool) {
        pendingFolderName = nil
        pendingThreadIDs = nil
        if !keepImpact {
            pendingImpact = .none
        }
    }
}

internal struct GraphSuggestionReviewSheet: View {
    @StateObject private var viewModel: GraphSuggestionReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFolderNameFocused: Bool

    private let onNotThisGroup: () -> Void
    private let onHideTopic: () -> Void
    private let onCreated: () -> Void

    internal init(grouping: GraphGrouping,
                  impactProvider: @escaping GraphSuggestionReviewViewModel.ImpactProvider,
                  confirmFolder: @escaping GraphSuggestionReviewViewModel.ConfirmFolder,
                  onNotThisGroup: @escaping () -> Void,
                  onHideTopic: @escaping () -> Void,
                  onCreated: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: GraphSuggestionReviewViewModel(
            grouping: grouping,
            impactProvider: impactProvider,
            confirmFolder: confirmFolder
        ))
        self.onNotThisGroup = onNotThisGroup
        self.onHideTopic = onHideTopic
        self.onCreated = onCreated
    }

    internal var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                nameSection
                reasonSection
                membersSection
                if viewModel.selectedImpact.requiresConfirmation {
                    impactDisclosure(viewModel.selectedImpact)
                }
                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(AccessibilityID.graphSuggestionReviewError)
                }
                actionRow
            }
            .padding(20)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 600)
        .background(DesignTokens.Graph.AppTheme.background)
        .onAppear { isFolderNameFocused = true }
        .onChange(of: viewModel.didCreateFolder) { _, didCreate in
            guard didCreate else { return }
            onCreated()
            dismiss()
        }
        .alert(NSLocalizedString("graph.group.review.impact.confirm.title",
                                 comment: "Confirm moving existing folder members"),
               isPresented: $viewModel.isImpactConfirmationPresented) {
            Button(NSLocalizedString("graph.group.review.cancel", comment: "Cancel graph topic review"),
                   role: .cancel) {
                viewModel.cancelExistingFolderImpact()
            }
            Button(NSLocalizedString("graph.group.review.impact.confirm.action",
                                     comment: "Confirm moving threads and creating folder"),
                   role: .destructive) {
                Task { await viewModel.confirmExistingFolderImpact() }
            }
        } message: {
            Text(impactConfirmationMessage(viewModel.pendingImpact))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(NSLocalizedString("graph.group.review.title",
                                    comment: "Graph topic review sheet title"),
                  systemImage: "sparkles")
                .font(.title2.bold())
            Text(NSLocalizedString("graph.group.review.local_preference_note",
                                   comment: "Local topic preference explanation"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("graph.group.review.name",
                                   comment: "Proposed graph folder name label"))
                .font(.headline)
            TextField(NSLocalizedString("graph.group.review.name.placeholder",
                                        comment: "Proposed graph folder name placeholder"),
                      text: $viewModel.folderName)
                .textFieldStyle(.roundedBorder)
                .focused($isFolderNameFocused)
                .accessibilityIdentifier(AccessibilityID.graphSuggestionReviewName)
        }
    }

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("graph.group.review.why",
                                   comment: "Why a graph topic was suggested heading"))
                .font(.headline)
            Text(viewModel.supportingReason.isEmpty
                 ? String.localizedStringWithFormat(
                    NSLocalizedString("graph.group.reason.fallback",
                                      comment: "Fallback explanation for a graph topic suggestion"),
                    viewModel.folderName
                 )
                 : viewModel.supportingReason)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.graphSuggestionReviewReason)
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("graph.group.review.members",
                                       comment: "Graph topic review members heading"))
                    .font(.headline)
                Spacer()
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("graph.group.review.selected_count",
                                      comment: "Selected graph topic member count"),
                    viewModel.selectedThreadIDs.count,
                    viewModel.members.count
                ))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.members) { member in
                        Toggle(isOn: Binding(
                            get: { viewModel.isSelected(member) },
                            set: { viewModel.setSelected($0, member: member) }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(member.fullTitle)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let folderTitle = member.existingFolderTitle {
                                    Text(String.localizedStringWithFormat(
                                        NSLocalizedString("graph.group.review.current_folder",
                                                          comment: "Existing folder for a graph topic member"),
                                        folderTitle
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(String.localizedStringWithFormat(
                            NSLocalizedString("graph.group.review.member.accessibility",
                                              comment: "Graph topic member selection accessibility label"),
                            member.fullTitle
                        ))
                    }
                }
                .padding(12)
            }
            .frame(minHeight: 160, maxHeight: 260)
            .background(DesignTokens.Graph.AppTheme.panel,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
            )
        }
        .accessibilityIdentifier(AccessibilityID.graphSuggestionReviewMembers)
    }

    private func impactDisclosure(_ impact: GraphFolderSuggestionImpact) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(NSLocalizedString("graph.group.review.impact.title",
                                    comment: "Existing folder impact heading"),
                  systemImage: "arrow.triangle.branch")
                .font(.headline)
            Text(impactSummary(impact))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(impact.affectedFolders) { folder in
                Text(String.localizedStringWithFormat(
                    NSLocalizedString(folder.willBeRemoved
                                      ? "graph.group.review.impact.folder_removed"
                                      : "graph.group.review.impact.folder_moved",
                                      comment: "Existing folder impact detail"),
                    folder.title,
                    folder.movedThreadCount
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.graphSuggestionReviewImpact)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(NSLocalizedString("graph.group.not_this_group",
                                     comment: "Reject this exact graph topic group")) {
                onNotThisGroup()
                dismiss()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.graphSuggestionReviewNotThisGroup)
            Button(NSLocalizedString("graph.group.hide_topic",
                                     comment: "Hide a graph topic across member changes")) {
                onHideTopic()
                dismiss()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.graphSuggestionReviewHideTopic)
            Spacer()
            Button(NSLocalizedString("graph.group.review.cancel", comment: "Cancel graph topic review")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier(AccessibilityID.graphSuggestionReviewCancel)
            Button {
                Task { await viewModel.requestCreate() }
            } label: {
                if viewModel.isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(NSLocalizedString("graph.group.review.create",
                                           comment: "Create reviewed graph topic folder"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.isCreateEnabled)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(AccessibilityID.graphSuggestionReviewCreate)
        }
    }

    private func impactSummary(_ impact: GraphFolderSuggestionImpact) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("graph.group.review.impact.summary",
                              comment: "Summary of existing folder mutations"),
            impact.movedThreadCount,
            impact.affectedFolders.count,
            impact.removedFolderCount
        )
    }

    private func impactConfirmationMessage(_ impact: GraphFolderSuggestionImpact) -> String {
        let folderNames = impact.affectedFolders.map(\.title).joined(separator: ", ")
        return String.localizedStringWithFormat(
            NSLocalizedString("graph.group.review.impact.confirm.message",
                              comment: "Confirmation message before moving existing folder members"),
            impact.movedThreadCount,
            folderNames,
            impact.removedFolderCount
        )
    }
}
