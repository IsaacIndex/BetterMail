import AppKit
import SpriteKit

internal final class GraphScene: SKScene {
    private enum EdgeRenderingMode: Equatable {
        case ribbon
        case stroke
    }

    private static let ribbonEdgeBudget = 420
    private static let pruneEdgeHitTolerance: CGFloat = 14
    private static let settledRibbonSamples = 72
    private static let edgeViewportBucketSize: CGFloat = 80
    private static let layoutSettlingFrameLimit = 120
    private static let localSettlingFrameLimit = 30
    private static let layoutSettledEnergyPerNodeThreshold: CGFloat = 0.04
    private static let interactionActiveFrameWindow: TimeInterval = 1.2
    internal static let activeFramesPerSecond = 30
    internal static let idleFramesPerSecond = 5

    internal var onSelectGraphNode: ((String?) -> Void)?
    internal var onExpandRemainingBranches: ((String) -> Void)?
    internal var onHoverItem: ((GraphHoverItem?) -> Void)?
    internal var onWaterThread: ((String) -> Void)?
    internal var onPruneThread: ((String) -> Void)?
    internal var onPruneAnimationFinished: ((UUID) -> Void)?
    internal var onViewportChanged: ((CGFloat, CGPoint) -> Void)?
    internal var onPositionsChanged: (([String: CGPoint]) -> Void)?
    internal var onFrameRatePreferenceChanged: ((Int) -> Void)?

    internal var preferredFramesPerSecond: Int {
        needsActiveFrameRate ? Self.activeFramesPerSecond : Self.idleFramesPerSecond
    }

    private struct EdgeRenderState: Equatable {
        let mode: EdgeRenderingMode
        let filteredNodeIDs: Set<String>
        let viewportMinXBucket: Int
        let viewportMinYBucket: Int
        let viewportMaxXBucket: Int
        let viewportMaxYBucket: Int
        let settled: Bool
    }

    private var graphData: GraphData = .empty
    private var simulator = GraphForceSimulator()
    private var graphNodesByID: [String: GraphSceneNode] = [:]
    private var summaryCalloutsByID: [String: SummaryCalloutNode] = [:]
    private var summaryAnglesByMessageID: [String: CGFloat] = [:]
    private var forceConfig = GraphForceConstants.defaults
    private let trunkEdgeNode = SKShapeNode()
    private let chainEdgeNode = SKShapeNode()
    private let remainingEdgeNode = SKShapeNode()
    private let dimmedTrunkEdgeNode = SKShapeNode()
    private let dimmedChainEdgeNode = SKShapeNode()
    private let dimmedRemainingEdgeNode = SKShapeNode()
    private var appliedEdgeRenderingMode: EdgeRenderingMode?
    private var theme = DesignTokens.Graph.AppTheme.Palette(isDark: false)
    private var selectedGraphNodeID: String?
    private var hoveredGraphNodeID: String?
    private var isHoverSuspended = false
    private var pruneMode: GraphPruneMode = .idle
    private var filteredNodeIDs: Set<String> = []
    private var edgeSourceByTargetID: [String: String] = [:]
    private var wateredCounts: [String: Int] = [:]
    private var reduceMotion = false
    private var textScale: CGFloat = 1
    private var sproutingMessageIDs: Set<String> = []
    private var lastUpdateTime: TimeInterval?
    private var edgeRenderFrame = 0
    private var layoutSettlingFrames = 0
    private var layoutIsSettled = false
    private var layoutSettledPositionsReported = false
    private var draggedNodeID: String?
    private var draggedNodeOffset: CGPoint?
    private var pendingDraggedNodePosition: CGPoint?
    private var dragStartPosition: CGPoint?
    private var dragInitialPositions: [String: CGPoint] = [:]
    private var dragInitialRestingPositions: [String: CGPoint] = [:]
    private var dragBranchNodeIDs: Set<String> = []
    private var localSettlingNodeIDs: Set<String>?
    private var localSettlingBranchNodeIDs: Set<String>?
    private var localReturningNodeOrigins: [String: CGPoint] = [:]
    private var hasDraggedNode = false
    private var pendingClickSelectionID: String?
    private var hasPendingClickSelection = false
    private var isPanning = false
    private var hasPanned = false
    private var lastInteractionTime: TimeInterval?
    private var lastPositionReportTime: TimeInterval = 0
    private var publishedFramesPerSecond = GraphScene.activeFramesPerSecond
    private var lastRenderedEdgeState: EdgeRenderState?
    private var runningPruneAnimationID: UUID?
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
                            pruneMode: GraphPruneMode,
                            filteredNodeIDs: Set<String>,
                            wateredCounts: [String: Int],
                            reduceMotion: Bool,
                            sproutingMessageIDs: Set<String>,
                            forceConfig: GraphForceConfig,
                            theme: DesignTokens.Graph.AppTheme.Palette,
                            textScale: CGFloat = 1,
                            zoomScale: CGFloat,
                            panOffset: CGPoint,
                            pruneAnimationRequest: GraphPruneAnimationRequest? = nil) {
        let dataChanged = data != graphData
        let textScaleChanged = textScale != self.textScale
        let shouldRebuild = dataChanged || simulator.size != size || theme != self.theme || textScaleChanged
        let themeChanged = theme != self.theme
        let forceConfigChanged = forceConfig != self.forceConfig
        let wasRunningGlobalLayout = !layoutIsSettled &&
            localSettlingNodeIDs == nil &&
            draggedNodeID == nil
        graphData = data
        if dataChanged {
            suspendHoverForInteraction()
        }
        self.forceConfig = forceConfig
        self.theme = theme
        self.selectedGraphNodeID = selectedGraphNodeID
        self.pruneMode = pruneMode
        self.filteredNodeIDs = filteredNodeIDs
        self.wateredCounts = wateredCounts
        self.reduceMotion = reduceMotion
        self.textScale = textScale
        self.sproutingMessageIDs = sproutingMessageIDs
        if themeChanged {
            applyTheme()
        }
        applyViewport(zoomScale: zoomScale, panOffset: panOffset)
        if shouldRebuild {
            runningPruneAnimationID = nil
            remainingPruneAnimationNodes = 0
            rebuildGraph(restartLayout: dataChanged || wasRunningGlobalLayout)
        } else if forceConfigChanged {
            cancelScopedSimulation()
            resetLayoutSettling()
        }
        applyVisualState()
        startPruneAnimationIfNeeded(pruneAnimationRequest)
        publishFrameRatePreferenceIfNeeded()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        let wasRunningGlobalLayout = !layoutIsSettled &&
            localSettlingNodeIDs == nil &&
            draggedNodeID == nil
        let previousCenter = CGPoint(x: oldSize.width / 2, y: oldSize.height / 2)
        let panOffset = CGPoint(x: cameraNode.position.x - previousCenter.x,
                                y: cameraNode.position.y - previousCenter.y)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraNode.position = CGPoint(x: center.x + panOffset.x,
                                      y: center.y + panOffset.y)
        runningPruneAnimationID = nil
        remainingPruneAnimationNodes = 0
        rebuildGraph(restartLayout: wasRunningGlobalLayout)
    }

    override func update(_ currentTime: TimeInterval) {
        let previous = lastUpdateTime ?? currentTime
        lastUpdateTime = currentTime
        let isActivelyDragging = draggedNodeID != nil && hasDraggedNode
        if isActivelyDragging {
            if let draggedNodeID,
               let pendingDraggedNodePosition,
               let dragStartPosition {
                dragBranchNodeIDs = simulator.previewDrag(nodeID: draggedNodeID,
                                                           from: dragStartPosition,
                                                           to: pendingDraggedNodePosition,
                                                           initialPositions: dragInitialPositions)
            }
            let frameDelta = min(max(currentTime - previous, 0.001), 0.032)
            simulator.step(deltaTime: frameDelta,
                           elapsedTime: currentTime * 1_000,
                           reduceMotion: reduceMotion,
                           config: forceConfig,
                           labelOccluderFrame: nil,
                           scope: .dragging(activeNodeID: draggedNodeID ?? "",
                                            branchNodeIDs: dragBranchNodeIDs,
                                            obstacleOrigins: dragInitialPositions))
            renderFromSimulator(elapsedTime: currentTime * 1_000)
        } else if !layoutIsSettled {
            let simulationScope: GraphSimulationScope
            if let localSettlingBranchNodeIDs {
                simulationScope = .localSettling(branchNodeIDs: localSettlingBranchNodeIDs,
                                                  returningNodeOrigins: localReturningNodeOrigins)
            } else {
                simulationScope = .global
            }
            let labelFramesByID = simulationScope.isGlobal ? labelOccluderFramesByID() : [:]
            simulator.step(deltaTime: currentTime - previous,
                           elapsedTime: currentTime * 1_000,
                           reduceMotion: reduceMotion,
                           config: forceConfig,
                           labelOccluderFrame: labelFramesByID.isEmpty
                               ? nil
                               : { labelFramesByID[$0.id] },
                           scope: simulationScope)
            if !layoutIsSettled {
                updateLayoutSettlingState()
            }
            renderFromSimulator(elapsedTime: currentTime * 1_000)
        }
        if shouldReportPositions(),
           currentTime - lastPositionReportTime > 0.2 {
            lastPositionReportTime = currentTime
            onPositionsChanged?(simulator.positionsByID())
            if layoutIsSettled {
                layoutSettledPositionsReported = true
            }
        }
        publishFrameRatePreferenceIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        markInteraction()
        pendingClickSelectionID = nil
        hasPendingClickSelection = false
        hasPanned = false
        let location = event.location(in: self)
        let hitNodeID = nodeID(at: location)
        if pruneMode != .idle {
            if let threadID = nearestEdgeThreadID(to: location) {
                onPruneThread?(threadID)
                return
            }
            if let hitNodeID,
               let threadID = threadID(forGraphNodeID: hitNodeID) {
                onPruneThread?(threadID)
                return
            }
        }
        if let nodeID = hitNodeID {
            if let remaining = graphData.remainingBranchByID[nodeID] {
                onExpandRemainingBranches?(remaining.parentID)
                publishFrameRatePreferenceIfNeeded()
                draggedNodeOffset = nil
                pendingDraggedNodePosition = nil
                clearDragSnapshot()
                hasDraggedNode = false
                return
            }
            if event.clickCount >= 2,
               let threadID = graphNodesByID[nodeID]?.threadID,
               graphNodesByID[nodeID]?.kind == .thread {
                onWaterThread?(threadID)
                graphNodesByID[nodeID]?.runWaterPulse(wateredCount: wateredCounts[threadID, default: 0] + 1,
                                                       reduceMotion: reduceMotion)
                publishFrameRatePreferenceIfNeeded()
                draggedNodeOffset = nil
                pendingDraggedNodePosition = nil
                clearDragSnapshot()
                hasDraggedNode = false
            } else {
                pendingClickSelectionID = nodeID
                hasPendingClickSelection = true
                draggedNodeID = nodeID == GraphCenter.you.id ? nil : nodeID
                if let node = simulator.nodesByID[nodeID] {
                    draggedNodeOffset = CGPoint(x: node.position.x - location.x,
                                               y: node.position.y - location.y)
                    dragStartPosition = node.position
                    dragInitialPositions = simulator.positionsByID()
                    dragInitialRestingPositions = simulator.restingPositionsByID()
                }
                pendingDraggedNodePosition = nil
                hasDraggedNode = false
                publishFrameRatePreferenceIfNeeded()
            }
        } else {
            suspendHoverForInteraction()
            draggedNodeOffset = nil
            pendingDraggedNodePosition = nil
            clearDragSnapshot()
            hasDraggedNode = false
            pendingClickSelectionID = nil
            hasPendingClickSelection = true
            if event.clickCount >= 2 {
                onSelectGraphNode?(nil)
                hasPendingClickSelection = false
                recenterCamera(animated: true)
                publishViewport()
                return
            }
            isPanning = true
            publishFrameRatePreferenceIfNeeded()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        markInteraction()
        suspendHoverForInteraction()
        let location = event.location(in: self)
        if let draggedNodeID {
            let offset = draggedNodeOffset ?? .zero
            let target = CGPoint(x: location.x + offset.x, y: location.y + offset.y)
            if !hasDraggedNode {
                dragStartPosition = simulator.nodesByID[draggedNodeID]?.position
                dragInitialPositions = simulator.positionsByID()
                dragInitialRestingPositions = simulator.restingPositionsByID()
                dragBranchNodeIDs = simulator.descendantNodeIDs(from: draggedNodeID)
                localSettlingNodeIDs = nil
                localSettlingBranchNodeIDs = nil
                localReturningNodeOrigins = [:]
                simulator.stopMotion()
                resetLayoutSettling()
            }
            hasDraggedNode = true
            hasPendingClickSelection = false
            pendingDraggedNodePosition = target
            if let dragStartPosition {
                dragBranchNodeIDs = simulator.previewDrag(nodeID: draggedNodeID,
                                                           from: dragStartPosition,
                                                           to: target,
                                                           initialPositions: dragInitialPositions)
            }
            renderFromSimulator(elapsedTime: (lastUpdateTime ?? 0) * 1_000)
            return
        }
        guard isPanning else { return }
        hasPanned = true
        hasPendingClickSelection = false
        panBy(deltaX: event.deltaX, deltaY: event.deltaY)
        publishViewport()
    }

    override func rightMouseDown(with event: NSEvent) {
        markInteraction()
        suspendHoverForInteraction()
        hasPendingClickSelection = false
        hasPanned = false
        isPanning = true
        publishFrameRatePreferenceIfNeeded()
    }

    override func rightMouseDragged(with event: NSEvent) {
        markInteraction()
        guard isPanning else { return }
        hasPanned = true
        panBy(deltaX: event.deltaX, deltaY: event.deltaY)
        publishViewport()
    }

    override func mouseUp(with event: NSEvent) {
        markInteraction()
        let clickSelectionID = pendingClickSelectionID
        let shouldApplyClickSelection = hasPendingClickSelection && !hasDraggedNode && !hasPanned
        if let draggedNodeID, hasDraggedNode {
            let location = event.location(in: self)
            let offset = draggedNodeOffset ?? .zero
            let target = CGPoint(x: location.x + offset.x, y: location.y + offset.y)
            if let dragStartPosition,
               !dragInitialPositions.isEmpty {
                let reactiveNodeIDs = simulator.lastDragReactiveNodeIDs
                    .subtracting(dragBranchNodeIDs)
                let movableNodeIDs = simulator.commitDrag(
                    nodeID: draggedNodeID,
                    from: dragStartPosition,
                    to: target,
                    initialPositions: dragInitialPositions,
                    initialRestingPositions: dragInitialRestingPositions
                )
                localSettlingBranchNodeIDs = movableNodeIDs.isEmpty ? nil : movableNodeIDs
                localReturningNodeOrigins = Dictionary(uniqueKeysWithValues: reactiveNodeIDs.compactMap { nodeID in
                    dragInitialPositions[nodeID].map { (nodeID, $0) }
                })
                localSettlingNodeIDs = movableNodeIDs
                    .union(localReturningNodeOrigins.keys)
            } else {
                simulator.releaseNode(at: target, for: draggedNodeID)
                localSettlingBranchNodeIDs = [draggedNodeID]
                localSettlingNodeIDs = [draggedNodeID]
                localReturningNodeOrigins = [:]
            }
            if localSettlingNodeIDs == nil {
                layoutIsSettled = true
            } else {
                resetLayoutSettling()
                renderFromSimulator(elapsedTime: (lastUpdateTime ?? 0) * 1_000)
            }
        }
        draggedNodeID = nil
        draggedNodeOffset = nil
        pendingDraggedNodePosition = nil
        clearDragSnapshot()
        hasDraggedNode = false
        pendingClickSelectionID = nil
        hasPendingClickSelection = false
        isPanning = false
        hasPanned = false
        if shouldApplyClickSelection {
            onSelectGraphNode?(clickSelectionID)
        }
        publishFrameRatePreferenceIfNeeded()
    }

    override func rightMouseUp(with event: NSEvent) {
        markInteraction()
        isPanning = false
        hasPanned = false
        publishFrameRatePreferenceIfNeeded()
    }

    override func mouseMoved(with event: NSEvent) {
        markInteraction()
        guard draggedNodeID == nil, !isPanning else {
            suspendHoverForInteraction()
            return
        }
        let location = event.location(in: self)
        let nextHoveredID = nodeID(at: location)
        applyHoverCandidate(nextHoveredID, at: location)
    }

    internal func applyHoverCandidate(_ nextHoveredID: String?, at location: CGPoint) {
        isHoverSuspended = false
        if hoveredGraphNodeID != nextHoveredID {
            hoveredGraphNodeID = nextHoveredID
            applyVisualState()
        }
        guard let nextHoveredID else {
            onHoverItem?(nil)
            return
        }
        if let grouping = graphData.groupingByID[nextHoveredID] {
            onHoverItem?(.grouping(grouping, location))
        } else if let thread = graphData.threadByID[nextHoveredID] {
            onHoverItem?(.thread(thread, location))
        } else if let remainingBranch = graphData.remainingBranchByID[nextHoveredID] {
            onHoverItem?(.remaining(remainingBranch, location))
        } else if let message = graphData.messageByID[nextHoveredID] {
            onHoverItem?(.message(message, location))
        } else {
            onHoverItem?(nil)
        }
    }

    internal func suspendHoverForInteraction() {
        guard !isHoverSuspended || hoveredGraphNodeID != nil else { return }
        let shouldRefreshVisualState = hoveredGraphNodeID != nil
        isHoverSuspended = true
        hoveredGraphNodeID = nil
        onHoverItem?(nil)
        if shouldRefreshVisualState {
            applyVisualState()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredGraphNodeID = nil
        onHoverItem?(nil)
        applyVisualState()
    }

    override func scrollWheel(with event: NSEvent) {
        markInteraction()
        suspendHoverForInteraction()
        let hasZoomModifier = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
        let shouldZoom = Self.shouldZoomScroll(hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                                               hasZoomModifier: hasZoomModifier)
        guard shouldZoom else {
            panBy(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            publishViewport()
            return
        }
        let delta = event.scrollingDeltaY == 0 ? -event.scrollingDeltaX : event.scrollingDeltaY
        let currentZoom = 1 / cameraNode.xScale
        let nextZoom = currentZoom * exp(delta * -0.005)
        setZoom(nextZoom, around: event.location(in: self))
        publishViewport()
    }

    internal static func shouldZoomScroll(hasPreciseScrollingDeltas: Bool,
                                          hasZoomModifier: Bool) -> Bool {
        _ = hasPreciseScrollingDeltas
        return hasZoomModifier
    }

    internal func magnify(by magnification: CGFloat, at viewPoint: CGPoint, in view: SKView) {
        markInteraction()
        suspendHoverForInteraction()
        let scenePoint = convertPoint(fromView: viewPoint)
        let currentZoom = 1 / cameraNode.xScale
        let nextZoom = currentZoom * max(0.2, 1 + magnification)
        setZoom(nextZoom, around: scenePoint)
        publishViewport()
    }

    private func commonInit() {
        backgroundColor = theme.backgroundNS
        anchorPoint = .zero
        scaleMode = .resizeFill
        camera = cameraNode
        configureEdgeLayers(mode: edgeRenderingMode())
        addChild(cameraNode)
    }

    private func applyTheme() {
        backgroundColor = theme.backgroundNS
        appliedEdgeRenderingMode = nil
        configureEdgeLayers(mode: edgeRenderingMode())
    }

    private func configureEdgeLayers(mode: EdgeRenderingMode) {
        guard appliedEdgeRenderingMode != mode else { return }
        appliedEdgeRenderingMode = mode
        let layers: [(SKShapeNode, NSColor, CGFloat, CGFloat, CGFloat)] = [
            (trunkEdgeNode, theme.inkTertiaryNS, 1.4, 0.82, 0.72),
            (chainEdgeNode, theme.inkQuaternaryNS, 1.0, 0.68, 0.62),
            (dimmedTrunkEdgeNode, theme.inkTertiaryNS, 1.4, 0.22, 0.22),
            (dimmedChainEdgeNode, theme.inkQuaternaryNS, 1.0, 0.22, 0.22)
        ]
        for (node, color, strokeWidth, fillAlpha, strokeAlpha) in layers {
            switch mode {
            case .ribbon:
                node.fillColor = color.withAlphaComponent(fillAlpha)
                node.strokeColor = .clear
                node.lineWidth = 0
            case .stroke:
                node.fillColor = .clear
                node.strokeColor = color.withAlphaComponent(strokeAlpha)
                node.lineWidth = strokeWidth
            }
            node.zPosition = -10
            node.lineCap = .round
            node.lineJoin = .round
            node.isAntialiased = true
            if node.parent == nil {
                addChild(node)
            }
        }
        let remainingLayers: [(SKShapeNode, NSColor, CGFloat, CGFloat)] = [
            (remainingEdgeNode, theme.archiveNS, 1.25, 0.58),
            (dimmedRemainingEdgeNode, theme.inkTertiaryNS, 1.0, 0.22)
        ]
        for (node, color, strokeWidth, strokeAlpha) in remainingLayers {
            node.fillColor = .clear
            node.strokeColor = color.withAlphaComponent(strokeAlpha)
            node.lineWidth = strokeWidth
            node.zPosition = -9
            node.lineCap = .round
            node.lineJoin = .round
            node.isAntialiased = true
            if node.parent == nil {
                addChild(node)
            }
        }
    }

    private func applyViewport(zoomScale: CGFloat, panOffset: CGPoint) {
        let clampedZoom = GraphViewport.clampedZoom(zoomScale)
        cameraNode.setScale(1 / clampedZoom)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraNode.position = CGPoint(x: center.x + panOffset.x,
                                      y: center.y + panOffset.y)
    }

    private func setZoom(_ zoomScale: CGFloat, around focus: CGPoint?) {
        let clampedZoom = GraphViewport.clampedZoom(zoomScale)
        let previousScale = max(cameraNode.xScale, 0.001)
        let previousPosition = cameraNode.position
        let nextScale = 1 / clampedZoom
        cameraNode.setScale(nextScale)

        if let focus {
            let scaleRatio = nextScale / previousScale
            cameraNode.position = CGPoint(x: focus.x - (focus.x - previousPosition.x) * scaleRatio,
                                          y: focus.y - (focus.y - previousPosition.y) * scaleRatio)
        }
    }

    private func panBy(deltaX: CGFloat, deltaY: CGFloat) {
        cameraNode.position = CGPoint(x: cameraNode.position.x - deltaX * cameraNode.xScale,
                                      y: cameraNode.position.y + deltaY * cameraNode.yScale)
    }

    private func recenterCamera(animated: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraNode.removeAction(forKey: "graph-camera-recenter")
        guard animated else {
            cameraNode.position = center
            cameraNode.setScale(1)
            return
        }
        cameraNode.run(.sequence([
            .group([
                .move(to: center, duration: 0.24),
                .scale(to: 1, duration: 0.24)
            ]),
            .run { [weak self] in
                self?.publishViewport()
                self?.publishFrameRatePreferenceIfNeeded()
            }
        ]), withKey: "graph-camera-recenter")
        publishFrameRatePreferenceIfNeeded()
    }

    private func publishViewport() {
        let zoomScale = 1 / cameraNode.xScale
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let pan = CGPoint(x: cameraNode.position.x - center.x,
                          y: cameraNode.position.y - center.y)
        onViewportChanged?(zoomScale, pan)
    }

    private func rebuildGraph(restartLayout: Bool = true) {
        lastRenderedEdgeState = nil
        cancelScopedSimulation()
        if restartLayout {
            resetLayoutSettling()
        } else {
            layoutSettlingFrames = 0
            layoutIsSettled = true
            layoutSettledPositionsReported = false
        }
        let existingPositions = simulator.positionsByID()
        simulator.reset(data: graphData, size: size, preserving: existingPositions)
        edgeSourceByTargetID = graphData.edges.reduce(into: [:]) { sourcesByTarget, edge in
            sourcesByTarget[edge.targetID] = edge.sourceID
        }
        for node in graphNodesByID.values {
            node.removeFromParent()
        }
        for callout in summaryCalloutsByID.values {
            callout.removeFromParent()
        }
        graphNodesByID = [:]
        summaryCalloutsByID = [:]
        let centerNode = GraphSceneNode(graphID: graphData.center.id,
                                        kind: .center,
                                        threadID: nil,
                                        radius: 38,
                                        title: graphData.center.title,
                                        fillColor: theme.panelNS,
                                        strokeColor: theme.inkNS,
                                        strokeWidth: 1.6,
                                        showsLabel: true,
                                        textScale: textScale,
                                        theme: theme)
        graphNodesByID[graphData.center.id] = centerNode
        addChild(centerNode)
        for grouping in graphData.groupings {
            let node = GraphSceneNode(graphID: grouping.id,
                                      kind: grouping.nodeKind,
                                      threadID: nil,
                                      radius: grouping.radius,
                                      title: grouping.title,
                                      fillColor: grouping.isSuggestion
                                          ? theme.panelSecondaryNS.withAlphaComponent(0.30)
                                          : theme.accentSoftNS,
                                      strokeColor: theme.accentNS,
                                      strokeWidth: grouping.isSuggestion ? 1.3 : 1.6,
                                      showsLabel: true,
                                      textScale: textScale,
                                      theme: theme)
            graphNodesByID[grouping.id] = node
            addChild(node)
        }
        for thread in graphData.threads {
            let node = GraphSceneNode(graphID: thread.id,
                                      kind: .thread,
                                      threadID: thread.id,
                                      radius: thread.radius,
                                      title: thread.subject,
                                      fillColor: theme.panelNS,
                                      strokeColor: strokeColor(for: thread.importance),
                                      strokeWidth: thread.importance.ringWidth,
                                      showsLabel: true,
                                      textScale: textScale,
                                      theme: theme)
            graphNodesByID[thread.id] = node
            addChild(node)
        }
        for remainingBranch in graphData.remainingBranches {
            let node = GraphSceneNode(graphID: remainingBranch.id,
                                      kind: .remaining,
                                      threadID: nil,
                                      radius: remainingBranch.radius,
                                      title: remainingBranch.title,
                                      fillColor: theme.panelSecondaryNS.withAlphaComponent(0.34),
                                      strokeColor: theme.archiveNS,
                                      strokeWidth: 1.4,
                                      showsLabel: true,
                                      textScale: textScale,
                                      theme: theme)
            node.configureExpansionAccessibility(label: remainingBranch.accessibilityLabel) { [weak self] in
                self?.onExpandRemainingBranches?(remainingBranch.parentID)
            }
            graphNodesByID[remainingBranch.id] = node
            addChild(node)
        }
        for message in graphData.messages {
            let node = GraphSceneNode(graphID: message.id,
                                      kind: .message,
                                      threadID: message.threadID,
                                      radius: message.radius,
                                      title: nil,
                                      fillColor: message.unread
                                      ? theme.accentNS
                                      : theme.panelNS,
                                      strokeColor: theme.inkNS.withAlphaComponent(0.9),
                                      strokeWidth: 1.0,
                                      showsLabel: false,
                                      textScale: textScale,
                                      theme: theme)
            graphNodesByID[message.id] = node
            addChild(node)
            if !message.summaryPreviewText.isEmpty {
                let callout = SummaryCalloutNode(graphID: message.id,
                                                 text: message.summaryPreviewText,
                                                 textScale: textScale,
                                                 theme: theme)
                summaryCalloutsByID[message.id] = callout
                addChild(callout)
            }
            if sproutingMessageIDs.contains(message.id) {
                node.runSprout(reduceMotion: reduceMotion)
            }
        }
        renderFromSimulator(elapsedTime: (lastUpdateTime ?? 0) * 1_000)
        applyVisualState()
    }

    private func startPruneAnimationIfNeeded(_ request: GraphPruneAnimationRequest?) {
        guard let request,
              runningPruneAnimationID != request.id else { return }
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
            node.runPrune(action: request.action,
                          reduceMotion: reduceMotion) { [weak self] in
                guard let self,
                      self.runningPruneAnimationID == request.id else { return }
                self.remainingPruneAnimationNodes -= 1
                guard self.remainingPruneAnimationNodes <= 0 else { return }
                self.runningPruneAnimationID = nil
                self.remainingPruneAnimationNodes = 0
                self.onPruneAnimationFinished?(request.id)
            }
        }
    }

    private func renderFromSimulator(elapsedTime: TimeInterval) {
        edgeRenderFrame += 1
        for physicsNode in simulator.nodes {
            guard let node = graphNodesByID[physicsNode.id] else { continue }
            node.position = physicsNode.position
            if physicsNode.kind != .center,
               let sourceID = edgeSourceByTargetID[physicsNode.id],
               let source = simulator.nodesByID[sourceID] {
                let dx = physicsNode.position.x - source.position.x
                let dy = physicsNode.position.y - source.position.y
                node.setBranchGeometry(angle: CGFloat(atan2(Double(dy), Double(dx))),
                                       incomingDistance: hypot(dx, dy))
            }
        }
        updateFocusedThreadMotion(elapsedTime: elapsedTime)
        let shouldRefreshOcclusionLayout = draggedNodeID == nil || edgeRenderFrame.isMultiple(of: 2)
        if shouldRefreshOcclusionLayout {
            updateSummaryCallouts()
            resolveGraphLabelOverlaps()
        }
        if draggedNodeID == nil || edgeRenderFrame.isMultiple(of: 2) {
            renderEdges(skipCoalescedChains: !layoutIsSettled && edgeRenderFrame % 2 != 0)
        }
    }

    private func resolveGraphLabelOverlaps() {
        guard let center = simulator.nodesByID[graphData.center.id]?.position else { return }
        let candidates = simulator.nodes
            .filter { $0.kind != .center && $0.kind != .message }
            .sorted { left, right in
                let leftAngle = atan2(left.position.y - center.y, left.position.x - center.x)
                let rightAngle = atan2(right.position.y - center.y, right.position.x - center.x)
                if leftAngle != rightAngle { return leftAngle < rightAngle }
                return left.id < right.id
            }
        let nodeFramesByID = Dictionary(uniqueKeysWithValues: simulator.nodes.map { node in
            let clearance: CGFloat = node.kind == .message ? 5 : 8
            return (node.id, CGRect(x: node.position.x - node.radius - clearance,
                                    y: node.position.y - node.radius - clearance,
                                    width: (node.radius + clearance) * 2,
                                    height: (node.radius + clearance) * 2))
        })
        let calloutFrames = summaryCalloutsByID.values.compactMap { callout -> CGRect? in
            guard callout.parent != nil, callout.alpha > 0.01 else { return nil }
            return callout.calculateAccumulatedFrame()
        }
        let centerLabelFrame = graphNodesByID[graphData.center.id]?.labelFrame(in: self)
        var occupiedFrames = calloutFrames + [centerLabelFrame].compactMap { $0 }
        let viewport = cameraVisibleRect().insetBy(dx: 8, dy: 8)
        for physicsNode in candidates {
            guard let sceneNode = graphNodesByID[physicsNode.id] else { continue }
            sceneNode.setLabelCollisionOffset(.zero)
            guard let frame = sceneNode.labelFrame(in: self) else { continue }
            let sourcePosition = edgeSourceByTargetID[physicsNode.id]
                .flatMap { simulator.nodesByID[$0]?.position } ?? center
            let dx = physicsNode.position.x - sourcePosition.x
            let dy = physicsNode.position.y - sourcePosition.y
            let distance = max(1, hypot(dx, dy))
            let branchUnit = CGVector(dx: dx / distance, dy: dy / distance)
            let nodeOccluders = nodeFramesByID.compactMap { id, frame in
                id == physicsNode.id ? nil : frame
            }
            let offset = Self.resolvedLabelOffset(frame: frame,
                                                  branchUnit: branchUnit,
                                                  occluders: occupiedFrames + nodeOccluders,
                                                  viewport: viewport)
            sceneNode.setLabelCollisionOffset(offset)
            occupiedFrames.append(frame.offsetBy(dx: offset.dx, dy: offset.dy))
        }
    }

    internal static func resolvedLabelOffset(frame: CGRect,
                                             branchUnit: CGVector,
                                             occluders: [CGRect],
                                             viewport: CGRect) -> CGVector {
        let perpendicular = CGVector(dx: -branchUnit.dy, dy: branchUnit.dx)
        let candidates: [CGVector] = [
            .zero,
            perpendicular.scaled(by: 16), perpendicular.scaled(by: -16),
            branchUnit.scaled(by: 16), branchUnit.scaled(by: -16),
            perpendicular.scaled(by: 32), perpendicular.scaled(by: -32),
            perpendicular.scaled(by: 48), perpendicular.scaled(by: -48),
            perpendicular.scaled(by: 64), perpendicular.scaled(by: -64)
        ]
        var best = candidates[0]
        var bestScore = CGFloat.greatestFiniteMagnitude
        for candidate in candidates {
            let proposed = frame.offsetBy(dx: candidate.dx, dy: candidate.dy)
            let overlapScore = occluders.reduce(CGFloat.zero) { score, occluder in
                let intersection = proposed.insetBy(dx: -6, dy: -4).intersection(occluder)
                guard !intersection.isNull else { return score }
                return score + intersection.width * intersection.height
            }
            let viewportPenalty: CGFloat = viewport.contains(proposed) ? 0 : 1_000_000
            let movementPenalty = hypot(candidate.dx, candidate.dy) * 0.01
            let score = overlapScore + viewportPenalty + movementPenalty
            if score < bestScore {
                best = candidate
                bestScore = score
            }
            if score < 0.001 { break }
        }
        return best
    }

    private func updateSummaryCallouts() {
        var occluders = simulator.nodes.map { physicsNode in
            GraphSummaryOccluder(id: physicsNode.id,
                                 position: physicsNode.position,
                                 radius: summaryOcclusionRadius(for: physicsNode))
        }
        for message in graphData.messages.sorted(by: { $0.id < $1.id }) {
            guard let callout = summaryCalloutsByID[message.id],
                  let physicsNode = simulator.nodesByID[message.id] else { continue }
            let angle = callout.update(text: message.summaryPreviewText,
                                       anchorPosition: physicsNode.position,
                                       anchorRadius: physicsNode.radius,
                                       occluders: occluders,
                                       previousAngle: summaryAnglesByMessageID[message.id])
            summaryAnglesByMessageID[message.id] = angle
            let isDimmed = !filteredNodeIDs.isEmpty && !filteredNodeIDs.contains(message.id)
            callout.applyDimmed(isDimmed)
            occluders.append(GraphSummaryOccluder(id: "callout:\(message.id)",
                                                  position: callout.position,
                                                  radius: callout.occlusionRadius))
        }
    }

    private func renderEdges(skipCoalescedChains: Bool = false) {
        let visibleRect = cameraVisibleRect().insetBy(dx: -120, dy: -120)
        let renderingMode = edgeRenderingMode()
        let modeChanged = appliedEdgeRenderingMode != renderingMode
        configureEdgeLayers(mode: renderingMode)
        let branchConfig = forceConfig.branchConfig
        let curlConfig = forceConfig.branchCurlConfig
        let anchor: CGPoint?
        if branchConfig.outwardArcAnchorEnabled {
            anchor = simulator.nodesByID[graphData.center.id]?.position ?? CGPoint(x: size.width / 2, y: size.height / 2)
        } else {
            anchor = nil
        }
        let trunkPath = CGMutablePath()
        let remainingPath = CGMutablePath()
        let shouldSkipChains = skipCoalescedChains && !modeChanged
        let chainPath = shouldSkipChains ? nil : CGMutablePath()
        let dimmedTrunkPath = CGMutablePath()
        let dimmedRemainingPath = CGMutablePath()
        let dimmedChainPath = shouldSkipChains ? nil : CGMutablePath()
        for edge in graphData.edges {
            guard let source = simulator.nodesByID[edge.sourceID],
                  let target = simulator.nodesByID[edge.targetID] else { continue }
            let midpoint = CGPoint(x: (source.position.x + target.position.x) / 2,
                                   y: (source.position.y + target.position.y) / 2)
            guard visibleRect.contains(midpoint) else { continue }
            let isDimmed = isEdgeDimmed(edge)
            switch (edge.kind, isDimmed) {
            case (.trunk, false), (.grouping, false):
                appendEdge(edge: edge,
                           source: source.position,
                           target: target.position,
                           to: trunkPath,
                           mode: renderingMode,
                           branchConfig: branchConfig,
                           curlConfig: curlConfig,
                           anchor: anchor)
            case (.remaining, false), (.suggested, false):
                appendDashedEdge(source: source,
                                 target: target,
                                 to: remainingPath)
            case (.trunk, true), (.grouping, true):
                appendEdge(edge: edge,
                           source: source.position,
                           target: target.position,
                           to: dimmedTrunkPath,
                           mode: renderingMode,
                           branchConfig: branchConfig,
                           curlConfig: curlConfig,
                           anchor: anchor)
            case (.remaining, true), (.suggested, true):
                appendDashedEdge(source: source,
                                 target: target,
                                 to: dimmedRemainingPath)
            case (.chain, false):
                if let chainPath {
                    appendEdge(edge: edge,
                               source: source.position,
                               target: target.position,
                               to: chainPath,
                               mode: renderingMode,
                               branchConfig: branchConfig,
                               curlConfig: curlConfig,
                               anchor: anchor)
                }
            case (.chain, true):
                if let dimmedChainPath {
                    appendEdge(edge: edge,
                               source: source.position,
                               target: target.position,
                               to: dimmedChainPath,
                               mode: renderingMode,
                               branchConfig: branchConfig,
                               curlConfig: curlConfig,
                               anchor: anchor)
                }
            }
        }
        trunkEdgeNode.path = trunkPath
        remainingEdgeNode.path = remainingPath
        dimmedTrunkEdgeNode.path = dimmedTrunkPath
        dimmedRemainingEdgeNode.path = dimmedRemainingPath
        if let chainPath {
            chainEdgeNode.path = chainPath
        }
        if let dimmedChainPath {
            dimmedChainEdgeNode.path = dimmedChainPath
        }
        if !shouldSkipChains {
            lastRenderedEdgeState = edgeRenderState(mode: renderingMode,
                                                    visibleRect: visibleRect)
        }
    }

    private func renderEdgesIfNeeded() {
        let visibleRect = cameraVisibleRect().insetBy(dx: -120, dy: -120)
        let renderingMode = edgeRenderingMode()
        let nextState = edgeRenderState(mode: renderingMode,
                                        visibleRect: visibleRect)
        guard nextState != lastRenderedEdgeState ||
              appliedEdgeRenderingMode != renderingMode else {
            return
        }
        renderEdges()
    }

    private func edgeRenderState(mode: EdgeRenderingMode,
                                 visibleRect: CGRect) -> EdgeRenderState {
        EdgeRenderState(mode: mode,
                        filteredNodeIDs: filteredNodeIDs,
                        viewportMinXBucket: edgeViewportBucket(for: visibleRect.minX),
                        viewportMinYBucket: edgeViewportBucket(for: visibleRect.minY),
                        viewportMaxXBucket: edgeViewportBucket(for: visibleRect.maxX),
                        viewportMaxYBucket: edgeViewportBucket(for: visibleRect.maxY),
                        settled: layoutIsSettled)
    }

    private func edgeViewportBucket(for value: CGFloat) -> Int {
        Int((value / Self.edgeViewportBucketSize).rounded(.down))
    }

    private func applyVisualState() {
        for (id, node) in graphNodesByID {
            if let thread = graphData.threadByID[id] {
                node.setBaseStyle(fillColor: theme.panelNS,
                                  strokeColor: strokeColor(for: thread.importance),
                                  strokeWidth: thread.importance.ringWidth,
                                  theme: theme)
            } else if let grouping = graphData.groupingByID[id] {
                node.setBaseStyle(fillColor: grouping.isSuggestion
                                  ? theme.panelSecondaryNS.withAlphaComponent(0.30)
                                  : theme.accentSoftNS,
                                  strokeColor: theme.accentNS,
                                  strokeWidth: grouping.isSuggestion ? 1.3 : 1.6,
                                  theme: theme)
            } else if let message = graphData.messageByID[id] {
                node.setBaseStyle(fillColor: message.unread
                                  ? theme.accentNS
                                  : theme.panelNS,
                                  strokeColor: theme.inkNS.withAlphaComponent(0.9),
                                  strokeWidth: 1.0,
                                  theme: theme)
            } else if graphData.remainingBranchByID[id] != nil {
                node.setBaseStyle(fillColor: theme.panelSecondaryNS.withAlphaComponent(0.34),
                                  strokeColor: theme.archiveNS,
                                  strokeWidth: 1.4,
                                  theme: theme)
            }
            let isDimmed = !filteredNodeIDs.isEmpty && !filteredNodeIDs.contains(id)
            node.applySelection(isSelected: selectedGraphNodeID == id,
                                isHovered: hoveredGraphNodeID == id,
                                isDimmed: isDimmed)
        }
        for (id, callout) in summaryCalloutsByID {
            callout.applyDimmed(!filteredNodeIDs.isEmpty && !filteredNodeIDs.contains(id))
        }
        updateFocusedThreadMotion(elapsedTime: (lastUpdateTime ?? 0) * 1_000)
        renderEdgesIfNeeded()
    }

    private func updateFocusedThreadMotion(elapsedTime: TimeInterval) {
        let focusedThreadID = threadID(forGraphNodeID: selectedGraphNodeID)
        for thread in graphData.threads where thread.isLive {
            graphNodesByID[thread.id]?.updateBreath(
                elapsedTime: elapsedTime,
                phase: Double(abs(thread.id.hashValue % 997)) / 997,
                reduceMotion: reduceMotion || thread.id != focusedThreadID
            )
        }
    }

    private func isEdgeDimmed(_ edge: GraphEdge) -> Bool {
        !filteredNodeIDs.isEmpty &&
        (!filteredNodeIDs.contains(edge.sourceID) || !filteredNodeIDs.contains(edge.targetID))
    }

    private func cameraVisibleRect() -> CGRect {
        let halfWidth = (size.width * cameraNode.xScale) / 2
        let halfHeight = (size.height * cameraNode.yScale) / 2
        return CGRect(x: cameraNode.position.x - halfWidth,
                      y: cameraNode.position.y - halfHeight,
                      width: halfWidth * 2,
                      height: halfHeight * 2)
    }

    private func strokeColor(for importance: GraphImportance) -> NSColor {
        switch importance {
        case .low:
            return theme.inkQuaternaryNS
        case .medium:
            return theme.inkSecondaryNS
        case .high:
            return theme.inkNS
        }
    }

    private func edgeRenderingMode() -> EdgeRenderingMode {
        graphData.edges.count > Self.ribbonEdgeBudget ? .stroke : .ribbon
    }

    private func resetLayoutSettling() {
        layoutSettlingFrames = 0
        layoutIsSettled = false
        layoutSettledPositionsReported = false
        publishFrameRatePreferenceIfNeeded()
    }

    private func markInteraction() {
        lastInteractionTime = lastUpdateTime ?? 0
        publishFrameRatePreferenceIfNeeded()
    }

    private func updateLayoutSettlingState() {
        layoutSettlingFrames += 1
        let nodeCount = max(1, localSettlingNodeIDs?.count ?? simulator.nodesByID.count)
        let energy = localSettlingNodeIDs.map { simulator.totalEnergy(for: $0) } ?? simulator.totalEnergy()
        let energyPerNode = energy / CGFloat(nodeCount)
        let frameLimit = localSettlingNodeIDs == nil
            ? Self.layoutSettlingFrameLimit
            : Self.localSettlingFrameLimit
        if layoutSettlingFrames >= frameLimit ||
            energyPerNode <= Self.layoutSettledEnergyPerNodeThreshold {
            if let localSettlingNodeIDs {
                simulator.stopMotion(for: localSettlingNodeIDs)
                simulator.finishLocalSettling(returningNodeOrigins: localReturningNodeOrigins)
                self.localSettlingNodeIDs = nil
                localSettlingBranchNodeIDs = nil
                localReturningNodeOrigins = [:]
            }
            layoutIsSettled = true
        }
    }

    private func clearDragSnapshot() {
        dragStartPosition = nil
        dragInitialPositions = [:]
        dragInitialRestingPositions = [:]
        dragBranchNodeIDs = []
    }

    private func cancelScopedSimulation() {
        if draggedNodeID != nil,
           !dragInitialPositions.isEmpty {
            simulator.restoreSnapshot(positions: dragInitialPositions,
                                      restingPositions: dragInitialRestingPositions)
        } else if !localReturningNodeOrigins.isEmpty {
            simulator.finishLocalSettling(returningNodeOrigins: localReturningNodeOrigins)
        }
        simulator.stopMotion()
        localSettlingNodeIDs = nil
        localSettlingBranchNodeIDs = nil
        localReturningNodeOrigins = [:]
        draggedNodeID = nil
        draggedNodeOffset = nil
        pendingDraggedNodePosition = nil
        hasDraggedNode = false
        clearDragSnapshot()
    }

    private func shouldReportPositions() -> Bool {
        !layoutIsSettled || !layoutSettledPositionsReported
    }

    private var needsActiveFrameRate: Bool {
        !layoutIsSettled ||
        hasRecentInteraction ||
        draggedNodeID != nil ||
        isPanning ||
        cameraNode.hasActions() ||
        graphNodesByID.values.contains { $0.hasActions() } ||
        summaryCalloutsByID.values.contains { $0.hasActions() }
    }

    private func publishFrameRatePreferenceIfNeeded() {
        let nextFramesPerSecond = preferredFramesPerSecond
        guard nextFramesPerSecond != publishedFramesPerSecond else { return }
        publishedFramesPerSecond = nextFramesPerSecond
        onFrameRatePreferenceChanged?(nextFramesPerSecond)
    }

    private func appendEdge(edge: GraphEdge,
                            source: CGPoint,
                            target: CGPoint,
                            to path: CGMutablePath,
                            mode: EdgeRenderingMode,
                            branchConfig: GraphBranchConfig,
                            curlConfig: GraphCurlConfig,
                            anchor: CGPoint?) {
        switch mode {
        case .ribbon:
            appendBranch(edge: edge,
                         source: source,
                         target: target,
                         to: path,
                         branchConfig: branchConfig,
                         curlConfig: curlConfig,
                         anchor: anchor)
        case .stroke:
            path.addPath(splinePath(from: source,
                                    to: target,
                                    seed: stableEdgeSeed(edge),
                                    config: forceConfig.curlConfig))
        }
    }

    private func appendBranch(edge: GraphEdge,
                              source: CGPoint,
                              target: CGPoint,
                              to path: CGMutablePath,
                              branchConfig: GraphBranchConfig,
                              curlConfig: GraphCurlConfig,
                              anchor: CGPoint?) {
        path.addPath(GraphSpline.ribbonPath(from: source,
                                            to: target,
                                            seed: stableEdgeSeed(edge),
                                            config: curlConfig,
                                            anchor: anchor,
                                            widthStart: branchConfig.baseWidth(for: edge.kind),
                                            widthEnd: branchConfig.tipWidth(for: edge.kind),
                                            tipMin: branchConfig.tipMin,
                                            taperPow: branchConfig.taperPow,
                                            samples: ribbonSamples(for: branchConfig)))
        let jointRadius = branchConfig.jointRadius(for: edge.kind)
        guard jointRadius > 0 else { return }
        path.addEllipse(in: CGRect(x: source.x - jointRadius,
                                   y: source.y - jointRadius,
                                   width: jointRadius * 2,
                                   height: jointRadius * 2))
    }

    private func ribbonSamples(for branchConfig: GraphBranchConfig) -> Int {
        guard layoutIsSettled else { return branchConfig.ribbonSamples }
        return max(branchConfig.ribbonSamples, Self.settledRibbonSamples)
    }

    private func appendDashedEdge(source: GraphPhysicsNode,
                                  target: GraphPhysicsNode,
                                  to path: CGMutablePath,
                                  dashLength: CGFloat = 10,
                                  gapLength: CGFloat = 7) {
        let dx = target.position.x - source.position.x
        let dy = target.position.y - source.position.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let unit = CGVector(dx: dx / length, dy: dy / length)
        let startOffset = min(length / 2, source.radius + 8)
        let endOffset = min(length / 2, target.radius + 8)
        let usableLength = length - startOffset - endOffset
        guard usableLength > 1 else { return }

        var cursor: CGFloat = 0
        while cursor < usableLength {
            let segmentEnd = min(cursor + dashLength, usableLength)
            let startDistance = startOffset + cursor
            let endDistance = startOffset + segmentEnd
            path.move(to: CGPoint(x: source.position.x + unit.dx * startDistance,
                                  y: source.position.y + unit.dy * startDistance))
            path.addLine(to: CGPoint(x: source.position.x + unit.dx * endDistance,
                                     y: source.position.y + unit.dy * endDistance))
            cursor = segmentEnd + gapLength
        }
    }

    private func nodeID(at location: CGPoint) -> String? {
        for touchedNode in nodes(at: location) {
            var currentNode: SKNode? = touchedNode
            while let current = currentNode {
                if let graphNode = current as? GraphSceneNode {
                    return graphNode.graphID
                }
                if let callout = current as? SummaryCalloutNode {
                    return callout.graphID
                }
                currentNode = current.parent
            }
        }
        return simulator.nodes
            .filter { $0.kind != .center || hypot($0.position.x - location.x, $0.position.y - location.y) <= $0.radius }
            .filter { hypot($0.position.x - location.x, $0.position.y - location.y) <= $0.radius + 8 }
            .min {
                hypot($0.position.x - location.x, $0.position.y - location.y) <
                hypot($1.position.x - location.x, $1.position.y - location.y)
            }?.id
    }

    private func nearestEdgeThreadID(to location: CGPoint) -> String? {
        let edgeHitTolerance = Self.pruneEdgeHitTolerance * max(cameraNode.xScale, 0.2)
        return graphData.edges
            .compactMap { edge -> (threadID: String, distance: CGFloat)? in
                guard edge.kind != .suggested else { return nil }
                guard graphData.threadByID[edge.threadID] != nil else { return nil }
                guard let source = simulator.nodesByID[edge.sourceID],
                      let target = simulator.nodesByID[edge.targetID] else { return nil }
                return (edge.threadID, distanceToSegment(location, source: source.position, target: target.position))
            }
            .filter { $0.distance < edgeHitTolerance }
            .min { $0.distance < $1.distance }?.threadID
    }

    private func threadID(forGraphNodeID graphNodeID: String?) -> String? {
        guard let graphNodeID else { return nil }
        if graphData.threadByID[graphNodeID] != nil {
            return graphNodeID
        }
        return graphData.messageByID[graphNodeID]?.threadID
    }

    private func distanceToSegment(_ point: CGPoint, source: CGPoint, target: CGPoint) -> CGFloat {
        let dx = target.x - source.x
        let dy = target.y - source.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - source.x, point.y - source.y) }
        let t = max(0, min(1, ((point.x - source.x) * dx + (point.y - source.y) * dy) / lengthSquared))
        let projection = CGPoint(x: source.x + t * dx, y: source.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func labelOccluderFrame(for node: GraphPhysicsNode) -> CGRect? {
        graphNodesByID[node.id]?.labelFrame(in: self)
    }

    private func labelOccluderFramesByID() -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: simulator.nodes.compactMap { node in
            labelOccluderFrame(for: node).map { (node.id, $0) }
        })
    }

    private func summaryOcclusionRadius(for node: GraphPhysicsNode) -> CGFloat {
        if let frame = labelOccluderFrame(for: node) {
            let centerDistance = hypot(frame.midX - node.position.x,
                                       frame.midY - node.position.y)
            return max(node.radius, centerDistance + hypot(frame.width, frame.height) * 0.5)
        }
        switch node.kind {
        case .message:
            return node.radius + (summaryCalloutsByID[node.id] == nil ? 18 : 124)
        case .folderGroup, .ghostGroup, .remaining:
            return node.radius + 90
        case .thread:
            return node.radius + 108
        case .center:
            return node.radius
        }
    }

    private var hasRecentInteraction: Bool {
        guard let lastInteractionTime,
              let lastUpdateTime else { return false }
        return lastUpdateTime - lastInteractionTime < Self.interactionActiveFrameWindow
    }

    private func stableEdgeSeed(_ edge: GraphEdge) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in "\(edge.sourceID)->\(edge.targetID)".utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return hash
    }
}

private extension CGVector {
    func scaled(by multiplier: CGFloat) -> CGVector {
        CGVector(dx: dx * multiplier, dy: dy * multiplier)
    }
}
