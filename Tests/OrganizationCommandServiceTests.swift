import Foundation
import XCTest
@testable import BetterMail

final class OrganizationCommandServiceTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_735_000_000)

    func testExecute_CreateGroup_WritesOpaqueCompletedOperationAndConditionalUndo() async throws {
        let mutationStore = FakeOrganizationMutationStore()
        let operationStore = makeOperationStore()
        let service = OrganizationCommandService(mutationStore: mutationStore,
                                                  operationStore: operationStore)
        let command = OrganizationGroupCommand.create(operationID: "create-1",
                                                       groupID: "group-1",
                                                       title: "Planning",
                                                       memberIDs: ["thread-a", "thread-b"],
                                                       createdAt: date)

        let result = try await service.execute(command, at: date)

        XCTAssertEqual(result.operation.phase, .completed)
        XCTAssertTrue(result.mutation.didChange)
        XCTAssertNotNil(result.undo)
        let snapshot = await mutationStore.snapshot(for: "group-1")
        XCTAssertEqual(snapshot?.memberIDs, ["thread-a", "thread-b"])

        let stored = try await operationStore.operation(id: "create-1")
        XCTAssertEqual(stored?.phase, .completed)
        let ledgerText = String(data: (stored?.betterMailDelta.before ?? Data())
            + (stored?.betterMailDelta.after ?? Data()), encoding: .utf8) ?? ""
        XCTAssertFalse(ledgerText.contains("group-1"))
        XCTAssertFalse(ledgerText.contains("Planning"))
        XCTAssertFalse(ledgerText.contains("thread-a"))
    }

    func testExecute_AddGroup_IsIdempotentAndPreservesUnrelatedMembership() async throws {
        let mutationStore = FakeOrganizationMutationStore([
            makeSnapshot(groupID: "target", title: "Target", members: ["existing"]),
            makeSnapshot(groupID: "unrelated", title: "Unrelated", members: ["untouched"])
        ])
        let operationStore = makeOperationStore()
        let service = OrganizationCommandService(mutationStore: mutationStore,
                                                  operationStore: operationStore)
        let current = await mutationStore.snapshot(for: "target")
        let before = try XCTUnwrap(current)
        let command = OrganizationGroupCommand.add(operationID: "add-1",
                                                    groupID: "target",
                                                    memberIDs: ["new"],
                                                    expectedCurrentFingerprint: before.fingerprint,
                                                    createdAt: date)

        let first = try await service.execute(command, at: date)
        let second = try await service.execute(command, at: date.addingTimeInterval(1))

        XCTAssertTrue(first.mutation.didChange)
        XCTAssertTrue(second.mutation.replayed)
        XCTAssertFalse(second.mutation.didChange)
        let target = await mutationStore.snapshot(for: "target")
        let unrelated = await mutationStore.snapshot(for: "unrelated")
        XCTAssertEqual(target?.memberIDs, ["existing", "new"])
        XCTAssertEqual(unrelated?.memberIDs, ["untouched"])
    }

    func testExecute_IdempotentReplayDoesNotDoubleCountActionOrCommitMetrics() async throws {
        let mutationStore = FakeOrganizationMutationStore([
            makeSnapshot(groupID: "target", title: "Target", members: ["existing"])
        ])
        let operationStore = makeOperationStore()
        let metricsRecorder = try OrganizerMetricsRecorder(
            runID: "synthetic-command-idempotence-run",
            fixtureID: "fixture-organizer-100-v1",
            protocolID: "protocol-visual-email-organizer-v1",
            generatedAt: date,
            defaultStratum: .warm
        )
        let workspaceReady = await metricsRecorder.recordEvent(.workspaceReady, status: .success)
        let taskVisible = await metricsRecorder.recordEvent(.taskVisible, status: .success)
        let taskReady = await metricsRecorder.beginTimedEvent(kind: .firstAction,
                                                              stratum: .warm,
                                                              event: .taskReady)
        XCTAssertTrue(workspaceReady)
        XCTAssertTrue(taskVisible)
        XCTAssertTrue(taskReady)

        let service = OrganizationCommandService(mutationStore: mutationStore,
                                                  operationStore: operationStore,
                                                  metricsRecorder: metricsRecorder)
        let current = await mutationStore.snapshot(for: "target")
        let before = try XCTUnwrap(current)
        let command = OrganizationGroupCommand.add(operationID: "metric-idempotence-1",
                                                    groupID: "target",
                                                    memberIDs: ["new"],
                                                    expectedCurrentFingerprint: before.fingerprint,
                                                    createdAt: date)

        _ = try await service.execute(command, at: date)
        _ = try await service.execute(command, at: date.addingTimeInterval(1))

        let report = await metricsRecorder.report()
        XCTAssertEqual(report.eventSummary.filter { $0.event == .actionStart }.count, 1)
        XCTAssertEqual(report.eventSummary.filter { $0.event == .groupCommitted }.count, 1)
        XCTAssertEqual(report.eventSummary.filter { $0.event == .betterMailCommit }.count, 1)
        XCTAssertEqual(report.records.first?.normalizedCommandCount, 1)
    }

    func testExecute_DuplicateMembers_RejectsBeforeLedgerWrite() async throws {
        let mutationStore = FakeOrganizationMutationStore()
        let operationStore = makeOperationStore()
        let service = OrganizationCommandService(mutationStore: mutationStore,
                                                  operationStore: operationStore)
        let command = OrganizationGroupCommand.add(operationID: "duplicate-1",
                                                    groupID: "target",
                                                    memberIDs: ["thread-a", "thread-a"],
                                                    createdAt: date)

        do {
            _ = try await service.execute(command, at: date)
            XCTFail("duplicate input should be rejected")
        } catch let error as OrganizationMutationStoreError {
            XCTAssertEqual(error, .duplicateInput)
        }
        let stored = try await operationStore.operation(id: "duplicate-1")
        XCTAssertNil(stored)
    }

    func testUndo_AddGroup_RejectsLaterTargetEditAndKeepsBothChanges() async throws {
        let mutationStore = FakeOrganizationMutationStore([
            makeSnapshot(groupID: "target", title: "Target", members: ["existing"])
        ])
        let operationStore = makeOperationStore()
        let service = OrganizationCommandService(mutationStore: mutationStore,
                                                  operationStore: operationStore)
        let current = await mutationStore.snapshot(for: "target")
        let before = try XCTUnwrap(current)
        let command = OrganizationGroupCommand.add(operationID: "add-undo-1",
                                                    groupID: "target",
                                                    memberIDs: ["new"],
                                                    expectedCurrentFingerprint: before.fingerprint,
                                                    createdAt: date)
        let result = try await service.execute(command, at: date)
        let undo = try XCTUnwrap(result.undo)
        await mutationStore.forceAdd(memberIDs: ["later"], to: "target")

        do {
            _ = try await service.undo(undo, at: date.addingTimeInterval(1))
            XCTFail("conditional undo should reject a later target edit")
        } catch let error as OrganizationCommandServiceError {
            XCTAssertEqual(error, .conditionalUndoConflict)
        }
        let target = await mutationStore.snapshot(for: "target")
        let stored = try await operationStore.operation(id: "add-undo-1")
        XCTAssertEqual(target?.memberIDs, ["existing", "later", "new"])
        XCTAssertEqual(stored?.phase, .completed)
    }

    func testUndo_CreateGroup_RemovesOnlyCreatedGroupAndIsIdempotent() async throws {
        let mutationStore = FakeOrganizationMutationStore([
            makeSnapshot(groupID: "unrelated", title: "Unrelated", members: ["keep"])
        ])
        let operationStore = makeOperationStore()
        let service = OrganizationCommandService(mutationStore: mutationStore,
                                                  operationStore: operationStore)
        let command = OrganizationGroupCommand.create(operationID: "create-undo-1",
                                                       groupID: "created",
                                                       title: "Created",
                                                       memberIDs: ["one", "two"],
                                                       createdAt: date)
        let result = try await service.execute(command, at: date)
        let undo = try XCTUnwrap(result.undo)

        let undone = try await service.undo(undo, at: date.addingTimeInterval(1))
        let replay = try await service.undo(undo, at: date.addingTimeInterval(2))

        XCTAssertTrue(undone.didApply)
        XCTAssertEqual(undone.operation.phase, .undone)
        XCTAssertFalse(replay.didApply)
        let created = await mutationStore.snapshot(for: "created")
        let unrelated = await mutationStore.snapshot(for: "unrelated")
        XCTAssertNil(created)
        XCTAssertEqual(unrelated?.memberIDs, ["keep"])
    }

    func testExecute_LedgerWriteAfterBetterMailCommit_LeavesPreparedAndRetriesWithoutDuplicateMutation() async throws {
        let mutationStore = FakeOrganizationMutationStore([
            makeSnapshot(groupID: "target", title: "Target", members: [])
        ])
        let fileIO = TestOperationFileIO()
        let operationStore = makeOperationStore(fileIO: fileIO)
        let service = OrganizationCommandService(mutationStore: mutationStore,
                                                  operationStore: operationStore)
        let current = await mutationStore.snapshot(for: "target")
        let before = try XCTUnwrap(current)
        let command = OrganizationGroupCommand.add(operationID: "boundary-1",
                                                    groupID: "target",
                                                    memberIDs: ["new"],
                                                    expectedCurrentFingerprint: before.fingerprint,
                                                    createdAt: date)
        await mutationStore.setApplyHook {
            fileIO.failNextWrite()
        }

        do {
            _ = try await service.execute(command, at: date)
            XCTFail("the injected ledger write failure should be observable")
        } catch let error as OrganizationCommandServiceError {
            guard case .ledgerBoundary(let operationID, true) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(operationID, "boundary-1")
        }
        let prepared = try await operationStore.operation(id: "boundary-1")
        let committed = await mutationStore.snapshot(for: "target")
        XCTAssertEqual(prepared?.phase, .prepared)
        XCTAssertEqual(committed?.memberIDs, ["new"])

        let retry = try await service.execute(command, at: date.addingTimeInterval(1))
        XCTAssertEqual(retry.operation.phase, .completed)
        XCTAssertTrue(retry.mutation.replayed)
        let retried = await mutationStore.snapshot(for: "target")
        XCTAssertEqual(retried?.memberIDs, ["new"])
    }

    func testExecute_BetterMailApplyFailureAfterLedgerPrepare_RecordsRecoveryWithoutMutationOrFalseCompletion() async throws {
        let mutationStore = FakeOrganizationMutationStore([
            makeSnapshot(groupID: "target", title: "Target", members: ["existing"])
        ])
        let operationStore = makeOperationStore()
        let service = OrganizationCommandService(mutationStore: mutationStore,
                                                  operationStore: operationStore)
        let beforeSnapshot = await mutationStore.snapshot(for: "target")
        let before = try XCTUnwrap(beforeSnapshot)
        let command = OrganizationGroupCommand.add(operationID: "apply-boundary-1",
                                                    groupID: "target",
                                                    memberIDs: ["new"],
                                                    expectedCurrentFingerprint: before.fingerprint,
                                                    createdAt: date)
        await mutationStore.failNextApply()

        do {
            _ = try await service.execute(command, at: date)
            XCTFail("the injected BetterMail transaction failure should be observable")
        } catch let error as OrganizationCommandServiceError {
            XCTAssertEqual(error, .mutationFailed(operationID: "apply-boundary-1"))
        }

        let unchanged = await mutationStore.snapshot(for: "target")
        XCTAssertEqual(unchanged, before)
        let storedRecovery = try await operationStore.operation(id: "apply-boundary-1")
        let recovery = try XCTUnwrap(storedRecovery)
        XCTAssertEqual(recovery.phase, .recovery)
        XCTAssertEqual(recovery.lastFailure?.code, "betterMailMutationFailed")
        XCTAssertFalse(recovery.receipts.contains { $0.kind == .appApplied })
        XCTAssertFalse(recovery.phase.isTerminal)
    }

    func testExecute_CreateGroupWithAnchor_LeavesLayoutPendingUntilReceiptAdapterAdvancesIt() async throws {
        let mutationStore = FakeOrganizationMutationStore()
        let operationStore = makeOperationStore()
        let service = OrganizationCommandService(mutationStore: mutationStore,
                                                  operationStore: operationStore)
        let anchor = OrganizationSpatialAnchorIntent(opaqueScopeFingerprint: "scope-token",
                                                     opaqueGroupFingerprint: "group-token",
                                                     x: 100,
                                                     y: 200,
                                                     zoom: 1)
        let command = OrganizationGroupCommand.create(operationID: "anchor-1",
                                                       groupID: "anchored",
                                                       title: "Anchored",
                                                       memberIDs: ["one", "two"],
                                                       anchorIntent: anchor,
                                                       createdAt: date)

        let result = try await service.execute(command, at: date)
        let replay = try await service.execute(command, at: date.addingTimeInterval(1))

        XCTAssertEqual(result.operation.phase, .layoutPending)
        XCTAssertEqual(replay.operation.phase, .layoutPending)
        XCTAssertFalse(replay.mutation.didChange)
    }

    private func makeOperationStore(fileIO: TestOperationFileIO = TestOperationFileIO()) -> OrganizationOperationStore {
        OrganizationOperationStore(fileURL: URL(fileURLWithPath: "/tmp/organization-command-tests.json"),
                                    fileIO: fileIO,
                                    routeCrypto: CryptoKitOrganizationRouteCryptoProvider(
                                        keyIdentifier: "test-route-key",
                                        keyData: Data(repeating: 7, count: 32),
                                        now: date))
    }

    private func makeSnapshot(groupID: String,
                              title: String,
                              members: [String]) -> OrganizationMutationSnapshot {
        OrganizationMutationSnapshot(groupID: groupID,
                                     exists: true,
                                     title: title,
                                     parentID: nil,
                                     memberIDs: members.sorted())
    }
}

private actor FakeOrganizationMutationStore: OrganizationMutationStoring {
    private var groups: [String: OrganizationMutationSnapshot]
    private var applyHook: (@Sendable () -> Void)?
    private var shouldFailNextApply = false

    init(_ snapshots: [OrganizationMutationSnapshot] = []) {
        self.groups = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.groupID, $0) })
    }

    func setApplyHook(_ hook: @escaping @Sendable () -> Void) {
        applyHook = hook
    }

    func failNextApply() {
        shouldFailNextApply = true
    }

    func snapshot(for groupID: String) -> OrganizationMutationSnapshot? {
        groups[groupID]
    }

    func forceAdd(memberIDs: [String], to groupID: String) {
        guard let current = groups[groupID] else { return }
        groups[groupID] = OrganizationMutationSnapshot(groupID: current.groupID,
                                                        exists: true,
                                                        title: current.title,
                                                        parentID: current.parentID,
                                                        memberIDs: Set(current.memberIDs).union(memberIDs).sorted())
    }

    func plan(_ rawCommand: OrganizationGroupCommand) throws -> OrganizationMutationPlan {
        let command = try rawCommand.validated()
        let current = groups[command.groupID]
        let before = current ?? .missing(groupID: command.groupID)
        if let expected = command.expectedCurrentFingerprint,
           before.fingerprint != expected {
            throw OrganizationMutationStoreError.staleMutation
        }

        switch command.kind {
        case .createGroup:
            let after = OrganizationMutationSnapshot(groupID: command.groupID,
                                                      exists: true,
                                                      title: command.title,
                                                      parentID: command.parentID,
                                                      memberIDs: command.memberIDs)
            guard current == nil else {
                guard before.title == after.title,
                      before.parentID == after.parentID,
                      before.memberIDs == after.memberIDs else {
                    throw OrganizationMutationStoreError.groupAlreadyExists(command.groupID)
                }
                return OrganizationMutationPlan(command: command,
                                                before: before,
                                                after: before,
                                                addedMemberIDs: [],
                                                removedMemberIDs: [],
                                                createdGroup: false,
                                                deletedGroup: false,
                                                wasNoop: true)
            }
            return OrganizationMutationPlan(command: command,
                                            before: before,
                                            after: after,
                                            addedMemberIDs: command.memberIDs,
                                            removedMemberIDs: [],
                                            createdGroup: true,
                                            deletedGroup: false,
                                            wasNoop: false)

        case .addToGroup:
            guard let current else {
                throw OrganizationMutationStoreError.missingGroup(command.groupID)
            }
            let existing = Set(current.memberIDs)
            let after = OrganizationMutationSnapshot(groupID: current.groupID,
                                                      exists: true,
                                                      title: current.title,
                                                      parentID: current.parentID,
                                                      memberIDs: existing.union(command.memberIDs).sorted())
            let added = after.memberIDs.filter { !existing.contains($0) }
            return OrganizationMutationPlan(command: command,
                                            before: before,
                                            after: after,
                                            addedMemberIDs: added,
                                            removedMemberIDs: [],
                                            createdGroup: false,
                                            deletedGroup: false,
                                            wasNoop: added.isEmpty)

        case .removeFromGroup:
            guard let current else {
                throw OrganizationMutationStoreError.missingGroup(command.groupID)
            }
            let existing = Set(current.memberIDs)
            let removed = command.memberIDs.filter(existing.contains).sorted()
            let after = OrganizationMutationSnapshot(groupID: current.groupID,
                                                      exists: true,
                                                      title: current.title,
                                                      parentID: current.parentID,
                                                      memberIDs: existing.subtracting(command.memberIDs).sorted())
            return OrganizationMutationPlan(command: command,
                                            before: before,
                                            after: after,
                                            addedMemberIDs: [],
                                            removedMemberIDs: removed,
                                            createdGroup: false,
                                            deletedGroup: false,
                                            wasNoop: removed.isEmpty)

        case .deleteGroup:
            guard let current else {
                return OrganizationMutationPlan(command: command,
                                                before: before,
                                                after: before,
                                                addedMemberIDs: [],
                                                removedMemberIDs: [],
                                                createdGroup: false,
                                                deletedGroup: false,
                                                wasNoop: true)
            }
            return OrganizationMutationPlan(command: command,
                                            before: current,
                                            after: .missing(groupID: command.groupID),
                                            addedMemberIDs: [],
                                            removedMemberIDs: current.memberIDs,
                                            createdGroup: false,
                                            deletedGroup: true,
                                            wasNoop: false)
        }
    }

    func apply(_ plan: OrganizationMutationPlan) throws -> OrganizationMutationResult {
        if shouldFailNextApply {
            shouldFailNextApply = false
            throw FakeOrganizationMutationStoreError.injectedApplyFailure
        }
        let current = groups[plan.command.groupID] ?? .missing(groupID: plan.command.groupID)
        if current.fingerprint == plan.after.fingerprint {
            return result(for: plan, didChange: false, replayed: !plan.wasNoop)
        }
        guard current.fingerprint == plan.before.fingerprint else {
            throw OrganizationMutationStoreError.staleMutation
        }
        guard !plan.wasNoop else {
            return result(for: plan, didChange: false, replayed: false)
        }
        if plan.deletedGroup {
            groups.removeValue(forKey: plan.command.groupID)
        } else {
            groups[plan.command.groupID] = plan.after
        }
        applyHook?()
        applyHook = nil
        return result(for: plan, didChange: true, replayed: false)
    }

    private func result(for plan: OrganizationMutationPlan,
                        didChange: Bool,
                        replayed: Bool) -> OrganizationMutationResult {
        OrganizationMutationResult(operationID: plan.command.operationID,
                                   kind: plan.command.kind,
                                   groupID: plan.command.groupID,
                                   beforeFingerprint: plan.before.fingerprint,
                                   afterFingerprint: plan.after.fingerprint,
                                   addedMemberIDs: plan.addedMemberIDs,
                                   removedMemberIDs: plan.removedMemberIDs,
                                   didChange: didChange,
                                   replayed: replayed)
    }
}

private enum FakeOrganizationMutationStoreError: Error {
    case injectedApplyFailure
}

private final class TestOperationFileIO: OrganizationOperationFileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: Data] = [:]
    private var pendingWriteFailures = 0

    func read(at url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[url] else {
            throw OrganizationOperationFileIOError.notFound
        }
        return value
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if pendingWriteFailures > 0 {
            pendingWriteFailures -= 1
            throw OrganizationOperationFileIOError.writeFailed
        }
        values[url] = data
    }

    func failNextWrite() {
        lock.lock()
        pendingWriteFailures += 1
        lock.unlock()
    }
}
