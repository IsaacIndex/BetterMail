import CoreGraphics
import Foundation

/// Transient, process-local payload used when a rail row initiates the same
/// batch organization gesture as a graph node. The payload is never persisted
/// or logged; consumers must still route the resulting mutation through the
/// organizer command boundary.
internal nonisolated struct OrganizerRailDragPayload: Codable, Equatable, Sendable {
    internal static let typeIdentifier = "com.bettermail.organizer.thread-ids"
    internal static let currentSchemaVersion = 1

    internal let schemaVersion: Int
    internal let rawThreadIDs: [String]

    internal init?(rawThreadIDs: [String]) {
        let normalized = Set(rawThreadIDs.compactMap { rawID -> String? in
            let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }).sorted()
        guard !normalized.isEmpty else { return nil }
        schemaVersion = Self.currentSchemaVersion
        self.rawThreadIDs = normalized
    }

    internal func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    internal static func decode(_ data: Data) throws -> OrganizerRailDragPayload? {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard decoded.schemaVersion == currentSchemaVersion else { return nil }
        return Self(rawThreadIDs: decoded.rawThreadIDs)
    }
}

internal nonisolated struct OrganizerPointerModifiers: OptionSet, Equatable, Sendable {
    internal let rawValue: Int

    internal init(rawValue: Int) {
        self.rawValue = rawValue
    }

    internal static let command = Self(rawValue: 1 << 0)
    internal static let shift = Self(rawValue: 1 << 1)
}

internal nonisolated enum OrganizerPointerSelectionIntent: Equatable, Sendable {
    case replace
    case toggle
    case range
}

internal nonisolated enum OrganizerPointerUpdate: Equatable, Sendable {
    case none
    case pan(delta: CGVector)
    case drag(nodeIDs: [String], delta: CGVector)
    case lasso(CGRect)
}

internal nonisolated enum OrganizerPointerCompletion: Equatable, Sendable {
    case none
    case select(nodeID: String, intent: OrganizerPointerSelectionIntent)
    case clearSelection
    case finishPan
    case finishDrag(nodeIDs: [String], pointerLocation: CGPoint, delta: CGVector)
    case finishLasso(rect: CGRect, additive: Bool)
}

/// Coarse, privacy-safe lifecycle emitted by the rendered graph adapter for
/// organizer drag attempts. Conversation and Group identifiers deliberately
/// never cross this boundary; the async command result remains authoritative
/// for whether an accepted release actually persisted.
internal nonisolated enum OrganizerDropDestinationKind: String, Equatable, Sendable {
    case confirmedGroup
    case emptyCanvas
    case invalidTarget
}

internal nonisolated enum OrganizerDropLifecycleSignal: Equatable, Sendable {
    case intent(itemCount: Int)
    case highlight(itemCount: Int)
    case release(itemCount: Int,
                 destination: OrganizerDropDestinationKind,
                 hadVisibleHighlight: Bool)
    case cancelled(itemCount: Int)
}

/// Serializes the asynchronous metrics and mutation work associated with
/// rendered pointer drops. SpriteKit publishes lifecycle signals on the main
/// actor, but starting an independent `Task` for every signal allows actor
/// hops to reorder intent, highlight, release, and outcome. This coordinator
/// preserves producer order while still allowing each operation to suspend.
@MainActor
internal final class OrganizerDropMetricsCoordinator {
    private var tail: Task<Void, Never>?

    @discardableResult
    internal func enqueue(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let predecessor = tail
        let task = Task { @MainActor in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        tail = task
        return task
    }

    internal func waitForIdle() async {
        await tail?.value
    }
}

/// A rendered-state receipt produced only after SpriteKit has rebuilt or
/// updated its nodes and installed organizer accessibility descriptors.
/// Group and conversation identifiers stay process-local; metrics receive
/// aggregate counts only.
internal nonisolated struct OrganizerRenderedAccessibilityFrame: Codable,
                                                                    Equatable,
                                                                    Sendable {
    internal let x: Double
    internal let y: Double
    internal let width: Double
    internal let height: Double

    internal init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    internal var isFiniteAndNonEmpty: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite &&
            width > 0 && height > 0
    }
}

internal nonisolated struct OrganizerRenderedGraphSnapshot: Equatable, Sendable {
    /// Readiness and pointer evidence must describe the graph after its force
    /// simulation has stopped, not an intermediate frame emitted while the
    /// workspace is still moving.
    internal let isLayoutSettled: Bool
    internal let confirmedMemberCountsByGroupID: [String: Int]
    internal let filteredAccessibleConversationRawThreadIDs: Set<String>
    /// Process-local identities for every currently visible, frame-backed
    /// organizer conversation and confirmed Group. Benchmark readiness uses
    /// these sets to start timing only after the exact task targets are
    /// rendered and accessibility-selectable.
    internal let accessibleConversationRawThreadIDs: Set<String>
    internal let accessibleConfirmedGroupKeys: Set<String>
    /// Screen-space frames are retained only in the in-process receipt. The
    /// DEBUG benchmark may persist its synthetic IDs so native-pointer audit
    /// tooling can act on the exact marks that made readiness pass.
    internal let accessibleConversationFramesByRawThreadID:
        [String: OrganizerRenderedAccessibilityFrame]
    internal let accessibleConfirmedGroupFramesByGroupKey:
        [String: OrganizerRenderedAccessibilityFrame]
    internal let accessibilityScreenFrame: OrganizerRenderedAccessibilityFrame?
    /// Process-local exact membership state keyed by the frozen BetterMail
    /// Group key. This is consumed by the recorder's outcome evaluator but is
    /// never serialized into aggregate metrics.
    internal let confirmedRawThreadIDsByGroupKey: [String: Set<String>]

    internal init(
        isLayoutSettled: Bool = true,
        confirmedMemberCountsByGroupID: [String: Int],
        filteredAccessibleConversationRawThreadIDs: Set<String>,
        accessibleConversationRawThreadIDs: Set<String> = [],
        accessibleConfirmedGroupKeys: Set<String> = [],
        accessibleConversationFramesByRawThreadID:
            [String: OrganizerRenderedAccessibilityFrame] = [:],
        accessibleConfirmedGroupFramesByGroupKey:
            [String: OrganizerRenderedAccessibilityFrame] = [:],
        accessibilityScreenFrame: OrganizerRenderedAccessibilityFrame? = nil,
        confirmedRawThreadIDsByGroupKey: [String: Set<String>] = [:]
    ) {
        self.isLayoutSettled = isLayoutSettled
        self.confirmedMemberCountsByGroupID = confirmedMemberCountsByGroupID
        self.filteredAccessibleConversationRawThreadIDs = filteredAccessibleConversationRawThreadIDs
        self.accessibleConversationRawThreadIDs = accessibleConversationRawThreadIDs
        self.accessibleConfirmedGroupKeys = accessibleConfirmedGroupKeys
        self.accessibleConversationFramesByRawThreadID =
            accessibleConversationFramesByRawThreadID
        self.accessibleConfirmedGroupFramesByGroupKey =
            accessibleConfirmedGroupFramesByGroupKey
        self.accessibilityScreenFrame = accessibilityScreenFrame
        self.confirmedRawThreadIDsByGroupKey = confirmedRawThreadIDsByGroupKey
    }

    internal var filteredAccessibleConversationCount: Int {
        filteredAccessibleConversationRawThreadIDs.count
    }

    internal func containsAccessibleConversation(rawThreadID: String) -> Bool {
        filteredAccessibleConversationRawThreadIDs.contains(rawThreadID)
    }

    internal static func confirmedMemberCount(
        rawThreadIDs: [String],
        renderedThreadIDs: [String]
    ) -> Int {
        let authoritativeIDs = rawThreadIDs.isEmpty ? renderedThreadIDs : rawThreadIDs
        return Set(authoritativeIDs).count
    }
}

/// A privacy-safe receipt derived from consecutive rendered snapshots. Group
/// identifiers remain inside the graph process; metrics only receive the
/// aggregate number of members that became visible in confirmed Groups.
internal nonisolated struct OrganizerRenderedGraphReceipt: Equatable, Sendable {
    internal let snapshot: OrganizerRenderedGraphSnapshot
    internal let newlyVisibleConfirmedMemberCount: Int
    /// Monotonic, process-local identity for the graph search filter that
    /// produced this render. Async delivery must match the view model's
    /// current generation before it can close retrieval timing.
    internal let filterGeneration: UInt64

    internal func matchesFilterGeneration(_ generation: UInt64) -> Bool {
        filterGeneration == generation
    }
}

/// Render delivery stays synchronous on the main actor. Passing this
/// collection-backed value through several nested async SwiftUI closure thunks
/// corrupted the receipt before it reached the benchmark runtime in an
/// installed Debug build. Callers may start their own asynchronous work after
/// the receipt has been copied at this boundary.
internal typealias OrganizerRenderedGraphReceiptHandler = @MainActor (
    OrganizerRenderedGraphReceipt
) -> Void

/// Durable render-delta state owned by the graph view model rather than a
/// transient SwiftUI view value. This keeps receipts stable when the organizer
/// view recomposes while selection, inspector, or bottom chrome changes.
internal nonisolated struct OrganizerRenderedGraphVisibilityTracker: Sendable {
    private var previousConfirmedMemberCountsByGroupID: [String: Int]?

    internal mutating func receipt(
        for snapshot: OrganizerRenderedGraphSnapshot,
        filterGeneration: UInt64 = 0
    ) -> OrganizerRenderedGraphReceipt {
        defer {
            previousConfirmedMemberCountsByGroupID = snapshot.confirmedMemberCountsByGroupID
        }
        guard let previousConfirmedMemberCountsByGroupID else {
            return OrganizerRenderedGraphReceipt(
                snapshot: snapshot,
                newlyVisibleConfirmedMemberCount: 0,
                filterGeneration: filterGeneration
            )
        }
        let newlyVisibleCount = snapshot.confirmedMemberCountsByGroupID.reduce(into: 0) {
            total, entry in
            total += max(
                0,
                entry.value - (previousConfirmedMemberCountsByGroupID[entry.key] ?? 0)
            )
        }
        return OrganizerRenderedGraphReceipt(
            snapshot: snapshot,
            newlyVisibleConfirmedMemberCount: newlyVisibleCount,
            filterGeneration: filterGeneration
        )
    }
}

/// Pure pointer state shared by the SpriteKit adapter and geometry tests.
/// Distances are measured in screen points so drag/lasso thresholds remain
/// stable at every zoom level.
internal nonisolated struct OrganizerPointerStateMachine: Equatable, Sendable {
    // Three screen points still protects click selection while making the mark
    // feel grabbed as soon as the pointer commits to a drag. The previous
    // five-point gate was perceptible on small graph marks and high-refresh
    // displays.
    internal static let defaultMovementThreshold: CGFloat = 3

    private enum Phase: Equatable, Sendable {
        case idle
        case pendingNode(nodeID: String,
                         dragNodeIDs: [String],
                         origin: CGPoint,
                         previous: CGPoint,
                         modifiers: OrganizerPointerModifiers)
        case pendingCanvas(origin: CGPoint,
                           previous: CGPoint,
                           modifiers: OrganizerPointerModifiers)
        case dragging(nodeIDs: [String], origin: CGPoint, previous: CGPoint)
        case panning(origin: CGPoint, previous: CGPoint)
        case lasso(origin: CGPoint, previous: CGPoint, additive: Bool)
    }

    private var phase: Phase = .idle
    private let movementThreshold: CGFloat

    internal init(movementThreshold: CGFloat = Self.defaultMovementThreshold) {
        self.movementThreshold = max(0, movementThreshold)
    }

    internal mutating func begin(at location: CGPoint,
                                 hitNodeID: String?,
                                 selectedNodeIDs: Set<String>,
                                 modifiers: OrganizerPointerModifiers,
                                 lassoArmed: Bool = false) {
        if let hitNodeID {
            let dragIDs = selectedNodeIDs.contains(hitNodeID) && selectedNodeIDs.count > 1
                ? selectedNodeIDs.sorted()
                : [hitNodeID]
            phase = .pendingNode(nodeID: hitNodeID,
                                 dragNodeIDs: dragIDs,
                                 origin: location,
                                 previous: location,
                                 modifiers: modifiers)
        } else {
            var effectiveModifiers = modifiers
            if lassoArmed {
                effectiveModifiers.insert(.shift)
            }
            phase = .pendingCanvas(origin: location,
                                   previous: location,
                                   modifiers: effectiveModifiers)
        }
    }

    internal mutating func move(to location: CGPoint,
                                zoomScale: CGFloat) -> OrganizerPointerUpdate {
        let zoom = max(abs(zoomScale), 0.001)
        switch phase {
        case .idle:
            return .none
        case .pendingNode(_, let nodeIDs, let origin, _, _):
            guard screenDistance(from: origin, to: location, zoomScale: zoom) >= movementThreshold else {
                return .none
            }
            phase = .dragging(nodeIDs: nodeIDs, origin: origin, previous: location)
            return .drag(nodeIDs: nodeIDs, delta: vector(from: origin, to: location))
        case .pendingCanvas(let origin, _, let modifiers):
            guard screenDistance(from: origin, to: location, zoomScale: zoom) >= movementThreshold else {
                return .none
            }
            if modifiers.contains(.shift) {
                let additive = modifiers.contains(.command)
                phase = .lasso(origin: origin, previous: location, additive: additive)
                return .lasso(Self.normalizedRect(from: origin, to: location))
            }
            phase = .panning(origin: origin, previous: location)
            return .pan(delta: vector(from: origin, to: location))
        case .dragging(let nodeIDs, let origin, _):
            phase = .dragging(nodeIDs: nodeIDs, origin: origin, previous: location)
            return .drag(nodeIDs: nodeIDs, delta: vector(from: origin, to: location))
        case .panning(let origin, let previous):
            phase = .panning(origin: origin, previous: location)
            return .pan(delta: vector(from: previous, to: location))
        case .lasso(let origin, _, let additive):
            phase = .lasso(origin: origin, previous: location, additive: additive)
            return .lasso(Self.normalizedRect(from: origin, to: location))
        }
    }

    /// Camera panning changes the world point under the same physical pointer.
    /// Rebase after applying each camera delta so that change is not fed back
    /// into the next pointer sample as reverse movement.
    internal mutating func rebasePan(at location: CGPoint) {
        guard case .panning(let origin, _) = phase else { return }
        phase = .panning(origin: origin, previous: location)
    }

    internal mutating func end(at location: CGPoint) -> OrganizerPointerCompletion {
        defer { phase = .idle }
        switch phase {
        case .idle:
            return .none
        case .pendingNode(let nodeID, _, _, _, let modifiers):
            let intent: OrganizerPointerSelectionIntent
            if modifiers.contains(.command) {
                intent = .toggle
            } else if modifiers.contains(.shift) {
                intent = .range
            } else {
                intent = .replace
            }
            return .select(nodeID: nodeID, intent: intent)
        case .pendingCanvas:
            return .clearSelection
        case .dragging(let nodeIDs, let origin, _):
            return .finishDrag(nodeIDs: nodeIDs,
                               pointerLocation: location,
                               delta: vector(from: origin, to: location))
        case .panning:
            return .finishPan
        case .lasso(let origin, _, let additive):
            return .finishLasso(rect: Self.normalizedRect(from: origin, to: location),
                                additive: additive)
        }
    }

    internal mutating func cancel() {
        phase = .idle
    }

    internal static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x),
               y: min(start.y, end.y),
               width: abs(end.x - start.x),
               height: abs(end.y - start.y))
    }

    private func screenDistance(from start: CGPoint,
                                to end: CGPoint,
                                zoomScale: CGFloat) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y) * zoomScale
    }

    private func vector(from start: CGPoint, to end: CGPoint) -> CGVector {
        CGVector(dx: end.x - start.x, dy: end.y - start.y)
    }
}

internal nonisolated struct OrganizerSelectableRegion: Equatable, Sendable {
    internal let nodeID: String
    internal let center: CGPoint
    internal let radius: CGFloat

    internal init(nodeID: String, center: CGPoint, radius: CGFloat) {
        self.nodeID = nodeID
        self.center = center
        self.radius = max(0, radius)
    }
}

internal nonisolated enum OrganizerLassoGeometry {
    internal static func selectedNodeIDs(in rect: CGRect,
                                         regions: [OrganizerSelectableRegion]) -> [String] {
        guard !rect.isNull, !rect.isInfinite else { return [] }
        return regions
            .filter { intersects(rect: rect, circle: $0) }
            .map(\.nodeID)
            .sorted()
    }

    private static func intersects(rect: CGRect, circle: OrganizerSelectableRegion) -> Bool {
        let nearestX = min(max(circle.center.x, rect.minX), rect.maxX)
        let nearestY = min(max(circle.center.y, rect.minY), rect.maxY)
        return hypot(circle.center.x - nearestX, circle.center.y - nearestY) <= circle.radius
    }
}

internal nonisolated struct OrganizerMultiDragPlan: Equatable, Sendable {
    internal let anchorNodeID: String
    internal let initialPositions: [String: CGPoint]

    internal init?(anchorNodeID: String,
                   selectedNodeIDs: Set<String>,
                   positions: [String: CGPoint]) {
        let nodeIDs = selectedNodeIDs.contains(anchorNodeID) && selectedNodeIDs.count > 1
            ? selectedNodeIDs
            : [anchorNodeID]
        let retained = positions.filter { nodeIDs.contains($0.key) }
        guard retained[anchorNodeID] != nil, retained.count == nodeIDs.count else { return nil }
        self.anchorNodeID = anchorNodeID
        self.initialPositions = retained
    }

    internal var nodeIDs: [String] {
        initialPositions.keys.sorted()
    }

    internal func positions(byApplying delta: CGVector) -> [String: CGPoint] {
        initialPositions.mapValues {
            CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy)
        }
    }
}

internal nonisolated struct OrganizerConfirmedGroupDropCandidate: Equatable, Sendable {
    internal let groupID: String
    internal let center: CGPoint
    internal let hitRadius: CGFloat
    internal let hierarchyDepth: Int
    internal let visibleArea: CGFloat
    internal let isConfirmed: Bool

    internal init(groupID: String,
                  center: CGPoint,
                  hitRadius: CGFloat,
                  hierarchyDepth: Int,
                  visibleArea: CGFloat,
                  isConfirmed: Bool) {
        self.groupID = groupID
        self.center = center
        self.hitRadius = max(0, hitRadius)
        self.hierarchyDepth = max(0, hierarchyDepth)
        self.visibleArea = max(0, visibleArea)
        self.isConfirmed = isConfirmed
    }
}

internal nonisolated enum OrganizerDropTargetResolver {
    /// Returns at most one confirmed Group. Nested targets win by deepest
    /// hierarchy, then smallest visible area, then stable ID.
    internal static func resolve(at location: CGPoint,
                                 candidates: [OrganizerConfirmedGroupDropCandidate],
                                 excludingGroupIDs: Set<String> = [])
    -> OrganizerConfirmedGroupDropCandidate? {
        candidates
            .filter { candidate in
                candidate.isConfirmed
                    && !excludingGroupIDs.contains(candidate.groupID)
                    && hypot(candidate.center.x - location.x,
                             candidate.center.y - location.y) <= candidate.hitRadius
            }
            .sorted {
                if $0.hierarchyDepth != $1.hierarchyDepth {
                    return $0.hierarchyDepth > $1.hierarchyDepth
                }
                if $0.visibleArea != $1.visibleArea {
                    return $0.visibleArea < $1.visibleArea
                }
                return $0.groupID < $1.groupID
            }
            .first
    }
}

internal nonisolated enum OrganizerAccessibilityRole: String, Codable, Sendable {
    case conversation
    case confirmedGroup = "group"
    case suggestedGroup = "suggestion"
}

internal nonisolated enum OrganizerAccessibilityAction: String, Codable, Hashable, Sendable {
    case activate
    case addToSelection
    case removeFromSelection
    case moveSelectionHere
    case createGroupHere
}

internal nonisolated struct OrganizerAccessibilityDescriptor: Equatable, Sendable {
    internal let role: OrganizerAccessibilityRole
    internal let opaqueToken: String
    internal let label: String
    internal let hint: String
    internal let isSelected: Bool
    internal let actions: [OrganizerAccessibilityAction]

    internal init?(role: OrganizerAccessibilityRole,
                   opaqueToken: String,
                   label: String,
                   hint: String,
                   isSelected: Bool,
                   actions: [OrganizerAccessibilityAction]) {
        let token = opaqueToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !label.isEmpty else { return nil }
        self.role = role
        self.opaqueToken = token
        self.label = label
        self.hint = hint
        self.isSelected = isSelected
        self.actions = Array(Set(actions)).sorted { $0.rawValue < $1.rawValue }
    }

    internal var identifier: String {
        "bettermail.organizer.\(role.rawValue).\(opaqueToken)"
    }
}
