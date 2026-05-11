import AppKit
import SpriteKit

internal final class GraphScene: SKScene {
    internal var onSelectGraphNode: ((String?) -> Void)?
    internal var onHoverItem: ((GraphHoverItem?) -> Void)?
    internal var onWaterThread: ((String) -> Void)?
    internal var onPruneThread: ((String) -> Void)?
    internal var onViewportChanged: ((CGFloat, CGPoint) -> Void)?
    internal var onPositionsChanged: (([String: CGPoint]) -> Void)?

    private var graphData: GraphData = .empty
    private var simulator = GraphForceSimulator()
    private var graphNodesByID: [String: GraphSceneNode] = [:]
    private var summaryCalloutsByID: [String: SummaryCalloutNode] = [:]
    private var summaryAnglesByMessageID: [String: CGFloat] = [:]
    private var forceConfig = GraphForceConstants.defaults
    private let trunkEdgeNode = SKShapeNode()
    private let chainEdgeNode = SKShapeNode()
    private let dimmedTrunkEdgeNode = SKShapeNode()
    private let dimmedChainEdgeNode = SKShapeNode()
    private var theme = DesignTokens.Graph.AppTheme.Palette(isDark: false)
    private var selectedGraphNodeID: String?
    private var hoveredGraphNodeID: String?
    private var pruneMode: GraphPruneMode = .idle
    private var filteredNodeIDs: Set<String> = []
    private var edgeSourceByTargetID: [String: String] = [:]
    private var wateredCounts: [String: Int] = [:]
    private var reduceMotion = false
    private var sproutingMessageIDs: Set<String> = []
    private var lastUpdateTime: TimeInterval?
    private var edgeRenderFrame = 0
    private var draggedNodeID: String?
    private var isPanning = false
    private var lastPositionReportTime: TimeInterval = 0
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
                            zoomScale: CGFloat,
                            panOffset: CGPoint) {
        let shouldRebuild = data != graphData || simulator.size != size || theme != self.theme
        graphData = data
        self.forceConfig = forceConfig
        self.theme = theme
        self.selectedGraphNodeID = selectedGraphNodeID
        self.pruneMode = pruneMode
        self.filteredNodeIDs = filteredNodeIDs
        self.wateredCounts = wateredCounts
        self.reduceMotion = reduceMotion
        self.sproutingMessageIDs = sproutingMessageIDs
        applyTheme()
        applyViewport(zoomScale: zoomScale, panOffset: panOffset)
        if shouldRebuild {
            rebuildGraph()
        }
        applyVisualState()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        cameraNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        rebuildGraph()
    }

    override func update(_ currentTime: TimeInterval) {
        let previous = lastUpdateTime ?? currentTime
        lastUpdateTime = currentTime
        simulator.step(deltaTime: currentTime - previous,
                       elapsedTime: currentTime * 1_000,
                       reduceMotion: reduceMotion,
                       config: forceConfig,
                       labelOccluderRadius: labelOccluderRadius(for:))
        renderFromSimulator(elapsedTime: currentTime * 1_000)
        if currentTime - lastPositionReportTime > 0.2 {
            lastPositionReportTime = currentTime
            onPositionsChanged?(simulator.positionsByID())
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = event.location(in: self)
        if pruneMode != .idle,
           let threadID = nearestEdgeThreadID(to: location) {
            onPruneThread?(threadID)
            return
        }
        if let nodeID = nodeID(at: location) {
            if event.clickCount >= 2,
               let threadID = graphNodesByID[nodeID]?.threadID,
               graphNodesByID[nodeID]?.kind == .thread {
                onWaterThread?(threadID)
                graphNodesByID[nodeID]?.runWaterPulse(wateredCount: wateredCounts[threadID, default: 0] + 1,
                                                       reduceMotion: reduceMotion)
            } else {
                onSelectGraphNode?(nodeID)
                draggedNodeID = nodeID == GraphCenter.you.id ? nil : nodeID
            }
        } else {
            onSelectGraphNode?(nil)
            if event.clickCount >= 2 {
                recenterCamera(animated: true)
                publishViewport()
                return
            }
            isPanning = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = event.location(in: self)
        if let draggedNodeID {
            simulator.setPosition(location, for: draggedNodeID, pinned: true)
            return
        }
        guard isPanning else { return }
        panBy(deltaX: event.deltaX, deltaY: event.deltaY)
        publishViewport()
    }

    override func rightMouseDown(with event: NSEvent) {
        isPanning = true
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isPanning else { return }
        panBy(deltaX: event.deltaX, deltaY: event.deltaY)
        publishViewport()
    }

    override func mouseUp(with event: NSEvent) {
        if let draggedNodeID {
            simulator.setPosition(event.location(in: self), for: draggedNodeID, pinned: false)
        }
        draggedNodeID = nil
        isPanning = false
    }

    override func rightMouseUp(with event: NSEvent) {
        isPanning = false
    }

    override func mouseMoved(with event: NSEvent) {
        let location = event.location(in: self)
        let nextHoveredID = nodeID(at: location)
        if hoveredGraphNodeID != nextHoveredID {
            hoveredGraphNodeID = nextHoveredID
            applyVisualState()
        }
        guard let nextHoveredID else {
            onHoverItem?(nil)
            return
        }
        if let thread = graphData.threadByID[nextHoveredID] {
            onHoverItem?(.thread(thread, location))
        } else if let message = graphData.messageByID[nextHoveredID] {
            onHoverItem?(.message(message, location))
        } else {
            onHoverItem?(nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredGraphNodeID = nil
        onHoverItem?(nil)
        applyVisualState()
    }

    override func scrollWheel(with event: NSEvent) {
        let shouldZoom = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
        guard shouldZoom else {
            panBy(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
                settleCameraIfNeeded()
            }
            publishViewport()
            return
        }
        let delta = event.scrollingDeltaY == 0 ? -event.scrollingDeltaX : event.scrollingDeltaY
        let currentZoom = 1 / cameraNode.xScale
        let nextZoom = currentZoom * exp(delta * -0.005)
        setZoom(nextZoom, around: event.location(in: self))
        publishViewport()
    }

    internal func magnify(by magnification: CGFloat, at viewPoint: CGPoint, in view: SKView) {
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
        configureEdgeLayers()
        addChild(cameraNode)
    }

    private func applyTheme() {
        backgroundColor = theme.backgroundNS
        configureEdgeLayers()
    }

    private func configureEdgeLayers() {
        let layers: [(SKShapeNode, NSColor, CGFloat, CGFloat)] = [
            (trunkEdgeNode, theme.inkTertiaryNS, 1.4, 0.72),
            (chainEdgeNode, theme.inkQuaternaryNS, 1.0, 0.62),
            (dimmedTrunkEdgeNode, theme.inkTertiaryNS, 1.4, 0.22),
            (dimmedChainEdgeNode, theme.inkQuaternaryNS, 1.0, 0.22)
        ]
        for (node, color, width, alpha) in layers {
            node.fillColor = .clear
            node.strokeColor = color.withAlphaComponent(alpha)
            node.lineWidth = width
            node.zPosition = -10
            node.lineCap = .round
            node.lineJoin = .round
            if node.parent == nil {
                addChild(node)
            }
        }
    }

    private func applyViewport(zoomScale: CGFloat, panOffset: CGPoint) {
        let clampedZoom = GraphViewport.clampedZoom(zoomScale)
        cameraNode.setScale(1 / clampedZoom)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraNode.position = constrainedCameraPosition(CGPoint(x: center.x + panOffset.x,
                                                                y: center.y + panOffset.y))
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
        cameraNode.position = constrainedCameraPosition(cameraNode.position)
    }

    private func panBy(deltaX: CGFloat, deltaY: CGFloat) {
        let proposed = CGPoint(x: cameraNode.position.x - deltaX * cameraNode.xScale,
                               y: cameraNode.position.y + deltaY * cameraNode.yScale)
        cameraNode.position = rubberBandedCameraPosition(proposed)
    }

    private func settleCameraIfNeeded() {
        let constrained = constrainedCameraPosition(cameraNode.position)
        guard hypot(constrained.x - cameraNode.position.x, constrained.y - cameraNode.position.y) > 0.5 else { return }
        cameraNode.removeAction(forKey: "graph-camera-settle")
        cameraNode.run(.move(to: constrained, duration: 0.18), withKey: "graph-camera-settle")
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
            .run { [weak self] in self?.publishViewport() }
        ]), withKey: "graph-camera-recenter")
    }

    private func publishViewport() {
        let zoomScale = 1 / cameraNode.xScale
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let pan = CGPoint(x: cameraNode.position.x - center.x,
                          y: cameraNode.position.y - center.y)
        onViewportChanged?(zoomScale, pan)
    }

    private func rebuildGraph() {
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
                                        theme: theme)
        graphNodesByID[graphData.center.id] = centerNode
        addChild(centerNode)
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
                                      theme: theme)
            graphNodesByID[thread.id] = node
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
                                      theme: theme,
                                      labelSide: message.index.isMultiple(of: 2) ? 1 : -1)
            graphNodesByID[message.id] = node
            addChild(node)
            if !message.summaryPreviewText.isEmpty {
                let callout = SummaryCalloutNode(graphID: message.id,
                                                 text: message.summaryPreviewText,
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

    private func renderFromSimulator(elapsedTime: TimeInterval) {
        edgeRenderFrame += 1
        for physicsNode in simulator.nodes {
            guard let node = graphNodesByID[physicsNode.id] else { continue }
            node.position = physicsNode.position
            if physicsNode.kind == .message,
               let sourceID = edgeSourceByTargetID[physicsNode.id],
               let source = simulator.nodesByID[sourceID] {
                let dx = physicsNode.position.x - source.position.x
                let dy = physicsNode.position.y - source.position.y
                node.setBranchAngle(CGFloat(atan2(Double(dy), Double(dx))))
            }
            if let thread = graphData.threadByID[physicsNode.id], thread.isLive {
                node.updateBreath(elapsedTime: elapsedTime,
                                  phase: Double(abs(thread.id.hashValue % 997)) / 997,
                                  reduceMotion: reduceMotion)
            }
        }
        updateSummaryCallouts()
        renderEdges(skipCoalescedChains: edgeRenderFrame % 2 != 0)
    }

    private func updateSummaryCallouts() {
        let occluders = simulator.nodes.map { physicsNode in
            GraphSummaryOccluder(id: physicsNode.id,
                                 position: physicsNode.position,
                                 radius: physicsNode.radius + labelOccluderRadius(for: physicsNode))
        }
        for message in graphData.messages {
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
        }
    }

    private func renderEdges(skipCoalescedChains: Bool = false) {
        let visibleRect = cameraVisibleRect().insetBy(dx: -120, dy: -120)
        let trunkPath = CGMutablePath()
        let chainPath = skipCoalescedChains ? nil : CGMutablePath()
        let dimmedTrunkPath = CGMutablePath()
        let dimmedChainPath = skipCoalescedChains ? nil : CGMutablePath()
        for edge in graphData.edges {
            guard let source = simulator.nodesByID[edge.sourceID],
                  let target = simulator.nodesByID[edge.targetID] else { continue }
            let midpoint = CGPoint(x: (source.position.x + target.position.x) / 2,
                                   y: (source.position.y + target.position.y) / 2)
            guard visibleRect.contains(midpoint) else { continue }
            let isDimmed = isEdgeDimmed(edge)
            let path = edgePath(edge: edge, source: source.position, target: target.position)
            switch (edge.kind, isDimmed) {
            case (.trunk, false):
                trunkPath.addPath(path)
            case (.trunk, true):
                dimmedTrunkPath.addPath(path)
            case (.chain, false):
                chainPath?.addPath(path)
            case (.chain, true):
                dimmedChainPath?.addPath(path)
            }
        }
        trunkEdgeNode.path = trunkPath
        dimmedTrunkEdgeNode.path = dimmedTrunkPath
        if let chainPath {
            chainEdgeNode.path = chainPath
        }
        if let dimmedChainPath {
            dimmedChainEdgeNode.path = dimmedChainPath
        }
    }

    private func applyVisualState() {
        for (id, node) in graphNodesByID {
            if let thread = graphData.threadByID[id] {
                node.setBaseStyle(fillColor: theme.panelNS,
                                  strokeColor: strokeColor(for: thread.importance),
                                  strokeWidth: thread.importance.ringWidth,
                                  theme: theme)
            } else if let message = graphData.messageByID[id] {
                node.setBaseStyle(fillColor: message.unread
                                  ? theme.accentNS
                                  : theme.panelNS,
                                  strokeColor: theme.inkNS.withAlphaComponent(0.9),
                                  strokeWidth: 1.0,
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
        renderEdges()
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

    private func constrainedCameraPosition(_ proposed: CGPoint) -> CGPoint {
        guard let envelope = cameraEnvelope() else { return proposed }
        return CGPoint(x: min(max(proposed.x, envelope.minX), envelope.maxX),
                       y: min(max(proposed.y, envelope.minY), envelope.maxY))
    }

    private func rubberBandedCameraPosition(_ proposed: CGPoint) -> CGPoint {
        let constrained = constrainedCameraPosition(proposed)
        var adjusted = proposed
        if proposed.x != constrained.x {
            adjusted.x = cameraNode.position.x + (proposed.x - cameraNode.position.x) * 0.5
        }
        if proposed.y != constrained.y {
            adjusted.y = cameraNode.position.y + (proposed.y - cameraNode.position.y) * 0.5
        }
        return constrainedCameraPosition(adjusted)
    }

    private func cameraEnvelope() -> CGRect? {
        let contentBounds = graphContentBounds()
        guard !contentBounds.isNull, size.width > 0, size.height > 0 else {
            return nil
        }
        let halfWidth = (size.width * cameraNode.xScale) / 2
        let halfHeight = (size.height * cameraNode.yScale) / 2
        let overscrollX = max(size.width * cameraNode.xScale * 0.55, 220)
        let overscrollY = max(size.height * cameraNode.yScale * 0.55, 180)
        let allowedMinX = contentBounds.minX - halfWidth - overscrollX
        let allowedMaxX = contentBounds.maxX + halfWidth + overscrollX
        let allowedMinY = contentBounds.minY - halfHeight - overscrollY
        let allowedMaxY = contentBounds.maxY + halfHeight + overscrollY
        return CGRect(x: allowedMinX,
                      y: allowedMinY,
                      width: max(0, allowedMaxX - allowedMinX),
                      height: max(0, allowedMaxY - allowedMinY))
    }

    private func graphContentBounds() -> CGRect {
        var bounds = CGRect.null
        for node in simulator.nodes {
            let labelPadding: CGFloat
            switch node.kind {
            case .message:
                labelPadding = 170
            case .thread:
                labelPadding = 130
            case .center:
                labelPadding = 72
            }
            bounds = bounds.union(CGRect(x: node.position.x - node.radius - labelPadding,
                                         y: node.position.y - node.radius - labelPadding,
                                         width: (node.radius + labelPadding) * 2,
                                         height: (node.radius + labelPadding) * 2))
        }
        return bounds
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

    private func edgePath(edge: GraphEdge, source: CGPoint, target: CGPoint) -> CGPath {
        splinePath(from: source,
                   to: target,
                   seed: stableEdgeSeed(edge),
                   config: forceConfig.curlConfig)
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
        graphData.edges
            .compactMap { edge -> (threadID: String, distance: CGFloat)? in
                guard let source = simulator.nodesByID[edge.sourceID],
                      let target = simulator.nodesByID[edge.targetID] else { return nil }
                return (edge.threadID, distanceToSegment(location, source: source.position, target: target.position))
            }
            .filter { $0.distance < 14 }
            .min { $0.distance < $1.distance }?.threadID
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

    private func labelOccluderRadius(for node: GraphPhysicsNode) -> CGFloat {
        switch node.kind {
        case .message:
            return summaryCalloutsByID[node.id] == nil ? 0 : 60
        case .thread:
            return 34
        case .center:
            return 0
        }
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
