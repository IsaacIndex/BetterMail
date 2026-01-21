import AppKit
import SwiftUI

struct ThreadCanvasView: View {
    @ObservedObject var viewModel: ThreadCanvasViewModel
    let topInset: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var zoomScale: CGFloat = 1.0
    @State private var accumulatedZoom: CGFloat = 1.0
    @State private var scrollOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var activeDropFolderID: String?
    @State private var dropHighlightPulseToken: Int = 0
    @State private var isDropHighlightPulsing: Bool = false
    @State private var dragState: ThreadCanvasDragState?
    @State private var dragPreviewOpacity: Double = 0
    @State private var dragPreviewScale: CGFloat = 0.94
    private let headerSpacing: CGFloat = 0
    private let headerCardHeight: CGFloat = 104

    private let calendar = Calendar.current
    private static let headerTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        GeometryReader { proxy in
            let metrics = ThreadCanvasLayoutMetrics(zoom: zoomScale, dayCount: viewModel.dayWindowCount)
            let today = Date()
            let layout = viewModel.canvasLayout(metrics: metrics, today: today, calendar: calendar)
            let chromeData = folderChromeData(layout: layout, metrics: metrics, rawZoom: zoomScale)
            let headerStackHeight = chromeData.isEmpty
                ? 0
                : (chromeData.map { $0.headerTopOffset + $0.headerHeight }.max() ?? headerCardHeight)
            let totalTopPadding = topInset + headerStackHeight + headerSpacing

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    dayBands(layout: layout, metrics: metrics, rawZoom: zoomScale)
                    folderColumnBackgroundLayer(chromeData: chromeData,
                                                 metrics: metrics,
                                                 headerHeight: headerStackHeight + headerSpacing)
                    groupLegendLayer(layout: layout, metrics: metrics, rawZoom: zoomScale, calendar: calendar)
                    columnDividers(layout: layout, metrics: metrics)
                    connectorLayer(layout: layout, metrics: metrics)
                    nodesLayer(layout: layout,
                               metrics: metrics,
                               chromeData: chromeData,
                               folderHeaderHeight: headerStackHeight + headerSpacing)
                    folderDropHighlightLayer(chromeData: chromeData,
                                             metrics: metrics,
                                             headerHeight: headerStackHeight + headerSpacing)
                    dragPreviewLayer()
                    folderColumnHeaderLayer(chromeData: chromeData, metrics: metrics, rawZoom: zoomScale)
                        .offset(y: -(headerStackHeight + headerSpacing))
                }
                .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
                .coordinateSpace(name: "ThreadCanvasContent")
                .padding(.top, totalTopPadding)
                .background(
                    GeometryReader { contentProxy in
                        let minY = contentProxy.frame(in: .named("ThreadCanvasScroll")).minY
                        Color.clear
                            .onChange(of: minY) { _, newValue in
                                let rawOffset = -newValue
                                let adjustedOffset = max(0, rawOffset + totalTopPadding)
                                let effectiveHeight = max(max(viewportHeight, proxy.size.height) - totalTopPadding, 1)
                                scrollOffset = adjustedOffset
                                viewModel.updateVisibleDayRange(scrollOffset: adjustedOffset,
                                                                viewportHeight: effectiveHeight,
                                                                layout: layout,
                                                                metrics: metrics,
                                                                today: today,
                                                                calendar: calendar)
                            }
                    }
                )
            }
            .scrollIndicators(.visible)
            .background(canvasBackground)
            .gesture(magnificationGesture)
            .coordinateSpace(name: "ThreadCanvasScroll")
            .background(
                GeometryReader { sizeProxy in
                    Color.clear.preference(key: ThreadCanvasViewportHeightPreferenceKey.self,
                                           value: sizeProxy.size.height)
                }
            )
            .onPreferenceChange(ThreadCanvasViewportHeightPreferenceKey.self) { height in
                let effectiveHeight = max(height, proxy.size.height) - totalTopPadding
                let clampedHeight = max(effectiveHeight, 1)
                viewportHeight = effectiveHeight
                viewModel.updateVisibleDayRange(scrollOffset: scrollOffset,
                                                viewportHeight: clampedHeight,
                                                layout: layout,
                                                metrics: metrics,
                                                today: today,
                                                calendar: calendar)
            }
            .onChange(of: layout.contentSize.height) { _ in
                viewModel.updateVisibleDayRange(scrollOffset: scrollOffset,
                                                viewportHeight: max(max(viewportHeight, proxy.size.height) - totalTopPadding, 1),
                                                layout: layout,
                                                metrics: metrics,
                                                today: today,
                                                calendar: calendar)
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
                viewModel.updateVisibleDayRange(scrollOffset: scrollOffset,
                                                viewportHeight: max(max(viewportHeight, proxy.size.height) - totalTopPadding, 1),
                                                layout: layout,
                                                metrics: metrics,
                                                today: today,
                                                calendar: calendar)
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
//                Log.app.info("Zoom ended at: \(accumulatedZoom, format: .fixed(precision: 3))")
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
                                         rawZoom: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            let maxDepth = chromeData.map(\.depth).max() ?? 0
            ForEach(chromeData.sorted { $0.depth < $1.depth }) { chrome in
                let headerFrame = folderHeaderFrame(for: chrome,
                                                    metrics: metrics,
                                                    maxDepth: maxDepth)
                FolderColumnHeader(title: chrome.title,
                                   unreadCount: chrome.unreadCount,
                                   updatedText: chrome.updated.map { Self.headerTimeFormatter.string(from: $0) },
                                   accentColor: accentColor(for: chrome.color),
                                   reduceTransparency: reduceTransparency,
                                   rawZoom: rawZoom,
                                   cornerRadius: metrics.nodeCornerRadius * 1.6,
                                   fixedHeight: headerCardHeight)
                .frame(width: headerFrame.width, alignment: .leading)
                .offset(x: headerFrame.minX, y: headerFrame.minY)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
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
    private func dayBands(layout: ThreadCanvasLayout,
                          metrics: ThreadCanvasLayoutMetrics,
                          rawZoom: CGFloat) -> some View {
        let labelMap = dayLabelMap(days: layout.days, rawZoom: rawZoom, calendar: calendar)
        ForEach(layout.days) { day in
            ThreadCanvasDayBand(day: day,
                                metrics: metrics,
                                labelText: labelMap[day.id] ?? nil,
                                contentWidth: layout.contentSize.width)
                .offset(x: 0, y: day.yOffset)
        }
    }

    @ViewBuilder
    private func columnDividers(layout: ThreadCanvasLayout,
                                metrics: ThreadCanvasLayoutMetrics) -> some View {
        let lineColor = reduceTransparency ? Color.secondary.opacity(0.2) : Color.white.opacity(0.12)
        ForEach(layout.columns) { column in
            Rectangle()
                .fill(lineColor)
                .frame(width: 1, height: layout.contentSize.height)
                .offset(x: column.xOffset + (metrics.columnWidth / 2), y: 0)
        }
    }

    @ViewBuilder
    private func connectorLayer(layout: ThreadCanvasLayout,
                                metrics: ThreadCanvasLayoutMetrics) -> some View {
        ForEach(layout.columns) { column in
            ThreadCanvasConnectorColumn(column: column,
                                        metrics: metrics,
                                        isHighlighted: isColumnSelected(column),
                                        rawZoom: zoomScale)
            .frame(width: metrics.columnWidth, height: layout.contentSize.height, alignment: .topLeading)
            .offset(x: column.xOffset, y: 0)
        }
    }

    @ViewBuilder
    private func nodesLayer(layout: ThreadCanvasLayout,
                            metrics: ThreadCanvasLayoutMetrics,
                            chromeData: [FolderChromeData],
                            folderHeaderHeight: CGFloat) -> some View {
        ForEach(layout.columns) { column in
            ForEach(column.nodes) { node in
                ThreadCanvasNodeView(node: node,
                                     isSelected: viewModel.selectedNodeIDs.contains(node.id),
                                     fontScale: metrics.fontScale,
                                     rawZoom: zoomScale)
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

    private func dayLabelMap(days: [ThreadCanvasDay],
                             rawZoom: CGFloat,
                             calendar: Calendar) -> [Int: String?] {
        if dayLabelMode(rawZoom: rawZoom) == nil {
            return days.reduce(into: [:]) { result, day in
                result[day.id] = day.label
            }
        }
        return days.reduce(into: [:]) { result, day in
            result[day.id] = nil
        }
    }

    private func dayLabelMode(rawZoom: CGFloat) -> DayLabelMode? {
        let rawFontSize = 11 * rawZoom
        if rawFontSize >= ThreadCanvasNodeView.textEllipsisPointSize {
            return nil
        }
        if rawZoom >= 0.179 {
            return .month
        }
        return .year
    }

    private struct FolderHeaderMetrics {
        let height: CGFloat
        let indent: CGFloat
        let spacing: CGFloat
    }

    private func folderHeaderMetrics(metrics: ThreadCanvasLayoutMetrics,
                                     rawZoom: CGFloat) -> FolderHeaderMetrics {
        let sizeScale = rawZoom.clamped(to: 0.6...1.25)
        let height = headerCardHeight * sizeScale
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
        let headerMetrics = folderHeaderMetrics(metrics: metrics, rawZoom: rawZoom)
        return layout.folderOverlays.compactMap { overlay in
            let columns = overlay.columnIDs.compactMap { columnsByID[$0] }
            guard !columns.isEmpty else { return nil }
            let headerTopOffset = CGFloat(overlay.depth) * (headerMetrics.height + headerMetrics.spacing)
            let headerIndent = CGFloat(overlay.depth) * headerMetrics.indent
            return folderChrome(for: overlay.id,
                                title: overlay.title,
                                color: overlay.color,
                                frame: overlay.frame,
                                columns: columns,
                                depth: overlay.depth,
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
    private func groupLegendLayer(layout: ThreadCanvasLayout,
                                  metrics: ThreadCanvasLayoutMetrics,
                                  rawZoom: CGFloat,
                                  calendar: Calendar) -> some View {
        if let mode = dayLabelMode(rawZoom: rawZoom) {
            let legendTopInset = max(8 * metrics.fontScale, metrics.nodeVerticalSpacing)
            let items = groupedLegendItems(days: layout.days, calendar: calendar, mode: mode)
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.dropFirst().enumerated()), id: \.offset) { _, item in
                    Rectangle()
                        .fill(legendGuideColor)
                        .frame(width: metrics.dayLabelWidth - metrics.nodeHorizontalInset, height: 1)
                        .offset(x: metrics.nodeHorizontalInset, y: item.startY)
                }
                ForEach(items) { item in
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
                    .frame(width: metrics.dayLabelWidth - metrics.nodeHorizontalInset,
                           height: item.height,
                           alignment: .topLeading)
                    .offset(x: metrics.nodeHorizontalInset, y: item.startY)
                }
            }
        } else {
            EmptyView()
        }
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

private struct FolderColumnHeader: View {
    let title: String
    let unreadCount: Int
    let updatedText: String?
    let accentColor: Color
    let reduceTransparency: Bool
    let rawZoom: CGFloat
    let cornerRadius: CGFloat
    let fixedHeight: CGFloat

    private var sizeScale: CGFloat {
        // Track zoom more closely than the clamped fontScale to keep the header proportional.
        rawZoom.clamped(to: 0.6...1.25)
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
        VStack(alignment: .leading, spacing: 6 * sizeScale, ) {
            textLine(title.isEmpty
                     ? NSLocalizedString("threadcanvas.subject.placeholder", comment: "Placeholder subject when missing")
                     : title,
                     baseSize: 14,
                     weight: .semibold,
                     color: Color.white,
                     allowWrap: true)
//            Spacer(minLength: 8 * sizeScale)
            HStack(alignment: .center, spacing: 10 * sizeScale) {
                if let updatedText {
                    textLine("Updated \(updatedText)",
                             baseSize: 12,
                             weight: .regular,
                             color: Color.white.opacity(0.78))
                }
                Spacer()
                badge(unread: unreadCount)
            }
            
        }
        .padding(.horizontal, 12 * sizeScale)
        .padding(.vertical, 10 * sizeScale)
        .frame(height: fixedHeight * sizeScale, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(headerBackground)
        .shadow(color: accentColor.opacity(0.25), radius: 10, y: 6)
    }

    @ViewBuilder
    private func textLine(_ text: String,
                          baseSize: CGFloat,
                          weight: Font.Weight,
                          color: Color,
                          allowWrap: Bool = false) -> some View {
        switch textVisibility(for: baseSize) {
        case .normal:
            Text(text)
                .font(.system(size: baseSize * sizeScale, weight: weight))
                .foregroundStyle(color)
                .lineLimit(allowWrap ? 3 : 1)
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
    private func badge(unread: Int) -> some View {
        switch textVisibility(for: 12) {
        case .hidden:
            EmptyView()
        case .ellipsis:
            Text("•")
                .font(.system(size: 12 * sizeScale, weight: .semibold))
                .padding(.horizontal, 8 * sizeScale)
                .padding(.vertical, 5 * sizeScale)
                .background(badgeBackground)
                .foregroundStyle(Color.white.opacity(0.95))
                .contentShape(Capsule())
        case .normal:
            Text("Unread \(unread)")
                .font(.system(size: 12 * sizeScale, weight: .semibold))
                .padding(.horizontal, 10 * sizeScale)
                .padding(.vertical, 6 * sizeScale)
                .background(badgeBackground)
                .foregroundStyle(Color.white.opacity(0.95))
                .contentShape(Capsule())
        }
    }

    private func textVisibility(for baseSize: CGFloat) -> TextVisibility {
        let rawSize = baseSize * rawZoom
        if rawSize < ThreadCanvasNodeView.textHidePointSize {
            return .hidden
        }
        if rawSize < ThreadCanvasNodeView.textEllipsisPointSize {
            return .ellipsis
        }
        return .normal
    }
}

private struct ThreadCanvasConnectorColumn: View {
    let column: ThreadCanvasColumn
    let metrics: ThreadCanvasLayoutMetrics
    let isHighlighted: Bool
    let rawZoom: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let segments = connectorSegments(for: column.nodes)

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
        if segment.isManual {
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

            let circleScale = max(rawZoom, 0.05)
            let circleSize = lineWidth * 5.8 * circleScale
            Circle()
                .fill(segmentColor(for: segment))
                .frame(width: circleSize, height: circleSize)
                .shadow(color: segmentColor(for: segment), radius: glowRadius)
                .position(x: localX + shift, y: segment.endY - (lineWidth * 8.8 * circleScale) / 2)
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
        let gap = 0.0

        for index in 1..<sortedNodes.count {
            let previous = sortedNodes[index - 1]
            let next = sortedNodes[index]
            let crossesThreads = previous.jwzThreadID != next.jwzThreadID
            let touchesManualAttachment = previous.isManualAttachment || next.isManualAttachment
            guard crossesThreads || touchesManualAttachment else { continue }

            let startY = previous.frame.maxY + gap
            let endY = next.frame.minY - gap
            guard endY > startY else { continue }

            let midX = (previous.frame.midX + next.frame.midX) / 2
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

        // Keep the connector from touching the node cards.
        let gap = 0.0

        for index in 1..<nodes.count {
            let previous = nodes[index - 1]
            let next = nodes[index]

            let startY = previous.frame.maxY + gap
            let endY = next.frame.minY - gap
            guard endY > startY else { continue }

            segments.append(
                ConnectorSegment(
                    id: "\(segmentPrefix)-\(index)",
                    startY: startY,
                    endY: endY,
                    nodeMidX: previous.frame.midX + laneOffset,
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
}

private struct ThreadCanvasViewportHeightPreferenceKey: PreferenceKey {
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

private struct ThreadCanvasNodeView: View {
    static let textEllipsisPointSize: CGFloat = 10
    static let textHidePointSize: CGFloat = 7

    let node: ThreadCanvasNode
    let isSelected: Bool
    let fontScale: CGFloat
    let rawZoom: CGFloat

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
            textLine(subjectText,
                     baseSize: 13,
                     weight: node.message.isUnread ? .semibold : .regular,
                     color: primaryTextColor)
            textLine(node.message.from, baseSize: 11, weight: .regular, color: secondaryTextColor)
            textLine(Self.timeFormatter.string(from: node.message.date),
                     baseSize: 11,
                     weight: .regular,
                     color: secondaryTextColor)
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
            subjectText,
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
                          color: Color) -> some View {
        switch textVisibility(for: baseSize) {
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

    private func textVisibility(for baseSize: CGFloat) -> TextVisibility {
        let rawSize = baseSize * rawZoom
        if rawSize < Self.textHidePointSize {
            return .hidden
        }
        if rawSize < Self.textEllipsisPointSize {
            return .ellipsis
        }
        return .normal
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

private enum TextVisibility {
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
