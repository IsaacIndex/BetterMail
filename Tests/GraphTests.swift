import CoreGraphics
import XCTest
@testable import BetterMail

final class GraphMappingTests: XCTestCase {
    func test_mapping_withFixtureInbox_preservesEdgeAndInboundInvariants() {
        let roots = (0..<9).map { index in
            makeThread(rootID: "root-\(index)", messageCount: 3 + index)
        }

        let graph = GraphData.make(roots: roots, now: Date(timeIntervalSince1970: 10_000))
        let messageCount = graph.messages.count

        XCTAssertEqual(graph.threads.count, 9)
        XCTAssertEqual(graph.edges.count, graph.threads.count + messageCount)
        XCTAssertEqual(graph.allNodeIDs.count, graph.threads.count + graph.messages.count + 1)

        let inboundCounts = graph.edges.reduce(into: [String: Int]()) { counts, edge in
            counts[edge.targetID, default: 0] += 1
        }
        for message in graph.messages {
            XCTAssertEqual(inboundCounts[message.id], 1, "message \(message.id) should have one inbound edge")
            XCTAssertNotNil(graph.threadByID[message.threadID])
        }
        let reachableIDs = Set(graph.edges.flatMap { [$0.sourceID, $0.targetID] })
        XCTAssertTrue(Set(graph.messages.map(\.id)).isSubset(of: reachableIDs))
        XCTAssertTrue(Set(graph.threads.map(\.id)).isSubset(of: reachableIDs))
    }

    func test_mapping_withNodeSummaries_attachesSummaryPreviewToMessages() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   summariesByNodeID: [
                                       "root-msg-1": GraphMessageSummary(text: "Confirm the deployment window and owner handoff.",
                                                                         statusMessage: "Updated now",
                                                                         isSummarizing: false)
                                   ],
                                   now: Date(timeIntervalSince1970: 10_000))

        let message = graph.messages.first { $0.rawMessageID == "root-msg-1" }
        XCTAssertEqual(message?.summaryPreviewText, "Confirm the deployment window and owner handoff.")
        XCTAssertTrue(graph.matchingNodeIDs(query: "deployment").contains(GraphData.messageNodeID(for: "root-msg-1")))
    }
}

final class GraphViewportTests: XCTestCase {
    func test_clampedZoom_keepsExpandedGraphRange() {
        XCTAssertEqual(GraphViewport.clampedZoom(0.01), 0.2)
        XCTAssertEqual(GraphViewport.clampedZoom(1.25), 1.25)
        XCTAssertEqual(GraphViewport.clampedZoom(8), 5.0)
    }
}

final class GraphForceSimulatorTests: XCTestCase {
    func test_forceSimulator_withFixedFixture_losesEnergyAfterSettling() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 6)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 800, height: 600))
        simulator.step(deltaTime: 0.016, elapsedTime: 16)
        let earlyEnergy = simulator.totalEnergy()

        for tick in 1...140 {
            simulator.step(deltaTime: 0.016, elapsedTime: Double(tick) * 16)
        }

        XCTAssertLessThan(simulator.totalEnergy(), earlyEnergy)
    }

    func test_forceSimulator_withMessageChain_keepsMessagesOutsideThreadOrbit() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 8)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        let size = CGSize(width: 800, height: 600)
        simulator.reset(data: graph, size: size)

        for tick in 1...180 {
            simulator.step(deltaTime: 0.016, elapsedTime: Double(tick) * 16)
        }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let threadID = GraphData.threadNodeID(for: "root")
        guard let thread = simulator.nodesByID[threadID] else {
            XCTFail("Expected thread node")
            return
        }
        let axisX = thread.position.x - center.x
        let axisY = thread.position.y - center.y
        let axisLength = max(1, hypot(axisX, axisY))
        let unitX = axisX / axisLength
        let unitY = axisY / axisLength

        for message in graph.messages {
            guard let node = simulator.nodesByID[message.id] else {
                XCTFail("Expected message node \(message.id)")
                return
            }
            let projection = (node.position.x - thread.position.x) * unitX +
                (node.position.y - thread.position.y) * unitY
            XCTAssertGreaterThan(projection, 0, "message \(message.id) should not curl back behind its thread")
        }
    }
}

final class GraphSelectionTests: XCTestCase {
    func test_nearestNodeID_whenMovingInEachDirection_picksDirectionalNeighbor() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 5)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 500, height: 500))
        let rootID = GraphData.threadNodeID(for: "root")
        let upID = GraphData.messageNodeID(for: "root-msg-1")
        let downID = GraphData.messageNodeID(for: "root-msg-2")
        let leftID = GraphData.messageNodeID(for: "root-msg-3")
        let rightID = GraphData.messageNodeID(for: "root-msg-4")
        simulator.setPosition(CGPoint(x: 250, y: 250), for: rootID)
        simulator.setPosition(CGPoint(x: 250, y: 340), for: upID)
        simulator.setPosition(CGPoint(x: 250, y: 160), for: downID)
        simulator.setPosition(CGPoint(x: 140, y: 250), for: leftID)
        simulator.setPosition(CGPoint(x: 360, y: 250), for: rightID)

        XCTAssertEqual(simulator.nearestNodeID(from: rootID, direction: .up), upID)
        XCTAssertEqual(simulator.nearestNodeID(from: rootID, direction: .down), downID)
        XCTAssertEqual(simulator.nearestNodeID(from: rootID, direction: .left), leftID)
        XCTAssertEqual(simulator.nearestNodeID(from: rootID, direction: .right), rightID)
    }
}

final class GraphPruneStateMachineTests: XCTestCase {
    func test_pruneStateMachine_snipAndRestore_roundTripsToIdle() {
        var machine = GraphPruneStateMachine()

        XCTAssertEqual(machine.send(.enterSnip), .snipMode)
        XCTAssertEqual(machine.send(.edgeClicked(threadID: "thread-1")), .pickingFolder(threadID: "thread-1"))
        XCTAssertEqual(machine.send(.folderPicked), .wilting(threadID: "thread-1"))
        XCTAssertEqual(machine.send(.animationFinished), .composted(threadID: "thread-1"))
        XCTAssertEqual(machine.send(.restore(threadID: "thread-1")), .restoring(threadID: "thread-1"))
        XCTAssertEqual(machine.send(.restoreFinished), .idle)
    }

    func test_pruneStateMachine_archiveAndCancel_returnsToIdle() {
        var machine = GraphPruneStateMachine()

        XCTAssertEqual(machine.send(.enterArchive), .archiveMode)
        XCTAssertEqual(machine.send(.edgeClicked(threadID: "thread-1")), .settling(threadID: "thread-1"))
        XCTAssertEqual(machine.send(.cancel), .idle)
    }
}

private func makeThread(rootID: String, messageCount: Int) -> ThreadNode {
    let now = Date(timeIntervalSince1970: 10_000)
    var child: ThreadNode?
    for index in stride(from: messageCount - 1, through: 1, by: -1) {
        let node = ThreadNode(message: makeMessage(id: "\(rootID)-msg-\(index)",
                                                   subject: "Subject \(rootID)",
                                                   date: now.addingTimeInterval(Double(index) * -60),
                                                   threadID: rootID),
                              children: child.map { [$0] } ?? [])
        child = node
    }
    return ThreadNode(message: makeMessage(id: rootID,
                                           subject: "Subject \(rootID)",
                                           date: now,
                                           threadID: rootID),
                      children: child.map { [$0] } ?? [])
}

private func makeMessage(id: String,
                         subject: String = "Subject",
                         date: Date,
                         threadID: String) -> EmailMessage {
    EmailMessage(messageID: id,
                 internalMailID: "internal-\(id)",
                 mailboxID: "Inbox",
                 accountName: "Account",
                 subject: subject,
                 from: "sender@example.com",
                 to: "me@example.com",
                 date: date,
                 snippet: "Snippet \(id)",
                 isUnread: id.hasSuffix("1"),
                 inReplyTo: nil,
                 references: [],
                 threadID: threadID)
}
