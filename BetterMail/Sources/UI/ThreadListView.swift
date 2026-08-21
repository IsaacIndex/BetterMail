import AppKit
import SwiftUI

private enum ThreadListCanvasViewMode: String, CaseIterable, Identifiable {
    case `default`
    case timeline
    case graph

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .default:
            return NSLocalizedString("threadlist.viewmode.default.segment",
                                     comment: "Default thread canvas view mode segment")
        case .timeline:
            return NSLocalizedString("threadlist.viewmode.timeline.segment",
                                     comment: "Timeline thread canvas view mode segment")
        case .graph:
            return NSLocalizedString("graph.mode.graph", comment: "Graph graph mode segment")
        }
    }
}

internal struct ThreadListView: View {
    @ObservedObject internal var viewModel: ThreadCanvasViewModel
    @ObservedObject internal var settings: AutoRefreshSettings
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    @StateObject private var graphSettings = GraphCanvasSettings()
    @StateObject private var graphViewModel = GraphCanvasViewModel(
        graphTitleCapabilityProvider: GraphTitleProviderFactory.makeCapability,
        graphTopicCapabilityProvider: GraphTopicProviderFactory.makeCapability
    )
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var navHeight: CGFloat = 96
    @State private var isShowingBackfillConfirmation = false
    @State private var backfillStartDate = Date()
    @State private var backfillEndDate = Date()
    @State private var isShowingCoverageCalendar = false
    @State private var selectedDayFetch: DayFetchSelection?
    @State private var isInspectorVisible = false
    @State private var isShowingMailboxMoveSheet = false
    @FocusState private var isSearchFieldFocused: Bool

    private let navCornerRadius: CGFloat = 18
    private let navHorizontalPadding: CGFloat = 16
    private let navTopPadding: CGFloat = 12
    private let navBottomSpacing: CGFloat = 12
    private let navCanvasSpacing: CGFloat = 6
    private let inspectorWidth: CGFloat = 320
    private let graphSelectionBarReservation: CGFloat = 78

    internal var body: some View {
        content
            .frame(minWidth: 480, minHeight: 400)
            .focusable()
            .onKeyPress(.upArrow) { handleCanvasNavigation(.up) }
            .onKeyPress(.downArrow) { handleCanvasNavigation(.down) }
            .onKeyPress(.leftArrow) { handleCanvasNavigation(.left) }
            .onKeyPress(.rightArrow) { handleCanvasNavigation(.right) }
            .onKeyPress(.return) { handleEnterKey() }
            .onKeyPress("s") { handleGraphKey(.snip) }
            .onKeyPress("a") { handleGraphKey(.archive) }
            .onKeyPress("w") { handleGraphKey(.water) }
            .onKeyPress("+") { handleGraphKey(.zoomIn) }
            .onKeyPress("-") { handleGraphKey(.zoomOut) }
            .onKeyPress("0") { handleGraphKey(.reset) }
            .onKeyPress(.escape) {
                if isSearchFieldFocused {
                    handleSearchEscape()
                    return .handled
                }
                // The allocation sheet owns Escape while it is presented. Its
                // cancel action dismisses first, and GraphCanvasView's
                // onDismiss callback restores staging without discarding the
                // batch. Consuming the parent event prevents the same key press
                // from falling through to the canvas cancellation handler.
                if graphViewModel.snipPhase == .allocating ||
                    graphViewModel.snipPhase == .moving {
                    return .handled
                }
                return handleGraphKey(.escape)
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
                    onConfirm: confirmBackfillWithOverrides,
                    onCancel: { isShowingBackfillConfirmation = false }
                )
                .frame(minWidth: 360)
            }
            .sheet(item: $selectedDayFetch) { selection in
                DayFetchConfirmationSheet(
                    selection: selection,
                    onConfirm: {
                        selectedDayFetch = nil
                        viewModel.fetchDay(selection.date)
                    },
                    onCancel: { selectedDayFetch = nil }
                )
            }
            .sheet(isPresented: $isShowingMailboxMoveSheet) {
                MailboxFolderMoveSheet(viewModel: viewModel)
                    .frame(minWidth: 440, minHeight: 390)
            }
            .sheet(isPresented: $viewModel.isGraphAutomationPresented) {
                GraphAutomationQueueSheet(coordinator: viewModel.graphAutomationCoordinator,
                                          folders: viewModel.threadFolders)
            }
    }

    private var content: some View {
        ZStack(alignment: .top) {
            GlassWindowBackground()
                .ignoresSafeArea()
            glassLayeredContent
        }
        .accessibilityIdentifier(AccessibilityID.threadList)
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
            ToastOverlay(activeToast: $viewModel.activeToast)
        }
        // Global minimap disabled — viewport coordinate alignment needs further work.
        // .overlay(alignment: .bottomLeading) {
        //     GlobalMinimapOverlay(
        //         folders: viewModel.globalMinimapFoldersSnapshot,
        //         viewportRect: viewModel.globalMinimapViewportRect
        //     )
        // }
    }

    private var canvasContent: some View {
        Group {
            if graphSettings.mode == .graph {
                GraphCanvasView(threadViewModel: viewModel,
                                graphViewModel: graphViewModel,
                                automationCoordinator: viewModel.graphAutomationCoordinator,
                                graphSettings: graphSettings,
                                displaySettings: displaySettings,
                                topInset: canvasTopPadding,
                                bottomChromeInset: graphBottomChromeReservation)
                .animation(.easeInOut(duration: 0.2),
                           value: graphBottomChromeReservation)
            } else {
                ThreadCanvasView(viewModel: viewModel,
                                 displaySettings: displaySettings,
                                 topInset: canvasTopPadding)
            }
        }
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
                                          isRefreshingFolderThreads: viewModel.isRefreshingFolderThreads(for: selectedFolder.id),
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
                                          onRefreshFolderThreads: {
                                              viewModel.refreshFolderThreads(for: selectedFolder.id)
                                          },
                                          onRefreshMailboxHierarchy: {
                                              viewModel.refreshMailboxHierarchy(force: true)
                                          },
                                          onRecalibrateColor: {
                                              viewModel.recalibratedColor(for: selectedFolder.id)
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
                                    generatedGraphTitle: selectedGeneratedGraphTitle,
                                    isGraphTitleRegenerating: isSelectedGraphTitleRegenerating,
                                    summaryState: selectedSummaryState,
                                    summaryExpansion: selectedSummaryExpansion,
                                    inspectorSettings: inspectorSettings,
                                    textScale: displaySettings.textScale,
                                    openInMailState: viewModel.openInMailState,
                                    canRegenerateSummary: viewModel.isSummaryProviderAvailable,
                                    onRegenerateSummary: {
                                        viewModel.regenerateNodeSummary(for: selectedNode.id)
                                    },
                                    canRegenerateGraphTitle: canRegenerateSelectedGraphTitle,
                                    onRegenerateGraphTitle: {
                                        graphViewModel.regenerateGraphTitle(for: selectedNode.id)
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

    private var graphBottomChromeReservation: CGFloat {
        guard graphSettings.mode == .graph, shouldShowActionBar else { return 0 }
        return graphSelectionBarReservation
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
        Color.glassPrimary(colorScheme: colorScheme, isGlassEnabled: isGlassNavEnabled)
    }

    private var navSecondaryForegroundStyle: Color {
        Color.glassSecondary(colorScheme: colorScheme, isGlassEnabled: isGlassNavEnabled)
    }

    private var navBar: some View {
        navBarContent
    }

    private var navBarContent: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                wideNavigationRow
                compactNavigationRows
                narrowNavigationRows
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if let errorMessage = viewModel.errorMessage {
                errorBanner(message: errorMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(navPrimaryForegroundStyle)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.threadListNavigationBar)
        .accessibilityLabel(NSLocalizedString("accessibility.threadlist.navbar.label",
                                              comment: "Accessibility label for the thread list navigation bar"))
    }

    private var wideNavigationRow: some View {
        HStack(spacing: 8) {
            navigationStatusBlock
            Spacer(minLength: 12)
            canvasViewModeSegmentedControl
            if isThreadCanvasSelected {
                zoomControls
            }
            searchBar
            coverageCalendarButton
            refreshButton
        }
    }

    private var compactNavigationRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                navigationStatusBlock
                Spacer(minLength: 12)
                coverageCalendarButton
                refreshButton
            }
            HStack(spacing: 8) {
                canvasViewModeSegmentedControl
                if isThreadCanvasSelected {
                    zoomControls
                }
                Spacer(minLength: 8)
                searchBar
            }
        }
    }

    private var narrowNavigationRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            navigationStatusBlock
            HStack(spacing: 8) {
                canvasViewModeSegmentedControl
                if isThreadCanvasSelected {
                    zoomControls
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                searchBar
                Spacer(minLength: 0)
                coverageCalendarButton
                refreshButton
            }
        }
    }

    private var navigationStatusBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NSLocalizedString("threadlist.title", comment: "Thread list navigation title"))
                .font(DesignTokens.font(size: 13, weight: .semibold, textScale: displaySettings.textScale))
            Text(statusText)
                .font(DesignTokens.font(size: 12, textScale: displaySettings.textScale))
                .foregroundStyle(navSecondaryForegroundStyle)
            refreshTimingView
        }
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .font(.system(size: 12))
            Text(message)
                .font(DesignTokens.font(size: 12, weight: .medium, textScale: displaySettings.textScale))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.85))
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(DesignTokens.font(size: DesignTokens.FontSize.bodySecondary,
                                        weight: .medium,
                                        textScale: displaySettings.textScale))
                .foregroundStyle(isSearchFieldFocused ? Color.accentColor : navSecondaryForegroundStyle)
                .accessibilityHidden(true)

            searchFieldControl

            if let count = currentSearchResultCount {
                Text("\(count)")
                    .font(DesignTokens.font(size: 10,
                                            weight: .semibold,
                                            textScale: displaySettings.textScale))
                    .monospacedDigit()
                    .foregroundStyle(navSecondaryForegroundStyle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(navSecondaryForegroundStyle.opacity(0.1))
                    )
                    .accessibilityLabel(String.localizedStringWithFormat(
                        NSLocalizedString("accessibility.threadlist.search.results",
                                          comment: "Accessibility label for the thread search result count"),
                        count
                    ))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if !trimmedSearchQuery.isEmpty {
                searchClearButton
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 190, idealWidth: 220, maxWidth: 260, minHeight: 30)
        .background(topBarControlSurface(isActive: isSearchFieldFocused))
        .animation(.easeOut(duration: 0.14), value: currentSearchResultCount)
        .animation(.easeOut(duration: 0.14), value: trimmedSearchQuery.isEmpty)
    }

    private var searchFieldControl: some View {
        TextField(NSLocalizedString("threadlist.search.placeholder",
                                    comment: "Thread search field placeholder"),
                  text: $viewModel.searchQuery)
            .textFieldStyle(.plain)
            .font(DesignTokens.font(size: DesignTokens.FontSize.bodySecondary,
                                    textScale: displaySettings.textScale))
            .foregroundStyle(navPrimaryForegroundStyle)
            .focused($isSearchFieldFocused)
            .onKeyPress(.escape) {
                handleSearchEscape()
                return .handled
            }
            .accessibilityIdentifier(AccessibilityID.searchField)
            .accessibilityLabel(NSLocalizedString("accessibility.threadlist.search.field",
                                                  comment: "Accessibility label for the thread search field"))
            .accessibilityHint(NSLocalizedString("accessibility.threadlist.search.field.hint",
                                                comment: "Accessibility hint for the persistent thread search field"))
    }

    private var searchClearButton: some View {
        Button {
            viewModel.searchQuery = ""
            isSearchFieldFocused = true
        } label: {
            Image(systemName: "xmark.circle.fill")
            .font(DesignTokens.font(size: DesignTokens.FontSize.bodySecondary,
                                    weight: .medium,
                                    textScale: displaySettings.textScale))
            .foregroundStyle(navSecondaryForegroundStyle)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("threadlist.search.clear", comment: "Tooltip for clearing search"))
        .accessibilityLabel(NSLocalizedString("accessibility.threadlist.search.clear",
                                              comment: "Accessibility label for clearing search"))
    }

    private var trimmedSearchQuery: String {
        viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentSearchResultCount: Int? {
        switch selectedCanvasViewMode {
        case .default, .timeline:
            return viewModel.searchResultCount
        case .graph:
            return graphViewModel.searchResultCount
        }
    }

    private func handleSearchEscape() {
        if trimmedSearchQuery.isEmpty {
            isSearchFieldFocused = false
        } else {
            viewModel.searchQuery = ""
        }
    }

    private func topBarControlSurface(isActive: Bool = false,
                                      cornerRadius: CGFloat = 9) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isActive
                  ? Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.1)
                  : navSecondaryForegroundStyle.opacity(isGlassNavEnabled ? 0.09 : 0.07))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isActive
                            ? Color.accentColor.opacity(0.42)
                            : navSecondaryForegroundStyle.opacity(0.16),
                            lineWidth: 1)
            )
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Text(zoomPercentText)
                .font(DesignTokens.font(size: 11, weight: .medium, textScale: displaySettings.textScale))
                .foregroundStyle(navSecondaryForegroundStyle)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
                .padding(.leading, 2)

            Button {
                displaySettings.requestFitVisibleContent()
            } label: {
                Image(systemName: "viewfinder")
                    .font(DesignTokens.font(size: 12, weight: .semibold, textScale: displaySettings.textScale))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(NSLocalizedString("threadlist.zoom.fit.help", comment: "Tooltip for fitting visible thread canvas content"))
            .accessibilityIdentifier(AccessibilityID.zoomFitButton)
            .accessibilityLabel(NSLocalizedString("accessibility.threadlist.zoom.fit",
                                                  comment: "Accessibility label for the fit zoom button"))
            .accessibilityHint(NSLocalizedString("accessibility.threadlist.zoom.fit.hint",
                                                comment: "Accessibility hint for the fit zoom button"))

            Button {
                displaySettings.updateCurrentZoom(ThreadCanvasDisplaySettings.defaultCurrentZoom)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(DesignTokens.font(size: 12, weight: .semibold, textScale: displaySettings.textScale))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(NSLocalizedString("threadlist.zoom.reset.help", comment: "Tooltip for resetting thread canvas zoom"))
            .accessibilityIdentifier(AccessibilityID.zoomResetButton)
            .accessibilityLabel(NSLocalizedString("accessibility.threadlist.zoom.reset",
                                                  comment: "Accessibility label for the reset zoom button"))
            .accessibilityHint(NSLocalizedString("accessibility.threadlist.zoom.reset.hint",
                                                comment: "Accessibility hint for the reset zoom button"))
        }
        .padding(2)
        .frame(height: 30)
        .background(topBarControlSurface())
    }

    private var zoomPercentText: String {
        let percent = Int((displaySettings.currentZoom * 100).rounded())
        return String.localizedStringWithFormat(
            NSLocalizedString("threadlist.zoom.percent", comment: "Thread canvas zoom percentage"),
            percent
        )
    }

    private var canvasViewModeSegmentedControl: some View {
        HStack(spacing: 2) {
            ForEach(ThreadListCanvasViewMode.allCases) { mode in
                let isSelected = selectedCanvasViewMode == mode
                Button {
                    transitionCanvasViewMode(to: mode)
                } label: {
                    Text(mode.localizedTitle)
                        .font(DesignTokens.font(size: 12,
                                                weight: isSelected ? .semibold : .medium,
                                                textScale: displaySettings.textScale))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 26)
                        .foregroundStyle(isSelected ? Color.accentColor : navSecondaryForegroundStyle)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected
                                      ? Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.11)
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityIdentifier(AccessibilityID.canvasViewModeSegment(mode.rawValue))
                .accessibilityLabel(mode.localizedTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: 30)
        .background(topBarControlSurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.canvasViewModeControl)
        .accessibilityLabel(NSLocalizedString("accessibility.threadlist.canvasviewmode.control",
                                              comment: "Accessibility label for canvas view mode picker"))
        .accessibilityHint(NSLocalizedString("accessibility.threadlist.canvasviewmode.hint",
                                            comment: "Accessibility hint for canvas view mode picker"))
    }

    private var selectedCanvasViewMode: ThreadListCanvasViewMode {
        if graphSettings.mode == .graph {
            return .graph
        }

        switch displaySettings.viewMode {
        case .default:
            return .default
        case .timeline:
            return .timeline
        }
    }

    private var isThreadCanvasSelected: Bool {
        graphSettings.mode == .timeline
    }

    private func transitionCanvasViewMode(to mode: ThreadListCanvasViewMode) {
        let isLeavingGraph = selectedCanvasViewMode == .graph && mode != .graph
        if isLeavingGraph {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectCanvasViewMode(mode)
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            selectCanvasViewMode(mode)
        }
    }

    private func selectCanvasViewMode(_ mode: ThreadListCanvasViewMode) {
        switch mode {
        case .default:
            graphSettings.mode = .timeline
            displaySettings.viewMode = .default
        case .timeline:
            graphSettings.mode = .timeline
            displaySettings.viewMode = .timeline
        case .graph:
            graphSettings.mode = .graph
        }
    }

    private var statusText: String {
        if viewModel.needsAttentionCount > 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("threadlist.status.needs_attention", comment: "Status showing needs-attention count"),
                viewModel.needsAttentionCount,
                viewModel.status
            )
        }
        return viewModel.status
    }

    private var refreshTimingView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let lastRefreshDate = viewModel.lastRefreshDate {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("threadlist.refresh.last_updated",
                                      comment: "Last refresh timestamp in the thread list navigation bar"),
                    lastRefreshDate.formatted(date: .numeric, time: .shortened)
                ))
                    .font(DesignTokens.font(size: 11, textScale: displaySettings.textScale))
                    .foregroundStyle(navSecondaryForegroundStyle)
            }
            if settings.isEnabled, let nextRefreshDate = viewModel.nextRefreshDate {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("threadlist.refresh.next_refresh",
                                      comment: "Next refresh timestamp in the thread list navigation bar"),
                    nextRefreshDate.formatted(date: .numeric, time: .shortened)
                ))
                    .font(DesignTokens.font(size: 11, textScale: displaySettings.textScale))
                    .foregroundStyle(navSecondaryForegroundStyle)
            }
        }
    }

    private var coverageCalendarButton: some View {
        Button {
            isShowingCoverageCalendar.toggle()
        } label: {
            topBarActionLabel(
                title: NSLocalizedString("dayfetch.calendar.button",
                                         comment: "Open day coverage calendar button"),
                systemImage: "calendar.badge.exclamationmark",
                isActive: isShowingCoverageCalendar
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .popover(isPresented: $isShowingCoverageCalendar, arrowEdge: .bottom) {
            DayCoverageCalendarView(scope: viewModel.activeDayFetchScope,
                                    coverages: viewModel.dayFetchCoverages,
                                    fetchingDate: viewModel.activeDayFetchDate) { selection in
                isShowingCoverageCalendar = false
                selectedDayFetch = selection
            }
        }
        .accessibilityIdentifier(AccessibilityID.dayCoverageCalendarButton)
        .accessibilityHint(NSLocalizedString("dayfetch.calendar.button.hint",
                                            comment: "Coverage calendar button accessibility hint"))
    }

    private var refreshButton: some View {
        Button(action: {
            viewModel.refreshMailboxHierarchy(force: true)
            viewModel.refreshNow()
        }) {
            HStack(spacing: 6) {
                if isTopBarRefreshRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(DesignTokens.font(size: 12,
                                                weight: .semibold,
                                                textScale: displaySettings.textScale))
                        .frame(width: 14, height: 14)
                }
                Text(NSLocalizedString("threadlist.refresh.button", comment: "Refresh threads button title"))
                    .font(DesignTokens.font(size: 12,
                                            weight: .semibold,
                                            textScale: displaySettings.textScale))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(topBarControlSurface())
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isTopBarRefreshRunning)
        .accessibilityIdentifier(AccessibilityID.refreshButton)
        .accessibilityLabel(isTopBarRefreshRunning
                            ? NSLocalizedString("refresh.status.refreshing",
                                                comment: "Status while refresh is running")
                            : NSLocalizedString("threadlist.refresh.button",
                                                comment: "Refresh threads button title"))
        .accessibilityHint(NSLocalizedString("accessibility.threadlist.refresh.hint",
                                            comment: "Accessibility hint for the refresh button"))
    }

    private var isTopBarRefreshRunning: Bool {
        viewModel.isAnyRefreshRunning || viewModel.isMailboxHierarchyLoading
    }

    private func topBarActionLabel(title: String,
                                   systemImage: String,
                                   isActive: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(DesignTokens.font(size: 12,
                                        weight: .semibold,
                                        textScale: displaySettings.textScale))
                .frame(width: 14, height: 14)
            Text(title)
                .font(DesignTokens.font(size: 12,
                                        weight: .semibold,
                                        textScale: displaySettings.textScale))
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .foregroundStyle(isActive ? Color.accentColor : navPrimaryForegroundStyle)
        .background(topBarControlSurface(isActive: isActive))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var navBackground: some View {
        GlassBackground(
            cornerRadius: navCornerRadius,
            fillOpacity: DesignTokens.Opacity.fill(for: colorScheme),
            strokeOpacity: DesignTokens.Opacity.stroke(for: colorScheme),
            shadowOpacity: DesignTokens.Opacity.shadow(for: colorScheme),
            shadowRadius: 12,
            shadowY: 5,
            tintOpacity: DesignTokens.Opacity.tint(for: colorScheme),
            isInteractive: true
        )
    }

    private var selectionActionBar: some View {
        Group {
            if shouldShowActionBar {
                Group {
                    VStack(alignment: .leading, spacing: 0) {
                        if viewModel.shouldShowSelectionActions {
                            ViewThatFits(in: .horizontal) {
                                selectionActionsRow(compact: false)
                                selectionActionsRow(compact: true)
                            }
                        } else {
                            HStack(spacing: 12) {
                                if shouldShowBackfillAction {
                                    Button(action: { presentBackfillConfirmation() }) {
                                        actionBarButtonLabel(
                                            systemImage: "tray.and.arrow.down",
                                            fullKey: "threadlist.backfill.button",
                                            compactKey: "threadlist.backfill.button.verb",
                                            compact: false
                                        )
                                    }
                                    .disabled(viewModel.isBackfilling)
                                    .help(NSLocalizedString("threadlist.backfill.button",
                                                            comment: "Backfill visible days button"))
                                    .accessibilityIdentifier(AccessibilityID.backfillButton)
                                }
                            }
                        }

                        if let mailboxActionStatus = viewModel.bottomBarMailboxActionStatusMessage {
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
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.bottom, 16)
                .offset(x: selectionActionBarHorizontalOffset)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.selectionActionBar)
                .accessibilityLabel(NSLocalizedString("accessibility.threadlist.selection_bar.label",
                                                      comment: "Accessibility label for the selection action bar"))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.2), value: shouldShowActionBar)
    }

    private var shouldShowBackfillAction: Bool {
        !viewModel.visibleAtRiskDayIntervals.isEmpty
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
        viewModel.shouldShowSelectionActions ? 760 : nil
    }

    private func selectionActionsRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 9 : 12) {
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
                actionBarButtonLabel(systemImage: "link",
                                     fullKey: "threadlist.selection.group",
                                     compactKey: "threadlist.selection.group.verb",
                                     compact: compact)
            }
            .disabled(!viewModel.canGroupSelection)
            .help(NSLocalizedString("threadlist.selection.group.help", comment: "Join Thread help"))
            .accessibilityIdentifier(AccessibilityID.selectionAction("group"))
            Button(action: { viewModel.addFolderForSelection() }) {
                actionBarButtonLabel(systemImage: "folder.badge.plus",
                                     fullKey: "threadlist.selection.add_folder",
                                     compactKey: "threadlist.selection.add_folder.verb",
                                     compact: compact)
            }
            .disabled(viewModel.selectedNodeIDs.isEmpty)
            .help(NSLocalizedString("threadlist.selection.add_folder.help", comment: "Create Group help"))
            .accessibilityIdentifier(AccessibilityID.selectionAction("add-thread-folder"))
            Button(action: { isShowingMailboxMoveSheet = true }) {
                actionBarButtonLabel(systemImage: "folder",
                                     fullKey: "threadlist.selection.move_mailbox_folder",
                                     compactKey: "threadlist.selection.move_mailbox_folder.verb",
                                     compact: compact)
            }
            .disabled(!viewModel.canMoveSelectionToMailboxFolder || viewModel.isMailboxActionRunning)
            .help(viewModel.mailboxActionDisabledReason ??
                  NSLocalizedString("threadlist.selection.move_mailbox_folder.help",
                                    comment: "Move selected nodes to mailbox folder help"))
            .accessibilityIdentifier(AccessibilityID.selectionAction("move-mailbox-folder"))
            Button(action: { viewModel.ungroupSelectedMessages() }) {
                actionBarButtonLabel(systemImage: "personalhotspot.slash",
                                     fullKey: "threadlist.selection.ungroup",
                                     compactKey: "threadlist.selection.ungroup.verb",
                                     compact: compact)
            }
            .disabled(!viewModel.canUngroupSelection)
            .help(NSLocalizedString("threadlist.selection.ungroup.help", comment: "Remove from Thread help"))
            .accessibilityIdentifier(AccessibilityID.selectionAction("ungroup"))
            if shouldShowBackfillAction {
                Button(action: { presentBackfillConfirmation() }) {
                    actionBarButtonLabel(systemImage: "tray.and.arrow.down",
                                         fullKey: "threadlist.backfill.button",
                                         compactKey: "threadlist.backfill.button.verb",
                                         compact: compact)
                }
                .disabled(viewModel.isBackfilling)
                .help(NSLocalizedString("threadlist.backfill.button",
                                        comment: "Backfill visible days button"))
                .accessibilityIdentifier(AccessibilityID.backfillButton)
            }
        }
    }

    private func actionBarButtonLabel(systemImage: String,
                                      fullKey: String,
                                      compactKey: String,
                                      compact: Bool) -> some View {
        Label(NSLocalizedString(compact ? compactKey : fullKey,
                                comment: "Selection action label"),
              systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .accessibilityLabel(NSLocalizedString(fullKey, comment: "Selection action button"))
    }

    private var mergedVisibleRiskInterval: DateInterval? {
        guard let first = viewModel.visibleAtRiskDayIntervals.min(by: { $0.start < $1.start }),
              let last = viewModel.visibleAtRiskDayIntervals.max(by: { $0.end < $1.end }) else {
            return nil
        }
        return DateInterval(start: first.start, end: last.end)
    }

    private var selectionActionBackground: some View {
        let actionBarFill = colorScheme == .light ? 0.24 : 0.1
        let actionBarTint = colorScheme == .light ? 0.36 : 0.16
        let actionBarStroke = colorScheme == .light
            ? (reduceTransparency ? 0.18 : 0.14)
            : (reduceTransparency ? 0.15 : 0.25)
        let actionBarShadow = isGlassNavEnabled ? 0.3 : 0.2
        return GlassBackground(
            cornerRadius: 14,
            fillOpacity: actionBarFill,
            strokeOpacity: actionBarStroke,
            shadowOpacity: actionBarShadow,
            shadowRadius: 12,
            shadowY: 6,
            tintOpacity: actionBarTint,
            isInteractive: true
        )
    }

    private var navDividerColor: Color {
        if colorScheme == .light {
            return Color.black.opacity(reduceTransparency ? 0.14 : 0.1)
        }
        return Color.white.opacity(reduceTransparency ? 0.2 : 0.12)
    }


    private var selectedSummaryState: ThreadSummaryState? {
        guard let selectedNodeID = viewModel.selectedNodeID else {
            return nil
        }
        return viewModel.summaryState(for: selectedNodeID)
    }

    private var selectedGeneratedGraphTitle: String? {
        guard graphSettings.mode == .graph else { return nil }
        return graphViewModel.generatedGraphTitle(for: viewModel.selectedNodeID)
    }

    private var isSelectedGraphTitleRegenerating: Bool {
        guard graphSettings.mode == .graph else { return false }
        return graphViewModel.isRegeneratingGraphTitle(for: viewModel.selectedNodeID)
    }

    private var canRegenerateSelectedGraphTitle: Bool {
        guard graphSettings.mode == .graph else { return false }
        return graphViewModel.canRegenerateGraphTitle(for: viewModel.selectedNodeID)
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
                Text(NSLocalizedString("threadlist.backfill.confirm.exhaustive",
                                       comment: "Backfill confirmation exhaustive fetching explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var intervalDescription: String {
        let range = orderedRange
        return Self.intervalFormatter.string(from: range.start, to: range.end)
    }

    private var orderedRange: (start: Date, end: Date) {
        startDate <= endDate
            ? (startDate, endDate)
            : (endDate, startDate)
    }

    private static let intervalFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
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
            .accessibilityIdentifier(AccessibilityID.mailboxMoveAccountPicker)

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
                .accessibilityIdentifier(AccessibilityID.mailboxMoveSearchField)

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
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.card, style: .continuous)
                    .fill(cardFillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.card, style: .continuous)
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
                .accessibilityIdentifier(AccessibilityID.mailboxMoveCancelButton)

                Button(submitButtonTitle) {
                    submit()
                }
                .controlSize(.small)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AccessibilityID.mailboxMoveSubmitButton)
            }
        }
        .padding(14)
        .accessibilityIdentifier(AccessibilityID.mailboxMoveSheet)
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
        guard let mergedInterval = mergedVisibleRiskInterval else { return }
        backfillStartDate = mergedInterval.start
        backfillEndDate = Calendar.current.date(byAdding: .day,
                                                 value: -1,
                                                 to: mergedInterval.end) ?? mergedInterval.start
        isShowingBackfillConfirmation = true
    }

    func confirmBackfillWithOverrides() {
        let orderedRange = backfillStartDate <= backfillEndDate
            ? DateInterval(start: backfillStartDate, end: backfillEndDate)
            : DateInterval(start: backfillEndDate, end: backfillStartDate)
        let calendar = Calendar.current
        let inclusiveEnd = calendar.date(byAdding: .day, value: 1, to: orderedRange.end) ?? orderedRange.end
        let inclusiveRange = DateInterval(start: orderedRange.start, end: inclusiveEnd)
        isShowingBackfillConfirmation = false
        viewModel.backfillVisibleRange(rangeOverride: inclusiveRange)
    }

    // MARK: - Keyboard Navigation

    private func handleCanvasNavigation(
        _ direction: ThreadCanvasViewModel.CanvasNavigationDirection
    ) -> KeyPress.Result {
        if graphSettings.mode == .graph {
            let graphDirection: GraphDirection
            switch direction {
            case .up:
                graphDirection = .up
            case .down:
                graphDirection = .down
            case .left:
                graphDirection = .left
            case .right:
                graphDirection = .right
            }
            guard let nextID = graphViewModel.nextSelection(from: viewModel.selectedNodeID,
                                                            direction: graphDirection) else {
                return .ignored
            }
            viewModel.selectNode(id: nextID)
            return .handled
        }
        let metrics = ThreadCanvasLayoutMetrics(
            zoom: displaySettings.currentZoom,
            dayCount: viewModel.dayWindowCount,
            columnWidthAdjustment: displaySettings.viewMode == .timeline
                ? ThreadTimelineLayoutConstants.summaryColumnExtraWidth : 0,
            showsDayAxis: viewModel.activeMailboxScope != .allFolders,
            textScale: displaySettings.textScale
        )
        let layout = viewModel.canvasLayout(metrics: metrics,
                                             viewMode: displaySettings.viewMode)
        viewModel.navigateToAdjacentNode(direction: direction, layout: layout)
        return .handled
    }

    private func handleEnterKey() -> KeyPress.Result {
        // Enter opens inspector for the selected node (selection triggers inspector)
        // If nothing selected, do nothing
        guard viewModel.selectedNodeID != nil else { return .ignored }
        return .handled
    }

    private func handleGraphKey(_ command: GraphKeyboardCommand) -> KeyPress.Result {
        guard graphSettings.mode == .graph else { return .ignored }
        switch command {
        case .snip:
            graphViewModel.toggleSnipMode()
        case .archive:
            graphViewModel.toggleArchiveMode()
        case .escape:
            graphViewModel.exitPruneMode()
        case .water:
            guard let threadID = graphViewModel.selectedGraphNodeID(for: viewModel.selectedNodeID),
                  graphViewModel.data.threadByID[threadID] != nil else { return .ignored }
            graphViewModel.water(threadID: threadID, settings: graphSettings)
        case .zoomIn:
            graphViewModel.zoomIn()
        case .zoomOut:
            graphViewModel.zoomOut()
        case .reset:
            graphViewModel.resetViewport()
        }
        return .handled
    }

}
