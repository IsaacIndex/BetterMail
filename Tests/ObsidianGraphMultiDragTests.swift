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
                XCTAssertLessThanOrEqual(recordedMetrics?.accessibilityRefreshCount ?? .max, 3)
            }
        }

        let median = samples.sorted()[samples.count / 2]
        let metrics = try XCTUnwrap(recordedMetrics)
        print(String(
            format: "BETTERMAIL_DRAG_BENCHMARK median_ms=%.3f full_renders=%d drag_renders=%d force_steps=%d accessibility_refreshes=%d",
            median,
            metrics.fullRenderPassCount,
            metrics.dragRenderPassCount,
            metrics.forceStepCount,
            metrics.accessibilityRefreshCount
        ))
    }

    func test_sceneDrag_whenPointerStartsOnYou_keepsRootAtMidpoint() throws {
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

        assertPoint(youNode.position, center)
        XCTAssertEqual(scene.workMetrics.dragRenderPassCount, 0)
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

    private func makeGraph(threadIDs: [String]) -> GraphData {
        GraphData.make(roots: threadIDs.map { makeThread(rootID: $0) },
                       now: Date(timeIntervalSince1970: 10_000))
    }

    private func configureBenchmarkScene(_ scene: ObsidianGraphScene, data: GraphData) {
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
                        panOffset: .zero)
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
