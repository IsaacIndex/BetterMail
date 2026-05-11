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
    internal var position: CGPoint
    internal var velocity: CGVector
    internal var radius: CGFloat
    internal var isPinned: Bool
}

internal struct GraphForceConstants {
    internal static let centerPull: CGFloat = 0.012
    internal static let edgeSpring: CGFloat = 0.045
    internal static let repulsion: CGFloat = 4_600
    internal static let damping: CGFloat = 0.82
    internal static let sway: CGFloat = 0.0008
    internal static let repulsionCutoffSquared: CGFloat = 160_000
    internal static let branchStraightening: CGFloat = 0.009
    internal static let branchOutward: CGFloat = 0.018
    internal static let branchStartSpacing: CGFloat = 92
    internal static let branchStepSpacing: CGFloat = 76
}

internal struct GraphForceSimulator {
    internal private(set) var nodesByID: [String: GraphPhysicsNode] = [:]
    internal private(set) var edges: [GraphEdge] = []
    internal private(set) var size: CGSize = .zero

    internal var nodes: [GraphPhysicsNode] {
        nodesByID.values.sorted { $0.id < $1.id }
    }

    internal mutating func reset(data: GraphData,
                                 size: CGSize,
                                 preserving existingPositions: [String: CGPoint] = [:]) {
        self.size = size
        edges = data.edges
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var nextNodes: [String: GraphPhysicsNode] = [
            data.center.id: GraphPhysicsNode(id: data.center.id,
                                             kind: .center,
                                             threadID: nil,
                                             position: center,
                                             velocity: .zero,
                                             radius: 38,
                                             isPinned: true)
        ]

        for thread in data.threads {
            let radians = thread.angle * .pi / 180
            let orbitRadius: CGFloat = 200 + (thread.messageCount > 8 ? 30 : 0)
            let defaultPosition = CGPoint(x: center.x + cos(radians) * orbitRadius,
                                          y: center.y + sin(radians) * orbitRadius)
            nextNodes[thread.id] = GraphPhysicsNode(id: thread.id,
                                                    kind: .thread,
                                                    threadID: thread.id,
                                                    position: existingPositions[thread.id] ?? defaultPosition,
                                                    velocity: nodesByID[thread.id]?.velocity ?? .zero,
                                                    radius: thread.radius,
                                                    isPinned: false)
            let messages = data.messages.filter { $0.threadID == thread.id }.sorted { $0.index < $1.index }
            for message in messages {
                let distance = orbitRadius + 48 + CGFloat(message.index * 18)
                let offset = CGPoint(x: center.x + cos(radians) * distance,
                                     y: center.y + sin(radians) * distance)
                let jitter = CGPoint(x: CGFloat((message.index % 3) - 1) * 10,
                                     y: CGFloat(((message.index + 1) % 3) - 1) * 10)
                nextNodes[message.id] = GraphPhysicsNode(id: message.id,
                                                         kind: .message,
                                                         threadID: thread.id,
                                                         position: existingPositions[message.id] ??
                                                         CGPoint(x: offset.x + jitter.x, y: offset.y + jitter.y),
                                                         velocity: nodesByID[message.id]?.velocity ?? .zero,
                                                         radius: message.radius,
                                                         isPinned: false)
            }
        }

        nodesByID = nextNodes
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

    internal mutating func step(deltaTime rawDeltaTime: TimeInterval,
                                elapsedTime: TimeInterval,
                                reduceMotion: Bool = false) {
        guard size.width > 0, size.height > 0 else { return }
        let dt = CGFloat(min(max(rawDeltaTime, 0), 0.032) / 0.016)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        if var centerNode = nodesByID[GraphCenter.you.id] {
            centerNode.position = center
            centerNode.velocity = .zero
            nodesByID[GraphCenter.you.id] = centerNode
        }

        var forces = Dictionary(uniqueKeysWithValues: nodesByID.keys.map { ($0, CGVector.zero) })
        applyEdgeForces(into: &forces)
        applyRepulsionForces(into: &forces)
        applyBranchShapeForces(into: &forces, center: center)
        applyCenterPullAndBreeze(into: &forces, center: center, elapsedTime: elapsedTime, reduceMotion: reduceMotion)

        for id in nodesByID.keys {
            guard var node = nodesByID[id] else { continue }
            if node.isPinned {
                node.position = id == GraphCenter.you.id ? center : node.position
                node.velocity = .zero
                nodesByID[id] = node
                continue
            }
            let force = forces[id] ?? .zero
            node.velocity.dx = (node.velocity.dx + force.dx * dt) * GraphForceConstants.damping
            node.velocity.dy = (node.velocity.dy + force.dy * dt) * GraphForceConstants.damping
            if abs(node.velocity.dx) < 0.05 { node.velocity.dx = 0 }
            if abs(node.velocity.dy) < 0.05 { node.velocity.dy = 0 }
            node.position.x += node.velocity.dx * dt
            node.position.y += node.velocity.dy * dt
            nodesByID[id] = node
        }
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

    internal func positionsByID() -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: nodesByID.map { ($0.key, $0.value.position) })
    }

    private mutating func applyEdgeForces(into forces: inout [String: CGVector]) {
        for edge in edges {
            guard let source = nodesByID[edge.sourceID],
                  let target = nodesByID[edge.targetID] else { continue }
            let dx = target.position.x - source.position.x
            let dy = target.position.y - source.position.y
            let distance = max(1, hypot(dx, dy))
            let springK = GraphForceConstants.edgeSpring * (edge.kind == .trunk ? 1.0 : 1.2)
            let force = (distance - edge.targetLength) * springK
            let fx = dx / distance * force
            let fy = dy / distance * force
            if !source.isPinned {
                forces[source.id, default: .zero].dx += fx
                forces[source.id, default: .zero].dy += fy
            }
            if !target.isPinned {
                forces[target.id, default: .zero].dx -= fx
                forces[target.id, default: .zero].dy -= fy
            }
        }
    }

    private func applyRepulsionForces(into forces: inout [String: CGVector]) {
        let nodeValues = nodesByID.values.sorted { $0.id < $1.id }
        guard nodeValues.count > 1 else { return }
        for leftIndex in 0..<(nodeValues.count - 1) {
            for rightIndex in (leftIndex + 1)..<nodeValues.count {
                let left = nodeValues[leftIndex]
                let right = nodeValues[rightIndex]
                let dx = right.position.x - left.position.x
                let dy = right.position.y - left.position.y
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared < GraphForceConstants.repulsionCutoffSquared else { continue }
                let distance = max(1, sqrt(distanceSquared))
                let preferredDistance = left.radius + right.radius + (left.kind == .message || right.kind == .message ? 72 : 24)
                let overlapForce = max(0, preferredDistance - distance) * 0.035
                let force = GraphForceConstants.repulsion / (distanceSquared + 160) + overlapForce
                let fx = dx / distance * force
                let fy = dy / distance * force
                if !left.isPinned {
                    forces[left.id, default: .zero].dx -= fx
                    forces[left.id, default: .zero].dy -= fy
                }
                if !right.isPinned {
                    forces[right.id, default: .zero].dx += fx
                    forces[right.id, default: .zero].dy += fy
                }
            }
        }
    }

    private func applyBranchShapeForces(into forces: inout [String: CGVector], center: CGPoint) {
        let depthsByMessageID = messageDepthsByID()
        for node in nodesByID.values where node.kind == .message && !node.isPinned {
            guard let threadID = node.threadID,
                  let thread = nodesByID[threadID] else { continue }
            let axisX = thread.position.x - center.x
            let axisY = thread.position.y - center.y
            let axisLength = max(1, hypot(axisX, axisY))
            let unitX = axisX / axisLength
            let unitY = axisY / axisLength
            let relativeX = node.position.x - thread.position.x
            let relativeY = node.position.y - thread.position.y
            let projection = relativeX * unitX + relativeY * unitY
            let projectedX = unitX * projection
            let projectedY = unitY * projection
            let perpendicularX = relativeX - projectedX
            let perpendicularY = relativeY - projectedY
            let depth = CGFloat(depthsByMessageID[node.id] ?? 0)
            let desiredProjection = GraphForceConstants.branchStartSpacing +
                depth * GraphForceConstants.branchStepSpacing
            let outwardDeficit = max(0, desiredProjection - projection)
            forces[node.id, default: .zero].dx -= perpendicularX * GraphForceConstants.branchStraightening
            forces[node.id, default: .zero].dy -= perpendicularY * GraphForceConstants.branchStraightening
            forces[node.id, default: .zero].dx += unitX * outwardDeficit * GraphForceConstants.branchOutward
            forces[node.id, default: .zero].dy += unitY * outwardDeficit * GraphForceConstants.branchOutward
        }
    }

    private func messageDepthsByID() -> [String: Int] {
        var targetBySourceID: [String: String] = [:]
        for edge in edges where edge.kind == .chain {
            targetBySourceID[edge.sourceID] = edge.targetID
        }
        var depths: [String: Int] = [:]
        for thread in nodesByID.values where thread.kind == .thread {
            var depth = 0
            var nextID = targetBySourceID[thread.id]
            var visited: Set<String> = []
            while let currentID = nextID,
                  visited.insert(currentID).inserted {
                depths[currentID] = depth
                nextID = targetBySourceID[currentID]
                depth += 1
            }
        }
        return depths
    }

    private func applyCenterPullAndBreeze(into forces: inout [String: CGVector],
                                          center: CGPoint,
                                          elapsedTime: TimeInterval,
                                          reduceMotion: Bool) {
        let breezeX = reduceMotion ? 0 : CGFloat(sin(elapsedTime * 0.0006) * 0.06)
        let breezeY = reduceMotion ? 0 : CGFloat(cos(elapsedTime * 0.0009) * 0.04)
        for node in nodesByID.values where !node.isPinned {
            let dx = center.x - node.position.x
            let dy = center.y - node.position.y
            let centerWeight: CGFloat = node.kind == .thread ? 0.0006 : 0.0002
            let breezeWeight: CGFloat = node.kind == .message ? 1.2 : 0.4
            forces[node.id, default: .zero].dx += dx * centerWeight + breezeX * breezeWeight
            forces[node.id, default: .zero].dy += dy * centerWeight + breezeY * breezeWeight
        }
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
