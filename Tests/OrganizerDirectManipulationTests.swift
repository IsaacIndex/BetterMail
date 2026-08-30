import CoreGraphics
import XCTest
@testable import BetterMail

private actor OrganizerDropTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class OrganizerDirectManipulationTests: XCTestCase {
    @MainActor
    func test_dropMetricsCoordinator_suspendedMutation_preservesProducerOrder() async {
        let prefixGate = OrganizerDropTestGate()
        let mutationGate = OrganizerDropTestGate()
        let prefixStarted = expectation(description: "Prefix started")
        let mutationStarted = expectation(description: "Mutation started")
        let coordinator = OrganizerDropMetricsCoordinator()
        var events: [String] = []

        coordinator.enqueue {
            prefixStarted.fulfill()
            await prefixGate.wait()
            events.append(contentsOf: ["action-start", "drop-intent"])
        }
        coordinator.enqueue {
            events.append("drop-highlight")
        }
        coordinator.enqueue {
            events.append("drop-release")
        }
        coordinator.enqueue {
            events.append("mutation-start")
            mutationStarted.fulfill()
            await mutationGate.wait()
            events.append(contentsOf: ["mutation-finish", "drop-outcome"])
        }
        coordinator.enqueue {
            events.append(contentsOf: ["next-action-start", "next-drop-intent"])
        }

        await fulfillment(of: [prefixStarted], timeout: 1)
        XCTAssertTrue(events.isEmpty)
        await prefixGate.open()
        await fulfillment(of: [mutationStarted], timeout: 1)
        XCTAssertEqual(events, [
            "action-start", "drop-intent", "drop-highlight", "drop-release",
            "mutation-start"
        ])

        await mutationGate.open()
        await coordinator.waitForIdle()
        XCTAssertEqual(events, [
            "action-start", "drop-intent", "drop-highlight", "drop-release",
            "mutation-start", "mutation-finish", "drop-outcome",
            "next-action-start", "next-drop-intent"
        ])
    }

    func test_renderedSnapshotMemberCountUsesOneIdentifierNamespace() {
        XCTAssertEqual(
            OrganizerRenderedGraphSnapshot.confirmedMemberCount(
                rawThreadIDs: ["raw-a", "raw-b", "raw-a"],
                renderedThreadIDs: ["graph-a", "graph-b"]
            ),
            2
        )
        XCTAssertEqual(
            OrganizerRenderedGraphSnapshot.confirmedMemberCount(
                rawThreadIDs: [],
                renderedThreadIDs: ["graph-a", "graph-b", "graph-a"]
            ),
            2
        )
    }

    func test_renderedVisibilityTrackerKeepsBaselineAndCountsOnlyPositiveMemberDeltas() {
        var tracker = OrganizerRenderedGraphVisibilityTracker()
        let initial = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: ["folder-a": 3, "folder-b": 0],
            filteredAccessibleConversationRawThreadIDs: ["raw-a", "raw-b", "raw-c", "raw-d"]
        )
        let unchanged = initial
        let regrouped = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: ["folder-a": 2, "folder-b": 1, "folder-c": 2],
            filteredAccessibleConversationRawThreadIDs: ["raw-a", "raw-b", "raw-c", "raw-d"]
        )
        let removalOnly = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: ["folder-a": 1, "folder-b": 1, "folder-c": 2],
            filteredAccessibleConversationRawThreadIDs: ["raw-a", "raw-b", "raw-c", "raw-d"]
        )

        XCTAssertEqual(tracker.receipt(for: initial).newlyVisibleConfirmedMemberCount, 0)
        XCTAssertEqual(tracker.receipt(for: unchanged).newlyVisibleConfirmedMemberCount, 0)
        XCTAssertEqual(tracker.receipt(for: regrouped).newlyVisibleConfirmedMemberCount, 3)
        XCTAssertEqual(tracker.receipt(for: removalOnly).newlyVisibleConfirmedMemberCount, 0)
    }

    func test_renderedReceiptCarriesExactFilterGeneration() {
        var tracker = OrganizerRenderedGraphVisibilityTracker()
        let snapshot = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: [:],
            filteredAccessibleConversationRawThreadIDs: []
        )

        let receipt = tracker.receipt(for: snapshot, filterGeneration: 41)

        XCTAssertTrue(receipt.matchesFilterGeneration(41))
        XCTAssertFalse(receipt.matchesFilterGeneration(42))
    }

    @MainActor
    func test_renderedReceiptHandlerCopiesIndirectValueBeforeAsyncDeferral() async {
        let firstSnapshot = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: ["folder:group-flat-00": 2],
            filteredAccessibleConversationRawThreadIDs: ["conversation-100-0000"],
            accessibleConversationRawThreadIDs: [
                "conversation-100-0000", "conversation-100-0001"
            ],
            accessibleConfirmedGroupKeys: ["group-flat-00"],
            confirmedRawThreadIDsByGroupKey: [
                "group-flat-00": ["conversation-100-0000", "conversation-100-0001"]
            ]
        )
        let secondSnapshot = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: ["folder:group-flat-00": 3],
            filteredAccessibleConversationRawThreadIDs: ["conversation-100-0002"],
            accessibleConversationRawThreadIDs: ["conversation-100-0002"],
            accessibleConfirmedGroupKeys: ["group-flat-00"],
            confirmedRawThreadIDsByGroupKey: [
                "group-flat-00": ["conversation-100-0002"]
            ]
        )
        var deferredCopies: [Task<OrganizerRenderedGraphSnapshot, Never>] = []
        let handler: OrganizerRenderedGraphReceiptHandler = { receipt in
            let copiedSnapshot = receipt.snapshot
            deferredCopies.append(Task { @MainActor in
                await Task.yield()
                return copiedSnapshot
            })
        }

        handler(OrganizerRenderedGraphReceipt(snapshot: firstSnapshot,
                                              newlyVisibleConfirmedMemberCount: 2,
                                              filterGeneration: 7))
        handler(OrganizerRenderedGraphReceipt(snapshot: secondSnapshot,
                                              newlyVisibleConfirmedMemberCount: 1,
                                              filterGeneration: 8))

        let deliveredFirst = await deferredCopies[0].value
        let deliveredSecond = await deferredCopies[1].value
        XCTAssertEqual(deliveredFirst, firstSnapshot)
        XCTAssertEqual(deliveredSecond, secondSnapshot)
    }

    func test_renderedSnapshotRetrievalRequiresExactAccessibleConversation() {
        let wrongResult = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: [:],
            filteredAccessibleConversationRawThreadIDs: ["conversation-100-0003"]
        )
        let exactResult = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: [:],
            filteredAccessibleConversationRawThreadIDs: [
                "conversation-100-0003",
                OrganizerMetricsRecorder.frozenRetrievalRawThreadID
            ]
        )

        XCTAssertFalse(wrongResult.containsAccessibleConversation(
            rawThreadID: OrganizerMetricsRecorder.frozenRetrievalRawThreadID
        ))
        XCTAssertTrue(exactResult.containsAccessibleConversation(
            rawThreadID: OrganizerMetricsRecorder.frozenRetrievalRawThreadID
        ))
        XCTAssertEqual(exactResult.filteredAccessibleConversationCount, 2)
    }

    func testRailDragPayload_normalizesDeduplicatesAndRoundTrips() throws {
        let payload = try XCTUnwrap(OrganizerRailDragPayload(
            rawThreadIDs: [" thread-b ", "thread-a", "thread-b", ""]
        ))

        XCTAssertEqual(payload.schemaVersion, OrganizerRailDragPayload.currentSchemaVersion)
        XCTAssertEqual(payload.rawThreadIDs, ["thread-a", "thread-b"])
        XCTAssertEqual(try OrganizerRailDragPayload.decode(payload.encoded()), payload)
        XCTAssertNil(OrganizerRailDragPayload(rawThreadIDs: [" ", "\n"]))
    }

    func testRailDragPayload_futureSchemaFailsClosed() throws {
        let data = try XCTUnwrap(
            "{\"schemaVersion\":999,\"rawThreadIDs\":[\"thread-a\"]}"
                .data(using: .utf8)
        )

        XCTAssertNil(try OrganizerRailDragPayload.decode(data))
    }

    func testPointerThreshold_isZoomCorrectAndKeepsClickIntent() {
        var machine = OrganizerPointerStateMachine(movementThreshold: 5)
        machine.begin(at: .zero,
                      hitNodeID: "a",
                      selectedNodeIDs: ["a", "b"],
                      modifiers: [.command])

        XCTAssertEqual(machine.move(to: CGPoint(x: 8, y: 0), zoomScale: 0.5), .none)
        XCTAssertEqual(machine.end(at: CGPoint(x: 8, y: 0)),
                       .select(nodeID: "a", intent: .toggle))
    }

    func testPointerShiftDrag_createsWorldCoordinateLasso() {
        var machine = OrganizerPointerStateMachine(movementThreshold: 4)
        machine.begin(at: CGPoint(x: 20, y: 30),
                      hitNodeID: nil,
                      selectedNodeIDs: [],
                      modifiers: [.shift, .command])

        XCTAssertEqual(machine.move(to: CGPoint(x: 10, y: 5), zoomScale: 1),
                       .lasso(CGRect(x: 10, y: 5, width: 10, height: 25)))
        XCTAssertEqual(machine.end(at: CGPoint(x: 8, y: 4)),
                       .finishLasso(rect: CGRect(x: 8, y: 4, width: 12, height: 26),
                                    additive: true))
    }

    func testArmedLassoWithoutShift_startsFromBlankCanvasAndPreservesCommandAdditive() {
        var machine = OrganizerPointerStateMachine(movementThreshold: 4)
        machine.begin(at: CGPoint(x: 20, y: 30),
                      hitNodeID: nil,
                      selectedNodeIDs: [],
                      modifiers: [.command],
                      lassoArmed: true)

        XCTAssertEqual(machine.move(to: CGPoint(x: 10, y: 5), zoomScale: 1),
                       .lasso(CGRect(x: 10, y: 5, width: 10, height: 25)))
        XCTAssertEqual(machine.end(at: CGPoint(x: 8, y: 4)),
                       .finishLasso(rect: CGRect(x: 8, y: 4, width: 12, height: 26),
                                    additive: true))
    }

    func testUnarmedBlankCanvasDrag_pansAndFinishesPan() {
        var machine = OrganizerPointerStateMachine(movementThreshold: 4)
        machine.begin(at: CGPoint(x: 20, y: 30),
                      hitNodeID: nil,
                      selectedNodeIDs: [],
                      modifiers: [],
                      lassoArmed: false)

        XCTAssertEqual(machine.move(to: CGPoint(x: 10, y: 5), zoomScale: 1),
                       .pan(delta: CGVector(dx: -10, dy: -25)))
        XCTAssertEqual(machine.end(at: CGPoint(x: 8, y: 4)), .finishPan)
    }

    func testArmedLasso_nodeOriginStillDragsSelectedNodes() {
        var machine = OrganizerPointerStateMachine(movementThreshold: 2)
        machine.begin(at: .zero,
                      hitNodeID: "b",
                      selectedNodeIDs: ["a", "b"],
                      modifiers: [],
                      lassoArmed: true)

        XCTAssertEqual(machine.move(to: CGPoint(x: 3, y: 4), zoomScale: 1),
                       .drag(nodeIDs: ["a", "b"], delta: CGVector(dx: 3, dy: 4)))
    }

    func testPointerSelectedNodeDrag_movesWholeSelectionInStableOrder() {
        var machine = OrganizerPointerStateMachine(movementThreshold: 2)
        machine.begin(at: .zero,
                      hitNodeID: "b",
                      selectedNodeIDs: ["c", "b", "a"],
                      modifiers: [])

        XCTAssertEqual(machine.move(to: CGPoint(x: 3, y: 4), zoomScale: 1),
                       .drag(nodeIDs: ["a", "b", "c"], delta: CGVector(dx: 3, dy: 4)))
        XCTAssertEqual(machine.end(at: CGPoint(x: 6, y: 8)),
                       .finishDrag(nodeIDs: ["a", "b", "c"],
                                   pointerLocation: CGPoint(x: 6, y: 8),
                                   delta: CGVector(dx: 6, dy: 8)))
    }

    func testLasso_intersectsNodeHitCirclesAndSortsIDs() {
        let selected = OrganizerLassoGeometry.selectedNodeIDs(
            in: CGRect(x: 0, y: 0, width: 10, height: 10),
            regions: [
                OrganizerSelectableRegion(nodeID: "z", center: CGPoint(x: 12, y: 5), radius: 2),
                OrganizerSelectableRegion(nodeID: "a", center: CGPoint(x: 5, y: 5), radius: 1),
                OrganizerSelectableRegion(nodeID: "outside", center: CGPoint(x: 20, y: 20), radius: 2)
            ]
        )
        XCTAssertEqual(selected, ["a", "z"])
    }

    func testMultiDragPlan_preservesRelativeOffsets() throws {
        let plan = try XCTUnwrap(OrganizerMultiDragPlan(
            anchorNodeID: "a",
            selectedNodeIDs: ["a", "b"],
            positions: ["a": CGPoint(x: 1, y: 2), "b": CGPoint(x: 5, y: 9)]
        ))
        XCTAssertEqual(plan.positions(byApplying: CGVector(dx: 3, dy: -2)),
                       ["a": CGPoint(x: 4, y: 0), "b": CGPoint(x: 8, y: 7)])
    }

    func testDropResolver_rejectsGhostAndChoosesDeepestSmallestStableTarget() throws {
        let candidates = [
            OrganizerConfirmedGroupDropCandidate(groupID: "outer",
                                                  center: .zero,
                                                  hitRadius: 50,
                                                  hierarchyDepth: 1,
                                                  visibleArea: 400,
                                                  isConfirmed: true),
            OrganizerConfirmedGroupDropCandidate(groupID: "ghost",
                                                  center: .zero,
                                                  hitRadius: 20,
                                                  hierarchyDepth: 9,
                                                  visibleArea: 10,
                                                  isConfirmed: false),
            OrganizerConfirmedGroupDropCandidate(groupID: "deep-large",
                                                  center: .zero,
                                                  hitRadius: 20,
                                                  hierarchyDepth: 2,
                                                  visibleArea: 100,
                                                  isConfirmed: true),
            OrganizerConfirmedGroupDropCandidate(groupID: "deep-small",
                                                  center: .zero,
                                                  hitRadius: 20,
                                                  hierarchyDepth: 2,
                                                  visibleArea: 50,
                                                  isConfirmed: true)
        ]
        let target = try XCTUnwrap(OrganizerDropTargetResolver.resolve(at: .zero,
                                                                       candidates: candidates))
        XCTAssertEqual(target.groupID, "deep-small")
        XCTAssertNil(OrganizerDropTargetResolver.resolve(at: .zero,
                                                         candidates: candidates,
                                                         excludingGroupIDs: ["outer", "deep-large", "deep-small"]))
    }

    func testAccessibilityDescriptor_usesOpaqueStableIdentifierAndDeduplicatedActions() throws {
        let descriptor = try XCTUnwrap(OrganizerAccessibilityDescriptor(
            role: .conversation,
            opaqueToken: "gsp-v1-opaque",
            label: "Quarterly planning",
            hint: "Select this conversation",
            isSelected: true,
            actions: [.activate, .activate, .removeFromSelection]
        ))
        XCTAssertEqual(descriptor.identifier,
                       "bettermail.organizer.conversation.gsp-v1-opaque")
        XCTAssertEqual(descriptor.actions, [.activate, .removeFromSelection])
        XCTAssertTrue(descriptor.isSelected)
    }
}
