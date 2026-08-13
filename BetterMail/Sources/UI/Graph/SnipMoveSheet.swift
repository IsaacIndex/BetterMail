import SwiftUI

internal struct SnipMoveSheet: View {
    internal let request: GraphSnipBatchRequest
    internal let mailboxAccounts: [MailboxAccount]
    @ObservedObject internal var settings: GraphCanvasSettings
    @ObservedObject internal var viewModel: GraphCanvasViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var bulkDestinationPath: String?
    @State private var searchQuery = ""
    @State private var escapeMonitor: Any?

    internal var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            folderSearch
            folderList
            Divider()
            allocationRows
            footer
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 560)
        .accessibilityIdentifier(AccessibilityID.graphSnipAllocationSheet)
        .interactiveDismissDisabled(isMoving)
        .onAppear {
            removeInvalidDrafts()
            installEscapeMonitor()
        }
        .onDisappear(perform: removeEscapeMonitor)
        .onChange(of: mailboxAccounts) { _, _ in removeInvalidDrafts() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("graph.snip.batch.title",
                                   comment: "Batch Snip allocation sheet title"))
                .font(.title3.bold())
            Label(request.accountName, systemImage: "person.crop.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    String.localizedStringWithFormat(
                        NSLocalizedString("graph.snip.batch.account.accessibility",
                                          comment: "Fixed Mail account for a Batch Snip"),
                        request.accountName
                    )
                )
            Text(String.localizedStringWithFormat(
                NSLocalizedString("graph.snip.batch.review_count",
                                  comment: "Threads included in Batch Snip allocation"),
                request.items.count
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var folderSearch: some View {
        HStack(spacing: 10) {
            TextField(NSLocalizedString("graph.snip.search",
                                        comment: "Graph snip mailbox search"),
                      text: $searchQuery)
                .textFieldStyle(.roundedBorder)
            Picker(NSLocalizedString("graph.snip.batch.bulk_destination",
                                     comment: "Bulk Batch Snip destination"),
                   selection: $bulkDestinationPath) {
                Text(NSLocalizedString("graph.snip.batch.choose_folder",
                                       comment: "No Batch Snip folder selected"))
                    .tag(Optional<String>.none)
                ForEach(filteredRows) { row in
                    Text(row.displayName).tag(Optional(row.path))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220)
            .accessibilityIdentifier(AccessibilityID.graphSnipBulkPicker)
            Button(NSLocalizedString("graph.snip.batch.apply_all",
                                     comment: "Apply one Mail folder to every staged thread")) {
                guard let bulkDestinationPath else { return }
                viewModel.applySnipDestinationToAll(bulkDestinationPath)
            }
            .disabled(bulkDestinationPath == nil || isMoving)
            .accessibilityIdentifier(AccessibilityID.graphSnipApplyAll)
        }
    }

    private var folderList: some View {
        Group {
            if filteredRows.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("graph.snip.no_folders",
                                      comment: "Empty graph snip mailbox list"),
                    systemImage: "folder.badge.questionmark"
                )
            } else {
                List(filteredRows, selection: $bulkDestinationPath) { row in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(row.displayName)
                        Spacer()
                        if bulkDestinationPath == row.path {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .tag(Optional(row.path))
                }
            }
        }
        .frame(height: 130)
    }

    private var allocationRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("graph.snip.batch.per_thread",
                                   comment: "Per-thread Batch Snip override section"))
                .font(.headline)
            List(request.items) { item in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.subject.isEmpty
                             ? NSLocalizedString("threadcanvas.subject.placeholder",
                                                 comment: "Missing email subject")
                             : item.subject)
                            .lineLimit(2)
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("graph.snip.batch.message_count",
                                              comment: "Messages in a staged thread"),
                            item.messages.count
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Picker(NSLocalizedString("graph.snip.batch.destination",
                                             comment: "Per-thread Batch Snip destination"),
                           selection: allocationBinding(for: item.threadID)) {
                        Text(NSLocalizedString("graph.snip.batch.choose_folder",
                                               comment: "No Batch Snip folder selected"))
                            .tag(Optional<String>.none)
                        ForEach(allRows) { row in
                            Text(row.displayName).tag(Optional(row.path))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240)
                    .disabled(isMoving)
                    .accessibilityLabel(
                        String.localizedStringWithFormat(
                            NSLocalizedString("graph.snip.batch.destination.accessibility",
                                              comment: "VoiceOver destination picker for a staged thread"),
                            item.subject
                        )
                    )
                }
                .padding(.vertical, 3)
            }
        }
        .frame(minHeight: 190)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isMoving {
                ProgressView(value: Double(viewModel.snipMoveCompletedCount),
                             total: Double(max(viewModel.snipMoveTotalCount, 1)))
                    .frame(width: 180)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("graph.snip.batch.progress",
                                      comment: "Batch Snip move progress"),
                    viewModel.snipMoveCompletedCount,
                    viewModel.snipMoveTotalCount
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(NSLocalizedString("graph.snip.batch.discard",
                                     comment: "Discard every staged Snip"), role: .destructive) {
                viewModel.discardSnipSession()
                dismiss()
            }
            .disabled(isMoving)
            .accessibilityIdentifier(AccessibilityID.graphSnipDiscardSession)
            Button(NSLocalizedString("graph.snip.batch.back",
                                     comment: "Return to the graph with Snips preserved")) {
                dismiss()
            }
            .disabled(isMoving)
            Button(NSLocalizedString("graph.snip.batch.move",
                                     comment: "Run every Batch Snip allocation")) {
                Task { await viewModel.confirmSnipBatch(request: request) }
            }
            .disabled(!canMove || isMoving)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(AccessibilityID.graphSnipMoveBatch)
        }
    }

    private var isMoving: Bool {
        viewModel.snipPhase == .moving
    }

    private var canMove: Bool {
        viewModel.canConfirmSnipAllocations && Self.allocationsAreValid(
            items: request.items,
            allocations: viewModel.snipAllocations,
            accountName: request.accountName,
            validPaths: Set(allRows.map(\.path))
        )
    }

    internal static func allocationsAreValid(
        items: [GraphSnipItem],
        allocations: [String: GraphSnipAllocation],
        accountName: String,
        validPaths: Set<String>
    ) -> Bool {
        let normalizedAccount = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !items.isEmpty && items.allSatisfy { item in
            guard let allocation = allocations[item.threadID] else { return false }
            return allocation.destinationAccountName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedAccount) == .orderedSame &&
                validPaths.contains(allocation.destinationMailboxPath)
        }
    }

    private var selectedAccount: MailboxAccount? {
        let target = request.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return mailboxAccounts.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(target) == .orderedSame
        }
    }

    private var allRows: [FolderRow] {
        Self.flattenRows(nodes: selectedAccount?.folders ?? [])
    }

    private var filteredRows: [FolderRow] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allRows }
        return allRows.filter {
            $0.path.lowercased().contains(query) || $0.name.lowercased().contains(query)
        }
    }

    private func allocationBinding(for threadID: String) -> Binding<String?> {
        Binding {
            viewModel.snipAllocations[threadID]?.destinationMailboxPath
        } set: { path in
            viewModel.setSnipAllocation(threadID: threadID, destinationPath: path)
        }
    }

    private func removeInvalidDrafts() {
        let validPaths = Set(allRows.map(\.path))
        if let bulkDestinationPath, !validPaths.contains(bulkDestinationPath) {
            self.bulkDestinationPath = nil
        }
        for item in request.items {
            if let path = viewModel.snipAllocations[item.threadID]?.destinationMailboxPath,
               !validPaths.contains(path) {
                viewModel.setSnipAllocation(threadID: item.threadID, destinationPath: nil)
            }
        }
    }

    /// The search field can consume SwiftUI's cancel command before the sheet
    /// receives it. Keep this AppKit boundary local to the presented sheet so
    /// Escape reliably means Back to Graph and never reaches the canvas.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            guard !isMoving else { return nil }
            dismiss()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    private static func flattenRows(nodes: [MailboxFolderNode], depth: Int = 0) -> [FolderRow] {
        nodes.flatMap { node in
            [FolderRow(path: node.path, name: node.name, depth: depth)] +
                flattenRows(nodes: node.children, depth: depth + 1)
        }
    }

    private struct FolderRow: Identifiable, Hashable {
        let path: String
        let name: String
        let depth: Int

        var id: String { path }
        var displayName: String { String(repeating: "  ", count: depth) + name }
    }
}
