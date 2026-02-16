import SwiftUI

internal struct MailboxSidebarView: View {
    @ObservedObject internal var viewModel: ThreadCanvasViewModel

    private var selectionBinding: Binding<MailboxScope?> {
        Binding(
            get: { viewModel.activeMailboxScope },
            set: { scope in
                guard let scope else { return }
                viewModel.selectMailboxScope(scope)
            }
        )
    }

    internal var body: some View {
        List(selection: selectionBinding) {
            Label(NSLocalizedString("mailbox.sidebar.all_inboxes", comment: "All Inboxes sidebar entry"),
                  systemImage: "tray.full")
                .tag(Optional(MailboxScope.allInboxes))

            ForEach(viewModel.mailboxAccounts) { account in
                Section(account.name) {
                    OutlineGroup(account.folders, children: \.childNodes) { folder in
                        Label(folder.name, systemImage: "folder")
                            .tag(Optional(MailboxScope.mailboxFolder(account: folder.account,
                                                                     path: folder.path)))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottomLeading) {
            if viewModel.isMailboxHierarchyLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(NSLocalizedString("mailbox.sidebar.loading", comment: "Mailbox hierarchy loading status"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            }
        }
        .onAppear {
            if viewModel.mailboxAccounts.isEmpty {
                viewModel.refreshMailboxHierarchy()
            }
        }
    }
}
