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
    func test_branchConfig_usesOrganicLimbDefaults() {
        let config = GraphForceConstants.defaults.branchConfig

        XCTAssertEqual(config.trunkWidth, 2.6)
        XCTAssertEqual(config.chainWidth, 1.6)
        XCTAssertEqual(config.taper, 0.6)
        XCTAssertEqual(config.tipMin, 0.5)
        XCTAssertEqual(config.taperPow, 1.8)
        XCTAssertEqual(config.jointRadiusTrunk, 1.8)
        XCTAssertEqual(config.jointRadiusChain, 1.4)
        XCTAssertTrue(config.asymmetricArc)
        XCTAssertTrue(config.outwardArcAnchorEnabled)
        XCTAssertEqual(config.ribbonSamples, 36)
    }

    func test_forceSimulator_withFixedFixture_energyDecreasesAcrossSettlingWindow() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 6)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var simulator = GraphForceSimulator()
        simulator.reset(data: graph, size: CGSize(width: 800, height: 600))

        for tick in 1...60 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true)
        }

        var sampledEnergies: [CGFloat] = []
        for tick in 61...185 {
            simulator.step(deltaTime: 0.016,
                           elapsedTime: Double(tick) * 16,
                           reduceMotion: true)
            if tick.isMultiple(of: 25) {
                sampledEnergies.append(simulator.totalEnergy())
            }
        }

        XCTAssertGreaterThanOrEqual(sampledEnergies.count, 4)
        XCTAssertLessThan(sampledEnergies.last ?? .greatestFiniteMagnitude,
                          sampledEnergies.first ?? 0)
        for (previous, next) in zip(sampledEnergies, sampledEnergies.dropFirst()) {
            XCTAssertLessThanOrEqual(next, previous * 1.05)
        }
    }

    func test_forceSimulator_whenLabelRepelIsOff_ignoresLabelProvider() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 2)],
                                   now: Date(timeIntervalSince1970: 10_000))
        var baseline = GraphForceSimulator()
        var labeled = GraphForceSimulator()
        baseline.reset(data: graph, size: CGSize(width: 600, height: 420))
        labeled.reset(data: graph, size: CGSize(width: 600, height: 420))
        let config = GraphForceConfig(center: GraphForceConstants.defaults.center,
                                      repel: GraphForceConstants.defaults.repel,
                                      repelCutoff: GraphForceConstants.defaults.repelCutoff,
                                      linkSpring: GraphForceConstants.defaults.linkSpring,
                                      trunkLength: GraphForceConstants.defaults.trunkLength,
                                      chainLength: GraphForceConstants.defaults.chainLength,
                                      damping: GraphForceConstants.defaults.damping,
                                      breezeAmplitude: GraphForceConstants.defaults.breezeAmplitude,
                                      curl: GraphForceConstants.defaults.curl,
                                      curlVariability: GraphForceConstants.defaults.curlVariability,
                                      splineTension: GraphForceConstants.defaults.splineTension,
                                      curlFalloff: GraphForceConstants.defaults.curlFalloff,
                                      labelRepelOn: false,
                                      labelRepelStrength: 0.4)

        baseline.step(deltaTime: 0.016, elapsedTime: 16, reduceMotion: true, config: config)
        labeled.step(deltaTime: 0.016,
                     elapsedTime: 16,
                     reduceMotion: true,
                     config: config,
                     labelOccluderRadius: { _ in 500 })

        for id in graph.allNodeIDs {
            assertPointsEqual(baseline.nodesByID[id]?.position, labeled.nodesByID[id]?.position)
        }
    }
}

final class GraphSceneStabilityTests: XCTestCase {
    func test_graphScene_afterSettling_stopsPublishingPositionsWithoutInput() {
        let graph = GraphData.make(roots: [makeThread(rootID: "root", messageCount: 8)],
                                   now: Date(timeIntervalSince1970: 10_000))
        let scene = GraphScene(size: CGSize(width: 960, height: 640))
        var reportCount = 0
        scene.onPositionsChanged = { _ in
            reportCount += 1
        }

        scene.configure(data: graph,
                        selectedGraphNodeID: nil,
                        pruneMode: .idle,
                        filteredNodeIDs: graph.allNodeIDs,
                        wateredCounts: [:],
                        reduceMotion: false,
                        sproutingMessageIDs: [],
                        forceConfig: GraphForceConstants.defaults,
                        theme: DesignTokens.Graph.AppTheme.Palette(isDark: false),
                        zoomScale: 1,
                        panOffset: .zero)

        for frame in 1...200 {
            scene.update(Double(frame) * 0.016)
        }
        let settledReportCount = reportCount

        for frame in 201...260 {
            scene.update(Double(frame) * 0.016)
        }

        XCTAssertGreaterThan(settledReportCount, 0)
        XCTAssertEqual(reportCount, settledReportCount)
    }
}

final class GraphSplineTests: XCTestCase {
    func test_splinePath_withCurl_startsAndEndsAtEdgeEndpointsAndStaysInEnvelope() {
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 210, y: 20)
        let config = GraphCurlConfig(curl: 6, curlVariability: 0.2, splineTension: 0.35, curlFalloff: 0.45)

        let points = GraphSpline.points(from: start, to: end, seed: 42, config: config)
        assertPointsEqual(points.first, start)
        assertPointsEqual(points.last, end)
        for point in points {
            XCTAssertLessThanOrEqual(abs(point.y - start.y), config.curl * (1 + config.curlVariability) + 4)
        }

        let path = splinePath(from: start, to: end, seed: 42, config: config)
        assertPointsEqual(path.currentPoint, end)
    }

    func test_ribbonPoints_withTaper_preserveRequestedEndpointWidths() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 120, y: 0)
        let config = GraphCurlConfig(curl: 0, curlVariability: 0, splineTension: 0.35, curlFalloff: 0.45)

        let ribbon = GraphSpline.ribbonPoints(from: start,
                                              to: end,
                                              seed: 7,
                                              config: config,
                                              anchor: nil,
                                              widthStart: 8,
                                              widthEnd: 2,
                                              tipMin: 1,
                                              taperPow: 1.8,
                                              samples: 36)

        XCTAssertEqual(pointDistance(ribbon.left.first, ribbon.right.first), 8, accuracy: 0.001)
        XCTAssertEqual(pointDistance(ribbon.left.last, ribbon.right.last), 2, accuracy: 0.001)
    }

    func test_outwardArcSign_whenMidpointIsPositiveNormalSide_returnsPositive() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 0)
        let anchor = CGPoint(x: 50, y: -20)
        let config = GraphCurlConfig(curl: 9,
                                     curlVariability: 0,
                                     splineTension: 0.35,
                                     curlFalloff: 0.45,
                                     asymmetricArc: true)

        let sign = GraphSpline.outwardArcSign(from: start, to: end, anchor: anchor, fallbackSign: -1)
        let points = GraphSpline.points(from: start, to: end, seed: 9, config: config, anchor: anchor)

        XCTAssertEqual(sign, 1)
        XCTAssertGreaterThan(points[2].y, 0)
    }
}

final class GraphSummaryPlacementTests: XCTestCase {
    func test_autoPlacement_picksCardinalWithGreatestFreeSpace() {
        let origin = CGPoint(x: 0, y: 0)
        let boxSize = CGSize(width: 120, height: 40)
        let occluders = [
            GraphSummaryOccluder(id: "right", position: CGPoint(x: 56, y: 0), radius: 24),
            GraphSummaryOccluder(id: "up", position: CGPoint(x: 0, y: 56), radius: 24),
            GraphSummaryOccluder(id: "down", position: CGPoint(x: 0, y: -56), radius: 24),
            GraphSummaryOccluder(id: "upper-right", position: CGPoint(x: 40, y: 40), radius: 24),
            GraphSummaryOccluder(id: "lower-right", position: CGPoint(x: 40, y: -40), radius: 24)
        ]

        let angle = GraphSummaryPlacement.preferredAngle(origin: origin,
                                                        boxSize: boxSize,
                                                        occluders: occluders,
                                                        previousAngle: nil)

        XCTAssertEqual(angle, .pi, accuracy: 0.001)
    }

    func test_smoothedAngle_whenEffectivelyAtPickedAngle_snapsToPickedAngle() {
        let picked = CGFloat.pi / 2
        let smoothed = GraphSummaryPlacement.smoothedAngle(previous: picked - 0.0005,
                                                          picked: picked)

        XCTAssertEqual(smoothed, picked, accuracy: 0.000001)
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

private func assertPointsEqual(_ lhs: CGPoint?,
                               _ rhs: CGPoint?,
                               accuracy: CGFloat = 0.001,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
    guard let lhs, let rhs else {
        XCTFail("Expected both points to be non-nil", file: file, line: line)
        return
    }
    XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
}

private func pointDistance(_ lhs: CGPoint?, _ rhs: CGPoint?) -> CGFloat {
    guard let lhs, let rhs else { return .greatestFiniteMagnitude }
    return hypot(lhs.x - rhs.x, lhs.y - rhs.y)
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
