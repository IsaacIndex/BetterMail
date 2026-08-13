import CoreGraphics
import Foundation

/// The small set of forces exposed by Obsidian's graph controls. Values are
/// intentionally frame-normalized so the layout behaves consistently at the
/// scene's active and idle frame rates.
internal struct ObsidianGraphForceConfig: Equatable {
    internal var centerStrength: CGFloat
    internal var repelStrength: CGFloat
    internal var linkStrength: CGFloat
    internal var linkDistance: CGFloat
    internal var damping: CGFloat

    internal static let defaults = ObsidianGraphForceConfig(centerStrength: 0.004,
                                                            repelStrength: 5_200,
                                                            linkStrength: 0.034,
                                                            linkDistance: 140,
                                                            damping: 0.84)

    /// Historical defaults retained only so existing installs can migrate to
    /// the roomier layout without overwriting deliberately customized values.
    internal static let legacyCompactDefaults = ObsidianGraphForceConfig(centerStrength: 0.004,
                                                                         repelStrength: 2_400,
                                                                         linkStrength: 0.034,
                                                                         linkDistance: 92,
                                                                         damping: 0.84)

    internal static let legacyRoomierDefaults = ObsidianGraphForceConfig(centerStrength: 0.004,
                                                                         repelStrength: 3_400,
                                                                         linkStrength: 0.034,
                                                                         linkDistance: 106,
                                                                         damping: 0.84)

    internal static func migratingHistoricalDefaults(_ config: Self) -> Self {
        if config == legacyCompactDefaults || config == legacyRoomierDefaults {
            return defaults
        }
        return config
    }

    /// One-time migration for the concise-label release. It raises only the
    /// spacing dimensions, preserving any customized center, spring, and
    /// damping behavior.
    internal static func migratingToExpandedSpacing(_ config: Self) -> Self {
        var migrated = config
        migrated.repelStrength = max(migrated.repelStrength, defaults.repelStrength)
        migrated.linkDistance = max(migrated.linkDistance, defaults.linkDistance)
        return migrated
    }
}

internal struct ObsidianGraphDisplayConfig: Equatable {
    internal var showsArrows: Bool
    internal var textFadeThreshold: CGFloat
    internal var nodeSize: CGFloat
    internal var linkThickness: CGFloat

    internal static let defaults = ObsidianGraphDisplayConfig(showsArrows: false,
                                                              textFadeThreshold: -0.4,
                                                              nodeSize: 1,
                                                              linkThickness: 1)
}

internal struct ObsidianGraphPhysicsNode: Identifiable, Equatable {
    internal let id: String
    internal let kind: GraphNodeKind
    internal let radius: CGFloat
    internal let branchID: String?
    internal let graphDepth: Int
    internal let chronologyRank: CGFloat?
    internal var position: CGPoint
    internal var velocity: CGVector
    internal var isPinned: Bool
}

/// A native, deterministic force simulation tailored to BetterMail's graph
/// projection. Every node, including the initially centered `You` node, remains
/// freely movable to match Obsidian's single-node drag behavior.
internal struct ObsidianGraphForceSimulator {
    internal private(set) var nodesByID: [String: ObsidianGraphPhysicsNode] = [:]
    internal private(set) var edges: [GraphEdge] = []
    internal private(set) var size: CGSize = .zero

    private var draggedNodeID: String?
    private var stationaryNodeIDsDuringDrag: Set<String> = []
    private static let interGroupRepelMultiplier: CGFloat = 3.2
    private static let interGroupRepelRangeMultiplier: CGFloat = 1.45
    private static let chronologyRadiusMultiplier: CGFloat = 1.8
    private static let chronologyRadialStrength: CGFloat = 0.018

    internal var nodes: [ObsidianGraphPhysicsNode] {
        nodesByID.values.sorted { $0.id < $1.id }
    }

    internal mutating func reset(data: GraphData,
                                 size nextSize: CGSize,
                                 preserving positions: [String: CGPoint] = [:],
                                 config: ObsidianGraphForceConfig = .defaults) {
        let previousSize = size
        let previousNodes = nodesByID
        let center = CGPoint(x: nextSize.width / 2, y: nextSize.height / 2)
        let centerShift = CGVector(dx: (nextSize.width - previousSize.width) / 2,
                                   dy: (nextSize.height - previousSize.height) / 2)
        let depths = Self.depths(in: data)
        let chronologyRankByThreadID = Self.chronologyRankMap(from: data.threads)
        let branchIDByThreadID = Self.folderBranchIDByThreadID(from: data.groupings)
        let nodeDescriptors = Self.nodeDescriptors(in: data,
                                                  branchIDByThreadID: branchIDByThreadID)

        nodesByID = Dictionary(uniqueKeysWithValues: nodeDescriptors.enumerated().map { index, descriptor in
            let retainedPosition = positions[descriptor.id] ?? previousNodes[descriptor.id]?.position
            let position: CGPoint
            if let retainedPosition {
                position = previousSize == .zero
                    ? retainedPosition
                    : CGPoint(x: retainedPosition.x + centerShift.dx,
                              y: retainedPosition.y + centerShift.dy)
            } else if descriptor.kind == .center {
                position = center
            } else {
                let chronologyRank = descriptor.threadID.flatMap { chronologyRankByThreadID[$0] } ?? 0
                position = Self.initialPosition(for: descriptor.id,
                                                index: index,
                                                depth: depths[descriptor.id, default: 1],
                                                chronologyRank: chronologyRank,
                                                center: center,
                                                linkDistance: config.linkDistance)
            }
            let previousVelocity = previousNodes[descriptor.id]?.velocity ?? .zero
            return (descriptor.id,
                    ObsidianGraphPhysicsNode(id: descriptor.id,
                                             kind: descriptor.kind,
                                             radius: descriptor.radius,
                                             branchID: descriptor.branchID,
                                             graphDepth: depths[descriptor.id, default: 1],
                                             chronologyRank: descriptor.threadID.flatMap { chronologyRankByThreadID[$0] },
                                             position: position,
                                             velocity: previousVelocity,
                                             isPinned: false))
        })
        edges = data.edges.filter { nodesByID[$0.sourceID] != nil && nodesByID[$0.targetID] != nil }
        size = nextSize
        draggedNodeID = nil
        stationaryNodeIDsDuringDrag = []
    }

    internal mutating func step(deltaTime: TimeInterval,
                                reduceMotion: Bool,
                                config: ObsidianGraphForceConfig) {
        guard nodesByID.count > 1 else { return }
        let frameScale = min(max(CGFloat(deltaTime) * 60, 0.2), 2)
        let iterations = reduceMotion ? 3 : 1
        let iterationScale = frameScale / CGFloat(iterations)
        for _ in 0..<iterations {
            stepOnce(frameScale: iterationScale, config: config)
        }
        if reduceMotion {
            dampMotion(multiplier: 0.55)
        }
    }

    internal mutating func beginDragging(nodeID: String,
                                         keepingStationary stationaryNodeIDs: Set<String> = []) {
        guard nodesByID[nodeID] != nil else { return }
        releaseStationaryNodesAfterDrag()
        draggedNodeID = nodeID
        stationaryNodeIDsDuringDrag = stationaryNodeIDs
            .intersection(Set(nodesByID.keys))
            .subtracting([nodeID])
        for stationaryNodeID in stationaryNodeIDsDuringDrag {
            nodesByID[stationaryNodeID]?.isPinned = true
            nodesByID[stationaryNodeID]?.velocity = .zero
        }
        nodesByID[nodeID]?.isPinned = true
        nodesByID[nodeID]?.velocity = .zero
    }

    internal mutating func drag(nodeID: String, to position: CGPoint) {
        guard draggedNodeID == nodeID else { return }
        nodesByID[nodeID]?.position = position
        nodesByID[nodeID]?.velocity = .zero
    }

    internal mutating func endDragging(nodeID: String, at position: CGPoint) {
        guard draggedNodeID == nodeID else { return }
        nodesByID[nodeID]?.position = position
        nodesByID[nodeID]?.velocity = .zero
        nodesByID[nodeID]?.isPinned = false
        draggedNodeID = nil
        releaseStationaryNodesAfterDrag()
    }

    private mutating func releaseStationaryNodesAfterDrag() {
        for stationaryNodeID in stationaryNodeIDsDuringDrag {
            nodesByID[stationaryNodeID]?.isPinned = false
            nodesByID[stationaryNodeID]?.velocity = .zero
        }
        stationaryNodeIDsDuringDrag = []
    }

    internal mutating func stopMotion() {
        for id in nodesByID.keys {
            nodesByID[id]?.velocity = .zero
        }
    }

    internal func positionsByID() -> [String: CGPoint] {
        nodesByID.mapValues(\.position)
    }

    internal func totalEnergy() -> CGFloat {
        nodesByID.values.reduce(0) { partial, node in
            partial + node.velocity.dx * node.velocity.dx + node.velocity.dy * node.velocity.dy
        }
    }

    internal func neighborIDs(of nodeID: String) -> Set<String> {
        edges.reduce(into: Set<String>()) { result, edge in
            if edge.sourceID == nodeID { result.insert(edge.targetID) }
            if edge.targetID == nodeID { result.insert(edge.sourceID) }
        }
    }

    private mutating func stepOnce(frameScale: CGFloat,
                                   config: ObsidianGraphForceConfig) {
        let ids = nodesByID.keys.sorted()
        var forces = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGVector.zero) })
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let repulsionCutoff = max(config.linkDistance * 6.0, 280)

        for index in ids.indices {
            let leftID = ids[index]
            guard let left = nodesByID[leftID] else { continue }
            for rightIndex in ids.index(after: index)..<ids.endIndex {
                let rightID = ids[rightIndex]
                guard let right = nodesByID[rightID] else { continue }
                var dx = right.position.x - left.position.x
                var dy = right.position.y - left.position.y
                var distance = hypot(dx, dy)
                if distance < 0.01 {
                    let angle = Self.stableAngle(for: "\(leftID)|\(rightID)")
                    dx = cos(angle)
                    dy = sin(angle)
                    distance = 1
                }
                let usesInterGroupRepulsion = Self.usesInterGroupRepulsion(left, right)
                let pairCutoff = repulsionCutoff * (usesInterGroupRepulsion
                    ? Self.interGroupRepelRangeMultiplier
                    : 1)
                guard distance < pairCutoff else { continue }
                let unit = CGVector(dx: dx / distance, dy: dy / distance)
                let minimumDistance = left.radius + right.radius + 12
                let inverseSquare = config.repelStrength / max(distance * distance, 64)
                let collision = max(0, minimumDistance - distance) * 0.24
                var magnitude = min(inverseSquare + collision, 20)
                if usesInterGroupRepulsion {
                    magnitude *= Self.interGroupRepelMultiplier
                }
                forces[leftID]?.dx -= unit.dx * magnitude
                forces[leftID]?.dy -= unit.dy * magnitude
                forces[rightID]?.dx += unit.dx * magnitude
                forces[rightID]?.dy += unit.dy * magnitude
            }
        }

        for edge in edges {
            guard let source = nodesByID[edge.sourceID],
                  let target = nodesByID[edge.targetID] else { continue }
            let dx = target.position.x - source.position.x
            let dy = target.position.y - source.position.y
            let distance = max(hypot(dx, dy), 1)
            let unit = CGVector(dx: dx / distance, dy: dy / distance)
            let targetDistance = Self.targetDistance(for: edge.kind, base: config.linkDistance)
            let magnitude = (distance - targetDistance) * config.linkStrength
            forces[edge.sourceID]?.dx += unit.dx * magnitude
            forces[edge.sourceID]?.dy += unit.dy * magnitude
            forces[edge.targetID]?.dx -= unit.dx * magnitude
            forces[edge.targetID]?.dy -= unit.dy * magnitude
        }

        for id in ids where id != GraphCenter.you.id {
            guard let node = nodesByID[id] else { continue }
            forces[id]?.dx += (center.x - node.position.x) * config.centerStrength
            forces[id]?.dy += (center.y - node.position.y) * config.centerStrength
        }

        if let graphCenter = nodesByID[GraphCenter.you.id] {
            for id in ids {
                guard let node = nodesByID[id],
                      node.kind == .thread,
                      let chronologyRank = node.chronologyRank else { continue }
                var dx = node.position.x - graphCenter.position.x
                var dy = node.position.y - graphCenter.position.y
                var distance = hypot(dx, dy)
                if distance < 0.01 {
                    let angle = Self.stableAngle(for: "chronology|\(id)")
                    dx = cos(angle)
                    dy = sin(angle)
                    distance = 1
                }
                let unit = CGVector(dx: dx / distance, dy: dy / distance)
                let depthBase = CGFloat(max(node.graphDepth, 1)) * config.linkDistance * 0.78
                let preferredDistance = depthBase
                    + chronologyRank * config.linkDistance * Self.chronologyRadiusMultiplier
                let magnitude = (preferredDistance - distance) * Self.chronologyRadialStrength
                forces[id]?.dx += unit.dx * magnitude
                forces[id]?.dy += unit.dy * magnitude
            }
        }

        let damping = pow(config.damping, frameScale)
        for id in ids {
            guard var node = nodesByID[id] else { continue }
            if node.isPinned {
                node.velocity = .zero
                nodesByID[id] = node
                continue
            }
            let force = forces[id] ?? .zero
            node.velocity.dx = (node.velocity.dx + force.dx * frameScale) * damping
            node.velocity.dy = (node.velocity.dy + force.dy * frameScale) * damping
            node.position.x += node.velocity.dx * frameScale
            node.position.y += node.velocity.dy * frameScale
            if !node.position.x.isFinite || !node.position.y.isFinite {
                node.position = center
                node.velocity = .zero
            }
            nodesByID[id] = node
        }

    }

    private mutating func dampMotion(multiplier: CGFloat) {
        for id in nodesByID.keys {
            nodesByID[id]?.velocity.dx *= multiplier
            nodesByID[id]?.velocity.dy *= multiplier
        }
    }

    private static func targetDistance(for kind: GraphEdgeKind, base: CGFloat) -> CGFloat {
        switch kind {
        case .trunk:
            return base * 1.25
        case .grouping, .suggested:
            return base
        case .chain:
            return base * 0.72
        case .remaining:
            return base * 1.15
        }
    }

    private static func depths(in data: GraphData) -> [String: Int] {
        var adjacency: [String: [String]] = [:]
        for edge in data.edges {
            adjacency[edge.sourceID, default: []].append(edge.targetID)
            adjacency[edge.targetID, default: []].append(edge.sourceID)
        }
        var result = [data.center.id: 0]
        var queue = [data.center.id]
        var index = 0
        while index < queue.count {
            let id = queue[index]
            index += 1
            let depth = result[id, default: 0]
            for neighbor in adjacency[id, default: []].sorted() where result[neighbor] == nil {
                result[neighbor] = depth + 1
                queue.append(neighbor)
            }
        }
        return result
    }

    private static func nodeDescriptors(in data: GraphData) -> [(id: String, kind: GraphNodeKind, radius: CGFloat, branchID: String?, threadID: String?)] {
        return Self.nodeDescriptors(in: data, branchIDByThreadID: Self.folderBranchIDByThreadID(from: data.groupings))
    }

    private static func nodeDescriptors(in data: GraphData,
                                        branchIDByThreadID: [String: String])
    -> [(id: String,
         kind: GraphNodeKind,
         radius: CGFloat,
         branchID: String?,
         threadID: String?)] {
        var result: [(String, GraphNodeKind, CGFloat, String?, String?)] = [(data.center.id, .center, 9, nil, nil)]
        result.append(contentsOf: data.groupings.map { grouping in
            (grouping.id,
             grouping.nodeKind,
             7.5,
             grouping.kind == .folder ? (grouping.sourceFolderID ?? grouping.id) : nil,
             nil)
        })
        result.append(contentsOf: data.threads.map { thread in
            (thread.id,
             .thread,
             5.5 + CGFloat(min(thread.messageCount, 8)) * 0.35,
             branchIDByThreadID[thread.id],
             thread.id)
        })
        result.append(contentsOf: data.remainingBranches.map { remaining in
            let branchID = remaining.parentID == data.center.id
                ? nil
                : (data.groupingByID[remaining.parentID]?.sourceFolderID ?? remaining.parentID)
            return (remaining.id, .remaining, 8.5, branchID, nil)
        })
        result.append(contentsOf: data.messages.map { message in
            (message.id,
             .message,
             message.unread ? 4 : 3,
             branchIDByThreadID[message.threadID],
             message.threadID)
        })
        return result
    }

    private static func initialPosition(for id: String,
                                        index: Int,
                                        depth: Int,
                                        chronologyRank: CGFloat,
                                        center: CGPoint,
                                        linkDistance: CGFloat) -> CGPoint {
        let angle = stableAngle(for: id) + CGFloat(index) * 2.399_963
        let depthRadius = CGFloat(max(depth, 1)) * linkDistance * 0.78
        let jitter = CGFloat(stableHash(id) % 37) - 18
        let chronologyOffset = chronologyRank * linkDistance * chronologyRadiusMultiplier
        let radius = max(linkDistance * 0.7, depthRadius + jitter + chronologyOffset)
        return CGPoint(x: center.x + cos(angle) * radius,
                       y: center.y + sin(angle) * radius)
    }

    private static func folderBranchIDByThreadID(from groupings: [GraphGrouping]) -> [String: String] {
        groupings.filter { $0.kind == .folder }
            .reduce(into: [:]) { result, grouping in
                grouping.threadIDs.forEach { threadID in
                    result[threadID] = grouping.sourceFolderID ?? grouping.id
                }
            }
    }

    private static func chronologyRankMap(from threads: [GraphThread]) -> [String: CGFloat] {
        guard let oldest = threads.map(\.lastUpdated).min(),
              let newest = threads.map(\.lastUpdated).max() else { return [:] }
        let span = newest.timeIntervalSince(oldest)
        guard span > 0 else {
            return Dictionary(uniqueKeysWithValues: threads.map { ($0.id, 0) })
        }
        return Dictionary(uniqueKeysWithValues: threads.map { thread in
            let elapsed = thread.lastUpdated.timeIntervalSince(oldest)
            return (thread.id, CGFloat(elapsed / span))
        })
    }

    private static func usesInterGroupRepulsion(_ left: ObsidianGraphPhysicsNode,
                                                 _ right: ObsidianGraphPhysicsNode) -> Bool {
        guard left.kind != .center, right.kind != .center else { return false }
        guard left.branchID != right.branchID else { return false }
        return left.branchID != nil || right.branchID != nil
    }

    private static func stableAngle(for value: String) -> CGFloat {
        CGFloat(stableHash(value) % 10_000) / 10_000 * .pi * 2
    }

    private static func stableHash(_ value: String) -> UInt32 {
        value.utf8.reduce(2_166_136_261) { hash, byte in
            (hash ^ UInt32(byte)) &* 16_777_619
        }
    }
}
