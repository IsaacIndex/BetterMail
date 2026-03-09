import SwiftUI
import UniformTypeIdentifiers

internal struct MailboxSidebarView: View {
    fileprivate struct VisibleFolderRow: Identifiable {
        let node: MailboxFolderNode
        let depth: Int

        var id: String { node.id }
    }

    fileprivate enum DropLinePosition {
        case before
        case after
    }

    fileprivate struct DropIndicator {
        let folderID: String
        let position: DropLinePosition
    }

    @ObservedObject internal var viewModel: ThreadCanvasViewModel
    @State private var selectedScope: MailboxScope?
    @State private var activeDropIndicator: DropIndicator?
    @State private var activeDraggedFolderID: String?
    @State private var rowFrameByFolderID: [String: CGRect] = [:]
    @State private var expandedFolderIDs: Set<String> = []

    internal var body: some View {
        List(selection: $selectedScope) {
            sidebarRow(scope: .allEmails,
                       title: NSLocalizedString("mailbox.sidebar.all_emails",
                                                comment: "All Emails sidebar entry"),
                       systemImage: "tray.2")
            sidebarRow(scope: .allFolders,
                       title: NSLocalizedString("mailbox.sidebar.all_folders",
                                                comment: "All Folders sidebar entry"),
                       systemImage: "folder.badge.gearshape")
            sidebarRow(scope: .allInboxes,
                       title: NSLocalizedString("mailbox.sidebar.all_inboxes",
                                                comment: "All Inboxes sidebar entry"),
                       systemImage: "tray.full")

            ForEach(viewModel.mailboxAccounts) { account in
                Section(account.name) {
                    ForEach(visibleFolderRows(in: account.folders)) { row in
                        folderSidebarRow(folder: row.node, depth: row.depth)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            selectedScope = viewModel.activeMailboxScope
        }
        .onChange(of: selectedScope) { _, newScope in
            guard let newScope else { return }
            if viewModel.activeMailboxScope != newScope {
                viewModel.selectMailboxScope(newScope)
            }
        }
        .onChange(of: viewModel.activeMailboxScope) { _, newScope in
            if selectedScope != newScope {
                selectedScope = newScope
            }
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.isMailboxHierarchyLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(NSLocalizedString("mailbox.sidebar.loading", comment: "Mailbox hierarchy loading status"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if activeDraggedFolderID != nil {
                    Label(NSLocalizedString("mailbox.sidebar.reorder.hint",
                                            comment: "Hint shown while dragging a mailbox folder to reorder"),
                          systemImage: "arrow.up.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { _ in
            activeDropIndicator = nil
            activeDraggedFolderID = nil
            return false
        }
        .onPreferenceChange(FolderRowFramePreferenceKey.self) { rowFrameByFolderID = $0 }
        .onChange(of: viewModel.mailboxAccounts) { _, newAccounts in
            let validIDs = Set(MailboxHierarchyBuilder.folderIDs(in: newAccounts))
            expandedFolderIDs.formIntersection(validIDs)
        }
    }

    private func sidebarRow(scope: MailboxScope, title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tag(scope)
    }

    private func folderSidebarRow(folder: MailboxFolderNode, depth: Int) -> some View {
        let isExpanded = expandedFolderIDs.contains(folder.id)
        let hasChildren = !folder.children.isEmpty

        return HStack(spacing: 6) {
            Group {
                if hasChildren {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10, height: 10)
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasChildren else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    if isExpanded {
                        expandedFolderIDs.remove(folder.id)
                    } else {
                        expandedFolderIDs.insert(folder.id)
                    }
                }
            }

            sidebarRow(scope: .mailboxFolder(account: folder.account, path: folder.path),
                       title: folder.name,
                       systemImage: "folder")
        }
            .padding(.leading, CGFloat(depth) * 14)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(activeDropIndicator?.folderID == folder.id ? Color.accentColor.opacity(0.06) : Color.clear)
            }
            .overlay(alignment: .topLeading) {
                if activeDropIndicator?.folderID == folder.id, activeDropIndicator?.position == .before {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.leading, 4)
                        .padding(.trailing, 4)
                        .offset(y: beforeLineOffsetY(for: folder))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if activeDropIndicator?.folderID == folder.id, activeDropIndicator?.position == .after {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.leading, 4)
                        .padding(.trailing, 4)
                        .offset(y: afterLineOffsetY(for: folder))
                        .allowsHitTesting(false)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: FolderRowFramePreferenceKey.self,
                                           value: [folder.id: proxy.frame(in: .global)])
                }
            }
            .onDrag {
                activeDraggedFolderID = folder.id
                return NSItemProvider(object: folder.id as NSString)
            } preview: {
                folderDragPreview(title: folder.name)
            }
            .onDrop(of: [UTType.plainText.identifier],
                    delegate: FolderReorderDropDelegate(targetFolder: folder,
                                                        viewModel: viewModel,
                                                        activeDropIndicator: $activeDropIndicator,
                                                        activeDraggedFolderID: $activeDraggedFolderID))
            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity))
    }

    private func visibleFolderRows(in nodes: [MailboxFolderNode], depth: Int = 0) -> [VisibleFolderRow] {
        var rows: [VisibleFolderRow] = []
        rows.reserveCapacity(nodes.count)
        for node in nodes {
            rows.append(VisibleFolderRow(node: node, depth: depth))
            if expandedFolderIDs.contains(node.id) {
                rows.append(contentsOf: visibleFolderRows(in: node.children, depth: depth + 1))
            }
        }
        return rows
    }

    private func folderDragPreview(title: String) -> some View {
        Label(title, systemImage: "folder.fill")
            .font(.body.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    private func beforeLineOffsetY(for folder: MailboxFolderNode) -> CGFloat {
        guard let currentFrame = rowFrameByFolderID[folder.id] else { return 0 }
        let neighbors = viewModel.mailboxNeighborFolderIDs(account: folder.account,
                                                           path: folder.path,
                                                           parentPath: folder.parentPath)
        guard let previousID = neighbors.previousID,
              let previousFrame = rowFrameByFolderID[previousID] else {
            return 0
        }
        let midpointY = (previousFrame.maxY + currentFrame.minY) / 2
        return midpointY - currentFrame.minY
    }

    private func afterLineOffsetY(for folder: MailboxFolderNode) -> CGFloat {
        guard let currentFrame = rowFrameByFolderID[folder.id] else { return 0 }
        let neighbors = viewModel.mailboxNeighborFolderIDs(account: folder.account,
                                                           path: folder.path,
                                                           parentPath: folder.parentPath)
        guard let nextID = neighbors.nextID,
              let nextFrame = rowFrameByFolderID[nextID] else {
            return 0
        }
        let midpointY = (currentFrame.maxY + nextFrame.minY) / 2
        return midpointY - currentFrame.maxY
    }
}

private struct FolderRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct FolderReorderDropDelegate: DropDelegate {
    let targetFolder: MailboxFolderNode
    let viewModel: ThreadCanvasViewModel
    @Binding var activeDropIndicator: MailboxSidebarView.DropIndicator?
    @Binding var activeDraggedFolderID: String?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropEntered(info: DropInfo) {
        updateDropIndicator(for: info)
    }

    func dropExited(info: DropInfo) {
        if activeDropIndicator?.folderID == targetFolder.id {
            activeDropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropIndicator(for: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            if activeDropIndicator?.folderID == targetFolder.id {
                activeDropIndicator = nil
            }
            activeDraggedFolderID = nil
        }
        guard let sourceID = activeDraggedFolderID,
              viewModel.canReorderMailboxFolder(sourceID: sourceID,
                                                targetAccount: targetFolder.account,
                                                targetParentPath: targetFolder.parentPath),
              let indicator = activeDropIndicator,
              indicator.folderID == targetFolder.id else {
            return false
        }
        let placement: ThreadCanvasViewModel.MailboxFolderDropPlacement = indicator.position == .before ? .before : .after
        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.reorderMailboxFolder(sourceID: sourceID,
                                           targetAccount: targetFolder.account,
                                           targetPath: targetFolder.path,
                                           targetParentPath: targetFolder.parentPath,
                                           placement: placement)
        }
        return true
    }

    private func updateDropIndicator(for info: DropInfo) {
        guard let sourceID = activeDraggedFolderID,
              viewModel.canReorderMailboxFolder(sourceID: sourceID,
                                                targetAccount: targetFolder.account,
                                                targetParentPath: targetFolder.parentPath) else {
            activeDropIndicator = nil
            return
        }
        let position: MailboxSidebarView.DropLinePosition = info.location.y > 12 ? .after : .before
        activeDropIndicator = MailboxSidebarView.DropIndicator(folderID: targetFolder.id,
                                                               position: position)
    }
}
