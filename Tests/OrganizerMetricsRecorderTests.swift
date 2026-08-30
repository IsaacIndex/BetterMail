import Foundation
import XCTest
@testable import BetterMail

private final class OrganizerMetricsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]
    private var lastValue: Int64

    init(values: [Int64]) {
        precondition(!values.isEmpty)
        self.values = values
        self.lastValue = values[0]
    }

    func read() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return lastValue }
        lastValue = values.removeFirst()
        return lastValue
    }
}

final class OrganizerMetricsRecorderTests: XCTestCase {
    private let timestamp = Date(timeIntervalSinceReferenceDate: 42)

    func test_timingReport_keepsWarmAndColdStrataAndUsesNearestRankP80() async throws {
        let recorder = try makeRecorder()
        for index in 0..<10 {
            try await recorder.recordTimed(kind: .firstAction,
                                           stratum: .warm,
                                           sampleID: "synthetic-first-warm-\(index)",
                                           durationMilliseconds: Int64(index + 1) * 1_000,
                                           outcome: .success,
                                           recordedAt: timestamp)
            try await recorder.recordTimed(kind: .firstAction,
                                           stratum: .coldRelaunch,
                                           sampleID: "synthetic-first-cold-\(index)",
                                           durationMilliseconds: Int64(index + 1) * 1_000,
                                           outcome: .success,
                                           recordedAt: timestamp)
        }

        let report = await recorder.report()
        let warm = try XCTUnwrap(report.timing.first {
            $0.kind == .firstAction && $0.stratum == .warm
        })
        let cold = try XCTUnwrap(report.timing.first {
            $0.kind == .firstAction && $0.stratum == .coldRelaunch
        })

        XCTAssertEqual(warm.sampleCount, 10)
        XCTAssertEqual(warm.medianMilliseconds, 5_000)
        XCTAssertEqual(warm.p80Milliseconds, 8_000)
        XCTAssertEqual(warm.p90Milliseconds, 9_000)
        XCTAssertEqual(warm.status, .pass)
        XCTAssertEqual(cold.p80Milliseconds, warm.p80Milliseconds)
        XCTAssertEqual(cold.status, .pass)
    }

    func test_timingFailuresRemainOverThresholdWithoutOverridingContractualP80() async throws {
        let recorder = try makeRecorder()
        for index in 0..<8 {
            try await recorder.recordTimed(kind: .fiveConversation,
                                           stratum: .warm,
                                           sampleID: "synthetic-five-warm-\(index)",
                                           durationMilliseconds: 1_000,
                                           outcome: .success,
                                           recordedAt: timestamp)
        }
        for index in 0..<2 {
            try await recorder.recordTimed(kind: .fiveConversation,
                                           stratum: .warm,
                                           sampleID: "synthetic-five-warm-failure-\(index)",
                                           durationMilliseconds: nil,
                                           outcome: .failure,
                                           recordedAt: timestamp)
        }

        let report = await recorder.report()
        let summary = try XCTUnwrap(report.timing.first {
            $0.kind == .fiveConversation && $0.stratum == .warm
        })
        XCTAssertEqual(summary.sampleCount, 10)
        XCTAssertEqual(summary.failureCount, 2)
        XCTAssertEqual(summary.p80Milliseconds, 1_000)
        XCTAssertEqual(summary.p90Milliseconds, 120_001)
        XCTAssertEqual(summary.status, .pass)
    }

    func test_timingFailuresFailAcceptanceWhenTheyReachContractualP80() async throws {
        let recorder = try makeRecorder()
        for index in 0..<7 {
            try await recorder.recordTimed(kind: .fiveConversation,
                                           stratum: .warm,
                                           sampleID: "synthetic-five-fail-p80-success-\(index)",
                                           durationMilliseconds: 1_000,
                                           outcome: .success,
                                           recordedAt: timestamp)
        }
        for index in 0..<3 {
            try await recorder.recordTimed(kind: .fiveConversation,
                                           stratum: .warm,
                                           sampleID: "synthetic-five-fail-p80-failure-\(index)",
                                           durationMilliseconds: nil,
                                           outcome: .failure,
                                           recordedAt: timestamp)
        }

        let report = await recorder.report()
        let summary = try XCTUnwrap(report.timing.first {
            $0.kind == .fiveConversation && $0.stratum == .warm
        })
        XCTAssertEqual(summary.p80Milliseconds, 120_001)
        XCTAssertEqual(summary.status, .fail)
    }

    func test_runtimeTiming_usesRecorderClockAndExportsOnlyCoarseRelativeEvents() async throws {
        let clock = OrganizerMetricsTestClock(values: [100, 150, 200, 250, 300, 350, 400, 1_450])
        let recorder = try makeRecorder(monotonicClock: OrganizerMetricsMonotonicClock(
            readMilliseconds: { clock.read() }
        ))

        let workspaceReady = await recorder.recordEvent(.workspaceReady, status: .success)
        let taskVisible = await recorder.recordEvent(.taskVisible, status: .success)
        let didStart = await recorder.beginTimedEvent(kind: .firstAction,
                                                      stratum: .warm,
                                                      event: .taskReady,
                                                      count: 1)
        let actionStarted = await recorder.recordEvent(.actionStart)
        let committed = await recorder.recordEvent(.betterMailCommit, status: .success)
        let rethreaded = await recorder.recordEvent(.rethreadComplete, status: .success)
        let didFinish = await recorder.finishTimedEvent(kind: .firstAction,
                                                        event: .visibleResult,
                                                        outcome: .success,
                                                        count: 1)

        XCTAssertTrue(workspaceReady)
        XCTAssertTrue(taskVisible)
        XCTAssertTrue(didStart)
        XCTAssertTrue(actionStarted)
        XCTAssertTrue(committed)
        XCTAssertTrue(rethreaded)
        XCTAssertTrue(didFinish)
        let report = await recorder.report()
        XCTAssertEqual(report.eventSummary, [
            OrganizerMetricEventRecord(sequence: 1,
                                       event: .workspaceReady,
                                       phase: .instant,
                                       stratum: nil,
                                       count: 1,
                                       status: .success,
                                       offsetMilliseconds: 50,
                                       durationMilliseconds: nil),
            OrganizerMetricEventRecord(sequence: 2,
                                       event: .taskVisible,
                                       phase: .instant,
                                       stratum: nil,
                                       count: 1,
                                       status: .success,
                                       offsetMilliseconds: 100,
                                       durationMilliseconds: nil),
            OrganizerMetricEventRecord(sequence: 3,
                                       event: .taskReady,
                                       phase: .started,
                                       stratum: .warm,
                                       count: 1,
                                       status: nil,
                                       offsetMilliseconds: 150,
                                       durationMilliseconds: nil),
            OrganizerMetricEventRecord(sequence: 4,
                                       event: .actionStart,
                                       phase: .instant,
                                       stratum: nil,
                                       count: 1,
                                       status: nil,
                                       offsetMilliseconds: 200,
                                       durationMilliseconds: nil),
            OrganizerMetricEventRecord(sequence: 5,
                                       event: .betterMailCommit,
                                       phase: .instant,
                                       stratum: nil,
                                       count: 1,
                                       status: .success,
                                       offsetMilliseconds: 250,
                                       durationMilliseconds: nil),
            OrganizerMetricEventRecord(sequence: 6,
                                       event: .rethreadComplete,
                                       phase: .instant,
                                       stratum: nil,
                                       count: 1,
                                       status: .success,
                                       offsetMilliseconds: 300,
                                       durationMilliseconds: nil),
            OrganizerMetricEventRecord(sequence: 7,
                                       event: .visibleResult,
                                       phase: .finished,
                                       stratum: .warm,
                                       count: 1,
                                       status: .success,
                                       offsetMilliseconds: 1_350,
                                       durationMilliseconds: 1_200)
        ])
        let summary = try XCTUnwrap(report.timing.first {
            $0.kind == .firstAction && $0.stratum == .warm
        })
        XCTAssertEqual(summary.sampleCount, 1)
        XCTAssertEqual(summary.successCount, 1)
        XCTAssertEqual(summary.p80Milliseconds, 1_200)
    }

    func test_trialRecordPinsFrozenTaskInputsWithoutMailDerivedIdentifiers() async throws {
        let contract = OrganizerMetricTaskContract(
            taskID: .fiveConversationOrganization,
            sourceNodeKeys: (0..<5).map { String(format: "node-100-%04d", $0) },
            destinationGroupKeys: [
                "group-flat-00",
                "group-flat-01",
                "group-nested-00",
                "group-nested-01",
                "group-flat-02"
            ],
            queryKey: OrganizerMetricsRecorder.frozenRetrievalQuery
        )
        let recorder = try OrganizerMetricsRecorder(
            runID: "synthetic-task-contract",
            fixtureID: "organizer-100-v1",
            protocolID: "visual-email-organizer-v1",
            evidenceType: .timedHumanTask,
            generatedAt: timestamp,
            defaultStratum: .warm,
            targetOutcome: .organization,
            taskContract: contract
        )

        let report = await recorder.report()
        let record = try XCTUnwrap(report.records.first)
        XCTAssertEqual(record.taskID, .fiveConversationOrganization)
        XCTAssertEqual(record.sourceNodeKeys, contract.sourceNodeKeys)
        XCTAssertEqual(record.destinationGroupKeys, contract.destinationGroupKeys)
        XCTAssertEqual(record.queryKey, contract.queryKey)
    }

    func test_exactTimedOrganizationRejectsWrongDestinationAndAcceptsExactMembership() async throws {
        let taskContract = OrganizerMetricTaskContract(
            taskID: .firstOrganization,
            sourceNodeKeys: ["node-100-0000"],
            destinationGroupKeys: ["group-flat-00"],
            queryKey: nil
        )
        let runtimeContract = OrganizerMetricRuntimeTaskContract(
            expectedMemberships: [
                OrganizerMetricExpectedMembership(rawThreadID: "conversation-100-0000",
                                                  destinationGroupKey: "group-flat-00")
            ],
            placementSetID: nil,
            allowsRetrievalTiming: false
        )

        for (runID, groups, expectedOutcome) in [
            ("synthetic-exact-wrong", ["group-flat-01": Set(["conversation-100-0000"])], OrganizerMetricOutcome.failure),
            ("synthetic-exact-correct", ["group-flat-00": Set(["conversation-100-0000"])], OrganizerMetricOutcome.success)
        ] {
            let recorder = try OrganizerMetricsRecorder(
                runID: runID,
                fixtureID: "organizer-100-v1",
                protocolID: "visual-email-organizer-v1",
                evidenceType: .timedHumanTask,
                generatedAt: timestamp,
                defaultStratum: .warm,
                targetOutcome: .organization,
                taskContract: taskContract,
                runtimeTaskContract: runtimeContract
            )
            _ = await recorder.recordEvent(.workspaceReady, status: .success)
            _ = await recorder.recordEvent(.taskVisible, status: .success)
            _ = await recorder.beginTimedEvent(kind: .firstAction,
                                               stratum: .warm,
                                               event: .taskReady)
            _ = await recorder.recordEvent(.actionStart)
            _ = await recorder.recordEvent(.betterMailCommit, status: .success)
            _ = await recorder.recordEvent(.rethreadComplete, status: .success)

            let modelOnlySnapshot = OrganizerRenderedGraphSnapshot(
                confirmedMemberCountsByGroupID: [:],
                filteredAccessibleConversationRawThreadIDs: [],
                confirmedRawThreadIDsByGroupKey: groups
            )
            _ = await recorder.recordRenderedOrganizerSnapshot(
                modelOnlySnapshot,
                newlyVisibleCount: 1
            )
            let modelOnlyReport = await recorder.report()
            XCTAssertFalse(modelOnlyReport.eventSummary.contains { $0.event == .visibleResult },
                           "Raw membership without accessible targets must not finish timing")

            let accessibleSnapshot = OrganizerRenderedGraphSnapshot(
                confirmedMemberCountsByGroupID: [:],
                filteredAccessibleConversationRawThreadIDs: [],
                accessibleConversationRawThreadIDs: ["conversation-100-0000"],
                accessibleConfirmedGroupKeys: ["group-flat-00", "group-flat-01"],
                confirmedRawThreadIDsByGroupKey: groups
            )
            _ = await recorder.recordRenderedOrganizerSnapshot(
                accessibleSnapshot,
                newlyVisibleCount: 0
            )

            let report = await recorder.report()
            let timing = try XCTUnwrap(report.timing.first {
                $0.kind == .firstAction && $0.stratum == .warm
            })
            XCTAssertEqual(timing.sampleCount, 1)
            if expectedOutcome == .success {
                XCTAssertEqual(timing.successCount, 1)
                XCTAssertTrue(report.eventSummary.contains { $0.event == .visibleResult })
            } else {
                XCTAssertEqual(timing.failureCount, 1)
                XCTAssertFalse(report.eventSummary.contains { $0.event == .visibleResult })
                XCTAssertEqual(report.records.first?.coarseFailureReason, .wrongCompletion)
            }
        }
    }

    func test_retrievalTimingIsTaskScopedCancelledAndCannotReuseStartBoundary() async throws {
        let diagnostic = try makeRecorder()
        let diagnosticStart = await diagnostic.beginDefaultRetrievalTimedEvent(generation: 1)
        XCTAssertFalse(diagnosticStart)

        let recorder = try OrganizerMetricsRecorder(
            runID: "synthetic-retrieval-cancel",
            fixtureID: "organizer-100-v1",
            protocolID: "visual-email-organizer-v1",
            evidenceType: .timedHumanTask,
            generatedAt: timestamp,
            defaultStratum: .warm,
            targetOutcome: .retrieval,
            taskContract: OrganizerMetricTaskContract(
                taskID: .retrieval,
                sourceNodeKeys: ["node-100-0004"],
                destinationGroupKeys: ["group-flat-02"],
                queryKey: OrganizerMetricsRecorder.frozenRetrievalQuery
            ),
            runtimeTaskContract: OrganizerMetricRuntimeTaskContract(
                expectedMemberships: [],
                placementSetID: nil,
                allowsRetrievalTiming: true
            )
        )
        _ = await recorder.recordEvent(.workspaceReady, status: .success)
        _ = await recorder.recordEvent(.taskVisible, status: .success)
        _ = await recorder.recordEvent(.taskReady, stratum: .warm)

        let didStart = await recorder.beginDefaultRetrievalTimedEvent(generation: 1)
        let didCancel = await recorder.cancelDefaultRetrievalTimedEvent(generation: 2)
        let didRestart = await recorder.beginDefaultRetrievalTimedEvent(generation: 3)
        XCTAssertTrue(didStart)
        XCTAssertTrue(didCancel)
        XCTAssertFalse(didRestart)

        let report = await recorder.report()
        let timing = try XCTUnwrap(report.timing.first {
            $0.kind == .retrieval && $0.stratum == .warm
        })
        XCTAssertEqual(timing.cancelledCount, 1)
        XCTAssertEqual(report.records.first?.coarseFailureReason, .cancelled)

        let reordered = try OrganizerMetricsRecorder(
            runID: "synthetic-retrieval-reordered",
            fixtureID: "organizer-100-v1",
            protocolID: "visual-email-organizer-v1",
            evidenceType: .timedHumanTask,
            generatedAt: timestamp,
            defaultStratum: .warm,
            targetOutcome: .retrieval,
            taskContract: OrganizerMetricTaskContract(
                taskID: .retrieval,
                sourceNodeKeys: ["node-100-0004"],
                destinationGroupKeys: ["group-flat-02"],
                queryKey: OrganizerMetricsRecorder.frozenRetrievalQuery
            ),
            runtimeTaskContract: OrganizerMetricRuntimeTaskContract(
                expectedMemberships: [],
                placementSetID: nil,
                allowsRetrievalTiming: true
            )
        )
        _ = await reordered.recordEvent(.workspaceReady, status: .success)
        _ = await reordered.recordEvent(.taskVisible, status: .success)
        _ = await reordered.recordEvent(.taskReady, stratum: .warm)
        let reorderedCancel = await reordered.cancelDefaultRetrievalTimedEvent(generation: 2)
        let staleStart = await reordered.beginDefaultRetrievalTimedEvent(generation: 1)
        let staleVisible = await reordered.recordRenderedRetrievalVisible(count: 1,
                                                                          generation: 1)
        XCTAssertTrue(reorderedCancel)
        XCTAssertFalse(staleStart)
        XCTAssertFalse(staleVisible)
        let reorderedReport = await reordered.report()
        XCTAssertEqual(reorderedReport.timing.first { $0.kind == .retrieval }?.cancelledCount,
                       1)

        let guarded = try OrganizerMetricsRecorder(
            runID: "synthetic-retrieval-currentness",
            fixtureID: "organizer-100-v1",
            protocolID: "visual-email-organizer-v1",
            evidenceType: .timedHumanTask,
            generatedAt: timestamp,
            defaultStratum: .warm,
            targetOutcome: .retrieval,
            taskContract: OrganizerMetricTaskContract(
                taskID: .retrieval,
                sourceNodeKeys: ["node-100-0004"],
                destinationGroupKeys: ["group-flat-02"],
                queryKey: OrganizerMetricsRecorder.frozenRetrievalQuery
            ),
            runtimeTaskContract: OrganizerMetricRuntimeTaskContract(
                expectedMemberships: [],
                placementSetID: nil,
                allowsRetrievalTiming: true
            )
        )
        _ = await guarded.recordEvent(.workspaceReady, status: .success)
        _ = await guarded.recordEvent(.taskVisible, status: .success)
        _ = await guarded.recordEvent(.taskReady, stratum: .warm)
        let didStartGuarded = await guarded.beginDefaultRetrievalTimedEvent(generation: 1)
        XCTAssertTrue(didStartGuarded)
        let rejectedCurrentness = await guarded.recordRenderedRetrievalVisible(
            count: 1,
            generation: 1,
            isStillCurrent: { false }
        )
        XCTAssertFalse(rejectedCurrentness)
        let didCancelGuarded = await guarded.cancelDefaultRetrievalTimedEvent(generation: 2)
        XCTAssertTrue(didCancelGuarded)
        let guardedReport = await guarded.report()
        XCTAssertFalse(guardedReport.eventSummary.contains { $0.event == .retrievalVisible })
        XCTAssertEqual(guardedReport.timing.first { $0.kind == .retrieval }?.cancelledCount,
                       1)
    }

    func test_fiveConversationTrialDurationDoesNotUseLaterRetrievalDuration() async throws {
        let recorder = try OrganizerMetricsRecorder(
            runID: "synthetic-primary-duration",
            fixtureID: "organizer-100-v1",
            protocolID: "visual-email-organizer-v1",
            evidenceType: .timedHumanTask,
            generatedAt: timestamp,
            defaultStratum: .warm,
            targetOutcome: .organization,
            taskContract: OrganizerMetricTaskContract(
                taskID: .fiveConversationOrganization,
                sourceNodeKeys: (0..<5).map { String(format: "node-100-%04d", $0) },
                destinationGroupKeys: ["group-flat-00", "group-flat-01", "group-nested-00", "group-nested-01", "group-flat-02"],
                queryKey: OrganizerMetricsRecorder.frozenRetrievalQuery
            )
        )
        try await recorder.recordTimed(kind: .fiveConversation,
                                       stratum: .warm,
                                       sampleID: "synthetic-five-duration",
                                       durationMilliseconds: 90_000,
                                       outcome: .success)
        try await recorder.recordTimed(kind: .retrieval,
                                       stratum: .warm,
                                       sampleID: "synthetic-retrieval-duration",
                                       durationMilliseconds: 250,
                                       outcome: .success)

        let report = await recorder.report()
        XCTAssertEqual(report.records.first?.durationMilliseconds, 90_000)
    }

    func test_placementSetAdjudicationRecordsExactFrozenSetAfterAllSourcesArePlaced() async throws {
        let sourceKeys = (0..<20).map { String(format: "node-500-%04d", $0) }
        let memberships = (0..<20).map {
            OrganizerMetricExpectedMembership(
                rawThreadID: String(format: "conversation-500-%04d", $0),
                destinationGroupKey: "group-flat-00"
            )
        }
        let recorder = try OrganizerMetricsRecorder(
            runID: "synthetic-placement-adjudication",
            fixtureID: "organizer-500-v1",
            protocolID: "visual-email-organizer-v1",
            evidenceType: .livePointer,
            generatedAt: timestamp,
            defaultStratum: .warm,
            targetOutcome: .placement,
            taskContract: OrganizerMetricTaskContract(taskID: .placementSet,
                                                       sourceNodeKeys: sourceKeys,
                                                       destinationGroupKeys: ["group-flat-00"],
                                                       queryKey: nil),
            runtimeTaskContract: OrganizerMetricRuntimeTaskContract(
                expectedMemberships: memberships,
                placementSetID: "placement-set-01",
                allowsRetrievalTiming: false
            )
        )
        let correct = Set((0..<19).map { String(format: "conversation-500-%04d", $0) })
        let wrong = Set(["conversation-500-0019"])

        let matchingSnapshot = OrganizerRenderedGraphSnapshot(
                confirmedMemberCountsByGroupID: [:],
                filteredAccessibleConversationRawThreadIDs: [],
                confirmedRawThreadIDsByGroupKey: [
                    "group-flat-00": correct,
                    "group-flat-01": wrong
                ]
            )
        let ignoredWhileMoving = await recorder.recordRenderedOrganizerSnapshot(
            OrganizerRenderedGraphSnapshot(
                isLayoutSettled: false,
                confirmedMemberCountsByGroupID: matchingSnapshot.confirmedMemberCountsByGroupID,
                filteredAccessibleConversationRawThreadIDs:
                    matchingSnapshot.filteredAccessibleConversationRawThreadIDs,
                confirmedRawThreadIDsByGroupKey:
                    matchingSnapshot.confirmedRawThreadIDsByGroupKey
            ),
            newlyVisibleCount: 0
        )
        XCTAssertTrue(ignoredWhileMoving)
        let movingReport = await recorder.report()
        XCTAssertTrue(movingReport.wrongPlacements.isEmpty)

        let didAdjudicate = await recorder.recordRenderedOrganizerSnapshot(
            matchingSnapshot,
            newlyVisibleCount: 0
        )
        XCTAssertTrue(didAdjudicate)

        let report = await recorder.report()
        let summary = try XCTUnwrap(report.wrongPlacements.first)
        XCTAssertEqual(summary.setCount, 1)
        XCTAssertEqual(summary.totalAttemptCount, 20)
        XCTAssertEqual(summary.totalWrongPlacementCount, 1)
        XCTAssertEqual(summary.sets.first?.setID, "placement-set-01")
    }

    func test_placementSetRetainsUnsettledVisibilityUntilSettledSnapshot() async throws {
        let membership = OrganizerMetricExpectedMembership(
            rawThreadID: "conversation-500-0000",
            destinationGroupKey: "group-flat-00"
        )
        let recorder = try OrganizerMetricsRecorder(
            runID: "synthetic-placement-unsettled",
            fixtureID: "organizer-500-v1",
            protocolID: "visual-email-organizer-v1",
            evidenceType: .livePointer,
            generatedAt: timestamp,
            defaultStratum: .warm,
            targetOutcome: .placement,
            taskContract: OrganizerMetricTaskContract(
                taskID: .placementSet,
                sourceNodeKeys: ["node-500-0000"],
                destinationGroupKeys: ["group-flat-00"],
                queryKey: nil
            ),
            runtimeTaskContract: OrganizerMetricRuntimeTaskContract(
                expectedMemberships: [membership],
                placementSetID: "placement-set-unsettled",
                allowsRetrievalTiming: false
            )
        )
        _ = await recorder.recordEvent(.workspaceReady, status: .success)
        _ = await recorder.recordEvent(.taskVisible, status: .success)
        _ = await recorder.recordEvent(.taskReady, status: .success)
        _ = await recorder.recordEvent(.actionStart)

        let unsettled = OrganizerRenderedGraphSnapshot(
            isLayoutSettled: false,
            confirmedMemberCountsByGroupID: ["group-flat-00": 1],
            filteredAccessibleConversationRawThreadIDs: [],
            confirmedRawThreadIDsByGroupKey: [
                "group-flat-00": ["conversation-500-0000"]
            ]
        )
        let retainedUnsettled = await recorder.recordRenderedOrganizerSnapshot(
            unsettled,
            newlyVisibleCount: 1
        )
        XCTAssertTrue(retainedUnsettled)
        _ = await recorder.recordEvent(.betterMailCommit, status: .success)
        _ = await recorder.recordEvent(.rethreadComplete, status: .success)

        let beforeSettlement = await recorder.report()
        XCTAssertFalse(beforeSettlement.eventSummary.contains { $0.event == .groupVisible })
        XCTAssertFalse(beforeSettlement.eventSummary.contains { $0.event == .visibleResult })

        let settled = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: ["group-flat-00": 1],
            filteredAccessibleConversationRawThreadIDs: [],
            confirmedRawThreadIDsByGroupKey: [
                "group-flat-00": ["conversation-500-0000"]
            ]
        )
        let recordedSettled = await recorder.recordRenderedOrganizerSnapshot(
            settled,
            newlyVisibleCount: 0
        )
        XCTAssertTrue(recordedSettled)

        let report = await recorder.report()
        XCTAssertEqual(report.eventSummary.filter { $0.event == .groupVisible }.count, 1)
        XCTAssertEqual(report.eventSummary.first { $0.event == .groupVisible }?.count, 1)
        XCTAssertEqual(report.eventSummary.filter { $0.event == .visibleResult }.count, 1)
        XCTAssertEqual(report.eventSummary.suffix(2).map(\.event), [
            .groupVisible,
            .visibleResult
        ])
    }

    func test_timedFailureDiscardsUnsettledPlacementVisibility() async throws {
        let recorder = try OrganizerMetricsRecorder(
            runID: "synthetic-placement-failed-unsettled",
            fixtureID: "organizer-500-v1",
            protocolID: "visual-email-organizer-v1",
            evidenceType: .timedHumanTask,
            generatedAt: timestamp,
            defaultStratum: .warm,
            targetOutcome: .placement,
            taskContract: OrganizerMetricTaskContract(
                taskID: .placementSet,
                sourceNodeKeys: ["node-500-0000"],
                destinationGroupKeys: ["group-flat-00"],
                queryKey: nil
            ),
            runtimeTaskContract: OrganizerMetricRuntimeTaskContract(
                expectedMemberships: [OrganizerMetricExpectedMembership(
                    rawThreadID: "conversation-500-0000",
                    destinationGroupKey: "group-flat-00"
                )],
                placementSetID: "placement-set-failed-unsettled",
                allowsRetrievalTiming: false
            )
        )
        _ = await recorder.recordEvent(.workspaceReady, status: .success)
        _ = await recorder.recordEvent(.taskVisible, status: .success)
        _ = await recorder.beginTimedEvent(kind: .firstAction,
                                           stratum: .warm,
                                           event: .taskReady)
        _ = await recorder.recordEvent(.actionStart)
        let unsettled = OrganizerRenderedGraphSnapshot(
            isLayoutSettled: false,
            confirmedMemberCountsByGroupID: ["group-flat-00": 1],
            filteredAccessibleConversationRawThreadIDs: [],
            confirmedRawThreadIDsByGroupKey: [
                "group-flat-00": ["conversation-500-0000"]
            ]
        )
        _ = await recorder.recordRenderedOrganizerSnapshot(unsettled,
                                                            newlyVisibleCount: 1)
        let failed = await recorder.failActiveTimedEvents(
            outcome: .failure,
            failureReason: .actionFailure
        )
        XCTAssertTrue(failed)
        _ = await recorder.recordEvent(.betterMailCommit, status: .success)
        _ = await recorder.recordEvent(.rethreadComplete, status: .success)
        let settled = OrganizerRenderedGraphSnapshot(
            confirmedMemberCountsByGroupID: ["group-flat-00": 1],
            filteredAccessibleConversationRawThreadIDs: [],
            confirmedRawThreadIDsByGroupKey: [
                "group-flat-00": ["conversation-500-0000"]
            ]
        )
        _ = await recorder.recordRenderedOrganizerSnapshot(settled,
                                                            newlyVisibleCount: 0)

        let report = await recorder.report()
        XCTAssertFalse(report.eventSummary.contains { $0.event == .groupVisible })
        XCTAssertFalse(report.eventSummary.contains { $0.event == .visibleResult })
    }

    func test_runtimeTiming_concurrentDuplicateStartsAndFinishesEmitExactlyOnePair() async throws {
        let clock = OrganizerMetricsTestClock(values: [0, 1, 2, 10, 20])
        let recorder = try makeRecorder(monotonicClock: OrganizerMetricsMonotonicClock(
            readMilliseconds: { clock.read() }
        ))

        let workspaceReady = await recorder.recordEvent(.workspaceReady, status: .success)
        let taskVisible = await recorder.recordEvent(.taskVisible, status: .success)
        XCTAssertTrue(workspaceReady)
        XCTAssertTrue(taskVisible)
        let startCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await recorder.beginTimedEvent(kind: .fiveConversation,
                                                   stratum: .coldRelaunch,
                                                   event: .taskReady)
                }
            }
            var count = 0
            for await didStart in group where didStart {
                count += 1
            }
            return count
        }
        let didFinish = await recorder.failActiveTimedEvents(outcome: .cancelled,
                                                             failureReason: .cancelled)
        let duplicateFinish = await recorder.finishTimedEvent(kind: .fiveConversation,
                                                              event: .cancelled,
                                                              outcome: .cancelled)

        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(didFinish)
        XCTAssertFalse(duplicateFinish)
        let report = await recorder.report()
        XCTAssertEqual(report.eventSummary.count, 4)
        XCTAssertEqual(report.eventSummary.map(\.phase), [.instant, .instant, .started, .finished])
        XCTAssertEqual(report.eventSummary.last?.status, .cancelled)
        XCTAssertEqual(report.eventSummary.last?.durationMilliseconds, 120_001)
        let summary = try XCTUnwrap(report.timing.first {
            $0.kind == .fiveConversation && $0.stratum == .coldRelaunch
        })
        XCTAssertEqual(summary.sampleCount, 1)
        XCTAssertEqual(summary.cancelledCount, 1)
    }

    func test_runtimeEvents_rejectInvalidCountsAndBackwardsClockWithoutPartialEvidence() async throws {
        let clock = OrganizerMetricsTestClock(values: [100, 90, 110])
        let recorder = try makeRecorder(monotonicClock: OrganizerMetricsMonotonicClock(
            readMilliseconds: { clock.read() }
        ))

        let backwardsEvent = await recorder.recordEvent(.workspaceReady)
        let invalidCount = await recorder.recordEvent(.selection, count: 0)
        let report = await recorder.report()

        XCTAssertFalse(backwardsEvent)
        XCTAssertFalse(invalidCount)
        XCTAssertTrue(report.eventSummary.isEmpty)
    }

    func test_runtimeEvents_rejectOutOfOrderCanonicalEvents() async throws {
        let recorder = try makeRecorder()

        let earlyAction = await recorder.recordEvent(.actionStart)
        let workspaceReady = await recorder.recordEvent(.workspaceReady, status: .success)
        let earlyTaskReady = await recorder.recordEvent(.taskReady)
        let taskVisible = await recorder.recordEvent(.taskVisible, status: .success)
        let taskReady = await recorder.beginTimedEvent(kind: .firstAction,
                                                       stratum: .warm,
                                                       event: .taskReady)
        let earlyCommit = await recorder.recordEvent(.betterMailCommit, status: .success)
        let actionStarted = await recorder.recordEvent(.actionStart)
        let earlyRethread = await recorder.recordEvent(.rethreadComplete, status: .success)
        let committed = await recorder.recordEvent(.betterMailCommit, status: .success)
        let earlyVisible = await recorder.finishTimedEvent(kind: .firstAction,
                                                           event: .visibleResult,
                                                           outcome: .success)
        let rethreaded = await recorder.recordEvent(.rethreadComplete, status: .success)
        let visible = await recorder.finishTimedEvent(kind: .firstAction,
                                                      event: .visibleResult,
                                                      outcome: .success)

        XCTAssertFalse(earlyAction)
        XCTAssertTrue(workspaceReady)
        XCTAssertFalse(earlyTaskReady)
        XCTAssertTrue(taskVisible)
        XCTAssertTrue(taskReady)
        XCTAssertFalse(earlyCommit)
        XCTAssertTrue(actionStarted)
        XCTAssertFalse(earlyRethread)
        XCTAssertTrue(committed)
        XCTAssertFalse(earlyVisible)
        XCTAssertTrue(rethreaded)
        XCTAssertTrue(visible)

        let report = await recorder.report()
        XCTAssertEqual(report.eventSummary.map(\.event), [
            .workspaceReady,
            .taskVisible,
            .taskReady,
            .actionStart,
            .betterMailCommit,
            .rethreadComplete,
            .visibleResult
        ])
    }

    func test_dropProtocol_rejectsOutOfOrderAndDuplicateLifecycleEvents() async throws {
        let recorder = try makeRecorder()

        _ = await recorder.recordEvent(.workspaceReady, status: .success)
        _ = await recorder.recordEvent(.taskVisible, status: .success)
        _ = await recorder.recordEvent(.taskReady, status: .success)

        let earlyHighlight = await recorder.recordEvent(.dropHighlight, status: .success)
        let earlyRelease = await recorder.recordEvent(.dropRelease, status: .success)
        let earlyOutcome = await recorder.recordEvent(.dropOutcome, status: .success)
        let actionStarted = await recorder.recordEvent(.actionStart)
        let intent = await recorder.recordEvent(.dropIntent)
        let duplicateIntent = await recorder.recordEvent(.dropIntent)
        let highlight = await recorder.recordEvent(.dropHighlight, status: .success)
        let duplicateHighlight = await recorder.recordEvent(.dropHighlight, status: .success)
        let release = await recorder.recordEvent(.dropRelease, status: .success)
        let duplicateRelease = await recorder.recordEvent(.dropRelease, status: .success)
        let outcome = await recorder.recordEvent(.dropOutcome, status: .success)
        let duplicateOutcome = await recorder.recordEvent(.dropOutcome, status: .success)

        XCTAssertFalse(earlyHighlight)
        XCTAssertFalse(earlyRelease)
        XCTAssertFalse(earlyOutcome)
        XCTAssertTrue(actionStarted)
        XCTAssertTrue(intent)
        XCTAssertFalse(duplicateIntent)
        XCTAssertTrue(highlight)
        XCTAssertFalse(duplicateHighlight)
        XCTAssertTrue(release)
        XCTAssertFalse(duplicateRelease)
        XCTAssertTrue(outcome)
        XCTAssertFalse(duplicateOutcome)

        let report = await recorder.report()
        XCTAssertEqual(report.eventSummary.map(\.event), [
            .workspaceReady,
            .taskVisible,
            .taskReady,
            .actionStart,
            .dropIntent,
            .dropHighlight,
            .dropRelease,
            .dropOutcome
        ])
    }

    func test_renderedGroupVisibleBeforeRethreadQueuesOnceAndFlushesInCanonicalOrder() async throws {
        let recorder = try makeRecorder()

        let workspaceReady = await recorder.recordEvent(.workspaceReady, status: .success)
        let taskVisible = await recorder.recordEvent(.taskVisible, status: .success)
        let taskReady = await recorder.beginTimedEvent(kind: .firstAction,
                                                       stratum: .warm,
                                                       event: .taskReady)
        let actionStarted = await recorder.recordEvent(.actionStart)
        let committed = await recorder.recordEvent(.betterMailCommit, status: .success)
        let rendered = await recorder.recordRenderedGroupVisible(count: 2)
        XCTAssertTrue(workspaceReady)
        XCTAssertTrue(taskVisible)
        XCTAssertTrue(taskReady)
        XCTAssertTrue(actionStarted)
        XCTAssertTrue(committed)
        XCTAssertTrue(rendered)
        let queuedReport = await recorder.report()
        XCTAssertFalse(queuedReport.eventSummary.contains { $0.event == .groupVisible })
        XCTAssertFalse(queuedReport.eventSummary.contains { $0.event == .visibleResult })

        let rethreaded = await recorder.recordEvent(.rethreadComplete, status: .success)
        XCTAssertTrue(rethreaded)
        let report = await recorder.report()
        XCTAssertEqual(report.eventSummary.map(\.event), [
            .workspaceReady,
            .taskVisible,
            .taskReady,
            .actionStart,
            .betterMailCommit,
            .rethreadComplete,
            .groupVisible,
            .visibleResult
        ])
        XCTAssertEqual(report.eventSummary.first { $0.event == .groupVisible }?.count, 2)
        XCTAssertEqual(report.eventSummary.first { $0.event == .visibleResult }?.count, 2)
        let timing = try XCTUnwrap(report.timing.first {
            $0.kind == .firstAction && $0.stratum == .warm
        })
        XCTAssertEqual(timing.sampleCount, 1)
        XCTAssertEqual(timing.successCount, 1)
    }

    func test_renderedGroupVisibleBeforeCommitRetainsActiveActionAndFlushesOnce() async throws {
        let recorder = try makeRecorder()

        let workspaceReady = await recorder.recordEvent(.workspaceReady, status: .success)
        let taskVisible = await recorder.recordEvent(.taskVisible, status: .success)
        let taskReady = await recorder.recordEvent(.taskReady, status: .success)
        let actionStarted = await recorder.recordEvent(.actionStart)
        let dropIntended = await recorder.recordEvent(.dropIntent)
        let rendered = await recorder.recordRenderedGroupVisible(count: 2)
        XCTAssertTrue(workspaceReady)
        XCTAssertTrue(taskVisible)
        XCTAssertTrue(taskReady)
        XCTAssertTrue(actionStarted)
        XCTAssertTrue(dropIntended)
        XCTAssertTrue(rendered)

        let queuedReport = await recorder.report()
        XCTAssertFalse(queuedReport.eventSummary.contains { $0.event == .groupVisible })
        XCTAssertFalse(queuedReport.eventSummary.contains { $0.event == .visibleResult })

        let committed = await recorder.recordEvent(.betterMailCommit, status: .success)
        let rethreaded = await recorder.recordEvent(.rethreadComplete, status: .success)
        XCTAssertTrue(committed)
        XCTAssertTrue(rethreaded)

        let report = await recorder.report()
        XCTAssertEqual(report.eventSummary.map(\.event), [
            .workspaceReady,
            .taskVisible,
            .taskReady,
            .actionStart,
            .dropIntent,
            .betterMailCommit,
            .rethreadComplete,
            .groupVisible,
            .visibleResult
        ])
        XCTAssertEqual(report.eventSummary.filter { $0.event == .groupVisible }.count, 1)
        XCTAssertEqual(report.eventSummary.first { $0.event == .groupVisible }?.count, 2)
        XCTAssertEqual(report.eventSummary.filter { $0.event == .visibleResult }.count, 1)
    }

    func test_failedActionDiscardsRenderedVisibilityQueuedBeforeCommit() async throws {
        let recorder = try makeRecorder()

        _ = await recorder.recordEvent(.workspaceReady, status: .success)
        _ = await recorder.recordEvent(.taskVisible, status: .success)
        _ = await recorder.recordEvent(.taskReady, status: .success)
        _ = await recorder.recordEvent(.actionStart)
        let rendered = await recorder.recordRenderedGroupVisible(count: 2)
        let failed = await recorder.recordEvent(.failure,
                                                status: .failure,
                                                failureReason: .actionFailure)
        XCTAssertTrue(rendered)
        XCTAssertTrue(failed)
        _ = await recorder.recordEvent(.betterMailCommit, status: .success)
        _ = await recorder.recordEvent(.rethreadComplete, status: .success)

        let report = await recorder.report()
        XCTAssertFalse(report.eventSummary.contains { $0.event == .groupVisible })
        XCTAssertFalse(report.eventSummary.contains { $0.event == .visibleResult })
    }

    func test_renderedGroupVisibleBeforeCommitCannotQueueStartupRendering() async throws {
        let recorder = try makeRecorder()

        let startupRendered = await recorder.recordRenderedGroupVisible(count: 8)
        XCTAssertFalse(startupRendered)
        _ = await recorder.recordEvent(.workspaceReady, status: .success)
        _ = await recorder.recordEvent(.taskVisible, status: .success)
        _ = await recorder.beginTimedEvent(kind: .firstAction,
                                           stratum: .warm,
                                           event: .taskReady)
        _ = await recorder.recordEvent(.actionStart)
        _ = await recorder.recordEvent(.betterMailCommit, status: .success)
        _ = await recorder.recordEvent(.rethreadComplete, status: .success)

        let report = await recorder.report()
        XCTAssertFalse(report.eventSummary.contains { $0.event == .groupVisible })
        XCTAssertFalse(report.eventSummary.contains { $0.event == .visibleResult })
    }

    func test_retrievalRequiresNineteenOfTwentyTrialsWithinFiveSeconds() async throws {
        let passingRecorder = try makeRecorder()
        let failingRecorder = try makeRecorder()
        for index in 0..<20 {
            try await passingRecorder.recordTimed(kind: .retrieval,
                                                  stratum: .warm,
                                                  sampleID: "synthetic-retrieval-pass-\(index)",
                                                  durationMilliseconds: index < 19 ? 1_000 : 5_001,
                                                  outcome: .success,
                                                  recordedAt: timestamp)
            try await failingRecorder.recordTimed(kind: .retrieval,
                                                  stratum: .warm,
                                                  sampleID: "synthetic-retrieval-fail-\(index)",
                                                  durationMilliseconds: index < 18 ? 1_000 : 5_001,
                                                  outcome: .success,
                                                  recordedAt: timestamp)
        }

        let passingReport = await passingRecorder.report()
        let failingReport = await failingRecorder.report()
        let passing = try XCTUnwrap(passingReport.timing.first {
            $0.kind == .retrieval && $0.stratum == .warm
        })
        let failing = try XCTUnwrap(failingReport.timing.first {
            $0.kind == .retrieval && $0.stratum == .warm
        })
        XCTAssertEqual(passing.withinThresholdCount, 19)
        XCTAssertEqual(passing.withinThresholdRate!, 0.95, accuracy: 0.0001)
        XCTAssertEqual(passing.status, .pass)
        XCTAssertEqual(failing.withinThresholdCount, 18)
        XCTAssertEqual(failing.withinThresholdRate!, 0.90, accuracy: 0.0001)
        XCTAssertEqual(failing.status, .fail)
    }

    func test_dropReportEvaluatesAggregateAndPerStratumRates() async throws {
        let recorder = try makeRecorder()
        for index in 0..<120 {
            try await recorder.recordDrop(source: .deterministicMatrix,
                                          stratum: index.isMultiple(of: 2) ? .warm : .coldRelaunch,
                                          sampleID: "synthetic-drop-\(index)",
                                          attemptCount: 1,
                                          successCount: 1,
                                          outcome: .success,
                                          recordedAt: timestamp)
        }
        for index in 0..<40 {
            try await recorder.recordDrop(source: .livePointer,
                                          stratum: .warm,
                                          sampleID: "synthetic-live-drop-\(index)",
                                          attemptCount: 1,
                                          successCount: 1,
                                          outcome: .success,
                                          recordedAt: timestamp)
        }

        let report = await recorder.report()
        let matrixAggregate = try XCTUnwrap(report.drops.first {
            $0.source == .deterministicMatrix && $0.stratum == .aggregate
        })
        let live = try XCTUnwrap(report.drops.first {
            $0.source == .livePointer && $0.stratum == .warm
        })
        XCTAssertEqual(matrixAggregate.attemptCount, 120)
        XCTAssertEqual(matrixAggregate.successRate, 1.0)
        XCTAssertEqual(matrixAggregate.status, .pass)
        XCTAssertEqual(live.attemptCount, 40)
        XCTAssertEqual(live.status, .pass)
    }

    func test_livePointerDropRequiresThirtyEightOfFortySuccessfulAttempts() async throws {
        let passingRecorder = try makeRecorder()
        let failingRecorder = try makeRecorder()
        for index in 0..<40 {
            try await passingRecorder.recordDrop(source: .livePointer,
                                                  stratum: .warm,
                                                  sampleID: "synthetic-live-threshold-pass-\(index)",
                                                  attemptCount: 1,
                                                  successCount: index < 38 ? 1 : 0,
                                                  outcome: index < 38 ? .success : .failure,
                                                  recordedAt: timestamp)
            try await failingRecorder.recordDrop(source: .livePointer,
                                                  stratum: .warm,
                                                  sampleID: "synthetic-live-threshold-fail-\(index)",
                                                  attemptCount: 1,
                                                  successCount: index < 37 ? 1 : 0,
                                                  outcome: index < 37 ? .success : .failure,
                                                  recordedAt: timestamp)
        }

        let passingReport = await passingRecorder.report()
        let failingReport = await failingRecorder.report()
        let passing = try XCTUnwrap(passingReport.drops.first {
            $0.source == .livePointer && $0.stratum == .warm
        })
        let failing = try XCTUnwrap(failingReport.drops.first {
            $0.source == .livePointer && $0.stratum == .warm
        })
        XCTAssertEqual(passing.successRate!, 0.95, accuracy: 0.0001)
        XCTAssertEqual(passing.status, .pass)
        XCTAssertEqual(failing.successRate!, 0.925, accuracy: 0.0001)
        XCTAssertEqual(failing.status, .fail)
    }

    func test_wrongPlacementRequiresFiveIndependentSetsAndBoundsEachSet() async throws {
        let recorder = try makeRecorder()
        for index in 0..<5 {
            try await recorder.recordWrongPlacement(stratum: .warm,
                                                    sampleID: "synthetic-placement-\(index)",
                                                    setID: "set-placement-\(index)",
                                                    attemptCount: 20,
                                                    wrongPlacementCount: 1,
                                                    outcome: .success,
                                                    recordedAt: timestamp)
        }

        let report = await recorder.report()
        let summary = try XCTUnwrap(report.wrongPlacements.first {
            $0.stratum == .warm
        })
        XCTAssertEqual(summary.setCount, 5)
        XCTAssertEqual(summary.totalAttemptCount, 100)
        XCTAssertEqual(summary.maximumWrongPlacementCountPerSet, 1)
        XCTAssertEqual(summary.status, .pass)
    }

    func test_wrongPlacementRejectsDuplicateIndependentSetID() async throws {
        let recorder = try makeRecorder()
        try await recorder.recordWrongPlacement(stratum: .warm,
                                                sampleID: "synthetic-placement-first",
                                                setID: "set-placement-shared",
                                                attemptCount: 20,
                                                wrongPlacementCount: 0,
                                                outcome: .success,
                                                recordedAt: timestamp)

        do {
            try await recorder.recordWrongPlacement(stratum: .warm,
                                                    sampleID: "synthetic-placement-second",
                                                    setID: "set-placement-shared",
                                                    attemptCount: 20,
                                                    wrongPlacementCount: 0,
                                                    outcome: .success,
                                                    recordedAt: timestamp)
            XCTFail("Duplicate independent placement sets must be rejected")
        } catch let error as OrganizerMetricsRecorderError {
            XCTAssertEqual(error, .duplicateSetIdentifier)
        }

        let report = await recorder.report()
        XCTAssertEqual(report.wrongPlacements.first?.setCount, 1)
    }

    func test_suggestionAggregateCountsCannotClaimPrecisionEvidence() async throws {
        let recorder = try makeRecorder()
        for (index, slice) in OrganizerSuggestionSlice.allCases.enumerated() {
            try await recorder.recordSuggestion(strictness: .conservative,
                                                 slice: slice,
                                                 sampleID: "synthetic-suggestion-\(index)",
                                                 candidateCount: 80,
                                                 acceptedCount: 40,
                                                 correctAcceptedCount: 34,
                                                 nonAbstainedCount: 80,
                                                 recordedAt: timestamp)
        }

        let report = await recorder.report()
        let summary = try XCTUnwrap(report.suggestions.first {
            $0.strictness == .conservative
        })
        XCTAssertEqual(summary.candidateCount, 240)
        XCTAssertEqual(summary.acceptedCount, 120)
        XCTAssertEqual(summary.correctAcceptedCount, 102)
        XCTAssertEqual(summary.precision!, 0.85, accuracy: 0.0001)
        XCTAssertEqual(summary.coverage!, 1.0, accuracy: 0.0001)
        XCTAssertTrue(summary.slices.allSatisfy { $0.acceptedCount == 40 })
        let unrelated = try XCTUnwrap(summary.slices.first { $0.slice == .unrelated })
        XCTAssertEqual(unrelated.denominator, .nonAbstainedDecisions)
        XCTAssertEqual(unrelated.qualifyingDecisionCount, 80)
        XCTAssertEqual(unrelated.minimumQualifyingDecisionCount, 25)
        XCTAssertEqual(summary.status, .insufficientEvidence)
    }

    func test_suggestionPredictionInputStructurallyExcludesGoldAdjudication() throws {
        let input = OrganizerSuggestionCandidateInput(
            candidateKey: "candidate-opaque-a",
            sourceKey: "source-opaque-a",
            targetKey: "destination-opaque-a",
            sourceTitle: "Synthetic launch review",
            sourceSummary: "Synthetic review request for Project Atlas.",
            sourceContent: "Please review the Project Atlas launch checklist.",
            targetTitle: "Project Atlas launch",
            targetSummary: "Synthetic Project Atlas launch work.",
            targetContent: "Launch checklist and review actions.",
            targetIsFolderProfile: true
        )

        let data = try JSONEncoder().encode(input)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()
        for forbidden in ["gold", "expected", "relation", "confidenceband", "provenance"] {
            XCTAssertFalse(text.contains(forbidden), "Prediction input leaked evaluator field: \(forbidden)")
        }
    }

    func test_suggestionEvaluatorJoinsIndependentPredictionsAndReportsEverySlice() throws {
        let evidence = makeSuggestionEvaluationEvidence(incorrectAcceptedCount: 16)
        let report = OrganizerSuggestionEvaluator.evaluate(
            pins: try XCTUnwrap(makeSuggestionPins(origin: .frozenProductionPredictions)),
            corpusQuality: try XCTUnwrap(makeSuggestionCorpusQuality()),
            goldRecords: evidence.gold,
            predictions: evidence.predictions
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertTrue(report.issueCodes.isEmpty)
        XCTAssertEqual(report.candidateCount, 240)
        XCTAssertEqual(report.acceptedCount, 112)
        XCTAssertEqual(report.correctAcceptedCount, 96)
        XCTAssertEqual(report.falsePositiveCount, 16)
        XCTAssertEqual(report.precision!, 96.0 / 112.0, accuracy: 0.0001)
        XCTAssertEqual(report.coverage!, 1, accuracy: 0.0001)
        XCTAssertEqual(report.slices.count, 9)
        XCTAssertTrue(report.slices.allSatisfy {
            $0.qualifyingDecisionCount >= $0.minimumQualifyingDecisionCount
        })
        let unrelated = try XCTUnwrap(report.slices.first {
            $0.dimension == .relation && $0.value == OrganizerSuggestionSlice.unrelated.rawValue
        })
        XCTAssertEqual(unrelated.denominator, .nonAbstainedDecisions)
        XCTAssertEqual(unrelated.acceptedCount, 0)
        XCTAssertEqual(unrelated.qualifyingDecisionCount, 80)
    }

    func test_suggestionArtifactEvaluatorBindsBytesAndKeepsGoldOutOfProviderInput() throws {
        let artifacts = try makeSuggestionArtifacts()
        let report = OrganizerSuggestionArtifactEvaluator.evaluate(
            inputArtifactData: artifacts.input,
            goldArtifactData: artifacts.gold,
            predictionArtifactData: artifacts.predictions
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertTrue(report.issueCodes.isEmpty)
        XCTAssertEqual(report.corpusQuality?.inputArtifactSHA256,
                       OrganizerSuggestionArtifactEvaluator.sha256Hex(artifacts.input))
        XCTAssertEqual(report.corpusQuality?.goldArtifactSHA256,
                       OrganizerSuggestionArtifactEvaluator.sha256Hex(artifacts.gold))

        let inputText = try XCTUnwrap(String(data: artifacts.input, encoding: .utf8)).lowercased()
        for forbidden in ["gold", "expected", "relation", "confidenceband", "provenance"] {
            XCTAssertFalse(inputText.contains(forbidden), "Provider artifact leaked: \(forbidden)")
        }
    }

    /// Manual acceptance harness. Normal test runs skip this method; an
    /// explicit environment flag runs the checked-in provider-input bytes
    /// through BetterMail's actual Foundation Models relationship provider,
    /// checkpoints gold-blind predictions, and evaluates only after generation.
    @MainActor
    func test_productionSuggestionAcceptanceRun_whenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let explicitRunSentinel = "/tmp/bettermail-run-production-suggestions.enabled"
        guard environment["BETTERMAIL_RUN_PRODUCTION_SUGGESTIONS"] == "1"
                || fileManager.fileExists(atPath: explicitRunSentinel) else {
            throw XCTSkip("Production suggestion acceptance run was not explicitly requested.")
        }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureRoot = repositoryRoot
            .appendingPathComponent("Tests/Fixtures/Organizer", isDirectory: true)
        let inputURL = fixtureRoot.appendingPathComponent("suggestion-input-v2.json")
        let goldURL = fixtureRoot.appendingPathComponent("suggestion-gold-v2.json")
        let predictionURL = environment["BETTERMAIL_SUGGESTION_PREDICTION_OUTPUT"].map {
            URL(fileURLWithPath: $0)
        } ?? fileManager.temporaryDirectory
            .appendingPathComponent("bettermail-suggestion-predictions-v2.json")
        let resultURL = environment["BETTERMAIL_SUGGESTION_RESULT_OUTPUT"].map {
            URL(fileURLWithPath: $0)
        } ?? fileManager.temporaryDirectory
            .appendingPathComponent("bettermail-suggestion-evaluation-v2.json")

        let inputData = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        let inputArtifact = try JSONDecoder().decode(OrganizerSuggestionInputArtifact.self,
                                                     from: inputData)
        XCTAssertEqual(inputArtifact.schemaVersion,
                       OrganizerSuggestionInputArtifact.currentSchemaVersion)
        XCTAssertEqual(inputArtifact.corpusID, "organizer-suggestion-v2")

        let capability = GraphRelationshipProviderFactory.makeCapability()
        guard let provider = capability.provider else {
            return XCTFail("Production relationship provider unavailable: \(capability.statusMessage)")
        }
        if environment["BETTERMAIL_SUGGESTION_SMOKE_ONLY"] == "1"
            || fileManager.fileExists(atPath: "/tmp/bettermail-suggestion-smoke-only.enabled") {
            let candidate = try XCTUnwrap(inputArtifact.candidates.first)
            let signal = try await provider.relationship(for: relationshipRequest(for: candidate))
            XCTAssertEqual(signal.relationship, .sameConversation)
            XCTAssertTrue(signal.hasSharedNamedTopic)
            XCTAssertTrue(signal.hasSameConcreteActionOrEvent)
            return
        }

        let inputDigest = OrganizerSuggestionArtifactEvaluator.sha256Hex(inputData)
        let appBuild = environment["BETTERMAIL_SUGGESTION_APP_BUILD"]
            ?? "1.0-1-local-20260824"
        let pins = try XCTUnwrap(OrganizerSuggestionVersionPins(
            corpusID: inputArtifact.corpusID,
            provider: "foundation-models-graph-relationship",
            modelVersion: capability.providerVersion,
            promptOrPolicyVersion: "organization-placement-policy-v1",
            strictness: .conservative,
            appBuild: appBuild,
            evidenceOrigin: .productionProvider
        ))

        var predictions: [OrganizerSuggestionPrediction] = []
        if FileManager.default.fileExists(atPath: predictionURL.path) {
            let checkpointData = try Data(contentsOf: predictionURL, options: [.mappedIfSafe])
            let checkpoint = try JSONDecoder().decode(OrganizerSuggestionPredictionArtifact.self,
                                                      from: checkpointData)
            guard checkpoint.corpusID == inputArtifact.corpusID,
                  checkpoint.inputArtifactSHA256 == inputDigest,
                  checkpoint.pins == pins else {
                return XCTFail("Existing prediction checkpoint does not match the exact input bytes and pins.")
            }
            predictions = checkpoint.predictions
        }

        let knownSources = Set(inputArtifact.candidates.map(\.sourceKey))
        guard predictions.allSatisfy({ knownSources.contains($0.sourceKey) }),
              Set(predictions.map(\.sourceKey)).count == predictions.count else {
            return XCTFail("Existing prediction checkpoint contains an unknown or duplicate source.")
        }
        var completedSources = Set(predictions.map(\.sourceKey))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for candidate in inputArtifact.candidates where !completedSources.contains(candidate.sourceKey) {
            let prediction: OrganizerSuggestionPrediction
            do {
                let signal = try await provider.relationship(for: relationshipRequest(for: candidate))
                prediction = productionPrediction(for: candidate, signal: signal)
            } catch {
                prediction = OrganizerSuggestionPrediction(candidateKey: candidate.candidateKey,
                                                           sourceKey: candidate.sourceKey,
                                                           decision: .abstained,
                                                           proposedDestinationKey: nil)
                print("Production provider abstained after error: \(error.localizedDescription)")
            }
            predictions.append(prediction)
            completedSources.insert(candidate.sourceKey)
            let checkpoint = OrganizerSuggestionPredictionArtifact(
                corpusID: inputArtifact.corpusID,
                inputArtifactSHA256: inputDigest,
                pins: pins,
                predictions: predictions
            )
            try encoder.encode(checkpoint).write(to: predictionURL, options: .atomic)
            if predictions.count.isMultiple(of: 10) || predictions.count == inputArtifact.candidates.count {
                print("Production suggestion predictions: \(predictions.count)/\(inputArtifact.candidates.count)")
            }
        }

        let report = OrganizerSuggestionArtifactEvaluator.evaluate(
            inputArtifactURL: inputURL,
            goldArtifactURL: goldURL,
            predictionArtifactURL: predictionURL
        )
        try encoder.encode(report).write(to: resultURL, options: .atomic)
        XCTAssertEqual(report.candidateCount, inputArtifact.candidates.count)
        XCTAssertEqual(report.status,
                       .pass,
                       "Production suggestion gate issues: \(report.issueCodes.map(\.rawValue).joined(separator: ", "))")
    }

    func test_suggestionArtifactEvaluatorScoresWrongOpaqueDestinationAsFalsePositive() throws {
        let artifacts = try makeSuggestionArtifacts(incorrectAcceptedCount: 16)
        let report = OrganizerSuggestionArtifactEvaluator.evaluate(
            inputArtifactData: artifacts.input,
            goldArtifactData: artifacts.gold,
            predictionArtifactData: artifacts.predictions
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertFalse(report.issueCodes.contains(.invalidPredictionArtifact))
        XCTAssertEqual(report.acceptedCount, 112)
        XCTAssertEqual(report.correctAcceptedCount, 96)
        XCTAssertEqual(report.falsePositiveCount, 16)
    }

    func test_suggestionArtifactEvaluatorScoresAcceptedUnrelatedControlAsFalsePositive() throws {
        let artifacts = try makeSuggestionArtifacts(acceptedUnrelatedPredictionCount: 1)
        let report = OrganizerSuggestionArtifactEvaluator.evaluate(
            inputArtifactData: artifacts.input,
            goldArtifactData: artifacts.gold,
            predictionArtifactData: artifacts.predictions
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertFalse(report.issueCodes.contains(.invalidPredictionArtifact))
        XCTAssertEqual(report.acceptedCount, 113)
        XCTAssertEqual(report.correctAcceptedCount, 112)
        XCTAssertEqual(report.falsePositiveCount, 1)
        let unrelated = try XCTUnwrap(report.slices.first {
            $0.dimension == .relation && $0.value == OrganizerSuggestionSlice.unrelated.rawValue
        })
        XCTAssertEqual(unrelated.denominator, .nonAbstainedDecisions)
        XCTAssertEqual(unrelated.acceptedCount, 1)
        XCTAssertEqual(unrelated.correctAcceptedCount, 0)
        XCTAssertEqual(unrelated.qualifyingDecisionCount, 80)
    }

    func test_suggestionArtifactEvaluatorRejectsAcceptedUnrelatedGoldOutcome() throws {
        let artifacts = try makeSuggestionArtifacts()
        let inputObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: artifacts.input) as? [String: Any]
        )
        let candidates = try XCTUnwrap(inputObject["candidates"] as? [[String: Any]])
        var targetByCandidate: [String: String] = [:]
        for candidate in candidates {
            if let candidateKey = candidate["candidateKey"] as? String,
               let targetKey = candidate["targetKey"] as? String {
                targetByCandidate[candidateKey] = targetKey
            }
        }

        var goldObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: artifacts.gold) as? [String: Any]
        )
        var records = try XCTUnwrap(goldObject["records"] as? [[String: Any]])
        let unrelatedIndex = try XCTUnwrap(records.firstIndex {
            $0["relation"] as? String == OrganizerSuggestionSlice.unrelated.rawValue
        })
        let candidateKey = try XCTUnwrap(records[unrelatedIndex]["candidateKey"] as? String)
        records[unrelatedIndex]["expectedLabel"] = OrganizerSuggestionGoldLabel.accepted.rawValue
        records[unrelatedIndex]["expectedDestinationKey"] = try XCTUnwrap(targetByCandidate[candidateKey])
        goldObject["records"] = records
        let invalidGold = try JSONSerialization.data(withJSONObject: goldObject,
                                                     options: [.sortedKeys])

        let report = OrganizerSuggestionArtifactEvaluator.evaluate(
            inputArtifactData: artifacts.input,
            goldArtifactData: invalidGold,
            predictionArtifactData: artifacts.predictions
        )

        XCTAssertEqual(report.status, .insufficientEvidence)
        XCTAssertTrue(report.issueCodes.contains(.invalidGoldAdjudication))
    }

    func test_suggestionArtifactEvaluatorRejectsDigestMismatchAndUnknownInputField() throws {
        let artifacts = try makeSuggestionArtifacts(inputDigestOverride: String(repeating: "0", count: 64))
        var inputObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: artifacts.input) as? [String: Any]
        )
        var candidates = try XCTUnwrap(inputObject["candidates"] as? [[String: Any]])
        candidates[0]["goldLabel"] = "accepted"
        inputObject["candidates"] = candidates
        let contaminatedInput = try JSONSerialization.data(withJSONObject: inputObject,
                                                           options: [.sortedKeys])

        let report = OrganizerSuggestionArtifactEvaluator.evaluate(
            inputArtifactData: contaminatedInput,
            goldArtifactData: artifacts.gold,
            predictionArtifactData: artifacts.predictions
        )

        XCTAssertEqual(report.status, .insufficientEvidence)
        XCTAssertTrue(report.issueCodes.contains(.artifactFieldContractViolation))
        XCTAssertTrue(report.issueCodes.contains(.inputArtifactDigestMismatch))
    }

    func test_suggestionArtifactEvaluatorFailsClosedOnMalformedArtifact() throws {
        let artifacts = try makeSuggestionArtifacts()
        let report = OrganizerSuggestionArtifactEvaluator.evaluate(
            inputArtifactData: Data("{".utf8),
            goldArtifactData: artifacts.gold,
            predictionArtifactData: artifacts.predictions
        )

        XCTAssertEqual(report.status, .insufficientEvidence)
        XCTAssertTrue(report.issueCodes.contains(.malformedInputArtifact))
    }

    func test_suggestionArtifactEvaluatorFailsClosedOnUnreadableFiles() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bettermail-missing-suggestion-artifacts-\(UUID().uuidString)",
                                    isDirectory: true)
        let report = OrganizerSuggestionArtifactEvaluator.evaluate(
            inputArtifactURL: missingRoot.appendingPathComponent("input.json"),
            goldArtifactURL: missingRoot.appendingPathComponent("gold.json"),
            predictionArtifactURL: missingRoot.appendingPathComponent("predictions.json")
        )

        XCTAssertEqual(report.status, .insufficientEvidence)
        XCTAssertTrue(report.issueCodes.contains(.unreadableInputArtifact))
        XCTAssertTrue(report.issueCodes.contains(.unreadableGoldArtifact))
        XCTAssertTrue(report.issueCodes.contains(.unreadablePredictionArtifact))
    }

    func test_suggestionEvaluatorRejectsDeterministicDoubleAsQualityEvidence() throws {
        let evidence = makeSuggestionEvaluationEvidence()
        let report = OrganizerSuggestionEvaluator.evaluate(
            pins: try XCTUnwrap(makeSuggestionPins(origin: .deterministicProviderDouble)),
            corpusQuality: try XCTUnwrap(makeSuggestionCorpusQuality()),
            goldRecords: evidence.gold,
            predictions: evidence.predictions
        )

        XCTAssertEqual(report.status, .insufficientEvidence)
        XCTAssertTrue(report.issueCodes.contains(.nonProductionEvidenceOrigin))
    }

    func test_suggestionEvaluatorDetectsSequentialKeyLabelLeakage() throws {
        let evidence = makeSuggestionEvaluationEvidence(sequentialKeys: true)
        let report = OrganizerSuggestionEvaluator.evaluate(
            pins: try XCTUnwrap(makeSuggestionPins(origin: .frozenProductionPredictions)),
            corpusQuality: try XCTUnwrap(makeSuggestionCorpusQuality()),
            goldRecords: evidence.gold,
            predictions: evidence.predictions
        )

        XCTAssertEqual(report.status, .insufficientEvidence)
        XCTAssertTrue(report.issueCodes.contains(.keyLabelLeakageDetected))
    }

    func test_suggestionEvaluatorReportsDuplicateSourceConflictWithoutShrinkingDenominator() throws {
        var evidence = makeSuggestionEvaluationEvidence()
        let first = try XCTUnwrap(evidence.predictions.first)
        evidence.predictions.append(
            OrganizerSuggestionPrediction(candidateKey: first.candidateKey,
                                          sourceKey: first.sourceKey,
                                          decision: .rejected,
                                          proposedDestinationKey: nil)
        )
        let report = OrganizerSuggestionEvaluator.evaluate(
            pins: try XCTUnwrap(makeSuggestionPins(origin: .frozenProductionPredictions)),
            corpusQuality: try XCTUnwrap(makeSuggestionCorpusQuality()),
            goldRecords: evidence.gold,
            predictions: evidence.predictions
        )

        XCTAssertEqual(report.status, .insufficientEvidence)
        XCTAssertEqual(report.candidateCount, 240)
        XCTAssertEqual(report.duplicatePredictionSourceCount, 1)
        XCTAssertEqual(report.conflictingSourceCount, 1)
        XCTAssertTrue(report.issueCodes.contains(.conflictingPredictionSource))
    }

    func test_suggestionEvaluatorCountsRejectedExpectedAcceptanceAsFalseNegative() throws {
        var evidence = makeSuggestionEvaluationEvidence()
        let index = try XCTUnwrap(evidence.gold.firstIndex { $0.expectedLabel == .accepted })
        let original = evidence.predictions[index]
        evidence.predictions[index] = OrganizerSuggestionPrediction(
            candidateKey: original.candidateKey,
            sourceKey: original.sourceKey,
            decision: .rejected,
            proposedDestinationKey: nil
        )
        let report = OrganizerSuggestionEvaluator.evaluate(
            pins: try XCTUnwrap(makeSuggestionPins(origin: .frozenProductionPredictions)),
            corpusQuality: try XCTUnwrap(makeSuggestionCorpusQuality()),
            goldRecords: evidence.gold,
            predictions: evidence.predictions
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertEqual(report.acceptedCount, 111)
        XCTAssertEqual(report.correctAcceptedCount, 111)
        XCTAssertEqual(report.falseNegativeCount, 1)
        XCTAssertEqual(report.nonAbstainedCount, 240)
    }

    func test_suggestionEvaluatorTreatsMissingAndExplicitAbstentionEqually() throws {
        let evidence = makeSuggestionEvaluationEvidence()
        let omitted = try XCTUnwrap(evidence.predictions.first)
        let missingReport = OrganizerSuggestionEvaluator.evaluate(
            pins: try XCTUnwrap(makeSuggestionPins(origin: .frozenProductionPredictions)),
            corpusQuality: try XCTUnwrap(makeSuggestionCorpusQuality()),
            goldRecords: evidence.gold,
            predictions: evidence.predictions.filter { $0.sourceKey != omitted.sourceKey }
        )
        let explicitPredictions = evidence.predictions.map { prediction in
            guard prediction.sourceKey == omitted.sourceKey else { return prediction }
            return OrganizerSuggestionPrediction(candidateKey: prediction.candidateKey,
                                                  sourceKey: prediction.sourceKey,
                                                  decision: .abstained,
                                                  proposedDestinationKey: nil)
        }
        let explicitReport = OrganizerSuggestionEvaluator.evaluate(
            pins: try XCTUnwrap(makeSuggestionPins(origin: .frozenProductionPredictions)),
            corpusQuality: try XCTUnwrap(makeSuggestionCorpusQuality()),
            goldRecords: evidence.gold,
            predictions: explicitPredictions
        )

        XCTAssertEqual(missingReport.status, .pass)
        XCTAssertEqual(explicitReport.status, .pass)
        XCTAssertEqual(missingReport.abstainedCount, 1)
        XCTAssertEqual(explicitReport.abstainedCount, 1)
        XCTAssertEqual(missingReport.nonAbstainedCount, explicitReport.nonAbstainedCount)
        XCTAssertEqual(missingReport.acceptedCount, explicitReport.acceptedCount)
        XCTAssertEqual(missingReport.correctAcceptedCount, explicitReport.correctAcceptedCount)
    }

    func test_suggestionArtifactEvaluatorRejectsUnknownGoldAndPredictionFields() throws {
        let artifacts = try makeSuggestionArtifacts()

        var goldObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: artifacts.gold) as? [String: Any]
        )
        var goldRecords = try XCTUnwrap(goldObject["records"] as? [[String: Any]])
        goldRecords[0]["unexpectedGoldField"] = true
        goldObject["records"] = goldRecords
        let unknownGold = try JSONSerialization.data(withJSONObject: goldObject,
                                                     options: [.sortedKeys])
        let goldReport = OrganizerSuggestionArtifactEvaluator.evaluate(
            inputArtifactData: artifacts.input,
            goldArtifactData: unknownGold,
            predictionArtifactData: artifacts.predictions
        )

        var predictionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: artifacts.predictions) as? [String: Any]
        )
        var predictions = try XCTUnwrap(predictionObject["predictions"] as? [[String: Any]])
        predictions[0]["unexpectedPredictionField"] = true
        predictionObject["predictions"] = predictions
        let unknownPredictions = try JSONSerialization.data(withJSONObject: predictionObject,
                                                            options: [.sortedKeys])
        let predictionReport = OrganizerSuggestionArtifactEvaluator.evaluate(
            inputArtifactData: artifacts.input,
            goldArtifactData: artifacts.gold,
            predictionArtifactData: unknownPredictions
        )

        XCTAssertEqual(goldReport.status, .insufficientEvidence)
        XCTAssertTrue(goldReport.issueCodes.contains(.artifactFieldContractViolation))
        XCTAssertEqual(predictionReport.status, .insufficientEvidence)
        XCTAssertTrue(predictionReport.issueCodes.contains(.artifactFieldContractViolation))
    }

    func test_suggestionEvaluatorReportsConflictingDuplicateGoldSource() throws {
        var evidence = makeSuggestionEvaluationEvidence()
        let first = try XCTUnwrap(evidence.gold.first)
        evidence.gold.append(
            OrganizerSuggestionGoldRecord(
                candidateKey: opaqueKey(prefix: "candidate", value: "conflicting-gold"),
                sourceKey: first.sourceKey,
                relation: .unrelated,
                confidenceBand: first.confidenceBand,
                provenance: first.provenance,
                expectedLabel: .rejected,
                expectedDestinationKey: nil
            )
        )
        let report = OrganizerSuggestionEvaluator.evaluate(
            pins: try XCTUnwrap(makeSuggestionPins(origin: .frozenProductionPredictions)),
            corpusQuality: try XCTUnwrap(makeSuggestionCorpusQuality()),
            goldRecords: evidence.gold,
            predictions: evidence.predictions
        )

        XCTAssertEqual(report.status, .insufficientEvidence)
        XCTAssertEqual(report.duplicateGoldSourceCount, 1)
        XCTAssertEqual(report.conflictingSourceCount, 1)
        XCTAssertTrue(report.issueCodes.contains(.conflictingGoldSource))
    }

    func test_suggestionEvaluatorDisclosesIdenticalDuplicatePredictionWithoutConflict() throws {
        var evidence = makeSuggestionEvaluationEvidence()
        let first = try XCTUnwrap(evidence.predictions.first)
        evidence.predictions.append(first)
        let report = OrganizerSuggestionEvaluator.evaluate(
            pins: try XCTUnwrap(makeSuggestionPins(origin: .frozenProductionPredictions)),
            corpusQuality: try XCTUnwrap(makeSuggestionCorpusQuality()),
            goldRecords: evidence.gold,
            predictions: evidence.predictions
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertEqual(report.rawPredictionCount, 241)
        XCTAssertEqual(report.duplicatePredictionSourceCount, 1)
        XCTAssertEqual(report.conflictingSourceCount, 0)
        XCTAssertFalse(report.issueCodes.contains(.conflictingPredictionSource))
    }

    func test_suggestionEvaluatorRequiresPinsAndProductionRelevantCorpus() {
        let evidence = makeSuggestionEvaluationEvidence()
        let quality = OrganizerSuggestionCorpusQuality(
            corpusID: "organizer-suggestion-gold-v1",
            inputArtifactSHA256: String(repeating: "a", count: 64),
            goldArtifactSHA256: String(repeating: "b", count: 64),
            hasProductionRelevantInputs: false,
            keysAreOpaqueAndLabelIndependent: false
        )
        let report = OrganizerSuggestionEvaluator.evaluate(
            pins: nil,
            corpusQuality: quality,
            goldRecords: evidence.gold,
            predictions: evidence.predictions
        )

        XCTAssertEqual(report.status, .insufficientEvidence)
        XCTAssertTrue(report.issueCodes.contains(.missingVersionPins))
        XCTAssertTrue(report.issueCodes.contains(.corpusInputsNotProductionRelevant))
        XCTAssertTrue(report.issueCodes.contains(.corpusKeysNotLabelIndependent))
    }

    func test_privacyBoundaryRejectsRawIdentifiersAndExportIsAggregateOnly() async throws {
        XCTAssertThrowsError(try OrganizerMetricsRecorder(runID: "raw-message-id",
                                                           fixtureID: "fixture-organizer-100-v1",
                                                           protocolID: "protocol-visual-email-organizer-v1",
                                                           generatedAt: timestamp)) { error in
            XCTAssertEqual(error as? OrganizerMetricsRecorderError, .invalidSyntheticIdentifier)
        }

        let recorder = try makeRecorder()
        for event in OrganizerMetricEventKind.allCases {
            let recorded = await recorder.recordEvent(event, count: 1, status: .success)
            XCTAssertTrue(recorded)
        }
        try await recorder.recordTimed(kind: .retrieval,
                                       stratum: .warm,
                                       sampleID: "synthetic-retrieval-0",
                                       durationMilliseconds: 1_000,
                                       outcome: .success,
                                       recordedAt: timestamp)
        let exported = try await recorder.exportJSON()
        let text = try XCTUnwrap(String(data: exported, encoding: .utf8))
        for forbidden in ["subject", "sender", "body", "snippet", "account", "mailbox", "route", "messageID", "threadID"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), "Leaked forbidden field: \(forbidden)")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let expectedKeys: Set<String> = [
            "schemaVersion",
            "runId",
            "fixtureId",
            "protocolId",
            "appBuild",
            "evidenceType",
            "generatedAt",
            "status",
            "records",
            "eventSummary",
            "timing",
            "drops",
            "wrongPlacements",
            "suggestions"
        ]
        XCTAssertTrue(expectedKeys.isSubset(of: Set(object.keys)))
        XCTAssertEqual(object["schemaVersion"] as? String, "visual-email-organizer-metrics-v1")
        XCTAssertEqual(object["runId"] as? String, "synthetic-run-1")
        XCTAssertEqual(object["fixtureId"] as? String, "fixture-organizer-100-v1")
        XCTAssertEqual(object["protocolId"] as? String, "protocol-visual-email-organizer-v1")
        XCTAssertEqual(object["appBuild"] as? String, "build-unknown")
        XCTAssertEqual(object["evidenceType"] as? String, "automated-logic")
        XCTAssertEqual((object["records"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(text.contains("synthetic-run-1"))
        XCTAssertTrue(text.contains("visual-email-organizer-metrics-v1"))
    }

    func test_duplicateAndInvalidCountsAreRejected() async throws {
        let recorder = try makeRecorder()
        try await recorder.recordDrop(source: .livePointer,
                                      stratum: .warm,
                                      sampleID: "synthetic-duplicate",
                                      attemptCount: 1,
                                      successCount: 1,
                                      outcome: .success,
                                      recordedAt: timestamp)
        do {
            try await recorder.recordDrop(source: .livePointer,
                                          stratum: .warm,
                                          sampleID: "synthetic-duplicate",
                                          attemptCount: 1,
                                          successCount: 1,
                                          outcome: .success,
                                          recordedAt: timestamp)
            XCTFail("Duplicate sample IDs must be rejected")
        } catch let error as OrganizerMetricsRecorderError {
            XCTAssertEqual(error, .duplicateSampleIdentifier)
        }

        do {
            try await recorder.recordDrop(source: .livePointer,
                                          stratum: .warm,
                                          sampleID: "synthetic-invalid-count",
                                          attemptCount: 1,
                                          successCount: 2,
                                          outcome: .success,
                                          recordedAt: timestamp)
            XCTFail("Invalid counts must be rejected")
        } catch let error as OrganizerMetricsRecorderError {
            XCTAssertEqual(error, .invalidCount)
        }
    }

    @MainActor
    private func relationshipRequest(
        for candidate: OrganizerSuggestionCandidateInput
    ) -> GraphAutomationRelationshipRequest {
        GraphAutomationRelationshipRequest(sourceSubject: candidate.sourceTitle,
                                           sourceSummary: candidate.sourceSummary,
                                           sourceContent: candidate.sourceContent,
                                           targetTitle: candidate.targetTitle,
                                           targetSummary: candidate.targetSummary,
                                           targetContent: candidate.targetContent,
                                           targetIsFolderProfile: candidate.targetIsFolderProfile)
    }

    @MainActor
    private func productionPrediction(
        for candidate: OrganizerSuggestionCandidateInput,
        signal: GraphAutomationRelationshipSignal
    ) -> OrganizerSuggestionPrediction {
        let sourceText = [candidate.sourceTitle,
                          candidate.sourceSummary,
                          candidate.sourceContent].joined(separator: " ")
        let targetText = [candidate.targetTitle,
                          candidate.targetSummary,
                          candidate.targetContent].joined(separator: " ")
        let scoring = GraphAutomationScorer.score(signal: signal,
                                                  sourceText: sourceText,
                                                  targetText: targetText)
        let relationshipMatches: Bool
        if candidate.targetIsFolderProfile {
            relationshipMatches = signal.relationship == .sameTopic
        } else {
            relationshipMatches = signal.relationship == .sameConversation
                && signal.hasSharedNamedTopic
                && signal.hasSameConcreteActionOrEvent
        }
        let accepted = relationshipMatches
            && OrganizationPlacementPolicy.isReviewable(
                score: scoring.score,
                thresholds: GraphAutomationStrictness.conservative.thresholds
            )
        return OrganizerSuggestionPrediction(candidateKey: candidate.candidateKey,
                                             sourceKey: candidate.sourceKey,
                                             decision: accepted ? .accepted : .rejected,
                                             proposedDestinationKey: accepted ? candidate.targetKey : nil)
    }

    private func makeRecorder(
        monotonicClock: OrganizerMetricsMonotonicClock = .continuous()
    ) throws -> OrganizerMetricsRecorder {
        try OrganizerMetricsRecorder(runID: "synthetic-run-1",
                                     fixtureID: "fixture-organizer-100-v1",
                                     protocolID: "protocol-visual-email-organizer-v1",
                                     generatedAt: timestamp,
                                     monotonicClock: monotonicClock)
    }

    private func makeSuggestionPins(
        origin: OrganizerSuggestionEvidenceOrigin
    ) -> OrganizerSuggestionVersionPins? {
        OrganizerSuggestionVersionPins(
            corpusID: "organizer-suggestion-v2",
            provider: "foundation-models-graph-relationship",
            modelVersion: "foundation-models-graph-relationship-v2",
            promptOrPolicyVersion: "organization-placement-policy-v1",
            strictness: .conservative,
            appBuild: "1.1.0-42-abcdef0",
            evidenceOrigin: origin
        )
    }

    private func makeSuggestionCorpusQuality() -> OrganizerSuggestionCorpusQuality? {
        OrganizerSuggestionCorpusQuality(
            corpusID: "organizer-suggestion-v2",
            inputArtifactSHA256: String(repeating: "a", count: 64),
            goldArtifactSHA256: String(repeating: "b", count: 64),
            hasProductionRelevantInputs: true,
            keysAreOpaqueAndLabelIndependent: true
        )
    }

    private func makeSuggestionEvaluationEvidence(
        incorrectAcceptedCount: Int = 0,
        sequentialKeys: Bool = false,
        acceptedUnrelatedPredictionCount: Int = 0
    ) -> (inputs: [OrganizerSuggestionCandidateInput],
          gold: [OrganizerSuggestionGoldRecord],
          predictions: [OrganizerSuggestionPrediction]) {
        var inputs: [OrganizerSuggestionCandidateInput] = []
        var gold: [OrganizerSuggestionGoldRecord] = []
        var predictions: [OrganizerSuggestionPrediction] = []
        var index = 0
        var acceptedIndex = 0
        var acceptedUnrelatedPredictionIndex = 0
        for relation in OrganizerSuggestionSlice.allCases {
            for confidenceBand in OrganizerSuggestionConfidenceBand.allCases {
                for provenance in OrganizerSuggestionProvenance.allCases {
                    for localIndex in 0..<10 {
                        let candidateKey: String
                        let sourceKey: String
                        if sequentialKeys {
                            candidateKey = String(format: "candidate-%04d", index)
                            sourceKey = String(format: "source-%04d", index)
                        } else {
                            candidateKey = opaqueKey(prefix: "candidate", value: "candidate-\(index)")
                            sourceKey = opaqueKey(prefix: "source", value: "source-\(index)")
                        }
                        let targetKey = opaqueKey(prefix: "destination", value: "target-\(index % 12)")
                        let isAccepted = sequentialKeys
                            ? localIndex.isMultiple(of: 2)
                            : relation != .unrelated && localIndex < 7
                        let destinationKey = isAccepted ? targetKey : nil
                        inputs.append(
                            OrganizerSuggestionCandidateInput(
                                candidateKey: candidateKey,
                                sourceKey: sourceKey,
                                targetKey: targetKey,
                                sourceTitle: "Synthetic source \(index)",
                                sourceSummary: "Synthetic source summary \(index)",
                                sourceContent: "Synthetic source evidence \(index)",
                                targetTitle: "Synthetic target \(index % 12)",
                                targetSummary: "Synthetic target summary \(index % 12)",
                                targetContent: "Synthetic target evidence \(index % 12)",
                                targetIsFolderProfile: relation != .attach
                            )
                        )
                        gold.append(
                            OrganizerSuggestionGoldRecord(
                                candidateKey: candidateKey,
                                sourceKey: sourceKey,
                                relation: relation,
                                confidenceBand: confidenceBand,
                                provenance: provenance,
                                expectedLabel: isAccepted ? .accepted : .rejected,
                                expectedDestinationKey: destinationKey
                            )
                        )
                        if isAccepted {
                            let predictedDestination = acceptedIndex < incorrectAcceptedCount
                                ? opaqueKey(prefix: "destination", value: "wrong-\(acceptedIndex)")
                                : destinationKey
                            predictions.append(
                                OrganizerSuggestionPrediction(
                                    candidateKey: candidateKey,
                                    sourceKey: sourceKey,
                                    decision: .accepted,
                                    proposedDestinationKey: predictedDestination
                                )
                            )
                            acceptedIndex += 1
                        } else if relation == .unrelated,
                                  acceptedUnrelatedPredictionIndex < acceptedUnrelatedPredictionCount {
                            predictions.append(
                                OrganizerSuggestionPrediction(
                                    candidateKey: candidateKey,
                                    sourceKey: sourceKey,
                                    decision: .accepted,
                                    proposedDestinationKey: targetKey
                                )
                            )
                            acceptedUnrelatedPredictionIndex += 1
                        } else {
                            predictions.append(
                                OrganizerSuggestionPrediction(
                                    candidateKey: candidateKey,
                                    sourceKey: sourceKey,
                                    decision: .rejected,
                                    proposedDestinationKey: nil
                                )
                            )
                        }
                        index += 1
                    }
                }
            }
        }
        return (inputs, gold, predictions)
    }

    private func makeSuggestionArtifacts(
        inputDigestOverride: String? = nil,
        incorrectAcceptedCount: Int = 0,
        acceptedUnrelatedPredictionCount: Int = 0
    ) throws -> (input: Data, gold: Data, predictions: Data) {
        let evidence = makeSuggestionEvaluationEvidence(
            incorrectAcceptedCount: incorrectAcceptedCount,
            acceptedUnrelatedPredictionCount: acceptedUnrelatedPredictionCount
        )
        let corpusID = "organizer-suggestion-v2"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let input = try encoder.encode(
            OrganizerSuggestionInputArtifact(corpusID: corpusID,
                                             candidates: evidence.inputs)
        )
        let gold = try encoder.encode(
            OrganizerSuggestionGoldArtifact(corpusID: corpusID,
                                            records: evidence.gold)
        )
        let pins = try XCTUnwrap(makeSuggestionPins(origin: .frozenProductionPredictions))
        let predictionArtifact = OrganizerSuggestionPredictionArtifact(
            corpusID: corpusID,
            inputArtifactSHA256: inputDigestOverride
                ?? OrganizerSuggestionArtifactEvaluator.sha256Hex(input),
            pins: pins,
            predictions: evidence.predictions
        )
        return (input, gold, try encoder.encode(predictionArtifact))
    }

    private func opaqueKey(prefix: String, value: String) -> String {
        "\(prefix)-\(OrganizerSuggestionArtifactEvaluator.sha256Hex(Data(value.utf8)))"
    }
}
