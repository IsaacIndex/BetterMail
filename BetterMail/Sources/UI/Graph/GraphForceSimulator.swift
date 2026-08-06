import CoreGraphics
import Foundation

internal enum GraphDirection {
    case up
    case down
    case left
    case right
}

internal struct GraphPhysicsNode: Identifiable, Hashable {
    internal let id: String
    internal let kind: GraphNodeKind
    internal let threadID: String?
    internal let branchID: String?
    internal var position: CGPoint
    internal var velocity: CGVector
    internal var radius: CGFloat
    internal var isPinned: Bool
    internal var restingPosition: CGPoint = .zero
}

internal struct GraphCurlConfig: Equatable {
    internal let curl: CGFloat
    internal let curlVariability: CGFloat
    internal let splineTension: CGFloat
    internal let curlFalloff: CGFloat
    internal let asymmetricArc: Bool

    internal init(curl: CGFloat,
                  curlVariability: CGFloat,
                  splineTension: CGFloat,
                  curlFalloff: CGFloat,
                  asymmetricArc: Bool = false) {
        self.curl = curl
        self.curlVariability = curlVariability
        self.splineTension = splineTension
        self.curlFalloff = curlFalloff
        self.asymmetricArc = asymmetricArc
    }
}

internal struct GraphBranchConfig: Equatable {
    internal let trunkWidth: CGFloat
    internal let chainWidth: CGFloat
    internal let taper: CGFloat
    internal let tipMin: CGFloat
    internal let taperPow: CGFloat
    internal let jointRadiusTrunk: CGFloat
    internal let jointRadiusChain: CGFloat
    internal let asymmetricArc: Bool
    internal let outwardArcAnchorEnabled: Bool
    internal let ribbonSamples: Int

    internal static let organicLimb = GraphBranchConfig(trunkWidth: 2.6,
                                                        chainWidth: 1.6,
                                                        taper: 0.6,
                                                        tipMin: 0.5,
                                                        taperPow: 1.8,
                                                        jointRadiusTrunk: 1.8,
                                                        jointRadiusChain: 1.4,
                                                        asymmetricArc: true,
                                                        outwardArcAnchorEnabled: true,
                                                        ribbonSamples: 36)

    internal func baseWidth(for edgeKind: GraphEdgeKind) -> CGFloat {
        switch edgeKind {
        case .trunk, .grouping, .remaining:
            return trunkWidth
        case .suggested, .chain:
            return chainWidth
        }
    }

    internal func tipWidth(for edgeKind: GraphEdgeKind) -> CGFloat {
        max(tipMin, baseWidth(for: edgeKind) * taper)
    }

    internal func jointRadius(for edgeKind: GraphEdgeKind) -> CGFloat {
        switch edgeKind {
        case .trunk, .grouping, .remaining:
            return jointRadiusTrunk
        case .suggested, .chain:
            return jointRadiusChain
        }
    }
}

internal struct GraphForceConfig: Equatable {
    internal let center: CGFloat
    internal let repel: CGFloat
    internal let repelCutoff: CGFloat
    internal let linkSpring: CGFloat
    internal let trunkLength: CGFloat
    internal let chainLength: CGFloat
    internal let damping: CGFloat
    internal let breezeAmplitude: CGFloat
    internal let curl: CGFloat
    internal let curlVariability: CGFloat
    internal let splineTension: CGFloat
    internal let curlFalloff: CGFloat
    internal let labelRepelOn: Bool
    internal let labelRepelStrength: CGFloat

    internal var repelCutoffSquared: CGFloat {
        repelCutoff * repelCutoff
    }

    internal var curlConfig: GraphCurlConfig {
        GraphCurlConfig(curl: curl,
                        curlVariability: curlVariability,
                        splineTension: splineTension,
                        curlFalloff: curlFalloff)
    }

    internal var branchConfig: GraphBranchConfig {
        .organicLimb
    }

    internal var branchCurlConfig: GraphCurlConfig {
        GraphCurlConfig(curl: curl,
                        curlVariability: curlVariability,
                        splineTension: splineTension,
                        curlFalloff: curlFalloff,
                        asymmetricArc: branchConfig.asymmetricArc)
    }
}

internal enum GraphForceConstants {
    internal static let legacySpringDefaults = GraphForceConfig(center: 0.006,
                                                                repel: 4_200,
                                                                repelCutoff: 360,
                                                                linkSpring: 0.045,
                                                                trunkLength: 210,
                                                                chainLength: 104,
                                                                damping: 0.86,
                                                                breezeAmplitude: 0.7,
                                                                curl: 3,
                                                                curlVariability: 0.2,
                                                                splineTension: 0.35,
                                                                curlFalloff: 0.45,
                                                                labelRepelOn: true,
                                                                labelRepelStrength: 0.12)

    internal static let defaults = GraphForceConfig(center: 0.008,
                                                    repel: 4_800,
                                                    repelCutoff: 440,
                                                    linkSpring: 0.028,
                                                    trunkLength: 210,
                                                    chainLength: 104,
                                                    damping: 0.78,
                                                    breezeAmplitude: 0.18,
                                                    curl: 3,
                                                    curlVariability: 0.2,
                                                    splineTension: 0.35,
                                                    curlFalloff: 0.45,
                                                    labelRepelOn: true,
                                                    labelRepelStrength: 0.18)
}

internal typealias GraphLabelOccluderProvider = (GraphPhysicsNode) -> CGRect?

internal enum GraphSimulationScope {
    case global
    case dragging(activeNodeID: String,
                  branchNodeIDs: Set<String>,
                  obstacleOrigins: [String: CGPoint])
    case localSettling(branchNodeIDs: Set<String>,
                       returningNodeOrigins: [String: CGPoint])

    internal var isGlobal: Bool {
        if case .global = self { return true }
        return false
    }
}

private struct GraphRadialLayoutTargets {
    let threadByID: [String: CGPoint]
    let groupingByID: [String: CGPoint]
    let branchByNodeID: [String: String]
    let remaining: CGPoint?
}

private struct GraphRadialBranch {
    let id: String
    let threadIDs: [String]
    let groupingID: String?
    let isRemaining: Bool
    let lastUpdated: Date
}

internal struct GraphForceSimulator {
    private static let messageLeafBaseOffset: CGFloat = 128
    private static let messageLeafSpacing: CGFloat = 88
    private static let messageFanStep: CGFloat = 0.12
    private static let messageFanMax: CGFloat = 0.78
    private static let branchSpacingStep: CGFloat = 170
    private static let treeLaneStrength: CGFloat = 0.018
    private static let treeDepthStrength: CGFloat = 0.008
    private static let crossBranchRepelMultiplier: CGFloat = 1.65
    private static let dragObstacleMaximumDisplacementPerStep: CGFloat = 1.25
    private static let dragObstacleMaximumTotalDisplacement: CGFloat = 9
    private static let dragObstacleReturnRate: CGFloat = 0.22
    private static let dragCollisionInfluence: CGFloat = 18
    internal private(set) var nodesByID: [String: GraphPhysicsNode] = [:]
    internal private(set) var edges: [GraphEdge] = []
    internal private(set) var size: CGSize = .zero
    internal private(set) var lastDragReactiveNodeIDs: Set<String> = []
    internal private(set) var lastDragCollisionCheckCount = 0

    internal var nodes: [GraphPhysicsNode] {
        nodesByID.values.sorted { $0.id < $1.id }
    }

    internal mutating func reset(data: GraphData,
                                 size: CGSize,
                                 preserving existingPositions: [String: CGPoint] = [:]) {
        let priorNodesByID = nodesByID
        let priorCenter = nodesByID[data.center.id]?.position ?? Self.rootAnchor(in: self.size)
        self.size = size
        edges = data.edges
        let center = Self.rootAnchor(in: size)
        let preservedOffset = CGVector(dx: center.x - priorCenter.x,
                                       dy: center.y - priorCenter.y)
        let preservedPosition: (String) -> CGPoint? = { id in
            existingPositions[id].map {
                CGPoint(x: $0.x + preservedOffset.dx,
                        y: $0.y + preservedOffset.dy)
            }
        }
        let preservedRestingPosition: (String) -> CGPoint? = { id in
            priorNodesByID[id].map {
                CGPoint(x: $0.restingPosition.x + preservedOffset.dx,
                        y: $0.restingPosition.y + preservedOffset.dy)
            }
        }
        let radialTargets = Self.radialLayoutTargets(data: data, center: center, size: size)
        var nextNodes: [String: GraphPhysicsNode] = [
            data.center.id: GraphPhysicsNode(id: data.center.id,
                                             kind: .center,
                                             threadID: nil,
                                             branchID: nil,
                                             position: center,
                                             velocity: .zero,
                                             radius: 38,
                                             isPinned: true,
                                             restingPosition: center)
        ]

        for (index, grouping) in data.groupings.enumerated() {
            let memberTargets = grouping.threadIDs.compactMap { radialTargets.threadByID[$0] }
            let averageTarget = memberTargets.isEmpty
                ? center
                : CGPoint(
                    x: memberTargets.reduce(0) { $0 + $1.x } / CGFloat(memberTargets.count),
                    y: memberTargets.reduce(0) { $0 + $1.y } / CGFloat(memberTargets.count)
                )
            let toCenterVector = Self.outwardUnitVector(from: center, through: averageTarget)
            let perpendicular = CGPoint(x: -toCenterVector.y, y: toCenterVector.x)
            let ghostOffset: CGFloat = grouping.isSuggestion
                ? (index.isMultiple(of: 2) ? -34 : 34)
                : 0
            let fallbackTarget = CGPoint(x: averageTarget.x + perpendicular.x * ghostOffset,
                                         y: averageTarget.y + perpendicular.y * ghostOffset)
            let target = radialTargets.groupingByID[grouping.id] ?? fallbackTarget
            nextNodes[grouping.id] = GraphPhysicsNode(id: grouping.id,
                                                      kind: grouping.nodeKind,
                                                      threadID: nil,
                                                      branchID: radialTargets.branchByNodeID[grouping.id] ?? grouping.id,
                                                      position: preservedPosition(grouping.id) ?? target,
                                                      velocity: .zero,
                                                      radius: grouping.radius,
                                                      isPinned: false,
                                                      restingPosition: preservedRestingPosition(grouping.id) ?? target)
        }

        for (threadIndex, thread) in data.threads.enumerated() {
            let threadTarget = radialTargets.threadByID[thread.id] ??
                               CGPoint(x: center.x + CGFloat(threadIndex) * 170, y: center.y + 258)
            let defaultPosition = threadTarget
            nextNodes[thread.id] = GraphPhysicsNode(id: thread.id,
                                                     kind: .thread,
                                                     threadID: thread.id,
                                                     branchID: radialTargets.branchByNodeID[thread.id] ?? thread.id,
                                                     position: preservedPosition(thread.id) ?? defaultPosition,
                                                     velocity: .zero,
                                                     radius: thread.radius,
                                                     isPinned: false,
                                                     restingPosition: preservedRestingPosition(thread.id) ?? defaultPosition)
            let messages = data.messages.filter { $0.threadID == thread.id }.sorted { $0.index < $1.index }
            let branchVector = Self.outwardUnitVector(from: center, through: threadTarget)
            let branchAngle = atan2(branchVector.y, branchVector.x)
            for message in messages {
                let branchOffset = Self.messageOffset(for: message.index)
                let fanAngle = Self.messageFanAngle(for: message.index)
                let messageAngle = branchAngle + fanAngle
                let messageVector = CGPoint(x: cos(messageAngle), y: sin(messageAngle))
                let target = CGPoint(x: threadTarget.x + messageVector.x * branchOffset,
                                     y: threadTarget.y + messageVector.y * branchOffset)
                nextNodes[message.id] = GraphPhysicsNode(id: message.id,
                                                         kind: .message,
                                                         threadID: thread.id,
                                                         branchID: radialTargets.branchByNodeID[thread.id] ?? thread.id,
                                                         position: preservedPosition(message.id) ?? target,
                                                         velocity: .zero,
                                                         radius: message.radius,
                                                         isPinned: false,
                                                         restingPosition: preservedRestingPosition(message.id) ?? target)
            }
        }
        if let remainingBranch = data.remainingBranch {
            let fallbackRadius = Self.threadRingRadius(branchCount: data.threads.count + 1, size: size)
            let defaultPosition = radialTargets.remaining ??
                                  CGPoint(x: center.x + fallbackRadius, y: center.y)
            nextNodes[remainingBranch.id] = GraphPhysicsNode(id: remainingBranch.id,
                                                             kind: .remaining,
                                                             threadID: nil,
                                                             branchID: remainingBranch.id,
                                                             position: preservedPosition(remainingBranch.id) ?? defaultPosition,
                                                             velocity: .zero,
                                                             radius: remainingBranch.radius,
                                                             isPinned: false,
                                                             restingPosition: preservedRestingPosition(remainingBranch.id) ?? defaultPosition)
        }

        nodesByID = nextNodes
        lastDragReactiveNodeIDs = []
        lastDragCollisionCheckCount = 0
    }

    internal mutating func setPosition(_ position: CGPoint, for nodeID: String, pinned: Bool? = nil) {
        guard var node = nodesByID[nodeID] else { return }
        node.position = position
        node.velocity = .zero
        if let pinned {
            node.isPinned = pinned
        }
        nodesByID[nodeID] = node
    }

    internal mutating func releaseNode(at position: CGPoint, for nodeID: String) {
        guard var node = nodesByID[nodeID] else { return }
        node.position = position
        node.velocity = .zero
        node.isPinned = false
        node.restingPosition = position
        nodesByID[nodeID] = node
    }

    internal func restingPositionsByID() -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: nodesByID.map { ($0.key, $0.value.restingPosition) })
    }

    internal func directNeighborIDs(of nodeID: String) -> Set<String> {
        Set(edges.compactMap { edge in
            if edge.sourceID == nodeID { return edge.targetID }
            if edge.targetID == nodeID { return edge.sourceID }
            return nil
        })
    }

    internal func descendantNodeIDs(from nodeID: String) -> Set<String> {
        var descendants: Set<String> = [nodeID]
        var pending = [nodeID]
        let targetsBySource = Dictionary(grouping: edges, by: \.sourceID)
        while let sourceID = pending.popLast() {
            for edge in targetsBySource[sourceID, default: []] where descendants.insert(edge.targetID).inserted {
                pending.append(edge.targetID)
            }
        }
        return descendants
    }

    internal mutating func stopMotion(for nodeIDs: Set<String>? = nil) {
        for id in nodesByID.keys where nodeIDs == nil || nodeIDs?.contains(id) == true {
            guard var node = nodesByID[id] else { continue }
            node.velocity = .zero
            nodesByID[id] = node
        }
    }

    @discardableResult
    internal mutating func previewDrag(nodeID: String,
                                       from startPosition: CGPoint,
                                       to pointerPosition: CGPoint,
                                       initialPositions: [String: CGPoint]) -> Set<String> {
        guard let draggedNode = nodesByID[nodeID],
              draggedNode.kind != .center,
              draggedNode.kind != .remaining else {
            setPosition(pointerPosition, for: nodeID, pinned: true)
            return [nodeID]
        }
        let branchNodeIDs = descendantNodeIDs(from: nodeID)
        let delta = CGVector(dx: pointerPosition.x - startPosition.x,
                             dy: pointerPosition.y - startPosition.y)
        transformNodePositions(branchNodeIDs, initialPositions: initialPositions) { point in
            CGPoint(x: point.x + delta.dx, y: point.y + delta.dy)
        }
        if var node = nodesByID[nodeID] {
            node.isPinned = true
            node.velocity = .zero
            nodesByID[nodeID] = node
        }
        return branchNodeIDs
    }

    internal mutating func restoreSnapshot(positions: [String: CGPoint],
                                           restingPositions: [String: CGPoint]) {
        for id in nodesByID.keys {
            guard var node = nodesByID[id] else { continue }
            node.position = positions[id] ?? node.position
            node.restingPosition = restingPositions[id] ?? node.restingPosition
            node.velocity = .zero
            node.isPinned = node.kind == .center
            nodesByID[id] = node
        }
        lastDragReactiveNodeIDs = []
        lastDragCollisionCheckCount = 0
    }

    internal mutating func finishLocalSettling(returningNodeOrigins: [String: CGPoint]) {
        for (id, origin) in returningNodeOrigins {
            guard var node = nodesByID[id] else { continue }
            node.position = origin
            node.velocity = .zero
            nodesByID[id] = node
        }
    }

    @discardableResult
    internal mutating func commitDrag(nodeID: String,
                                      from startPosition: CGPoint,
                                      to releasePosition: CGPoint,
                                      initialPositions: [String: CGPoint],
                                      initialRestingPositions: [String: CGPoint]) -> Set<String> {
        guard let draggedNode = nodesByID[nodeID],
              draggedNode.kind != .center,
              draggedNode.kind != .remaining else {
            releaseNode(at: releasePosition, for: nodeID)
            return []
        }
        let movableNodeIDs = descendantNodeIDs(from: nodeID)
        let delta = CGVector(dx: releasePosition.x - startPosition.x,
                             dy: releasePosition.y - startPosition.y)
        transformNodes(movableNodeIDs,
                       initialPositions: initialPositions,
                       initialRestingPositions: initialRestingPositions) { point in
            CGPoint(x: point.x + delta.dx, y: point.y + delta.dy)
        }
        for id in nodesByID.keys where !movableNodeIDs.contains(id) {
            guard var node = nodesByID[id] else { continue }
            node.restingPosition = initialRestingPositions[id] ?? node.restingPosition
            node.velocity = .zero
            node.isPinned = node.kind == .center
            nodesByID[id] = node
        }
        if var node = nodesByID[nodeID] {
            node.isPinned = false
            node.velocity = .zero
            nodesByID[nodeID] = node
        }
        lastDragReactiveNodeIDs = []
        return movableNodeIDs
    }

    internal mutating func step(deltaTime rawDeltaTime: TimeInterval,
                                elapsedTime: TimeInterval,
                                reduceMotion: Bool = false,
                                config: GraphForceConfig = GraphForceConstants.defaults,
                                labelOccluderFrame: GraphLabelOccluderProvider? = nil,
                                scope: GraphSimulationScope = .global) {
        guard size.width > 0, size.height > 0 else { return }
        let dt = CGFloat(min(max(rawDeltaTime, 0), 0.032) / 0.016)
        let center = Self.rootAnchor(in: size)
        if var centerNode = nodesByID[GraphCenter.you.id] {
            centerNode.position = center
            centerNode.velocity = .zero
            nodesByID[GraphCenter.you.id] = centerNode
        }

        switch scope {
        case .global:
            break
        case let .dragging(activeNodeID, branchNodeIDs, obstacleOrigins):
            stepDrag(activeNodeID: activeNodeID,
                     branchNodeIDs: branchNodeIDs,
                     obstacleOrigins: obstacleOrigins,
                     labelOccluder: labelOccluderFrame,
                     deltaTime: dt,
                     config: config)
            return
        case let .localSettling(branchNodeIDs, returningNodeOrigins):
            stepLocalSettling(branchNodeIDs: branchNodeIDs,
                              returningNodeOrigins: returningNodeOrigins)
            return
        }

        var forces = Dictionary(uniqueKeysWithValues: nodesByID.keys.map { ($0, CGVector.zero) })
        applyEdgeForces(into: &forces, config: config)
        applyRepulsionForces(into: &forces,
                             config: config,
                             labelOccluderFrame: labelOccluderFrame)
        applyTreeLaneForces(into: &forces, center: center)
        applyCenterPullAndBreeze(into: &forces,
                                 center: center,
                                 elapsedTime: elapsedTime,
                                 reduceMotion: reduceMotion,
                                 config: config,
                                 allowsBreeze: true)
        integrate(forces: forces,
                  deltaTime: dt,
                  damping: config.damping)
    }

    internal func nearestNodeID(from originID: String, direction: GraphDirection) -> String? {
        guard let origin = nodesByID[originID] else { return nil }
        let candidates = nodesByID.values.filter { candidate in
            candidate.id != originID && candidate.kind != .center && isCandidate(candidate.position,
                                                                                from: origin.position,
                                                                                direction: direction)
        }
        return candidates.min { lhs, rhs in
            directionalScore(lhs.position, from: origin.position, direction: direction) <
            directionalScore(rhs.position, from: origin.position, direction: direction)
        }?.id
    }

    internal func totalEnergy() -> CGFloat {
        nodesByID.values.reduce(0) { partial, node in
            partial + node.velocity.dx * node.velocity.dx + node.velocity.dy * node.velocity.dy
        }
    }

    internal func totalEnergy(for nodeIDs: Set<String>) -> CGFloat {
        nodeIDs.reduce(0) { partial, nodeID in
            guard let node = nodesByID[nodeID] else { return partial }
            return partial + node.velocity.dx * node.velocity.dx + node.velocity.dy * node.velocity.dy
        }
    }

    internal func positionsByID() -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: nodesByID.map { ($0.key, $0.value.position) })
    }

    private mutating func applyEdgeForces(into forces: inout [String: CGVector],
                                          config: GraphForceConfig,
                                          movableNodeIDs: Set<String>? = nil) {
        for edge in edges {
            guard let source = nodesByID[edge.sourceID],
                  let target = nodesByID[edge.targetID] else { continue }
            if let movableNodeIDs,
               !movableNodeIDs.contains(source.id),
               !movableNodeIDs.contains(target.id) {
                continue
            }
            let dx = target.position.x - source.position.x
            let dy = target.position.y - source.position.y
            let distance = max(1, hypot(dx, dy))
            let usesTrunkPhysics = edge.kind == .trunk || edge.kind == .grouping || edge.kind == .remaining
            let springMultiplier: CGFloat
            let targetLength: CGFloat
            if edge.kind == .suggested {
                springMultiplier = 0.22
                targetLength = config.trunkLength * 0.72
            } else {
                springMultiplier = usesTrunkPhysics ? 1.0 : 1.2
                targetLength = usesTrunkPhysics ? config.trunkLength : config.chainLength
            }
            let springK = config.linkSpring * springMultiplier
            let force = (distance - targetLength) * springK
            let fx = dx / distance * force
            let fy = dy / distance * force
            if !source.isPinned && (movableNodeIDs == nil || movableNodeIDs?.contains(source.id) == true) {
                forces[source.id, default: .zero].dx += fx
                forces[source.id, default: .zero].dy += fy
            }
            if !target.isPinned && (movableNodeIDs == nil || movableNodeIDs?.contains(target.id) == true) {
                forces[target.id, default: .zero].dx -= fx
                forces[target.id, default: .zero].dy -= fy
            }
        }
    }

    private func applyRepulsionForces(into forces: inout [String: CGVector],
                                      config: GraphForceConfig,
                                      labelOccluderFrame: GraphLabelOccluderProvider?,
                                      movableNodeIDs: Set<String>? = nil) {
        let nodeValues = nodesByID.values.sorted { $0.id < $1.id }
        guard nodeValues.count > 1 else { return }
        for leftIndex in 0..<(nodeValues.count - 1) {
            for rightIndex in (leftIndex + 1)..<nodeValues.count {
                let left = nodeValues[leftIndex]
                let right = nodeValues[rightIndex]
                if let movableNodeIDs,
                   !movableNodeIDs.contains(left.id),
                   !movableNodeIDs.contains(right.id) {
                    continue
                }
                let dx = right.position.x - left.position.x
                let dy = right.position.y - left.position.y
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared < config.repelCutoffSquared else { continue }
                let distance = max(1, sqrt(distanceSquared))
                let preferredDistance = left.radius + right.radius +
                    (left.kind == .message || right.kind == .message ? 104 : 82)
                let overlapForce = max(0, preferredDistance - distance) * 0.035
                let isCrossBranch = left.branchID != nil &&
                    right.branchID != nil &&
                    left.branchID != right.branchID
                let branchMultiplier = isCrossBranch ? Self.crossBranchRepelMultiplier : 1
                var response = CGVector(
                    dx: dx / distance * (config.repel / (distanceSquared + 160) + overlapForce) * branchMultiplier,
                    dy: dy / distance * (config.repel / (distanceSquared + 160) + overlapForce) * branchMultiplier
                )
                if config.labelRepelOn,
                   let labelResponse = collisionCorrection(from: left,
                                                           to: right,
                                                           labelOccluder: labelOccluderFrame,
                                                           influence: 8) {
                    response.dx += labelResponse.dx * config.labelRepelStrength * branchMultiplier
                    response.dy += labelResponse.dy * config.labelRepelStrength * branchMultiplier
                }
                if !left.isPinned && (movableNodeIDs == nil || movableNodeIDs?.contains(left.id) == true) {
                    forces[left.id, default: .zero].dx -= response.dx
                    forces[left.id, default: .zero].dy -= response.dy
                }
                if !right.isPinned && (movableNodeIDs == nil || movableNodeIDs?.contains(right.id) == true) {
                    forces[right.id, default: .zero].dx += response.dx
                    forces[right.id, default: .zero].dy += response.dy
                }
            }
        }
    }

    private func applyTreeLaneForces(into forces: inout [String: CGVector],
                                     center: CGPoint,
                                     movableNodeIDs: Set<String>? = nil) {
        for node in nodesByID.values where !node.isPinned &&
            node.restingPosition != .zero &&
            (movableNodeIDs == nil || movableNodeIDs?.contains(node.id) == true) {
            let targetVector = CGVector(dx: node.restingPosition.x - center.x,
                                        dy: node.restingPosition.y - center.y)
            let targetDistance = max(1, hypot(targetVector.dx, targetVector.dy))
            let direction = CGVector(dx: targetVector.dx / targetDistance,
                                     dy: targetVector.dy / targetDistance)
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            let currentVector = CGVector(dx: node.position.x - center.x,
                                         dy: node.position.y - center.y)
            let lateralDisplacement = currentVector.dx * normal.dx + currentVector.dy * normal.dy
            let currentDepth = currentVector.dx * direction.dx + currentVector.dy * direction.dy
            let depthError = targetDistance - currentDepth

            forces[node.id, default: .zero].dx +=
                -normal.dx * lateralDisplacement * Self.treeLaneStrength +
                direction.dx * depthError * Self.treeDepthStrength
            forces[node.id, default: .zero].dy +=
                -normal.dy * lateralDisplacement * Self.treeLaneStrength +
                direction.dy * depthError * Self.treeDepthStrength
        }
    }

    private func applyCenterPullAndBreeze(into forces: inout [String: CGVector],
                                          center: CGPoint,
                                          elapsedTime: TimeInterval,
                                          reduceMotion: Bool,
                                          config: GraphForceConfig,
                                          movableNodeIDs: Set<String>? = nil,
                                          allowsBreeze: Bool = true) {
        let breezeX = reduceMotion || !allowsBreeze
            ? 0
            : CGFloat(sin(elapsedTime * 0.0006)) * config.breezeAmplitude * 0.085
        let breezeY = reduceMotion || !allowsBreeze
            ? 0
            : CGFloat(cos(elapsedTime * 0.0009)) * config.breezeAmplitude * 0.057
        for node in nodesByID.values where !node.isPinned &&
            (movableNodeIDs == nil || movableNodeIDs?.contains(node.id) == true) {
            let target = node.restingPosition == .zero ? center : node.restingPosition
            let dx = target.x - node.position.x
            let dy = target.y - node.position.y
            let anchorWeight: CGFloat
            switch node.kind {
            case .folderGroup, .ghostGroup, .remaining:
                anchorWeight = 1.1
            case .thread:
                anchorWeight = 0.85
            case .message:
                anchorWeight = 0.55
            case .center:
                anchorWeight = 0
            }
            let breezeWeight: CGFloat = node.kind == .message ? 1.2 : 0.4
            forces[node.id, default: .zero].dx += dx * config.center * anchorWeight + breezeX * breezeWeight
            forces[node.id, default: .zero].dy += dy * config.center * anchorWeight + breezeY * breezeWeight
        }
    }

    private mutating func stepDrag(activeNodeID: String,
                                   branchNodeIDs: Set<String>,
                                   obstacleOrigins: [String: CGPoint],
                                   labelOccluder: GraphLabelOccluderProvider?,
                                   deltaTime: CGFloat,
                                   config: GraphForceConfig) {
        guard nodesByID[activeNodeID] != nil else { return }
        lastDragCollisionCheckCount = 0
        let effectiveBranchNodeIDs = branchNodeIDs.union([activeNodeID])
        let branchEnvelope = effectiveBranchNodeIDs.compactMap { nodesByID[$0] }
            .reduce(CGRect.null) { bounds, node in
                bounds.union(CGRect(x: node.position.x - node.radius,
                                    y: node.position.y - node.radius,
                                    width: node.radius * 2,
                                    height: node.radius * 2))
            }
            .insetBy(dx: -Self.dragCollisionInfluence,
                     dy: -Self.dragCollisionInfluence)
        let obstacleNodeIDs = Set(nodesByID.keys)
            .subtracting(effectiveBranchNodeIDs)
            .filter {
                guard let node = nodesByID[$0], node.kind != .center else { return false }
                let frame = CGRect(x: node.position.x - node.radius,
                                   y: node.position.y - node.radius,
                                   width: node.radius * 2,
                                   height: node.radius * 2)
                return branchEnvelope.intersects(frame)
            }
        var nextReactiveNodeIDs: Set<String> = []

        for obstacleID in obstacleNodeIDs {
            guard var obstacle = nodesByID[obstacleID],
                  let origin = obstacleOrigins[obstacleID] else { continue }
            var response = CGVector.zero
            for branchNodeID in effectiveBranchNodeIDs {
                lastDragCollisionCheckCount += 1
                guard let branchNode = nodesByID[branchNodeID],
                      let correction = collisionCorrection(from: branchNode,
                                                           to: obstacle,
                                                           labelOccluder: labelOccluder,
                                                           influence: Self.dragCollisionInfluence) else { continue }
                response.dx += correction.dx
                response.dy += correction.dy
            }

            var displacement: CGVector
            if hypot(response.dx, response.dy) > 0.001 {
                displacement = limited(response,
                                       maximum: Self.dragObstacleMaximumDisplacementPerStep * deltaTime)
                nextReactiveNodeIDs.insert(obstacleID)
            } else {
                displacement = limited(CGVector(dx: (origin.x - obstacle.position.x) * Self.dragObstacleReturnRate,
                                                dy: (origin.y - obstacle.position.y) * Self.dragObstacleReturnRate),
                                       maximum: 0.7 * deltaTime)
            }

            var proposed = CGPoint(x: obstacle.position.x + displacement.dx,
                                   y: obstacle.position.y + displacement.dy)
            let fromOrigin = CGVector(dx: proposed.x - origin.x, dy: proposed.y - origin.y)
            let boundedFromOrigin = limited(fromOrigin,
                                            maximum: Self.dragObstacleMaximumTotalDisplacement)
            proposed = CGPoint(x: origin.x + boundedFromOrigin.dx,
                               y: origin.y + boundedFromOrigin.dy)
            let applied = CGVector(dx: proposed.x - obstacle.position.x,
                                   dy: proposed.y - obstacle.position.y)
            obstacle.position = proposed
            obstacle.velocity = applied
            nodesByID[obstacleID] = obstacle
            if hypot(applied.dx, applied.dy) > 0.01 {
                nextReactiveNodeIDs.insert(obstacleID)
            }
        }

        for branchNodeID in effectiveBranchNodeIDs {
            guard var node = nodesByID[branchNodeID] else { continue }
            node.velocity = .zero
            node.isPinned = branchNodeID == activeNodeID
            nodesByID[branchNodeID] = node
        }
        lastDragReactiveNodeIDs.formUnion(nextReactiveNodeIDs)
    }

    private mutating func stepLocalSettling(branchNodeIDs: Set<String>,
                                            returningNodeOrigins: [String: CGPoint]) {
        for branchNodeID in branchNodeIDs {
            guard var node = nodesByID[branchNodeID] else { continue }
            node.velocity = .zero
            node.restingPosition = node.position
            node.isPinned = false
            nodesByID[branchNodeID] = node
        }

        for (nodeID, origin) in returningNodeOrigins {
            guard !branchNodeIDs.contains(nodeID), var node = nodesByID[nodeID] else { continue }
            let displacement = limited(CGVector(dx: (origin.x - node.position.x) * Self.dragObstacleReturnRate,
                                                dy: (origin.y - node.position.y) * Self.dragObstacleReturnRate),
                                       maximum: 0.8)
            node.position.x += displacement.dx
            node.position.y += displacement.dy
            node.velocity = displacement
            nodesByID[nodeID] = node
        }
    }

    private mutating func integrate(forces: [String: CGVector],
                                    deltaTime: CGFloat,
                                    damping: CGFloat,
                                    movableNodeIDs: Set<String>? = nil,
                                    maximumDisplacement: CGFloat? = nil) {
        for id in nodesByID.keys {
            guard var node = nodesByID[id] else { continue }
            if node.isPinned {
                node.position = id == GraphCenter.you.id ? Self.rootAnchor(in: size) : node.position
                node.velocity = .zero
                nodesByID[id] = node
                continue
            }
            if let movableNodeIDs, !movableNodeIDs.contains(id) {
                node.velocity = .zero
                nodesByID[id] = node
                continue
            }
            let force = forces[id] ?? .zero
            node.velocity.dx = (node.velocity.dx + force.dx * deltaTime) * damping
            node.velocity.dy = (node.velocity.dy + force.dy * deltaTime) * damping
            if abs(node.velocity.dx) < 0.05 { node.velocity.dx = 0 }
            if abs(node.velocity.dy) < 0.05 { node.velocity.dy = 0 }
            var displacement = CGVector(dx: node.velocity.dx * deltaTime,
                                        dy: node.velocity.dy * deltaTime)
            if let maximumDisplacement {
                let magnitude = hypot(displacement.dx, displacement.dy)
                if magnitude > maximumDisplacement {
                    let scale = maximumDisplacement / magnitude
                    displacement.dx *= scale
                    displacement.dy *= scale
                    node.velocity.dx = displacement.dx / max(deltaTime, 0.001)
                    node.velocity.dy = displacement.dy / max(deltaTime, 0.001)
                }
            }
            node.position.x += displacement.dx
            node.position.y += displacement.dy
            nodesByID[id] = node
        }
    }

    private func collisionCorrection(from source: GraphPhysicsNode,
                                     to target: GraphPhysicsNode,
                                     labelOccluder: GraphLabelOccluderProvider?,
                                     influence: CGFloat) -> CGVector? {
        let sourceFrames = collisionFrames(for: source, labelOccluder: labelOccluder)
        let targetFrames = collisionFrames(for: target, labelOccluder: labelOccluder)
        var strongest: CGVector?
        var strongestMagnitude: CGFloat = 0
        for sourceFrame in sourceFrames {
            for targetFrame in targetFrames {
                let gapX = max(0, max(sourceFrame.minX - targetFrame.maxX,
                                      targetFrame.minX - sourceFrame.maxX))
                let gapY = max(0, max(sourceFrame.minY - targetFrame.maxY,
                                      targetFrame.minY - sourceFrame.maxY))
                let gap = hypot(gapX, gapY)
                guard gap <= influence else { continue }
                let centerDX = targetFrame.midX - sourceFrame.midX
                let centerDY = targetFrame.midY - sourceFrame.midY
                let centerDistance = hypot(centerDX, centerDY)
                let direction: CGVector
                if centerDistance > 0.001 {
                    direction = CGVector(dx: centerDX / centerDistance,
                                         dy: centerDY / centerDistance)
                } else {
                    direction = source.id < target.id
                        ? CGVector(dx: 1, dy: 0)
                        : CGVector(dx: -1, dy: 0)
                }
                let overlapX = min(sourceFrame.maxX, targetFrame.maxX) -
                    max(sourceFrame.minX, targetFrame.minX)
                let overlapY = min(sourceFrame.maxY, targetFrame.maxY) -
                    max(sourceFrame.minY, targetFrame.minY)
                let penetration = overlapX > 0 && overlapY > 0 ? min(overlapX, overlapY) : 0
                let magnitude = max(0, influence - gap) + penetration
                guard magnitude > strongestMagnitude else { continue }
                strongestMagnitude = magnitude
                strongest = CGVector(dx: direction.dx * magnitude,
                                     dy: direction.dy * magnitude)
            }
        }
        return strongest
    }

    private func collisionFrames(for node: GraphPhysicsNode,
                                 labelOccluder: GraphLabelOccluderProvider?) -> [CGRect] {
        var frames = [CGRect(x: node.position.x - node.radius,
                             y: node.position.y - node.radius,
                             width: node.radius * 2,
                             height: node.radius * 2)]
        if let labelFrame = labelOccluder?(node), !labelFrame.isNull, !labelFrame.isEmpty {
            frames.append(labelFrame)
        }
        return frames
    }

    private func limited(_ vector: CGVector, maximum: CGFloat) -> CGVector {
        let magnitude = hypot(vector.dx, vector.dy)
        guard magnitude > maximum, magnitude > 0 else { return vector }
        let scale = maximum / magnitude
        return CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
    }

    private mutating func transformNodePositions(_ nodeIDs: Set<String>,
                                                 initialPositions: [String: CGPoint],
                                                 transform: (CGPoint) -> CGPoint) {
        for id in nodeIDs {
            guard var node = nodesByID[id] else { continue }
            node.position = transform(initialPositions[id] ?? node.position)
            node.velocity = .zero
            node.isPinned = false
            nodesByID[id] = node
        }
    }

    private mutating func transformNodes(_ nodeIDs: Set<String>,
                                         initialPositions: [String: CGPoint],
                                         initialRestingPositions: [String: CGPoint],
                                         transform: (CGPoint) -> CGPoint) {
        for id in nodeIDs {
            guard var node = nodesByID[id] else { continue }
            node.position = transform(initialPositions[id] ?? node.position)
            node.restingPosition = transform(initialRestingPositions[id] ?? node.restingPosition)
            node.velocity = .zero
            node.isPinned = false
            nodesByID[id] = node
        }
    }

    internal static func rootAnchor(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private static func threadRingRadius(branchCount: Int, size: CGSize) -> CGFloat {
        let visibleBranchCount = max(1, min(branchCount, 10))
        let minimumDimension = max(1, min(size.width, size.height))
        let canvasRadius = minimumDimension * 0.36
        let labelSpacingRadius = CGFloat(visibleBranchCount) * 188 / (2 * .pi)
        return max(250, max(canvasRadius, labelSpacingRadius))
    }

    private static func radialLayoutTargets(data: GraphData,
                                            center: CGPoint,
                                            size: CGSize) -> GraphRadialLayoutTargets {
        let threadByID = Dictionary(uniqueKeysWithValues: data.threads.map { ($0.id, $0) })
        let sortedThreads = data.threads.sorted {
            if $0.lastUpdated != $1.lastUpdated { return $0.lastUpdated > $1.lastUpdated }
            return $0.id < $1.id
        }
        let confirmedGroups = data.groupings
            .filter { !$0.isSuggestion }
            .sorted {
                let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
                return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
            }
        var claimedThreadIDs: Set<String> = []
        var branches: [GraphRadialBranch] = []

        for grouping in confirmedGroups {
            let memberIDs = grouping.threadIDs
                .filter { threadByID[$0] != nil }
                .sorted {
                    guard let left = threadByID[$0], let right = threadByID[$1] else { return $0 < $1 }
                    if left.lastUpdated != right.lastUpdated { return left.lastUpdated > right.lastUpdated }
                    return left.id < right.id
                }
            guard !memberIDs.isEmpty else { continue }
            claimedThreadIDs.formUnion(memberIDs)
            let lastUpdated = memberIDs.compactMap { threadByID[$0]?.lastUpdated }.max() ?? .distantPast
            branches.append(GraphRadialBranch(id: grouping.id,
                                              threadIDs: memberIDs,
                                              groupingID: grouping.id,
                                              isRemaining: false,
                                              lastUpdated: lastUpdated))
        }

        for thread in sortedThreads where !claimedThreadIDs.contains(thread.id) {
            branches.append(GraphRadialBranch(id: thread.id,
                                              threadIDs: [thread.id],
                                              groupingID: nil,
                                              isRemaining: false,
                                              lastUpdated: thread.lastUpdated))
        }
        if let remaining = data.remainingBranch {
            branches.append(GraphRadialBranch(id: remaining.id,
                                              threadIDs: [],
                                              groupingID: nil,
                                              isRemaining: true,
                                              lastUpdated: .distantPast))
        }
        branches.sort {
            if $0.isRemaining != $1.isRemaining { return !$0.isRemaining }
            if $0.lastUpdated != $1.lastUpdated { return $0.lastUpdated > $1.lastUpdated }
            return $0.id < $1.id
        }

        var threadTargets: [String: CGPoint] = [:]
        var groupingTargets: [String: CGPoint] = [:]
        var branchByNodeID: [String: String] = [:]
        var remainingTarget: CGPoint?
        let branchesPerRing = 10
        let baseRadius = threadRingRadius(branchCount: branches.count, size: size)

        for (index, branch) in branches.enumerated() {
            let ringIndex = index / branchesPerRing
            let indexInRing = index % branchesPerRing
            let nodesInRing = min(branchesPerRing, branches.count - ringIndex * branchesPerRing)
            let angleStep = 2 * CGFloat.pi / CGFloat(max(1, nodesInRing))
            let stagger = ringIndex.isMultiple(of: 2) ? 0 : angleStep / 2
            let angle = CGFloat.pi / 2 + CGFloat(indexInRing) * angleStep + stagger
            let radius = baseRadius + CGFloat(ringIndex) * branchSpacingStep

            if branch.isRemaining {
                remainingTarget = point(center: center, radius: radius * 0.9, angle: angle)
                branchByNodeID[branch.id] = branch.id
                continue
            }

            if let groupingID = branch.groupingID {
                branchByNodeID[groupingID] = branch.id
                groupingTargets[groupingID] = point(center: center,
                                                    radius: max(132, radius * 0.54),
                                                    angle: angle)
            }

            let slotWidth = 2 * CGFloat.pi / CGFloat(max(1, branches.count))
            let fanSpan = min(slotWidth * 0.64, 0.72)
            for (memberIndex, threadID) in branch.threadIDs.enumerated() {
                branchByNodeID[threadID] = branch.id
                let memberOffset: CGFloat
                if branch.threadIDs.count < 2 {
                    memberOffset = 0
                } else {
                    memberOffset = -fanSpan / 2 +
                        fanSpan * CGFloat(memberIndex) / CGFloat(branch.threadIDs.count - 1)
                }
                let memberRingOffset = CGFloat(memberIndex / 5) * 118
                threadTargets[threadID] = point(center: center,
                                                radius: radius + memberRingOffset,
                                                angle: angle + memberOffset)
            }
        }

        for (index, grouping) in data.groupings.filter(\.isSuggestion).enumerated() {
            let memberTargets = grouping.threadIDs.compactMap { threadTargets[$0] }
            let direction = circularMeanDirection(points: memberTargets, center: center) ??
                CGPoint(x: cos(CGFloat(index) * 2.39996), y: sin(CGFloat(index) * 2.39996))
            let radius = max(136, baseRadius * 0.58)
            let perpendicular = CGPoint(x: -direction.y, y: direction.x)
            let sideOffset: CGFloat = index.isMultiple(of: 2) ? -28 : 28
            groupingTargets[grouping.id] = CGPoint(x: center.x + direction.x * radius + perpendicular.x * sideOffset,
                                                   y: center.y + direction.y * radius + perpendicular.y * sideOffset)
            branchByNodeID[grouping.id] = grouping.id
        }

        return GraphRadialLayoutTargets(threadByID: threadTargets,
                                        groupingByID: groupingTargets,
                                        branchByNodeID: branchByNodeID,
                                        remaining: remainingTarget)
    }

    private static func messageOffset(for messageIndex: Int) -> CGFloat {
        messageLeafBaseOffset + messageLeafSpacing * CGFloat(messageIndex)
    }

    private static func messageFanAngle(for messageIndex: Int) -> CGFloat {
        guard messageIndex > 0 else { return 0 }
        let depth = CGFloat((messageIndex - 1) / 2 + 1)
        let fanOffset = min(messageFanMax, depth * messageFanStep)
        return messageIndex.isMultiple(of: 2) ? -fanOffset : fanOffset
    }

    private static func point(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius)
    }

    private static func circularMeanDirection(points: [CGPoint], center: CGPoint) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { partial, point in
            let direction = outwardUnitVector(from: center, through: point)
            return CGPoint(x: partial.x + direction.x, y: partial.y + direction.y)
        }
        let length = hypot(sum.x, sum.y)
        guard length > 0.001 else { return nil }
        return CGPoint(x: sum.x / length, y: sum.y / length)
    }

    private static func outwardUnitVector(from center: CGPoint, through point: CGPoint) -> CGPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let length = max(1, hypot(dx, dy))
        return CGPoint(x: dx / length, y: dy / length)
    }

    private func isCandidate(_ point: CGPoint, from origin: CGPoint, direction: GraphDirection) -> Bool {
        switch direction {
        case .up:
            return point.y > origin.y
        case .down:
            return point.y < origin.y
        case .left:
            return point.x < origin.x
        case .right:
            return point.x > origin.x
        }
    }

    private func directionalScore(_ point: CGPoint, from origin: CGPoint, direction: GraphDirection) -> CGFloat {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let primary: CGFloat
        let cross: CGFloat
        switch direction {
        case .up:
            primary = max(1, dy)
            cross = abs(dx)
        case .down:
            primary = max(1, -dy)
            cross = abs(dx)
        case .left:
            primary = max(1, -dx)
            cross = abs(dy)
        case .right:
            primary = max(1, dx)
            cross = abs(dy)
        }
        return primary + cross * 1.35
    }
}
