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

internal struct GraphCurlConfig: Equatable {
    internal let curl: CGFloat
    internal let curlVariability: CGFloat
    internal let splineTension: CGFloat
    internal let curlFalloff: CGFloat
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
}

internal enum GraphForceConstants {
    internal static let defaults = GraphForceConfig(center: 0.006,
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
}

internal typealias GraphLabelOccluderProvider = (GraphPhysicsNode) -> CGFloat

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
                                reduceMotion: Bool = false,
                                config: GraphForceConfig = GraphForceConstants.defaults,
                                labelOccluderRadius: GraphLabelOccluderProvider? = nil) {
        guard size.width > 0, size.height > 0 else { return }
        let dt = CGFloat(min(max(rawDeltaTime, 0), 0.032) / 0.016)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        if var centerNode = nodesByID[GraphCenter.you.id] {
            centerNode.position = center
            centerNode.velocity = .zero
            nodesByID[GraphCenter.you.id] = centerNode
        }

        var forces = Dictionary(uniqueKeysWithValues: nodesByID.keys.map { ($0, CGVector.zero) })
        applyEdgeForces(into: &forces, config: config)
        applyRepulsionForces(into: &forces, config: config, labelOccluderRadius: labelOccluderRadius)
        applyCenterPullAndBreeze(into: &forces,
                                 center: center,
                                 elapsedTime: elapsedTime,
                                 reduceMotion: reduceMotion,
                                 config: config)

        for id in nodesByID.keys {
            guard var node = nodesByID[id] else { continue }
            if node.isPinned {
                node.position = id == GraphCenter.you.id ? center : node.position
                node.velocity = .zero
                nodesByID[id] = node
                continue
            }
            let force = forces[id] ?? .zero
            node.velocity.dx = (node.velocity.dx + force.dx * dt) * config.damping
            node.velocity.dy = (node.velocity.dy + force.dy * dt) * config.damping
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

    private mutating func applyEdgeForces(into forces: inout [String: CGVector],
                                          config: GraphForceConfig) {
        for edge in edges {
            guard let source = nodesByID[edge.sourceID],
                  let target = nodesByID[edge.targetID] else { continue }
            let dx = target.position.x - source.position.x
            let dy = target.position.y - source.position.y
            let distance = max(1, hypot(dx, dy))
            let springK = config.linkSpring * (edge.kind == .trunk ? 1.0 : 1.2)
            let targetLength = edge.kind == .trunk ? config.trunkLength : config.chainLength
            let force = (distance - targetLength) * springK
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

    private func applyRepulsionForces(into forces: inout [String: CGVector],
                                      config: GraphForceConfig,
                                      labelOccluderRadius: GraphLabelOccluderProvider?) {
        let nodeValues = nodesByID.values.sorted { $0.id < $1.id }
        guard nodeValues.count > 1 else { return }
        for leftIndex in 0..<(nodeValues.count - 1) {
            for rightIndex in (leftIndex + 1)..<nodeValues.count {
                let left = nodeValues[leftIndex]
                let right = nodeValues[rightIndex]
                let dx = right.position.x - left.position.x
                let dy = right.position.y - left.position.y
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared < config.repelCutoffSquared else { continue }
                let distance = max(1, sqrt(distanceSquared))
                let leftLabelRadius = config.labelRepelOn ? labelOccluderRadius?(left) ?? 0 : 0
                let rightLabelRadius = config.labelRepelOn ? labelOccluderRadius?(right) ?? 0 : 0
                let labelOverlap = max(0,
                                       left.radius + leftLabelRadius + right.radius + rightLabelRadius - distance) *
                    config.labelRepelStrength
                let preferredDistance = left.radius + right.radius + (left.kind == .message || right.kind == .message ? 72 : 24)
                let overlapForce = max(0, preferredDistance - distance) * 0.035 + labelOverlap
                let force = config.repel / (distanceSquared + 160) + overlapForce
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

    private func applyCenterPullAndBreeze(into forces: inout [String: CGVector],
                                          center: CGPoint,
                                          elapsedTime: TimeInterval,
                                          reduceMotion: Bool,
                                          config: GraphForceConfig) {
        let breezeX = reduceMotion ? 0 : CGFloat(sin(elapsedTime * 0.0006)) * config.breezeAmplitude * 0.085
        let breezeY = reduceMotion ? 0 : CGFloat(cos(elapsedTime * 0.0009)) * config.breezeAmplitude * 0.057
        for node in nodesByID.values where !node.isPinned {
            let dx = center.x - node.position.x
            let dy = center.y - node.position.y
            let centerWeight = config.center * (node.kind == .thread ? 0.1 : 0.034)
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
