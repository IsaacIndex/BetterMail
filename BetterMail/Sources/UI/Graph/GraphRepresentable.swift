import SpriteKit
import SwiftUI

internal struct GraphRepresentable: NSViewRepresentable {
    @ObservedObject internal var graphViewModel: GraphCanvasViewModel
    @ObservedObject internal var settings: GraphCanvasSettings
    internal let selectedNodeID: String?
    internal let reduceMotion: Bool
    internal let colorScheme: ColorScheme
    internal let audio: GraphAudio
    internal let onSelectRootNode: (String?) -> Void

    internal func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    internal func makeNSView(context: Context) -> GraphSKView {
        let view = GraphSKView()
        view.allowsTransparency = false
        view.ignoresSiblingOrder = true
        view.shouldCullNonVisibleNodes = true
        view.preferredFramesPerSecond = 60
#if DEBUG
        view.showsFPS = true
        view.showsNodeCount = true
#endif
        let scene = GraphScene(size: view.bounds.size == .zero ? CGSize(width: 960, height: 640) : view.bounds.size)
        context.coordinator.scene = scene
        view.presentScene(scene)
        return view
    }

    internal func updateNSView(_ nsView: GraphSKView, context: Context) {
        context.coordinator.parent = self
        nsView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let scene = context.coordinator.scene ?? GraphScene(size: nsView.bounds.size)
        context.coordinator.scene = scene
        if nsView.scene !== scene {
            nsView.presentScene(scene)
        }
        scene.onSelectGraphNode = { graphNodeID in
            onSelectRootNode(graphViewModel.rootNodeID(forGraphNodeID: graphNodeID))
        }
        scene.onHoverItem = { item in
            graphViewModel.setHoverItem(item)
            if item != nil {
                audio.play(.hover, settings: settings)
            }
        }
        scene.onWaterThread = { threadID in
            graphViewModel.water(threadID: threadID, settings: settings)
            audio.play(.water, settings: settings)
        }
        scene.onPruneThread = { threadID in
            let mode = graphViewModel.pruneMode
            graphViewModel.requestPrune(threadID: threadID)
            switch mode {
            case .snip:
                audio.play(.snip, settings: settings)
            case .archive:
                audio.play(.archive, settings: settings)
            case .idle:
                break
            }
        }
        scene.onViewportChanged = { zoom, pan in
            graphViewModel.setZoom(zoom)
            graphViewModel.setPanOffset(pan)
        }
        scene.onPositionsChanged = { positions in
            graphViewModel.setNodePositions(positions)
        }
        scene.configure(data: graphViewModel.data,
                        selectedGraphNodeID: graphViewModel.selectedGraphNodeID(for: selectedNodeID),
                        pruneMode: graphViewModel.pruneMode,
                        filteredNodeIDs: graphViewModel.filteredNodeIDs,
                        wateredCounts: settings.wateredCounts,
                        reduceMotion: reduceMotion,
                        sproutingMessageIDs: graphViewModel.sproutingMessageIDs,
                        forceConfig: settings.forceConfig,
                        theme: DesignTokens.Graph.AppTheme.palette(for: colorScheme),
                        zoomScale: graphViewModel.zoomScale,
                        panOffset: graphViewModel.panOffset)
    }

    internal final class Coordinator {
        internal var parent: GraphRepresentable
        internal var scene: GraphScene?

        internal init(parent: GraphRepresentable) {
            self.parent = parent
        }
    }
}

internal final class GraphSKView: SKView {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func magnify(with event: NSEvent) {
        guard let graphScene = scene as? GraphScene else {
            super.magnify(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        graphScene.magnify(by: event.magnification, at: viewPoint, in: self)
    }
}
