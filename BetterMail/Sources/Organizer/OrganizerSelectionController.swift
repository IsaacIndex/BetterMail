import Foundation

/// Pure effective-conversation selection semantics shared by a future rail
/// and graph adapter. It returns new values instead of mutating application
/// state; `ThreadCanvasViewModel` remains responsible for applying the final
/// IDs to the live mailbox/thread selection.
internal nonisolated struct OrganizerSelectionController: Equatable, Sendable {
    /// Resolves rail IDs and Graph node IDs without importing either UI
    /// framework. Graph thread nodes use the existing `thread:<raw-id>` form;
    /// message nodes need the supplied mapping because a message alone does
    /// not identify an effective conversation after manual grouping.
    internal struct Normalizer: Equatable, Sendable {
        internal let validConversationIDs: Set<String>
        internal let aliases: [String: String]
        internal let graphNodeToConversationID: [String: String]

        internal init(validConversationIDs: Set<String> = [],
                      aliases: [String: String] = [:],
                      graphNodeToConversationID: [String: String] = [:]) {
            self.validConversationIDs = Set(validConversationIDs.compactMap(Self.normalizedID))
            self.aliases = Self.normalizedMap(aliases)
            self.graphNodeToConversationID = Self.normalizedMap(graphNodeToConversationID)
        }

        internal func railConversationID(from rawID: String?) -> String? {
            normalize(rawID, source: .rail)
        }

        internal func graphConversationID(from rawID: String?) -> String? {
            normalize(rawID, source: .graph)
        }

        internal func normalize(_ rawID: String?) -> String? {
            normalize(rawID, source: .generic)
        }

        private enum Source {
            case rail
            case graph
            case generic
        }

        private func normalize(_ rawID: String?, source: Source) -> String? {
            guard let rawID = Self.normalizedID(rawID) else { return nil }

            let mappedID: String?
            switch source {
            case .graph:
                mappedID = graphNodeToConversationID[rawID] ?? aliases[rawID]
            case .rail, .generic:
                mappedID = aliases[rawID]
            }
            let candidate = Self.normalizedID(mappedID ?? rawID)

            if source == .graph,
               mappedID == nil,
               ["message:", "folder:", "suggestion:", "remaining:"].contains(where: rawID.hasPrefix) {
                return nil
            }

            if let candidate,
               validConversationIDs.isEmpty || validConversationIDs.contains(candidate) {
                return candidate
            }

            guard source == .graph,
                  rawID.hasPrefix("thread:"),
                  let stripped = Self.normalizedID(String(rawID.dropFirst("thread:".count))),
                  validConversationIDs.isEmpty || validConversationIDs.contains(stripped) else {
                return nil
            }
            return stripped
        }

        private static func normalizedMap(_ map: [String: String]) -> [String: String] {
            map.reduce(into: [String: String]()) { result, entry in
                guard let key = normalizedID(entry.key),
                      let value = normalizedID(entry.value) else { return }
                result[key] = value
            }
        }

        private static func normalizedID(_ rawID: String?) -> String? {
            guard let rawID else { return nil }
            let value = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    internal private(set) var selectedConversationIDs: Set<String>
    internal private(set) var focusID: String?
    internal private(set) var rangeAnchorID: String?
    internal private(set) var focusOrder: [String]

    internal init(selectedConversationIDs: Set<String> = [],
                  focusID: String? = nil,
                  rangeAnchorID: String? = nil,
                  focusOrder: [String] = []) {
        let normalizedOrder = Self.uniqueIDs(focusOrder)
        let orderSet = Set(normalizedOrder)
        let normalizedSelection = Set(selectedConversationIDs.compactMap(Self.normalizedID))
        self.focusOrder = normalizedOrder
        self.selectedConversationIDs = orderSet.isEmpty
            ? normalizedSelection
            : normalizedSelection.intersection(orderSet)
        self.focusID = Self.normalizedID(focusID)
        self.rangeAnchorID = Self.normalizedID(rangeAnchorID)
        self = reconciled(availableConversationIDs: orderSet.isEmpty ? nil : orderSet,
                          focusOrder: normalizedOrder)
    }

    internal var selectedCount: Int {
        selectedConversationIDs.count
    }

    internal var selectedIDsInFocusOrder: [String] {
        let ordered = focusOrder.filter(selectedConversationIDs.contains)
        let orderedSet = Set(ordered)
        return ordered + selectedConversationIDs.subtracting(orderedSet).sorted()
    }

    /// Creates a deterministic keyboard/VoiceOver order. Rail IDs lead so
    /// keyboard traversal starts with the stable scanning surface; graph IDs
    /// add any conversation not already present without duplicating it.
    internal static func focusOrder(railConversationIDs: [String],
                                    graphConversationIDs: [String] = []) -> [String] {
        uniqueIDs(railConversationIDs + graphConversationIDs)
    }

    internal static func makeFocusOrder(railConversationIDs: [String],
                                        graphConversationIDs: [String] = []) -> [String] {
        focusOrder(railConversationIDs: railConversationIDs,
                   graphConversationIDs: graphConversationIDs)
    }

    internal func updatingFocusOrder(_ newOrder: [String]) -> OrganizerSelectionController {
        reconciled(availableConversationIDs: Set(Self.uniqueIDs(newOrder)),
                    focusOrder: newOrder)
    }

    /// Selects one normalized conversation. A plain click replaces the
    /// selection and establishes a new range anchor. A command click toggles
    /// only that conversation and leaves an existing anchor intact.
    internal func selectingConversation(id rawID: String,
                                        command: Bool) -> OrganizerSelectionController {
        guard let id = Self.normalizedID(rawID) else { return self }
        var next = self
        next.ensureFocusContains(id)
        if command {
            if next.selectedConversationIDs.contains(id) {
                next.selectedConversationIDs.remove(id)
            } else {
                next.selectedConversationIDs.insert(id)
            }
            next.focusID = id
            if next.rangeAnchorID == nil {
                next.rangeAnchorID = id
            }
        } else {
            next.selectedConversationIDs = [id]
            next.focusID = id
            next.rangeAnchorID = id
        }
        if next.selectedConversationIDs.isEmpty {
            next.focusID = nil
            next.rangeAnchorID = nil
        }
        return next
    }

    internal func selectingRailID(_ rawID: String?,
                                 command: Bool,
                                 normalizingWith normalizer: Normalizer) -> OrganizerSelectionController {
        guard let id = normalizer.railConversationID(from: rawID) else { return self }
        return selectingConversation(id: id, command: command)
    }

    internal func selectingGraphNodeID(_ rawID: String?,
                                      command: Bool,
                                      normalizingWith normalizer: Normalizer) -> OrganizerSelectionController {
        guard let id = normalizer.graphConversationID(from: rawID) else { return self }
        return selectingConversation(id: id, command: command)
    }

    /// Extends selection inclusively from the deterministic range anchor. If
    /// the anchor was pruned, the focused ID (or target ID) is the safe
    /// one-item fallback.
    internal func selectingRange(to rawID: String) -> OrganizerSelectionController {
        guard let targetID = Self.normalizedID(rawID) else { return self }
        var next = self
        next.ensureFocusContains(targetID)
        let order = Self.uniqueIDs(next.focusOrder)
        guard !order.isEmpty,
              let targetIndex = order.firstIndex(of: targetID) else {
            next.selectedConversationIDs = [targetID]
            next.focusID = targetID
            next.rangeAnchorID = targetID
            return next
        }
        let anchorID = next.rangeAnchorID.flatMap { order.contains($0) ? $0 : nil }
            ?? next.focusID.flatMap { order.contains($0) ? $0 : nil }
            ?? targetID
        guard let anchorIndex = order.firstIndex(of: anchorID) else {
            next.selectedConversationIDs = [targetID]
            next.focusID = targetID
            next.rangeAnchorID = targetID
            return next
        }
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        next.selectedConversationIDs = Set(order[lower...upper])
        next.focusID = targetID
        next.rangeAnchorID = anchorID
        return next
    }

    /// Applies a lasso result as either a replacement or an additive selection.
    /// The Set input is intentionally normalized into focus order before
    /// focus/anchor values are chosen, so identical geometric results cannot
    /// yield random focus.
    internal func applyingLasso(_ rawIDs: Set<String>,
                               normalizingWith normalizer: Normalizer? = nil,
                               focusID requestedFocusID: String? = nil,
                               additive: Bool = false) -> OrganizerSelectionController {
        let normalizedIDs = Set(rawIDs.compactMap { rawID in
            normalizer?.normalize(rawID) ?? Self.normalizedID(rawID)
        })
        var next = self
        next.selectedConversationIDs = additive
            ? next.selectedConversationIDs.union(normalizedIDs)
            : normalizedIDs
        next.focusOrder = Self.uniqueIDs(next.focusOrder + normalizedIDs.sorted())

        guard !next.selectedConversationIDs.isEmpty else {
            next.focusID = nil
            next.rangeAnchorID = nil
            return next
        }

        let orderedSelection = next.focusOrder.filter(next.selectedConversationIDs.contains)
        let focus = requestedFocusID.flatMap { candidate in
            next.selectedConversationIDs.contains(candidate) ? candidate : nil
        } ?? orderedSelection.first
            ?? next.selectedConversationIDs.sorted().first
            ?? ""
        next.focusID = focus
        next.rangeAnchorID = focus
        return next
    }

    internal func applyingLassoGraphNodeIDs(_ rawIDs: Set<String>,
                                            normalizingWith normalizer: Normalizer,
                                            focusGraphNodeID: String? = nil,
                                            additive: Bool = false) -> OrganizerSelectionController {
        let focusID = focusGraphNodeID.flatMap { normalizer.graphConversationID(from: $0) }
        return applyingLasso(Set(rawIDs.compactMap { normalizer.graphConversationID(from: $0) }),
                            normalizingWith: nil,
                            focusID: focusID,
                            additive: additive)
    }

    /// Removes selections that are no longer valid in a refreshed scope and
    /// repairs focus/anchor deterministically from the new visible order.
    internal func reconciled(availableConversationIDs: Set<String>?,
                             focusOrder newOrder: [String]? = nil) -> OrganizerSelectionController {
        var next = self
        if let newOrder {
            next.focusOrder = Self.uniqueIDs(newOrder)
        } else {
            next.focusOrder = Self.uniqueIDs(next.focusOrder)
        }

        let available: Set<String>
        if let availableConversationIDs {
            available = Set(availableConversationIDs.compactMap(Self.normalizedID))
            next.focusOrder = next.focusOrder.filter(available.contains)
        } else {
            available = next.focusOrder.isEmpty
                ? next.selectedConversationIDs
                : Set(next.focusOrder)
        }
        next.selectedConversationIDs = next.selectedConversationIDs.intersection(available)

        guard !next.selectedConversationIDs.isEmpty else {
            next.focusID = nil
            next.rangeAnchorID = nil
            return next
        }

        if let focusID = next.focusID,
           available.contains(focusID) {
            next.focusID = focusID
        } else {
            next.focusID = next.focusOrder.first(where: next.selectedConversationIDs.contains)
                ?? next.selectedConversationIDs.sorted().first
        }
        if let anchorID = next.rangeAnchorID,
           available.contains(anchorID) {
            next.rangeAnchorID = anchorID
        } else {
            next.rangeAnchorID = next.focusID
        }
        return next
    }

    private mutating func ensureFocusContains(_ id: String) {
        guard !focusOrder.contains(id) else { return }
        focusOrder.append(id)
    }

    private static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { rawID in
            guard let id = normalizedID(rawID), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    private static func normalizedID(_ rawID: String?) -> String? {
        guard let rawID else { return nil }
        let value = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
