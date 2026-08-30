#if DEBUG
import CoreData
import XCTest
@testable import BetterMail

@MainActor
final class OrganizerBenchmarkRuntimeTests: XCTestCase {
    func test_launchArgumentsParseActiveInactiveAndFailClosedConfigurations() {
        XCTAssertEqual(OrganizerBenchmarkLaunchSelection.parse(arguments: ["BetterMail"]),
                       .inactive)
        XCTAssertEqual(
            OrganizerBenchmarkLaunchSelection.parse(arguments: [
                "BetterMail",
                "--organizer-benchmark-fixture", "100",
                "--organizer-benchmark-run", "synthetic-run-01",
                "--organizer-benchmark-stratum", "cold-relaunch",
                "--organizer-benchmark-reset"
            ]),
            .active(OrganizerBenchmarkConfiguration(nodeCount: 100,
                                                    runID: "synthetic-run-01",
                                                    reset: true,
                                                    stratum: .coldRelaunch))
        )
        XCTAssertEqual(
            OrganizerBenchmarkLaunchSelection.parse(arguments: [
                "BetterMail",
                "--organizer-benchmark-fixture", "100",
                "--organizer-benchmark-run", "synthetic-first-01",
                "--organizer-benchmark-task", "first-organization"
            ]),
            .active(OrganizerBenchmarkConfiguration(nodeCount: 100,
                                                    runID: "synthetic-first-01",
                                                    reset: false,
                                                    stratum: .warm,
                                                    task: .firstOrganization))
        )
        XCTAssertEqual(
            OrganizerBenchmarkLaunchSelection.parse(arguments: [
                "BetterMail",
                "--organizer-benchmark-fixture", "500",
                "--organizer-benchmark-run", "synthetic-placement-01",
                "--organizer-benchmark-task", "placement-set",
                "--organizer-benchmark-placement-set", "placement-set-03"
            ]),
            .active(OrganizerBenchmarkConfiguration(nodeCount: 500,
                                                    runID: "synthetic-placement-01",
                                                    reset: false,
                                                    stratum: .warm,
                                                    task: .placementSet,
                                                    placementSetID: "placement-set-03"))
        )

        for arguments in [
            ["BetterMail", "--organizer-benchmark-fixture", "250"],
            ["BetterMail", "--organizer-benchmark-fixture", "100", "--organizer-benchmark-run", "../real-mail"],
            ["BetterMail", "--organizer-benchmark-fixture"],
            ["BetterMail", "--organizer-benchmark-fixture", "100", "--organizer-benchmark-task"],
            ["BetterMail", "--organizer-benchmark-fixture", "500", "--organizer-benchmark-task", "retrieval"],
            ["BetterMail", "--organizer-benchmark-fixture", "100", "--organizer-benchmark-task", "placement-set", "--organizer-benchmark-placement-set", "placement-set-01"],
            ["BetterMail", "--organizer-benchmark-fixture", "500", "--organizer-benchmark-task", "placement-set"],
            ["BetterMail", "--organizer-benchmark-fixture", "500", "--organizer-benchmark-task", "placement-set", "--organizer-benchmark-placement-set", "placement-set-99"],
            ["BetterMail", "--organizer-benchmark-fixture", "500", "--organizer-benchmark-placement-set", "placement-set-01"],
            ["BetterMail", "--organizer-benchmark-unknown"]
        ] {
            guard case .invalid = OrganizerBenchmarkLaunchSelection.parse(arguments: arguments) else {
                XCTFail("Malformed benchmark launch must fail closed: \(arguments)")
                continue
            }
        }
    }

    func test_benchmarkTaskModesSeparateDiagnosticPointerAndTimedEvidence() throws {
        XCTAssertEqual(OrganizerBenchmarkConfiguration.Task.diagnostic.evidenceType,
                       .accessibilityAudit)
        XCTAssertNil(OrganizerBenchmarkConfiguration.Task.diagnostic.timedKindAtTaskReady)
        XCTAssertEqual(OrganizerBenchmarkConfiguration.Task.livePointer.evidenceType,
                       .livePointer)
        XCTAssertEqual(OrganizerBenchmarkConfiguration.Task.livePointer.targetOutcome,
                       .pointerDrop)
        XCTAssertEqual(OrganizerBenchmarkConfiguration.Task.firstOrganization.evidenceType,
                       .timedHumanTask)
        XCTAssertEqual(OrganizerBenchmarkConfiguration.Task.firstOrganization.timedKindAtTaskReady,
                       .firstAction)
        XCTAssertEqual(OrganizerBenchmarkConfiguration.Task.fiveConversationOrganization.timedKindAtTaskReady,
                       .fiveConversation)
        XCTAssertNil(OrganizerBenchmarkConfiguration.Task.retrieval.timedKindAtTaskReady,
                     "Retrieval starts at search-start, not task-ready")

        let first = OrganizerBenchmarkConfiguration.Task.firstOrganization.metricContract
        XCTAssertEqual(first.taskID, .firstOrganization)
        XCTAssertEqual(first.sourceNodeKeys, ["node-100-0000"])
        XCTAssertEqual(first.destinationGroupKeys, ["group-flat-00"])
        XCTAssertNil(first.queryKey)

        let five = OrganizerBenchmarkConfiguration.Task.fiveConversationOrganization.metricContract
        XCTAssertEqual(five.sourceNodeKeys, (0..<5).map {
            String(format: "node-100-%04d", $0)
        })
        XCTAssertEqual(five.destinationGroupKeys, [
            "group-flat-00",
            "group-flat-01",
            "group-nested-00",
            "group-nested-01",
            "group-flat-02"
        ])
        XCTAssertEqual(five.queryKey, OrganizerMetricsRecorder.frozenRetrievalQuery)

        let placementConfiguration = OrganizerBenchmarkConfiguration(
            nodeCount: 500,
            runID: "synthetic-placement-contract",
            reset: true,
            stratum: .warm,
            task: .placementSet,
            placementSetID: "placement-set-05"
        )
        XCTAssertEqual(placementConfiguration.metricContract.sourceNodeKeys,
                       (80..<100).map { String(format: "node-500-%04d", $0) })
        XCTAssertEqual(placementConfiguration.metricContract.destinationGroupKeys,
                       ["group-flat-02"])
        let fixture = try XCTUnwrap(OrganizerBenchmarkFixture.make(nodeCount: 500))
        let runtimeContract = placementConfiguration.runtimeMetricContract(fixture: fixture)
        XCTAssertEqual(runtimeContract.placementSetID, "placement-set-05")
        XCTAssertEqual(runtimeContract.expectedMemberships.count, 20)
        XCTAssertEqual(runtimeContract.expectedMemberships.first,
                       OrganizerMetricExpectedMembership(rawThreadID: "conversation-500-0080",
                                                         destinationGroupKey: "group-flat-02"))
        XCTAssertFalse(runtimeContract.allowsRetrievalTiming)
    }

    func test_runtimeContract_requiresExactFrameBackedTaskTargetsBeforeReadiness() {
        let contract = OrganizerMetricRuntimeTaskContract(
            expectedMemberships: [
                OrganizerMetricExpectedMembership(rawThreadID: "conversation-100-0000",
                                                  destinationGroupKey: "group-flat-00"),
                OrganizerMetricExpectedMembership(rawThreadID: "conversation-100-0001",
                                                  destinationGroupKey: "group-flat-01")
            ],
            placementSetID: nil,
            allowsRetrievalTiming: false
        )
        let incomplete = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: [:],
            filteredAccessibleConversationRawThreadIDs: [],
            accessibleConversationRawThreadIDs: ["conversation-100-0000"],
            accessibleConfirmedGroupKeys: ["group-flat-00"]
        )
        let moving = OrganizerRenderedGraphSnapshot(
            isLayoutSettled: false,
            confirmedMemberCountsByGroupID: [:],
            filteredAccessibleConversationRawThreadIDs: [],
            accessibleConversationRawThreadIDs: [
                "conversation-100-0000", "conversation-100-0001"
            ],
            accessibleConfirmedGroupKeys: ["group-flat-00", "group-flat-01"]
        )
        let complete = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: [:],
            filteredAccessibleConversationRawThreadIDs: [],
            accessibleConversationRawThreadIDs: [
                "conversation-100-0000", "conversation-100-0001"
            ],
            accessibleConfirmedGroupKeys: ["group-flat-00", "group-flat-01"]
        )

        XCTAssertFalse(contract.isAccessibilityReady(for: incomplete))
        XCTAssertFalse(contract.isAccessibilityReady(for: moving))
        XCTAssertTrue(contract.isAccessibilityReady(for: complete))
    }

    func test_renderedReceiptHandlerFinalizesProductionRuntimeOnceAfterDeferral() async throws {
        let configuration = OrganizerBenchmarkConfiguration(
            nodeCount: 100,
            runID: "synthetic-runtime-receipt-regression",
            reset: true,
            stratum: .warm,
            task: .diagnostic
        )
        try OrganizerBenchmarkEnvironment.prepare(configuration)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.defaultsSuiteName))

        let runtime = OrganizerBenchmarkRuntime(
            configuration: configuration,
            settings: AutoRefreshSettings(userDefaults: defaults),
            inspectorSettings: InspectorViewSettings(userDefaults: defaults),
            displaySettings: ThreadCanvasDisplaySettings(userDefaults: defaults),
            pinnedFolderSettings: PinnedFolderSettings(userDefaults: defaults),
            activityCenter: ProcessingActivityCenter()
        )
        await runtime.seedIfNeeded()
        XCTAssertEqual(runtime.state, .launching)

        let threadResult = JWZThreader().buildThreads(from: runtime.fixture.emailMessages())
        let graphData = GraphData.make(
            roots: threadResult.roots,
            folders: runtime.fixture.threadFolders(),
            branchLimit: 24
        )
        await runtime.evaluateReadiness(roots: threadResult.roots, graphData: graphData)

        let firstConversationID = try XCTUnwrap(
            runtime.fixture.nodes.first?.effectiveConversationKey
        )
        let firstGroupKey = try XCTUnwrap(runtime.fixture.groups.first(where: \.acceptsDrop)?.groupKey)
        let snapshot = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: ["folder:\(firstGroupKey)": 1],
            filteredAccessibleConversationRawThreadIDs: [firstConversationID],
            accessibleConversationRawThreadIDs: [firstConversationID],
            accessibleConfirmedGroupKeys: [firstGroupKey],
            confirmedRawThreadIDsByGroupKey: [firstGroupKey: [firstConversationID]]
        )
        let handler: OrganizerRenderedGraphReceiptHandler = { receipt in
            runtime.evaluateRenderedReadiness(receipt)
        }
        handler(OrganizerRenderedGraphReceipt(snapshot: snapshot,
                                              newlyVisibleConfirmedMemberCount: 1,
                                              filterGeneration: 17))
        handler(OrganizerRenderedGraphReceipt(snapshot: snapshot,
                                              newlyVisibleConfirmedMemberCount: 0,
                                              filterGeneration: 18))

        for _ in 0..<200 where runtime.state != .ready {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(runtime.state, .ready)

        handler(OrganizerRenderedGraphReceipt(snapshot: snapshot,
                                              newlyVisibleConfirmedMemberCount: 0,
                                              filterGeneration: 19))
        await Task.yield()
        let report = await runtime.metricsRecorder.report()
        XCTAssertEqual(
            report.eventSummary.filter { $0.event == .workspaceReady }.map(\.count),
            [1]
        )
        XCTAssertEqual(
            report.eventSummary.filter { $0.event == .taskVisible }.map(\.count),
            [1]
        )
        XCTAssertEqual(
            report.eventSummary.filter { $0.event == .taskReady }.map(\.count),
            [1]
        )
    }

    func test_xctestHostDetectionKeepsUnitTestAppInert() {
        XCTAssertTrue(BetterMailApp.isXCTestHost(environment: [
            "XCTestConfigurationFilePath": "/tmp/BetterMailTests.xctestconfiguration"
        ]))
        XCTAssertTrue(BetterMailApp.isXCTestHost(environment: [
            "XCTestBundlePath": "/tmp/BetterMailTests.xctest"
        ]))
        XCTAssertFalse(BetterMailApp.isXCTestHost(environment: [:]))
    }

    func test_runtimeGeneratorExactlyMatchesBothFrozenFixtureDocuments() throws {
        for nodeCount in [100, 500] {
            let expected = try JSONDecoder().decode(
                OrganizerBenchmarkFixture.self,
                from: Data(contentsOf: fixtureURL(nodeCount: nodeCount))
            )
            XCTAssertEqual(OrganizerBenchmarkFixture.make(nodeCount: nodeCount), expected)
        }
        XCTAssertNil(OrganizerBenchmarkFixture.make(nodeCount: 250))
    }

    func test_runtimeMessagesProduceExactConversationCountAndStableThreadKeys() throws {
        let fixture = try XCTUnwrap(OrganizerBenchmarkFixture.make(nodeCount: 100))
        let messages = fixture.emailMessages()
        let result = JWZThreader().buildThreads(from: messages)

        XCTAssertEqual(messages.count, 300)
        XCTAssertEqual(result.roots.count, 100)
        XCTAssertEqual(Set(result.threads.map(\.id)), Set(fixture.nodes.map(\.effectiveConversationKey)))
        XCTAssertTrue(messages.contains { $0.snippet.contains("synthetic-query-organized-0004") })
        XCTAssertTrue(messages.allSatisfy { $0.accountName == "Synthetic Benchmark" })
    }

    func test_initialSpatialSnapshotUsesSceneGroupKeysAndVisibleAnchors() throws {
        let fixture = try XCTUnwrap(OrganizerBenchmarkFixture.make(nodeCount: 500))
        let snapshot = fixture.initialSpatialSnapshot()
        let expectedGroupKeys = Set(fixture.groups.filter(\.acceptsDrop).map(\.groupKey))

        XCTAssertEqual(Set(snapshot.confirmedGroupAnchors.keys), expectedGroupKeys)
        XCTAssertNil(snapshot.confirmedGroupAnchors["folder:group-flat-00"])
        XCTAssertEqual(snapshot.confirmedGroupAnchors["group-flat-00"],
                       GraphSpatialPoint(x: 120, y: 180))
        XCTAssertEqual(snapshot.confirmedGroupAnchors["group-flat-02"],
                       GraphSpatialPoint(x: 320, y: 180))
        XCTAssertEqual(snapshot.confirmedGroupAnchors["group-nested-00"],
                       GraphSpatialPoint(x: 120, y: 360))
        XCTAssertEqual(snapshot.confirmedGroupAnchors["group-nested-01"],
                       GraphSpatialPoint(x: 220, y: 360))
        XCTAssertTrue(snapshot.confirmedGroupAnchors.values.allSatisfy {
            (100...440).contains($0.x) && (160...380).contains($0.y)
        })
    }

    func test_seedIfNeededPreservesExistingRawKeyGroupAnchors() async throws {
        let configuration = OrganizerBenchmarkConfiguration(
            nodeCount: 500,
            runID: "synthetic-runtime-anchor-preservation",
            reset: true,
            stratum: .warm,
            task: .diagnostic
        )
        try OrganizerBenchmarkEnvironment.prepare(configuration)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.defaultsSuiteName))
        let fixture = try XCTUnwrap(OrganizerBenchmarkFixture.make(nodeCount: 500))
        let runRoot = try OrganizerBenchmarkEnvironment.runRootURL(for: configuration)
        let spatialStore = GraphSpatialStateStore(
            fileAccessor: OrganizerBenchmarkSpatialFileAccessor(
                fileURL: runRoot.appendingPathComponent("GraphSpatialState.json")
            ),
            secretProvider: OrganizerBenchmarkSpatialSecretProvider()
        )
        let rawGroupKeys = fixture.groups.filter(\.acceptsDrop).map(\.groupKey)
        let preservedAnchors = Dictionary(uniqueKeysWithValues: rawGroupKeys.enumerated().map {
            ($0.element, GraphSpatialPoint(x: Double(700 + $0.offset),
                                           y: Double(500 + $0.offset)))
        })
        try await spatialStore.save(
            GraphSpatialSnapshot(confirmedGroupAnchors: preservedAnchors),
            forScopeID: MailboxScope.allEmails.graphPagingScopeID
        )

        let runtime = OrganizerBenchmarkRuntime(
            configuration: configuration,
            settings: AutoRefreshSettings(userDefaults: defaults),
            inspectorSettings: InspectorViewSettings(userDefaults: defaults),
            displaySettings: ThreadCanvasDisplaySettings(userDefaults: defaults),
            pinnedFolderSettings: PinnedFolderSettings(userDefaults: defaults),
            activityCenter: ProcessingActivityCenter()
        )
        await runtime.seedIfNeeded()

        let restored = await spatialStore.load(
            scopeID: MailboxScope.allEmails.graphPagingScopeID,
            sourceNodeIDs: [],
            confirmedGroupIDs: Set(rawGroupKeys)
        )
        XCTAssertEqual(restored.confirmedGroupAnchors, preservedAnchors)
        XCTAssertTrue(restored.nodePositions.isEmpty)
    }

    func test_renderedGeometryReceiptPersistsSyntheticAccessibilityFrames() async throws {
        let configuration = OrganizerBenchmarkConfiguration(
            nodeCount: 100,
            runID: "synthetic-runtime-rendered-geometry",
            reset: true,
            stratum: .warm,
            task: .diagnostic
        )
        try OrganizerBenchmarkEnvironment.prepare(configuration)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.defaultsSuiteName))
        let runtime = OrganizerBenchmarkRuntime(
            configuration: configuration,
            settings: AutoRefreshSettings(userDefaults: defaults),
            inspectorSettings: InspectorViewSettings(userDefaults: defaults),
            displaySettings: ThreadCanvasDisplaySettings(userDefaults: defaults),
            pinnedFolderSettings: PinnedFolderSettings(userDefaults: defaults),
            activityCenter: ProcessingActivityCenter()
        )
        let conversationFrame = OrganizerRenderedAccessibilityFrame(
            CGRect(x: 120, y: 220, width: 24, height: 24)
        )
        let groupFrame = OrganizerRenderedAccessibilityFrame(
            CGRect(x: 420, y: 320, width: 32, height: 32)
        )
        let screenFrame = OrganizerRenderedAccessibilityFrame(
            CGRect(x: 0, y: 0, width: 1_215, height: 768)
        )
        runtime.evaluateRenderedReadiness(
            OrganizerRenderedGraphReceipt(
                snapshot: OrganizerRenderedGraphSnapshot(
                    confirmedMemberCountsByGroupID: [:],
                    filteredAccessibleConversationRawThreadIDs: [],
                    accessibleConversationRawThreadIDs: ["conversation-100-0000"],
                    accessibleConfirmedGroupKeys: ["group-flat-00"],
                    accessibleConversationFramesByRawThreadID: [
                        "conversation-100-0000": conversationFrame,
                        "real-mailbox-thread": conversationFrame
                    ],
                    accessibleConfirmedGroupFramesByGroupKey: [
                        "group-flat-00": groupFrame,
                        "real-mailbox-group": groupFrame
                    ],
                    accessibilityScreenFrame: screenFrame
                ),
                newlyVisibleConfirmedMemberCount: 0,
                filterGeneration: 1
            )
        )

        let geometryURL = try OrganizerBenchmarkEnvironment.runRootURL(for: configuration)
            .appendingPathComponent("OrganizerRenderedGeometry.json")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: geometryURL.path) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let document = try JSONDecoder().decode(
            OrganizerBenchmarkRenderedGeometryDocument.self,
            from: Data(contentsOf: geometryURL)
        )

        XCTAssertEqual(document.schemaVersion,
                       OrganizerBenchmarkRenderedGeometryDocument.currentSchemaVersion)
        XCTAssertEqual(document.coordinateSpace,
                       OrganizerBenchmarkRenderedGeometryDocument.coordinateSpaceIdentifier)
        XCTAssertEqual(document.screenFrame, screenFrame)
        XCTAssertEqual(document.conversationFramesByRawThreadID[
            "conversation-100-0000"
        ], conversationFrame)
        XCTAssertEqual(document.confirmedGroupFramesByGroupKey["group-flat-00"], groupFrame)
        XCTAssertNil(document.conversationFramesByRawThreadID["real-mailbox-thread"])
        XCTAssertNil(document.confirmedGroupFramesByGroupKey["real-mailbox-group"])
    }

    func test_renderedGeometryWriterSuppressesMovingReceiptAndPersistsLatestSettledFrame() async throws {
        let configuration = OrganizerBenchmarkConfiguration(
            nodeCount: 100,
            runID: "synthetic-runtime-rendered-geometry-coalescing",
            reset: true,
            stratum: .warm,
            task: .diagnostic
        )
        try OrganizerBenchmarkEnvironment.prepare(configuration)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.defaultsSuiteName))
        let runtime = OrganizerBenchmarkRuntime(
            configuration: configuration,
            settings: AutoRefreshSettings(userDefaults: defaults),
            inspectorSettings: InspectorViewSettings(userDefaults: defaults),
            displaySettings: ThreadCanvasDisplaySettings(userDefaults: defaults),
            pinnedFolderSettings: PinnedFolderSettings(userDefaults: defaults),
            activityCenter: ProcessingActivityCenter()
        )
        let rawThreadID = try XCTUnwrap(runtime.fixture.nodes.first?.effectiveConversationKey)
        let geometryURL = try OrganizerBenchmarkEnvironment.runRootURL(for: configuration)
            .appendingPathComponent("OrganizerRenderedGeometry.json")
        let firstFrame = OrganizerRenderedAccessibilityFrame(
            CGRect(x: 100, y: 200, width: 24, height: 24)
        )
        let finalFrame = OrganizerRenderedAccessibilityFrame(
            CGRect(x: 300, y: 400, width: 24, height: 24)
        )
        func receipt(frame: OrganizerRenderedAccessibilityFrame,
                     settled: Bool) -> OrganizerRenderedGraphReceipt {
            OrganizerRenderedGraphReceipt(
                snapshot: OrganizerRenderedGraphSnapshot(
                    isLayoutSettled: settled,
                    confirmedMemberCountsByGroupID: [:],
                    filteredAccessibleConversationRawThreadIDs: [],
                    accessibleConversationRawThreadIDs: [rawThreadID],
                    accessibleConfirmedGroupKeys: ["group-flat-00"],
                    accessibleConversationFramesByRawThreadID: [rawThreadID: frame]
                ),
                newlyVisibleConfirmedMemberCount: 0,
                filterGeneration: 1
            )
        }

        runtime.evaluateRenderedReadiness(receipt(frame: firstFrame, settled: false))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: geometryURL.path))

        runtime.evaluateRenderedReadiness(receipt(frame: firstFrame, settled: true))
        runtime.evaluateRenderedReadiness(receipt(frame: finalFrame, settled: true))
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: geometryURL.path) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let document = try JSONDecoder().decode(
            OrganizerBenchmarkRenderedGeometryDocument.self,
            from: Data(contentsOf: geometryURL)
        )
        XCTAssertEqual(document.conversationFramesByRawThreadID[rawThreadID], finalFrame)
    }

    func test_benchmarkRuntimeRethreadsEntireFrozenFixtureOutsideRollingDateWindow() async throws {
        let configuration = OrganizerBenchmarkConfiguration(
            nodeCount: 500,
            runID: "synthetic-runtime-date-window-regression",
            reset: true,
            stratum: .warm,
            task: .diagnostic
        )
        try OrganizerBenchmarkEnvironment.prepare(configuration)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.defaultsSuiteName))
        let runtime = OrganizerBenchmarkRuntime(
            configuration: configuration,
            settings: AutoRefreshSettings(userDefaults: defaults),
            inspectorSettings: InspectorViewSettings(userDefaults: defaults),
            displaySettings: ThreadCanvasDisplaySettings(userDefaults: defaults),
            pinnedFolderSettings: PinnedFolderSettings(userDefaults: defaults),
            activityCenter: ProcessingActivityCenter()
        )

        await runtime.seedIfNeeded()
        runtime.viewModel.start()
        for _ in 0..<400 where runtime.viewModel.roots.count != 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(runtime.viewModel.roots.count, 500)
        XCTAssertEqual(Set(runtime.viewModel.roots.compactMap(\.message.threadID)),
                       Set(runtime.fixture.nodes.map(\.effectiveConversationKey)))
    }

    func test_emptyConfirmedGroupsRenderAsFlatAndNestedDropTargets() throws {
        let fixture = try XCTUnwrap(OrganizerBenchmarkFixture.make(nodeCount: 100))
        let data = GraphData.make(roots: [],
                                  folders: fixture.threadFolders(),
                                  branchLimit: 24)

        XCTAssertEqual(data.groupings.count, 8)
        XCTAssertEqual(data.totalPrimaryBranchCount, 8)
        for grouping in data.groupings {
            XCTAssertEqual(grouping.kind, .folder)
            XCTAssertTrue(grouping.threadIDs.isEmpty)
            let expectedDepth = grouping.sourceFolderID?.contains("nested") == true ? 1 : 0
            XCTAssertEqual(grouping.hierarchyDepth, expectedDepth)
        }
    }

    func test_benchmarkRunPathCannotEscapeDedicatedApplicationSupportRoot() throws {
        let configuration = OrganizerBenchmarkConfiguration(nodeCount: 500,
                                                            runID: "synthetic-run-safe",
                                                            reset: true,
                                                            stratum: .warm)
        let base = URL(fileURLWithPath: "/tmp/bettermail-benchmark-path-test", isDirectory: true)
        let resolved = try OrganizerBenchmarkEnvironment.runRootURL(
            for: configuration,
            applicationSupportURL: base
        )
        XCTAssertEqual(resolved.path,
                       "/tmp/bettermail-benchmark-path-test/BetterMail/OrganizerBenchmark/organizer-500-v1/synthetic-run-safe")

        let unsafe = OrganizerBenchmarkConfiguration(nodeCount: 100,
                                                     runID: "synthetic-../escape",
                                                     reset: true,
                                                     stratum: .warm)
        XCTAssertThrowsError(try OrganizerBenchmarkEnvironment.runRootURL(
            for: unsafe,
            applicationSupportURL: base
        ))
    }

    func test_injectedPreferenceSuitesStayIndependentAcrossBenchmarkRuns() throws {
        let firstName = "OrganizerBenchmarkRuntimeTests.first.\(UUID().uuidString)"
        let secondName = "OrganizerBenchmarkRuntimeTests.second.\(UUID().uuidString)"
        let first = try XCTUnwrap(UserDefaults(suiteName: firstName))
        let second = try XCTUnwrap(UserDefaults(suiteName: secondName))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: firstName)
            UserDefaults.standard.removePersistentDomain(forName: secondName)
        }

        let firstGraph = GraphCanvasSettings(userDefaults: first)
        firstGraph.mode = .graph
        firstGraph.forceRepel = 1_234
        let secondGraph = GraphCanvasSettings(userDefaults: second)
        XCTAssertEqual(secondGraph.mode, .timeline)
        XCTAssertNotEqual(secondGraph.forceRepel, 1_234)

        let firstAutoRefresh = AutoRefreshSettings(userDefaults: first)
        firstAutoRefresh.isEnabled = true
        XCTAssertFalse(AutoRefreshSettings(userDefaults: second).isEnabled)

        let firstInspector = InspectorViewSettings(userDefaults: first)
        firstInspector.snippetLineLimit = 42
        XCTAssertEqual(InspectorViewSettings(userDefaults: second).snippetLineLimit,
                       InspectorViewSettings.defaultSnippetLineLimit)

        let firstPinned = PinnedFolderSettings(userDefaults: first)
        firstPinned.pin("synthetic-folder")
        XCTAssertTrue(PinnedFolderSettings(userDefaults: second).pinnedFolderIDs.isEmpty)

        let firstOrder = MailboxFolderOrderSettings(userDefaults: first)
        firstOrder.moveRelativeToTarget(sourceID: "b",
                                        targetID: "a",
                                        siblingIDs: ["a", "b"],
                                        insertAfterTarget: false)
        XCTAssertTrue(MailboxFolderOrderSettings(userDefaults: second).orderedFolderIDs.isEmpty)

        let firstMoveRules = MailboxThreadAutoMoveSettings(userDefaults: first)
        firstMoveRules.upsert(threadIDs: ["synthetic-thread"],
                              destinationPath: "Synthetic",
                              account: "Synthetic")
        XCTAssertTrue(MailboxThreadAutoMoveSettings(userDefaults: second).rules.isEmpty)

        let firstAppearance = AppearanceSettings(userDefaults: first)
        firstAppearance.mode = .dark
        XCTAssertEqual(AppearanceSettings(userDefaults: second).mode, .system)
    }

    func test_benchmarkMailBoundariesDenyMutationWithoutExternalCalls() async throws {
        let fixture = try XCTUnwrap(OrganizerBenchmarkFixture.make(nodeCount: 100))
        let boundary = OrganizerBenchmarkMailBoundary()
        let client = OrganizerBenchmarkMailClient(messages: fixture.emailMessages(),
                                                  boundary: boundary)
        do {
            _ = try await client.moveMessages(messageIDs: ["synthetic-message"],
                                              toMailboxPath: "Synthetic",
                                              account: "Synthetic",
                                              sourceMailboxPath: "Synthetic Inbox",
                                              sourceAccount: "Synthetic")
            XCTFail("Synthetic benchmark Mail move must be denied")
        } catch let error as OrganizerBenchmarkMailBoundaryError {
            XCTAssertEqual(error, .blocked)
        }

        let transport = OrganizerBenchmarkDeniedMailTransport(boundary: boundary)
        do {
            _ = try await transport.createMailbox(
                destination: .newMailbox(account: "Synthetic", path: "Synthetic/New")
            )
            XCTFail("Synthetic benchmark mailbox creation must be denied")
        } catch let error as OrganizerBenchmarkMailBoundaryError {
            XCTAssertEqual(error, .blocked)
        }

        let snapshot = await boundary.snapshot()
        XCTAssertEqual(snapshot.externalCallCount, 0)
        XCTAssertEqual(snapshot.deniedMutationCount, 2)
    }

    func test_viewModelActionItemsUseInjectedBenchmarkStore() async throws {
        let suiteName = "OrganizerBenchmarkRuntimeTests.action-items.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let fixture = try XCTUnwrap(OrganizerBenchmarkFixture.make(nodeCount: 100))
        let message = try XCTUnwrap(fixture.emailMessages().first)
        let boundary = OrganizerBenchmarkMailBoundary()
        let client = OrganizerBenchmarkMailClient(messages: [message], boundary: boundary)
        let operationStore = makeInMemoryOrganizationOperationStore(label: suiteName)
        let mailService = OrganizationMailExecutionService(
            operationStore: operationStore,
            transport: OrganizerBenchmarkDeniedMailTransport(boundary: boundary)
        )
        let viewModel = ThreadCanvasViewModel(
            settings: AutoRefreshSettings(userDefaults: defaults),
            inspectorSettings: InspectorViewSettings(userDefaults: defaults),
            pinnedFolderSettings: PinnedFolderSettings(userDefaults: defaults),
            mailboxFolderOrderSettings: MailboxFolderOrderSettings(userDefaults: defaults),
            mailboxThreadAutoMoveSettings: MailboxThreadAutoMoveSettings(userDefaults: defaults),
            store: store,
            organizationOperationStore: operationStore,
            organizationMailService: mailService,
            client: client,
            calendarRecoveryClient: client,
            dayFetchCoordinator: DayFetchCoordinator(client: client, store: store),
            summaryCapability: EmailSummaryCapability(provider: nil,
                                                       statusMessage: "Synthetic",
                                                       providerID: "synthetic-none-v1"),
            tagCapability: EmailTagCapability(provider: nil,
                                               statusMessage: "Synthetic",
                                               providerID: "synthetic-none-v1"),
            graphAutomationSettings: GraphAutomationSettings(userDefaults: defaults),
            graphAutomationMailClient: client,
            performsInitialSourceRefresh: false
        )

        viewModel.addActionItem(message: message, folderID: nil, tags: ["Synthetic"])
        for _ in 0..<100 where viewModel.actionItems.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let persistedItems = await store.fetchActionItems()
        XCTAssertEqual(viewModel.actionItems.map(\.messageID), [message.messageID])
        XCTAssertEqual(persistedItems.map(\.messageID), [message.messageID])
    }

    private func fixtureURL(nodeCount: Int) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Organizer", isDirectory: true)
            .appendingPathComponent(String(format: "organizer-%03d-v1.json", nodeCount))
    }
}
#endif
