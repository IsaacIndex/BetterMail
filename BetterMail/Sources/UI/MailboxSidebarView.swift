import SwiftUI

internal struct MailboxSidebarView: View {
    @ObservedObject internal var viewModel: ThreadCanvasViewModel
    private var selectedScope: Binding<MailboxScope?> {
        Binding(
            get: { viewModel.activeMailboxScope },
            set: { scope in
                guard let scope else { return }
                viewModel.selectMailboxScope(scope)
            }
        )
    }

    internal var body: some View {
        List(selection: selectedScope) {
            sidebarRow(scope: .allEmails,
                       title: NSLocalizedString("mailbox.sidebar.all_emails",
                                                comment: "All Emails sidebar entry"),
                       systemImage: "tray.2")
            sidebarRow(scope: .allInboxes,
                       title: NSLocalizedString("mailbox.sidebar.all_inboxes",
                                                comment: "All Inboxes sidebar entry"),
                       systemImage: "tray.full")

            ForEach(viewModel.mailboxAccounts) { account in
                Section(account.name) {
                    OutlineGroup(account.folders, children: \.childNodes) { folder in
                        sidebarRow(scope: .mailboxFolder(account: folder.account, path: folder.path),
                                   title: folder.name,
                                   systemImage: "folder")
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
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            viewModel.refreshMailboxHierarchy()
        }
    }

    private func sidebarRow(scope: MailboxScope, title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tag(scope)
    }
}
