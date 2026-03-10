import AppKit
import SwiftUI

internal struct ThreadListView: View {
    @ObservedObject internal var viewModel: ThreadCanvasViewModel
    @ObservedObject internal var settings: AutoRefreshSettings
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var navHeight: CGFloat = 96
    @State private var isShowingBackfillConfirmation = false
    @State private var backfillStartDate = Date()
    @State private var backfillEndDate = Date()
    @State private var backfillLimit: Int = 10
    @State private var isInspectorVisible = false
    @State private var isShowingMailboxMoveSheet = false

    private let navCornerRadius: CGFloat = 18
    private let navHorizontalPadding: CGFloat = 16
    private let navTopPadding: CGFloat = 12
    private let navBottomSpacing: CGFloat = 12
    private let navCanvasSpacing: CGFloat = 6
    private let inspectorWidth: CGFloat = 320

    internal var body: some View {
        content
            .frame(minWidth: 480, minHeight: 400)
            .task {
                viewModel.start()
            }
            .onAppear {
                isInspectorVisible = viewModel.selectedNodeID != nil || viewModel.selectedFolderID != nil
            }
            .onChange(of: viewModel.selectedNodeID) { _, newValue in
                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                    isInspectorVisible = newValue != nil || viewModel.selectedFolderID != nil
                }
            }
            .onChange(of: viewModel.selectedFolderID) { _, newValue in
                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                    isInspectorVisible = newValue != nil || viewModel.selectedNodeID != nil
                }
            }
            .onChange(of: settings.isEnabled) { _, _ in
                viewModel.applyAutoRefreshSettings()
            }
            .onChange(of: settings.interval) { _, _ in
                viewModel.applyAutoRefreshSettings()
            }
            .sheet(isPresented: $isShowingBackfillConfirmation) {
                BackfillConfirmationSheet(
                    startDate: $backfillStartDate,
                    endDate: $backfillEndDate,
                    limit: $backfillLimit,
                    intervalDescription: backfillIntervalDescription ?? "",
                    onConfirm: confirmBackfillWithOverrides,
                    onCancel: { isShowingBackfillConfirmation = false }
                )
                .frame(minWidth: 360)
            }
            .sheet(isPresented: $isShowingMailboxMoveSheet) {
                MailboxFolderMoveSheet(viewModel: viewModel)
                    .frame(minWidth: 440, minHeight: 390)
            }
    }

    private var content: some View {
        ZStack(alignment: .top) {
            GlassWindowBackground()
                .ignoresSafeArea()
            glassLayeredContent
        }
    }

    @ViewBuilder
    private var glassLayeredContent: some View {
        if #available(macOS 26, *) {
            layeredContent
        } else {
            layeredContent
        }
    }

    private var layeredContent: some View {
        ZStack(alignment: .top) {
            if #available(macOS 26, *) {
                GlassEffectContainer {
                    canvasContent
                }
            } else {
                canvasContent
            }
            inspectorOverlay
            navigationBarOverlay
            selectionActionBar
        }
    }

    private var canvasContent: some View {
        ThreadCanvasView(viewModel: viewModel,
                         displaySettings: displaySettings,
                         topInset: canvasTopPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, navHorizontalPadding)
    }

    @ViewBuilder
    private var inspectorOverlay: some View {
        if isInspectorVisible {
            if let selectedFolder = viewModel.selectedFolder {
                let minimapModel = viewModel.folderMinimapModel(for: selectedFolder.id)
                ThreadFolderInspectorView(folder: selectedFolder,
                                          mailboxAccounts: viewModel.mailboxAccounts,
                                          isMailboxHierarchyLoading: viewModel.isMailboxHierarchyLoading,
                                          mailboxEditingDisabledReason: viewModel.folderMailboxEditingDisabledReason(for: selectedFolder.id),
                                          preferredMailboxAccount: viewModel.preferredMailboxAccountForFolder(selectedFolder.id),
                                          textScale: displaySettings.textScale,
                                          minimapModel: minimapModel,
                                          minimapSelectedNodeID: viewModel.folderMinimapSelectedNodeID(for: selectedFolder.id),
                                          minimapViewportRect: viewModel.folderMinimapViewport(for: selectedFolder.id),
                                          summaryState: viewModel.folderSummaryState(for: selectedFolder.id),
                                          canRegenerateSummary: viewModel.isSummaryProviderAvailable,
                                          onRegenerateSummary: {
                                              viewModel.regenerateFolderSummary(for: selectedFolder.id)
                                          },
                                          onMinimapJump: { point in
                                              viewModel.jumpToFolderMinimapPoint(in: selectedFolder.id,
                                                                                 normalizedPoint: point)
                                          },
                                          onJumpToLatest: {
                                              viewModel.jumpToLatestNode(in: selectedFolder.id)
                                          },
                                          onJumpToOldest: {
                                              viewModel.jumpToFirstNode(in: selectedFolder.id)
                                          },
                                          onRefreshMailboxHierarchy: {
                                              viewModel.refreshMailboxHierarchy(force: true)
                                          },
                                          onPreview: { title, color, mailboxAccount, mailboxPath in
                                              viewModel.previewFolderEdits(id: selectedFolder.id,
                                                                           title: title,
                                                                           color: color,
                                                                           mailboxAccount: mailboxAccount,
                                                                           mailboxPath: mailboxPath)
                                          },
                                          onSave: { title, color, mailboxAccount, mailboxPath in
                                              viewModel.saveFolderEdits(id: selectedFolder.id,
                                                                        title: title,
                                                                        color: color,
                                                                        mailboxAccount: mailboxAccount,
                                                                        mailboxPath: mailboxPath)
                                          })
                    .id(selectedFolder.id)
                    .frame(width: inspectorWidth)
                    .padding(.top, navInsetHeight)
                    .padding(.trailing, navHorizontalPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(0.5)
                    .transition(
                        .scale(scale: 0.96, anchor: .topTrailing)
                        .combined(with: .opacity)
                    )
                    .animation(.spring(response: 0.24, dampingFraction: 0.82),
                               value: viewModel.selectedFolderID ?? viewModel.selectedNodeID)
            } else if let selectedNode = viewModel.selectedNode {
                ThreadInspectorView(node: selectedNode,
                                    summaryState: selectedSummaryState,
                                    summaryExpansion: selectedSummaryExpansion,
                                    inspectorSettings: inspectorSettings,
                                    textScale: displaySettings.textScale,
                                    openInMailState: viewModel.openInMailState,
                                    canRegenerateSummary: viewModel.isSummaryProviderAvailable,
                                    onRegenerateSummary: {
                                        viewModel.regenerateNodeSummary(for: selectedNode.id)
                                    },
                                    onOpenInMail: viewModel.openMessageInMail,
                                    onCopyOpenInMailText: viewModel.copyToPasteboard)
                    .frame(width: inspectorWidth)
                    .padding(.top, navInsetHeight)
                    .padding(.trailing, navHorizontalPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(0.5)
                    .transition(
                        .scale(scale: 0.96, anchor: .topTrailing)
                        .combined(with: .opacity)
                    )
                    .animation(.spring(response: 0.24, dampingFraction: 0.82),
                               value: viewModel.selectedFolderID ?? viewModel.selectedNodeID)
            }
        }
    }

    private var navInsetHeight: CGFloat {
        max(navHeight + navTopPadding + navBottomSpacing, 88)
    }

    private var canvasTopPadding: CGFloat {
        navHeight + navTopPadding + navCanvasSpacing
    }

    private var navigationBarOverlay: some View {
        navBar
            .padding(.horizontal, navHorizontalPadding)
            .padding(.top, navTopPadding)
            .onPreferenceChange(NavHeightPreferenceKey.self) { navHeight = $0 }
            .zIndex(1)
    }

    private var isGlassNavEnabled: Bool {
        if #available(macOS 26, *) {
            return !reduceTransparency
        }
        return false
    }

    private var navPrimaryForegroundStyle: Color {
        guard isGlassNavEnabled else { return Color.primary }
        if colorScheme == .light {
            return Color.black.opacity(0.82)
        }
        return Color.white
    }

    private var navSecondaryForegroundStyle: Color {
        guard isGlassNavEnabled else { return Color.secondary }
        if colorScheme == .light {
            return Color.black.opacity(0.62)
        }
        return Color.white.opacity(0.75)
    }

    private var navBar: some View {
        navBarContent
    }

    private var navBarContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Threads")
                    .font(font(size: 13, weight: .semibold))
                Text(statusText)
                    .font(font(size: 12))
                    .foregroundStyle(navSecondaryForegroundStyle)
                refreshTimingView
            }
            Spacer()
            if viewModel.isRefreshing {
                ProgressView().controlSize(.small)
            }
            if viewModel.isBackfilling {
                ProgressView().controlSize(.small)
            }
            viewModeToggle
            HStack(spacing: 6) {
                Text("Limit")
                    .font(font(size: 12))
                    .foregroundStyle(navSecondaryForegroundStyle)
                limitField
            }
            refreshButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(navPrimaryForegroundStyle)
        .shadow(color: Color.black.opacity(isGlassNavEnabled ? (colorScheme == .light ? 0.18 : 0.45) : 0),
                radius: 1.5,
                x: 0,
                y: 1)
        .background(navBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(navDividerColor)
                .frame(height: 1)
                .blur(radius: reduceTransparency ? 0 : 0.5)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: NavHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
    }

    private func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * displaySettings.textScale, weight: weight)
    }

    @ViewBuilder
    private var viewModeToggle: some View {
        Toggle(isOn: viewModeToggleBinding) {
            Text(viewModeLabel)
                .font(font(size: 12))
        }
        .toggleStyle(.switch)
        .tint(.green)
    }

    private var viewModeLabel: String {
        switch displaySettings.viewMode {
        case .default:
            return NSLocalizedString("threadlist.viewmode.default", comment: "Default thread canvas view label")
        case .timeline:
            return NSLocalizedString("threadlist.viewmode.timeline", comment: "Timeline thread canvas view label")
        }
    }

    private var viewModeToggleBinding: Binding<Bool> {
        Binding(
            get: { displaySettings.viewMode == .timeline },
            set: { displaySettings.viewMode = $0 ? .timeline : .default }
        )
    }

    private var statusText: String {
        if viewModel.unreadTotal > 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("threadlist.status.unread", comment: "Status showing unread count"),
                viewModel.unreadTotal,
                viewModel.status
            )
        }
        return viewModel.status
    }

    private var refreshTimingView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let lastRefreshDate = viewModel.lastRefreshDate {
                Text("Last updated: \(lastRefreshDate.formatted(date: .numeric, time: .shortened))")
                    .font(font(size: 11))
                    .foregroundStyle(navSecondaryForegroundStyle)
            }
            if settings.isEnabled, let nextRefreshDate = viewModel.nextRefreshDate {
                Text("Next refresh: \(nextRefreshDate.formatted(date: .numeric, time: .shortened))")
                    .font(font(size: 11))
                    .foregroundStyle(navSecondaryForegroundStyle)
            }
        }
    }

    @ViewBuilder
    private var limitField: some View {
        if isGlassNavEnabled {
            let fieldFill = colorScheme == .light ? Color.white.opacity(0.55) : Color.white.opacity(0.18)
            let fieldStroke = colorScheme == .light ? Color.black.opacity(0.2) : Color.white.opacity(0.55)
            let fieldForeground = colorScheme == .light ? Color.black.opacity(0.9) : Color.white
            TextField("Limit", value: $viewModel.fetchLimit, format: .number)
                .font(font(size: 13))
                .textFieldStyle(.plain)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fieldFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(fieldStroke)
                )
                .foregroundStyle(fieldForeground)
                .tint(fieldForeground)
                .frame(width: 60, height: 24)
        } else {
            TextField("Limit", value: $viewModel.fetchLimit, format: .number)
                .font(font(size: 13))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 60, height: 24)
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        let button = Button(action: {
            viewModel.refreshMailboxHierarchy(force: true)
            viewModel.refreshNow()
        }) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isRefreshing)

        if #available(macOS 26, *) {
            button.buttonStyle(.glass)
        } else {
            button
        }
    }

    @ViewBuilder
    private var navBackground: some View {
        let shape = RoundedRectangle(cornerRadius: navCornerRadius, style: .continuous)
        if reduceTransparency {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.96))
                .overlay(shape.stroke(colorScheme == .light ? Color.black.opacity(0.15) : Color.white.opacity(0.3)))
        } else if #available(macOS 26, *) {
            let strokeColor = colorScheme == .light ? Color.black.opacity(0.16) : Color.white.opacity(0.35)
            let shadowOpacity = colorScheme == .light ? 0.12 : 0.25
            let tintOpacity = colorScheme == .light ? 0.52 : 0.2
            let fillOpacity = colorScheme == .light ? 0.24 : 0.08
            shape
                .fill(Color.white.opacity(fillOpacity))
                .glassEffect(
                    .regular
                        .tint(Color.white.opacity(tintOpacity))
                        .interactive(),
                    in: .rect(cornerRadius: navCornerRadius)
                )
                .overlay(shape.stroke(strokeColor))
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 16, y: 8)
        } else {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.9))
                .overlay(shape.stroke(colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.25)))
        }
    }

    private var selectionActionBar: some View {
        Group {
            if shouldShowActionBar {
                Group {
                    VStack(alignment: .leading, spacing: 0) {
                        if viewModel.shouldShowSelectionActions {
                            HStack(spacing: 12) {
                                if viewModel.isMailboxActionRunning {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text(viewModel.mailboxActionProgressMessage ??
                                             NSLocalizedString("mailbox.action.progress.move",
                                                               comment: "Status while moving messages to mailbox folder"))
                                            .font(.caption)
                                            .foregroundStyle(navSecondaryForegroundStyle)
                                    }
                                }
                                Text(String.localizedStringWithFormat(
                                    NSLocalizedString("threadlist.selection.count", comment: "Selection count label"),
                                    viewModel.selectedNodeIDs.count
                                ))
                                .font(.caption)
                                .foregroundStyle(navSecondaryForegroundStyle)
                                Button(action: { viewModel.groupSelectedMessages() }) {
                                    actionBarButtonLabel(
                                        systemImage: "link",
                                        verbKey: "threadlist.selection.group.verb",
                                        accessibilityKey: "threadlist.selection.group"
                                    )
                                }
                                .disabled(!viewModel.canGroupSelection)
                                .help(NSLocalizedString("threadlist.selection.group", comment: "Group selection button"))
                                Button(action: { viewModel.addFolderForSelection() }) {
                                    actionBarButtonLabel(
                                        systemImage: "folder",
                                        verbKey: "threadlist.selection.add_folder.verb",
                                        accessibilityKey: "threadlist.selection.add_folder"
                                    )
                                }
                                .disabled(viewModel.selectedNodeIDs.isEmpty)
                                .help(NSLocalizedString("threadlist.selection.add_folder", comment: "Add folder selection button"))
                                Button(action: { isShowingMailboxMoveSheet = true }) {
                                    actionBarButtonLabel(
                                        systemImage: "folder.badge.plus",
                                        verbKey: "threadlist.selection.move_mailbox_folder.verb",
                                        accessibilityKey: "threadlist.selection.move_mailbox_folder"
                                    )
                                }
                                .disabled(!viewModel.canMoveSelectionToMailboxFolder || viewModel.isMailboxActionRunning)
                                .help(viewModel.mailboxActionDisabledReason ??
                                      NSLocalizedString("threadlist.selection.move_mailbox_folder",
                                                        comment: "Move selected nodes to mailbox folder button"))
                                Button(action: { viewModel.ungroupSelectedMessages() }) {
                                    actionBarButtonLabel(
                                        systemImage: "personalhotspot.slash",
                                        verbKey: "threadlist.selection.ungroup.verb",
                                        accessibilityKey: "threadlist.selection.ungroup"
                                    )
                                }
                                .disabled(!viewModel.canUngroupSelection)
                                .help(NSLocalizedString("threadlist.selection.ungroup", comment: "Ungroup selection button"))
                                if shouldShowBackfillAction {
                                    Button(action: { presentBackfillConfirmation() }) {
                                        actionBarButtonLabel(
                                            systemImage: "tray.and.arrow.down",
                                            verbKey: "threadlist.backfill.button.verb",
                                            accessibilityKey: "threadlist.backfill.button"
                                        )
                                    }
                                    .disabled(viewModel.isBackfilling)
                                    .help(NSLocalizedString("threadlist.backfill.button",
                                                            comment: "Backfill visible days button"))
                                }
                            }
                        } else {
                            HStack(spacing: 12) {
                                if shouldShowBackfillAction {
                                    Button(action: { presentBackfillConfirmation() }) {
                                        actionBarButtonLabel(
                                            systemImage: "tray.and.arrow.down",
                                            verbKey: "threadlist.backfill.button.verb",
                                            accessibilityKey: "threadlist.backfill.button"
                                        )
                                    }
                                    .disabled(viewModel.isBackfilling)
                                    .help(NSLocalizedString("threadlist.backfill.button",
                                                            comment: "Backfill visible days button"))
                                }
                            }
                        }

                        if let mailboxActionStatus = viewModel.mailboxActionStatusMessage {
                            Text(mailboxActionStatus)
                                .font(.caption2)
                                .foregroundStyle(navSecondaryForegroundStyle)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: actionBarMaxWidth)
                .background(selectionActionBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(actionBarStrokeColor)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(isGlassNavEnabled ? 0.3 : 0.2), radius: 12, y: 6)
                .padding(.bottom, 16)
                .offset(x: selectionActionBarHorizontalOffset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.2), value: shouldShowActionBar)
    }

    private var shouldShowBackfillAction: Bool {
        !viewModel.visibleEmptyDayIntervals.isEmpty
    }

    private var selectionActionBarInspectorReservation: CGFloat {
        isInspectorVisible ? inspectorWidth + navHorizontalPadding : 0
    }

    private var selectionActionBarHorizontalOffset: CGFloat {
        -selectionActionBarInspectorReservation / 2
    }

    private var shouldShowActionBar: Bool {
        viewModel.shouldShowSelectionActions || shouldShowBackfillAction
    }

    private var actionBarMaxWidth: CGFloat? {
        viewModel.shouldShowSelectionActions ? 520 : nil
    }

    private func actionBarButtonLabel(systemImage: String,
                                      verbKey: String,
                                      accessibilityKey: String) -> some View {
        Label(NSLocalizedString(verbKey, comment: "Selection action short verb"),
              systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .help(NSLocalizedString(accessibilityKey, comment: "Selection action button"))
            .accessibilityLabel(NSLocalizedString(accessibilityKey, comment: "Selection action button"))
    }

    private var backfillIntervalDescription: String? {
        guard let mergedInterval = mergedVisibleEmptyInterval else { return nil }
        return Self.backfillIntervalFormatter.string(from: mergedInterval.start,
                                                     to: mergedInterval.end)
    }

    private var mergedVisibleEmptyInterval: DateInterval? {
        guard let first = viewModel.visibleEmptyDayIntervals.min(by: { $0.start < $1.start }),
              let last = viewModel.visibleEmptyDayIntervals.max(by: { $0.end < $1.end }) else {
            return nil
        }
        return DateInterval(start: first.start, end: last.end)
    }

    @ViewBuilder
    private var selectionActionBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.92))
        } else if #available(macOS 26, *), isGlassNavEnabled {
            let fillOpacity = colorScheme == .light ? 0.24 : 0.1
            let tintOpacity = colorScheme == .light ? 0.36 : 0.16
            shape
                .fill(Color.white.opacity(fillOpacity))
                .glassEffect(
                    .regular
                        .tint(Color.white.opacity(tintOpacity))
                        .interactive(),
                    in: .rect(cornerRadius: 14)
                )
        } else {
            shape.fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.86))
        }
    }

    private var navDividerColor: Color {
        if colorScheme == .light {
            return Color.black.opacity(reduceTransparency ? 0.14 : 0.1)
        }
        return Color.white.opacity(reduceTransparency ? 0.2 : 0.12)
    }

    private var actionBarStrokeColor: Color {
        if colorScheme == .light {
            return Color.black.opacity(reduceTransparency ? 0.18 : 0.14)
        }
        return Color.white.opacity(reduceTransparency ? 0.15 : 0.25)
    }

    private var selectedSummaryState: ThreadSummaryState? {
        guard let selectedNodeID = viewModel.selectedNodeID else {
            return nil
        }
        return viewModel.summaryState(for: selectedNodeID)
    }

    private var selectedSummaryExpansion: Binding<Bool>? {
        guard let selectedNodeID = viewModel.selectedNodeID else {
            return nil
        }
        return Binding(
            get: { viewModel.isSummaryExpanded(for: selectedNodeID) },
            set: { viewModel.setSummaryExpanded($0, for: selectedNodeID) }
        )
    }
}

private struct NavHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BackfillConfirmationSheet: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Binding var limit: Int
    let intervalDescription: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("threadlist.backfill.confirm.title",
                                   comment: "Title for backfill confirmation"))
                .font(.title3.bold())
            Text(String.localizedStringWithFormat(
                NSLocalizedString("threadlist.backfill.confirm.description",
                                  comment: "Description for backfill confirmation"),
                intervalDescription
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                DatePicker(NSLocalizedString("threadlist.backfill.confirm.start",
                                             comment: "Backfill start date"),
                           selection: $startDate,
                           displayedComponents: [.date])
                DatePicker(NSLocalizedString("threadlist.backfill.confirm.end",
                                             comment: "Backfill end date"),
                           selection: $endDate,
                           displayedComponents: [.date])
                Stepper(value: $limit, in: 1...5000, step: 10) {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("threadlist.backfill.confirm.limit",
                                          comment: "Backfill limit field label"),
                        limit))
                }
            }

            HStack {
                Spacer()
                Button(NSLocalizedString("threadlist.backfill.confirm.cancel",
                                         comment: "Cancel backfill action"), action: onCancel)
                Button(NSLocalizedString("threadlist.backfill.confirm.action",
                                         comment: "Confirm backfill action"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MailboxFolderMoveSheet: View {
    private enum MailboxMoveMode: String, CaseIterable, Identifiable {
        case existing
        case create

        var id: String { rawValue }
    }

    private struct FolderTreeRow: Identifiable {
        let path: String
        let name: String
        let depth: Int

        var id: String { path }
    }

    @ObservedObject var viewModel: ThreadCanvasViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @State private var mode: MailboxMoveMode = .existing
    @State private var selectedAccount: String = ""
    @State private var selectedExistingPath: String?
    @State private var selectedParentPath: String?
    @State private var newFolderName: String = ""
    @State private var folderSearchQuery: String = ""
    private let isCreateAndMoveEnabled = false

    private var forcedAccount: String? {
        viewModel.mailboxActionSelectionAccount
    }

    private var accountOptions: [String] {
        if let forcedAccount {
            return [forcedAccount]
        }
        return viewModel.mailboxActionAccountNames
    }

    private var folderChoices: [MailboxFolderChoice] {
        guard !selectedAccount.isEmpty else { return [] }
        return viewModel.mailboxFolderChoices(for: selectedAccount)
    }

    private var selectedMailboxAccount: MailboxAccount? {
        viewModel.mailboxAccounts.first(where: { $0.name == selectedAccount })
    }

    private var filteredFolders: [MailboxFolderNode] {
        guard let selectedMailboxAccount else { return [] }
        return MailboxHierarchyBuilder.filterFolderTree(selectedMailboxAccount.folders, query: folderSearchQuery)
    }

    private var filteredFolderRows: [FolderTreeRow] {
        Self.flattenRows(nodes: filteredFolders)
    }

    private var trimmedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        guard !selectedAccount.isEmpty else { return false }
        guard viewModel.mailboxActionDisabledReason == nil else { return false }
        guard !viewModel.isMailboxActionRunning else { return false }
        if !isCreateAndMoveEnabled && mode == .create {
            return false
        }
        switch mode {
        case .existing:
            return selectedExistingPath != nil && !folderChoices.isEmpty
        case .create:
            return !trimmedNewFolderName.isEmpty
        }
    }

    private var submitButtonTitle: String {
        switch mode {
        case .existing:
            return NSLocalizedString("mailbox.sheet.action.move", comment: "Primary action to move selection to an existing folder")
        case .create:
            return NSLocalizedString("mailbox.sheet.action.create_and_move", comment: "Primary action to create folder and move selection")
        }
    }

    private var cardFillColor: Color {
        if reduceTransparency {
            return Color(nsColor: NSColor.windowBackgroundColor).opacity(0.96)
        }
        if colorScheme == .light {
            return Color.white.opacity(0.78)
        }
        return Color.white.opacity(0.1)
    }

    private var cardStrokeColor: Color {
        colorScheme == .light ? Color.black.opacity(0.12) : Color.white.opacity(0.24)
    }

    private static func isInboxPath(_ path: String) -> Bool {
        guard let leaf = MailboxPathFormatter.leafName(from: path) else { return false }
        return leaf.caseInsensitiveCompare("inbox") == .orderedSame
    }

    private static func flattenRows(nodes: [MailboxFolderNode], depth: Int = 0) -> [FolderTreeRow] {
        var rows: [FolderTreeRow] = []
        for node in nodes {
            rows.append(FolderTreeRow(path: node.path, name: node.name, depth: depth))
            rows.append(contentsOf: flattenRows(nodes: node.children, depth: depth + 1))
        }
        return rows
    }

    private func setDefaultSelections() {
        if selectedAccount.isEmpty {
            selectedAccount = forcedAccount ?? accountOptions.first ?? ""
        }
        if selectedExistingPath == nil {
            selectedExistingPath = folderChoices.first(where: { Self.isInboxPath($0.path) })?.path ?? folderChoices.first?.path
        } else if let selectedExistingPath,
                  !folderChoices.contains(where: { $0.path == selectedExistingPath }) {
            self.selectedExistingPath = folderChoices.first(where: { Self.isInboxPath($0.path) })?.path ?? folderChoices.first?.path
        }
        if let selectedParentPath,
           !folderChoices.contains(where: { $0.path == selectedParentPath }) {
            self.selectedParentPath = nil
        }
    }

    private func submit() {
        if !isCreateAndMoveEnabled && mode == .create {
            return
        }
        switch mode {
        case .existing:
            guard let selectedExistingPath else { return }
            viewModel.moveSelectionToMailboxFolder(path: selectedExistingPath, in: selectedAccount)
            dismiss()
        case .create:
            viewModel.createMailboxFolderAndMoveSelection(name: trimmedNewFolderName,
                                                          in: selectedAccount,
                                                          parentPath: selectedParentPath)
            dismiss()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("mailbox.sheet.title", comment: "Mailbox folder move sheet title"))
                        .font(.title3.bold())
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("mailbox.sheet.selection_count", comment: "Summary label for selected message count in mailbox move sheet"),
                        viewModel.selectedNodeIDs.count
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.isMailboxActionRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let disabledReason = viewModel.mailboxActionDisabledReason {
                Text(disabledReason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker(NSLocalizedString("mailbox.sheet.account", comment: "Mailbox action account picker label"),
                   selection: $selectedAccount) {
                ForEach(accountOptions, id: \.self) { account in
                    Text(account).tag(account)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(forcedAccount != nil || viewModel.isMailboxActionRunning)

            if isCreateAndMoveEnabled {
                Picker(NSLocalizedString("mailbox.sheet.mode", comment: "Mailbox move sheet mode segmented control label"),
                       selection: $mode) {
                    Text(NSLocalizedString("mailbox.sheet.mode.existing", comment: "Mode for moving to an existing mailbox folder"))
                        .tag(MailboxMoveMode.existing)
                    Text(NSLocalizedString("mailbox.sheet.mode.create", comment: "Mode for creating a folder and moving"))
                        .tag(MailboxMoveMode.create)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .disabled(viewModel.isMailboxActionRunning)
            }

            VStack(alignment: .leading, spacing: 8) {
                if isCreateAndMoveEnabled && mode == .create {
                    TextField(NSLocalizedString("mailbox.sheet.new_name", comment: "New mailbox folder name field"),
                              text: $newFolderName)
                    .textFieldStyle(.roundedBorder)

                    Text(NSLocalizedString("mailbox.sheet.parent_folder", comment: "Parent mailbox folder picker label"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(NSLocalizedString("mailbox.sheet.existing_folder", comment: "Existing mailbox folder picker label"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField(NSLocalizedString("mailbox.sheet.search.placeholder",
                                            comment: "Search field placeholder for mailbox folder selection"),
                          text: $folderSearchQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

                Group {
                    if viewModel.isMailboxHierarchyLoading && folderChoices.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(NSLocalizedString("mailbox.sheet.loading", comment: "Loading mailbox folders indicator"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if folderChoices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(NSLocalizedString("mailbox.sheet.empty.destinations",
                                                   comment: "Empty state when no mailbox folders are available for selection"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(NSLocalizedString("mailbox.sheet.refresh", comment: "Refresh mailbox hierarchy button")) {
                                viewModel.refreshMailboxHierarchy(force: true)
                            }
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if filteredFolderRows.isEmpty {
                        Text(NSLocalizedString("mailbox.sheet.empty.filtered",
                                               comment: "Empty state when no mailbox folders match the search query"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                if isCreateAndMoveEnabled && mode == .create {
                                    rootFolderRow
                                }
                                ForEach(filteredFolderRows) { row in
                                    folderRow(path: row.path, name: row.name, depth: row.depth)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 210)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(cardFillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(cardStrokeColor)
                )

                Text(mode == .existing || !isCreateAndMoveEnabled
                     ? NSLocalizedString("mailbox.sheet.helper.existing", comment: "Helper text for existing folder move mode")
                     : NSLocalizedString("mailbox.sheet.helper.create", comment: "Helper text for create-and-move mode"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(cardFillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(cardStrokeColor)
            )

            if let status = viewModel.mailboxActionStatusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(NSLocalizedString("mailbox.sheet.cancel", comment: "Cancel mailbox action sheet button")) {
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)

                Button(submitButtonTitle) {
                    submit()
                }
                .controlSize(.small)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear {
            if !isCreateAndMoveEnabled {
                mode = .existing
            }
            setDefaultSelections()
            if viewModel.mailboxAccounts.isEmpty || folderChoices.isEmpty {
                viewModel.refreshMailboxHierarchy()
            }
        }
        .onChange(of: viewModel.mailboxAccounts) { _, _ in
            let resolvedAccount = forcedAccount
                ?? (accountOptions.contains(selectedAccount) ? selectedAccount : (accountOptions.first ?? ""))
            if selectedAccount != resolvedAccount {
                selectedAccount = resolvedAccount
            }
            setDefaultSelections()
        }
        .onChange(of: selectedAccount) { _, _ in
            selectedExistingPath = folderChoices.first(where: { Self.isInboxPath($0.path) })?.path ?? folderChoices.first?.path
            selectedParentPath = nil
            folderSearchQuery = ""
        }
    }

    private var rootFolderRow: some View {
        let isSelected = selectedParentPath == nil
        return Button {
            selectedParentPath = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("mailbox.sheet.parent_root", comment: "Account root parent option"))
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func folderRow(path: String, name: String, depth: Int) -> some View {
        let isSelected: Bool = {
            switch mode {
            case .existing:
                return selectedExistingPath == path
            case .create:
                return selectedParentPath == path
            }
        }()
        return Button {
            switch mode {
            case .existing:
                selectedExistingPath = path
            case .create:
                selectedParentPath = path
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.leading, CGFloat(depth) * 12 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
        }
        .help(path)
        .buttonStyle(.plain)
    }
}

private extension ThreadListView {
    func presentBackfillConfirmation() {
        guard let mergedInterval = mergedVisibleEmptyInterval else { return }
        backfillStartDate = mergedInterval.start
        backfillEndDate = mergedInterval.end
        backfillLimit = viewModel.fetchLimit
        isShowingBackfillConfirmation = true
    }

    func confirmBackfillWithOverrides() {
        let adjustedLimit = max(1, backfillLimit)
        let orderedRange = backfillStartDate <= backfillEndDate
            ? DateInterval(start: backfillStartDate, end: backfillEndDate)
            : DateInterval(start: backfillEndDate, end: backfillStartDate)
        let calendar = Calendar.current
        let inclusiveEnd = calendar.date(byAdding: .day, value: 1, to: orderedRange.end) ?? orderedRange.end
        let inclusiveRange = DateInterval(start: orderedRange.start, end: inclusiveEnd)
        isShowingBackfillConfirmation = false
        viewModel.backfillVisibleRange(rangeOverride: inclusiveRange, limitOverride: adjustedLimit)
    }

    static var backfillIntervalFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
