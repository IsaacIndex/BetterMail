import AppKit
import SpriteKit

/// BetterMail's native Obsidian-style graph adapter. It consumes the existing
/// GraphData projection and emits the same selection/action callbacks as the
/// previous botanical renderer, while owning only layout and interaction.
internal final class ObsidianGraphScene: SKScene {
    internal static let activeFramesPerSecond = 60
    internal static let idleFramesPerSecond = 12

    private static let pruneEdgeHitTolerance: CGFloat = 14
    private static let folderDropMagnetRadius: CGFloat = 44
    private static let interactionFrameWindow: TimeInterval = 1.1
    private static let maximumSettlingFrames = 240
    private static let reducedMotionSettlingFrames = 48

    internal var onSelectGraphNode: ((String?, Bool) -> Void)?
    internal var onExpandRemainingBranches: ((String) -> Void)?
    internal var onHoverItem: ((GraphHoverItem?) -> Void)?
    internal var onWaterThread: ((String) -> Void)?
    internal var onToggleActionItem: ((String) -> Void)?
    internal var isActionItem: ((String) -> Bool)?
    internal var onMoveThreadToFolder: ((String, String) -> Void)?
    internal var onSnipTarget: ((GraphSnipTarget) -> Void)?
    internal var onPruneThread: ((String) -> Void)?
    internal var onPruneAnimationFinished: ((UUID) -> Void)?
    internal var onViewportChanged: ((CGFloat, CGPoint) -> Void)?
    internal var onPositionsChanged: (([String: CGPoint]) -> Void)?
    internal var onFrameRatePreferenceChanged: ((Int) -> Void)?

    internal var preferredFramesPerSecond: Int {
        needsActiveFrameRate ? Self.activeFramesPerSecond : Self.idleFramesPerSecond
    }

    private final class EdgeVisual {
        let line = SKShapeNode()
        let arrow = SKShapeNode()

        init() {
            line.fillColor = .clear
            line.lineCap = .round
            line.lineJoin = .round
            line.isAntialiased = true
            line.zPosition = -10
            arrow.fillColor = .clear
            arrow.lineCap = .round
            arrow.lineJoin = .round
            arrow.isAntialiased = true
            arrow.zPosition = -9
        }
    }

    private var graphData: GraphData = .empty
    private var simulator = ObsidianGraphForceSimulator()
    private var graphNodesByID: [String: ObsidianGraphSceneNode] = [:]
    private var edgeVisualsByID: [String: EdgeVisual] = [:]
    private var neighborIDsByNodeID: [String: Set<String>] = [:]
    private var forceConfig = ObsidianGraphForceConfig.defaults
    private var displayConfig = ObsidianGraphDisplayConfig.defaults
    private var theme = DesignTokens.Graph.AppTheme.Palette(isDark: false)
    private var selectedGraphNodeIDs: Set<String> = []
    private var hoveredGraphNodeID: String?
    private var pruneMode: GraphPruneMode = .idle
    private var filteredNodeIDs: Set<String> = []
    private var wateredCounts: [String: Int] = [:]
    private var reduceMotion = false
    private var textScale: CGFloat = 1
    private var sproutingMessageIDs: Set<String> = []
    private var stagedSnipThreadIDs: Set<String> = []
    private var fullyStagedSnipGroupingIDs: Set<String> = []
    private var partiallyStagedSnipGroupingIDs: Set<String> = []

    private var lastUpdateTime: TimeInterval?
    private var lastInteractionTime: TimeInterval?
    private var lastPositionReportTime: TimeInterval = 0
    private var settlingFrames = 0
    private var stableFrames = 0
    private var layoutIsSettled = false
    private var positionsReportedAfterSettling = false
    private var publishedFramesPerSecond = ObsidianGraphScene.activeFramesPerSecond

    private var draggedNodeID: String?
    private var draggedNodeOffset = CGPoint.zero
    private var activeFolderDropTarget: GraphFolderDropTarget?
    private var hasDraggedNode = false
    private var isPanning = false
    private var hasPanned = false
    private var pendingSelectionID: String?
    private var pendingSelectionIsAdditive = false
    private var hasPendingSelection = false

    private var runningPruneAnimationID: UUID?
    private var runningSnipVisualTransitionID: UUID?
    private var remainingPruneAnimationNodes = 0
    private let cameraNode = SKCameraNode()

    override init(size: CGSize) {
        super.init(size: size)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    internal func configure(data: GraphData,
                            selectedGraphNodeID: String?,
                            selectedGraphNodeIDs: Set<String> = [],
                            pruneMode: GraphPruneMode,
                            filteredNodeIDs: Set<String>,
                            wateredCounts: [String: Int],
                            reduceMotion: Bool,
                            sproutingMessageIDs: Set<String>,
                            forceConfig: ObsidianGraphForceConfig,
                            displayConfig: ObsidianGraphDisplayConfig,
                            theme: DesignTokens.Graph.AppTheme.Palette,
                            textScale: CGFloat = 1,
                            zoomScale: CGFloat,
                            panOffset: CGPoint,
                            stagedSnipThreadIDs: Set<String> = [],
                            fullyStagedSnipGroupingIDs: Set<String> = [],
                            partiallyStagedSnipGroupingIDs: Set<String> = [],
                            snipVisualTransition: GraphSnipVisualTransition? = nil,
                            pruneAnimationRequest: GraphPruneAnimationRequest? = nil) {
        let dataChanged = data != graphData
        let themeChanged = theme != self.theme
        let textScaleChanged = textScale != self.textScale
        let forceChanged = forceConfig != self.forceConfig
        let displayChanged = displayConfig != self.displayConfig
        let reduceMotionChanged = reduceMotion != self.reduceMotion

        graphData = data
        if dataChanged, hoveredGraphNodeID != nil {
            hoveredGraphNodeID = nil
            onHoverItem?(nil)
        }
        if dataChanged {
            activeFolderDropTarget = nil
        }
        self.selectedGraphNodeIDs = selectedGraphNodeIDs.intersection(data.allNodeIDs)
        if let selectedGraphNodeID,
           data.allNodeIDs.contains(selectedGraphNodeID) {
            self.selectedGraphNodeIDs.insert(selectedGraphNodeID)
        }
        self.pruneMode = pruneMode
        self.filteredNodeIDs = filteredNodeIDs
        self.wateredCounts = wateredCounts
        self.reduceMotion = reduceMotion
        self.sproutingMessageIDs = sproutingMessageIDs
        self.stagedSnipThreadIDs = stagedSnipThreadIDs
        self.fullyStagedSnipGroupingIDs = fullyStagedSnipGroupingIDs
        self.partiallyStagedSnipGroupingIDs = partiallyStagedSnipGroupingIDs
        self.forceConfig = forceConfig
        self.displayConfig = displayConfig
        self.theme = theme
        self.textScale = textScale

        applyViewport(zoomScale: zoomScale, panOffset: panOffset)
        if dataChanged || themeChanged || textScaleChanged || simulator.size != size {
            rebuildGraph(restartLayout: dataChanged || simulator.nodesByID.isEmpty)
        } else {
            if forceChanged || reduceMotionChanged {
                wakeLayout()
            }
            if displayChanged {
                applyNodeScale()
            }
            renderGraph()
        }
        applyVisualState()
        startSnipVisualTransitionIfNeeded(snipVisualTransition)
        startPruneAnimationIfNeeded(pruneAnimationRequest)
        publishFrameRatePreferenceIfNeeded()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard size.width > 0, size.height > 0 else { return }
        let currentPositions = simulator.positionsByID()
        simulator.reset(data: graphData,
                        size: size,
                        preserving: currentPositions,
                        config: forceConfig)
        let oldCenter = CGPoint(x: oldSize.width / 2, y: oldSize.height / 2)
        let pan = CGPoint(x: cameraNode.position.x - oldCenter.x,
                          y: cameraNode.position.y - oldCenter.y)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraNode.position = CGPoint(x: center.x + pan.x, y: center.y + pan.y)
        wakeLayout()
        renderGraph()
    }

    override func update(_ currentTime: TimeInterval) {
        let previousTime = lastUpdateTime ?? currentTime
        lastUpdateTime = currentTime
        let shouldSimulate = !layoutIsSettled || draggedNodeID != nil
        if shouldSimulate {
            simulator.step(deltaTime: min(max(currentTime - previousTime, 1.0 / 240.0), 1.0 / 20.0),
                           reduceMotion: reduceMotion,
                           config: forceConfig)
            updateSettlingState()
            renderGraph()
        }
        if shouldReportPositions,
           currentTime - lastPositionReportTime >= 0.2 {
            lastPositionReportTime = currentTime
            onPositionsChanged?(simulator.positionsByID())
            if layoutIsSettled {
                positionsReportedAfterSettling = true
            }
        }
        publishFrameRatePreferenceIfNeeded()
    }

    internal func teardownForRemoval() {
        isPaused = true
        layoutIsSettled = true
        positionsReportedAfterSettling = true
        runningPruneAnimationID = nil
        remainingPruneAnimationNodes = 0
        graphNodesByID.values.forEach {
            $0.removeAllActions()
            $0.removeFromParent()
        }
        edgeVisualsByID.values.forEach { visual in
            visual.line.removeAllActions()
            visual.arrow.removeAllActions()
            visual.line.removeFromParent()
            visual.arrow.removeFromParent()
        }
        graphNodesByID.removeAll()
        edgeVisualsByID.removeAll()
        neighborIDsByNodeID.removeAll()
        onSelectGraphNode = nil
        onExpandRemainingBranches = nil
        onHoverItem = nil
        onWaterThread = nil
        onToggleActionItem = nil
        isActionItem = nil
        onMoveThreadToFolder = nil
        onSnipTarget = nil
        onPruneThread = nil
        onPruneAnimationFinished = nil
        onViewportChanged = nil
        onPositionsChanged = nil
        onFrameRatePreferenceChanged = nil
        selectedGraphNodeIDs = []
        hoveredGraphNodeID = nil
        pendingSelectionID = nil
        pendingSelectionIsAdditive = false
        draggedNodeID = nil
        activeFolderDropTarget = nil
        graphData = .empty
        simulator = ObsidianGraphForceSimulator()
        filteredNodeIDs = []
        wateredCounts = [:]
        sproutingMessageIDs = []
        stagedSnipThreadIDs = []
        fullyStagedSnipGroupingIDs = []
        partiallyStagedSnipGroupingIDs = []
        runningSnipVisualTransitionID = nil
        lastUpdateTime = nil
        lastInteractionTime = nil
        removeAllActions()
        removeAllChildren()
    }

    override func mouseDown(with event: NSEvent) {
        markInteraction()
        setActiveFolderDropTarget(nil)
        hasPanned = false
        hasDraggedNode = false
        hasPendingSelection = false
        pendingSelectionID = nil
        pendingSelectionIsAdditive = false
        let location = event.location(in: self)
        let hitNodeID = hitTestNodeID(at: location)

        if pruneMode == .snip {
            if let target = nearestSnipTarget(to: location)
                ?? hitNodeID.flatMap(snipTarget(forGraphNodeID:)) {
                onSnipTarget?(target)
                return
            }
        } else if pruneMode == .archive {
            if let threadID = nearestEdgeThreadID(to: location)
                ?? hitNodeID.flatMap({ threadID(forGraphNodeID: $0) }) {
                onPruneThread?(threadID)
                return
            }
        }

        if let hitNodeID {
            if expandRemainingBranchIfPresent(nodeID: hitNodeID) {
                return
            }
            if event.clickCount >= 2,
               graphData.threadByID[hitNodeID] != nil,
               let threadID = threadID(forGraphNodeID: hitNodeID) {
                onWaterThread?(threadID)
                graphNodesByID[hitNodeID]?.runWaterPulse(reduceMotion: reduceMotion)
                return
            }
            pendingSelectionID = hitNodeID
            pendingSelectionIsAdditive = event.modifierFlags.contains(.command)
            hasPendingSelection = true
            if let physicsNode = simulator.nodesByID[hitNodeID] {
                draggedNodeID = hitNodeID
                draggedNodeOffset = CGPoint(x: physicsNode.position.x - location.x,
                                            y: physicsNode.position.y - location.y)
            }
            return
        }

        pendingSelectionID = nil
        hasPendingSelection = true
        isPanning = true
        if event.clickCount >= 2 {
            hasPendingSelection = false
            isPanning = false
            onSelectGraphNode?(nil, false)
            recenterCamera(animated: true)
        }
    }

    @discardableResult
    internal func expandRemainingBranchIfPresent(nodeID: String) -> Bool {
        guard let remaining = graphData.remainingBranchByID[nodeID] else { return false }
        onExpandRemainingBranches?(remaining.parentID)
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        markInteraction()
        clearHover()
        let location = event.location(in: self)
        if let draggedNodeID {
            let target = CGPoint(x: location.x + draggedNodeOffset.x,
                                 y: location.y + draggedNodeOffset.y)
            if !hasDraggedNode {
                simulator.beginDragging(
                    nodeID: draggedNodeID,
                    keepingStationary: stationaryFolderDropNodeIDs(
                        forDraggedGraphNodeID: draggedNodeID
                    )
                )
            }
            hasDraggedNode = true
            hasPendingSelection = false
            simulator.drag(nodeID: draggedNodeID, to: target)
            setActiveFolderDropTarget(folderDropTarget(at: location,
                                                       draggedGraphNodeID: draggedNodeID))
            wakeLayout()
            renderGraph()
            return
        }
        guard isPanning else { return }
        hasPanned = true
        hasPendingSelection = false
        panBy(deltaX: event.deltaX, deltaY: event.deltaY)
        publishViewport()
    }

    override func mouseUp(with event: NSEvent) {
        markInteraction()
        if let draggedNodeID, hasDraggedNode {
            let location = event.location(in: self)
            simulator.endDragging(nodeID: draggedNodeID,
                                  at: CGPoint(x: location.x + draggedNodeOffset.x,
                                              y: location.y + draggedNodeOffset.y))
            performFolderDrop(at: location, draggedGraphNodeID: draggedNodeID)
            wakeLayout()
        } else if hasPendingSelection && !hasPanned {
            onSelectGraphNode?(pendingSelectionID, pendingSelectionIsAdditive)
        }
        draggedNodeID = nil
        draggedNodeOffset = .zero
        setActiveFolderDropTarget(nil)
        hasDraggedNode = false
        isPanning = false
        hasPanned = false
        pendingSelectionID = nil
        pendingSelectionIsAdditive = false
        hasPendingSelection = false
        publishFrameRatePreferenceIfNeeded()
    }

    override func rightMouseDown(with event: NSEvent) {
        markInteraction()
        clearHover()
        isPanning = true
        hasPanned = false
        hasPendingSelection = false
        pendingSelectionIsAdditive = false
    }

    override func rightMouseDragged(with event: NSEvent) {
        markInteraction()
        guard isPanning else { return }
        hasPanned = true
        panBy(deltaX: event.deltaX, deltaY: event.deltaY)
        publishViewport()
    }

    override func rightMouseUp(with event: NSEvent) {
        markInteraction()
        isPanning = false
        hasPanned = false
    }

    internal func contextMenu(at viewPoint: CGPoint) -> NSMenu? {
        let location = convertPoint(fromView: viewPoint)
        guard let graphNodeID = hitTestNodeID(at: location) else { return nil }
        markInteraction()
        clearHover()
        return actionItemContextMenu(forGraphNodeID: graphNodeID)
    }

    internal func actionItemContextMenu(forGraphNodeID graphNodeID: String) -> NSMenu? {
        guard pruneMode == .idle,
              graphData.threadByID[graphNodeID] != nil || graphData.messageByID[graphNodeID] != nil,
              let onToggleActionItem else {
            return nil
        }

        onSelectGraphNode?(graphNodeID, false)
        let isActionItem = isActionItem?(graphNodeID) ?? false
        let title = isActionItem
            ? NSLocalizedString("graph.actions.remove_action_item",
                                comment: "Remove selected graph email from action items")
            : NSLocalizedString("graph.actions.action_item",
                                comment: "Mark selected graph email as an action item")
        let action = GraphContextMenuAction {
            onToggleActionItem(graphNodeID)
        }
        let item = NSMenuItem(title: title,
                              action: #selector(GraphContextMenuAction.perform(_:)),
                              keyEquivalent: "")
        item.image = NSImage(systemSymbolName: isActionItem ? "checkmark.circle.fill" : "bolt.circle",
                             accessibilityDescription: title)
        item.target = action
        item.representedObject = action
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }

    override func mouseMoved(with event: NSEvent) {
        markInteraction()
        guard draggedNodeID == nil, !isPanning else {
            clearHover()
            return
        }
        let location = event.location(in: self)
        applyHoverCandidate(hitTestNodeID(at: location), at: location)
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func scrollWheel(with event: NSEvent) {
        markInteraction()
        clearHover()
        let shouldZoom = event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.control)
        guard shouldZoom else {
            panBy(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            publishViewport()
            return
        }
        let delta = event.scrollingDeltaY == 0 ? -event.scrollingDeltaX : event.scrollingDeltaY
        let nextZoom = currentZoomScale * exp(delta * -0.005)
        setZoom(nextZoom, around: event.location(in: self))
        publishViewport()
    }

    internal func magnify(by magnification: CGFloat,
                          at viewPoint: CGPoint,
                          in view: SKView) {
        markInteraction()
        clearHover()
        let focus = convertPoint(fromView: viewPoint)
        let nextZoom = currentZoomScale * max(0.2, 1 + magnification)
        setZoom(nextZoom, around: focus)
        publishViewport()
    }

    internal func applyHoverCandidate(_ nextHoveredID: String?, at location: CGPoint) {
        if hoveredGraphNodeID != nextHoveredID {
            hoveredGraphNodeID = nextHoveredID
            applyVisualState()
        }
        guard let nextHoveredID else {
            onHoverItem?(nil)
            return
        }
        let overlayLocation = overlayPoint(for: location)
        if let grouping = graphData.groupingByID[nextHoveredID] {
            onHoverItem?(.grouping(grouping, overlayLocation))
        } else if let thread = graphData.threadByID[nextHoveredID] {
            onHoverItem?(.thread(thread, overlayLocation))
        } else if let remaining = graphData.remainingBranchByID[nextHoveredID] {
            onHoverItem?(.remaining(remaining, overlayLocation))
        } else if let message = graphData.messageByID[nextHoveredID] {
            onHoverItem?(.message(message, overlayLocation))
        } else {
            onHoverItem?(nil)
        }
    }

    private func commonInit() {
        backgroundColor = theme.backgroundNS
        anchorPoint = .zero
        scaleMode = .resizeFill
        camera = cameraNode
        addChild(cameraNode)
    }

    private func rebuildGraph(restartLayout: Bool) {
        runningPruneAnimationID = nil
        remainingPruneAnimationNodes = 0
        let existingPositions = simulator.positionsByID()
        simulator.reset(data: graphData,
                        size: size,
                        preserving: existingPositions,
                        config: forceConfig)

        graphNodesByID.values.forEach { $0.removeFromParent() }
        edgeVisualsByID.values.forEach {
            $0.line.removeFromParent()
            $0.arrow.removeFromParent()
        }
        graphNodesByID.removeAll(keepingCapacity: true)
        edgeVisualsByID.removeAll(keepingCapacity: true)

        for physicsNode in simulator.nodes {
            let descriptor = nodeDescriptor(for: physicsNode)
            let node = ObsidianGraphSceneNode(graphID: physicsNode.id,
                                              kind: physicsNode.kind,
                                              threadID: descriptor.threadID,
                                              radius: physicsNode.radius,
                                              title: descriptor.title,
                                              fillColor: descriptor.fill,
                                              strokeColor: descriptor.stroke,
                                              textScale: textScale,
                                              theme: theme)
            node.zPosition = 2
            node.position = physicsNode.position
            if let remaining = graphData.remainingBranchByID[physicsNode.id] {
                node.configureExpansionAccessibility(label: remaining.accessibilityLabel) { [weak self] in
                    _ = self?.expandRemainingBranchIfPresent(nodeID: remaining.id)
                }
            }
            graphNodesByID[physicsNode.id] = node
            addChild(node)
            if sproutingMessageIDs.contains(physicsNode.id) {
                node.runSprout(reduceMotion: reduceMotion)
            }
        }

        for edge in graphData.edges {
            let visual = EdgeVisual()
            edgeVisualsByID[edge.id] = visual
            addChild(visual.line)
            addChild(visual.arrow)
        }
        neighborIDsByNodeID = graphData.allNodeIDs.reduce(into: [:]) { result, id in
            result[id] = simulator.neighborIDs(of: id)
        }
        applyNodeScale()
        backgroundColor = theme.backgroundNS
        if restartLayout {
            wakeLayout()
        } else {
            layoutIsSettled = true
            positionsReportedAfterSettling = false
        }
        renderGraph()
    }

    private func renderGraph() {
        for physicsNode in simulator.nodes {
            graphNodesByID[physicsNode.id]?.position = physicsNode.position
        }
        for edge in graphData.edges {
            render(edge: edge)
        }
        updateLabels()
    }

    private func render(edge: GraphEdge) {
        guard let visual = edgeVisualsByID[edge.id],
              let source = simulator.nodesByID[edge.sourceID],
              let target = simulator.nodesByID[edge.targetID] else { return }
        let geometry = trimmedEdge(source: source, target: target)
        visual.line.path = edge.kind == .suggested || edge.kind == .remaining
            ? Self.dashedLinePath(from: geometry.start, to: geometry.end)
            : Self.linePath(from: geometry.start, to: geometry.end)
        visual.arrow.path = Self.arrowPath(from: geometry.start, to: geometry.end)
        visual.arrow.isHidden = !displayConfig.showsArrows
        applyStyle(to: visual, edge: edge)
    }

    private func applyVisualState() {
        let focusedNodeIDs = interactionFocusedNodeIDs
        let neighbors = Set(focusedNodeIDs.flatMap { neighborIDsByNodeID[$0] ?? [] })
        for (id, node) in graphNodesByID {
            let isSelected = selectedGraphNodeIDs.contains(id)
            let isHovered = hoveredGraphNodeID == id || activeFolderDropTarget?.graphNodeID == id
            let isNeighbor = neighbors.contains(id)
            let isFiltered = !filteredNodeIDs.isEmpty && !filteredNodeIDs.contains(id)
            let snipState: GraphSnipNodeState
            if node.threadID.map(stagedSnipThreadIDs.contains) == true ||
                fullyStagedSnipGroupingIDs.contains(id) {
                snipState = .staged
            } else if partiallyStagedSnipGroupingIDs.contains(id) {
                snipState = .partial
            } else {
                snipState = .normal
            }
            node.applyFocus(isSelected: isSelected,
                            isHovered: isHovered,
                            isNeighbor: isNeighbor,
                            isDimmed: isFiltered,
                            hasFocusedNode: !focusedNodeIDs.isEmpty,
                            snipState: snipState)
        }
        for edge in graphData.edges {
            guard let visual = edgeVisualsByID[edge.id] else { continue }
            applyStyle(to: visual, edge: edge)
        }
        updateLabels()
    }

    private func applyStyle(to visual: EdgeVisual, edge: GraphEdge) {
        let focusedNodeIDs = interactionFocusedNodeIDs
        let isConnected = focusedNodeIDs.isEmpty
            || focusedNodeIDs.contains(edge.sourceID)
            || focusedNodeIDs.contains(edge.targetID)
        let isFiltered = !filteredNodeIDs.isEmpty
            && (!filteredNodeIDs.contains(edge.sourceID) || !filteredNodeIDs.contains(edge.targetID))
        let baseColor: NSColor
        switch edge.kind {
        case .suggested:
            baseColor = theme.accentNS
        case .remaining:
            baseColor = theme.archiveNS
        case .trunk, .grouping, .chain:
            baseColor = theme.inkTertiaryNS
        }
        let isStaged = stagedSnipThreadIDs.contains(edge.threadID) ||
            fullyStagedSnipGroupingIDs.contains(edge.sourceID) ||
            fullyStagedSnipGroupingIDs.contains(edge.targetID)
        let isPartiallyStaged = partiallyStagedSnipGroupingIDs.contains(edge.sourceID) ||
            partiallyStagedSnipGroupingIDs.contains(edge.targetID)
        let alpha: CGFloat
        if isFiltered {
            alpha = 0.08
        } else if isStaged {
            alpha = 0.24
        } else if isPartiallyStaged {
            alpha = 0.38
        } else {
            alpha = isConnected ? 0.58 : 0.10
        }
        let activeBaseColor = isStaged || isPartiallyStaged
            ? theme.snipNS
            : (isConnected && !focusedNodeIDs.isEmpty ? theme.accentNS : baseColor)
        let color = activeBaseColor.withAlphaComponent(alpha)
        visual.line.strokeColor = color
        visual.line.lineWidth = displayConfig.linkThickness * (isConnected && !focusedNodeIDs.isEmpty ? 1.35 : 1)
        visual.arrow.strokeColor = color
        visual.arrow.lineWidth = max(0.8, displayConfig.linkThickness)
    }

    private func updateLabels() {
        let focusedNodeIDs = interactionFocusedNodeIDs
        let visibleNodeIDs = selectedGraphNodeIDs.union(focusedNodeIDs)
        let neighbors = Set(focusedNodeIDs.flatMap { neighborIDsByNodeID[$0] ?? [] })
        for (id, node) in graphNodesByID {
            node.updateLabel(zoomScale: currentZoomScale,
                             threshold: displayConfig.textFadeThreshold,
                             forceVisible: visibleNodeIDs.contains(id) || neighbors.contains(id))
        }
    }

    private func applyNodeScale() {
        for node in graphNodesByID.values {
            node.setNodeScale(displayConfig.nodeSize)
        }
    }

    private func nodeDescriptor(for physicsNode: ObsidianGraphPhysicsNode)
    -> (title: String?, threadID: String?, fill: NSColor, stroke: NSColor) {
        if physicsNode.kind == .center {
            return (graphData.center.title, nil, theme.accentNS, theme.accentNS)
        }
        if let grouping = graphData.groupingByID[physicsNode.id] {
            return (grouping.title,
                    nil,
                    grouping.isSuggestion ? theme.panelSecondaryNS : theme.accentSoftNS,
                    theme.accentNS)
        }
        if let thread = graphData.threadByID[physicsNode.id] {
            let stroke = thread.isLive ? theme.liveNS : strokeColor(for: thread.importance)
            return (thread.displayTitle, thread.id, theme.panelNS, stroke)
        }
        if let remaining = graphData.remainingBranchByID[physicsNode.id] {
            return (remaining.title, nil, theme.panelSecondaryNS, theme.archiveNS)
        }
        if let message = graphData.messageByID[physicsNode.id] {
            return (message.displayTitle,
                    message.threadID,
                    message.unread ? theme.accentNS : theme.panelNS,
                    message.unread ? theme.accentNS : theme.inkTertiaryNS)
        }
        return (nil, nil, theme.panelNS, theme.inkTertiaryNS)
    }

    private func strokeColor(for importance: GraphImportance) -> NSColor {
        switch importance {
        case .low: return theme.inkQuaternaryNS
        case .medium: return theme.inkSecondaryNS
        case .high: return theme.inkNS
        }
    }

    private func clearHover() {
        guard hoveredGraphNodeID != nil else { return }
        hoveredGraphNodeID = nil
        onHoverItem?(nil)
        applyVisualState()
    }

    private var interactionFocusedNodeIDs: Set<String> {
        if let activeFolderDropTarget {
            return Set([activeFolderDropTarget.graphNodeID, draggedNodeID].compactMap { $0 })
        }
        return hoveredGraphNodeID.map { Set([$0]) } ?? selectedGraphNodeIDs
    }

    private func setActiveFolderDropTarget(_ target: GraphFolderDropTarget?) {
        guard target != activeFolderDropTarget else { return }
        activeFolderDropTarget = target
        applyVisualState()
    }

    private func overlayPoint(for scenePoint: CGPoint) -> CGPoint {
        let scale = max(cameraNode.xScale, 0.001)
        return CGPoint(x: (scenePoint.x - cameraNode.position.x) / scale + size.width / 2,
                       y: (scenePoint.y - cameraNode.position.y) / scale + size.height / 2)
    }

    private func applyViewport(zoomScale: CGFloat, panOffset: CGPoint) {
        let zoom = GraphViewport.clampedZoom(zoomScale)
        cameraNode.setScale(1 / zoom)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraNode.position = CGPoint(x: center.x + panOffset.x,
                                      y: center.y + panOffset.y)
        updateLabels()
    }

    private var currentZoomScale: CGFloat {
        1 / max(cameraNode.xScale, 0.001)
    }

    private func setZoom(_ zoomScale: CGFloat, around focus: CGPoint?) {
        let nextScale = 1 / GraphViewport.clampedZoom(zoomScale)
        let previousScale = max(cameraNode.xScale, 0.001)
        let previousPosition = cameraNode.position
        cameraNode.setScale(nextScale)
        if let focus {
            let ratio = nextScale / previousScale
            cameraNode.position = CGPoint(x: focus.x - (focus.x - previousPosition.x) * ratio,
                                          y: focus.y - (focus.y - previousPosition.y) * ratio)
        }
        updateLabels()
    }

    private func panBy(deltaX: CGFloat, deltaY: CGFloat) {
        cameraNode.position = CGPoint(x: cameraNode.position.x - deltaX * cameraNode.xScale,
                                      y: cameraNode.position.y + deltaY * cameraNode.yScale)
    }

    internal func recenterCamera(animated: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraNode.removeAction(forKey: "obsidian-camera-recenter")
        guard animated && !reduceMotion else {
            cameraNode.position = center
            cameraNode.setScale(1)
            updateLabels()
            publishViewport()
            return
        }
        cameraNode.run(.sequence([
            .group([.move(to: center, duration: 0.22), .scale(to: 1, duration: 0.22)]),
            .run { [weak self] in
                self?.updateLabels()
                self?.publishViewport()
            }
        ]), withKey: "obsidian-camera-recenter")
    }

    private func publishViewport() {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        onViewportChanged?(currentZoomScale,
                           CGPoint(x: cameraNode.position.x - center.x,
                                   y: cameraNode.position.y - center.y))
    }

    private func wakeLayout() {
        settlingFrames = 0
        stableFrames = 0
        layoutIsSettled = simulator.nodesByID.count <= 1
        positionsReportedAfterSettling = false
        publishFrameRatePreferenceIfNeeded()
    }

    private func updateSettlingState() {
        guard draggedNodeID == nil else { return }
        settlingFrames += 1
        let energyPerNode = simulator.totalEnergy() / CGFloat(max(simulator.nodesByID.count, 1))
        stableFrames = energyPerNode < 0.035 ? stableFrames + 1 : 0
        let frameLimit = reduceMotion ? Self.reducedMotionSettlingFrames : Self.maximumSettlingFrames
        if stableFrames >= 12 || settlingFrames >= frameLimit {
            simulator.stopMotion()
            layoutIsSettled = true
        }
    }

    private var shouldReportPositions: Bool {
        !layoutIsSettled || !positionsReportedAfterSettling
    }

    private var needsActiveFrameRate: Bool {
        !layoutIsSettled
            || draggedNodeID != nil
            || isPanning
            || hasRecentInteraction
            || cameraNode.hasActions()
            || graphNodesByID.values.contains { $0.hasActions() }
    }

    private var hasRecentInteraction: Bool {
        guard let lastInteractionTime, let lastUpdateTime else { return false }
        return lastUpdateTime - lastInteractionTime < Self.interactionFrameWindow
    }

    private func markInteraction() {
        lastInteractionTime = lastUpdateTime ?? 0
        publishFrameRatePreferenceIfNeeded()
    }

    private func publishFrameRatePreferenceIfNeeded() {
        let next = preferredFramesPerSecond
        guard next != publishedFramesPerSecond else { return }
        publishedFramesPerSecond = next
        onFrameRatePreferenceChanged?(next)
    }

    /// Hit-tests only the visible circular mark. Labels intentionally remain
    /// pointer-transparent so text never selects or drags a node.
    internal func hitTestNodeID(at location: CGPoint) -> String? {
        let scale = max(displayConfig.nodeSize, 0.55)
        var bestNodeID: String?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for node in simulator.nodes {
            let radius = node.radius * scale
            let distance = hypot(node.position.x - location.x, node.position.y - location.y)
            guard distance <= radius else { continue }
            if distance < bestDistance {
                bestDistance = distance
                bestNodeID = node.id
            }
        }
        return bestNodeID
    }

    internal func folderDropTarget(at location: CGPoint,
                                   draggedGraphNodeID: String) -> GraphFolderDropTarget? {
        guard let rawThreadID = rawThreadID(forGraphNodeID: draggedGraphNodeID) else { return nil }
        let scale = max(displayConfig.nodeSize, 0.55)
        let zoomAdjustedMagnetRadius = Self.folderDropMagnetRadius * max(cameraNode.xScale, 0.2)

        return graphData.groupings.compactMap { grouping -> (CGFloat, GraphFolderDropTarget)? in
            guard grouping.kind == .folder,
                  let folderID = grouping.sourceFolderID,
                  !grouping.rawThreadIDs.contains(rawThreadID),
                  let folderNode = simulator.nodesByID[grouping.id] else {
                return nil
            }
            let distance = hypot(folderNode.position.x - location.x,
                                 folderNode.position.y - location.y)
            let dropRadius = max(folderNode.radius * scale, zoomAdjustedMagnetRadius)
            guard distance <= dropRadius else { return nil }
            return (distance,
                    GraphFolderDropTarget(graphNodeID: grouping.id,
                                          rawThreadID: rawThreadID,
                                          folderID: folderID))
        }
        .min { $0.0 < $1.0 }?.1
    }

    internal func stationaryFolderDropNodeIDs(forDraggedGraphNodeID graphNodeID: String) -> Set<String> {
        guard let rawThreadID = rawThreadID(forGraphNodeID: graphNodeID) else { return [] }
        return Set(graphData.groupings.compactMap { grouping in
            guard grouping.kind == .folder,
                  grouping.sourceFolderID != nil,
                  !grouping.rawThreadIDs.contains(rawThreadID) else {
                return nil
            }
            return grouping.id
        })
    }

    @discardableResult
    internal func performFolderDrop(at location: CGPoint,
                                    draggedGraphNodeID: String) -> Bool {
        guard let target = folderDropTarget(at: location,
                                            draggedGraphNodeID: draggedGraphNodeID),
              let onMoveThreadToFolder else {
            return false
        }
        onMoveThreadToFolder(target.rawThreadID, target.folderID)
        return true
    }

    private func nearestSnipTarget(to location: CGPoint) -> GraphSnipTarget? {
        let tolerance = Self.pruneEdgeHitTolerance * max(cameraNode.xScale, 0.2)
        return graphData.edges.compactMap { edge -> (GraphSnipTarget, CGFloat)? in
            guard let snipTarget = snipTarget(for: edge),
                  let source = simulator.nodesByID[edge.sourceID],
                  let target = simulator.nodesByID[edge.targetID] else { return nil }
            return (snipTarget,
                    Self.distanceToSegment(location,
                                           source: source.position,
                                           target: target.position))
        }
        .filter { $0.1 <= tolerance }
        .min { $0.1 < $1.1 }?.0
    }

    internal func snipTarget(for edge: GraphEdge) -> GraphSnipTarget? {
        guard edge.kind != .suggested, edge.kind != .remaining else { return nil }
        if edge.kind == .trunk,
           let grouping = graphData.groupingByID[edge.targetID],
           grouping.kind == .folder {
            return .confirmedGroup(grouping.id)
        }
        guard graphData.threadByID[edge.threadID] != nil else { return nil }
        return .thread(edge.threadID)
    }

    internal func snipTarget(forGraphNodeID graphNodeID: String) -> GraphSnipTarget? {
        if let grouping = graphData.groupingByID[graphNodeID], grouping.kind == .folder {
            return .confirmedGroup(grouping.id)
        }
        return threadID(forGraphNodeID: graphNodeID).map(GraphSnipTarget.thread)
    }

    private func nearestEdgeThreadID(to location: CGPoint) -> String? {
        let tolerance = Self.pruneEdgeHitTolerance * max(cameraNode.xScale, 0.2)
        return graphData.edges.compactMap { edge -> (String, CGFloat)? in
            guard edge.kind != .suggested,
                  graphData.threadByID[edge.threadID] != nil,
                  let source = simulator.nodesByID[edge.sourceID],
                  let target = simulator.nodesByID[edge.targetID] else { return nil }
            return (edge.threadID,
                    Self.distanceToSegment(location, source: source.position, target: target.position))
        }
        .filter { $0.1 <= tolerance }
        .min { $0.1 < $1.1 }?.0
    }

    private func threadID(forGraphNodeID graphNodeID: String) -> String? {
        if graphData.threadByID[graphNodeID] != nil { return graphNodeID }
        return graphData.messageByID[graphNodeID]?.threadID
    }

    private func rawThreadID(forGraphNodeID graphNodeID: String) -> String? {
        if let thread = graphData.threadByID[graphNodeID] {
            return thread.rawThreadID
        }
        return graphData.messageByID[graphNodeID]?.rawThreadID
    }

    private func startSnipVisualTransitionIfNeeded(_ transition: GraphSnipVisualTransition?) {
        guard let transition,
              runningSnipVisualTransitionID != transition.id else { return }
        runningSnipVisualTransitionID = transition.id
        let threadIDs = Set(transition.threadIDs)
        let nodes = graphNodesByID.values
            .filter { node in node.threadID.map(threadIDs.contains) == true }
            .sorted { $0.graphID < $1.graphID }
        for (index, node) in nodes.enumerated() {
            let delay = transition.cascades ? min(Double(index) * 0.025, 0.18) : 0
            node.runSnipTransition(transition.change,
                                   reduceMotion: reduceMotion,
                                   delay: delay)
        }
        for edge in graphData.edges where threadIDs.contains(edge.threadID) {
            guard let visual = edgeVisualsByID[edge.id] else { continue }
            visual.line.removeAction(forKey: "obsidian-snip-cut")
            visual.arrow.removeAction(forKey: "obsidian-snip-cut")
            let action: SKAction
            if reduceMotion {
                visual.line.alpha = 0
                visual.arrow.alpha = 0
                action = .fadeAlpha(to: 1, duration: 0.16)
            } else if transition.change == .stage {
                visual.line.alpha = 1
                visual.arrow.alpha = 1
                action = .sequence([.fadeOut(withDuration: 0.06),
                                    .fadeIn(withDuration: 0.14)])
            } else {
                visual.line.alpha = 0.24
                visual.arrow.alpha = 0.24
                action = .fadeIn(withDuration: 0.18)
            }
            visual.line.run(action, withKey: "obsidian-snip-cut")
            visual.arrow.run(action, withKey: "obsidian-snip-cut")
        }
    }

    private func startPruneAnimationIfNeeded(_ request: GraphPruneAnimationRequest?) {
        guard let request, runningPruneAnimationID != request.id else { return }
        let branchNodes = graphNodesByID.values.filter { node in
            node.threadID.map(request.threadIDs.contains) == true
        }
        guard !branchNodes.isEmpty else {
            onPruneAnimationFinished?(request.id)
            return
        }
        runningPruneAnimationID = request.id
        remainingPruneAnimationNodes = branchNodes.count
        for node in branchNodes {
            node.runPrune(action: request.action, reduceMotion: reduceMotion) { [weak self] in
                guard let self, self.runningPruneAnimationID == request.id else { return }
                self.remainingPruneAnimationNodes -= 1
                if self.remainingPruneAnimationNodes <= 0 {
                    self.runningPruneAnimationID = nil
                    self.remainingPruneAnimationNodes = 0
                    self.onPruneAnimationFinished?(request.id)
                }
            }
        }
    }

    private func trimmedEdge(source: ObsidianGraphPhysicsNode,
                             target: ObsidianGraphPhysicsNode) -> (start: CGPoint, end: CGPoint) {
        let dx = target.position.x - source.position.x
        let dy = target.position.y - source.position.y
        let distance = max(hypot(dx, dy), 1)
        let ux = dx / distance
        let uy = dy / distance
        let sourceInset = source.radius * displayConfig.nodeSize + 2
        let targetInset = target.radius * displayConfig.nodeSize + 2
        return (CGPoint(x: source.position.x + ux * sourceInset,
                        y: source.position.y + uy * sourceInset),
                CGPoint(x: target.position.x - ux * targetInset,
                        y: target.position.y - uy * targetInset))
    }

    private static func linePath(from start: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    private static func dashedLinePath(from start: CGPoint,
                                       to end: CGPoint,
                                       dash: CGFloat = 7,
                                       gap: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 0 else { return path }
        let ux = dx / distance
        let uy = dy / distance
        var cursor: CGFloat = 0
        while cursor < distance {
            let segmentEnd = min(cursor + dash, distance)
            path.move(to: CGPoint(x: start.x + ux * cursor, y: start.y + uy * cursor))
            path.addLine(to: CGPoint(x: start.x + ux * segmentEnd, y: start.y + uy * segmentEnd))
            cursor = segmentEnd + gap
        }
        return path
    }

    private static func arrowPath(from start: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return path }
        let ux = dx / distance
        let uy = dy / distance
        let back = CGPoint(x: end.x - ux * 8, y: end.y - uy * 8)
        let perpendicular = CGVector(dx: -uy * 3.5, dy: ux * 3.5)
        path.move(to: CGPoint(x: back.x + perpendicular.dx, y: back.y + perpendicular.dy))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: back.x - perpendicular.dx, y: back.y - perpendicular.dy))
        return path
    }

    private static func distanceToSegment(_ point: CGPoint,
                                          source: CGPoint,
                                          target: CGPoint) -> CGFloat {
        let dx = target.x - source.x
        let dy = target.y - source.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - source.x, point.y - source.y) }
        let t = max(0, min(1, ((point.x - source.x) * dx + (point.y - source.y) * dy) / lengthSquared))
        let projection = CGPoint(x: source.x + t * dx, y: source.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}

internal struct GraphFolderDropTarget: Equatable {
    internal let graphNodeID: String
    internal let rawThreadID: String
    internal let folderID: String
}

internal final class GraphContextMenuAction: NSObject {
    private let handler: () -> Void

    internal init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc internal func perform(_ sender: Any?) {
        handler()
    }
}
