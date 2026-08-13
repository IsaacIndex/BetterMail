import SpriteKit
import SwiftUI

internal struct GraphRepresentable: NSViewRepresentable {
    @ObservedObject internal var graphViewModel: GraphCanvasViewModel
    @ObservedObject internal var settings: GraphCanvasSettings
    internal let selectedNodeID: String?
    internal let selectedNodeIDs: Set<String>
    internal let reduceMotion: Bool
    internal let colorScheme: ColorScheme
    internal let textScale: CGFloat
    internal let audio: GraphAudio
    internal let onSelectRootNode: (String?, Bool) -> Void
    internal let onToggleActionItem: (String) -> Void
    internal let isActionItem: (String) -> Bool
    internal let onMoveThreadToFolder: (String, String) -> Void

    internal func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    internal func makeNSView(context: Context) -> GraphSKView {
        let view = GraphSKView()
        view.allowsTransparency = false
        view.ignoresSiblingOrder = true
        view.shouldCullNonVisibleNodes = true
        view.preferredFramesPerSecond = ObsidianGraphScene.activeFramesPerSecond
#if DEBUG
        view.showsFPS = true
        view.showsNodeCount = true
#endif
        let scene = ObsidianGraphScene(size: view.bounds.size == .zero
                                      ? CGSize(width: 960, height: 640)
                                      : view.bounds.size)
        context.coordinator.scene = scene
        view.presentScene(scene)
        return view
    }

    internal func updateNSView(_ nsView: GraphSKView, context: Context) {
        context.coordinator.parent = self
        nsView.isPaused = false
        nsView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let scene = context.coordinator.scene ?? ObsidianGraphScene(size: nsView.bounds.size)
        context.coordinator.scene = scene
        if nsView.scene !== scene {
            nsView.presentScene(scene)
        }
        scene.onSelectGraphNode = { graphNodeID, isAdditive in
            if let graphNodeID,
               graphViewModel.data.groupingByID[graphNodeID] != nil {
                graphViewModel.selectGrouping(id: graphNodeID)
                onSelectRootNode(nil, false)
                return
            }
            graphViewModel.selectGrouping(id: nil)
            onSelectRootNode(graphViewModel.rootNodeID(forGraphNodeID: graphNodeID), isAdditive)
        }
        scene.onToggleActionItem = onToggleActionItem
        scene.isActionItem = isActionItem
        scene.onMoveThreadToFolder = onMoveThreadToFolder
        scene.onExpandRemainingBranches = { parentID in
            graphViewModel.expandRemainingBranches(parentID: parentID)
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
        scene.onSnipTarget = { target in
            graphViewModel.toggleSnipTarget(target)
            audio.play(.snip, settings: settings)
        }
        scene.onPruneThread = { threadID in
            let mode = graphViewModel.pruneMode
            graphViewModel.requestPrune(threadID: threadID)
            switch mode {
            case .archive:
                audio.play(.archive, settings: settings)
            case .snip, .idle:
                break
            }
        }
        scene.onPruneAnimationFinished = { [weak graphViewModel] requestID in
            graphViewModel?.finishPruneAnimation(id: requestID)
        }
        scene.onViewportChanged = { zoom, pan in
            graphViewModel.setZoom(zoom)
            graphViewModel.setPanOffset(pan)
        }
        scene.onPositionsChanged = { positions in
            graphViewModel.setNodePositions(positions)
        }
        scene.onFrameRatePreferenceChanged = { [weak nsView] framesPerSecond in
            nsView?.preferredFramesPerSecond = framesPerSecond
        }
        let selectedGraphNodeID = graphViewModel.selectedGroupingID
            ?? graphViewModel.selectedGraphNodeID(for: selectedNodeID)
        let selectedGraphNodeIDs: Set<String>
        if let selectedGroupingID = graphViewModel.selectedGroupingID {
            selectedGraphNodeIDs = [selectedGroupingID]
        } else {
            selectedGraphNodeIDs = graphViewModel.graphNodeIDs(for: selectedNodeIDs)
        }
        scene.configure(data: graphViewModel.data,
                        selectedGraphNodeID: selectedGraphNodeID,
                        selectedGraphNodeIDs: selectedGraphNodeIDs,
                        pruneMode: graphViewModel.pruneMode,
                        filteredNodeIDs: graphViewModel.filteredNodeIDs,
                        wateredCounts: settings.wateredCounts,
                        reduceMotion: reduceMotion,
                        sproutingMessageIDs: graphViewModel.sproutingMessageIDs,
                        forceConfig: settings.obsidianForceConfig,
                        displayConfig: settings.obsidianDisplayConfig,
                        theme: DesignTokens.Graph.AppTheme.palette(for: colorScheme),
                        textScale: textScale,
                        zoomScale: graphViewModel.zoomScale,
                        panOffset: graphViewModel.panOffset,
                        stagedSnipThreadIDs: graphViewModel.stagedSnipThreadIDs,
                        fullyStagedSnipGroupingIDs: graphViewModel.fullyStagedSnipGroupingIDs,
                        partiallyStagedSnipGroupingIDs: graphViewModel.partiallyStagedSnipGroupingIDs,
                        snipVisualTransition: graphViewModel.snipVisualTransition,
                        pruneAnimationRequest: graphViewModel.pruneAnimationRequest)
        nsView.preferredFramesPerSecond = scene.preferredFramesPerSecond
    }

    static func dismantleNSView(_ nsView: GraphSKView, coordinator: Coordinator) {
        nsView.isPaused = true
        coordinator.scene?.teardownForRemoval()
        coordinator.scene = nil
        nsView.presentScene(nil)
        nsView.delegate = nil
    }

    internal final class Coordinator {
        internal var parent: GraphRepresentable
        internal var scene: ObsidianGraphScene?

        internal init(parent: GraphRepresentable) {
            self.parent = parent
        }
    }
}

internal final class GraphSKView: SKView {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPaused = window == nil
        window?.acceptsMouseMovedEvents = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let graphScene = scene as? ObsidianGraphScene else {
            super.rightMouseDown(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let menu = graphScene.contextMenu(at: viewPoint) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let graphScene = scene as? ObsidianGraphScene else {
            super.magnify(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        graphScene.magnify(by: event.magnification, at: viewPoint, in: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let graphScene = scene as? ObsidianGraphScene else {
            super.scrollWheel(with: event)
            return
        }
        graphScene.scrollWheel(with: event)
    }
}
