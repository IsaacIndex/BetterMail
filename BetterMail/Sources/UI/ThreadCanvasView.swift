import AppKit
import SwiftUI

struct ThreadCanvasView: View {
    @ObservedObject var viewModel: ThreadCanvasViewModel
    let topInset: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var zoomScale: CGFloat = 1.0
    @State private var accumulatedZoom: CGFloat = 1.0

    private let calendar = Calendar.current

    var body: some View {
        let metrics = ThreadCanvasLayoutMetrics(zoom: zoomScale)
        let layout = viewModel.canvasLayout(metrics: metrics, today: Date(), calendar: calendar)

        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                dayBands(layout: layout, metrics: metrics)
                columnDividers(layout: layout, metrics: metrics)
                connectorLayer(layout: layout, metrics: metrics)
                nodesLayer(layout: layout, metrics: metrics)
            }
            .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
            .padding(.top, topInset)
        }
        .scrollIndicators(.visible)
        .background(canvasBackground)
        .gesture(magnificationGesture)
        .onAppear {
            accumulatedZoom = zoomScale
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
            }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, ThreadCanvasLayoutMetrics.minZoom), ThreadCanvasLayoutMetrics.maxZoom)
    }

    @ViewBuilder
    private func dayBands(layout: ThreadCanvasLayout, metrics: ThreadCanvasLayoutMetrics) -> some View {
        ForEach(layout.days) { day in
            ThreadCanvasDayBand(day: day, metrics: metrics, contentWidth: layout.contentSize.width)
                .offset(x: 0, y: day.yOffset)
        }
    }

    @ViewBuilder
    private func columnDividers(layout: ThreadCanvasLayout, metrics: ThreadCanvasLayoutMetrics) -> some View {
        let lineColor = reduceTransparency ? Color.secondary.opacity(0.2) : Color.white.opacity(0.12)
        ForEach(layout.columns) { column in
            Rectangle()
                .fill(lineColor)
                .frame(width: 1, height: layout.contentSize.height)
                .offset(x: column.xOffset + (metrics.columnWidth / 2), y: 0)
        }
    }

    @ViewBuilder
    private func connectorLayer(layout: ThreadCanvasLayout, metrics: ThreadCanvasLayoutMetrics) -> some View {
        ForEach(layout.columns) { column in
            ThreadCanvasConnectorColumn(column: column, metrics: metrics, isHighlighted: isColumnSelected(column))
                .frame(width: metrics.columnWidth, height: layout.contentSize.height, alignment: .topLeading)
                .offset(x: column.xOffset, y: 0)
        }
    }

    @ViewBuilder
    private func nodesLayer(layout: ThreadCanvasLayout, metrics: ThreadCanvasLayoutMetrics) -> some View {
        ForEach(layout.columns) { column in
            ForEach(column.nodes) { node in
                ThreadCanvasNodeView(node: node,
                                     isSelected: viewModel.selectedNodeIDs.contains(node.id),
                                     fontScale: metrics.fontScale)
                    .frame(width: node.frame.width, height: node.frame.height)
                    .offset(x: node.frame.minX, y: node.frame.minY)
                    .onTapGesture {
                        viewModel.selectNode(id: node.id, additive: isCommandClick())
                    }
            }
        }
    }

    private func isColumnSelected(_ column: ThreadCanvasColumn) -> Bool {
        guard let selectedNodeID = viewModel.selectedNodeID else { return false }
        return column.nodes.contains(where: { $0.id == selectedNodeID })
    }

    private func isCommandClick() -> Bool {
        guard let flags = NSApp.currentEvent?.modifierFlags else { return false }
        return flags.contains(.command)
    }
}

private struct ThreadCanvasDayBand: View {
    let day: ThreadCanvasDay
    let metrics: ThreadCanvasLayoutMetrics
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
            Text(day.label)
                .font(.system(size: 11 * metrics.fontScale, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: metrics.dayLabelWidth - metrics.nodeHorizontalInset, alignment: .trailing)
                .padding(.leading, metrics.nodeHorizontalInset)
                .padding(.top, metrics.nodeVerticalSpacing)
                .accessibilityAddTraits(.isHeader)
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

private struct ThreadCanvasConnectorColumn: View {
    let column: ThreadCanvasColumn
    let metrics: ThreadCanvasLayoutMetrics
    let isHighlighted: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let sortedNodes = column.nodes.sorted { $0.frame.minY < $1.frame.minY }
        let segments = connectorSegments(for: sortedNodes)

        ZStack(alignment: .topLeading) {
            ForEach(segments) { segment in
                // Convert the node’s global X into this column-local coordinate space.
                let localX = (segment.nodeMidX - column.xOffset)
                    .clamped(to: 0...metrics.columnWidth)
                Path { path in
                    // Draw the connector directly under the node (not at column center).
                    path.move(to: CGPoint(x: localX - (segment.isManual ? 5 : -5), y: segment.startY))
                    path.addLine(to: CGPoint(x: localX - (segment.isManual ? 5 : -5), y: segment.endY))
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
                
                Circle()
                    .fill(segmentColor(for: segment))
                    .frame(width: lineWidth * 8.8, height: lineWidth * 8.8)
                    .shadow(color: segmentColor(for: segment), radius: glowRadius)
                    .position(x: localX - (segment.isManual ? 5 : -5), y: segment.endY - lineWidth * 8.8 / 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(segments: segments))
    }

    private var lineWidth: CGFloat {
        isHighlighted ? 2 : 1.3
    }

    private var glowRadius: CGFloat {
        isHighlighted ? 4 : 3.75
    }

    private func segmentColor(for segment: ConnectorSegment) -> Color {
        let baseColor = segment.isManual ? manualConnectorColor : connectorColor
        return isHighlighted ? baseColor.opacity(1.0) : baseColor.opacity(0.7)
    }

    private func segmentGlowColor(for segment: ConnectorSegment) -> Color {
        if segment.isManual {
            return manualConnectorGlowColor
        }
        return isHighlighted ? connectorGlowColor : connectorGlowColor.opacity(0.6)
    }

    private var connectorColor: Color {
        if reduceTransparency {
            return Color.secondary.opacity(0.35)
        }
        return Color.blue.opacity(0.35)
    }

    private var connectorGlowColor: Color {
        Color.accentColor.opacity(isHighlighted ? 0.75 : 0.55)
    }

    private var manualConnectorColor: Color {
        if reduceTransparency {
            return Color.red.opacity(0.68)
        }
        return Color.red.opacity(0.95)
    }

    private var manualConnectorGlowColor: Color {
        Color.orange.opacity(isHighlighted ? 0.92 : 0.65)
    }

    private func connectorSegments(for nodes: [ThreadCanvasNode]) -> [ConnectorSegment] {
        guard nodes.count > 1 else { return [] }
        var segments: [ConnectorSegment] = []
        segments.reserveCapacity(nodes.count - 1)

        // Keep the connector from touching the node cards.
        // let gap = max(6, 8 * metrics.fontScale)
        let gap = 0.0

        for index in 1..<nodes.count {
            let previous = nodes[index - 1]
            let next = nodes[index]
            let isManual = previous.isManualOverride || next.isManualOverride

            let startY = previous.frame.maxY + gap
            let endY = next.frame.minY - gap
            guard endY > startY else { continue }

            segments.append(
                ConnectorSegment(
                    id: "\(column.id)-\(index)",
                    startY: startY,
                    endY: endY,
                    nodeMidX: previous.frame.midX,
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

private struct ConnectorSegment: Identifiable {
    let id: String
    let startY: CGFloat
    let endY: CGFloat
    let nodeMidX: CGFloat
    let isManual: Bool
}

private struct ThreadCanvasNodeView: View {
    let node: ThreadCanvasNode
    let isSelected: Bool
    let fontScale: CGFloat

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
            Text(subjectText)
                .font(.system(size: 13 * fontScale, weight: node.message.isUnread ? .semibold : .regular))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)

            Text(node.message.from)
                .font(.system(size: 11 * fontScale))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)

            Text(Self.timeFormatter.string(from: node.message.date))
                .font(.system(size: 11 * fontScale))
                .foregroundStyle(secondaryTextColor)
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
        shape
            .fill(nodeSolidFillColor)
            .overlay(shape.stroke(nodeStrokeColor))
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 6)
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

    private var nodeSolidFillColor: Color {
        if reduceTransparency {
            return Color(nsColor: NSColor.windowBackgroundColor).opacity(0.98)
        }
        return colorScheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.92)
    }

    private var nodeStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.1)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.95) : Color.black.opacity(0.88)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.55)
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
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
