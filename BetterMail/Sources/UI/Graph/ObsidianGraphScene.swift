import AppKit
import SpriteKit

internal enum ObsidianGraphEdgeStyle {
    internal static func dashPattern(for kind: GraphEdgeKind) -> [CGFloat]? {
        switch kind {
        case .manualChain:
            return [4, 4]
        case .suggested, .remaining:
            return [7, 5]
        case .trunk, .grouping, .chain:
            return nil
        }
    }

    internal static func usesManualThreadColor(_ kind: GraphEdgeKind) -> Bool {
        kind == .manualChain
    }
}

/// Builds the immutable lookup tables used by the live SpriteKit scene.
/// Keeping this index beside the scene avoids rebuilding every GraphData
/// dictionary once per rendered node during each SwiftUI update.
internal struct GraphSceneLookupIndex {
    internal let groupingByID: [String: GraphGrouping]
    internal let threadByID: [String: GraphThread]
    internal let messageByID: [String: GraphMessage]
    internal let remainingBranchByID: [String: GraphRemainingBranch]

    internal init(data: GraphData) {
        groupingByID = Dictionary(uniqueKeysWithValues: data.groupings.map { ($0.id, $0) })
        threadByID = Dictionary(uniqueKeysWithValues: data.threads.map { ($0.id, $0) })
        messageByID = Dictionary(uniqueKeysWithValues: data.messages.map { ($0.id, $0) })
        remainingBranchByID = Dictionary(uniqueKeysWithValues: data.remainingBranches.map { ($0.id, $0) })
    }

    internal func eligibleDragNodeIDs(from nodeIDs: Set<String>) -> Set<String> {
        nodeIDs.filter { threadByID[$0] != nil || messageByID[$0] != nil }
    }

    /// Returns nodes that may participate in direct visual manipulation.
    /// Moving a mark never grants it conversation-mutation eligibility.
    internal func visualDragNodeIDs(from nodeIDs: Set<String>) -> Set<String> {
        nodeIDs.filter { nodeID in
            nodeID == GraphCenter.you.id || threadByID[nodeID] != nil
                || messageByID[nodeID] != nil || groupingByID[nodeID] != nil
                || remainingBranchByID[nodeID] != nil
        }
    }
}

@MainActor
internal struct GraphSpatialSceneConfiguration: Equatable {
    internal let nodePositions: [String: CGPoint]
    internal let confirmedGroupAnchors: [String: CGPoint]
    internal let forceApply: Bool

    internal init(nodePositions: [String: CGPoint],
                  confirmedGroupAnchors: [String: CGPoint],
                  forceApply: Bool = false) {
        self.nodePositions = nodePositions
        self.confirmedGroupAnchors = confirmedGroupAnchors
        self.forceApply = forceApply
    }
}

#if DEBUG
internal struct ObsidianGraphSceneWorkMetrics: Equatable {
    internal var fullRenderPassCount = 0
    internal var dragRenderPassCount = 0
    internal var forceStepCount = 0
    internal var dragSimulationStepCount = 0
    internal var dragCollisionCheckCount = 0
    internal var accessibilityRefreshCount = 0
    internal var dragFrameIntervals: [TimeInterval] = []
}
#endif

/// The mounted SwiftUI adapter owns scene creation. This narrow main-actor
/// handoff lets the presenter publish restored positions before the next scene
/// configuration without changing the existing selection/drag callbacks.
@MainActor
internal enum GraphSpatialSceneBridge {
    private static var pendingConfiguration: GraphSpatialSceneConfiguration?

    internal static func publish(nodePositions: [String: CGPoint],
                                 confirmedGroupAnchors: [String: CGPoint],
                                 forceApply: Bool = false) {
        pendingConfiguration = GraphSpatialSceneConfiguration(
            nodePositions: nodePositions,
            confirmedGroupAnchors: confirmedGroupAnchors,
            forceApply: forceApply
        )
    }

    internal static func consume(for data: GraphData) -> GraphSpatialSceneConfiguration? {
        guard let pendingConfiguration else { return nil }
        if pendingConfiguration.forceApply {
            self.pendingConfiguration = nil
            return pendingConfiguration
        }
        let hasNodeMatch = pendingConfiguration.nodePositions.keys.contains { data.allNodeIDs.contains($0) }
        let confirmedGroupIDs = Set(data.groupings.compactMap { grouping in
            grouping.kind == .folder ? grouping.sourceFolderID : nil
        })
        let hasGroupMatch = pendingConfiguration.confirmedGroupAnchors.keys.contains {
            confirmedGroupIDs.contains($0)
        }
        guard hasNodeMatch || hasGroupMatch else { return nil }
        self.pendingConfiguration = nil
        return pendingConfiguration
    }

    internal static func clear() {
        pendingConfiguration = nil
    }
}

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
    internal var onSelectGraphNodeWithIntent: ((String?, OrganizerPointerSelectionIntent) -> Void)?
    internal var onLassoGraphNodeIDs: ((Set<String>, Bool) -> Void)?
    internal var onExpandRemainingBranches: ((GraphRemainderScope) -> Void)?
    internal var onHoverItem: ((GraphHoverItem?) -> Void)?
    internal var onWaterThread: ((String) -> Void)?
    internal var onToggleActionItem: ((String) -> Void)?
    internal var isActionItem: ((String) -> Bool)?
    internal var onMoveThreadToFolder: ((String, String) -> Void)?
    internal var onMoveThreadsToFolder: (([String], String) -> Void)?
    /// Raw conversation IDs, overlay point, and world-space anchor.
    internal var onCreateGroupAtCanvasPoint: (([String], CGPoint, CGPoint) -> Void)?
    internal var onDropLifecycle: ((OrganizerDropLifecycleSignal) -> Void)?
    internal var onRenderedOrganizerSnapshot: ((OrganizerRenderedGraphSnapshot) -> Void)?
    internal var onSnipTarget: ((GraphSnipTarget) -> Void)?
    internal var onPruneThread: ((String) -> Void)?
    internal var onPruneAnimationFinished: ((UUID) -> Void)?
    internal var onViewportChanged: ((CGFloat, CGPoint) -> Void)?
    internal var onPositionsChanged: (([String: CGPoint]) -> Void)?
    internal var onLayoutSettled: (([String: CGPoint]) -> Void)?
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
    private var graphLookupIndex = GraphSceneLookupIndex(data: .empty)
    private var simulator = ObsidianGraphForceSimulator()
    private var graphNodesByID: [String: ObsidianGraphSceneNode] = [:]
    private var edgeVisualsByID: [String: EdgeVisual] = [:]
    private var neighborIDsByNodeID: [String: Set<String>] = [:]
    private var forceConfig = ObsidianGraphForceConfig.defaults
    private var displayConfig = ObsidianGraphDisplayConfig.defaults
    private var theme = DesignTokens.Graph.AppTheme.Palette(isDark: false)
    private var selectedGraphNodeIDs: Set<String> = []
    private var eligibleSelectedDragNodeIDs: Set<String> = []
    private var isLassoSelectionActive = false
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
    private var restoredNodePositions: [String: CGPoint] = [:]
    private var restoredGroupAnchors: [String: CGPoint] = [:]

    private var lastUpdateTime: TimeInterval?
    private var lastInteractionTime: TimeInterval?
    private var lastPositionReportTime: TimeInterval = 0
    private var settlingFrames = 0
    private var stableFrames = 0
    private var layoutIsSettled = false
    private var positionsReportedAfterSettling = false
    private var publishedFramesPerSecond = ObsidianGraphScene.activeFramesPerSecond

    private var pointerStateMachine = OrganizerPointerStateMachine()
    private var pointerAnchorNodeID: String?
    private var activeDragPlan: OrganizerMultiDragPlan?
    private var activeDraggedNodeIDs: Set<String> = []
    private var activeDragRawThreadIDs: [String] = []
    private var activeDragReactiveNodeIDs: Set<String> = []
    private var localReturningNodeOrigins: [String: CGPoint] = [:]
    private var dragFrameNeedsRender = false
    private var lastDragFrameTime: TimeInterval?
    private var activeFolderDropTarget: GraphFolderDropTarget?
    private var activeDropItemCount = 0
    private var activeDropHadVisibleHighlight = false
    private var activeDropDidRelease = false
    private var isPointerGestureActive = false
    private var isSecondaryPanning = false
    private let lassoNode = SKShapeNode()

    private var runningPruneAnimationID: UUID?
    private var runningSnipVisualTransitionID: UUID?
    private var remainingPruneAnimationNodes = 0
    private let cameraNode = SKCameraNode()

#if DEBUG
    internal private(set) var workMetrics = ObsidianGraphSceneWorkMetrics()

    internal func resetWorkMetricsForTesting() {
        workMetrics = ObsidianGraphSceneWorkMetrics()
    }
#endif

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
                            isLassoSelectionActive: Bool = false,
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
                            pruneAnimationRequest: GraphPruneAnimationRequest? = nil,
                            restoredNodePositions: [String: CGPoint]? = nil,
                            restoredGroupAnchors: [String: CGPoint]? = nil) {
        let dataChanged = data != graphData
        let themeChanged = theme != self.theme
        let textScaleChanged = textScale != self.textScale
        let forceChanged = forceConfig != self.forceConfig
        let displayChanged = displayConfig != self.displayConfig
        let reduceMotionChanged = reduceMotion != self.reduceMotion
        let requestedSpatialConfiguration: GraphSpatialSceneConfiguration?
        if let restoredNodePositions, let restoredGroupAnchors {
            requestedSpatialConfiguration = GraphSpatialSceneConfiguration(
                nodePositions: restoredNodePositions,
                confirmedGroupAnchors: restoredGroupAnchors,
                forceApply: true
            )
        } else {
            requestedSpatialConfiguration = GraphSpatialSceneBridge.consume(for: data)
        }
        let spatialConfigurationChanged = requestedSpatialConfiguration.map {
            $0.nodePositions != self.restoredNodePositions
                || $0.confirmedGroupAnchors != self.restoredGroupAnchors
        } ?? false
        if let requestedSpatialConfiguration {
            self.restoredNodePositions = requestedSpatialConfiguration.nodePositions
            self.restoredGroupAnchors = requestedSpatialConfiguration.confirmedGroupAnchors
        }

        graphData = data
        if dataChanged {
            graphLookupIndex = GraphSceneLookupIndex(data: data)
        }
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
        eligibleSelectedDragNodeIDs = graphLookupIndex.eligibleDragNodeIDs(
            from: self.selectedGraphNodeIDs
        )
        self.isLassoSelectionActive = isLassoSelectionActive
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
        if dataChanged || themeChanged || textScaleChanged || spatialConfigurationChanged || simulator.size != size {
            rebuildGraph(restartLayout: dataChanged || simulator.nodesByID.isEmpty,
                         preservingExistingPositions: requestedSpatialConfiguration?.forceApply != true)
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
        onRenderedOrganizerSnapshot?(renderedOrganizerSnapshot())
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard size.width > 0, size.height > 0 else { return }
        var currentPositions = simulator.positionsByID()
        currentPositions.merge(localReturningNodeOrigins) { _, origin in origin }
        simulator.reset(data: graphData,
                        size: size,
                        preserving: currentPositions,
                        config: forceConfig)
        activeDragReactiveNodeIDs = []
        localReturningNodeOrigins = [:]
        let oldCenter = CGPoint(x: oldSize.width / 2, y: oldSize.height / 2)
        let pan = CGPoint(x: cameraNode.position.x - oldCenter.x,
                          y: cameraNode.position.y - oldCenter.y)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraNode.position = CGPoint(x: center.x + pan.x, y: center.y + pan.y)
        wakeLayout()
        renderGraph()
        onRenderedOrganizerSnapshot?(renderedOrganizerSnapshot())
    }

    /// Re-evaluates native accessibility visibility when AppKit attaches,
    /// detaches, shows, or otherwise changes the hosting window. A model-only
    /// render must never make benchmark readiness appear onscreen.
    internal func refreshRenderedOrganizerSnapshotForWindowState() {
        renderGraph()
        onRenderedOrganizerSnapshot?(renderedOrganizerSnapshot())
    }

    override func update(_ currentTime: TimeInterval) {
        let previousTime = lastUpdateTime ?? currentTime
        lastUpdateTime = currentTime
        let wasLayoutSettled = layoutIsSettled
        let isDragging = !activeDraggedNodeIDs.isEmpty
        let isLocallySettling = !localReturningNodeOrigins.isEmpty
            && !isDragging
            && !isPointerGestureActive
        let shouldSimulate = !layoutIsSettled
            && !isPointerGestureActive
            && localReturningNodeOrigins.isEmpty
        if isDragging {
#if DEBUG
            workMetrics.dragSimulationStepCount += 1
            if let lastDragFrameTime, currentTime > lastDragFrameTime,
               workMetrics.dragFrameIntervals.count < 3_600 {
                workMetrics.dragFrameIntervals.append(currentTime - lastDragFrameTime)
            }
#endif
            lastDragFrameTime = currentTime
            let changedNodeIDs = simulator.stepDragging(
                deltaTime: min(max(currentTime - previousTime, 1.0 / 240.0), 1.0 / 20.0),
                reduceMotion: reduceMotion,
                zoomScale: currentZoomScale,
                nodeScale: displayConfig.nodeSize
            )
#if DEBUG
            workMetrics.dragCollisionCheckCount += simulator.lastDragCollisionCheckCount
#endif
            activeDragReactiveNodeIDs = changedNodeIDs
            if dragFrameNeedsRender || !changedNodeIDs.isEmpty {
                renderDragFrame()
                dragFrameNeedsRender = false
            }
        } else if isLocallySettling {
            let changedNodeIDs = simulator.stepLocalSettling(
                deltaTime: min(max(currentTime - previousTime, 1.0 / 240.0), 1.0 / 20.0),
                returningNodeOrigins: localReturningNodeOrigins,
                reduceMotion: reduceMotion
            )
            activeDragReactiveNodeIDs = changedNodeIDs
            if !changedNodeIDs.isEmpty {
                renderDragFrame()
            }
            if simulator.isAtPositions(localReturningNodeOrigins) {
                simulator.restorePositions(localReturningNodeOrigins)
                localReturningNodeOrigins = [:]
                activeDragReactiveNodeIDs = []
                finishDragSettling()
                renderGraph()
            }
        } else if shouldSimulate {
#if DEBUG
            workMetrics.forceStepCount += 1
#endif
            simulator.step(deltaTime: min(max(currentTime - previousTime, 1.0 / 240.0), 1.0 / 20.0),
                           reduceMotion: reduceMotion,
                           config: forceConfig)
            updateSettlingState()
            renderGraph()
        }
        if !wasLayoutSettled, layoutIsSettled {
            onRenderedOrganizerSnapshot?(renderedOrganizerSnapshot())
        }
        if cameraNode.action(forKey: "obsidian-camera-recenter") != nil {
            updateLabels()
            updateAccessibilityGeometry()
        }
        if shouldReportPositions,
           currentTime - lastPositionReportTime >= 0.2 {
            lastPositionReportTime = currentTime
            let positions = simulator.positionsByID()
            onPositionsChanged?(positions)
            if layoutIsSettled {
                positionsReportedAfterSettling = true
                onLayoutSettled?(positions)
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
        activeDragReactiveNodeIDs = []
        localReturningNodeOrigins = [:]
        onSelectGraphNode = nil
        onSelectGraphNodeWithIntent = nil
        onLassoGraphNodeIDs = nil
        onExpandRemainingBranches = nil
        onHoverItem = nil
        onWaterThread = nil
        onToggleActionItem = nil
        isActionItem = nil
        onMoveThreadToFolder = nil
        onMoveThreadsToFolder = nil
        onCreateGroupAtCanvasPoint = nil
        onDropLifecycle = nil
        onRenderedOrganizerSnapshot = nil
        onSnipTarget = nil
        onPruneThread = nil
        onPruneAnimationFinished = nil
        onViewportChanged = nil
        onPositionsChanged = nil
        onLayoutSettled = nil
        onFrameRatePreferenceChanged = nil
        selectedGraphNodeIDs = []
        eligibleSelectedDragNodeIDs = []
        hoveredGraphNodeID = nil
        cancelDirectManipulation()
        activeFolderDropTarget = nil
        graphData = .empty
        graphLookupIndex = GraphSceneLookupIndex(data: .empty)
        simulator = ObsidianGraphForceSimulator()
        filteredNodeIDs = []
        wateredCounts = [:]
        sproutingMessageIDs = []
        stagedSnipThreadIDs = []
        fullyStagedSnipGroupingIDs = []
        partiallyStagedSnipGroupingIDs = []
        restoredNodePositions = [:]
        restoredGroupAnchors = [:]
        GraphSpatialSceneBridge.clear()
        runningSnipVisualTransitionID = nil
        lastUpdateTime = nil
        lastInteractionTime = nil
        removeAllActions()
        removeAllChildren()
    }

    override func mouseDown(with event: NSEvent) {
        markInteraction()
        cancelDirectManipulation()
        setActiveFolderDropTarget(nil)
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
            if event.clickCount >= 2,
               graphLookupIndex.threadByID[hitNodeID] != nil,
               let threadID = threadID(forGraphNodeID: hitNodeID) {
                onWaterThread?(threadID)
                graphNodesByID[hitNodeID]?.runWaterPulse(reduceMotion: reduceMotion)
                return
            }
            pointerAnchorNodeID = hitNodeID
        }

        if event.clickCount >= 2 {
            publishSelection(nodeID: nil, intent: .replace)
            recenterCamera(animated: true)
            return
        }

        pointerStateMachine.begin(
            at: location,
            hitNodeID: hitNodeID,
            selectedNodeIDs: visualDragNodeIDs(from: selectedGraphNodeIDs,
                                                anchoredNodeID: hitNodeID),
            modifiers: organizerModifiers(from: event.modifierFlags),
            lassoArmed: isLassoSelectionActive
        )
        isPointerGestureActive = true
    }

    @discardableResult
    internal func expandRemainingBranchIfPresent(nodeID: String) -> Bool {
        guard let remaining = graphLookupIndex.remainingBranchByID[nodeID] else { return false }
        onExpandRemainingBranches?(remaining.scope)
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        markInteraction()
        clearHover()
        let location = event.location(in: self)
        switch pointerStateMachine.move(to: location, zoomScale: currentZoomScale) {
        case .none:
            return
        case .pan(let delta):
            panByWorld(delta: delta)
            publishViewport()
        case .lasso(let rect):
            showLasso(rect)
        case .drag(let requestedNodeIDs, let delta):
            guard let anchorNodeID = pointerAnchorNodeID else {
                return
            }
            let visualNodeIDs = visualDragNodeIDs(from: Set(requestedNodeIDs),
                                                   anchoredNodeID: anchorNodeID)
            guard visualNodeIDs.contains(anchorNodeID),
                  let plan = activeDragPlan ?? OrganizerMultiDragPlan(
                    anchorNodeID: anchorNodeID,
                    selectedNodeIDs: visualNodeIDs,
                    positions: simulator.positionsByID()
                  ) else {
                return
            }
            if activeDragPlan == nil {
                activeDragPlan = plan
                activeDraggedNodeIDs = Set(plan.nodeIDs)
                activeDragRawThreadIDs = rawThreadIDs(forGraphNodeIDs: activeDraggedNodeIDs)
                activeDragReactiveNodeIDs = []
                lastDragFrameTime = nil
                localReturningNodeOrigins = [:]
                simulator.beginDragging(
                    nodeIDs: activeDraggedNodeIDs,
                    keepingStationary: stationaryFolderNodeIDs(
                        forDraggedGraphNodeIDs: activeDraggedNodeIDs
                    )
                )
                applyVisualState()
            }
            NSCursor.closedHand.set()
            simulator.drag(nodePositions: plan.positions(byApplying: delta))
            let target = activeDragRawThreadIDs.isEmpty
                ? nil
                : batchFolderDropTarget(at: location,
                                        rawThreadIDs: activeDragRawThreadIDs)
            let itemCount = activeDragRawThreadIDs.count
            if itemCount >= 2 || target != nil {
                beginDropLifecycleIfNeeded(itemCount: itemCount)
            }
            if target != nil {
                noteVisibleDropHighlight(itemCount: itemCount)
            }
            setActiveFolderDropTarget(target?.singleCompatibilityTarget)
            dragFrameNeedsRender = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        markInteraction()
        let location = event.location(in: self)
        let hadActiveDrag = !activeDraggedNodeIDs.isEmpty
        var dragReturningNodeOrigins: [String: CGPoint] = [:]
        switch pointerStateMachine.end(at: location) {
        case .none:
            if hadActiveDrag {
                dragReturningNodeOrigins = simulator.lastDragReactiveNodeOrigins
                simulator.cancelDragging()
            }
        case .select(let nodeID, let intent):
            if !expandRemainingBranchIfPresent(nodeID: nodeID) {
                publishSelection(nodeID: nodeID, intent: intent)
            }
        case .clearSelection:
            publishSelection(nodeID: nil, intent: .replace)
        case .finishPan:
            publishViewport()
        case .finishLasso(let rect, let additive):
            let nodeIDs = Set(OrganizerLassoGeometry.selectedNodeIDs(
                in: rect,
                regions: selectableRegions()
            ))
            onLassoGraphNodeIDs?(nodeIDs, additive)
        case .finishDrag(let nodeIDs, _, let delta):
            guard hadActiveDrag, let plan = activeDragPlan else {
                dragReturningNodeOrigins = simulator.lastDragReactiveNodeOrigins
                simulator.cancelDragging()
                break
            }
            // Resolve the final pointer sample before releasing, including a
            // mouse-up that arrived between display frames. Keep clearance
            // around the placed nodes instead of undoing the user's layout.
            simulator.drag(nodePositions: plan.positions(byApplying: delta))
            simulator.stepDragging(deltaTime: 1.0 / 60.0,
                                   reduceMotion: reduceMotion,
                                   zoomScale: currentZoomScale,
                                   nodeScale: displayConfig.nodeSize)
            dragReturningNodeOrigins = simulator.lastDragSettlingPositions
            simulator.endDragging(nodePositions: plan.positions(byApplying: delta))
            let draggedIDs = activeDraggedNodeIDs.isEmpty ? Set(nodeIDs) : activeDraggedNodeIDs
            let rawThreadIDs = activeDragRawThreadIDs.isEmpty
                ? rawThreadIDs(forGraphNodeIDs: draggedIDs)
                : activeDragRawThreadIDs
            let target = rawThreadIDs.isEmpty
                ? nil
                : batchFolderDropTarget(at: location,
                                        rawThreadIDs: rawThreadIDs)
            let blockingNodeID = hitTestNodeID(at: location, excluding: draggedIDs)
            if let target {
                beginDropLifecycleIfNeeded(itemCount: rawThreadIDs.count)
                noteVisibleDropHighlight(itemCount: rawThreadIDs.count)
                releaseDropLifecycle(destination: .confirmedGroup)
                _ = performBatchFolderDrop(target)
            } else if rawThreadIDs.count >= 2, blockingNodeID == nil {
                beginDropLifecycleIfNeeded(itemCount: rawThreadIDs.count)
                releaseDropLifecycle(destination: .emptyCanvas)
                onCreateGroupAtCanvasPoint?(rawThreadIDs,
                                            overlayPoint(for: location),
                                            location)
            } else if blockingNodeID != nil || activeDropItemCount > 0 {
                beginDropLifecycleIfNeeded(itemCount: rawThreadIDs.count)
                releaseDropLifecycle(destination: .invalidTarget)
            }
        }
        if hadActiveDrag {
            if dragReturningNodeOrigins.isEmpty {
                activeDragReactiveNodeIDs = []
                finishDragSettling()
            } else {
                beginLocalSettling(returningNodeOrigins: dragReturningNodeOrigins)
            }
        }
        hideLasso()
        activeDragPlan = nil
        activeDraggedNodeIDs = []
        activeDragRawThreadIDs = []
        dragFrameNeedsRender = false
        pointerAnchorNodeID = nil
        isPointerGestureActive = false
        setActiveFolderDropTarget(nil)
        resetDropLifecycle()
        if hadActiveDrag {
            applyVisualState()
            renderGraph()
            onRenderedOrganizerSnapshot?(renderedOrganizerSnapshot())
        }
        NSCursor.arrow.set()
        publishFrameRatePreferenceIfNeeded()
    }

    override func rightMouseDown(with event: NSEvent) {
        markInteraction()
        clearHover()
        cancelDirectManipulation()
        isSecondaryPanning = true
    }

    override func rightMouseDragged(with event: NSEvent) {
        markInteraction()
        guard isSecondaryPanning else { return }
        panBy(deltaX: event.deltaX, deltaY: event.deltaY)
        publishViewport()
    }

    override func rightMouseUp(with event: NSEvent) {
        markInteraction()
        isSecondaryPanning = false
    }

    internal func contextMenu(at viewPoint: CGPoint) -> NSMenu? {
        let location = convertPoint(fromView: viewPoint)
        markInteraction()
        clearHover()
        guard let graphNodeID = hitTestNodeID(at: location) else {
            return createGroupContextMenu(at: location)
        }
        if let grouping = graphLookupIndex.groupingByID[graphNodeID],
           grouping.kind == .folder {
            return confirmedGroupContextMenu(grouping: grouping, at: location)
        }
        return conversationContextMenu(forGraphNodeID: graphNodeID, at: location)
    }

    internal func actionItemContextMenu(forGraphNodeID graphNodeID: String) -> NSMenu? {
        guard pruneMode == .idle,
              graphLookupIndex.threadByID[graphNodeID] != nil || graphLookupIndex.messageByID[graphNodeID] != nil,
              let onToggleActionItem else {
            return nil
        }

        if !selectedGraphNodeIDs.contains(graphNodeID) {
            publishSelection(nodeID: graphNodeID, intent: .replace)
        }
        let isActionItem = isActionItem?(graphNodeID) ?? false
        let title = isActionItem
            ? NSLocalizedString("graph.actions.remove_action_item",
                                comment: "Remove selected graph email from action items")
            : NSLocalizedString("graph.actions.action_item",
                                comment: "Mark selected graph email as an action item")
        let menu = NSMenu()
        menu.addItem(contextMenuItem(title: title,
                                     systemImage: isActionItem ? "checkmark.circle.fill" : "bolt.circle") {
            onToggleActionItem(graphNodeID)
        })
        return menu
    }

    private func conversationContextMenu(forGraphNodeID graphNodeID: String,
                                         at location: CGPoint) -> NSMenu? {
        guard pruneMode == .idle,
              graphLookupIndex.threadByID[graphNodeID] != nil || graphLookupIndex.messageByID[graphNodeID] != nil else {
            return nil
        }
        if !selectedGraphNodeIDs.contains(graphNodeID) {
            publishSelection(nodeID: graphNodeID, intent: .replace)
        }
        let menuSelection = selectedGraphNodeIDs.contains(graphNodeID)
            ? eligibleDragNodeIDs(from: selectedGraphNodeIDs)
            : [graphNodeID]
        let rawThreadIDs = rawThreadIDs(forGraphNodeIDs: menuSelection)
        let menu = NSMenu()

        if rawThreadIDs.count >= 2 {
            menu.addItem(contextMenuItem(
                title: NSLocalizedString("graph.actions.create_group_here",
                                         comment: "Create a BetterMail Group from the graph action menu"),
                systemImage: "folder.badge.plus"
            ) { [weak self] in
                guard let self else { return }
                self.onCreateGroupAtCanvasPoint?(rawThreadIDs,
                                                  self.overlayPoint(for: location),
                                                  location)
            })
        }

        if let onToggleActionItem {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let isActionItem = isActionItem?(graphNodeID) ?? false
            let title = isActionItem
                ? NSLocalizedString("graph.actions.remove_action_item",
                                    comment: "Remove selected graph email from action items")
                : NSLocalizedString("graph.actions.action_item",
                                    comment: "Mark selected graph email as an action item")
            menu.addItem(contextMenuItem(title: title,
                                         systemImage: isActionItem ? "checkmark.circle.fill" : "bolt.circle") {
                onToggleActionItem(graphNodeID)
            })
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func confirmedGroupContextMenu(grouping: GraphGrouping,
                                           at location: CGPoint) -> NSMenu? {
        let selectedIDs = eligibleDragNodeIDs(from: selectedGraphNodeIDs)
        guard !selectedIDs.isEmpty,
              let target = batchFolderDropTarget(at: location,
                                                 draggedGraphNodeIDs: selectedIDs) else {
            return nil
        }
        let menu = NSMenu()
        menu.addItem(contextMenuItem(
            title: NSLocalizedString("graph.actions.move_selection_here",
                                     comment: "Move selected conversations into a confirmed Group"),
            systemImage: "folder"
        ) { [weak self] in
            _ = self?.performBatchFolderDrop(at: location,
                                             rawThreadIDs: target.rawThreadIDs)
        })
        return menu
    }

    private func createGroupContextMenu(at location: CGPoint) -> NSMenu? {
        let rawThreadIDs = rawThreadIDs(
            forGraphNodeIDs: eligibleDragNodeIDs(from: selectedGraphNodeIDs)
        )
        guard rawThreadIDs.count >= 2 else { return nil }
        let menu = NSMenu()
        menu.addItem(contextMenuItem(
            title: NSLocalizedString("graph.actions.create_group_here",
                                     comment: "Create a BetterMail Group from the graph action menu"),
            systemImage: "folder.badge.plus"
        ) { [weak self] in
            guard let self else { return }
            self.onCreateGroupAtCanvasPoint?(rawThreadIDs,
                                              self.overlayPoint(for: location),
                                              location)
        })
        return menu
    }

    private func contextMenuItem(title: String,
                                 systemImage: String,
                                 handler: @escaping () -> Void) -> NSMenuItem {
        let action = GraphContextMenuAction(handler: handler)
        let item = NSMenuItem(title: title,
                              action: #selector(GraphContextMenuAction.perform(_:)),
                              keyEquivalent: "")
        item.image = NSImage(systemSymbolName: systemImage,
                             accessibilityDescription: title)
        item.target = action
        item.representedObject = action
        return item
    }

    override func mouseMoved(with event: NSEvent) {
        markInteraction()
        guard activeDraggedNodeIDs.isEmpty,
              !isPointerGestureActive,
              !isSecondaryPanning else {
            clearHover()
            return
        }
        let location = event.location(in: self)
        let hitNodeID = hitTestNodeID(at: location)
        if hitNodeID != nil, pruneMode == .idle {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
        applyHoverCandidate(hitNodeID, at: location)
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
        if activeDraggedNodeIDs.isEmpty { NSCursor.arrow.set() }
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
        if let grouping = graphLookupIndex.groupingByID[nextHoveredID] {
            onHoverItem?(.grouping(grouping, overlayLocation))
        } else if let thread = graphLookupIndex.threadByID[nextHoveredID] {
            onHoverItem?(.thread(thread, overlayLocation))
        } else if let remaining = graphLookupIndex.remainingBranchByID[nextHoveredID] {
            onHoverItem?(.remaining(remaining, overlayLocation))
        } else if let message = graphLookupIndex.messageByID[nextHoveredID] {
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
        lassoNode.fillColor = theme.accentNS.withAlphaComponent(0.08)
        lassoNode.strokeColor = theme.accentNS.withAlphaComponent(0.82)
        lassoNode.lineWidth = 1.5
        lassoNode.zPosition = 100
        lassoNode.isHidden = true
        addChild(lassoNode)
    }

    private func rebuildGraph(restartLayout: Bool,
                              preservingExistingPositions: Bool = true) {
        runningPruneAnimationID = nil
        remainingPruneAnimationNodes = 0
        var existingPositions = preservingExistingPositions ? simulator.positionsByID() : [:]
        existingPositions.merge(localReturningNodeOrigins) { _, origin in origin }
        for (nodeID, position) in restoredNodePositions where position.x.isFinite && position.y.isFinite {
            existingPositions[nodeID] = position
        }
        for grouping in graphData.groupings where grouping.kind == .folder {
            guard let folderID = grouping.sourceFolderID,
                  let anchor = restoredGroupAnchors[folderID],
                  anchor.x.isFinite,
                  anchor.y.isFinite else { continue }
            existingPositions[grouping.id] = anchor
        }
        simulator.reset(data: graphData,
                        size: size,
                        preserving: existingPositions,
                        config: forceConfig)
        activeDragReactiveNodeIDs = []
        localReturningNodeOrigins = [:]

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
            if let remaining = graphLookupIndex.remainingBranchByID[physicsNode.id] {
                node.configureExpansionAccessibility(label: remaining.accessibilityLabel) { [weak self] in
                    _ = self?.expandRemainingBranchIfPresent(nodeID: remaining.id)
                }
            } else {
                configureOrganizerAccessibility(forGraphNodeID: physicsNode.id, node: node)
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
        restoredNodePositions = [:]
        restoredGroupAnchors = [:]
    }

    private func renderGraph() {
#if DEBUG
        workMetrics.fullRenderPassCount += 1
#endif
        for physicsNode in simulator.nodes {
            graphNodesByID[physicsNode.id]?.position = physicsNode.position
        }
        for edge in graphData.edges {
            render(edge: edge)
        }
        updateLabels()
        updateAccessibilityGeometry()
    }

    /// Pointer events can arrive substantially faster than the display refresh
    /// rate. During a drag, the global layout is frozen, so only the dragged
    /// cohort, locally reacting nodes, and their incident edges need geometry
    /// updates on the next frame. Labels move with their parent nodes;
    /// accessibility geometry is refreshed by the full render on release or
    /// cancellation.
    private func renderDragFrame() {
#if DEBUG
        workMetrics.dragRenderPassCount += 1
#endif
        let renderedNodeIDs = activeDraggedNodeIDs.union(activeDragReactiveNodeIDs)
        for nodeID in renderedNodeIDs {
            guard let physicsNode = simulator.nodesByID[nodeID] else { continue }
            graphNodesByID[nodeID]?.position = physicsNode.position
        }
        for edge in graphData.edges where renderedNodeIDs.contains(edge.sourceID)
            || renderedNodeIDs.contains(edge.targetID) {
            render(edge: edge)
        }
    }

    private func updateAccessibilityGeometry() {
        guard let view else { return }
#if DEBUG
        workMetrics.accessibilityRefreshCount += 1
#endif
        let visibleElements: [ObsidianGraphAccessibilityElement] = graphNodesByID.keys.sorted().compactMap { nodeID in
            guard let node = graphNodesByID[nodeID],
                  let element = node.updateAccessibilityGeometry(in: self, view: view),
                  node.isAccessibilityVisible(in: view) else {
                return nil
            }
            return element
        }
        (view as? GraphSKView)?.updateGraphAccessibilityElements(visibleElements)
    }

    private func render(edge: GraphEdge) {
        guard let visual = edgeVisualsByID[edge.id],
              let source = simulator.nodesByID[edge.sourceID],
              let target = simulator.nodesByID[edge.targetID] else { return }
        let geometry = trimmedEdge(source: source, target: target)
        if let dashPattern = ObsidianGraphEdgeStyle.dashPattern(for: edge.kind) {
            visual.line.path = Self.dashedLinePath(from: geometry.start,
                                                   to: geometry.end,
                                                   dash: dashPattern[0],
                                                   gap: dashPattern[1])
        } else {
            visual.line.path = Self.linePath(from: geometry.start, to: geometry.end)
        }
        visual.arrow.path = Self.arrowPath(from: geometry.start, to: geometry.end)
        visual.arrow.isHidden = !displayConfig.showsArrows
        applyStyle(to: visual, edge: edge)
    }

    private func applyVisualState() {
        let focusedNodeIDs = interactionFocusedNodeIDs
        let neighbors = Set(focusedNodeIDs.flatMap { neighborIDsByNodeID[$0] ?? [] })
        for (id, node) in graphNodesByID {
            let isSelected = selectedGraphNodeIDs.contains(id) || activeDraggedNodeIDs.contains(id)
            node.zPosition = activeDraggedNodeIDs.contains(id) ? 20 : 2
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
            configureOrganizerAccessibility(forGraphNodeID: id, node: node)
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
        if ObsidianGraphEdgeStyle.usesManualThreadColor(edge.kind) {
            baseColor = theme.manualThreadNS
        } else {
            switch edge.kind {
            case .suggested:
                baseColor = theme.accentNS
            case .remaining:
                baseColor = theme.archiveNS
            case .trunk, .grouping, .chain:
                baseColor = theme.inkTertiaryNS
            case .manualChain:
                baseColor = theme.manualThreadNS
            }
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
        let activeBaseColor: NSColor
        if isStaged || isPartiallyStaged {
            activeBaseColor = theme.snipNS
        } else if ObsidianGraphEdgeStyle.usesManualThreadColor(edge.kind) {
            // Manual provenance must remain visually distinct while its
            // endpoints are selected or hovered; focus changes emphasis, not
            // relationship meaning.
            activeBaseColor = baseColor
        } else {
            activeBaseColor = isConnected && !focusedNodeIDs.isEmpty
                ? theme.accentNS
                : baseColor
        }
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

    private func configureOrganizerAccessibility(forGraphNodeID graphNodeID: String,
                                                  node: ObsidianGraphSceneNode) {
        let role: OrganizerAccessibilityRole
        let label: String
        let rawTokenSource: String
        let actions: [OrganizerAccessibilityAction]

        if let grouping = graphLookupIndex.groupingByID[graphNodeID] {
            role = grouping.isSuggestion ? .suggestedGroup : .confirmedGroup
            label = grouping.title
            rawTokenSource = grouping.sourceFolderID ?? grouping.id
            if grouping.kind == .folder,
               !eligibleSelectedDragNodeIDs.isEmpty {
                actions = [.activate, .moveSelectionHere]
            } else {
                actions = [.activate]
            }
        } else if let thread = graphLookupIndex.threadByID[graphNodeID] {
            role = .conversation
            label = thread.displayTitle
            rawTokenSource = thread.rawThreadID
            var conversationActions: [OrganizerAccessibilityAction] = [
                .activate,
                selectedGraphNodeIDs.contains(graphNodeID) ? .removeFromSelection : .addToSelection
            ]
            if selectedGraphNodeIDs.contains(graphNodeID),
               eligibleSelectedDragNodeIDs.count >= 2 {
                conversationActions.append(.createGroupHere)
            }
            actions = conversationActions
        } else if let message = graphLookupIndex.messageByID[graphNodeID] {
            role = .conversation
            label = message.displayTitle
            rawTokenSource = message.rawMessageID
            var conversationActions: [OrganizerAccessibilityAction] = [
                .activate,
                selectedGraphNodeIDs.contains(graphNodeID) ? .removeFromSelection : .addToSelection
            ]
            if selectedGraphNodeIDs.contains(graphNodeID),
               eligibleSelectedDragNodeIDs.count >= 2 {
                conversationActions.append(.createGroupHere)
            }
            actions = conversationActions
        } else {
            return
        }

        let token = OrganizationOpaqueFingerprint.digest(namespace: "accessibility-\(role.rawValue)",
                                                           rawValue: rawTokenSource)
        guard let descriptor = OrganizerAccessibilityDescriptor(
            role: role,
            opaqueToken: token,
            label: label,
            hint: NSLocalizedString("accessibility.organizer.node.hint",
                                    comment: "Organizer graph node accessibility hint"),
            isSelected: selectedGraphNodeIDs.contains(graphNodeID),
            actions: actions
        ) else {
            return
        }
        node.configureOrganizerAccessibility(descriptor) { [weak self] action in
            self?.performOrganizerAccessibilityAction(action,
                                                      graphNodeID: graphNodeID) ?? false
        }
    }

    private func performOrganizerAccessibilityAction(_ action: OrganizerAccessibilityAction,
                                                      graphNodeID: String) -> Bool {
        switch action {
        case .activate:
            publishSelection(nodeID: graphNodeID, intent: .replace)
            return true
        case .addToSelection, .removeFromSelection:
            publishSelection(nodeID: graphNodeID, intent: .toggle)
            return true
        case .moveSelectionHere:
            guard graphLookupIndex.groupingByID[graphNodeID]?.kind == .folder,
                  let point = simulator.nodesByID[graphNodeID]?.position else {
                return false
            }
            return performBatchFolderDrop(
                at: point,
                draggedGraphNodeIDs: eligibleDragNodeIDs(from: selectedGraphNodeIDs)
            )
        case .createGroupHere:
            let selectedIDs = eligibleDragNodeIDs(from: selectedGraphNodeIDs)
            let rawThreadIDs = rawThreadIDs(forGraphNodeIDs: selectedIDs)
            guard rawThreadIDs.count >= 2,
                  let point = simulator.nodesByID[graphNodeID]?.position else {
                return false
            }
            onCreateGroupAtCanvasPoint?(rawThreadIDs, overlayPoint(for: point), point)
            return true
        }
    }

    private func nodeDescriptor(for physicsNode: ObsidianGraphPhysicsNode)
    -> (title: String?, threadID: String?, fill: NSColor, stroke: NSColor) {
        if physicsNode.kind == .center {
            return (graphData.center.title, nil, theme.accentNS, theme.accentNS)
        }
        if let grouping = graphLookupIndex.groupingByID[physicsNode.id] {
            return (grouping.title,
                    nil,
                    grouping.isSuggestion ? theme.panelSecondaryNS : theme.accentSoftNS,
                    theme.accentNS)
        }
        if let thread = graphLookupIndex.threadByID[physicsNode.id] {
            let stroke = thread.isLive ? theme.liveNS : strokeColor(for: thread.importance)
            return (thread.displayTitle, thread.id, theme.panelNS, stroke)
        }
        if let remaining = graphLookupIndex.remainingBranchByID[physicsNode.id] {
            return (remaining.title, nil, theme.panelSecondaryNS, theme.archiveNS)
        }
        if let message = graphLookupIndex.messageByID[physicsNode.id] {
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
            return activeDraggedNodeIDs.union([activeFolderDropTarget.graphNodeID])
        }
        if !activeDraggedNodeIDs.isEmpty { return activeDraggedNodeIDs }
        return hoveredGraphNodeID.map { Set([$0]) } ?? selectedGraphNodeIDs
    }

    private func setActiveFolderDropTarget(_ target: GraphFolderDropTarget?) {
        guard target != activeFolderDropTarget else { return }
        activeFolderDropTarget = target
        applyVisualState()
    }

    private func beginDropLifecycleIfNeeded(itemCount: Int) {
        guard activeDropItemCount == 0, itemCount > 0 else { return }
        activeDropItemCount = itemCount
        activeDropHadVisibleHighlight = false
        activeDropDidRelease = false
        onDropLifecycle?(.intent(itemCount: itemCount))
    }

    private func noteVisibleDropHighlight(itemCount: Int) {
        beginDropLifecycleIfNeeded(itemCount: itemCount)
        guard activeDropItemCount > 0,
              !activeDropHadVisibleHighlight else { return }
        activeDropHadVisibleHighlight = true
        onDropLifecycle?(.highlight(itemCount: activeDropItemCount))
    }

    private func releaseDropLifecycle(destination: OrganizerDropDestinationKind) {
        guard activeDropItemCount > 0, !activeDropDidRelease else { return }
        activeDropDidRelease = true
        onDropLifecycle?(.release(itemCount: activeDropItemCount,
                                  destination: destination,
                                  hadVisibleHighlight: activeDropHadVisibleHighlight))
    }

    private func cancelDropLifecycleIfNeeded() {
        guard activeDropItemCount > 0, !activeDropDidRelease else { return }
        onDropLifecycle?(.cancelled(itemCount: activeDropItemCount))
    }

    private func resetDropLifecycle() {
        activeDropItemCount = 0
        activeDropHadVisibleHighlight = false
        activeDropDidRelease = false
    }

    private func renderedOrganizerSnapshot() -> OrganizerRenderedGraphSnapshot {
        let memberCounts = graphData.groupings.reduce(into: [String: Int]()) { result, grouping in
            guard grouping.kind == .folder else { return }
            result[grouping.id] = OrganizerRenderedGraphSnapshot.confirmedMemberCount(
                rawThreadIDs: grouping.rawThreadIDs,
                renderedThreadIDs: grouping.threadIDs
            )
        }
        let membershipsByGroupKey = graphData.groupings.reduce(
            into: [String: Set<String>]()
        ) { result, grouping in
            guard grouping.kind == .folder,
                  let sourceFolderID = grouping.sourceFolderID else { return }
            result[sourceFolderID] = Set(grouping.rawThreadIDs)
        }
        let accessibleFilteredConversationRawThreadIDs = filteredNodeIDs.reduce(into: Set<String>()) {
            rawThreadIDs, nodeID in
            guard let view,
                  graphNodesByID[nodeID]?.isOrganizerAccessibilityVisible(in: view) == true,
                  let rawThreadID = graphLookupIndex.threadByID[nodeID]?.rawThreadID else {
                return
            }
            rawThreadIDs.insert(rawThreadID)
        }
        let accessibleConversationRawThreadIDs = graphData.threads.reduce(into: Set<String>()) {
            rawThreadIDs, thread in
            guard let view,
                  graphNodesByID[thread.id]?.isOrganizerAccessibilityVisible(in: view) == true else {
                return
            }
            rawThreadIDs.insert(thread.rawThreadID)
        }
        let accessibleConfirmedGroupKeys = graphData.groupings.reduce(into: Set<String>()) {
            groupKeys, grouping in
            guard grouping.kind == .folder,
                  let sourceFolderID = grouping.sourceFolderID,
                  let view,
                  graphNodesByID[grouping.id]?.isOrganizerAccessibilityVisible(in: view) == true else {
                return
            }
            groupKeys.insert(sourceFolderID)
        }
        let accessibleConversationFramesByRawThreadID = graphData.threads.reduce(
            into: [String: OrganizerRenderedAccessibilityFrame]()
        ) { frames, thread in
            guard let view,
                  let frame = graphNodesByID[thread.id]?
                    .organizerAccessibilityFrameInScreen(in: view) else { return }
            frames[thread.rawThreadID] = OrganizerRenderedAccessibilityFrame(frame)
        }
        let accessibleConfirmedGroupFramesByGroupKey = graphData.groupings.reduce(
            into: [String: OrganizerRenderedAccessibilityFrame]()
        ) { frames, grouping in
            guard grouping.kind == .folder,
                  let sourceFolderID = grouping.sourceFolderID,
                  let view,
                  let frame = graphNodesByID[grouping.id]?
                    .organizerAccessibilityFrameInScreen(in: view) else { return }
            frames[sourceFolderID] = OrganizerRenderedAccessibilityFrame(frame)
        }
        let accessibilityScreenFrame: OrganizerRenderedAccessibilityFrame?
        if let screen = view?.window?.screen {
            accessibilityScreenFrame = OrganizerRenderedAccessibilityFrame(screen.frame)
        } else {
            accessibilityScreenFrame = nil
        }
        return OrganizerRenderedGraphSnapshot(
            isLayoutSettled: layoutIsSettled,
            confirmedMemberCountsByGroupID: memberCounts,
            filteredAccessibleConversationRawThreadIDs: accessibleFilteredConversationRawThreadIDs,
            accessibleConversationRawThreadIDs: accessibleConversationRawThreadIDs,
            accessibleConfirmedGroupKeys: accessibleConfirmedGroupKeys,
            accessibleConversationFramesByRawThreadID:
                accessibleConversationFramesByRawThreadID,
            accessibleConfirmedGroupFramesByGroupKey:
                accessibleConfirmedGroupFramesByGroupKey,
            accessibilityScreenFrame: accessibilityScreenFrame,
            confirmedRawThreadIDsByGroupKey: membershipsByGroupKey
        )
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

    private func panByWorld(delta: CGVector) {
        cameraNode.position = CGPoint(x: cameraNode.position.x - delta.dx,
                                      y: cameraNode.position.y - delta.dy)
    }

    private func organizerModifiers(from flags: NSEvent.ModifierFlags) -> OrganizerPointerModifiers {
        var modifiers: OrganizerPointerModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    private func eligibleDragNodeIDs(from nodeIDs: Set<String>) -> Set<String> {
        graphLookupIndex.eligibleDragNodeIDs(from: nodeIDs)
    }

    private func visualDragNodeIDs(from nodeIDs: Set<String>,
                                   anchoredNodeID: String?) -> Set<String> {
        let candidates = graphLookupIndex.visualDragNodeIDs(from: nodeIDs)
        guard let anchoredNodeID,
              graphLookupIndex.eligibleDragNodeIDs(from: [anchoredNodeID]).isEmpty else {
            return graphLookupIndex.eligibleDragNodeIDs(from: candidates)
        }
        // Folders, suggestions, You, and paging marks move independently of
        // any stale conversation selection and never become a merge payload.
        return graphLookupIndex.visualDragNodeIDs(from: [anchoredNodeID])
    }

    private func rawThreadIDs(forGraphNodeIDs nodeIDs: Set<String>) -> [String] {
        Set(nodeIDs.compactMap(rawThreadID(forGraphNodeID:))).sorted()
    }

    private func publishSelection(nodeID: String?, intent: OrganizerPointerSelectionIntent) {
        if let onSelectGraphNodeWithIntent {
            onSelectGraphNodeWithIntent(nodeID, intent)
            return
        }
        onSelectGraphNode?(nodeID, intent == .toggle)
    }

    private func selectableRegions() -> [OrganizerSelectableRegion] {
        let nodeScale = max(displayConfig.nodeSize, 0.55)
        return simulator.nodes.compactMap { node in
            guard graphLookupIndex.threadByID[node.id] != nil || graphLookupIndex.messageByID[node.id] != nil else {
                return nil
            }
            return OrganizerSelectableRegion(
                nodeID: node.id,
                center: node.position,
                radius: ObsidianGraphSceneNode.effectiveHitRadius(
                    radius: node.radius,
                    nodeScale: nodeScale
                )
            )
        }
    }

    private func showLasso(_ rect: CGRect) {
        lassoNode.path = CGPath(rect: rect, transform: nil)
        lassoNode.fillColor = theme.accentNS.withAlphaComponent(0.08)
        lassoNode.strokeColor = theme.accentNS.withAlphaComponent(0.82)
        lassoNode.isHidden = false
    }

    private func hideLasso() {
        lassoNode.path = nil
        lassoNode.isHidden = true
    }

    /// Releases every gesture-owned simulator pin and visual without
    /// publishing a selection or mutation. Escape and teardown use the same
    /// cancellation path as a superseding pointer gesture.
    internal func cancelDirectManipulation() {
        let hadActiveDrag = !activeDraggedNodeIDs.isEmpty
        let returningNodeOrigins = simulator.lastDragReactiveNodeOrigins
        cancelDropLifecycleIfNeeded()
        pointerStateMachine.cancel()
        if let activeDragPlan {
            simulator.restorePositions(activeDragPlan.initialPositions)
        }
        simulator.cancelDragging()
        pointerAnchorNodeID = nil
        activeDragPlan = nil
        activeDraggedNodeIDs = []
        activeDragRawThreadIDs = []
        dragFrameNeedsRender = false
        isPointerGestureActive = false
        isSecondaryPanning = false
        hideLasso()
        setActiveFolderDropTarget(nil)
        resetDropLifecycle()
        NSCursor.arrow.set()
        if hadActiveDrag {
            if returningNodeOrigins.isEmpty {
                activeDragReactiveNodeIDs = []
                finishDragSettling()
            } else {
                beginLocalSettling(returningNodeOrigins: returningNodeOrigins)
            }
            applyVisualState()
            renderGraph()
            onRenderedOrganizerSnapshot?(renderedOrganizerSnapshot())
        } else {
            let hadLocalSettle = !localReturningNodeOrigins.isEmpty
            simulator.restorePositions(localReturningNodeOrigins)
            activeDragReactiveNodeIDs = []
            localReturningNodeOrigins = [:]
            if hadLocalSettle {
                finishDragSettling()
                renderGraph()
                onRenderedOrganizerSnapshot?(renderedOrganizerSnapshot())
            }
        }
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
        updateAccessibilityGeometry()
        onRenderedOrganizerSnapshot?(renderedOrganizerSnapshot())
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

    private func beginLocalSettling(returningNodeOrigins: [String: CGPoint]) {
        localReturningNodeOrigins = returningNodeOrigins.filter { nodeID, origin in
            simulator.nodesByID[nodeID] != nil && origin.x.isFinite && origin.y.isFinite
        }
        guard !localReturningNodeOrigins.isEmpty else {
            activeDragReactiveNodeIDs = []
            finishDragSettling()
            return
        }
        settlingFrames = 0
        stableFrames = 0
        layoutIsSettled = false
        positionsReportedAfterSettling = false
        publishFrameRatePreferenceIfNeeded()
    }

    /// A manual placement is already a layout decision. Resume the global
    /// solver only for a data/force change, keeping folders and the placement
    /// steady while the small local response settles and is persisted.
    private func finishDragSettling() {
        simulator.stopMotion()
        layoutIsSettled = true
        positionsReportedAfterSettling = false
    }

    private func updateSettlingState() {
        guard activeDraggedNodeIDs.isEmpty else { return }
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
            || !activeDraggedNodeIDs.isEmpty
            || isPointerGestureActive
            || isSecondaryPanning
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
        hitTestNodeID(at: location, excluding: [])
    }

    private func hitTestNodeID(at location: CGPoint,
                               excluding excludedNodeIDs: Set<String>) -> String? {
        let scale = max(displayConfig.nodeSize, 0.55)
        var bestNodeID: String?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for node in simulator.nodes where !excludedNodeIDs.contains(node.id) {
            let radius = ObsidianGraphSceneNode.effectiveHitRadius(radius: node.radius,
                                                                  nodeScale: scale)
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
        batchFolderDropTarget(at: location,
                              draggedGraphNodeIDs: [draggedGraphNodeID])?
            .singleCompatibilityTarget
    }

    internal func batchFolderDropTarget(
        at location: CGPoint,
        draggedGraphNodeIDs: Set<String>
    ) -> GraphBatchFolderDropTarget? {
        batchFolderDropTarget(at: location,
                              rawThreadIDs: rawThreadIDs(forGraphNodeIDs: draggedGraphNodeIDs))
    }

    internal func batchFolderDropTarget(
        at location: CGPoint,
        rawThreadIDs suppliedRawThreadIDs: [String]
    ) -> GraphBatchFolderDropTarget? {
        guard let payload = OrganizerRailDragPayload(rawThreadIDs: suppliedRawThreadIDs) else {
            return nil
        }
        let rawThreadIDs = payload.rawThreadIDs
        let rawThreadIDSet = Set(rawThreadIDs)
        let scale = max(displayConfig.nodeSize, 0.55)
        let zoomAdjustedMagnetRadius = Self.folderDropMagnetRadius * max(cameraNode.xScale, 0.2)

        let groupingsByGraphID = Dictionary(uniqueKeysWithValues: graphData.groupings.map { ($0.id, $0) })
        let candidates = graphData.groupings.compactMap { grouping -> OrganizerConfirmedGroupDropCandidate? in
            guard grouping.kind == .folder,
                  let folderID = grouping.sourceFolderID,
                  Set(grouping.rawThreadIDs).isDisjoint(with: rawThreadIDSet),
                  let folderNode = simulator.nodesByID[grouping.id] else {
                return nil
            }
            let visibleRadius = ObsidianGraphSceneNode.effectiveHitRadius(
                radius: folderNode.radius,
                nodeScale: scale
            )
            let dropRadius = max(visibleRadius, zoomAdjustedMagnetRadius)
            return OrganizerConfirmedGroupDropCandidate(
                groupID: grouping.id,
                center: folderNode.position,
                hitRadius: dropRadius,
                hierarchyDepth: grouping.hierarchyDepth ?? 0,
                visibleArea: .pi * visibleRadius * visibleRadius,
                isConfirmed: !folderID.isEmpty
            )
        }
        guard let resolved = OrganizerDropTargetResolver.resolve(at: location,
                                                                 candidates: candidates),
              let grouping = groupingsByGraphID[resolved.groupID],
              let folderID = grouping.sourceFolderID else {
            return nil
        }
        return GraphBatchFolderDropTarget(graphNodeID: grouping.id,
                                          rawThreadIDs: rawThreadIDs,
                                          folderID: folderID)
    }

    internal func stationaryFolderDropNodeIDs(forDraggedGraphNodeID graphNodeID: String) -> Set<String> {
        stationaryFolderDropNodeIDs(forDraggedGraphNodeIDs: [graphNodeID])
    }

    internal func stationaryFolderDropNodeIDs(
        forDraggedGraphNodeIDs graphNodeIDs: Set<String>
    ) -> Set<String> {
        let rawThreadIDs = Set(rawThreadIDs(forGraphNodeIDs: graphNodeIDs))
        guard !rawThreadIDs.isEmpty else { return [] }
        return Set(graphData.groupings.compactMap { grouping in
            guard grouping.kind == .folder,
                  grouping.sourceFolderID != nil,
                  Set(grouping.rawThreadIDs).isDisjoint(with: rawThreadIDs) else {
                return nil
            }
            return grouping.id
        })
    }

    /// Confirmed folders are spatial anchors and remain stationary while any
    /// other graph node is dragged. This is separate from the drop-target
    /// helper above, which retains its conversation-membership semantics.
    private func stationaryFolderNodeIDs(
        forDraggedGraphNodeIDs graphNodeIDs: Set<String>
    ) -> Set<String> {
        Set(graphData.groupings.compactMap { grouping in
            guard grouping.kind == .folder,
                  grouping.sourceFolderID != nil,
                  !graphNodeIDs.contains(grouping.id) else {
                return nil
            }
            return grouping.id
        })
    }

    @discardableResult
    internal func performFolderDrop(at location: CGPoint,
                                    draggedGraphNodeID: String) -> Bool {
        performBatchFolderDrop(at: location,
                               draggedGraphNodeIDs: [draggedGraphNodeID])
    }

    @discardableResult
    internal func performBatchFolderDrop(at location: CGPoint,
                                         draggedGraphNodeIDs: Set<String>) -> Bool {
        performBatchFolderDrop(
            at: location,
            rawThreadIDs: rawThreadIDs(forGraphNodeIDs: draggedGraphNodeIDs)
        )
    }

    @discardableResult
    internal func performBatchFolderDrop(at location: CGPoint,
                                         rawThreadIDs: [String]) -> Bool {
        guard let target = batchFolderDropTarget(at: location,
                                                 rawThreadIDs: rawThreadIDs) else {
            return false
        }
        return performBatchFolderDrop(target)
    }

    @discardableResult
    private func performBatchFolderDrop(_ target: GraphBatchFolderDropTarget) -> Bool {
        if let onMoveThreadsToFolder {
            onMoveThreadsToFolder(target.rawThreadIDs, target.folderID)
            return true
        }
        guard target.rawThreadIDs.count == 1,
              let rawThreadID = target.rawThreadIDs.first,
              let onMoveThreadToFolder else {
            return false
        }
        onMoveThreadToFolder(rawThreadID, target.folderID)
        return true
    }

    /// Updates the confirmed Group highlight for a process-local rail drag.
    /// Returns whether the current location accepts a drop: either a confirmed
    /// Group, or empty canvas for a batch that can create a new Group.
    internal func updateRailDrag(at viewPoint: CGPoint,
                                 rawThreadIDs: [String]) -> Bool {
        guard let payload = OrganizerRailDragPayload(rawThreadIDs: rawThreadIDs) else {
            cancelDropLifecycleIfNeeded()
            resetDropLifecycle()
            setActiveFolderDropTarget(nil)
            return false
        }
        beginDropLifecycleIfNeeded(itemCount: payload.rawThreadIDs.count)
        markInteraction()
        clearHover()
        let location = convertPoint(fromView: viewPoint)
        let target = batchFolderDropTarget(at: location,
                                           rawThreadIDs: payload.rawThreadIDs)
        if target != nil {
            noteVisibleDropHighlight(itemCount: payload.rawThreadIDs.count)
        }
        setActiveFolderDropTarget(target?.singleCompatibilityTarget)
        return target != nil
            || (payload.rawThreadIDs.count >= 2 && hitTestNodeID(at: location) == nil)
    }

    /// Commits a rail-originated drop through the same callbacks as graph
    /// direct manipulation. A batch on empty canvas opens the accessible Group
    /// composer; no mutation occurs for an invalid single-item empty drop.
    @discardableResult
    internal func performRailDrop(at viewPoint: CGPoint,
                                  rawThreadIDs: [String]) -> Bool {
        defer {
            setActiveFolderDropTarget(nil)
            resetDropLifecycle()
        }
        guard let payload = OrganizerRailDragPayload(rawThreadIDs: rawThreadIDs) else {
            cancelDropLifecycleIfNeeded()
            return false
        }
        beginDropLifecycleIfNeeded(itemCount: payload.rawThreadIDs.count)
        let location = convertPoint(fromView: viewPoint)
        if let target = batchFolderDropTarget(at: location,
                                              rawThreadIDs: payload.rawThreadIDs) {
            noteVisibleDropHighlight(itemCount: payload.rawThreadIDs.count)
            releaseDropLifecycle(destination: .confirmedGroup)
            return performBatchFolderDrop(target)
        }
        guard payload.rawThreadIDs.count >= 2,
              hitTestNodeID(at: location) == nil else {
            releaseDropLifecycle(destination: .invalidTarget)
            return false
        }
        releaseDropLifecycle(destination: .emptyCanvas)
        onCreateGroupAtCanvasPoint?(payload.rawThreadIDs,
                                    overlayPoint(for: location),
                                    location)
        return onCreateGroupAtCanvasPoint != nil
    }

    internal func cancelRailDrag() {
        cancelDropLifecycleIfNeeded()
        resetDropLifecycle()
        setActiveFolderDropTarget(nil)
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
           let grouping = graphLookupIndex.groupingByID[edge.targetID],
           grouping.kind == .folder {
            return .confirmedGroup(grouping.id)
        }
        guard graphLookupIndex.threadByID[edge.threadID] != nil else { return nil }
        return .thread(edge.threadID)
    }

    internal func snipTarget(forGraphNodeID graphNodeID: String) -> GraphSnipTarget? {
        if let grouping = graphLookupIndex.groupingByID[graphNodeID], grouping.kind == .folder {
            return .confirmedGroup(grouping.id)
        }
        return threadID(forGraphNodeID: graphNodeID).map(GraphSnipTarget.thread)
    }

    private func nearestEdgeThreadID(to location: CGPoint) -> String? {
        let tolerance = Self.pruneEdgeHitTolerance * max(cameraNode.xScale, 0.2)
        return graphData.edges.compactMap { edge -> (String, CGFloat)? in
            guard edge.kind != .suggested,
                  graphLookupIndex.threadByID[edge.threadID] != nil,
                  let source = simulator.nodesByID[edge.sourceID],
                  let target = simulator.nodesByID[edge.targetID] else { return nil }
            return (edge.threadID,
                    Self.distanceToSegment(location, source: source.position, target: target.position))
        }
        .filter { $0.1 <= tolerance }
        .min { $0.1 < $1.1 }?.0
    }

    private func threadID(forGraphNodeID graphNodeID: String) -> String? {
        if graphLookupIndex.threadByID[graphNodeID] != nil { return graphNodeID }
        return graphLookupIndex.messageByID[graphNodeID]?.threadID
    }

    private func rawThreadID(forGraphNodeID graphNodeID: String) -> String? {
        if let thread = graphLookupIndex.threadByID[graphNodeID] {
            return thread.rawThreadID
        }
        return graphLookupIndex.messageByID[graphNodeID]?.rawThreadID
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

internal struct GraphBatchFolderDropTarget: Equatable {
    internal let graphNodeID: String
    internal let rawThreadIDs: [String]
    internal let folderID: String

    internal var singleCompatibilityTarget: GraphFolderDropTarget? {
        guard let rawThreadID = rawThreadIDs.first else { return nil }
        return GraphFolderDropTarget(graphNodeID: graphNodeID,
                                     rawThreadID: rawThreadID,
                                     folderID: folderID)
    }
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
