import AppKit
import CoreGraphics
import Foundation
import SpriteKit
import XCTest
@testable import BetterMail

@MainActor
final class ObsidianGraphMultiDragTests: XCTestCase {
    func test_dragBenchmark_fixedPointerWorkload_coalescesFullGraphWork() throws {
        let fixture = try XCTUnwrap(OrganizerBenchmarkFixture.make(nodeCount: 100))
        let roots = JWZThreader().buildThreads(from: fixture.emailMessages()).roots
        let graph = GraphData.make(roots: roots,
                                   folders: fixture.threadFolders(),
                                   branchLimit: 24,
                                   branchBatchSize: 8,
                                   perNodeBranchPageSize: 6,
                                   messageLimitPerBranch: 5)
        var samples: [Double] = []
        var recordedMetrics: ObsidianGraphSceneWorkMetrics?

        for sampleIndex in 0..<5 {
            let view = GraphSKView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 760))
            let scene = ObsidianGraphScene(size: view.bounds.size)
            view.presentScene(scene)
            configureBenchmarkScene(scene, data: graph)

            let sourceNode = try XCTUnwrap(scene.children
                .compactMap { $0 as? ObsidianGraphSceneNode }
                .first { $0.kind == .thread })
            let targetNode = try XCTUnwrap(scene.children
                .compactMap { $0 as? ObsidianGraphSceneNode }
                .first { node in
                    graph.groupingByID[node.graphID]?.kind == .folder
                })
            scene.onMoveThreadsToFolder = { _, _ in }
            scene.mouseDown(with: try pointerEvent(type: .leftMouseDown,
                                                   location: sourceNode.position,
                                                   timestamp: 0))
            scene.resetWorkMetricsForTesting()

            let clock = ContinuousClock()
            let start = clock.now
            for frameIndex in 0..<30 {
                for pointerIndex in 1...4 {
                    let progress = CGFloat(frameIndex * 4 + pointerIndex) / 120
                    let location = CGPoint(
                        x: sourceNode.position.x + (targetNode.position.x - sourceNode.position.x) * progress,
                        y: sourceNode.position.y + (targetNode.position.y - sourceNode.position.y) * progress
                    )
                    scene.mouseDragged(with: try pointerEvent(
                        type: .leftMouseDragged,
                        location: location,
                        timestamp: Double(frameIndex * 4 + pointerIndex) / 240
                    ))
                }
                scene.update(Double(frameIndex + 1) / 60)
            }
            scene.mouseUp(with: try pointerEvent(type: .leftMouseUp,
                                                 location: targetNode.position,
                                                 timestamp: 0.5))
            let duration = start.duration(to: clock.now)
            samples.append(milliseconds(duration))
            recordedMetrics = scene.workMetrics
            scene.teardownForRemoval()

            if sampleIndex == 0 {
                XCTAssertLessThanOrEqual(recordedMetrics?.fullRenderPassCount ?? .max, 3)
                XCTAssertLessThanOrEqual(recordedMetrics?.dragRenderPassCount ?? .max, 30)
                XCTAssertEqual(recordedMetrics?.forceStepCount, 0)
                XCTAssertGreaterThan(recordedMetrics?.dragSimulationStepCount ?? 0, 0)
                XCTAssertLessThanOrEqual(recordedMetrics?.dragSimulationStepCount ?? .max, 30)
                XCTAssertLessThanOrEqual(
                    recordedMetrics?.dragCollisionCheckCount ?? .max,
                    graph.allNodeIDs.count * 30
                )
                XCTAssertLessThanOrEqual(recordedMetrics?.accessibilityRefreshCount ?? .max, 3)
            }
        }

        let median = samples.sorted()[samples.count / 2]
        let metrics = try XCTUnwrap(recordedMetrics)
        print(String(
            format: "BETTERMAIL_DRAG_BENCHMARK median_ms=%.3f full_renders=%d drag_renders=%d force_steps=%d drag_simulation_steps=%d drag_collision_checks=%d accessibility_refreshes=%d",
            median,
            metrics.fullRenderPassCount,
            metrics.dragRenderPassCount,
            metrics.forceStepCount,
            metrics.dragSimulationStepCount,
            metrics.dragCollisionCheckCount,
            metrics.accessibilityRefreshCount
        ))
    }

    func test_sceneDrag_whenPointerStartsOnYou_preservesPlacementAfterRelease() throws {
        let graph = makeGraph(threadIDs: ["first"])
        let view = GraphSKView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let scene = ObsidianGraphScene(size: view.bounds.size)
        view.presentScene(scene)
        configureBenchmarkScene(scene, data: graph)
        let youNode = try XCTUnwrap(scene.children
            .compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == GraphCenter.you.id })
        let center = CGPoint(x: 400, y: 300)
        assertPoint(youNode.position, center)
        for frameIndex in 0...240 {
            scene.update(Double(frameIndex + 1) / 60)
        }
        scene.resetWorkMetricsForTesting()

        scene.mouseDown(with: try pointerEvent(type: .leftMouseDown,
                                               location: center,
                                               timestamp: 0))
        scene.mouseDragged(with: try pointerEvent(type: .leftMouseDragged,
                                                  location: CGPoint(x: 160, y: 120),
                                                  timestamp: 1.0 / 60.0))
        scene.update(1.0 / 60.0)
        scene.mouseUp(with: try pointerEvent(type: .leftMouseUp,
                                             location: CGPoint(x: 160, y: 120),
                                             timestamp: 2.0 / 60.0))
        scene.update(1)

        assertPoint(youNode.position, CGPoint(x: 160, y: 120))
        XCTAssertEqual(scene.workMetrics.dragRenderPassCount, 1)
        XCTAssertEqual(scene.workMetrics.forceStepCount, 0)
        scene.teardownForRemoval()
    }

    func test_sceneDrag_afterRelease_refreshesAccessibilityGeometry() throws {
        let graph = makeGraph(threadIDs: ["first"])
        let view = GraphSKView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let scene = ObsidianGraphScene(size: view.bounds.size)
        view.presentScene(scene)
        configureBenchmarkScene(scene, data: graph)
        let threadID = GraphData.threadNodeID(for: "first")
        let threadNode = try XCTUnwrap(scene.children
            .compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == threadID })
        let initialFrame = threadNode.accessibilityFrame
        let target = CGPoint(x: threadNode.position.x + 110,
                             y: threadNode.position.y + 70)
        scene.resetWorkMetricsForTesting()

        scene.mouseDown(with: try pointerEvent(type: .leftMouseDown,
                                               location: threadNode.position,
                                               timestamp: 0))
        scene.mouseDragged(with: try pointerEvent(type: .leftMouseDragged,
                                                  location: target,
                                                  timestamp: 1.0 / 60.0))
        scene.update(1.0 / 60.0)
        scene.mouseUp(with: try pointerEvent(type: .leftMouseUp,
                                             location: target,
                                             timestamp: 2.0 / 60.0))

        XCTAssertNotEqual(threadNode.accessibilityFrame, initialFrame)
        XCTAssertGreaterThanOrEqual(scene.workMetrics.accessibilityRefreshCount, 1)
        XCTAssertLessThanOrEqual(scene.workMetrics.accessibilityRefreshCount, 2)
        scene.teardownForRemoval()
    }

    func test_sceneDrag_overConfirmedGroup_preservesLifecycleOrder() throws {
        let folder = ThreadFolder(id: "work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: ["foldered"],
                                  parentID: nil)
        let graph = GraphData.make(
            roots: [makeThread(rootID: "foldered"), makeThread(rootID: "loose")],
            folders: [folder],
            folderMembershipByThreadID: ["foldered": folder.id],
            now: Date(timeIntervalSince1970: 10_000)
        )
        let view = GraphSKView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let scene = ObsidianGraphScene(size: view.bounds.size)
        view.presentScene(scene)
        configureBenchmarkScene(scene, data: graph)
        let sourceID = GraphData.threadNodeID(for: "loose")
        let groupID = try XCTUnwrap(graph.groupings.first?.id)
        let sourceNode = try XCTUnwrap(scene.children
            .compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == sourceID })
        let targetNode = try XCTUnwrap(scene.children
            .compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == groupID })
        var lifecycle: [OrganizerDropLifecycleSignal] = []
        scene.onDropLifecycle = { lifecycle.append($0) }
        scene.onMoveThreadsToFolder = { _, _ in }

        scene.mouseDown(with: try pointerEvent(type: .leftMouseDown,
                                               location: sourceNode.position,
                                               timestamp: 0))
        scene.mouseDragged(with: try pointerEvent(type: .leftMouseDragged,
                                                  location: targetNode.position,
                                                  timestamp: 1.0 / 60.0))
        scene.update(1.0 / 60.0)
        scene.mouseUp(with: try pointerEvent(type: .leftMouseUp,
                                             location: targetNode.position,
                                             timestamp: 2.0 / 60.0))

        XCTAssertEqual(lifecycle, [
            .intent(itemCount: 1),
            .highlight(itemCount: 1),
            .release(itemCount: 1,
                     destination: .confirmedGroup,
                     hadVisibleHighlight: true)
        ])
        scene.teardownForRemoval()
    }

    func testAccessibilityIndex_indexes500ConversationFixtureAndFiltersSelection() throws {
        let fixture = try XCTUnwrap(OrganizerBenchmarkFixture.make(nodeCount: 500))
        let threadResult = JWZThreader().buildThreads(from: fixture.emailMessages())
        let graph = GraphData.make(roots: threadResult.roots,
                                   folders: fixture.threadFolders())
        let index = GraphSceneLookupIndex(data: graph)
        let selectedThreadIDs = Set(graph.threads.prefix(15).map(\.id))
        let selectedMessageIDs = Set(graph.messages.prefix(5).map(\.id))
        let selectedConversationIDs = selectedThreadIDs.union(selectedMessageIDs)
        let selectedGroupID = try XCTUnwrap(graph.groupings.first?.id)
        let suppliedSelection = selectedConversationIDs.union([selectedGroupID, "missing"])

        XCTAssertEqual(index.threadByID.count, 500)
        XCTAssertEqual(index.groupingByID.count, 8)
        XCTAssertEqual(Set(index.messageByID.keys), Set(graph.messages.map(\.id)))
        XCTAssertEqual(Set(index.remainingBranchByID.keys),
                       Set(graph.remainingBranches.map(\.id)))
        XCTAssertEqual(index.eligibleDragNodeIDs(from: suppliedSelection),
                       selectedConversationIDs)
        XCTAssertEqual(index.visualDragNodeIDs(from: suppliedSelection),
                       selectedConversationIDs.union([selectedGroupID]))
    }

    func testScene_draggingConfirmedFolderMovesVisuallyWithoutConversationMutation() throws {
        let folder = ThreadFolder(id: "work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: ["foldered"],
                                  parentID: nil)
        let graph = GraphData.make(
            roots: [makeThread(rootID: "foldered"), makeThread(rootID: "loose")],
            folders: [folder],
            folderMembershipByThreadID: ["foldered": folder.id],
            now: Date(timeIntervalSince1970: 10_000)
        )
        let view = GraphSKView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let scene = ObsidianGraphScene(size: view.bounds.size)
        view.presentScene(scene)
        configureBenchmarkScene(scene, data: graph)
        let groupID = try XCTUnwrap(graph.groupings.first?.id)
        let groupNode = try XCTUnwrap(scene.children
            .compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.graphID == groupID })
        let start = groupNode.position
        let target = CGPoint(x: start.x + 120, y: start.y + 70)
        var moveCallCount = 0
        var createCallCount = 0
        scene.onMoveThreadsToFolder = { _, _ in moveCallCount += 1 }
        scene.onCreateGroupAtCanvasPoint = { _, _, _ in createCallCount += 1 }
        scene.resetWorkMetricsForTesting()

        scene.mouseDown(with: try pointerEvent(type: .leftMouseDown,
                                               location: start,
                                               timestamp: 0))
        scene.mouseDragged(with: try pointerEvent(type: .leftMouseDragged,
                                                  location: target,
                                                  timestamp: 1.0 / 60.0))
        scene.update(1.0 / 60.0)
        XCTAssertEqual(scene.preferredFramesPerSecond, ObsidianGraphScene.activeFramesPerSecond)
        scene.mouseUp(with: try pointerEvent(type: .leftMouseUp,
                                             location: target,
                                             timestamp: 2.0 / 60.0))

        assertPoint(groupNode.position, target)
        XCTAssertEqual(moveCallCount, 0)
        XCTAssertEqual(createCallCount, 0)
        XCTAssertEqual(scene.workMetrics.forceStepCount, 0)
        XCTAssertEqual(scene.workMetrics.dragSimulationStepCount, 1)
        scene.teardownForRemoval()
    }

    func testMultiDrag_pinsMovesAndReleasesEverySelectedNode() throws {
        let graph = makeGraph(threadIDs: ["first", "second"])
        let firstID = GraphData.threadNodeID(for: "first")
        let secondID = GraphData.threadNodeID(for: "second")
        let positions = [firstID: CGPoint(x: 100, y: 120),
                         secondID: CGPoint(x: 180, y: 220)]
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 800, height: 600), preserving: positions)

        simulator.beginDragging(nodeIDs: [firstID, secondID])
        XCTAssertTrue(simulator.nodesByID[firstID]?.isPinned ?? false)
        XCTAssertTrue(simulator.nodesByID[secondID]?.isPinned ?? false)

        let targets = [firstID: CGPoint(x: 260, y: 160),
                       secondID: CGPoint(x: 340, y: 260)]
        simulator.drag(nodePositions: targets)
        assertPoint(simulator.nodesByID[firstID]?.position, targets[firstID])
        assertPoint(simulator.nodesByID[secondID]?.position, targets[secondID])

        simulator.endDragging(nodePositions: targets)
        XCTAssertFalse(simulator.nodesByID[firstID]?.isPinned ?? true)
        XCTAssertFalse(simulator.nodesByID[secondID]?.isPinned ?? true)
        assertPoint(simulator.nodesByID[firstID]?.position, targets[firstID])
        assertPoint(simulator.nodesByID[secondID]?.position, targets[secondID])
    }

    func testMultiDrag_preservesRelativeOffsetsWhenTranslatedTogether() throws {
        let graph = makeGraph(threadIDs: ["first", "second"])
        let firstID = GraphData.threadNodeID(for: "first")
        let secondID = GraphData.threadNodeID(for: "second")
        let firstStart = CGPoint(x: 120, y: 150)
        let secondStart = CGPoint(x: 205, y: 275)
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph,
                        size: CGSize(width: 800, height: 600),
                        preserving: [firstID: firstStart, secondID: secondStart])

        simulator.beginDragging(nodeIDs: [firstID, secondID])
        let delta = CGVector(dx: 74, dy: -38)
        let targets = [firstID: translated(firstStart, by: delta),
                       secondID: translated(secondStart, by: delta)]
        simulator.drag(nodePositions: targets)

        XCTAssertEqual(simulator.nodesByID[secondID]!.position.x - simulator.nodesByID[firstID]!.position.x,
                       secondStart.x - firstStart.x,
                       accuracy: 0.001)
        XCTAssertEqual(simulator.nodesByID[secondID]!.position.y - simulator.nodesByID[firstID]!.position.y,
                       secondStart.y - firstStart.y,
                       accuracy: 0.001)
        simulator.endDragging(nodePositions: targets)
    }

    func testMultiDrag_ignoresMissingIDsAndMissingPositionsSafely() throws {
        let graph = makeGraph(threadIDs: ["first"])
        let firstID = GraphData.threadNodeID(for: "first")
        let start = CGPoint(x: 140, y: 190)
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 800, height: 600), preserving: [firstID: start])

        simulator.beginDragging(nodeIDs: [firstID, "missing"], keepingStationary: ["missing"])
        XCTAssertTrue(simulator.nodesByID[firstID]?.isPinned ?? false)
        simulator.drag(nodePositions: ["missing": CGPoint(x: 900, y: 900)])
        assertPoint(simulator.nodesByID[firstID]?.position, start)
        simulator.endDragging(nodePositions: ["missing": CGPoint(x: 1, y: 1)])
        XCTAssertFalse(simulator.nodesByID[firstID]?.isPinned ?? true)

        simulator.beginDragging(nodeIDs: ["missing"])
        simulator.drag(nodePositions: ["missing": CGPoint(x: 2, y: 2)])
        simulator.endDragging(nodePositions: ["missing": CGPoint(x: 3, y: 3)])
        XCTAssertFalse(simulator.nodesByID[firstID]?.isPinned ?? true)
        assertPoint(simulator.nodesByID[firstID]?.position, start)
    }

    func testMultiDrag_releasesStationaryGroupAfterDrop() throws {
        let folder = ThreadFolder(id: "work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: ["first"],
                                  parentID: nil)
        let graph = GraphData.make(roots: [makeThread(rootID: "first")],
                                   folders: [folder],
                                   folderMembershipByThreadID: ["first": folder.id],
                                   now: Date(timeIntervalSince1970: 10_000))
        let groupID = try XCTUnwrap(graph.groupings.first?.id)
        let draggedID = GraphData.threadNodeID(for: "first")
        let groupStart = CGPoint(x: 110, y: 120)
        let draggedStart = CGPoint(x: 250, y: 260)
        let draggedTarget = CGPoint(x: 310, y: 290)
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph,
                        size: CGSize(width: 800, height: 600),
                        preserving: [groupID: groupStart, draggedID: draggedStart])

        simulator.beginDragging(nodeIDs: [draggedID], keepingStationary: [groupID])
        XCTAssertTrue(simulator.nodesByID[groupID]?.isPinned ?? false)
        simulator.drag(nodePositions: [draggedID: draggedTarget])
        assertPoint(simulator.nodesByID[groupID]?.position, groupStart)
        simulator.endDragging(nodePositions: [draggedID: draggedTarget])

        XCTAssertFalse(simulator.nodesByID[groupID]?.isPinned ?? true)
        XCTAssertFalse(simulator.nodesByID[draggedID]?.isPinned ?? true)
        assertPoint(simulator.nodesByID[groupID]?.position, groupStart)
        assertPoint(simulator.nodesByID[draggedID]?.position, draggedTarget)
    }

    func testDragReaction_movesNearbyNonFolderNodesButLeavesFolderAnchorsStationary() throws {
        let folder = ThreadFolder(id: "work",
                                  title: "Work",
                                  color: .defaultNewFolder,
                                  threadIDs: ["foldered"],
                                  parentID: nil)
        let graph = GraphData.make(
            roots: [makeThread(rootID: "dragged"),
                    makeThread(rootID: "nearby"),
                    makeThread(rootID: "distant"),
                    makeThread(rootID: "foldered")],
            folders: [folder],
            folderMembershipByThreadID: ["foldered": folder.id],
            now: Date(timeIntervalSince1970: 10_000)
        )
        let draggedID = GraphData.threadNodeID(for: "dragged")
        let nearbyID = GraphData.threadNodeID(for: "nearby")
        let distantID = GraphData.threadNodeID(for: "distant")
        let groupID = try XCTUnwrap(graph.groupings.first?.id)
        let draggedStart = CGPoint(x: 100, y: 100)
        let nearbyStart = CGPoint(x: 125, y: 100)
        let distantStart = CGPoint(x: 700, y: 500)
        let groupStart = CGPoint(x: 100, y: 220)
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph,
                        size: CGSize(width: 1_000, height: 800),
                        preserving: [draggedID: draggedStart,
                                     nearbyID: nearbyStart,
                                     distantID: distantStart,
                                     groupID: groupStart])

        simulator.beginDragging(nodeID: draggedID,
                                keepingStationary: [groupID])
        simulator.drag(nodeID: draggedID, to: CGPoint(x: 130, y: 100))
        let changed = simulator.stepDragging(deltaTime: 1.0 / 60.0)

        XCTAssertTrue(changed.contains(nearbyID))
        XCTAssertTrue(simulator.lastDragReactiveNodeIDs.contains(nearbyID))
        XCTAssertGreaterThan(simulator.lastDragCollisionCheckCount, 0)
        XCTAssertLessThan(simulator.nodesByID[nearbyID]!.position.x, nearbyStart.x)
        assertPoint(simulator.nodesByID[distantID]?.position, distantStart)
        assertPoint(simulator.nodesByID[groupID]?.position, groupStart)
        XCTAssertTrue(simulator.nodesByID[groupID]?.isPinned ?? false)

        let returningOrigins = simulator.lastDragReactiveNodeOrigins
        simulator.endDragging(nodeID: draggedID, at: CGPoint(x: 130, y: 100))
        for _ in 0..<120 {
            _ = simulator.stepLocalSettling(deltaTime: 1.0 / 60.0,
                                             returningNodeOrigins: returningOrigins)
        }

        XCTAssertTrue(simulator.isAtPositions(returningOrigins, tolerance: 0.25))
        assertPoint(simulator.nodesByID[groupID]?.position, groupStart)
        XCTAssertFalse(simulator.nodesByID[groupID]?.isPinned ?? true)
    }

    func test_dragReaction_heldNearNode_createsVisibleStableClearanceAtEveryZoom() throws {
        let graph = makeGraph(threadIDs: ["dragged", "nearby", "far"])
        let draggedID = GraphData.threadNodeID(for: "dragged")
        let nearbyID = GraphData.threadNodeID(for: "nearby")
        let farID = GraphData.threadNodeID(for: "far")
        for zoom: CGFloat in [0.2, 1, 5] {
            var simulator = ObsidianGraphForceSimulator()
            let origin = CGPoint(x: 110, y: 100)
            simulator.reset(data: graph, size: CGSize(width: 1_000, height: 800),
                            preserving: [draggedID: CGPoint(x: 100, y: 100),
                                         nearbyID: origin,
                                         farID: CGPoint(x: 2_000, y: 2_000)])
            simulator.beginDragging(nodeID: draggedID)
            for _ in 0..<60 {
                simulator.stepDragging(deltaTime: 1.0 / 60.0, zoomScale: zoom, nodeScale: 2.2)
            }
            let source = try XCTUnwrap(simulator.nodesByID[draggedID])
            let neighbor = try XCTUnwrap(simulator.nodesByID[nearbyID])
            let screenGap = (hypot(neighbor.position.x - source.position.x,
                                   neighbor.position.y - source.position.y)
                             - (source.radius + neighbor.radius) * 2.2) * zoom
            XCTAssertGreaterThan(screenGap, 60)
            XCTAssertGreaterThan((neighbor.position.x - origin.x) * zoom, 20)
            for _ in 0..<30 {
                simulator.stepDragging(deltaTime: 1.0 / 60.0, zoomScale: zoom, nodeScale: 2.2)
            }
            assertPoint(simulator.nodesByID[nearbyID]?.position, neighbor.position)
            assertPoint(simulator.nodesByID[farID]?.position, CGPoint(x: 2_000, y: 2_000))
        }
    }

    func test_dragReaction_reduceMotion_andCoincidentNodes_resolveWithoutOscillation() throws {
        let graph = makeGraph(threadIDs: ["dragged", "nearby"])
        let draggedID = GraphData.threadNodeID(for: "dragged")
        let nearbyID = GraphData.threadNodeID(for: "nearby")
        var simulator = ObsidianGraphForceSimulator()
        let origin = CGPoint(x: 100, y: 100)
        simulator.reset(data: graph, size: CGSize(width: 800, height: 600),
                        preserving: [draggedID: origin, nearbyID: origin])
        simulator.beginDragging(nodeID: draggedID)
        simulator.stepDragging(deltaTime: 1.0 / 60.0, reduceMotion: true)
        let target = try XCTUnwrap(simulator.nodesByID[nearbyID]?.position)
        XCTAssertGreaterThan(hypot(target.x - origin.x, target.y - origin.y), 64)
        simulator.stepDragging(deltaTime: 1.0 / 60.0, reduceMotion: true)
        assertPoint(simulator.nodesByID[nearbyID]?.position, target)
        simulator.cancelDragging()
        simulator.stepLocalSettling(deltaTime: 1.0 / 60.0,
                                    returningNodeOrigins: simulator.lastDragReactiveNodeOrigins,
                                    reduceMotion: true)
        assertPoint(simulator.nodesByID[nearbyID]?.position, origin)
    }

    func test_sceneDrag_cancellation_restoresGrabbedAndReactiveNodesWithoutMutation() throws {
        let graph = makeGraph(threadIDs: ["first", "second"])
        let view = GraphSKView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let scene = ObsidianGraphScene(size: view.bounds.size)
        view.presentScene(scene)
        configureBenchmarkScene(scene, data: graph)
        let nodes = scene.children.compactMap { $0 as? ObsidianGraphSceneNode }
        let source = try XCTUnwrap(nodes.first { $0.kind == .thread })
        let neighbor = try XCTUnwrap(nodes.first { $0.kind == .thread && $0 !== source })
        let initialPositions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.graphID, $0.position) })
        var mutationCount = 0
        scene.onMoveThreadsToFolder = { _, _ in mutationCount += 1 }
        scene.onCreateGroupAtCanvasPoint = { _, _, _ in mutationCount += 1 }
        scene.mouseDown(with: try pointerEvent(type: .leftMouseDown, location: source.position, timestamp: 0))
        scene.mouseDragged(with: try pointerEvent(type: .leftMouseDragged, location: neighbor.position, timestamp: 0.1))
        for frame in 1...30 { scene.update(Double(frame) / 60) }
        XCTAssertNotEqual(source.position, initialPositions[source.graphID])
        scene.cancelDirectManipulation()
        for frame in 31...150 { scene.update(Double(frame) / 60) }
        for node in nodes { assertPoint(node.position, initialPositions[node.graphID]) }
        XCTAssertEqual(mutationCount, 0)
        scene.teardownForRemoval()
    }

    func test_sceneDrag_pagingNode_movesWithoutExpandingAndClickStillExpands() throws {
        let graph = GraphData.make(roots: ["first", "second", "third"].map { makeThread(rootID: $0) },
                                   branchLimit: 1,
                                   now: Date(timeIntervalSince1970: 10_000))
        let view = GraphSKView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let scene = ObsidianGraphScene(size: view.bounds.size)
        view.presentScene(scene)
        configureBenchmarkScene(scene, data: graph)
        let node = try XCTUnwrap(scene.children.compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.kind == .remaining })
        var expansions = 0
        scene.onExpandRemainingBranches = { _ in expansions += 1 }
        let target = CGPoint(x: node.position.x + 100, y: node.position.y + 60)
        scene.mouseDown(with: try pointerEvent(type: .leftMouseDown, location: node.position, timestamp: 0))
        scene.mouseDragged(with: try pointerEvent(type: .leftMouseDragged, location: target, timestamp: 0.1))
        scene.update(0.1)
        scene.mouseUp(with: try pointerEvent(type: .leftMouseUp, location: target, timestamp: 0.2))
        XCTAssertEqual(expansions, 0)
        assertPoint(node.position, target)
        scene.mouseDown(with: try pointerEvent(type: .leftMouseDown, location: node.position, timestamp: 0.3))
        XCTAssertEqual(expansions, 0)
        scene.mouseUp(with: try pointerEvent(type: .leftMouseUp, location: node.position, timestamp: 0.4))
        XCTAssertEqual(expansions, 1)
        scene.teardownForRemoval()
    }

    func test_sceneDrag_suggestedGroup_repositionsWithoutConfirmingOrMovingConversations() throws {
        let signal = GraphTopicSignal(topic: "CR60 booking rollout", displayTitle: "CR60 booking rollout",
                                      confidence: 0.95, supportingReason: "Shared synthetic topic")
        let graph = GraphData.make(roots: [makeThread(rootID: "first"), makeThread(rootID: "second")],
                                   topicSignalsByRawThreadID: ["first": signal, "second": signal],
                                   now: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(GraphSceneLookupIndex(data: graph).visualDragNodeIDs(from: graph.allNodeIDs), graph.allNodeIDs)
        let view = GraphSKView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let scene = ObsidianGraphScene(size: view.bounds.size)
        view.presentScene(scene)
        configureBenchmarkScene(scene, data: graph)
        let node = try XCTUnwrap(scene.children.compactMap { $0 as? ObsidianGraphSceneNode }
            .first { $0.kind == .ghostGroup })
        let target = CGPoint(x: node.position.x + 130, y: node.position.y + 75)
        var mutations = 0
        scene.onMoveThreadsToFolder = { _, _ in mutations += 1 }
        scene.onCreateGroupAtCanvasPoint = { _, _, _ in mutations += 1 }
        scene.mouseDown(with: try pointerEvent(type: .leftMouseDown, location: node.position, timestamp: 0))
        scene.mouseDragged(with: try pointerEvent(type: .leftMouseDragged, location: target, timestamp: 0.1))
        scene.update(0.1)
        scene.mouseUp(with: try pointerEvent(type: .leftMouseUp, location: target, timestamp: 0.2))
        for frame in 1...120 { scene.update(0.2 + Double(frame) / 60) }
        assertPoint(node.position, target)
        XCTAssertEqual(mutations, 0)
        XCTAssertEqual(scene.workMetrics.forceStepCount, 0)
        scene.teardownForRemoval()
    }

    func test_dragReaction_largeSelection_checksOnlyLocalPairs() throws {
        let graph = makeGraph(threadIDs: (0..<500).map { "node-\($0)" })
        XCTAssertEqual(graph.threads.count, 500)
        let ids = graph.threads.map(\.id).sorted()
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map {
            ($0.element, CGPoint(x: CGFloat($0.offset % 25) * 180, y: CGFloat($0.offset / 25) * 180))
        })
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 5_000, height: 4_000), preserving: positions)
        let sources = Set(ids.enumerated().filter { $0.offset.isMultiple(of: 3) }.map(\.element))
        simulator.beginDragging(nodeIDs: sources)
        simulator.stepDragging(deltaTime: 1.0 / 60.0)
        XCTAssertLessThan(simulator.lastDragCollisionCheckCount, ids.count * 8)
        XCTAssertTrue(simulator.nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    /// Opt-in because this measures real display scheduling, which is not a
    /// deterministic headless CI assertion. Uses synthetic data and no Mail.
    func test_dragDisplayBenchmark_500VisibleNodes_staysAbove30FPS() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BETTERMAIL_DRAG_DISPLAY_BENCHMARK"] == "1",
                          "Requires an active macOS display; opt in to run the rendered FPS check.")
        let graph = makeGraph(threadIDs: (0..<500).map { "node-\($0)" })
        XCTAssertEqual(graph.threads.count, 500)
        let view = GraphSKView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 760))
        view.preferredFramesPerSecond = 60
        view.ignoresSiblingOrder = true
        view.shouldCullNonVisibleNodes = true
        view.showsFPS = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "BetterMail synthetic drag performance"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let scene = ObsidianGraphScene(size: view.bounds.size)
        view.presentScene(scene)
        let positions = Dictionary(uniqueKeysWithValues: graph.threads.enumerated().map {
            ($0.element.id, CGPoint(x: 70 + CGFloat($0.offset % 25) * 43,
                                   y: 60 + CGFloat($0.offset / 25) * 33))
        })
        configureBenchmarkScene(scene, data: graph, positions: positions)
        defer {
            scene.cancelDirectManipulation()
            scene.teardownForRemoval()
            view.presentScene(nil)
            window.close()
        }
        // Freeze the initial fixture layout while SpriteKit warms its renderer.
        let sourceID = try XCTUnwrap(graph.threads.first?.id)
        let sourcePosition = try XCTUnwrap(positions[sourceID])
        scene.mouseDown(with: try pointerEvent(type: .leftMouseDown, location: sourcePosition, timestamp: 0))
        try await Task.sleep(for: .milliseconds(750))
        scene.resetWorkMetricsForTesting()
        for sample in 0..<240 {
            let angle = CGFloat(sample) * .pi / 90
            let target = CGPoint(x: 600 + cos(angle) * 380, y: 380 + sin(angle) * 240)
            scene.mouseDragged(with: try pointerEvent(type: .leftMouseDragged,
                                                      location: target,
                                                      timestamp: Double(sample) / 120))
            try await Task.sleep(for: .milliseconds(8))
        }
        let intervals = Array(scene.workMetrics.dragFrameIntervals.dropFirst(5)).sorted()
        XCTAssertGreaterThan(intervals.count, 30, "SpriteKit must actually render frames on the display")
        guard !intervals.isEmpty else { return }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let p95 = intervals[min(intervals.count - 1, Int(Double(intervals.count) * 0.95))]
        let maximum = intervals.last ?? .infinity
        print(String(format: "BETTERMAIL_DRAG_DISPLAY nodes=%d frames=%d mean_fps=%.2f p95_frame_ms=%.3f max_frame_ms=%.3f",
                     graph.allNodeIDs.count, intervals.count, 1 / mean, p95 * 1_000, maximum * 1_000))
        XCTAssertGreaterThan(1 / mean, 30)
        XCTAssertLessThan(p95, 1.0 / 30.0)
        XCTAssertLessThan(maximum, 1.0 / 30.0)
        XCTAssertEqual(scene.workMetrics.forceStepCount, 0)
    }

    func test_reset_invalidPreservedRootPosition_usesFiniteMidpoint() throws {
        var simulator = ObsidianGraphForceSimulator()
        simulator.reset(data: makeGraph(threadIDs: ["first"]),
                        size: CGSize(width: 800, height: 600),
                        preserving: [GraphCenter.you.id: CGPoint(x: CGFloat.nan, y: 20)])
        assertPoint(simulator.nodesByID[GraphCenter.you.id]?.position, CGPoint(x: 400, y: 300))
        simulator.beginDragging(nodeID: GraphData.threadNodeID(for: "first"))
        simulator.stepDragging(deltaTime: 1.0 / 60.0)
        XCTAssertTrue(simulator.nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    private func makeGraph(threadIDs: [String]) -> GraphData {
        GraphData.make(roots: threadIDs.map { makeThread(rootID: $0) },
                       now: Date(timeIntervalSince1970: 10_000))
    }

    private func configureBenchmarkScene(_ scene: ObsidianGraphScene,
                                         data: GraphData,
                                         positions: [String: CGPoint]? = nil) {
        scene.configure(data: data,
                        selectedGraphNodeID: nil,
                        selectedGraphNodeIDs: [],
                        pruneMode: .idle,
                        filteredNodeIDs: data.allNodeIDs,
                        wateredCounts: [:],
                        reduceMotion: false,
                        sproutingMessageIDs: [],
                        forceConfig: .defaults,
                        displayConfig: .defaults,
                        theme: DesignTokens.Graph.AppTheme.Palette(isDark: false),
                        zoomScale: 1,
                        panOffset: .zero,
                        restoredNodePositions: positions,
                        restoredGroupAnchors: positions == nil ? nil : [:])
    }

    private func pointerEvent(type: NSEvent.EventType,
                              location: CGPoint,
                              timestamp: TimeInterval) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type,
                                        location: location,
                                        modifierFlags: [],
                                        timestamp: timestamp,
                                        windowNumber: 0,
                                        context: nil,
                                        eventNumber: 0,
                                        clickCount: 1,
                                        pressure: 1))
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func makeThread(rootID: String) -> ThreadNode {
        ThreadNode(message: EmailMessage(messageID: rootID,
                                         internalMailID: "internal-\(rootID)",
                                         mailboxID: "Inbox",
                                         accountName: "Account",
                                         subject: rootID,
                                         from: "sender@example.com",
                                         to: "me@example.com",
                                         date: Date(timeIntervalSince1970: 10_000),
                                         snippet: rootID,
                                         isUnread: false,
                                         inReplyTo: nil,
                                         references: [],
                                         threadID: rootID))
    }

    private func translated(_ point: CGPoint, by delta: CGVector) -> CGPoint {
        CGPoint(x: point.x + delta.dx, y: point.y + delta.dy)
    }

    private func assertPoint(_ actual: CGPoint?, _ expected: CGPoint?, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual, let expected else {
            XCTFail("Expected both points to be present", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.001, file: file, line: line)
    }
}
