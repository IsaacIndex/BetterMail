import SpriteKit
import SwiftUI

internal struct GraphRepresentable: NSViewRepresentable {
    @ObservedObject internal var graphViewModel: GraphCanvasViewModel
    @ObservedObject internal var settings: GraphCanvasSettings
    internal let selectedNodeID: String?
    internal let selectedNodeIDs: Set<String>
    internal let isLassoSelectionActive: Bool
    internal let reduceMotion: Bool
    internal let colorScheme: ColorScheme
    internal let textScale: CGFloat
    internal let audio: GraphAudio
    internal let onSelectRootNode: (String?, Bool) -> Void
    internal let onSelectGraphNodeWithIntent: (String?, OrganizerPointerSelectionIntent) -> Void
    internal let onLassoGraphNodeIDs: (Set<String>, Bool) -> Void
    internal let onToggleActionItem: (String) -> Void
    internal let isActionItem: (String) -> Bool
    internal let onMoveThreadToFolder: (String, String) -> Void
    internal let onMoveThreadsToFolder: ([String], String) -> Void
    internal let onCreateGroupAtCanvasPoint: ([String], CGPoint, CGPoint) -> Void
    internal let onDropLifecycle: (OrganizerDropLifecycleSignal) -> Void
    internal let onRenderedOrganizerSnapshot: (OrganizerRenderedGraphReceipt) -> Void

    internal func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    internal func makeNSView(context: Context) -> GraphSKView {
        let view = GraphSKView()
        view.allowsTransparency = false
        view.ignoresSiblingOrder = true
        view.shouldCullNonVisibleNodes = true
        view.preferredFramesPerSecond = ObsidianGraphScene.activeFramesPerSecond
        view.registerForDraggedTypes([
            NSPasteboard.PasteboardType(OrganizerRailDragPayload.typeIdentifier)
        ])
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
                onSelectGraphNodeWithIntent(nil, .replace)
                return
            }
            graphViewModel.selectGrouping(id: nil)
            onSelectRootNode(graphViewModel.rootNodeID(forGraphNodeID: graphNodeID), isAdditive)
        }
        scene.onSelectGraphNodeWithIntent = { graphNodeID, intent in
            if let graphNodeID,
               graphViewModel.data.groupingByID[graphNodeID] != nil {
                graphViewModel.selectGrouping(id: graphNodeID)
                onSelectRootNode(nil, false)
                onSelectGraphNodeWithIntent(nil, .replace)
                return
            }
            graphViewModel.selectGrouping(id: nil)
            onSelectGraphNodeWithIntent(graphNodeID, intent)
        }
        scene.onLassoGraphNodeIDs = { graphNodeIDs, additive in
            graphViewModel.selectGrouping(id: nil)
            onLassoGraphNodeIDs(graphNodeIDs, additive)
        }
        scene.onToggleActionItem = onToggleActionItem
        scene.isActionItem = isActionItem
        scene.onMoveThreadToFolder = onMoveThreadToFolder
        scene.onMoveThreadsToFolder = onMoveThreadsToFolder
        scene.onCreateGroupAtCanvasPoint = onCreateGroupAtCanvasPoint
        scene.onDropLifecycle = onDropLifecycle
        let renderFilterGeneration = graphViewModel.organizerRenderFilterGeneration
        scene.onRenderedOrganizerSnapshot = { [weak coordinator = context.coordinator,
                                                weak graphViewModel] snapshot in
            guard let graphViewModel else { return }
            let receipt = graphViewModel.renderedOrganizerReceipt(
                for: snapshot,
                filterGeneration: renderFilterGeneration
            )
            DispatchQueue.main.async { [weak coordinator] in
                coordinator?.parent.onRenderedOrganizerSnapshot(receipt)
            }
        }
        scene.onExpandRemainingBranches = { scope in
            graphViewModel.expandRemaining(scope: scope)
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
            graphViewModel.recordSceneNodePositions(positions, isSettled: false)
        }
        scene.onLayoutSettled = { positions in
            graphViewModel.recordSceneNodePositions(positions, isSettled: true)
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
                        isLassoSelectionActive: isLassoSelectionActive,
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
        nsView.unregisterDraggedTypes()
        nsView.updateGraphAccessibilityElements([])
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

    private var activeRailDragPayload: OrganizerRailDragPayload?
    internal private(set) var graphAccessibilityElements: [ObsidianGraphAccessibilityElement] = []

    internal func updateGraphAccessibilityElements(
        _ elements: [ObsidianGraphAccessibilityElement]
    ) {
        let oldIdentities = graphAccessibilityElements.map(ObjectIdentifier.init)
        let newIdentities = elements.map(ObjectIdentifier.init)
        graphAccessibilityElements = elements
        guard oldIdentities != newIdentities else { return }
        setAccessibilityChildren(elements)
        setAccessibilityVisibleChildren(elements)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53,
           let graphScene = scene as? ObsidianGraphScene {
            graphScene.cancelDirectManipulation()
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowGeometryChanges()
        isPaused = window == nil
        window?.acceptsMouseMovedEvents = true
        (scene as? ObsidianGraphScene)?.refreshRenderedOrganizerSnapshotForWindowState()
        let attachedWindow = window
        DispatchQueue.main.async { [weak self, weak attachedWindow] in
            guard let self, self.window === attachedWindow else { return }
            (self.scene as? ObsidianGraphScene)?
                .refreshRenderedOrganizerSnapshotForWindowState()
        }
    }

    private func observeWindowGeometryChanges() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didMoveNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowGeometryDidChange(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowGeometryDidChange(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
    }

    @objc private func windowGeometryDidChange(_ notification: Notification) {
        (scene as? ObsidianGraphScene)?.refreshRenderedOrganizerSnapshotForWindowState()
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateRailDrag(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateRailDrag(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        activeRailDragPayload = nil
        (scene as? ObsidianGraphScene)?.cancelRailDrag()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateRailDrag(sender) != []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { activeRailDragPayload = nil }
        guard let graphScene = scene as? ObsidianGraphScene,
              let payload = activeRailDragPayload ?? railDragPayload(from: sender) else {
            return false
        }
        let viewPoint = convert(sender.draggingLocation, from: nil)
        return graphScene.performRailDrop(at: viewPoint,
                                          rawThreadIDs: payload.rawThreadIDs)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        activeRailDragPayload = nil
        (scene as? ObsidianGraphScene)?.cancelRailDrag()
    }

    private func updateRailDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let graphScene = scene as? ObsidianGraphScene,
              let payload = activeRailDragPayload ?? railDragPayload(from: sender) else {
            activeRailDragPayload = nil
            (scene as? ObsidianGraphScene)?.cancelRailDrag()
            return []
        }
        activeRailDragPayload = payload
        let viewPoint = convert(sender.draggingLocation, from: nil)
        return graphScene.updateRailDrag(at: viewPoint,
                                         rawThreadIDs: payload.rawThreadIDs) ? .copy : []
    }

    private func railDragPayload(from sender: NSDraggingInfo) -> OrganizerRailDragPayload? {
        let pasteboardType = NSPasteboard.PasteboardType(OrganizerRailDragPayload.typeIdentifier)
        guard let data = sender.draggingPasteboard.data(forType: pasteboardType) else {
            return nil
        }
        return try? OrganizerRailDragPayload.decode(data)
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
