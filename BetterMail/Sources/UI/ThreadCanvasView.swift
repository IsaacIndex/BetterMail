import AppKit
import SwiftUI
internal import os
import os.signpost

internal struct ThreadCanvasView: View {
    @ObservedObject internal var viewModel: ThreadCanvasViewModel
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    internal let topInset: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var zoomScale: CGFloat = 1.0
    @State private var accumulatedZoom: CGFloat = 1.0
    @State private var isMagnificationGestureActive = false
    @State private var activeDropFolderID: String?
    @State private var dropHighlightPulseToken: Int = 0
    @State private var isDropHighlightPulsing: Bool = false
    @State private var dragState: ThreadCanvasDragState?
    @State private var dragPreviewOpacity: Double = 0
    @State private var dragPreviewScale: CGFloat = 0.94
    @State private var suspendTimelineTagFetch = false
    private let headerSpacing: CGFloat = 0
    private let layoutZoomQuantizationStep: CGFloat = 0.025
    private let visibilityHysteresisPadding: CGFloat = 24
    private let nodeDragMinimumDistance: CGFloat = 14

    private let calendar = Calendar.current
    private static let headerTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy HH:mm"
        return formatter
    }()

    internal init(viewModel: ThreadCanvasViewModel,
                  displaySettings: ThreadCanvasDisplaySettings,
                  topInset: CGFloat) {
        self.viewModel = viewModel
        self.displaySettings = displaySettings
        self.topInset = topInset
        let initialZoom = min(max(displaySettings.currentZoom, ThreadCanvasLayoutMetrics.minZoom),
                              ThreadCanvasLayoutMetrics.maxZoom)
        _zoomScale = State(initialValue: initialZoom)
        _accumulatedZoom = State(initialValue: initialZoom)
    }

    fileprivate struct CanvasVisibilityState {
        let headerStackHeight: CGFloat
        let totalTopPadding: CGFloat
        let visibleYStart: CGFloat
        let visibleYEnd: CGFloat
        let visibleDays: [ThreadCanvasDay]
        let visibleColumns: [ThreadCanvasColumn]
        let visibleNodesByColumnID: [String: [ThreadCanvasNode]]
        let visibleChromeData: [FolderChromeData]
        let visibleHeaderChromeData: [FolderChromeData]
    }

    private struct VisibleNodePreparationStats {
        let totalNodeCount: Int
        let visibleNodeCount: Int
    }

    private struct FolderChromeCacheEntry {
        let ownerID: ObjectIdentifier
        let cacheKey: ThreadCanvasViewModel.FolderChromeCacheKey
        let headerMetrics: FolderHeaderMetrics
        let chromeData: [FolderChromeData]
    }

    private struct VisibleCanvasNodeData: Identifiable, Equatable {
        let node: ThreadCanvasNode
        let summaryState: ThreadSummaryState?
        let tags: [String]
        let isSelected: Bool
        let mailboxLabel: String?

        var id: String { node.id }
    }

    private struct VisibleFolderHeaderData: Identifiable, Equatable {
        let chrome: FolderChromeData
        let summaryPreviewText: String?
        let updatedText: String?
        let isPinned: Bool
        let isSelected: Bool
        let isJumping: Bool

        var id: String { chrome.id }

        static func == (lhs: VisibleFolderHeaderData, rhs: VisibleFolderHeaderData) -> Bool {
            lhs.chrome.id == rhs.chrome.id &&
            lhs.chrome.title == rhs.chrome.title &&
            lhs.chrome.color == rhs.chrome.color &&
            lhs.chrome.unreadCount == rhs.chrome.unreadCount &&
            lhs.chrome.mailboxLabel == rhs.chrome.mailboxLabel &&
            lhs.chrome.updated == rhs.chrome.updated &&
            lhs.chrome.headerHeight == rhs.chrome.headerHeight &&
            lhs.chrome.headerTopOffset == rhs.chrome.headerTopOffset &&
            lhs.chrome.headerIndent == rhs.chrome.headerIndent &&
            lhs.summaryPreviewText == rhs.summaryPreviewText &&
            lhs.updatedText == rhs.updatedText &&
            lhs.isPinned == rhs.isPinned &&
            lhs.isSelected == rhs.isSelected &&
            lhs.isJumping == rhs.isJumping
        }
    }

    private final class FolderChromeCacheBox {
        var entry: FolderChromeCacheEntry?
    }

    private struct FolderHeaderRenderCacheEntry {
        let ownerID: ObjectIdentifier
        let stateVersion: Int
        let chromeSignature: Int
        let data: [VisibleFolderHeaderData]
    }

    private final class FolderHeaderRenderCacheBox {
        var entry: FolderHeaderRenderCacheEntry?
    }

    private static let folderChromeCacheBox = FolderChromeCacheBox()
    private static let folderHeaderRenderCacheBox = FolderHeaderRenderCacheBox()

    fileprivate struct CanvasRenderContext {
        let metrics: ThreadCanvasLayoutMetrics
        let showsDayAxis: Bool
        let today: Date
        let layout: ThreadCanvasLayout
        let jumpAnchorVersion: Int
        let chromeData: [FolderChromeData]
        let readabilityMode: ThreadCanvasReadabilityMode
        let visibility: CanvasVisibilityState
        let totalTopPadding: CGFloat
        let viewportState: CanvasViewportState
    }

    fileprivate struct CanvasStaticContext {
        let metrics: ThreadCanvasLayoutMetrics
        let showsDayAxis: Bool
        let today: Date
        let layout: ThreadCanvasLayout
        let jumpAnchorVersion: Int
        let chromeData: [FolderChromeData]
        let readabilityMode: ThreadCanvasReadabilityMode
        let headerStackHeight: CGFloat
        let totalTopPadding: CGFloat
    }

    fileprivate struct CanvasViewportState: Equatable {
        let rawScrollOffset: CGFloat
        let rawScrollOffsetX: CGFloat
        let scrollOffset: CGFloat
        let viewportWidth: CGFloat
        let viewportHeight: CGFloat
        // Unquantized offsets used exclusively for overlay header positioning.
        // The main rawScrollOffset/X are quantized for performance (fewer visibility
        // recalculations), but the overlay header needs pixel-accurate values so it
        // stays aligned with the folder backgrounds inside the scroll view.
        let overlayScrollOffset: CGFloat
        let overlayScrollOffsetX: CGFloat
    }

    internal var body: some View {
        GeometryReader { proxy in
            canvasContent(proxy: proxy)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectNode(id: nil)
            viewModel.selectFolder(id: nil)
        }
    }

    @ViewBuilder
    private func canvasContent(proxy: GeometryProxy) -> some View {
        let staticContext = makeCanvasStaticContext(proxy: proxy)
        Self.ScrollViewportHost(
            viewModel: viewModel,
            displaySettings: displaySettings,
            staticContext: staticContext,
            proxySize: proxy.size,
            zoomScale: $zoomScale,
            accumulatedZoom: $accumulatedZoom,
            isMagnificationGestureActive: $isMagnificationGestureActive,
            activeDropFolderID: $activeDropFolderID,
            suspendTimelineTagFetch: $suspendTimelineTagFetch,
            canvasBackground: AnyView(canvasBackground),
            buildRenderContext: { viewportState in
                makeCanvasRenderContext(staticContext: staticContext,
                                        viewportState: viewportState,
                                        proxySize: proxy.size)
            },
            renderContent: { context in
                AnyView(canvasLayers(context: context))
            },
            renderOverlay: { context in
                AnyView(canvasOverlay(context: context, proxySize: proxy.size))
            },
            onStartDropHighlightPulse: {
                startDropHighlightPulse()
            },
            onCancelDrag: {
                cancelDrag()
            }
        )
    }

    private func makeCanvasStaticContext(proxy: GeometryProxy) -> CanvasStaticContext {
        let signpostID = OSSignpostID(log: Log.performance)
        os_signpost(.begin, log: Log.performance, name: "CanvasRenderContext", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Log.performance, name: "CanvasRenderContext", signpostID: signpostID)
        }
        let columnWidthAdjustment = displaySettings.viewMode == .timeline
            ? ThreadTimelineLayoutConstants.summaryColumnExtraWidth
            : 0
        let showsDayAxis = viewModel.activeMailboxScope != .allFolders
        let layoutZoomScale = quantized(zoomScale, step: layoutZoomQuantizationStep)
        let metrics = ThreadCanvasLayoutMetrics(zoom: layoutZoomScale,
                                                dayCount: viewModel.dayWindowCount,
                                                columnWidthAdjustment: columnWidthAdjustment,
                                                showsDayAxis: showsDayAxis,
                                                textScale: displaySettings.textScale)
        let today = Date()
        let layout = viewModel.canvasLayout(metrics: metrics,
                                            viewMode: displaySettings.viewMode,
                                            today: today,
                                            calendar: calendar)
        let jumpAnchorVersion = jumpAnchorVersion(for: layout)
        let chromeData = folderChromeData(layout: layout, metrics: metrics, rawZoom: zoomScale)
        let readabilityMode = displaySettings.readabilityMode(for: zoomScale)
        let defaultHeaderHeight = FolderHeaderLayout.headerHeight(rawZoom: zoomScale,
                                                                  textScale: displaySettings.textScale,
                                                                  readabilityMode: readabilityMode)
        let headerStackHeight = chromeData.isEmpty
            ? 0
            : (chromeData.map { $0.headerTopOffset + $0.headerHeight }.max() ?? defaultHeaderHeight)
        let totalTopPadding = topInset + headerStackHeight + headerSpacing
        return CanvasStaticContext(metrics: metrics,
                                   showsDayAxis: showsDayAxis,
                                   today: today,
                                   layout: layout,
                                   jumpAnchorVersion: jumpAnchorVersion,
                                   chromeData: chromeData,
                                   readabilityMode: readabilityMode,
                                   headerStackHeight: headerStackHeight,
                                   totalTopPadding: totalTopPadding)
    }

    private func makeCanvasRenderContext(staticContext: CanvasStaticContext,
                                         viewportState: CanvasViewportState,
                                         proxySize: CGSize) -> CanvasRenderContext {
        let visibility = canvasVisibilityState(staticContext: staticContext,
                                               viewportState: viewportState,
                                               proxySize: proxySize)
        let profilingSnapshot = viewModel.layoutProfilingSnapshot()
        let totalNodeCount = staticContext.layout.columns.reduce(into: 0) { partial, column in
            partial += column.nodes.count
        }
        os_signpost(.event,
                    log: Log.performance,
                    name: "CanvasRenderContextStats",
                    "scopeAllFolders=%{public}d columns=%{public}d totalNodes=%{public}d visibleColumns=%{public}d visibleNodes=%{public}d folderOverlays=%{public}d totalInvalidations=%{public}d sessionInvalidations=%{public}d scrollActive=%{public}d deferredInvalidation=%{public}d",
                    viewModel.activeMailboxScope == .allFolders ? 1 : 0,
                    staticContext.layout.columns.count,
                    totalNodeCount,
                    visibility.visibleColumns.count,
                    visibility.visibleNodesByColumnID.values.reduce(0) { $0 + $1.count },
                    staticContext.layout.folderOverlays.count,
                    profilingSnapshot.totalInvalidationCount,
                    profilingSnapshot.scrollSessionInvalidationCount,
                    profilingSnapshot.isAllFoldersScrollActive ? 1 : 0,
                    profilingSnapshot.hasDeferredEnrichmentInvalidation ? 1 : 0)
        return CanvasRenderContext(metrics: staticContext.metrics,
                                   showsDayAxis: staticContext.showsDayAxis,
                                   today: staticContext.today,
                                   layout: staticContext.layout,
                                   jumpAnchorVersion: staticContext.jumpAnchorVersion,
                                   chromeData: staticContext.chromeData,
                                   readabilityMode: staticContext.readabilityMode,
                                   visibility: visibility,
                                   totalTopPadding: staticContext.totalTopPadding,
                                   viewportState: viewportState)
    }

    @ViewBuilder
    private func canvasLayers(context: CanvasRenderContext) -> some View {
        let visibility = context.visibility
        dayBands(days: visibility.visibleDays,
                 metrics: context.metrics,
                 contentWidth: context.layout.contentSize.width)
        folderColumnBackgroundLayer(chromeData: visibility.visibleChromeData,
                                    metrics: context.metrics,
                                    headerHeight: visibility.headerStackHeight + headerSpacing)
        columnDividers(columns: visibility.visibleColumns,
                       metrics: context.metrics,
                       contentHeight: context.layout.contentSize.height)
        connectorLayer(columns: visibility.visibleColumns,
                       metrics: context.metrics,
                       readabilityMode: context.readabilityMode,
                       timelineTagsByNodeID: viewModel.timelineTagsByNodeID,
                       contentHeight: context.layout.contentSize.height)
        nodesLayer(columns: visibility.visibleColumns,
                   visibleNodesByColumnID: visibility.visibleNodesByColumnID,
                   metrics: context.metrics,
                   chromeData: context.chromeData,
                   readabilityMode: context.readabilityMode,
                   folderHeaderHeight: visibility.headerStackHeight + headerSpacing)
        folderDropHighlightLayer(chromeData: visibility.visibleChromeData,
                                 metrics: context.metrics,
                                 headerHeight: visibility.headerStackHeight + headerSpacing)
        dragPreviewLayer()
    }

    @ViewBuilder
    private func canvasOverlay(context: CanvasRenderContext,
                               proxySize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if context.showsDayAxis {
                floatingDateRail(layout: context.layout,
                                 metrics: context.metrics,
                                 readabilityMode: context.readabilityMode,
                                 totalTopPadding: context.totalTopPadding,
                                 rawScrollOffset: context.viewportState.rawScrollOffset,
                                 viewportHeight: proxySize.height,
                                 visibleYStart: context.visibility.visibleYStart,
                                 visibleYEnd: context.visibility.visibleYEnd)
            }
            folderColumnHeaderLayer(chromeData: context.visibility.visibleHeaderChromeData,
                                    metrics: context.metrics,
                                    rawScrollOffset: context.viewportState.overlayScrollOffset,
                                    rawScrollOffsetX: context.viewportState.overlayScrollOffsetX,
                                    rawZoom: zoomScale,
                                    readabilityMode: context.readabilityMode,
                                    topInset: topInset,
                                    totalTopPadding: context.totalTopPadding,
                                    folderHeaderHeight: context.visibility.headerStackHeight + headerSpacing)
        }
        .coordinateSpace(name: "ThreadCanvasOverlay")
    }

    private func canvasVisibilityState(staticContext: CanvasStaticContext,
                                       viewportState: CanvasViewportState,
                                       proxySize: CGSize) -> CanvasVisibilityState {
        let signpostID = OSSignpostID(log: Log.performance)
        os_signpost(.begin, log: Log.performance, name: "CanvasVisibilityState", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Log.performance, name: "CanvasVisibilityState", signpostID: signpostID)
        }
        let layout = staticContext.layout
        let metrics = staticContext.metrics
        let chromeData = staticContext.chromeData
        let headerStackHeight = staticContext.headerStackHeight
        let totalTopPadding = staticContext.totalTopPadding
        let effectiveViewportHeight = max(max(viewportState.viewportHeight, proxySize.height) - totalTopPadding, 1)
        let effectiveViewportWidth = max(max(viewportState.viewportWidth, proxySize.width), 1)
        let visibleDayBuffer: CGFloat = 1
        let visibleColumnBuffer: CGFloat = 1
        let visibleYStart = max(0, viewportState.rawScrollOffset - (metrics.dayHeight * visibleDayBuffer))
        let visibleYEnd = viewportState.rawScrollOffset + effectiveViewportHeight + (metrics.dayHeight * visibleDayBuffer)
        let stableVisibleYStart = max(0, visibleYStart - visibilityHysteresisPadding)
        let stableVisibleYEnd = visibleYEnd + visibilityHysteresisPadding
        let visibleXStart = max(0, viewportState.rawScrollOffsetX - (metrics.columnWidth * visibleColumnBuffer))
        let visibleXEnd = viewportState.rawScrollOffsetX + effectiveViewportWidth + (metrics.columnWidth * visibleColumnBuffer)
        let pinnedFolderIDs = viewModel.pinnedFolderIDs
        let shouldShowAllNodesInColumn = viewModel.activeMailboxScope == .allFolders
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
        let (visibleNodesByColumnID, nodeStats) = visibleNodesByColumnID(columns: visibleColumns,
                                                                         shouldShowAllNodesInColumn: shouldShowAllNodesInColumn,
                                                                         pinnedFolderIDs: pinnedFolderIDs,
                                                                         visibleDayRange: visibleDayRange,
                                                                         stableVisibleYStart: stableVisibleYStart,
                                                                         stableVisibleYEnd: stableVisibleYEnd)
        let visibleChromeData = visibleBodyChromeData(chromeData: chromeData,
                                                      visibleXStart: visibleXStart,
                                                      visibleXEnd: visibleXEnd,
                                                      stableVisibleYStart: stableVisibleYStart,
                                                      stableVisibleYEnd: stableVisibleYEnd,
                                                      pinnedFolderIDs: pinnedFolderIDs)
        let overlayByID = Dictionary(uniqueKeysWithValues: layout.folderOverlays.map { ($0.id, $0) })
        var alwaysVisibleHeaderFolderIDs = pinnedFolderIDs
        for pinnedFolderID in pinnedFolderIDs {
            var currentID = overlayByID[pinnedFolderID]?.parentID
            while let resolvedID = currentID {
                guard alwaysVisibleHeaderFolderIDs.contains(resolvedID) == false else { break }
                alwaysVisibleHeaderFolderIDs.insert(resolvedID)
                currentID = overlayByID[resolvedID]?.parentID
            }
        }
        let visibleHeaderChromeData = visibleHeaderChromeData(chromeData: chromeData,
                                                              visibleXStart: visibleXStart,
                                                              visibleXEnd: visibleXEnd,
                                                              stableVisibleYStart: stableVisibleYStart,
                                                              stableVisibleYEnd: stableVisibleYEnd,
                                                              alwaysVisibleHeaderFolderIDs: alwaysVisibleHeaderFolderIDs)
        os_signpost(.event,
                    log: Log.performance,
                    name: "CanvasVisibilityStats",
                    "columns=%{public}d visibleColumns=%{public}d totalNodes=%{public}d visibleNodes=%{public}d visibleDays=%{public}d visibleChrome=%{public}d visibleHeaders=%{public}d",
                    layout.columns.count,
                    visibleColumns.count,
                    nodeStats.totalNodeCount,
                    nodeStats.visibleNodeCount,
                    visibleDays.count,
                    visibleChromeData.count,
                    visibleHeaderChromeData.count)
        return CanvasVisibilityState(headerStackHeight: headerStackHeight,
                                     totalTopPadding: totalTopPadding,
                                     visibleYStart: visibleYStart,
                                     visibleYEnd: visibleYEnd,
                                     visibleDays: visibleDays,
                                     visibleColumns: visibleColumns,
                                     visibleNodesByColumnID: visibleNodesByColumnID,
                                     visibleChromeData: visibleChromeData,
                                     visibleHeaderChromeData: visibleHeaderChromeData)
    }

    private func visibleNodesByColumnID(columns: [ThreadCanvasColumn],
                                        shouldShowAllNodesInColumn: Bool,
                                        pinnedFolderIDs: Set<String>,
                                        visibleDayRange: ClosedRange<Int>?,
                                        stableVisibleYStart: CGFloat,
                                        stableVisibleYEnd: CGFloat) -> ([String: [ThreadCanvasNode]], VisibleNodePreparationStats) {
        let signpostID = OSSignpostID(log: Log.performance)
        os_signpost(.begin, log: Log.performance, name: "VisibleNodePreparation", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Log.performance, name: "VisibleNodePreparation", signpostID: signpostID)
        }

        var totalNodeCount = 0
        var visibleNodeCount = 0
        let visibleNodesByColumnID = Dictionary(uniqueKeysWithValues: columns.map { column in
            totalNodeCount += column.nodes.count
            let nodes: [ThreadCanvasNode]
            if shouldShowAllNodesInColumn {
                nodes = visibleNodes(in: column.nodes,
                                     minY: stableVisibleYStart,
                                     maxY: stableVisibleYEnd)
            } else if let folderID = column.folderID, pinnedFolderIDs.contains(folderID) {
                nodes = column.nodes
            } else {
                nodes = column.nodes.filter { node in
                    if let visibleDayRange, !visibleDayRange.contains(node.dayIndex) {
                        return false
                    }
                    return node.frame.maxY >= stableVisibleYStart && node.frame.minY <= stableVisibleYEnd
                }
            }
            visibleNodeCount += nodes.count
            return (column.id, nodes)
        })
        os_signpost(.event,
                    log: Log.performance,
                    name: "VisibleNodePreparationStats",
                    "columns=%{public}d totalNodes=%{public}d visibleNodes=%{public}d",
                    columns.count,
                    totalNodeCount,
                    visibleNodeCount)
        return (visibleNodesByColumnID,
                VisibleNodePreparationStats(totalNodeCount: totalNodeCount,
                                            visibleNodeCount: visibleNodeCount))
    }

    private func visibleBodyChromeData(chromeData: [FolderChromeData],
                                       visibleXStart: CGFloat,
                                       visibleXEnd: CGFloat,
                                       stableVisibleYStart: CGFloat,
                                       stableVisibleYEnd: CGFloat,
                                       pinnedFolderIDs: Set<String>) -> [FolderChromeData] {
        chromeData.filter { chrome in
            if pinnedFolderIDs.contains(chrome.id) {
                return true
            }
            let intersectsX = chrome.frame.maxX >= visibleXStart && chrome.frame.minX <= visibleXEnd
            let intersectsY = chrome.frame.maxY >= stableVisibleYStart && chrome.frame.minY <= stableVisibleYEnd
            return intersectsX && intersectsY
        }
    }

    private func visibleHeaderChromeData(chromeData: [FolderChromeData],
                                         visibleXStart: CGFloat,
                                         visibleXEnd: CGFloat,
                                         stableVisibleYStart: CGFloat,
                                         stableVisibleYEnd: CGFloat,
                                         alwaysVisibleHeaderFolderIDs: Set<String>) -> [FolderChromeData] {
        chromeData.filter { chrome in
            if alwaysVisibleHeaderFolderIDs.contains(chrome.id) {
                return true
            }
            let intersectsX = chrome.frame.maxX >= visibleXStart && chrome.frame.minX <= visibleXEnd
            let intersectsHeaderRange = chrome.headerTopOffset <= stableVisibleYEnd &&
                chrome.frame.maxY >= stableVisibleYStart
            return intersectsX && intersectsHeaderRange
        }
    }

    private func visibleNodes(in nodes: [ThreadCanvasNode],
                              minY: CGFloat,
                              maxY: CGFloat) -> [ThreadCanvasNode] {
        guard !nodes.isEmpty else { return [] }

        // All Folders columns are packed in ascending Y order, so find the visible
        // window boundaries instead of scanning every node on each scroll update.
        let startIndex = firstVisibleNodeIndex(in: nodes, minY: minY)
        guard startIndex < nodes.count else { return [] }
        let endIndex = firstNodeIndex(after: maxY, in: nodes)
        guard startIndex < endIndex else { return [] }
        return Array(nodes[startIndex..<endIndex])
    }

    private func firstVisibleNodeIndex(in nodes: [ThreadCanvasNode], minY: CGFloat) -> Int {
        var lowerBound = 0
        var upperBound = nodes.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if nodes[midpoint].frame.maxY < minY {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private func firstNodeIndex(after maxY: CGFloat, in nodes: [ThreadCanvasNode]) -> Int {
        var lowerBound = 0
        var upperBound = nodes.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if nodes[midpoint].frame.minY <= maxY {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private var canvasBackground: some View {
        if reduceTransparency {
            return Color(nsColor: NSColor.windowBackgroundColor).opacity(0.75)
        }
        return Color.clear
    }

    private func quantized(_ value: CGFloat, step: CGFloat) -> CGFloat {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private func jumpAnchorVersion(for layout: ThreadCanvasLayout) -> Int {
        var hasher = Hasher()
        hasher.combine(layout.columns.count)
        for column in layout.columns {
            hasher.combine(column.id)
            hasher.combine(column.nodes.count)
            hasher.combine(Int(column.latestDate.timeIntervalSinceReferenceDate))
        }
        return hasher.finalize()
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
        ForEach(chromeData) { chrome in
            let topExtension = max(headerHeight - chrome.headerTopOffset, 0)
            // Extend the background upward so it visually connects with the folder header.
            // Height also grows upward to cover the space between header and first day band.
            let extendedMinY = -(topExtension)
            let extendedHeight = chrome.frame.height + chrome.frame.minY + topExtension
            let backgroundWidth = max(chrome.frame.width, metrics.columnWidth * 0.6)
            FolderColumnBackground(accentColor: accentColor(for: chrome.color),
                                   reduceTransparency: reduceTransparency,
                                   cornerRadius: metrics.nodeCornerRadius * 1.6)
                .frame(width: backgroundWidth,
                       height: extendedHeight,
                       alignment: .topLeading)
                .offset(x: chrome.frame.minX,
                        y: extendedMinY)
        }
    }

    @ViewBuilder
    private func folderDropHighlightLayer(chromeData: [FolderChromeData],
                                          metrics: ThreadCanvasLayoutMetrics,
                                          headerHeight: CGFloat) -> some View {
        ForEach(chromeData) { chrome in
            if activeDropFolderID == chrome.id {
                let dropFrame = folderDropFrame(for: chrome,
                                                headerHeight: headerHeight)
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
                                         rawScrollOffset: CGFloat,
                                         rawScrollOffsetX: CGFloat,
                                         rawZoom: CGFloat,
                                         readabilityMode: ThreadCanvasReadabilityMode,
                                         topInset: CGFloat,
                                         totalTopPadding: CGFloat,
                                         folderHeaderHeight: CGFloat) -> some View {
        let headerData = visibleFolderHeaderData(chromeData: chromeData)
        return ZStack(alignment: .topLeading) {
            ForEach(headerData) { data in
                // Position in viewport/overlay coordinates so this layer can live outside the
                // ScrollView — no scroll counteraction needed, eliminating the quantization wiggle.
                let headerFrame = folderHeaderFrame(for: data.chrome, metrics: metrics)
                let maxSlideY = max(data.chrome.headerTopOffset, data.chrome.frame.maxY - data.chrome.headerHeight)
                let pinnedY = topInset + min(data.chrome.headerTopOffset, maxSlideY - rawScrollOffset)
                let pinnedX = headerFrame.minX - rawScrollOffsetX
                FolderColumnHeader(title: data.chrome.title,
                                   unreadCount: data.chrome.unreadCount,
                                   mailboxLabel: data.chrome.mailboxLabel,
                                   updatedText: data.updatedText,
                                   summaryPreviewText: data.summaryPreviewText,
                                   accentDescriptor: data.chrome.color,
                                   accentColor: accentColor(for: data.chrome.color),
                                   reduceTransparency: reduceTransparency,
                                   rawZoom: rawZoom,
                                   textScale: displaySettings.textScale,
                                   readabilityMode: readabilityMode,
                                   cornerRadius: metrics.nodeCornerRadius * 1.6,
                                   isPinned: data.isPinned,
                                   isSelected: data.isSelected,
                                   isJumping: data.isJumping,
                                   onSelect: { viewModel.selectFolder(id: data.chrome.id) },
                                   onPinToggle: {
                                       if data.isPinned {
                                           viewModel.unpinFolder(id: data.chrome.id)
                                       } else {
                                           viewModel.pinFolder(id: data.chrome.id)
                                       }
                                   },
                                   onJumpLatest: { viewModel.jumpToLatestNode(in: data.chrome.id) },
                                   onJumpFirst: { viewModel.jumpToFirstNode(in: data.chrome.id) })
                .equatable()
                .frame(width: headerFrame.width, alignment: .leading)
                .offset(x: pinnedX, y: pinnedY)
                .simultaneousGesture(
                    DragGesture(minimumDistance: nodeDragMinimumDistance, coordinateSpace: .named("ThreadCanvasOverlay"))
                        .onChanged { value in
                            // Convert overlay (viewport) coordinates to canvas content coordinates.
                            let canvasLocation = overlayToCanvasLocation(value.location,
                                                                         rawScrollOffset: rawScrollOffset,
                                                                         rawScrollOffsetX: rawScrollOffsetX,
                                                                         totalTopPadding: totalTopPadding)
                            updateFolderDragState(chrome: data.chrome,
                                                  location: canvasLocation,
                                                  chromeData: chromeData,
                                                  folderHeaderHeight: folderHeaderHeight)
                        }
                        .onEnded { value in
                            let canvasLocation = overlayToCanvasLocation(value.location,
                                                                         rawScrollOffset: rawScrollOffset,
                                                                         rawScrollOffsetX: rawScrollOffsetX,
                                                                         totalTopPadding: totalTopPadding)
                            finishDrag(location: canvasLocation,
                                       chromeData: chromeData,
                                       folderHeaderHeight: folderHeaderHeight)
                        }
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(data.chrome.title.isEmpty
                                    ? NSLocalizedString("threadcanvas.folder.inspector.accessibility",
                                                        comment: "Accessibility label for a folder header")
                                    : data.chrome.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(data.isSelected ? .isSelected : [])
            }
        }
    }

    private func overlayToCanvasLocation(_ overlayLocation: CGPoint,
                                         rawScrollOffset: CGFloat,
                                         rawScrollOffsetX: CGFloat,
                                         totalTopPadding: CGFloat) -> CGPoint {
        CGPoint(x: overlayLocation.x + rawScrollOffsetX,
                y: overlayLocation.y + rawScrollOffset - totalTopPadding)
    }

    private func visibleFolderHeaderData(chromeData: [FolderChromeData]) -> [VisibleFolderHeaderData] {
        let cacheOwnerID = ObjectIdentifier(viewModel)
        let stateVersion = viewModel.currentFolderHeaderStateVersion()
        let chromeSignature = folderHeaderDataSignature(chromeData: chromeData)
        if let cached = Self.folderHeaderRenderCacheBox.entry,
           cached.ownerID == cacheOwnerID,
           cached.stateVersion == stateVersion,
           cached.chromeSignature == chromeSignature {
            os_signpost(.event,
                        log: Log.performance,
                        name: "FolderHeaderRenderDataCacheHit",
                        "headers=%{public}d stateVersion=%{public}d",
                        cached.data.count,
                        stateVersion)
            return cached.data
        }
        let folderSummaries = viewModel.folderSummaries
        let pinnedFolderIDs = viewModel.pinnedFolderIDs
        let selectedFolderID = viewModel.selectedFolderID
        let folderJumpInProgressIDs = viewModel.folderJumpInProgressIDs

        let headerData = chromeData.map { chrome in
            VisibleFolderHeaderData(chrome: chrome,
                                    summaryPreviewText: folderSummaryPreviewText(folderSummaries[chrome.id]),
                                    updatedText: chrome.updated.map { Self.headerTimeFormatter.string(from: $0) },
                                    isPinned: pinnedFolderIDs.contains(chrome.id),
                                    isSelected: selectedFolderID == chrome.id,
                                    isJumping: folderJumpInProgressIDs.contains(chrome.id))
        }
        Self.folderHeaderRenderCacheBox.entry = FolderHeaderRenderCacheEntry(ownerID: cacheOwnerID,
                                                                             stateVersion: stateVersion,
                                                                             chromeSignature: chromeSignature,
                                                                             data: headerData)
        os_signpost(.event,
                    log: Log.performance,
                    name: "FolderHeaderRenderDataStats",
                    "headers=%{public}d stateVersion=%{public}d",
                    headerData.count,
                    stateVersion)
        return headerData
    }

    private func folderHeaderDataSignature(chromeData: [FolderChromeData]) -> Int {
        var hasher = Hasher()
        hasher.combine(chromeData.count)
        for chrome in chromeData {
            hasher.combine(chrome.id)
            hasher.combine(chrome.unreadCount)
            hasher.combine(chrome.depth)
            hasher.combine(chrome.color)
            hasher.combine(chrome.mailboxLabel)
            hasher.combine(chrome.updated?.timeIntervalSinceReferenceDate ?? 0)
        }
        return hasher.finalize()
    }

    private func folderSummaryPreviewText(_ summaryState: ThreadSummaryState?) -> String? {
        guard let summaryState else { return nil }
        let summaryText = summaryState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryText.isEmpty {
            return summaryText
        }
        let statusText = summaryState.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return statusText.isEmpty ? nil : statusText
    }

    @ViewBuilder
    private func dragPreviewLayer() -> some View {
        if let dragState {
            ThreadDragPreview(title: dragState.previewTitle, detail: dragState.previewDetail)
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
        let lineColor = reduceTransparency
            ? Color.secondary.opacity(0.2)
            : (colorScheme == .light ? Color.black.opacity(0.16) : Color.white.opacity(0.12))
        ForEach(columns) { column in
            Rectangle()
                .fill(lineColor)
                .frame(width: 1, height: contentHeight)
                .offset(x: column.xOffset + (metrics.columnWidth / 2), y: 0)
        }
    }

    @ViewBuilder
    private func connectorLayer(columns: [ThreadCanvasColumn],
                                metrics: ThreadCanvasLayoutMetrics,
                                readabilityMode: ThreadCanvasReadabilityMode,
                                timelineTagsByNodeID: [String: [String]],
                                contentHeight: CGFloat) -> some View {
        ForEach(columns) { column in
            ThreadCanvasConnectorColumn(column: column,
                                        // Use the full column node list so connectors remain continuous
                                        // across empty day ranges and viewport boundaries.
                                        nodes: column.nodes,
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
        let visibleNodeDataByColumnID = visibleNodeDataByColumnID(columns: columns,
                                                                  visibleNodesByColumnID: visibleNodesByColumnID)
        ForEach(columns) { column in
            ForEach(visibleNodeDataByColumnID[column.id] ?? []) { nodeData in
                Group {
                    if displaySettings.viewMode == .timeline {
                        ThreadTimelineCanvasNodeView(node: nodeData.node,
                                                     summaryState: nodeData.summaryState,
                                                     tags: nodeData.tags,
                                                     isSelected: nodeData.isSelected,
                                                     mailboxLabel: nodeData.mailboxLabel,
                                                     fontScale: metrics.fontScale,
                                                     readabilityMode: readabilityMode)
                            .equatable()
                            .onAppear {
                                guard !suspendTimelineTagFetch else { return }
                                viewModel.requestTimelineTagsIfNeeded(for: ThreadNode(message: nodeData.node.message))
                            }
                    } else {
                        ThreadCanvasNodeView(node: nodeData.node,
                                             summaryState: nodeData.summaryState,
                                             isSelected: nodeData.isSelected,
                                             isActionItem: viewModel.actionItemIDs.contains(nodeData.node.message.messageID),
                                             mailboxLabel: nodeData.mailboxLabel,
                                             fontScale: metrics.fontScale,
                                             viewMode: displaySettings.viewMode,
                                             readabilityMode: readabilityMode)
                            .equatable()
                    }
                }
                    .frame(width: nodeData.node.frame.width, height: nodeData.node.frame.height)
                    .position(x: nodeData.node.frame.midX, y: nodeData.node.frame.midY)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: nodeDragMinimumDistance, coordinateSpace: .named("ThreadCanvasContent"))
                            .onChanged { value in
                                updateDragState(node: nodeData.node,
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
                        viewModel.selectNode(id: nodeData.node.id, additive: isCommandClick())
                    }
                    .contextMenu {
                        let message = nodeData.node.message
                        let isActionItem = viewModel.actionItemIDs.contains(message.messageID)
                        let folderID = viewModel.folderMembershipByThreadID[nodeData.node.threadID]
                        let tags = nodeData.tags

                        Button {
                            if isActionItem {
                                viewModel.removeActionItem(message: message)
                            } else {
                                viewModel.addActionItem(message: message,
                                                        folderID: folderID,
                                                        tags: tags)
                            }
                        } label: {
                            Label(
                                isActionItem
                                    ? NSLocalizedString("threadcanvas.node.menu.remove_action_item",
                                                        comment: "Remove from Action Items")
                                    : NSLocalizedString("threadcanvas.node.menu.add_action_item",
                                                        comment: "Add to Action Items"),
                                systemImage: isActionItem ? "checkmark.circle.fill" : "bolt.circle"
                            )
                        }
                    }
            }
        }
    }

    private func visibleNodeDataByColumnID(columns: [ThreadCanvasColumn],
                                           visibleNodesByColumnID: [String: [ThreadCanvasNode]]) -> [String: [VisibleCanvasNodeData]] {
        let nodeSummaries = viewModel.nodeSummaries
        let timelineTagsByNodeID = viewModel.timelineTagsByNodeID
        let selectedNodeIDs = viewModel.selectedNodeIDs
        let mailboxIDs = Set(columns
            .flatMap { visibleNodesByColumnID[$0.id] ?? [] }
            .map(\.message.mailboxID))
        let mailboxLabelsByMailboxID = mailboxLeafNames(for: mailboxIDs)

        return Dictionary(uniqueKeysWithValues: columns.map { column in
            let nodeData = (visibleNodesByColumnID[column.id] ?? []).map { node in
                VisibleCanvasNodeData(node: node,
                                      summaryState: nodeSummaries[node.id],
                                      tags: timelineTagsByNodeID[node.id] ?? [],
                                      isSelected: selectedNodeIDs.contains(node.id),
                                      mailboxLabel: mailboxLabelsByMailboxID[node.message.mailboxID])
            }
            return (column.id, nodeData)
        })
    }

    private func mailboxLeafNames(for mailboxIDs: Set<String>) -> [String: String] {
        guard !mailboxIDs.isEmpty else { return [:] }
        var labelsByMailboxID: [String: String] = [:]
        labelsByMailboxID.reserveCapacity(mailboxIDs.count)
        for mailboxID in mailboxIDs {
            guard let leafName = MailboxPathFormatter.leafName(from: mailboxID),
                  !leafName.isEmpty else { continue }
            labelsByMailboxID[mailboxID] = leafName
        }
        return labelsByMailboxID
    }

    // MARK: - Drag helpers

    private func updateDragState(node: ThreadCanvasNode,
                                 column: ThreadCanvasColumn,
                                 location: CGPoint,
                                 chromeData: [FolderChromeData],
                                 folderHeaderHeight: CGFloat) {
        if dragState == nil {
            startThreadDrag(node: node, column: column, location: location)
        }

        guard var dragState else { return }
        dragState.location = location
        self.dragState = dragState

        let rawDropFolderID = folderHitTestID(at: location,
                                              chromeData: chromeData,
                                              headerHeight: folderHeaderHeight)
        activeDropFolderID = normalizedDropFolderID(rawDropFolderID, for: dragState)
    }

    private func updateFolderDragState(chrome: FolderChromeData,
                                       location: CGPoint,
                                       chromeData: [FolderChromeData],
                                       folderHeaderHeight: CGFloat) {
        if dragState == nil {
            startFolderDrag(chrome: chrome, location: location)
        }

        guard var dragState else { return }
        dragState.location = location
        self.dragState = dragState

        let rawDropFolderID = folderHitTestID(at: location,
                                              chromeData: chromeData,
                                              headerHeight: folderHeaderHeight)
        activeDropFolderID = normalizedDropFolderID(rawDropFolderID, for: dragState)
    }

    private func startThreadDrag(node: ThreadCanvasNode,
                                 column: ThreadCanvasColumn,
                                 location: CGPoint) {
        let subject = latestSubject(in: column) ?? column.title
        let count = column.nodes.count
        let initialFolderID = viewModel.folderMembershipByThreadID[node.threadID]
        dragState = ThreadCanvasDragState(payload: .thread(threadID: node.threadID,
                                                           initialFolderID: initialFolderID),
                                          previewTitle: subject,
                                          previewDetail: "\(count) message\(count == 1 ? "" : "s")",
                                          location: location)
        dragPreviewOpacity = 0
        dragPreviewScale = 0.94
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            dragPreviewOpacity = 1
            dragPreviewScale = 1
        }
    }

    private func startFolderDrag(chrome: FolderChromeData,
                                 location: CGPoint) {
        let title = chrome.title.isEmpty
            ? NSLocalizedString("threadcanvas.subject.placeholder",
                                comment: "Placeholder subject when missing")
            : chrome.title
        let count = chrome.columnIDs.count
        dragState = ThreadCanvasDragState(payload: .folder(folderID: chrome.id,
                                                           initialParentFolderID: viewModel.parentFolderID(for: chrome.id)),
                                          previewTitle: title,
                                          previewDetail: "\(count) thread\(count == 1 ? "" : "s")",
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
        let rawDropFolderID = folderHitTestID(at: location,
                                              chromeData: chromeData,
                                              headerHeight: folderHeaderHeight)
        let dropFolderID = normalizedDropFolderID(rawDropFolderID, for: dragState)

        switch dragState.payload {
        case let .thread(threadID, initialFolderID):
            if let dropFolderID {
                viewModel.moveThread(threadID: threadID, toFolderID: dropFolderID)
            } else if initialFolderID != nil {
                viewModel.removeThreadFromFolder(threadID: threadID)
            }
        case let .folder(folderID, initialParentFolderID):
            if let dropFolderID {
                viewModel.moveFolder(folderID: folderID, toParentFolderID: dropFolderID)
            } else if rawDropFolderID == nil, initialParentFolderID != nil {
                viewModel.removeFolderFromParent(folderID: folderID)
            }
        }
        endDrag()
    }

    private func normalizedDropFolderID(_ candidateFolderID: String?,
                                        for dragState: ThreadCanvasDragState) -> String? {
        switch dragState.payload {
        case .thread:
            return candidateFolderID
        case let .folder(folderID, _):
            guard let candidateFolderID else { return nil }
            return ThreadCanvasViewModel.applyFolderMove(folderID: folderID,
                                                         toParentFolderID: candidateFolderID,
                                                         folders: viewModel.threadFolders) == nil
                ? nil
                : candidateFolderID
        }
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
        let ordered = chromeData.sorted { lhs, rhs in
            if lhs.depth == rhs.depth {
                return lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
            return lhs.depth > rhs.depth
        }
        for chrome in ordered {
            let frame = folderDropFrame(for: chrome, headerHeight: headerHeight)
            if frame.contains(location) {
                return chrome.id
            }
        }
        return nil
    }

    private func folderDropFrame(for chrome: FolderChromeData,
                                 headerHeight: CGFloat) -> CGRect {
        let topExtension = max(headerHeight - chrome.headerTopOffset, 0)
        let extendedMinY = -(topExtension)
        let extendedHeight = chrome.frame.height + chrome.frame.minY + topExtension
        return CGRect(x: chrome.frame.minX,
                      y: extendedMinY,
                      width: chrome.frame.width,
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

    private struct FolderHeaderMetrics: Equatable {
        let height: CGFloat
        let indent: CGFloat
        let spacing: CGFloat
    }

    private func folderHeaderMetrics(metrics: ThreadCanvasLayoutMetrics,
                                     rawZoom: CGFloat,
                                     readabilityMode: ThreadCanvasReadabilityMode) -> FolderHeaderMetrics {
        let sizeScale = FolderHeaderLayout.sizeScale(rawZoom: rawZoom,
                                                     textScale: displaySettings.textScale)
        let height = FolderHeaderLayout.headerHeight(rawZoom: rawZoom,
                                                     textScale: displaySettings.textScale,
                                                     readabilityMode: readabilityMode)
        let indent = max(16 * metrics.fontScale, metrics.nodeHorizontalInset)
        let spacing = headerSpacing * sizeScale
        return FolderHeaderMetrics(height: height, indent: indent, spacing: spacing)
    }

    private func folderHeaderFrame(for chrome: FolderChromeData,
                                   metrics: ThreadCanvasLayoutMetrics) -> CGRect {
        let width = max(chrome.frame.width, metrics.columnWidth * 0.6)
        return CGRect(x: chrome.frame.minX,
                      y: chrome.headerTopOffset,
                      width: width,
                      height: chrome.headerHeight)
    }

    private func folderChromeData(layout: ThreadCanvasLayout,
                                  metrics: ThreadCanvasLayoutMetrics,
                                  rawZoom: CGFloat) -> [FolderChromeData] {
        let signpostID = OSSignpostID(log: Log.performance)
        os_signpost(.begin, log: Log.performance, name: "FolderChromeData", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Log.performance, name: "FolderChromeData", signpostID: signpostID)
        }
        let columnsByID = Dictionary(uniqueKeysWithValues: layout.columns.map { ($0.id, $0) })
        let headerMetrics = folderHeaderMetrics(metrics: metrics,
                                                rawZoom: rawZoom,
                                                readabilityMode: displaySettings.readabilityMode(for: rawZoom))
        let cacheOwnerID = ObjectIdentifier(viewModel)
        let cacheKey = viewModel.folderChromeCacheKey(metrics: metrics,
                                                      viewMode: displaySettings.viewMode,
                                                      today: Date(),
                                                      calendar: calendar)
        if let cached = Self.folderChromeCacheBox.entry,
           cached.ownerID == cacheOwnerID,
           cached.cacheKey == cacheKey,
           cached.headerMetrics == headerMetrics {
            os_signpost(.event,
                        log: Log.performance,
                        name: "FolderChromeDataCacheHit",
                        "folderOverlays=%{public}d chromeEntries=%{public}d columns=%{public}d",
                        layout.folderOverlays.count,
                        cached.chromeData.count,
                        layout.columns.count)
            return cached.chromeData
        }

        let mailboxLabelsByFolderID = viewModel.folderMailboxLeafNames(for: Set(layout.folderOverlays.map(\.id)))
        let chromeData: [FolderChromeData] = layout.folderOverlays.compactMap { overlay in
            let columns = overlay.columnIDs.compactMap { columnsByID[$0] }
            guard !columns.isEmpty else { return nil }
            let headerTopOffset = CGFloat(overlay.depth) * (headerMetrics.height + headerMetrics.spacing)
            let headerIndent = CGFloat(overlay.depth) * headerMetrics.indent
            return folderChrome(for: overlay.id,
                                title: overlay.title,
                                color: overlay.color,
                                frame: overlay.frame,
                                columns: columns,
                                mailboxLabel: mailboxLabelsByFolderID[overlay.id],
                                depth: overlay.depth,
                                headerHeight: headerMetrics.height,
                                headerTopOffset: headerTopOffset,
                                headerIndent: headerIndent,
                                indentStep: headerMetrics.indent)
        }
        .sorted {
            if $0.depth == $1.depth {
                return $0.frame.minX < $1.frame.minX
            }
            return $0.depth < $1.depth
        }
        Self.folderChromeCacheBox.entry = FolderChromeCacheEntry(ownerID: cacheOwnerID,
                                                                 cacheKey: cacheKey,
                                                                 headerMetrics: headerMetrics,
                                                                 chromeData: chromeData)
        os_signpost(.event,
                    log: Log.performance,
                    name: "FolderChromeDataStats",
                    "folderOverlays=%{public}d chromeEntries=%{public}d columns=%{public}d",
                    layout.folderOverlays.count,
                    chromeData.count,
                    layout.columns.count)
        return chromeData
    }

    private func folderChrome(for id: String,
                              title: String,
                              color: ThreadFolderColor,
                              frame: CGRect,
                              columns: [ThreadCanvasColumn],
                              mailboxLabel: String?,
                              depth: Int,
                              headerHeight: CGFloat,
                              headerTopOffset: CGFloat,
                              headerIndent: CGFloat,
                              indentStep: CGFloat) -> FolderChromeData {
        let unread = columns.reduce(0) { partial, column in
            partial + column.unreadCount
        }
        let latest = columns.map(\.latestDate).max()
        return FolderChromeData(id: id,
                                title: title,
                                color: color,
                                frame: frame,
                                columnIDs: columns.map(\.id),
                                depth: depth,
                                unreadCount: unread,
                                mailboxLabel: mailboxLabel,
                                updated: latest,
                                headerHeight: headerHeight,
                                headerTopOffset: headerTopOffset,
                                headerIndent: headerIndent,
                                indentStep: indentStep)
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

    private struct ScrollViewportHost: View {
        @ObservedObject var viewModel: ThreadCanvasViewModel
        @ObservedObject var displaySettings: ThreadCanvasDisplaySettings
        let staticContext: ThreadCanvasView.CanvasStaticContext
        let proxySize: CGSize
        @Binding var zoomScale: CGFloat
        @Binding var accumulatedZoom: CGFloat
        @Binding var isMagnificationGestureActive: Bool
        @Binding var activeDropFolderID: String?
        @Binding var suspendTimelineTagFetch: Bool
        let canvasBackground: AnyView
        let buildRenderContext: (ThreadCanvasView.CanvasViewportState) -> ThreadCanvasView.CanvasRenderContext
        let renderContent: (ThreadCanvasView.CanvasRenderContext) -> AnyView
        let renderOverlay: (ThreadCanvasView.CanvasRenderContext) -> AnyView
        let onStartDropHighlightPulse: () -> Void
        let onCancelDrag: () -> Void

        @State private var scrollOffset: CGFloat = 0
        @State private var rawScrollOffset: CGFloat = 0
        @State private var rawScrollOffsetX: CGFloat = 0
        @State private var overlayScrollOffset: CGFloat = 0
        @State private var overlayScrollOffsetX: CGFloat = 0
        @State private var viewportWidth: CGFloat = 0
        @State private var viewportHeight: CGFloat = 0
        @State private var canvasScrollView: NSScrollView?
        @State private var pendingScrollConsumeTask: Task<Void, Never>?
        @State private var tagFetchResumeTask: Task<Void, Never>?
        @State private var preservedJumpScrollXByToken: [UUID: CGFloat] = [:]
        @State private var suppressPendingScrollCancellation = false
        @State private var lastMinimapSyncTimestamp: TimeInterval = 0
        @State private var lastScrollTraceDirection: Int = 0
        @State private var lastScrollTraceTimestamp: TimeInterval = 0
        @State private var trackedScrollViewID: ObjectIdentifier?
        @State private var trackedDocumentViewID: ObjectIdentifier?
        @State private var trackedDocumentSize: CGSize = .zero
        // Bumped every time the zoom level changes so that `body` re-runs and picks up the
        // updated `buildRenderContext`/`renderOverlay` closures from the parent re-render.
        // (@Binding reads in body are not tracked as dependencies by SwiftUI, but @State reads are.)
        @State private var zoomRenderVersion: Int = 0

        private let calendar = Calendar.current
        private let scrollTraceMinimumDelta: CGFloat = 2
        private let scrollTraceInterval: TimeInterval = 0.12
        private let tagFetchResumeDebounce: TimeInterval = 0.2
        private let scrollStateUpdateTolerance: CGFloat = 1
        private let minimapSyncInterval: TimeInterval = 1.0 / 30.0
        private let magnificationActivationThreshold: CGFloat = 0.02

        private var visualScrollQuantizationStep: CGFloat {
            viewModel.activeMailboxScope == .allFolders ? 12 : 6
        }

        private var logicalScrollQuantizationStep: CGFloat {
            viewModel.activeMailboxScope == .allFolders ? 12 : 6
        }

        private var horizontalScrollQuantizationStep: CGFloat {
            viewModel.activeMailboxScope == .allFolders ? 16 : 8
        }

        private var viewportState: ThreadCanvasView.CanvasViewportState {
            ThreadCanvasView.CanvasViewportState(rawScrollOffset: rawScrollOffset,
                                                 rawScrollOffsetX: rawScrollOffsetX,
                                                 scrollOffset: scrollOffset,
                                                 viewportWidth: viewportWidth,
                                                 viewportHeight: viewportHeight,
                                                 overlayScrollOffset: overlayScrollOffset,
                                                 overlayScrollOffsetX: overlayScrollOffsetX)
        }

        var body: some View {
            // zoomRenderVersion is a @State that is bumped inside magnificationGesture whenever
            // the zoom level changes.  Reading it here makes it a tracked body dependency, so
            // SwiftUI re-invokes body (and therefore re-evaluates buildRenderContext /
            // renderOverlay with the parent's updated closures) on every zoom step.
            let _ = zoomRenderVersion
            let renderContext = buildRenderContext(viewportState)
            ScrollViewReader { _ in
                configuredScrollView(renderContext: renderContext)
            }
        }

        private func configuredScrollView(renderContext: ThreadCanvasView.CanvasRenderContext) -> some View {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    renderContent(renderContext)
                }
                .frame(width: staticContext.layout.contentSize.width,
                       height: staticContext.layout.contentSize.height,
                       alignment: .topLeading)
                .coordinateSpace(name: "ThreadCanvasContent")
                .padding(.top, staticContext.totalTopPadding)
                .background(
                    ScrollViewResolver(
                        onResolve: { scrollView in
                            configureScrollViewBehavior(scrollView)
                            updateViewportSize(scrollView.contentView.bounds.size)
                            if canvasScrollView !== scrollView {
                                canvasScrollView = scrollView
                                Log.app.debug("Thread canvas scroll host resolved. marker=scroll-host-resolved")
                            }
                            trackScrollHostState(scrollView,
                                                 expectedContentSize: staticContext.layout.contentSize,
                                                 totalTopPadding: staticContext.totalTopPadding)
                        },
                        onBoundsChange: { scrollView, origin in
                            updateViewportSize(scrollView.contentView.bounds.size)
                            trackScrollHostState(scrollView,
                                                 expectedContentSize: staticContext.layout.contentSize,
                                                 totalTopPadding: staticContext.totalTopPadding)
                            handleScrollBoundsChange(origin)
                        }
                    )
                )
            }
            .scrollIndicators(.visible)
            .background(canvasBackground)
            .overlay(alignment: .topLeading) {
                renderOverlay(renderContext)
            }
            .simultaneousGesture(magnificationGesture)
            .background(
                GeometryReader { sizeProxy in
                    Color.clear.preference(key: ThreadCanvasViewportHeightPreferenceKey.self,
                                           value: sizeProxy.size.height)
                }
            )
            .onPreferenceChange(ThreadCanvasViewportHeightPreferenceKey.self) { height in
                handleViewportHeightPreferenceChange(height)
            }
            .onChange(of: staticContext.layout.contentSize.height) { _ in
                handleLayoutContentHeightChange()
            }
            .onChange(of: viewModel.pendingScrollRequest) { oldRequest, request in
                if let oldRequest {
                    preservedJumpScrollXByToken.removeValue(forKey: oldRequest.token)
                }
                guard let request else { return }
                scrollToPendingRequestIfAvailable(request)
            }
            .onChange(of: staticContext.jumpAnchorVersion) { _, _ in
                guard viewModel.pendingScrollRequest != nil else { return }
                if let request = viewModel.pendingScrollRequest {
                    scrollToPendingRequestIfAvailable(request)
                }
            }
            .onChange(of: activeDropFolderID) { oldValue, newValue in
                guard newValue != nil else { return }
                if newValue != oldValue {
                    onStartDropHighlightPulse()
                }
            }
            .onAppear {
                accumulatedZoom = zoomScale
                displaySettings.updateCurrentZoom(zoomScale)
                viewModel.scheduleVisibleDayRangeUpdate(scrollOffset: scrollOffset,
                                                        viewportHeight: effectiveViewportHeight(proxyHeight: proxySize.height,
                                                                                               totalTopPadding: staticContext.totalTopPadding),
                                                        layout: staticContext.layout,
                                                        metrics: staticContext.metrics,
                                                        today: staticContext.today,
                                                        calendar: calendar,
                                                        immediate: true)
                syncFolderMinimapViewportSnapshot()
            }
            .onChange(of: zoomScale) { _, newValue in
                displaySettings.updateCurrentZoom(newValue)
            }
            .onHover { isInside in
                if !isInside {
                    onCancelDrag()
                }
            }
            .onExitCommand {
                onCancelDrag()
            }
        }

        private func effectiveViewportHeight(proxyHeight: CGFloat,
                                             totalTopPadding: CGFloat) -> CGFloat {
            max(max(viewportHeight, proxyHeight) - totalTopPadding, 1)
        }

        private var magnificationGesture: some Gesture {
            MagnificationGesture()
                .onChanged { value in
                    let deltaMagnitude = abs(value - 1)
                    guard isMagnificationGestureActive || deltaMagnitude >= magnificationActivationThreshold else {
                        return
                    }
                    if !isMagnificationGestureActive {
                        isMagnificationGestureActive = true
                    }
                    zoomScale = clampedZoom(value)
                    zoomRenderVersion &+= 1
                }
                .onEnded { value in
                    defer { isMagnificationGestureActive = false }
                    guard isMagnificationGestureActive else { return }
                    let clamped = clampedZoom(value)
                    zoomScale = clamped
                    accumulatedZoom = clamped
                    zoomRenderVersion &+= 1
                }
        }

        private func clampedZoom(_ gestureValue: CGFloat) -> CGFloat {
            let proposed = accumulatedZoom * gestureValue
            return min(max(proposed, ThreadCanvasLayoutMetrics.minZoom),
                       ThreadCanvasLayoutMetrics.maxZoom)
        }

        private func configureScrollViewBehavior(_ scrollView: NSScrollView) {
            if scrollView.verticalScrollElasticity != .none {
                scrollView.verticalScrollElasticity = .none
            }
            if scrollView.horizontalScrollElasticity != .none {
                scrollView.horizontalScrollElasticity = .none
            }
        }

        private func handleScrollBoundsChange(_ origin: CGPoint) {
            markScrollingActivityForTimelineTagFetch()
            let rawOffsetY = max(0, origin.y)
            let rawOffsetX = max(0, origin.x)
            viewModel.noteCanvasScrollActivity(rawOffset: rawOffsetY)
            if viewModel.activeMailboxScope == .allFolders {
                viewModel.noteAllFoldersScrollActivity(rawOffset: rawOffsetY)
            }
            let signpostID = OSSignpostID(log: Log.performance)
            os_signpost(.begin, log: Log.performance, name: "ScrollOffsetUpdate", signpostID: signpostID)
            defer {
                os_signpost(.end, log: Log.performance, name: "ScrollOffsetUpdate", signpostID: signpostID)
            }
            let snappedRawYOffset = snappedScrollOffset(rawOffsetY, step: visualScrollQuantizationStep)
            let snappedRawXOffset = snappedScrollOffset(rawOffsetX, step: horizontalScrollQuantizationStep)
            let adjustedOffset = max(0, rawOffsetY + staticContext.totalTopPadding)
            let snappedAdjustedOffset = snappedScrollOffset(adjustedOffset, step: logicalScrollQuantizationStep)
            let effectiveHeight = effectiveViewportHeight(proxyHeight: proxySize.height,
                                                          totalTopPadding: staticContext.totalTopPadding)
            let signedRawDelta = snappedRawYOffset - rawScrollOffset
            traceScrollSample(rawOffset: snappedRawYOffset,
                              signedDelta: signedRawDelta,
                              pendingRequestToken: viewModel.pendingScrollRequest?.token)
            let scrollDelta = abs(snappedRawYOffset - rawScrollOffset)
            if !suppressPendingScrollCancellation,
               scrollDelta >= 2,
               viewModel.pendingScrollRequest != nil {
                viewModel.cancelPendingScrollRequest(reason: "manual_scroll")
            }
            withNoAnimation {
                if abs(rawScrollOffset - snappedRawYOffset) >= scrollStateUpdateTolerance {
                    rawScrollOffset = snappedRawYOffset
                }
                if abs(rawScrollOffsetX - snappedRawXOffset) >= scrollStateUpdateTolerance {
                    rawScrollOffsetX = snappedRawXOffset
                }
                // Overlay offsets track every pixel (step=1) so folder headers in the
                // overlay stay aligned with folder backgrounds inside the scroll view.
                if abs(overlayScrollOffset - rawOffsetY) >= scrollStateUpdateTolerance {
                    overlayScrollOffset = rawOffsetY
                }
                if abs(overlayScrollOffsetX - rawOffsetX) >= scrollStateUpdateTolerance {
                    overlayScrollOffsetX = rawOffsetX
                }
            }
            syncFolderMinimapViewportSnapshot()
            guard abs(scrollOffset - snappedAdjustedOffset) >= scrollStateUpdateTolerance else { return }
            withNoAnimation {
                scrollOffset = snappedAdjustedOffset
            }
            viewModel.scheduleVisibleDayRangeUpdate(scrollOffset: snappedAdjustedOffset,
                                                    viewportHeight: effectiveHeight,
                                                    layout: staticContext.layout,
                                                    metrics: staticContext.metrics,
                                                    today: staticContext.today,
                                                    calendar: calendar)
        }

        private func snappedScrollOffset(_ value: CGFloat, step: CGFloat) -> CGFloat {
            guard step > 0 else { return value }
            let scaled = value / step
            let floored = floor(scaled + 1e-6)
            return floored * step
        }

        private func withNoAnimation(_ updates: () -> Void) {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, updates)
        }

        private func traceScrollSample(rawOffset: CGFloat,
                                       signedDelta: CGFloat,
                                       pendingRequestToken: UUID?) {
#if DEBUG
            let magnitude = abs(signedDelta)
            guard magnitude >= scrollTraceMinimumDelta else { return }
            let direction = signedDelta > 0 ? 1 : -1
            let now = Date().timeIntervalSinceReferenceDate
            let directionFlipped = lastScrollTraceDirection != 0 && direction != lastScrollTraceDirection
            let intervalElapsed = now - lastScrollTraceTimestamp >= scrollTraceInterval
            guard directionFlipped || intervalElapsed else { return }
            lastScrollTraceDirection = direction
            lastScrollTraceTimestamp = now
#endif
        }

        private func markScrollingActivityForTimelineTagFetch() {
            guard viewModel.activeMailboxScope == .allFolders, displaySettings.viewMode == .timeline else {
                tagFetchResumeTask?.cancel()
                tagFetchResumeTask = nil
                if suspendTimelineTagFetch {
                    suspendTimelineTagFetch = false
                }
                return
            }
            if !suspendTimelineTagFetch {
                suspendTimelineTagFetch = true
            }
            tagFetchResumeTask?.cancel()
            tagFetchResumeTask = Task { [tagFetchResumeDebounce] in
                try? await Task.sleep(nanoseconds: UInt64(tagFetchResumeDebounce * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    suspendTimelineTagFetch = false
                    tagFetchResumeTask = nil
                }
            }
        }

        private func handleViewportHeightPreferenceChange(_ height: CGFloat) {
            updateViewportSize(CGSize(width: max(viewportWidth, proxySize.width),
                                      height: max(height, proxySize.height)))
            let clampedHeight = max(effectiveViewportHeight(proxyHeight: proxySize.height,
                                                            totalTopPadding: staticContext.totalTopPadding),
                                    1)
            syncFolderMinimapViewportSnapshot()
            viewModel.scheduleVisibleDayRangeUpdate(scrollOffset: scrollOffset,
                                                    viewportHeight: clampedHeight,
                                                    layout: staticContext.layout,
                                                    metrics: staticContext.metrics,
                                                    today: staticContext.today,
                                                    calendar: calendar,
                                                    immediate: true)
        }

        private func handleLayoutContentHeightChange() {
            let effectiveHeight = effectiveViewportHeight(proxyHeight: proxySize.height,
                                                          totalTopPadding: staticContext.totalTopPadding)
            syncFolderMinimapViewportSnapshot()
            viewModel.scheduleVisibleDayRangeUpdate(scrollOffset: scrollOffset,
                                                    viewportHeight: effectiveHeight,
                                                    layout: staticContext.layout,
                                                    metrics: staticContext.metrics,
                                                    today: staticContext.today,
                                                    calendar: calendar,
                                                    immediate: true)
            if let request = viewModel.pendingScrollRequest {
                scrollToPendingRequestIfAvailable(request)
            }
        }

        private func updateViewportSize(_ size: CGSize) {
            let nextWidth = max(size.width, 1)
            let nextHeight = max(size.height, 1)
            if abs(viewportWidth - nextWidth) >= scrollStateUpdateTolerance {
                viewportWidth = nextWidth
            }
            if abs(viewportHeight - nextHeight) >= scrollStateUpdateTolerance {
                viewportHeight = nextHeight
            }
        }

        private func syncFolderMinimapViewportSnapshot(force: Bool = false) {
            guard viewModel.selectedFolderID != nil else { return }
            let now = Date().timeIntervalSinceReferenceDate
            if !force, now - lastMinimapSyncTimestamp < minimapSyncInterval {
                return
            }
            lastMinimapSyncTimestamp = now
            let effectiveWidth = max(proxySize.width, 1)
            let effectiveHeight = effectiveViewportHeight(proxyHeight: proxySize.height,
                                                          totalTopPadding: staticContext.totalTopPadding)
            let logicalScrollOffsetY = max(0, rawScrollOffset + staticContext.totalTopPadding)
            viewModel.updateFolderMinimapViewportSnapshot(layout: staticContext.layout,
                                                          scrollOffsetX: rawScrollOffsetX,
                                                          scrollOffsetY: logicalScrollOffsetY,
                                                          viewportWidth: effectiveWidth,
                                                          viewportHeight: effectiveHeight)
        }

        private func trackScrollHostState(_ scrollView: NSScrollView,
                                          expectedContentSize: CGSize,
                                          totalTopPadding: CGFloat) {
            let profilingSnapshot = viewModel.layoutProfilingSnapshot()
            let scrollViewID = ObjectIdentifier(scrollView)
            let documentViewID = scrollView.documentView.map(ObjectIdentifier.init)
            let documentSize = scrollView.documentView?.bounds.size ?? .zero
            let expectedDocumentSize = CGSize(width: expectedContentSize.width,
                                              height: expectedContentSize.height + totalTopPadding)

            if trackedScrollViewID != scrollViewID {
                trackedScrollViewID = scrollViewID
                os_signpost(.event,
                            log: Log.performance,
                            name: "CanvasScrollHostChanged",
                            "scope=%{public}s scrollActive=%{public}d width=%.1f height=%.1f",
                            viewModel.activeMailboxScope == .allFolders ? "allFolders" : "other",
                            profilingSnapshot.isCanvasScrollActive ? 1 : 0,
                            documentSize.width,
                            documentSize.height)
            }

            if trackedDocumentViewID != documentViewID {
                trackedDocumentViewID = documentViewID
                os_signpost(.event,
                            log: Log.performance,
                            name: "CanvasDocumentViewChanged",
                            "scope=%{public}s scrollActive=%{public}d width=%.1f height=%.1f",
                            viewModel.activeMailboxScope == .allFolders ? "allFolders" : "other",
                            profilingSnapshot.isCanvasScrollActive ? 1 : 0,
                            documentSize.width,
                            documentSize.height)
            }

            if trackedDocumentSize != documentSize {
                trackedDocumentSize = documentSize
                os_signpost(.event,
                            log: Log.performance,
                            name: "CanvasDocumentSizeChanged",
                            "scope=%{public}s scrollActive=%{public}d width=%.1f height=%.1f expectedWidth=%.1f expectedHeight=%.1f",
                            viewModel.activeMailboxScope == .allFolders ? "allFolders" : "other",
                            profilingSnapshot.isCanvasScrollActive ? 1 : 0,
                            documentSize.width,
                            documentSize.height,
                            expectedDocumentSize.width,
                            expectedDocumentSize.height)
            }
        }

        private func scrollToPendingRequestIfAvailable(_ request: ThreadCanvasScrollRequest,
                                                       retryCount: Int = 0) {
            let matchingNodes = staticContext.layout.columns
                .flatMap(\.nodes)
                .filter { $0.id == request.nodeID }
            guard let targetNode = matchingNodes.first else { return }
            let requestToken = request.token
            func isRequestActive() -> Bool {
                viewModel.pendingScrollRequest?.token == requestToken && viewModel.isJumpInProgress(for: request.folderID)
            }
            guard isRequestActive() else { return }
            guard let scrollView = canvasScrollView,
                  let documentView = scrollView.documentView else {
                let nextRetry = retryCount + 1
                guard nextRetry <= 45 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard isRequestActive() else { return }
                    scrollToPendingRequestIfAvailable(request, retryCount: nextRetry)
                }
                return
            }
            let clipView = scrollView.contentView
            let preservedX = ThreadCanvasViewModel.resolvedPreservedJumpX(existingPreservedX: preservedJumpScrollXByToken[requestToken],
                                                                          currentX: clipView.bounds.origin.x)
            preservedJumpScrollXByToken[requestToken] = preservedX
            let effectiveHeight = max(effectiveViewportHeight(proxyHeight: proxySize.height,
                                                              totalTopPadding: staticContext.totalTopPadding),
                                      clipView.bounds.height)
            let targetMinYInScrollContent = targetNode.frame.minY + staticContext.totalTopPadding
            let targetMidYInScrollContent = targetNode.frame.midY + staticContext.totalTopPadding
            let resolution = ThreadCanvasViewModel.resolveVerticalJump(boundary: request.boundary,
                                                                       targetMinYInScrollContent: targetMinYInScrollContent,
                                                                       targetMidYInScrollContent: targetMidYInScrollContent,
                                                                       totalTopPadding: staticContext.totalTopPadding,
                                                                       viewportHeight: effectiveHeight,
                                                                       documentHeight: documentView.bounds.height,
                                                                       clipHeight: clipView.bounds.height)
            suppressPendingScrollCancellation = true
            clipView.setBoundsOrigin(CGPoint(x: preservedX, y: resolution.clampedY))
            scrollView.reflectScrolledClipView(clipView)
            DispatchQueue.main.async {
                suppressPendingScrollCancellation = false
            }
            DispatchQueue.main.async {
                guard isRequestActive() else { return }
                let finalOrigin = clipView.bounds.origin
                let didConsume = ThreadCanvasViewModel.shouldConsumeVerticalJump(finalY: finalOrigin.y,
                                                                                 targetY: resolution.clampedY,
                                                                                 didClampToBottom: resolution.didClampToBottom)
                if didConsume {
                    schedulePendingScrollConsumption(request)
                } else {
                    let nextRetry = retryCount + 1
                    guard nextRetry <= 8 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        guard isRequestActive() else { return }
                        scrollToPendingRequestIfAvailable(request, retryCount: nextRetry)
                    }
                }
            }
        }

        private func schedulePendingScrollConsumption(_ request: ThreadCanvasScrollRequest) {
            pendingScrollConsumeTask?.cancel()
            let requestToken = request.token
            pendingScrollConsumeTask = Task {
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard viewModel.pendingScrollRequest?.token == requestToken else { return }
                    viewModel.consumeScrollRequest(request)
                }
            }
        }
    }
}

private struct ThreadCanvasDayBand: View {
    let day: ThreadCanvasDay
    let metrics: ThreadCanvasLayoutMetrics
    let labelText: String?
    let contentWidth: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

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
        if colorScheme == .light {
            return Color.black.opacity(isEven ? 0.015 : 0.03)
        }
        return Color.white.opacity(isEven ? 0.02 : 0.05)
    }

    private var separatorColor: Color {
        if reduceTransparency {
            return Color.secondary.opacity(0.25)
        }
        if colorScheme == .light {
            return Color.black.opacity(0.12)
        }
        return Color.white.opacity(0.08)
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
    static let summaryFooterSpacing: CGFloat = 6
    static let badgeVerticalPadding: CGFloat = 6
    static let badgeVerticalPaddingEllipsis: CGFloat = 5

    static func sizeScale(rawZoom: CGFloat,
                          textScale: CGFloat) -> CGFloat {
        max(rawZoom.clamped(to: 0.6...1.25) * textScale, 0.5)
    }

    static func headerHeight(rawZoom: CGFloat,
                             textScale: CGFloat,
                             readabilityMode: ThreadCanvasReadabilityMode) -> CGFloat {
        let scale = sizeScale(rawZoom: rawZoom, textScale: textScale)
        let titleHeight = titleSectionHeight(sizeScale: scale, readabilityMode: readabilityMode)
        let summaryHeight = summarySectionHeight(sizeScale: scale, readabilityMode: readabilityMode)
        let footerHeight = footerSectionHeight(sizeScale: scale, readabilityMode: readabilityMode)
        let visibleHeights = [titleHeight, summaryHeight, footerHeight].filter { $0 > 0 }
        let spacingCount = max(visibleHeights.count - 1, 0)
        let spacing = CGFloat(spacingCount) * lineSpacing * scale
        let summaryFooterExtraSpacing = (summaryHeight > 0 && footerHeight > 0)
            ? summaryFooterSpacing * scale
            : 0

        return (verticalPadding * 2 * scale) + visibleHeights.reduce(0, +) + spacing + summaryFooterExtraSpacing
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

private struct FolderColumnHeader: View, Equatable {
    let title: String
    let unreadCount: Int
    let mailboxLabel: String?
    let updatedText: String?
    let summaryPreviewText: String?
    let accentDescriptor: ThreadFolderColor
    let accentColor: Color
    let reduceTransparency: Bool
    let rawZoom: CGFloat
    let textScale: CGFloat
    let readabilityMode: ThreadCanvasReadabilityMode
    let cornerRadius: CGFloat
    let isPinned: Bool
    let isSelected: Bool
    let isJumping: Bool
    let onSelect: () -> Void
    let onPinToggle: () -> Void
    let onJumpLatest: () -> Void
    let onJumpFirst: () -> Void

    static func == (lhs: FolderColumnHeader, rhs: FolderColumnHeader) -> Bool {
        lhs.title == rhs.title &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.mailboxLabel == rhs.mailboxLabel &&
        lhs.updatedText == rhs.updatedText &&
        lhs.summaryPreviewText == rhs.summaryPreviewText &&
        lhs.accentDescriptor == rhs.accentDescriptor &&
        lhs.rawZoom == rhs.rawZoom &&
        lhs.textScale == rhs.textScale &&
        lhs.readabilityMode == rhs.readabilityMode &&
        lhs.cornerRadius == rhs.cornerRadius &&
        lhs.isPinned == rhs.isPinned &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isJumping == rhs.isJumping &&
        lhs.reduceTransparency == rhs.reduceTransparency
    }

    private final class MarkdownCacheBox {
        var cache: [String: AttributedString] = [:]
    }

    private static let markdownCacheBox = MarkdownCacheBox()

    private var sizeScale: CGFloat {
        // Track zoom more closely than the clamped fontScale to keep the header proportional.
        FolderHeaderLayout.sizeScale(rawZoom: rawZoom, textScale: textScale)
    }

    private var headerBackground: some View {
        let gradient = LinearGradient(colors: [
            accentColor.opacity(reduceTransparency ? 0.36 : 0.82),
            accentColor.opacity(reduceTransparency ? 0.32 : 0.75)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)

        let backgroundStyle: AnyShapeStyle = reduceTransparency
            ? AnyShapeStyle(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.97))
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
        let summaryFooterSpacing = (summarySectionHeight > 0 && footerSectionHeight > 0)
            ? FolderHeaderLayout.summaryFooterSpacing * sizeScale
            : 0

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
                        if let summaryPreviewText {
                            summaryLine(summaryPreviewText)
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
                            HStack(spacing: 6 * sizeScale) {
                                headerActionButton(systemName: "arrow.up.to.line",
                                                   accessibilityKey: "threadcanvas.folder.jump.latest.accessibility",
                                                   tooltipKey: "threadcanvas.folder.jump.latest.tooltip",
                                                   action: onJumpLatest)
                                headerActionButton(systemName: "arrow.down.to.line",
                                                   accessibilityKey: "threadcanvas.folder.jump.first.accessibility",
                                                   tooltipKey: "threadcanvas.folder.jump.first.tooltip",
                                                   action: onJumpFirst)
                            }
                            badge(unread: unreadCount, mailboxLabel: mailboxLabel)
                        }
                        .padding(.top, summaryFooterSpacing)
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
                                                       textScale: textScale,
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
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button {
                onPinToggle()
            } label: {
                Label(
                    NSLocalizedString(isPinned ? "threadcanvas.folder.menu.unpin" : "threadcanvas.folder.menu.pin",
                                      comment: "Context menu action to pin or unpin a folder"),
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
        }
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
        if let cached = Self.markdownCacheBox.cache[text] {
            return cached
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return nil
        }
        Self.markdownCacheBox.cache[text] = attributed
        return attributed
    }

    @ViewBuilder
    private func badge(unread: Int, mailboxLabel: String?) -> some View {
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
            Text(mailboxLabel ?? "Unread \(unread)")
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
    private func headerActionButton(systemName: String,
                                    accessibilityKey: String,
                                    tooltipKey: String,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: max(FolderHeaderLayout.footerBaseSize * sizeScale - 1, 9), weight: .semibold))
                .frame(width: 22 * sizeScale, height: 20 * sizeScale)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(isJumping ? 0.5 : 0.92))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accentColor.opacity(reduceTransparency ? 0.2 : 0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.22))
        )
        .help(NSLocalizedString(tooltipKey, comment: "Tooltip for folder header jump action"))
        .accessibilityLabel(NSLocalizedString(accessibilityKey,
                                              comment: "Accessibility label for folder header jump action"))
        .disabled(isJumping)
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
        let topLineHeight = timelineTopLineHeight(tags: tags,
                                                  mailboxLabel: MailboxPathFormatter.leafName(from: node.message.mailboxID))
        return node.frame.minY + verticalPadding + (topLineHeight / 2)
    }

    private func timelineTopLineHeight(tags: [String], mailboxLabel: String?) -> CGFloat {
        let fontScale = metrics.fontScale
        let textVisibility = timelineTextVisibility(readabilityMode: readabilityMode)
        let dotSize = ThreadTimelineLayoutConstants.dotSize(fontScale: fontScale)

        guard textVisibility == .normal else {
            return dotSize
        }

        let timeFont = NSFont.systemFont(ofSize: ThreadTimelineLayoutConstants.timeFontSize(fontScale: fontScale),
                                         weight: .semibold)
        let tagFont = NSFont.systemFont(ofSize: ThreadTimelineLayoutConstants.tagChipFontSize(fontScale: fontScale),
                                        weight: .semibold)
        let mailboxFont = NSFont.systemFont(ofSize: ThreadTimelineLayoutConstants.mailboxChipFontSize(fontScale: fontScale),
                                            weight: .semibold)
        let timeHeight = ceil(timeFont.ascender - timeFont.descender)
        let tagVerticalPadding = ThreadTimelineLayoutConstants.tagVerticalPadding(fontScale: fontScale)
        let visibleTags = tags.prefix(3)
        let tagHeight = visibleTags.isEmpty
            ? 0
            : ceil((tagFont.ascender - tagFont.descender) + (tagVerticalPadding * 2))
        let mailboxHeight = mailboxLabel == nil
            ? 0
            : ceil((mailboxFont.ascender - mailboxFont.descender) + (tagVerticalPadding * 2))

        return max(dotSize, timeHeight, tagHeight, mailboxHeight)
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

private struct ThreadTimelineCanvasNodeView: View, Equatable {
    let node: ThreadCanvasNode
    let summaryState: ThreadSummaryState?
    let tags: [String]
    let isSelected: Bool
    let mailboxLabel: String?
    let fontScale: CGFloat
    let readabilityMode: ThreadCanvasReadabilityMode

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func == (lhs: ThreadTimelineCanvasNodeView, rhs: ThreadTimelineCanvasNodeView) -> Bool {
        lhs.node == rhs.node &&
            lhs.summaryState == rhs.summaryState &&
            lhs.tags == rhs.tags &&
            lhs.isSelected == rhs.isSelected &&
            lhs.mailboxLabel == rhs.mailboxLabel &&
            lhs.fontScale == rhs.fontScale &&
            lhs.readabilityMode == rhs.readabilityMode
    }

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

                Spacer(minLength: 0)

                if textVisibility == .normal, let mailboxLabel {
                    mailboxFolderChip(label: mailboxLabel)
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
            tagText,
            mailboxLabel ?? ""
        ].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func mailboxFolderChip(label: String) -> some View {
        Label(label, systemImage: "folder")
            .labelStyle(.titleAndIcon)
            .font(.system(size: mailboxChipFontSize, weight: .semibold))
            .foregroundStyle(mailboxChipForeground)
            .lineLimit(1)
            .truncationMode(.head)
            .minimumScaleFactor(0.72)
            .padding(.vertical, scaled(3))
            .padding(.horizontal, scaled(8))
            .background(
                Capsule(style: .continuous)
                    .fill(mailboxChipFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(mailboxChipStroke, lineWidth: scaled(0.8))
            )
            .shadow(color: mailboxChipShadowColor, radius: scaled(3), y: scaled(1))
    }

    private var mailboxChipForeground: Color {
        if isSelected {
            return .accentColor
        }
        return colorScheme == .dark ? Color.white.opacity(0.86) : Color.primary.opacity(0.78)
    }

    private var mailboxChipFill: Color {
        if isSelected {
            return Color.accentColor.opacity(reduceTransparency ? 0.22 : 0.16)
        }
        if colorScheme == .dark {
            return Color.white.opacity(reduceTransparency ? 0.12 : 0.08)
        }
        return Color.black.opacity(reduceTransparency ? 0.08 : 0.05)
    }

    private var mailboxChipStroke: Color {
        if isSelected {
            return Color.accentColor.opacity(0.55)
        }
        return colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
    }

    private var mailboxChipShadowColor: Color {
        guard !reduceTransparency else {
            return .clear
        }
        if isSelected {
            return Color.accentColor.opacity(0.2)
        }
        return colorScheme == .dark ? Color.black.opacity(0.2) : Color.black.opacity(0.08)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * fontScale
    }

    private var mailboxChipFontSize: CGFloat {
        ThreadTimelineLayoutConstants.mailboxChipFontSize(fontScale: fontScale)
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
            .font(.system(size: chipFontSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.vertical, 3 * fontScale)
            .padding(.horizontal, 6 * fontScale)
            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.28), lineWidth: 0.6 * fontScale))
            .foregroundStyle(Color.accentColor)
    }

    private var chipFontSize: CGFloat {
        ThreadTimelineLayoutConstants.tagChipFontSize(fontScale: fontScale)
    }
}

private struct ThreadCanvasNodeView: View, Equatable {
    let node: ThreadCanvasNode
    let summaryState: ThreadSummaryState?
    let isSelected: Bool
    let isActionItem: Bool
    let mailboxLabel: String?
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

    static func == (lhs: ThreadCanvasNodeView, rhs: ThreadCanvasNodeView) -> Bool {
        lhs.node == rhs.node &&
            lhs.summaryState == rhs.summaryState &&
            lhs.isSelected == rhs.isSelected &&
            lhs.isActionItem == rhs.isActionItem &&
            lhs.mailboxLabel == rhs.mailboxLabel &&
            lhs.fontScale == rhs.fontScale &&
            lhs.viewMode == rhs.viewMode &&
            lhs.readabilityMode == rhs.readabilityMode
    }

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
            metadataLine
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(nodeBackground)
        .overlay(selectionOverlay)
        .overlay(alignment: .topTrailing) {
            if isActionItem {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7 * fontScale, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.85))
                    .padding(4 * fontScale)
            }
        }
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
            [Self.timeFormatter.string(from: node.message.date), mailboxLabel]
                .compactMap { $0 }
                .joined(separator: ", ")
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
    private var metadataLine: some View {
        switch nodeTextVisibility(readabilityMode: readabilityMode, isTitleLine: false) {
        case .normal:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.timeFormatter.string(from: node.message.date))
                    .font(.system(size: 11 * fontScale, weight: .regular))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let mailboxLabel {
                    Text(mailboxLabel)
                        .font(.system(size: 11 * fontScale, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        case .ellipsis:
            Text("…")
                .font(.system(size: 11 * fontScale, weight: .regular))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
        case .hidden:
            EmptyView()
        }
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

private enum ThreadCanvasDragPayload: Equatable {
    case thread(threadID: String, initialFolderID: String?)
    case folder(folderID: String, initialParentFolderID: String?)
}

private struct ThreadCanvasDragState: Equatable {
    let payload: ThreadCanvasDragPayload
    let previewTitle: String
    let previewDetail: String?
    var location: CGPoint
}

private struct ThreadDragPreview: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.isEmpty ? NSLocalizedString("threadcanvas.subject.placeholder",
                                                   comment: "Placeholder subject when missing") : title)
                .font(.headline)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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

private struct ScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView) -> Void
    let onBoundsChange: (NSScrollView, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResolve: onResolve, onBoundsChange: onBoundsChange)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.updateHandlers(onResolve: onResolve, onBoundsChange: onBoundsChange)
        let view = NSView(frame: .zero)
        context.coordinator.scheduleResolution(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.updateHandlers(onResolve: onResolve, onBoundsChange: onBoundsChange)
        context.coordinator.scheduleResolution(from: nsView)
    }

    private static func findScrollView(startingAt view: NSView) -> NSScrollView? {
        if let direct = view.enclosingScrollView {
            return direct
        }
        var current: NSView? = view
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            current = candidate.superview
        }
        return nil
    }

    final class Coordinator {
        private var onResolve: (NSScrollView) -> Void
        private var onBoundsChange: (NSScrollView, CGPoint) -> Void
        private weak var observedScrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?

        init(onResolve: @escaping (NSScrollView) -> Void,
             onBoundsChange: @escaping (NSScrollView, CGPoint) -> Void) {
            self.onResolve = onResolve
            self.onBoundsChange = onBoundsChange
        }

        func updateHandlers(onResolve: @escaping (NSScrollView) -> Void,
                            onBoundsChange: @escaping (NSScrollView, CGPoint) -> Void) {
            self.onResolve = onResolve
            self.onBoundsChange = onBoundsChange
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func scheduleResolution(from view: NSView?) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let scrollView = ScrollViewResolver.findScrollView(startingAt: view) else { return }
                bind(to: scrollView)
            }
        }

        private func bind(to scrollView: NSScrollView) {
            guard observedScrollView !== scrollView else {
                return
            }

            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }

            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                self.onBoundsChange(scrollView, scrollView.contentView.bounds.origin)
            }

            onResolve(scrollView)
            onBoundsChange(scrollView, scrollView.contentView.bounds.origin)
        }
    }
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
    let mailboxLabel: String?
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
        mailboxLabel: "Inbox",
        fontScale: 1.0,
        readabilityMode: .detailed
    )
}
