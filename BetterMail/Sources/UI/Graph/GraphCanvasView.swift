import SwiftUI

internal struct GraphCanvasView: View {
    @ObservedObject internal var threadViewModel: ThreadCanvasViewModel
    @ObservedObject internal var graphViewModel: GraphCanvasViewModel
    @ObservedObject internal var graphSettings: GraphCanvasSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    internal let topInset: CGFloat
    internal let bottomChromeInset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var audio = GraphAudio()

    internal var body: some View {
        GeometryReader { proxy in
            ZStack {
                GraphRepresentable(graphViewModel: graphViewModel,
                                   settings: graphSettings,
                                   selectedNodeID: threadViewModel.selectedNodeID,
                                   reduceMotion: reduceMotion,
                                   audio: audio,
                                   onSelectRootNode: { nodeID in
                                       threadViewModel.selectNode(id: nodeID)
                                   })
                graphDotGrid
                    .allowsHitTesting(false)
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
        .background(DesignTokens.Graph.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier(AccessibilityID.graphCanvas)
        .accessibilityLabel(NSLocalizedString("graph.accessibility.canvas",
                                              comment: "Accessibility label for graph canvas"))
        .onAppear {
            audio.warm()
            syncData()
        }
        .onReceive(threadViewModel.$roots) { _ in syncData() }
        .onReceive(threadViewModel.$searchQuery) { _ in syncData() }
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
        graphViewModel.update(roots: threadViewModel.roots,
                              searchQuery: threadViewModel.searchQuery,
                              tagsByNodeID: threadViewModel.timelineTagsByNodeID,
                              summariesByNodeID: threadViewModel.nodeSummaries)
    }

    private func hoverPosition(for item: GraphHoverItem, in size: CGSize) -> CGPoint {
        let rawPoint: CGPoint
        switch item {
        case .thread(_, let point), .message(_, let point):
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

internal enum GraphKeyboardCommand {
    case snip
    case archive
    case escape
    case water
    case zoomIn
    case zoomOut
    case reset
}
