import AppKit
import SwiftUI
internal import os

internal struct ThreadCanvasView: View {
    @ObservedObject internal var viewModel: ThreadCanvasViewModel
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    internal let topInset: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var zoomScale: CGFloat = 1.0
    @State private var accumulatedZoom: CGFloat = 1.0
    @State private var rawScrollOffset: CGFloat = 0
    @State private var rawScrollOffsetX: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var activeDropFolderID: String?
    @State private var dropHighlightPulseToken: Int = 0
    @State private var isDropHighlightPulsing: Bool = false
    @State private var dragState: ThreadCanvasDragState?
    @State private var dragPreviewOpacity: Double = 0
    @State private var dragPreviewScale: CGFloat = 0.94
    private let headerSpacing: CGFloat = 0

    private let calendar = Calendar.current
    private static let headerTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    internal var body: some View {
        GeometryReader { proxy in
            let columnWidthAdjustment = displaySettings.viewMode == .timeline
                ? ThreadTimelineLayoutConstants.summaryColumnExtraWidth
                : 0
            let metrics = ThreadCanvasLayoutMetrics(zoom: zoomScale,
                                                    dayCount: viewModel.dayWindowCount,
                                                    columnWidthAdjustment: columnWidthAdjustment)
            let today = Date()
            let layout = viewModel.canvasLayout(metrics: metrics,
                                                viewMode: displaySettings.viewMode,
                                                today: today,
                                                calendar: calendar)
            let chromeData = folderChromeData(layout: layout, metrics: metrics, rawZoom: zoomScale)
            let readabilityMode = displaySettings.readabilityMode(for: zoomScale)
            let defaultHeaderHeight = FolderHeaderLayout.headerHeight(rawZoom: zoomScale,
                                                                     readabilityMode: readabilityMode)
            let headerStackHeight = chromeData.isEmpty
                ? 0
                : (chromeData.map { $0.headerTopOffset + $0.headerHeight }.max() ?? defaultHeaderHeight)
            let totalTopPadding = topInset + headerStackHeight + headerSpacing
            let effectiveViewportHeight = max(max(viewportHeight, proxy.size.height) - totalTopPadding, 1)
            let effectiveViewportWidth = max(viewportWidth, proxy.size.width)
            let visibleDayBuffer: CGFloat = 1
            let visibleColumnBuffer: CGFloat = 1
            let visibleYStart = max(0, rawScrollOffset - (metrics.dayHeight * visibleDayBuffer))
            let visibleYEnd = rawScrollOffset + effectiveViewportHeight + (metrics.dayHeight * visibleDayBuffer)
            let visibleXStart = max(0, rawScrollOffsetX - (metrics.columnWidth * visibleColumnBuffer))
            let visibleXEnd = rawScrollOffsetX + effectiveViewportWidth + (metrics.columnWidth * visibleColumnBuffer)
            let pinnedFolderIDs = viewModel.pinnedFolderIDs
            let visibleDays = layout.days.filter { day in
                let dayStart = day.yOffset
                let dayEnd = day.yOffset + day.height
                return dayEnd >= visibleYStart && dayStart <= visibleYEnd
            }
            let visibleDayRange: ClosedRange<Int>? = {
                guard let minID = visibleDays.map(\.id).min(),
                      let maxID = visibleDays.map(\.id).max() else { return nil }
                return minID...maxID
            }()
            let visibleColumns = layout.columns.filter { column in
                let minX = column.xOffset
                let maxX = column.xOffset + metrics.columnWidth
                if let folderID = column.folderID, pinnedFolderIDs.contains(folderID) {
                    return true
                }
                return maxX >= visibleXStart && minX <= visibleXEnd
            }
            let visibleNodesByColumnID: [String: [ThreadCanvasNode]] = Dictionary(uniqueKeysWithValues: visibleColumns.map { column in
                let nodes: [ThreadCanvasNode]
                if let folderID = column.folderID, pinnedFolderIDs.contains(folderID) {
                    nodes = column.nodes
                } else {
                    nodes = column.nodes.filter { node in
                        if let visibleDayRange, !visibleDayRange.contains(node.dayIndex) {
                            return false
                        }
                        return node.frame.maxY >= visibleYStart && node.frame.minY <= visibleYEnd
                    }
                }
                return (column.id, nodes)
            })
            let visibleChromeData = chromeData.filter { chrome in
                let minX = chrome.frame.minX
                let maxX = chrome.frame.maxX
                let minY = chrome.frame.minY
                let maxY = chrome.frame.maxY
                if pinnedFolderIDs.contains(chrome.id) {
                    return true
                }
                let intersectsX = maxX >= visibleXStart && minX <= visibleXEnd
                let intersectsY = maxY >= visibleYStart && minY <= visibleYEnd
                return intersectsX && intersectsY
            }
            let visibleHeaderChromeData = chromeData.filter { chrome in
                let minX = chrome.frame.minX
                let maxX = chrome.frame.maxX
                if pinnedFolderIDs.contains(chrome.id) {
                    return true
                }
                return maxX >= visibleXStart && minX <= visibleXEnd
            }

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    dayBands(days: visibleDays,
                             metrics: metrics,
                             contentWidth: layout.contentSize.width)
                    folderColumnBackgroundLayer(chromeData: visibleChromeData,
                                                 metrics: metrics,
                                                 headerHeight: headerStackHeight + headerSpacing)
                    columnDividers(columns: visibleColumns, metrics: metrics, contentHeight: layout.contentSize.height)
                    connectorLayer(columns: visibleColumns,
                                   visibleNodesByColumnID: visibleNodesByColumnID,
                                    metrics: metrics,
                                    readabilityMode: readabilityMode,
                                    timelineTagsByNodeID: viewModel.timelineTagsByNodeID,
                                    contentHeight: layout.contentSize.height)
                    nodesLayer(columns: visibleColumns,
                               visibleNodesByColumnID: visibleNodesByColumnID,
                               metrics: metrics,
                               chromeData: chromeData,
                               readabilityMode: readabilityMode,
                               folderHeaderHeight: headerStackHeight + headerSpacing)
                    folderDropHighlightLayer(chromeData: visibleChromeData,
                                             metrics: metrics,
                                             headerHeight: headerStackHeight + headerSpacing)
                    dragPreviewLayer()
                    folderColumnHeaderLayer(chromeData: visibleHeaderChromeData,
                                            metrics: metrics,
                                            rawZoom: zoomScale,
                                            readabilityMode: readabilityMode)
                        .offset(y: -(headerStackHeight + headerSpacing))
                    folderHeaderHitTargets(chromeData: visibleHeaderChromeData, metrics: metrics)
                        .offset(y: -(headerStackHeight + headerSpacing))
                }
                .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
                .coordinateSpace(name: "ThreadCanvasContent")
                .padding(.top, totalTopPadding)
                .background(
                    GeometryReader { contentProxy in
                        let frame = contentProxy.frame(in: .named("ThreadCanvasScroll"))
                        let minY = frame.minY
                        let minX = frame.minX
                        Color.clear
                            .onChange(of: minY) { _, newValue in
                                let rawOffset = -newValue
                                rawScrollOffset = max(0, rawOffset)
                                let effectiveHeight = max(max(viewportHeight, proxy.size.height) - totalTopPadding, 1)
                                viewModel.scheduleVisibleDayRangeUpdate(scrollOffset: rawScrollOffset,
                                                                        viewportHeight: effectiveHeight,
                                                                        layout: layout,
                                                                        metrics: metrics,
                                                                        today: today,
                                                                        calendar: calendar)
                            }
                            .onChange(of: minX) { _, newValue in
                                let rawOffset = -newValue
                                rawScrollOffsetX = max(0, rawOffset)
                            }
                    }
                )
            }
            .scrollIndicators(.visible)
            .background(canvasBackground)
            .overlay(alignment: .topLeading) {
                floatingDateRail(layout: layout,
                                 metrics: metrics,
                                 readabilityMode: readabilityMode,
                                 totalTopPadding: totalTopPadding,
                                 rawScrollOffset: rawScrollOffset,
                                 viewportHeight: proxy.size.height,
                                 visibleYStart: visibleYStart,
                                 visibleYEnd: visibleYEnd)
            }
            .gesture(magnificationGesture)
            .coordinateSpace(name: "ThreadCanvasScroll")
            .background(
                GeometryReader { sizeProxy in
                    Color.clear.preference(key: ThreadCanvasViewportHeightPreferenceKey.self,
                                           value: sizeProxy.size.height)
                        .preference(key: ThreadCanvasViewportWidthPreferenceKey.self,
                                    value: sizeProxy.size.width)
                }
            )
            .onPreferenceChange(ThreadCanvasViewportHeightPreferenceKey.self) { height in
                let effectiveHeight = max(height, proxy.size.height) - totalTopPadding
                let clampedHeight = max(effectiveHeight, 1)
                viewportHeight = effectiveHeight
                viewModel.scheduleVisibleDayRangeUpdate(scrollOffset: rawScrollOffset,
                                                        viewportHeight: clampedHeight,
                                                        layout: layout,
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar,
                                                        immediate: true)
            }
            .onPreferenceChange(ThreadCanvasViewportWidthPreferenceKey.self) { width in
                viewportWidth = width
            }
            .onChange(of: layout.contentSize.height) { _, _ in
                viewModel.scheduleVisibleDayRangeUpdate(scrollOffset: rawScrollOffset,
                                                        viewportHeight: max(max(viewportHeight, proxy.size.height) - totalTopPadding, 1),
                                                        layout: layout,
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar,
                                                        immediate: true)
            }
            .onChange(of: activeDropFolderID) { oldValue, newValue in
                guard newValue != nil else {
                    isDropHighlightPulsing = false
                    return
                }
                if newValue != oldValue {
                    startDropHighlightPulse()
                }
            }
            .onAppear {
                accumulatedZoom = zoomScale
                displaySettings.updateCurrentZoom(zoomScale)
                viewModel.scheduleVisibleDayRangeUpdate(scrollOffset: rawScrollOffset,
                                                        viewportHeight: max(max(viewportHeight, proxy.size.height) - totalTopPadding, 1),
                                                        layout: layout,
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar,
                                                        immediate: true)
            }
            .onChange(of: zoomScale) { _, newValue in
                displaySettings.updateCurrentZoom(newValue)
            }
            .onHover { isInside in
                if !isInside {
                    cancelDrag()
                }
            }
            .onExitCommand {
                cancelDrag()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectNode(id: nil)
            viewModel.selectFolder(id: nil)
        }
    }

    private var canvasBackground: some View {
        if reduceTransparency {
            return Color(nsColor: NSColor.windowBackgroundColor).opacity(0.75)
        }
        return Color.clear
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoomScale = clampedZoom(accumulatedZoom * value)
            }
            .onEnded { value in
                let clamped = clampedZoom(accumulatedZoom * value)
                zoomScale = clamped
                accumulatedZoom = clamped
                Log.app.info("Zoom ended at: \(accumulatedZoom, format: .fixed(precision: 3))")
            }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, ThreadCanvasLayoutMetrics.minZoom), ThreadCanvasLayoutMetrics.maxZoom)
    }

    @ViewBuilder
    private func folderBackgroundLayer(layout: ThreadCanvasLayout,
                                       metrics: ThreadCanvasLayoutMetrics) -> some View {
        ForEach(layout.folderOverlays) { overlay in
            RoundedRectangle(cornerRadius: metrics.nodeCornerRadius * 1.4, style: .continuous)
                .fill(folderColor(overlay.color).opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.nodeCornerRadius * 1.4, style: .continuous)
                        .stroke(folderColor(overlay.color).opacity(0.22), lineWidth: 1)
                )
                .frame(width: overlay.frame.width, height: overlay.frame.height, alignment: .topLeading)
                .offset(x: overlay.frame.minX, y: overlay.frame.minY)
        }
    }

    @ViewBuilder
    private func folderColumnBackgroundLayer(chromeData: [FolderChromeData],
                                             metrics: ThreadCanvasLayoutMetrics,
                                             headerHeight: CGFloat) -> some View {
        let maxDepth = chromeData.map(\.depth).max() ?? 0
        let ordered = chromeData.sorted { $0.depth < $1.depth }
        ForEach(ordered) { chrome in
            let topExtension = max(headerHeight - chrome.headerTopOffset, 0)
            // Extend the background upward so it visually connects with the folder header.
            // Height also grows upward to cover the space between header and first day band.
            let extendedMinY = -(topExtension)
            let extendedHeight = chrome.frame.height + chrome.frame.minY + topExtension
            let expansion = folderHorizontalExpansion(for: chrome, maxDepth: maxDepth)
            let backgroundWidth = max(chrome.frame.width + (expansion * 2), metrics.columnWidth * 0.6)
            let backgroundMinX = chrome.frame.minX - expansion
            FolderColumnBackground(accentColor: accentColor(for: chrome.color),
                                   reduceTransparency: reduceTransparency,
                                   cornerRadius: metrics.nodeCornerRadius * 1.6)
                .frame(width: backgroundWidth,
                       height: extendedHeight,
                       alignment: .topLeading)
                .offset(x: backgroundMinX,
                        y: extendedMinY)
        }
    }

    @ViewBuilder
    private func folderDropHighlightLayer(chromeData: [FolderChromeData],
                                          metrics: ThreadCanvasLayoutMetrics,
                                          headerHeight: CGFloat) -> some View {
        let maxDepth = chromeData.map(\.depth).max() ?? 0
        ForEach(chromeData) { chrome in
            if activeDropFolderID == chrome.id {
                let dropFrame = folderDropFrame(for: chrome,
                                                headerHeight: headerHeight,
                                                maxDepth: maxDepth)
                RoundedRectangle(cornerRadius: metrics.nodeCornerRadius * 1.6, style: .continuous)
                    .stroke(accentColor(for: chrome.color).opacity(isDropHighlightPulsing ? 1.0 : 0.85),
                            lineWidth: isDropHighlightPulsing ? 4 : 3)
                    .frame(width: dropFrame.width, height: dropFrame.height, alignment: .topLeading)
                    .offset(x: dropFrame.minX, y: dropFrame.minY)
            }
        }
        .allowsHitTesting(false)
    }

    private func folderColumnHeaderLayer(chromeData: [FolderChromeData],
                                         metrics: ThreadCanvasLayoutMetrics,
                                         rawZoom: CGFloat,
                                         readabilityMode: ThreadCanvasReadabilityMode) -> some View {
        ZStack(alignment: .topLeading) {
            let maxDepth = chromeData.map(\.depth).max() ?? 0
            ForEach(chromeData.sorted { $0.depth < $1.depth }) { chrome in
                let headerFrame = folderHeaderFrame(for: chrome,
                                                    metrics: metrics,
                                                    maxDepth: maxDepth)
                FolderColumnHeader(title: chrome.title,
                                   unreadCount: chrome.unreadCount,
                                   updatedText: chrome.updated.map { Self.headerTimeFormatter.string(from: $0) },
                                   summaryState: chrome.summaryState,
                                   accentColor: accentColor(for: chrome.color),
                                   reduceTransparency: reduceTransparency,
                                   rawZoom: rawZoom,
                                   readabilityMode: readabilityMode,
                                   cornerRadius: metrics.nodeCornerRadius * 1.6,
                                   isPinned: viewModel.isFolderPinned(id: chrome.id),
                                   isSelected: viewModel.selectedFolderID == chrome.id)
                .frame(width: headerFrame.width, alignment: .leading)
                .offset(x: headerFrame.minX, y: headerFrame.minY)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func folderHeaderHitTargets(chromeData: [FolderChromeData],
                                        metrics: ThreadCanvasLayoutMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            let maxDepth = chromeData.map(\.depth).max() ?? 0
            ForEach(chromeData.sorted { $0.depth < $1.depth }) { chrome in
                let headerFrame = folderHeaderFrame(for: chrome,
                                                    metrics: metrics,
                                                    maxDepth: maxDepth)
                let isPinned = viewModel.isFolderPinned(id: chrome.id)
                Button {
                    viewModel.selectFolder(id: chrome.id)
                } label: {
                    Color.clear
                        .frame(width: headerFrame.width, height: headerFrame.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if isPinned {
                        Button {
                            viewModel.unpinFolder(id: chrome.id)
                        } label: {
                            Label(NSLocalizedString("threadcanvas.folder.menu.unpin",
                                                   comment: "Context menu action to unpin a folder"),
                                  systemImage: "pin.slash")
                        }
                    } else {
                        Button {
                            viewModel.pinFolder(id: chrome.id)
                        } label: {
                            Label(NSLocalizedString("threadcanvas.folder.menu.pin",
                                                   comment: "Context menu action to pin a folder"),
                                  systemImage: "pin")
                        }
                    }
                }
                .offset(x: headerFrame.minX, y: headerFrame.minY)
                .accessibilityLabel(chrome.title.isEmpty
                                    ? NSLocalizedString("threadcanvas.folder.inspector.accessibility",
                                                        comment: "Accessibility label for a folder header")
                                    : chrome.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(viewModel.selectedFolderID == chrome.id ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func dragPreviewLayer() -> some View {
        if let dragState {
            ThreadDragPreview(subject: dragState.subject, count: dragState.count)
                .scaleEffect(dragPreviewScale)
                .opacity(dragPreviewOpacity)
                .position(x: dragState.location.x, y: dragState.location.y)
                .allowsHitTesting(false)
        }
    }

    private func folderColor(_ color: ThreadFolderColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }

    private func accentColor(for folderColor: ThreadFolderColor) -> Color {
        let base = self.folderColor(folderColor)
        return base.opacity(reduceTransparency ? 1.0 : 0.95)
    }

    @ViewBuilder
    private func dayBands(days: [ThreadCanvasDay],
                          metrics: ThreadCanvasLayoutMetrics,
                          contentWidth: CGFloat) -> some View {
        ForEach(days) { day in
            ThreadCanvasDayBand(day: day,
                                metrics: metrics,
                                labelText: nil,
                                contentWidth: contentWidth)
                .offset(x: 0, y: day.yOffset)
        }
    }

    @ViewBuilder
    private func columnDividers(columns: [ThreadCanvasColumn],
                                metrics: ThreadCanvasLayoutMetrics,
                                contentHeight: CGFloat) -> some View {
        let lineColor = reduceTransparency ? Color.secondary.opacity(0.2) : Color.white.opacity(0.12)
        ForEach(columns) { column in
            Rectangle()
                .fill(lineColor)
                .frame(width: 1, height: contentHeight)
                .offset(x: column.xOffset + (metrics.columnWidth / 2), y: 0)
        }
    }

    @ViewBuilder
    private func connectorLayer(columns: [ThreadCanvasColumn],
                                visibleNodesByColumnID: [String: [ThreadCanvasNode]],
                                metrics: ThreadCanvasLayoutMetrics,
                                readabilityMode: ThreadCanvasReadabilityMode,
                                timelineTagsByNodeID: [String: [String]],
                                contentHeight: CGFloat) -> some View {
        ForEach(columns) { column in
            ThreadCanvasConnectorColumn(column: column,
                                        nodes: visibleNodesByColumnID[column.id] ?? [],
                                        metrics: metrics,
                                        viewMode: displaySettings.viewMode,
                                        readabilityMode: readabilityMode,
                                        timelineTagsByNodeID: timelineTagsByNodeID,
                                        isHighlighted: isColumnSelected(column),
                                        rawZoom: zoomScale)
            .frame(width: metrics.columnWidth, height: contentHeight, alignment: .topLeading)
            .offset(x: column.xOffset, y: 0)
        }
    }

    @ViewBuilder
    private func nodesLayer(columns: [ThreadCanvasColumn],
                            visibleNodesByColumnID: [String: [ThreadCanvasNode]],
                            metrics: ThreadCanvasLayoutMetrics,
                            chromeData: [FolderChromeData],
                            readabilityMode: ThreadCanvasReadabilityMode,
                            folderHeaderHeight: CGFloat) -> some View {
        ForEach(columns) { column in
            ForEach(visibleNodesByColumnID[column.id] ?? []) { node in
                Group {
                    if displaySettings.viewMode == .timeline {
                        ThreadTimelineCanvasNodeView(node: node,
                                                     summaryState: viewModel.summaryState(for: node.id),
                                                     tags: viewModel.timelineTags(for: node.id),
                                                     isSelected: viewModel.selectedNodeIDs.contains(node.id),
                                                     fontScale: metrics.fontScale,
                                                     readabilityMode: readabilityMode)
                            .task {
                                viewModel.requestTimelineTagsIfNeeded(for: ThreadNode(message: node.message))
                            }
                    } else {
                        ThreadCanvasNodeView(node: node,
                                             summaryState: viewModel.summaryState(for: node.id),
                                             isSelected: viewModel.selectedNodeIDs.contains(node.id),
                                             fontScale: metrics.fontScale,
                                             viewMode: displaySettings.viewMode,
                                             readabilityMode: readabilityMode)
                    }
                }
                    .frame(width: node.frame.width, height: node.frame.height)
                    .offset(x: node.frame.minX, y: node.frame.minY)
                    .gesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .named("ThreadCanvasContent"))
                            .onChanged { value in
                                updateDragState(node: node,
                                                column: column,
                                                location: value.location,
                                                chromeData: chromeData,
                                                folderHeaderHeight: folderHeaderHeight)
                            }
                            .onEnded { value in
                                finishDrag(location: value.location,
                                           chromeData: chromeData,
                                           folderHeaderHeight: folderHeaderHeight)
                            }
                    )
                    .onTapGesture {
                        viewModel.selectNode(id: node.id, additive: isCommandClick())
                    }
            }
        }
    }

    // MARK: - Drag helpers

    private func updateDragState(node: ThreadCanvasNode,
                                 column: ThreadCanvasColumn,
                                 location: CGPoint,
                                 chromeData: [FolderChromeData],
                                 folderHeaderHeight: CGFloat) {
        if dragState == nil {
            startDrag(node: node, column: column, location: location)
        }

        guard var dragState else { return }
        dragState.location = location
        self.dragState = dragState

        activeDropFolderID = folderHitTestID(at: location,
                                             chromeData: chromeData,
                                             headerHeight: folderHeaderHeight)
    }

    private func startDrag(node: ThreadCanvasNode,
                           column: ThreadCanvasColumn,
                           location: CGPoint) {
        let subject = latestSubject(in: column) ?? column.title
        let count = column.nodes.count
        let initialFolderID = viewModel.folderMembershipByThreadID[node.threadID]
        dragState = ThreadCanvasDragState(threadID: node.threadID,
                                          nodeID: node.id,
                                          subject: subject,
                                          count: count,
                                          initialFolderID: initialFolderID,
                                          location: location)
        dragPreviewOpacity = 0
        dragPreviewScale = 0.94
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            dragPreviewOpacity = 1
            dragPreviewScale = 1
        }
    }

    private func finishDrag(location: CGPoint,
                            chromeData: [FolderChromeData],
                            folderHeaderHeight: CGFloat) {
        guard let dragState else { return }
        let dropFolderID = folderHitTestID(at: location,
                                           chromeData: chromeData,
                                           headerHeight: folderHeaderHeight)
        if let dropFolderID {
            viewModel.moveThread(threadID: dragState.threadID, toFolderID: dropFolderID)
        } else if dragState.initialFolderID != nil {
            viewModel.removeThreadFromFolder(threadID: dragState.threadID)
        }
        endDrag()
    }

    private func cancelDrag() {
        guard dragState != nil else { return }
        endDrag()
    }

    private func endDrag() {
        activeDropFolderID = nil
        withAnimation(.easeOut(duration: 0.12)) {
            dragPreviewOpacity = 0
            dragPreviewScale = 0.96
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            dragState = nil
        }
    }

    private func startDropHighlightPulse() {
        dropHighlightPulseToken += 1
        let token = dropHighlightPulseToken
        withAnimation(.easeOut(duration: 0.12)) {
            isDropHighlightPulsing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            guard token == dropHighlightPulseToken else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                isDropHighlightPulsing = false
            }
        }
    }

    private func folderHitTestID(at location: CGPoint,
                                 chromeData: [FolderChromeData],
                                 headerHeight: CGFloat) -> String? {
        let maxDepth = chromeData.map(\.depth).max() ?? 0
        let ordered = chromeData.sorted { lhs, rhs in
            if lhs.depth == rhs.depth {
                return lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
            return lhs.depth > rhs.depth
        }
        for chrome in ordered {
            let frame = folderDropFrame(for: chrome,
                                        headerHeight: headerHeight,
                                        maxDepth: maxDepth)
            if frame.contains(location) {
                return chrome.id
            }
        }
        return nil
    }

    private func folderDropFrame(for chrome: FolderChromeData,
                                 headerHeight: CGFloat,
                                 maxDepth: Int) -> CGRect {
        let topExtension = max(headerHeight - chrome.headerTopOffset, 0)
        let extendedMinY = -(topExtension)
        let extendedHeight = chrome.frame.height + chrome.frame.minY + topExtension
        let expansion = folderHorizontalExpansion(for: chrome, maxDepth: maxDepth)
        return CGRect(x: chrome.frame.minX - expansion,
                      y: extendedMinY,
                      width: chrome.frame.width + (expansion * 2),
                      height: extendedHeight)
    }

    private func latestSubject(in column: ThreadCanvasColumn) -> String? {
        column.nodes.max(by: { $0.message.date < $1.message.date })?.message.subject
    }

    private func isColumnSelected(_ column: ThreadCanvasColumn) -> Bool {
        guard let selectedNodeID = viewModel.selectedNodeID else { return false }
        return column.nodes.contains(where: { $0.id == selectedNodeID })
    }

    private func isCommandClick() -> Bool {
        guard let flags = NSApp.currentEvent?.modifierFlags else { return false }
        return flags.contains(.command)
    }

    private func dayLabelMode(readabilityMode: ThreadCanvasReadabilityMode) -> DayLabelMode? {
        switch readabilityMode {
        case .detailed:
            return nil
        case .compact:
            return .month
        case .minimal:
            return .year
        }
    }

    private struct FolderHeaderMetrics {
        let height: CGFloat
        let indent: CGFloat
        let spacing: CGFloat
    }

    private func folderHeaderMetrics(metrics: ThreadCanvasLayoutMetrics,
                                     rawZoom: CGFloat,
                                     readabilityMode: ThreadCanvasReadabilityMode) -> FolderHeaderMetrics {
        let sizeScale = FolderHeaderLayout.sizeScale(rawZoom: rawZoom)
        let height = FolderHeaderLayout.headerHeight(rawZoom: rawZoom,
                                                     readabilityMode: readabilityMode)
        let indent = max(16 * metrics.fontScale, metrics.nodeHorizontalInset)
        let spacing = headerSpacing * sizeScale
        return FolderHeaderMetrics(height: height, indent: indent, spacing: spacing)
    }

    private func folderHeaderFrame(for chrome: FolderChromeData,
                                   metrics: ThreadCanvasLayoutMetrics,
                                   maxDepth: Int) -> CGRect {
        let expansion = folderHorizontalExpansion(for: chrome, maxDepth: maxDepth)
        let width = max(chrome.frame.width + (expansion * 2), metrics.columnWidth * 0.6)
        return CGRect(x: chrome.frame.minX - expansion,
                      y: chrome.headerTopOffset,
                      width: width,
                      height: chrome.headerHeight)
    }

    private func folderChromeData(layout: ThreadCanvasLayout,
                                  metrics: ThreadCanvasLayoutMetrics,
                                  rawZoom: CGFloat) -> [FolderChromeData] {
        let columnsByID = Dictionary(uniqueKeysWithValues: layout.columns.map { ($0.id, $0) })
        let headerMetrics = folderHeaderMetrics(metrics: metrics,
                                                rawZoom: rawZoom,
                                                readabilityMode: displaySettings.readabilityMode(for: rawZoom))
        return layout.folderOverlays.compactMap { overlay in
            let columns = overlay.columnIDs.compactMap { columnsByID[$0] }
            guard !columns.isEmpty else { return nil }
            let headerTopOffset = CGFloat(overlay.depth) * (headerMetrics.height + headerMetrics.spacing)
            let headerIndent = CGFloat(overlay.depth) * headerMetrics.indent
            let summaryState = viewModel.folderSummaryState(for: overlay.id)
            return folderChrome(for: overlay.id,
                                title: overlay.title,
                                color: overlay.color,
                                frame: overlay.frame,
                                columns: columns,
                                depth: overlay.depth,
                                summaryState: summaryState,
                                headerHeight: headerMetrics.height,
                                headerTopOffset: headerTopOffset,
                                headerIndent: headerIndent,
                                indentStep: headerMetrics.indent)
        }
    }

    private func folderChrome(for id: String,
                              title: String,
                              color: ThreadFolderColor,
                              frame: CGRect,
                              columns: [ThreadCanvasColumn],
                              depth: Int,
                              summaryState: ThreadSummaryState?,
                              headerHeight: CGFloat,
                              headerTopOffset: CGFloat,
                              headerIndent: CGFloat,
                              indentStep: CGFloat) -> FolderChromeData {
        let unread = columns.flatMap(\.nodes).reduce(0) { partial, node in
            partial + (node.message.isUnread ? 1 : 0)
        }
        let latest = columns.flatMap(\.nodes).map(\.message.date).max()
        return FolderChromeData(id: id,
                                title: title,
                                color: color,
                                frame: frame,
                                columnIDs: columns.map(\.id),
                                depth: depth,
                                summaryState: summaryState,
                                unreadCount: unread,
                                updated: latest,
                                headerHeight: headerHeight,
                                headerTopOffset: headerTopOffset,
                                headerIndent: headerIndent,
                                indentStep: indentStep)
    }

    private func folderHorizontalExpansion(for chrome: FolderChromeData,
                                           maxDepth: Int) -> CGFloat {
        let levelsAbove = max(0, maxDepth - chrome.depth)
        return CGFloat(levelsAbove) * chrome.indentStep
    }
    @ViewBuilder
    private func floatingDateRail(layout: ThreadCanvasLayout,
                                  metrics: ThreadCanvasLayoutMetrics,
                                  readabilityMode: ThreadCanvasReadabilityMode,
                                  totalTopPadding: CGFloat,
                                  rawScrollOffset: CGFloat,
                                  viewportHeight: CGFloat,
                                  visibleYStart: CGFloat,
                                  visibleYEnd: CGFloat) -> some View {
        let railWidth = metrics.dayLabelWidth
        ZStack(alignment: .topLeading) {
            if let mode = dayLabelMode(readabilityMode: readabilityMode) {
                let legendTopInset = max(8 * metrics.fontScale, metrics.nodeVerticalSpacing)
                let items = groupedLegendItems(days: layout.days, calendar: calendar, mode: mode)
                ForEach(Array(items.dropFirst().enumerated()), id: \.offset) { _, item in
                    let itemStart = item.startY
                    let itemEnd = item.startY + item.height
                    if itemEnd >= visibleYStart && itemStart <= visibleYEnd {
                        Rectangle()
                            .fill(legendGuideColor)
                            .frame(width: railWidth - metrics.nodeHorizontalInset, height: 1)
                            .offset(x: metrics.nodeHorizontalInset,
                                    y: item.startY + totalTopPadding - rawScrollOffset)
                    }
                }
                ForEach(items) { item in
                    let itemStart = item.startY
                    let itemEnd = item.startY + item.height
                    if itemEnd >= visibleYStart && itemStart <= visibleYEnd {
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(legendGuideColor)
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                            Text(item.label)
                                .font(.system(size: 13 * metrics.fontScale, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .rotationEffect(.degrees(-90))
                                .frame(width: max(item.height - legendTopInset, 0),
                                       alignment: .leading)
                                .frame(maxWidth: .infinity,
                                       maxHeight: .infinity,
                                       alignment: .topLeading)
                                .offset(y: legendTopInset)
                                .accessibilityAddTraits(.isHeader)
                                .allowsHitTesting(false)
                        }
                        .frame(width: railWidth - metrics.nodeHorizontalInset,
                               height: item.height,
                               alignment: .topLeading)
                        .offset(x: metrics.nodeHorizontalInset,
                                y: item.startY + totalTopPadding - rawScrollOffset)
                    }
                }
            } else {
                ForEach(layout.days) { day in
                    let dayStart = day.yOffset
                    let dayEnd = day.yOffset + day.height
                    if dayEnd >= visibleYStart && dayStart <= visibleYEnd {
                        Text(day.label)
                            .font(.system(size: 11 * metrics.fontScale, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: railWidth - metrics.nodeHorizontalInset, alignment: .trailing)
                            .padding(.leading, metrics.nodeHorizontalInset)
                            .padding(.top, metrics.nodeVerticalSpacing)
                            .offset(y: day.yOffset + totalTopPadding - rawScrollOffset)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .frame(width: railWidth, height: viewportHeight, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    private var legendGuideColor: Color {
        Color.secondary.opacity(0.35)
    }

    private func groupedLegendItems(days: [ThreadCanvasDay],
                                    calendar: Calendar,
                                    mode: DayLabelMode) -> [ThreadCanvasLegendItem] {
        let sorted = days.sorted { $0.id < $1.id }
        var items: [ThreadCanvasLegendItem] = []
        var currentKey: String?
        var currentLabel: String = ""
        var groupStartY: CGFloat = 0
        var groupEndY: CGFloat = 0
        var groupFirstHeight: CGFloat = 0

        func flushGroup() {
            guard let key = currentKey else { return }
            let height = groupEndY - groupStartY
            items.append(ThreadCanvasLegendItem(id: key,
                                                label: currentLabel,
                                                startY: groupStartY,
                                                height: height,
                                                firstDayHeight: groupFirstHeight))
        }

        for day in sorted {
            let components = calendar.dateComponents([.year, .month], from: day.date)
            let year = components.year ?? 0
            let month = components.month ?? 0
            let key: String
            let label: String
            switch mode {
            case .month:
                key = "\(year)-\(month)"
                label = ThreadCanvasDateHelper.monthLabel(for: day.date)
            case .year:
                key = "\(year)"
                label = ThreadCanvasDateHelper.yearLabel(for: day.date)
            }
            let dayStartY = day.yOffset
            let dayEndY = day.yOffset + day.height
            if key != currentKey {
                flushGroup()
                currentKey = key
                currentLabel = label
                groupStartY = dayStartY
                groupEndY = dayEndY
                groupFirstHeight = day.height
            } else {
                groupEndY = dayEndY
            }
        }
        flushGroup()
        return items
    }
}

private struct ThreadCanvasDayBand: View {
    let day: ThreadCanvasDay
    let metrics: ThreadCanvasLayoutMetrics
    let labelText: String?
    let contentWidth: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let isEven = day.id % 2 == 0
        let background = bandBackground(isEven: isEven)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(background)
            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)
                .padding(.leading, metrics.dayLabelWidth)
            if let labelText {
                Text(labelText)
                    .font(.system(size: 11 * metrics.fontScale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.dayLabelWidth - metrics.nodeHorizontalInset, alignment: .trailing)
                    .padding(.leading, metrics.nodeHorizontalInset)
                    .padding(.top, metrics.nodeVerticalSpacing)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .frame(width: contentWidth, height: day.height, alignment: .topLeading)
    }

    private func bandBackground(isEven: Bool) -> Color {
        if reduceTransparency {
            return Color(nsColor: NSColor.windowBackgroundColor)
        }
        return Color.white.opacity(isEven ? 0.02 : 0.05)
    }

    private var separatorColor: Color {
        reduceTransparency ? Color.secondary.opacity(0.25) : Color.white.opacity(0.08)
    }
}

private struct FolderColumnBackground: View {
    let accentColor: Color
    let reduceTransparency: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.92))
                .overlay(shape.stroke(accentColor.opacity(0.4)))
        } else {
            shape
                .fill(
                    LinearGradient(colors: [
                        accentColor.opacity(0.38),
                        accentColor.opacity(0.26)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    shape
                        .stroke(Color.white.opacity(0.08))
                        .blendMode(.screen)
                )
                .overlay(shape.stroke(accentColor.opacity(0.44)))
                .shadow(color: accentColor.opacity(0.28), radius: 16, y: 12)
        }
    }
}

private struct FolderHeaderLayout {
    static let titleBaseSize: CGFloat = 14
    static let titleLineLimit: Int = 2
    static let summaryBaseSize: CGFloat = 11
    static let summaryLineLimit: Int = 5
    static let footerBaseSize: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let lineSpacing: CGFloat = 6
    static let badgeVerticalPadding: CGFloat = 6
    static let badgeVerticalPaddingEllipsis: CGFloat = 5

    static func sizeScale(rawZoom: CGFloat) -> CGFloat {
        rawZoom.clamped(to: 0.6...1.25)
    }

    static func headerHeight(rawZoom: CGFloat,
                             readabilityMode: ThreadCanvasReadabilityMode) -> CGFloat {
        let scale = sizeScale(rawZoom: rawZoom)
        let titleHeight = titleSectionHeight(sizeScale: scale, readabilityMode: readabilityMode)
        let summaryHeight = summarySectionHeight(sizeScale: scale, readabilityMode: readabilityMode)
        let footerHeight = footerSectionHeight(sizeScale: scale, readabilityMode: readabilityMode)
        let visibleHeights = [titleHeight, summaryHeight, footerHeight].filter { $0 > 0 }
        let spacingCount = max(visibleHeights.count - 1, 0)
        let spacing = CGFloat(spacingCount) * lineSpacing * scale

        return (verticalPadding * 2 * scale) + visibleHeights.reduce(0, +) + spacing
    }

    static func lineHeight(baseSize: CGFloat, sizeScale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: baseSize * sizeScale)
        return font.ascender - font.descender + font.leading
    }

    static func lineCount(lineLimit: Int,
                          readabilityMode: ThreadCanvasReadabilityMode) -> Int {
        switch textVisibility(readabilityMode: readabilityMode) {
        case .normal:
            return lineLimit
        case .ellipsis:
            return 1
        case .hidden:
            return 0
        }
    }

    static func titleSectionHeight(sizeScale: CGFloat,
                                   readabilityMode: ThreadCanvasReadabilityMode) -> CGFloat {
        let titleLines = lineCount(lineLimit: titleLineLimit, readabilityMode: readabilityMode)
        return lineHeight(baseSize: titleBaseSize, sizeScale: sizeScale) * CGFloat(titleLines)
    }

    static func summarySectionHeight(sizeScale: CGFloat,
                                     readabilityMode: ThreadCanvasReadabilityMode) -> CGFloat {
        let summaryLines = lineCount(lineLimit: summaryLineLimit, readabilityMode: readabilityMode)
        return lineHeight(baseSize: summaryBaseSize, sizeScale: sizeScale) * CGFloat(summaryLines)
    }

    static func footerSectionHeight(sizeScale: CGFloat,
                                    readabilityMode: ThreadCanvasReadabilityMode) -> CGFloat {
        footerRowHeight(sizeScale: sizeScale, readabilityMode: readabilityMode)
    }

    static func footerRowHeight(sizeScale: CGFloat,
                                readabilityMode: ThreadCanvasReadabilityMode) -> CGFloat {
        let visibility = textVisibility(readabilityMode: readabilityMode)
        let lineHeight = lineHeight(baseSize: footerBaseSize, sizeScale: sizeScale)

        switch visibility {
        case .hidden:
            return 0
        case .ellipsis:
            let badgeHeight = lineHeight + 2 * badgeVerticalPaddingEllipsis * sizeScale
            return max(lineHeight, badgeHeight)
        case .normal:
            let badgeHeight = lineHeight + 2 * badgeVerticalPadding * sizeScale
            return max(lineHeight, badgeHeight)
        }
    }

    static func textVisibility(readabilityMode: ThreadCanvasReadabilityMode) -> TextVisibility {
        switch readabilityMode {
        case .detailed:
            return .normal
        case .compact:
            return .ellipsis
        case .minimal:
            return .hidden
        }
    }
}

private struct FolderColumnHeader: View {
    let title: String
    let unreadCount: Int
    let updatedText: String?
    let summaryState: ThreadSummaryState?
    let accentColor: Color
    let reduceTransparency: Bool
    let rawZoom: CGFloat
    let readabilityMode: ThreadCanvasReadabilityMode
    let cornerRadius: CGFloat
    let isPinned: Bool
    let isSelected: Bool

    private var sizeScale: CGFloat {
        // Track zoom more closely than the clamped fontScale to keep the header proportional.
        FolderHeaderLayout.sizeScale(rawZoom: rawZoom)
    }

    private var headerBackground: some View {
        let gradient = LinearGradient(colors: [
            accentColor.opacity(reduceTransparency ? 0.26 : 0.36),
            accentColor.opacity(reduceTransparency ? 0.22 : 0.30)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)

        let backgroundStyle: AnyShapeStyle = reduceTransparency
            ? AnyShapeStyle(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.9))
            : AnyShapeStyle(gradient)

        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(backgroundStyle)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.22))
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(accentColor.opacity(reduceTransparency ? 0.45 : 0.6))
                    .frame(height: 1)
            }
    }

    private var badgeBackground: some View {
        Capsule(style: .continuous)
            .fill(accentColor.opacity(reduceTransparency ? 0.28 : 0.4))
            .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.28)))
    }

    var body: some View {
        let titleVisibility = textVisibility()
        let summaryVisibility = textVisibility()
        let footerVisibility = textVisibility()
        let titleSectionHeight = FolderHeaderLayout.titleSectionHeight(sizeScale: sizeScale, readabilityMode: readabilityMode)
        let summarySectionHeight = FolderHeaderLayout.summarySectionHeight(sizeScale: sizeScale, readabilityMode: readabilityMode)
        let footerSectionHeight = FolderHeaderLayout.footerSectionHeight(sizeScale: sizeScale, readabilityMode: readabilityMode)

        VStack(alignment: .leading, spacing: FolderHeaderLayout.lineSpacing * sizeScale) {
            if titleSectionHeight > 0 {
                Group {
                    if titleVisibility != .hidden {
                        textLine(title.isEmpty
                                 ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing")
                                 : title,
                                 baseSize: FolderHeaderLayout.titleBaseSize,
                                 weight: .semibold,
                                 color: Color.white,
                                 allowWrap: true)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: titleSectionHeight, alignment: .topLeading)
            }
            if summarySectionHeight > 0 {
                Group {
                    if summaryVisibility != .hidden {
                        if let summaryText = summaryPreviewText {
                            summaryLine(summaryText)
                        } else {
                            Color.clear
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(height: summarySectionHeight, alignment: .topLeading)
            }
            if footerSectionHeight > 0 {
                Group {
                    if footerVisibility != .hidden {
                        HStack(alignment: .center, spacing: 10 * sizeScale) {
                            if let updatedText {
                                textLine("Updated \(updatedText)",
                                         baseSize: FolderHeaderLayout.footerBaseSize,
                                         weight: .regular,
                                         color: Color.white.opacity(0.78))
                            }
                            Spacer()
                            badge(unread: unreadCount)
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(height: footerSectionHeight, alignment: .leading)
            }
        }
        .padding(.horizontal, 12 * sizeScale)
        .padding(.vertical, FolderHeaderLayout.verticalPadding * sizeScale)
        .frame(height: FolderHeaderLayout.headerHeight(rawZoom: rawZoom,
                                                       readabilityMode: readabilityMode),
               alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(headerBackground)
        .overlay(alignment: .topTrailing) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12 * sizeScale, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.top, 8 * sizeScale)
                    .padding(.trailing, 10 * sizeScale)
                    .accessibilityHidden(true)
            }
        }
        .overlay(selectionOverlay)
        .shadow(color: accentColor.opacity(0.25), radius: 10, y: 6)
    }

    private var summaryPreviewText: String? {
        guard let summaryState else { return nil }
        if !summaryState.text.isEmpty {
            return summaryState.text
        }
        if !summaryState.statusMessage.isEmpty {
            return summaryState.statusMessage
        }
        return nil
    }

    @ViewBuilder
    private func textLine(_ text: String,
                          baseSize: CGFloat,
                          weight: Font.Weight,
                          color: Color,
                          allowWrap: Bool = false) -> some View {
        switch textVisibility() {
        case .normal:
            Text(text)
                .font(.system(size: baseSize * sizeScale, weight: weight))
                .foregroundStyle(color)
                .lineLimit(allowWrap ? FolderHeaderLayout.titleLineLimit : 1)
                .fixedSize(horizontal: false, vertical: allowWrap)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
        case .ellipsis:
            Text("…")
                .font(.system(size: baseSize * sizeScale, weight: weight))
                .foregroundStyle(color)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private func summaryLine(_ text: String) -> some View {
        switch textVisibility() {
        case .normal:
            summaryText(text)
                .font(.system(size: FolderHeaderLayout.summaryBaseSize * sizeScale, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(FolderHeaderLayout.summaryLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
        case .ellipsis:
            Text("…")
                .font(.system(size: FolderHeaderLayout.summaryBaseSize * sizeScale, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.8))
        case .hidden:
            EmptyView()
        }
    }

    private func summaryText(_ text: String) -> Text {
        if let attributed = markdownAttributed(text) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func markdownAttributed(_ text: String) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return try? AttributedString(markdown: text, options: options)
    }

    @ViewBuilder
    private func badge(unread: Int) -> some View {
        switch textVisibility() {
        case .hidden:
            EmptyView()
        case .ellipsis:
            Text("•")
                .font(.system(size: FolderHeaderLayout.footerBaseSize * sizeScale, weight: .semibold))
                .padding(.horizontal, 8 * sizeScale)
                .padding(.vertical, FolderHeaderLayout.badgeVerticalPaddingEllipsis * sizeScale)
                .background(badgeBackground)
                .foregroundStyle(Color.white.opacity(0.95))
                .contentShape(Capsule())
        case .normal:
            Text("Unread \(unread)")
                .font(.system(size: FolderHeaderLayout.footerBaseSize * sizeScale, weight: .semibold))
                .padding(.horizontal, 10 * sizeScale)
                .padding(.vertical, FolderHeaderLayout.badgeVerticalPadding * sizeScale)
                .background(badgeBackground)
                .foregroundStyle(Color.white.opacity(0.95))
                .contentShape(Capsule())
        }
    }

    private func textVisibility() -> TextVisibility {
        FolderHeaderLayout.textVisibility(readabilityMode: readabilityMode)
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(0.9), lineWidth: 1.8)
                .shadow(color: Color.accentColor.opacity(0.45), radius: 8)
        }
    }
}

private struct ThreadCanvasConnectorColumn: View {
    let column: ThreadCanvasColumn
    let nodes: [ThreadCanvasNode]
    let metrics: ThreadCanvasLayoutMetrics
    let viewMode: ThreadCanvasViewMode
    let readabilityMode: ThreadCanvasReadabilityMode
    let timelineTagsByNodeID: [String: [String]]
    let isHighlighted: Bool
    let rawZoom: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let segments = connectorSegments(for: nodes)

        ZStack(alignment: .topLeading) {
            ForEach(segments, id: \.id) { segment in
                connectorContent(segment)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(segments: segments))
    }

    private func connectorContent(_ segment: ConnectorSegment) -> some View {
        let manualShift = max(4, metrics.nodeWidth * 0.02)
        var localX: CGFloat
        var shift: CGFloat
        if viewMode == .timeline {
            localX = (segment.nodeMidX - column.xOffset).clamped(to: 0...metrics.columnWidth)
            shift = 0
        } else if segment.isManual {
            localX = metrics.columnWidth / 2
            shift = 0
        } else {
            // Convert the node’s global X into this column-local coordinate space.
            localX = (segment.nodeMidX - column.xOffset)
                .clamped(to: 0...metrics.columnWidth)
            // Push blue lanes away from the column center.
            let centerX = column.xOffset + (metrics.columnWidth / 2)
            shift = (segment.nodeMidX - centerX) >= 0 ? manualShift : -manualShift
        }

        return ZStack(alignment: .topLeading) {
            Path { path in
                // Draw JWZ connectors under their lane; manual connectors stay centered.
                path.move(to: CGPoint(x: localX + shift, y: segment.startY))
                path.addLine(to: CGPoint(x: localX + shift, y: segment.endY))
            }
            .stroke(
                segmentColor(for: segment),
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    dash: segment.isManual ? [4, 4] : []
                )
            )
            .shadow(color: segmentColor(for: segment), radius: glowRadius, x: 0, y: 0)

            if viewMode != .timeline {
                let circleScale = max(rawZoom, 0.05)
                let circleSize = lineWidth * 5.8 * circleScale
                Circle()
                    .fill(segmentColor(for: segment))
                    .frame(width: circleSize, height: circleSize)
                    .shadow(color: segmentColor(for: segment), radius: glowRadius)
                    .position(x: localX + shift, y: segment.endY - (lineWidth * 8.8 * circleScale) / 2)
            }
        }
    }

    private var lineWidth: CGFloat {
        isHighlighted ? 3 : 2.3
    }

    private var glowRadius: CGFloat {
        isHighlighted ? 2 : 1
    }

    private func segmentColor(for segment: ConnectorSegment) -> Color {
        let baseColor = segment.isManual ? manualConnectorColor : connectorColor
        return isHighlighted ? baseColor.opacity(1.0) : baseColor.opacity(0.7)
    }

    private var connectorColor: Color {
        if reduceTransparency {
            return Color.blue.opacity(0.35)
        }
        return Color.blue.opacity(0.55)
    }

    private var connectorGlowColor: Color {
        Color.accentColor.opacity(isHighlighted ? 0.9 : 0.65)
    }

    private var manualConnectorColor: Color {
        if reduceTransparency {
            return Color.red.opacity(0.68)
        }
        return Color.red.opacity(0.95)
    }

    private func connectorSegments(for nodes: [ThreadCanvasNode]) -> [ConnectorSegment] {
        let jwzThreadIDs = Array(Set(nodes.map(\.jwzThreadID))).sorted()
        let offsets = laneOffsets(for: jwzThreadIDs)
        let jwzSegments = jwzConnectorSegments(for: nodes, laneOffsets: offsets)
        let manualSegments = manualConnectorSegments(for: nodes)
        return jwzSegments + manualSegments
    }

    private func jwzConnectorSegments(for nodes: [ThreadCanvasNode],
                                      laneOffsets: [String: CGFloat]) -> [ConnectorSegment] {
        let grouped = Dictionary(grouping: nodes, by: \.jwzThreadID)
        let sortedKeys = grouped.keys.sorted()

        var segments: [ConnectorSegment] = []
        for (index, jwzThreadID) in sortedKeys.enumerated() {
            guard let groupNodes = grouped[jwzThreadID]?.sorted(by: { $0.frame.minY < $1.frame.minY }),
                  groupNodes.count > 1 else { continue }
            let laneOffset = laneOffsets[jwzThreadID] ?? 0
            segments.append(contentsOf: connectorSegments(for: groupNodes,
                                                         laneOffset: laneOffset,
                                                         segmentPrefix: "\(column.id)-\(index)",
                                                         isManual: false))
        }
        return segments
    }

    private func manualConnectorSegments(for nodes: [ThreadCanvasNode]) -> [ConnectorSegment] {
        let sortedNodes = nodes.sorted { $0.frame.minY < $1.frame.minY }
        guard sortedNodes.count > 1 else { return [] }

        var segments: [ConnectorSegment] = []

        for index in 1..<sortedNodes.count {
            let previous = sortedNodes[index - 1]
            let next = sortedNodes[index]
            let crossesThreads = previous.jwzThreadID != next.jwzThreadID
            let touchesManualAttachment = previous.isManualAttachment || next.isManualAttachment
            guard crossesThreads || touchesManualAttachment else { continue }

            let endpoints = connectorEndpoints(previous: previous, next: next)
            let startY = endpoints.startY
            let endY = endpoints.endY
            guard endY > startY else { continue }

            let midX = (anchorX(for: previous) + anchorX(for: next)) / 2
            segments.append(
                ConnectorSegment(
                    id: "\(column.id)-manual-\(index)",
                    startY: startY,
                    endY: endY,
                    nodeMidX: midX,
                    isManual: true
                )
            )
        }
        return segments
    }

    private func laneOffsets(for jwzThreadIDs: [String]) -> [String: CGFloat] {
        if viewMode == .timeline {
            return jwzThreadIDs.reduce(into: [:]) { $0[$1] = 0 }
        }
        guard jwzThreadIDs.count > 1 else {
            return jwzThreadIDs.reduce(into: [:]) { $0[$1] = 0 }
        }
        let laneSpacing = max(6 * metrics.fontScale, metrics.nodeWidth * 0.08)
        let totalWidth = laneSpacing * CGFloat(jwzThreadIDs.count - 1)
        let startOffset = -totalWidth / 2
        var offsets: [String: CGFloat] = [:]
        for (index, jwzThreadID) in jwzThreadIDs.enumerated() {
            offsets[jwzThreadID] = startOffset + laneSpacing * CGFloat(index)
        }
        return offsets
    }

    private func connectorSegments(for nodes: [ThreadCanvasNode],
                                   laneOffset: CGFloat,
                                   segmentPrefix: String,
                                   isManual: Bool) -> [ConnectorSegment] {
        guard nodes.count > 1 else { return [] }
        var segments: [ConnectorSegment] = []
        segments.reserveCapacity(nodes.count - 1)

        for index in 1..<nodes.count {
            let previous = nodes[index - 1]
            let next = nodes[index]

            let endpoints = connectorEndpoints(previous: previous, next: next)
            let startY = endpoints.startY
            let endY = endpoints.endY
            guard endY > startY else { continue }

            segments.append(
                ConnectorSegment(
                    id: "\(segmentPrefix)-\(index)",
                    startY: startY,
                    endY: endY,
                    nodeMidX: anchorX(for: previous, laneOffset: laneOffset),
                    isManual: isManual
                )
            )
        }
        return segments
    }

    private func accessibilityLabel(segments: [ConnectorSegment]) -> Text {
        let manualCount = segments.filter(\.isManual).count
        let jwzCount = segments.count - manualCount
        return Text(String.localizedStringWithFormat(
            NSLocalizedString("threadcanvas.connectors.accessibility", comment: "Accessibility label for thread connectors"),
            jwzCount,
            manualCount
        ))
    }

    private func anchorX(for node: ThreadCanvasNode, laneOffset: CGFloat = 0) -> CGFloat {
        let base: CGFloat
        if viewMode == .timeline {
            base = timelineDotCenterX(for: node)
        } else {
            base = node.frame.midX
        }
        return base + laneOffset
    }

    private func timelineDotCenterX(for node: ThreadCanvasNode) -> CGFloat {
        let padding = ThreadTimelineLayoutConstants.rowHorizontalPadding(fontScale: metrics.fontScale)
        let dotRadius = ThreadTimelineLayoutConstants.dotSize(fontScale: metrics.fontScale) / 2
        return node.frame.minX + padding + dotRadius
    }

    private func connectorEndpoints(previous: ThreadCanvasNode,
                                    next: ThreadCanvasNode) -> (startY: CGFloat, endY: CGFloat) {
        guard viewMode == .timeline else {
            return (previous.frame.maxY, next.frame.minY)
        }

        let previousEdges = timelineDotEdges(for: previous)
        let nextEdges = timelineDotEdges(for: next)
        let overlap = connectorDotOverlap
        return (previousEdges.bottom - overlap, nextEdges.top + overlap)
    }

    private func timelineDotEdges(for node: ThreadCanvasNode) -> (top: CGFloat, bottom: CGFloat) {
        let centerY = timelineDotCenterY(for: node)
        let radius = ThreadTimelineLayoutConstants.dotSize(fontScale: metrics.fontScale) / 2
        return (centerY - radius, centerY + radius)
    }

    private func timelineDotCenterY(for node: ThreadCanvasNode) -> CGFloat {
        let tags = timelineTagsByNodeID[node.id] ?? []
        let verticalPadding = ThreadTimelineLayoutConstants.rowVerticalPadding(fontScale: metrics.fontScale)
        let topLineHeight = timelineTopLineHeight(tags: tags)
        return node.frame.minY + verticalPadding + (topLineHeight / 2)
    }

    private func timelineTopLineHeight(tags: [String]) -> CGFloat {
        let fontScale = metrics.fontScale
        let textVisibility = timelineTextVisibility(readabilityMode: readabilityMode)
        let dotSize = ThreadTimelineLayoutConstants.dotSize(fontScale: fontScale)

        guard textVisibility == .normal else {
            return dotSize
        }

        let timeFont = NSFont.systemFont(ofSize: ThreadTimelineLayoutConstants.timeFontSize(fontScale: fontScale),
                                         weight: .semibold)
        let tagFont = NSFont.systemFont(ofSize: ThreadTimelineLayoutConstants.tagFontSize(fontScale: fontScale),
                                        weight: .semibold)
        let timeHeight = ceil(timeFont.ascender - timeFont.descender)
        let tagVerticalPadding = ThreadTimelineLayoutConstants.tagVerticalPadding(fontScale: fontScale)
        let visibleTags = tags.prefix(3)
        let tagHeight = visibleTags.isEmpty
            ? 0
            : ceil((tagFont.ascender - tagFont.descender) + (tagVerticalPadding * 2))

        return max(dotSize, timeHeight, tagHeight)
    }

    private var connectorDotOverlap: CGFloat {
        let scaled = 0.8 * metrics.fontScale
        return min(max(scaled, 0.5), 1.2)
    }
}

private struct ThreadCanvasViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ThreadCanvasViewportWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


private struct ConnectorSegment: Identifiable {
    let id: String
    let startY: CGFloat
    let endY: CGFloat
    let nodeMidX: CGFloat
    let isManual: Bool
}

private struct ThreadTimelineCanvasNodeView: View {
    let node: ThreadCanvasNode
    let summaryState: ThreadSummaryState?
    let tags: [String]
    let isSelected: Bool
    let fontScale: CGFloat
    let readabilityMode: ThreadCanvasReadabilityMode

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        let textVisibility = timelineTextVisibility(readabilityMode: readabilityMode)
        VStack(alignment: .leading, spacing: textVisibility == .normal ? summaryLineSpacing : 0) {
            HStack(alignment: .center, spacing: elementSpacing) {
                timelineDot

                if textVisibility == .normal {
                    Text(Self.timeFormatter.string(from: node.message.date))
                        .font(.system(size: timeFontSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: timeWidth, alignment: .leading)
                }

                if !tags.isEmpty {
                    HStack(alignment: .center, spacing: tagSpacing) {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            ThreadTimelineTagChip(text: tag, fontScale: fontScale)
                        }
                    }
                }
            }

            if textVisibility == .normal {
                Text(titleText)
                    .font(.system(size: summaryFontSize, weight: node.message.isUnread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, summaryIndent)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionBackground)
        .overlay(selectionOverlay)
        .contentShape(RoundedRectangle(cornerRadius: selectionCornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var titleText: String {
        let subject = node.message.subject.isEmpty
            ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing")
            : node.message.subject
        guard let summaryState else { return subject }
        let summaryText = summaryState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryText.isEmpty {
            return summaryText
        }
        let statusText = summaryState.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return statusText.isEmpty ? subject : statusText
    }

    private var selectionCornerRadius: CGFloat {
        ThreadTimelineLayoutConstants.selectionCornerRadius(fontScale: fontScale)
    }

    private var summaryFontSize: CGFloat {
        ThreadTimelineLayoutConstants.summaryFontSize(fontScale: fontScale)
    }

    private var timeFontSize: CGFloat {
        ThreadTimelineLayoutConstants.timeFontSize(fontScale: fontScale)
    }

    private var timeWidth: CGFloat {
        ThreadTimelineLayoutConstants.timeWidth(fontScale: fontScale)
    }

    private var elementSpacing: CGFloat {
        ThreadTimelineLayoutConstants.elementSpacing(fontScale: fontScale)
    }

    private var tagSpacing: CGFloat {
        ThreadTimelineLayoutConstants.tagSpacing(fontScale: fontScale)
    }

    private var summaryLineSpacing: CGFloat {
        ThreadTimelineLayoutConstants.summaryLineSpacing(fontScale: fontScale)
    }

    private var horizontalPadding: CGFloat {
        ThreadTimelineLayoutConstants.rowHorizontalPadding(fontScale: fontScale)
    }

    private var verticalPadding: CGFloat {
        ThreadTimelineLayoutConstants.rowVerticalPadding(fontScale: fontScale)
    }

    private var dotSize: CGFloat {
        ThreadTimelineLayoutConstants.dotSize(fontScale: fontScale)
    }

    private var summaryIndent: CGFloat {
        dotSize + elementSpacing
    }

    @ViewBuilder
    private var timelineDot: some View {
        Circle()
            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.7))
            .frame(width: dotSize, height: dotSize)
            .shadow(color: isSelected && !reduceTransparency ? Color.accentColor.opacity(0.4) : .clear,
                    radius: scaled(4))
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: selectionCornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(0.9), lineWidth: scaled(1.2))
                .shadow(color: Color.accentColor.opacity(0.35), radius: scaled(6))
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: selectionCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(reduceTransparency ? 0.18 : 0.12))
        }
    }

    private var accessibilityLabel: String {
        let tagText = tags.prefix(3).joined(separator: ", ")
        return [
            titleText,
            Self.timeFormatter.string(from: node.message.date),
            tagText
        ].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * fontScale
    }
}

internal func timelineTextVisibility(readabilityMode: ThreadCanvasReadabilityMode) -> TextVisibility {
    switch readabilityMode {
    case .detailed:
        return .normal
    case .compact, .minimal:
        return .hidden
    }
}

private struct ThreadTimelineTagChip: View {
    let text: String
    let fontScale: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 8 * fontScale, weight: .semibold))
            .lineLimit(1)
            .clipped()
            .padding(.vertical, 3 * fontScale)
            .padding(.horizontal, 6 * fontScale)
            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.28), lineWidth: 0.6 * fontScale))
            .foregroundStyle(Color.accentColor)
    }
}

private struct ThreadCanvasNodeView: View {
    let node: ThreadCanvasNode
    let summaryState: ThreadSummaryState?
    let isSelected: Bool
    let fontScale: CGFloat
    let viewMode: ThreadCanvasViewMode
    let readabilityMode: ThreadCanvasReadabilityMode

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            textLine(titleText,
                     baseSize: 13,
                     weight: node.message.isUnread ? .semibold : .regular,
                     color: primaryTextColor,
                     isTitleLine: true)
            textLine(node.message.from,
                     baseSize: 11,
                     weight: .regular,
                     color: secondaryTextColor,
                     isTitleLine: false)
            textLine(Self.timeFormatter.string(from: node.message.date),
                     baseSize: 11,
                     weight: .regular,
                     color: secondaryTextColor,
                     isTitleLine: false)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(nodeBackground)
        .overlay(selectionOverlay)
        .shadow(color: textShadowColor, radius: textShadowRadius, x: 0, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var subjectText: String {
        node.message.subject.isEmpty ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing") : node.message.subject
    }

    private var titleText: String {
        switch viewMode {
        case .default:
            return subjectText
        case .timeline:
            return summaryTitleText ?? subjectText
        }
    }

    private var summaryTitleText: String? {
        guard let summaryState else { return nil }
        let summaryText = summaryState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryText.isEmpty {
            return summaryText
        }
        let statusText = summaryState.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return statusText.isEmpty ? nil : statusText
    }

    private var cornerRadius: CGFloat {
        10 * fontScale
    }

    @ViewBuilder
    private var nodeBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.96))
                .overlay(shape.stroke(Color.white.opacity(0.22)))
        } else {
            shape
                .fill(
                    LinearGradient(colors: [
                        Color.black.opacity(0.55),
                        Color.black.opacity(0.42)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(shape.stroke(Color.white.opacity(0.12)))
                .shadow(color: Color.black.opacity(0.28), radius: 8, y: 6)
        }
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(0.9), lineWidth: 1.8)
                .shadow(color: Color.accentColor.opacity(0.45), radius: 8)
        }
    }

    private var accessibilityLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("threadcanvas.node.accessibility", comment: "Accessibility label for a node"),
            node.message.from,
            titleText,
            Self.timeFormatter.string(from: node.message.date)
        )
    }

    private var primaryTextColor: Color {
        Color.white.opacity(0.96)
    }

    private var secondaryTextColor: Color {
        Color.white.opacity(0.76)
    }

    private var textShadowColor: Color {
        guard !reduceTransparency, colorScheme == .dark else {
            return .clear
        }
        return Color.black.opacity(0.45)
    }

    private var textShadowRadius: CGFloat {
        (reduceTransparency || colorScheme == .light) ? 0 : 1
    }

    @ViewBuilder
    private func textLine(_ text: String,
                          baseSize: CGFloat,
                          weight: Font.Weight,
                          color: Color,
                          isTitleLine: Bool) -> some View {
        switch nodeTextVisibility(readabilityMode: readabilityMode, isTitleLine: isTitleLine) {
        case .normal:
            Text(text)
                .font(.system(size: baseSize * fontScale, weight: weight))
                .foregroundStyle(color)
                .lineLimit(1)
        case .ellipsis:
            Text("…")
                .font(.system(size: baseSize * fontScale, weight: weight))
                .foregroundStyle(color)
                .lineLimit(1)
        case .hidden:
            EmptyView()
        }
    }
}

// MARK: - Drag preview

private struct ThreadCanvasDragState: Equatable {
    let threadID: String
    let nodeID: String
    let subject: String
    let count: Int
    let initialFolderID: String?
    var location: CGPoint
}

private struct ThreadDragPreview: View {
    let subject: String
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subject.isEmpty ? NSLocalizedString("threadcanvas.subject.placeholder",
                                                     comment: "Placeholder subject when missing") : subject)
                .font(.headline)
            Text("\(count) message\(count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 6)
        )
    }
}

internal func nodeTextVisibility(readabilityMode: ThreadCanvasReadabilityMode,
                                 isTitleLine: Bool) -> TextVisibility {
    switch readabilityMode {
    case .detailed:
        return .normal
    case .compact:
        return isTitleLine ? .normal : .hidden
    case .minimal:
        return .hidden
    }
}

internal enum TextVisibility {
    case normal
    case ellipsis
    case hidden
}

private enum DayLabelMode {
    case month
    case year
}

private struct ThreadCanvasLegendItem: Identifiable {
    let id: String
    let label: String
    let startY: CGFloat
    let height: CGFloat
    let firstDayHeight: CGFloat
}

private struct FolderChromeData: Identifiable {
    let id: String
    let title: String
    let color: ThreadFolderColor
    let frame: CGRect
    let columnIDs: [String]
    let depth: Int
    let summaryState: ThreadSummaryState?
    let unreadCount: Int
    let updated: Date?
    let headerHeight: CGFloat
    let headerTopOffset: CGFloat
    let headerIndent: CGFloat
    let indentStep: CGFloat
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#if DEBUG
// Preview helper for EmailMessage type used in previews.
private extension EmailMessage {
    static func preview(
        messageID: String = "<msg-1@example.com>",
        mailboxID: String = "inbox",
        accountName: String = "Preview Account",
        subject: String = "Quarterly Results and Strategy Update",
        from: String = "Alex Johnson",
        to: String = "You",
        date: Date = Date(),
        isUnread: Bool = true,
        snippet: String = "Highlights: Revenue up 12% QoQ, margin expansion continues.",
        inReplyTo: String = "",
        references: [String] = ["<ref-1@example.com>", "<ref-2@example.com>"]
    ) -> EmailMessage {
        EmailMessage(
            messageID: messageID,
            mailboxID: mailboxID,
            accountName: accountName,
            subject: subject,
            from: from,
            to: to,
            date: date,
            snippet: snippet,
            isUnread: isUnread,
            inReplyTo: inReplyTo,
            references: references
        )
    }
}
#endif

#Preview("ThreadTimelineTagChip") {
    ThreadTimelineTagChip(text: "Important", fontScale: 1.0)
}

#Preview("ThreadTimelineCanvasNodeView") {
    let message = EmailMessage.preview()
    let node = ThreadCanvasNode(
        id: "node-1",
        message: message,
        threadID: "thread-1",
        jwzThreadID: "jwz-1",
        frame: CGRect(x: 0, y: 0, width: 400, height: 80),
        dayIndex: 0,
        isManualAttachment: false
    )
    ThreadTimelineCanvasNodeView(
        node: node,
        summaryState: nil,
        tags: ["Finance", "Q1", "Update"],
        isSelected: true,
        fontScale: 1.0,
        readabilityMode: .detailed
    )
}
