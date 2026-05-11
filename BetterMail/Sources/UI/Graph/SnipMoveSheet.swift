import SwiftUI

internal struct SnipMoveSheet: View {
    internal let request: SnipMoveRequest
    internal let mailboxAccounts: [MailboxAccount]
    @ObservedObject internal var settings: GraphCanvasSettings
    internal let onConfirm: (String, String?) -> Void
    internal let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccount = ""
    @State private var selectedPath = ""
    @State private var searchQuery = ""

    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("graph.snip.title", comment: "Graph snip sheet title"))
                .font(.title3.bold())
            Text(request.thread.subject)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Picker(NSLocalizedString("graph.snip.account", comment: "Graph snip account picker"),
                   selection: $selectedAccount) {
                ForEach(mailboxAccounts.map(\.name), id: \.self) { account in
                    Text(account).tag(account)
                }
            }
            .pickerStyle(.menu)
            TextField(NSLocalizedString("graph.snip.search", comment: "Graph snip mailbox search"),
                      text: $searchQuery)
                .textFieldStyle(.roundedBorder)
            List(filteredRows, id: \.id) { row in
                Button {
                    selectedPath = row.path
                } label: {
                    HStack {
                        Text(String(repeating: "  ", count: row.depth) + row.name)
                        Spacer()
                        if selectedPath == row.path {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button(NSLocalizedString("graph.snip.cancel", comment: "Cancel graph snip")) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("graph.snip.move", comment: "Confirm graph snip move")) {
                    onConfirm(selectedPath, selectedAccount.isEmpty ? nil : selectedAccount)
                    dismiss()
                }
                .disabled(selectedPath.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear(perform: selectDefaults)
        .onChange(of: selectedAccount) { _, _ in
            selectedPath = filteredRows.first?.path ?? ""
        }
    }

    private var selectedMailboxAccount: MailboxAccount? {
        mailboxAccounts.first { $0.name == selectedAccount } ?? mailboxAccounts.first
    }

    private var rows: [FolderRow] {
        guard let selectedMailboxAccount else { return [] }
        let parent = settings.snipParentMailboxPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodes = parent.isEmpty
            ? selectedMailboxAccount.folders
            : MailboxHierarchyBuilder.filterFolderTree(selectedMailboxAccount.folders, query: parent)
        return Self.flattenRows(nodes: nodes)
    }

    private var filteredRows: [FolderRow] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.path.lowercased().contains(query) || $0.name.lowercased().contains(query) }
    }

    private func selectDefaults() {
        selectedAccount = request.thread.accountName.isEmpty ? (mailboxAccounts.first?.name ?? "") : request.thread.accountName
        selectedPath = filteredRows.first?.path ?? ""
    }

    private static func flattenRows(nodes: [MailboxFolderNode], depth: Int = 0) -> [FolderRow] {
        nodes.flatMap { node in
            [FolderRow(path: node.path, name: node.name, depth: depth)] +
            flattenRows(nodes: node.children, depth: depth + 1)
        }
    }

    private struct FolderRow: Identifiable {
        let path: String
        let name: String
        let depth: Int

        var id: String { path }
    }
}
