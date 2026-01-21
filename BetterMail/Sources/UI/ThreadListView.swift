import AppKit
import SwiftUI

struct ThreadListView: View {
    @ObservedObject var viewModel: ThreadCanvasViewModel
    @ObservedObject var settings: AutoRefreshSettings
    @ObservedObject var inspectorSettings: InspectorViewSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var navHeight: CGFloat = 96
    @State private var isShowingBackfillConfirmation = false
    @State private var backfillStartDate = Date()
    @State private var backfillEndDate = Date()
    @State private var backfillLimit: Int = 10
    @State private var isInspectorVisible = false

    private let navCornerRadius: CGFloat = 18
    private let navHorizontalPadding: CGFloat = 16
    private let navTopPadding: CGFloat = 12
    private let navBottomSpacing: CGFloat = 12
    private let navCanvasSpacing: CGFloat = 6
    private let inspectorWidth: CGFloat = 320

    var body: some View {
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
                         topInset: canvasTopPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, navHorizontalPadding)
    }

    @ViewBuilder
    private var inspectorOverlay: some View {
        if isInspectorVisible {
            if let selectedFolder = viewModel.selectedFolder {
                ThreadFolderInspectorView(folder: selectedFolder,
                                          onPreview: { title, color in
                                              viewModel.previewFolderEdits(id: selectedFolder.id,
                                                                           title: title,
                                                                           color: color)
                                          },
                                          onSave: { title, color in
                                              viewModel.saveFolderEdits(id: selectedFolder.id,
                                                                        title: title,
                                                                        color: color)
                                          },
                                          onCancel: {
                                              viewModel.clearFolderEdits(id: selectedFolder.id)
                                          })
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
                                    onOpenInMail: viewModel.openMessageInMail)
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
        isGlassNavEnabled ? Color.white : Color.primary
    }

    private var navSecondaryForegroundStyle: Color {
        isGlassNavEnabled ? Color.white.opacity(0.75) : Color.secondary
    }

    @ViewBuilder
    private var navBar: some View {
        if isGlassNavEnabled {
            navBarContent
                .colorScheme(.dark)
        } else {
            navBarContent
        }
    }

    private var navBarContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Threads")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
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
            HStack(spacing: 6) {
                Text("Limit")
                    .font(.caption)
                    .foregroundStyle(navSecondaryForegroundStyle)
                limitField
            }
            .fixedSize()
            refreshButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(navPrimaryForegroundStyle)
        .shadow(color: Color.black.opacity(isGlassNavEnabled ? 0.45 : 0), radius: 1.5, x: 0, y: 1)
        .background(navBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(reduceTransparency ? 0.2 : 0.12))
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
                    .font(.caption2)
                    .foregroundStyle(navSecondaryForegroundStyle)
            }
            if settings.isEnabled, let nextRefreshDate = viewModel.nextRefreshDate {
                Text("Next refresh: \(nextRefreshDate.formatted(date: .numeric, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(navSecondaryForegroundStyle)
            }
        }
    }

    @ViewBuilder
    private var limitField: some View {
        if isGlassNavEnabled {
            TextField("Limit", value: $viewModel.fetchLimit, format: .number)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.55))
                )
                .foregroundStyle(Color.white)
                .tint(Color.white)
                .frame(width: 60)
        } else {
            TextField("Limit", value: $viewModel.fetchLimit, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        let button = Button(action: { viewModel.refreshNow() }) {
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
                .overlay(shape.stroke(Color.white.opacity(0.3)))
        } else if #available(macOS 26, *) {
            shape
                .fill(Color.white.opacity(0.08))
                .glassEffect(
                    .regular
                        .tint(Color.white.opacity(0.2))
                        .interactive(),
                    in: .rect(cornerRadius: navCornerRadius)
                )
                .overlay(shape.stroke(Color.white.opacity(0.35)))
                .shadow(color: Color.black.opacity(0.25), radius: 16, y: 8)
        } else {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.9))
                .overlay(shape.stroke(Color.white.opacity(0.25)))
        }
    }

    private var selectionActionBar: some View {
        Group {
            if shouldShowActionBar {
                Group {
                    if viewModel.shouldShowSelectionActions {
                        HStack(spacing: 12) {
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("threadlist.selection.count", comment: "Selection count label"),
                                viewModel.selectedNodeIDs.count
                            ))
                            .font(.caption)
                            .foregroundStyle(navSecondaryForegroundStyle)
                            Spacer()
                            Button(action: { viewModel.groupSelectedMessages() }) {
                                Label(NSLocalizedString("threadlist.selection.group", comment: "Group selection button"),
                                      systemImage: "link")
                            }
                            .disabled(!viewModel.canGroupSelection)
                            Button(action: { viewModel.addFolderForSelection() }) {
                                Label(NSLocalizedString("threadlist.selection.add_folder", comment: "Add folder selection button"),
                                      systemImage: "folder")
                            }
                            .disabled(viewModel.selectedNodeIDs.isEmpty)
                            Button(action: { viewModel.ungroupSelectedMessages() }) {
                                Label(NSLocalizedString("threadlist.selection.ungroup", comment: "Ungroup selection button"),
                                      systemImage: "personalhotspot.slash")
                            }
                            .disabled(!viewModel.canUngroupSelection)
                            if shouldShowBackfillAction {
                                Button(action: { presentBackfillConfirmation() }) {
                                    Label(NSLocalizedString("threadlist.backfill.button",
                                                            comment: "Backfill visible days button"),
                                          systemImage: "tray.and.arrow.down")
                                }
                                .disabled(viewModel.isBackfilling)
                            }
                        }
                    } else {
                        HStack(spacing: 12) {
                            if shouldShowBackfillAction {
                                Button(action: { presentBackfillConfirmation() }) {
                                    Label(NSLocalizedString("threadlist.backfill.button",
                                                            comment: "Backfill visible days button"),
                                          systemImage: "tray.and.arrow.down")
                                }
                                .disabled(viewModel.isBackfilling)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: actionBarMaxWidth)
                .background(selectionActionBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(reduceTransparency ? 0.15 : 0.25))
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(isGlassNavEnabled ? 0.3 : 0.2), radius: 12, y: 6)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.2), value: shouldShowActionBar)
    }

    private var shouldShowBackfillAction: Bool {
        !viewModel.visibleEmptyDayIntervals.isEmpty
    }

    private var shouldShowActionBar: Bool {
        viewModel.shouldShowSelectionActions || shouldShowBackfillAction
    }

    private var actionBarMaxWidth: CGFloat? {
        viewModel.shouldShowSelectionActions ? 600 : nil
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
            shape
                .fill(Color.white.opacity(0.1))
                .glassEffect(
                    .regular
                        .tint(Color.white.opacity(0.16))
                        .interactive(),
                    in: .rect(cornerRadius: 14)
                )
        } else {
            shape.fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.86))
        }
    }

    private var selectedSummaryState: ThreadSummaryState? {
        guard let selectedNodeID = viewModel.selectedNodeID,
              let rootID = viewModel.rootID(containing: selectedNodeID) else {
            return nil
        }
        return viewModel.summaryState(for: rootID)
    }

    private var selectedSummaryExpansion: Binding<Bool>? {
        guard let selectedNodeID = viewModel.selectedNodeID,
              let rootID = viewModel.rootID(containing: selectedNodeID) else {
            return nil
        }
        return Binding(
            get: { viewModel.isSummaryExpanded(for: rootID) },
            set: { viewModel.setSummaryExpanded($0, for: rootID) }
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
