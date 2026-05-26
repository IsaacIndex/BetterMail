import SwiftUI

internal struct GraphCanvasView: View {
    @ObservedObject internal var threadViewModel: ThreadCanvasViewModel
    @ObservedObject internal var graphViewModel: GraphCanvasViewModel
    @ObservedObject internal var graphSettings: GraphCanvasSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    internal let topInset: CGFloat
    internal let bottomChromeInset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var audio = GraphAudio()
    @State private var isLegendExpanded = false

    internal var body: some View {
        GeometryReader { proxy in
            ZStack {
                GraphRepresentable(graphViewModel: graphViewModel,
                                   settings: graphSettings,
                                   selectedNodeID: threadViewModel.selectedNodeID,
                                   reduceMotion: reduceMotion,
                                   colorScheme: colorScheme,
                                   audio: audio,
                                   onSelectRootNode: { nodeID in
                                       threadViewModel.selectNode(id: nodeID)
                                       if nodeID == nil {
                                           threadViewModel.selectFolder(id: nil)
                                       }
                                   })
                    .accessibilityIdentifier(AccessibilityID.graphCanvas)
                    .accessibilityLabel(NSLocalizedString("graph.accessibility.canvas",
                                                          comment: "Accessibility label for graph canvas"))
                graphDotGrid
                    .allowsHitTesting(false)
                VStack {
                    HStack {
                        GraphLegend(isExpanded: $isLegendExpanded)
                            .padding(.top, 16)
                            .padding(.leading, 18)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .zIndex(1)
                if let hoverItem = graphViewModel.hoverItem {
                    GraphHoverCard(item: hoverItem, textScale: displaySettings.textScale)
                        .position(hoverPosition(for: hoverItem, in: proxy.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(2)
                }
                VStack {
                    Spacer()
                    GraphToolbar(viewModel: graphViewModel,
                                 settings: graphSettings,
                                 textScale: displaySettings.textScale)
                    .padding(.bottom, overlayBottomPadding)
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        GraphCompostRing(entries: graphViewModel.compostEntries,
                                         textScale: displaySettings.textScale,
                                         onRestore: restore)
                        .padding(.trailing, 24)
                        .padding(.bottom, overlayBottomPadding)
                    }
                }
            }
        }
        .padding(.top, topInset)
        .background(DesignTokens.Graph.AppTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            warmAudioIfNeeded()
            syncData()
        }
        .onChange(of: graphSettings.soundOn) { _, _ in
            warmAudioIfNeeded()
        }
        .onReceive(threadViewModel.$roots) { _ in syncData() }
        .onReceive(threadViewModel.$searchQuery) { _ in syncData() }
        .onReceive(threadViewModel.$activeMailboxScope) { _ in syncData() }
        .onReceive(threadViewModel.$timelineTagsByNodeID) { _ in syncData() }
        .onReceive(threadViewModel.$nodeSummaries) { _ in syncData() }
        .sheet(item: $graphViewModel.snipMoveRequest) { request in
            SnipMoveSheet(request: request,
                          mailboxAccounts: threadViewModel.mailboxAccounts,
                          settings: graphSettings,
                          onConfirm: { path, account in
                              Task { await confirmSnip(request: request, path: path, account: account) }
                          },
                          onCancel: graphViewModel.cancelSnip)
        }
        .sheet(isPresented: $graphViewModel.isSettingsPresented) {
            GraphSettingsSheet(settings: graphSettings)
        }
    }

    internal func handleKey(_ key: GraphKeyboardCommand) -> KeyPress.Result {
        switch key {
        case .snip:
            graphViewModel.toggleSnipMode()
        case .archive:
            graphViewModel.toggleArchiveMode()
        case .escape:
            graphViewModel.exitPruneMode()
        case .water:
            guard let threadID = graphViewModel.selectedGraphNodeID(for: threadViewModel.selectedNodeID),
                  graphViewModel.data.threadByID[threadID] != nil else { return .ignored }
            graphViewModel.water(threadID: threadID, settings: graphSettings)
            audio.play(.water, settings: graphSettings)
        case .zoomIn:
            graphViewModel.zoomIn()
        case .zoomOut:
            graphViewModel.zoomOut()
        case .reset:
            graphViewModel.resetViewport()
        }
        return .handled
    }

    private var reduceMotion: Bool {
        graphSettings.shouldReduceMotion(systemReduceMotion: systemReduceMotion)
    }

    private var overlayBottomPadding: CGFloat {
        24 + bottomChromeInset
    }

    @MainActor
    private func warmAudioIfNeeded() {
        guard graphSettings.soundOn else { return }
        audio.warm()
    }

    private var graphDotGrid: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28
            let color = Color.black.opacity(0.035)
            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    let rect = CGRect(x: x, y: y, width: 1.2, height: 1.2)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                    y += spacing
                }
                x += spacing
            }
        }
        .mask(
            RadialGradient(colors: [.black, .black.opacity(0.2), .clear],
                           center: .center,
                           startRadius: 80,
                           endRadius: 680)
        )
    }

    private func syncData() {
        graphViewModel.onArchiveStateChanged = { [weak threadViewModel] in
            threadViewModel?.refreshGraphArchiveVisibility()
        }
        graphViewModel.update(roots: threadViewModel.roots,
                              searchQuery: threadViewModel.searchQuery,
                              tagsByNodeID: threadViewModel.timelineTagsByNodeID,
                              summariesByNodeID: threadViewModel.nodeSummaries,
                              showsArchivedThreads: threadViewModel.activeMailboxScope == .graphArchive)
    }

    private func hoverPosition(for item: GraphHoverItem, in size: CGSize) -> CGPoint {
        let rawPoint: CGPoint
        switch item {
        case .thread(_, let point), .remaining(_, let point), .message(_, let point):
            rawPoint = point
        }
        let x = min(max(rawPoint.x + 150, 140), max(140, size.width - 140))
        let y = min(max(size.height - rawPoint.y + 76, 90), max(90, size.height - 90))
        return CGPoint(x: x, y: y)
    }

    private func confirmSnip(request: SnipMoveRequest, path: String, account: String?) async {
        do {
            try await graphViewModel.confirmSnip(request: request,
                                                 destinationPath: path,
                                                 account: account)
            threadViewModel.showToast(NSLocalizedString("graph.snip.success",
                                                        comment: "Graph snip success toast"),
                                      style: .success)
        } catch {
            graphViewModel.cancelSnip()
            threadViewModel.showError(error.localizedDescription)
        }
    }

    private func restore(_ entry: GraphCompostEntry) {
        Task {
            do {
                try await graphViewModel.restore(entry)
                threadViewModel.showToast(NSLocalizedString("graph.restore.success",
                                                            comment: "Graph restore success toast"),
                                          style: .success)
            } catch {
                threadViewModel.showError(error.localizedDescription)
            }
        }
    }
}

private struct GraphLegend: View {
    @Binding fileprivate var isExpanded: Bool

    fileprivate var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                legendRow(title: NSLocalizedString("graph.legend.you.title",
                                                   comment: "Graph legend current user node title"),
                          detail: NSLocalizedString("graph.legend.you.detail",
                                                    comment: "Graph legend current user node detail")) {
                    Circle()
                        .fill(DesignTokens.Graph.AppTheme.panel)
                        .overlay(Circle().stroke(DesignTokens.Graph.AppTheme.accent, lineWidth: 2))
                        .frame(width: 21, height: 21)
                }
                legendRow(title: NSLocalizedString("graph.legend.thread.title",
                                                   comment: "Graph legend thread node title"),
                          detail: NSLocalizedString("graph.legend.thread.detail",
                                                    comment: "Graph legend thread node detail")) {
                    HStack(spacing: 3) {
                        legendCircle(stroke: DesignTokens.Graph.AppTheme.inkQuaternary, lineWidth: 1)
                        legendCircle(stroke: DesignTokens.Graph.AppTheme.inkSecondary, lineWidth: 1.4)
                        legendCircle(stroke: DesignTokens.Graph.AppTheme.ink, lineWidth: 1.9)
                    }
                }
                legendRow(title: NSLocalizedString("graph.legend.message.title",
                                                   comment: "Graph legend message node title"),
                          detail: NSLocalizedString("graph.legend.message.detail",
                                                    comment: "Graph legend message node detail")) {
                    HStack(spacing: -4) {
                        GraphLegendLeafShape()
                            .fill(DesignTokens.Graph.AppTheme.panel)
                            .overlay(GraphLegendLeafShape().stroke(DesignTokens.Graph.AppTheme.ink, lineWidth: 1))
                            .frame(width: 21, height: 15)
                        GraphLegendLeafShape()
                            .fill(DesignTokens.Graph.AppTheme.accent)
                            .overlay(GraphLegendLeafShape().stroke(DesignTokens.Graph.AppTheme.ink.opacity(0.55),
                                                                   lineWidth: 0.8))
                            .frame(width: 21, height: 15)
                    }
                }
                legendRow(title: NSLocalizedString("graph.legend.remaining.title",
                                                   comment: "Graph legend remaining branch title"),
                          detail: NSLocalizedString("graph.legend.remaining.detail",
                                                    comment: "Graph legend remaining branch detail")) {
                    ZStack {
                        Circle()
                            .stroke(DesignTokens.Graph.AppTheme.archive,
                                    style: StrokeStyle(lineWidth: 1.4,
                                                       lineCap: .round,
                                                       dash: [4, 3]))
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignTokens.Graph.AppTheme.archive)
                    }
                    .frame(width: 23, height: 23)
                }
                legendRow(title: NSLocalizedString("graph.legend.branch.title",
                                                   comment: "Graph legend branch line title"),
                          detail: NSLocalizedString("graph.legend.branch.detail",
                                                    comment: "Graph legend branch line detail")) {
                    VStack(spacing: 5) {
                        GraphLegendCurve()
                            .stroke(DesignTokens.Graph.AppTheme.inkTertiary,
                                    style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                        GraphLegendCurve()
                            .stroke(DesignTokens.Graph.AppTheme.inkQuaternary,
                                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    }
                    .frame(width: 32, height: 20)
                }
                legendRow(title: NSLocalizedString("graph.legend.archive.title",
                                                   comment: "Graph legend archive branch title"),
                          detail: NSLocalizedString("graph.legend.archive.detail",
                                                    comment: "Graph legend archive branch detail")) {
                    GraphLegendCurve()
                        .stroke(DesignTokens.Graph.AppTheme.archive,
                                style: StrokeStyle(lineWidth: 1.5,
                                                   lineCap: .round,
                                                   lineJoin: .round,
                                                   dash: [5, 4]))
                        .frame(width: 32, height: 18)
                }
            }
            .padding(.top, 8)
        } label: {
            Label(NSLocalizedString("graph.legend.title", comment: "Graph legend disclosure title"),
                  systemImage: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
        }
        .font(.system(size: 10))
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .frame(width: isExpanded ? 286 : 116, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 8)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .accessibilityIdentifier("graph.legend")
    }

    private func legendCircle(stroke: Color, lineWidth: CGFloat) -> some View {
        Circle()
            .fill(DesignTokens.Graph.AppTheme.panel)
            .overlay(Circle().stroke(stroke, lineWidth: lineWidth))
            .frame(width: 15, height: 15)
    }

    private func legendRow<Icon: View>(title: String,
                                       detail: String,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon()
                .frame(width: 34, height: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct GraphLegendLeafShape: Shape {
    fileprivate func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control: CGPoint(x: rect.minX + rect.width * 0.16,
                                           y: rect.minY - rect.height * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: midY),
                          control: CGPoint(x: rect.maxX - rect.width * 0.16,
                                           y: rect.minY - rect.height * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX - rect.width * 0.16,
                                           y: rect.maxY + rect.height * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: midY),
                          control: CGPoint(x: rect.minX + rect.width * 0.16,
                                           y: rect.maxY + rect.height * 0.04))
        path.closeSubpath()
        return path
    }
}

private struct GraphLegendCurve: Shape {
    fileprivate func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 4))
        path.addCurve(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 4),
                      control1: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.midY + 4),
                      control2: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.midY - 4))
        return path
    }
}

internal enum GraphKeyboardCommand {
    case snip
    case archive
    case escape
    case water
    case zoomIn
    case zoomOut
    case reset
}
