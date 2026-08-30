import CryptoKit
import Foundation

/// An in-memory conditional inverse for one manual BetterMail command. The
/// inverse contains effective IDs only while the command is in process; the
/// durable operation keeps the before/after representation opaque.
internal nonisolated struct OrganizationConditionalUndo: Hashable, Sendable {
    internal let operationID: String
    internal let expectedCurrentFingerprint: String
    internal let inverseCommand: OrganizationGroupCommand

    internal init(operationID: String,
                  expectedCurrentFingerprint: String,
                  inverseCommand: OrganizationGroupCommand) {
        self.operationID = operationID
        self.expectedCurrentFingerprint = expectedCurrentFingerprint
        self.inverseCommand = inverseCommand
    }
}

internal nonisolated struct OrganizationCommandResult: Hashable, Sendable {
    internal let operation: OrganizationOperation
    internal let mutation: OrganizationMutationResult
    internal let undo: OrganizationConditionalUndo?
}

internal nonisolated struct OrganizationUndoResult: Hashable, Sendable {
    internal let operation: OrganizationOperation
    internal let mutation: OrganizationMutationResult
    internal let didApply: Bool
}

internal nonisolated enum OrganizationCommandServiceError: Error, Equatable, LocalizedError, Sendable {
    case operationConflict
    case operationAlreadyUndone
    case operationNeedsRecovery
    case conditionalUndoConflict
    case ledgerBoundary(operationID: String, mutationApplied: Bool)
    case mutationFailed(operationID: String)
    case operationStore(OrganizationOperationStoreError)

    internal var errorDescription: String? {
        switch self {
        case .operationConflict:
            return "The operation ID is already associated with a different Group command."
        case .operationAlreadyUndone:
            return "The organization operation has already been undone."
        case .operationNeedsRecovery:
            return "The organization operation needs recovery before it can be retried."
        case .conditionalUndoConflict:
            return "The Group changed after the operation, so its conditional undo was not applied."
        case .ledgerBoundary:
            return "BetterMail changed, but the durable operation ledger needs recovery."
        case .mutationFailed:
            return "The BetterMail Group mutation could not be committed."
        case .operationStore:
            return "The organization operation ledger could not be updated."
        }
    }
}

/// The command boundary for manual BetterMail Group operations. It performs
/// a write-ahead ledger prepare, one serialized Core Data mutation, and
/// lifecycle advancement. The JSON ledger and Core Data context are separate
/// stores; a failure between them is returned as `ledgerBoundary` rather than
/// being represented as an atomic transaction that does not exist.
internal actor OrganizationCommandService {
    private let mutationStore: any OrganizationMutationStoring
    private let operationStore: OrganizationOperationStore
    private let metricsRecorder: OrganizerMetricsRecorder?
    private var undoByOperationID: [String: OrganizationConditionalUndo] = [:]

    internal init(mutationStore: any OrganizationMutationStoring,
                  operationStore: OrganizationOperationStore,
                  metricsRecorder: OrganizerMetricsRecorder? = nil) {
        self.mutationStore = mutationStore
        self.operationStore = operationStore
        self.metricsRecorder = metricsRecorder
    }

    internal init(messageStore: MessageStore,
                  operationStore: OrganizationOperationStore,
                  metricsRecorder: OrganizerMetricsRecorder? = nil) {
        self.mutationStore = OrganizationMutationStore(messageStore: messageStore)
        self.operationStore = operationStore
        self.metricsRecorder = metricsRecorder
    }

    /// Executes one idempotent BetterMail-only Group command. Reusing an
    /// operation ID with the same opaque command identity replays the durable
    /// result; reusing it with a different command is rejected.
    @discardableResult
    internal func execute(_ rawCommand: OrganizationGroupCommand,
                          at date: Date = Date()) async throws -> OrganizationCommandResult {
        let count = max(rawCommand.memberIDs.count, 1)
        do {
            let result = try await executeImpl(rawCommand, at: date)
            if result.mutation.didChange {
                await recordCommittedGroup(count: count)
            }
            return result
        } catch {
            if case OrganizationCommandServiceError.ledgerBoundary(_, true) = error {
                await recordCommittedGroup(count: count)
            } else {
                await metricsRecorder?.recordEvent(.groupCommitted,
                                                   count: count,
                                                   status: .failure,
                                                   failureReason: .actionFailure)
            }
            if Self.requiresRecoveryMetric(error) {
                await metricsRecorder?.recordEvent(.recovery,
                                                   count: count,
                                                   status: .failure,
                                                   failureReason: .unresolvedOutcome)
            }
            _ = await metricsRecorder?.failActiveTimedEvents(
                outcome: .failure,
                failureReason: .actionFailure
            )
            throw error
        }
    }

    private func recordCommittedGroup(count: Int) async {
        await metricsRecorder?.recordEvent(.groupCommitted,
                                           count: count,
                                           status: .success)
        await metricsRecorder?.recordEvent(.betterMailCommit,
                                           count: 1,
                                           status: .success)
    }

    private func executeImpl(_ rawCommand: OrganizationGroupCommand,
                             at date: Date) async throws -> OrganizationCommandResult {
        let command = try rawCommand.validated()
        let existing: OrganizationOperation?
        do {
            existing = try await operationStore.operation(id: command.operationID)
        } catch let error as OrganizationOperationStoreError {
            throw OrganizationCommandServiceError.operationStore(error)
        }

        if let existing {
            try validate(existing, against: command)
            if existing.phase != .completed, existing.phase != .layoutPending {
                await metricsRecorder?.recordEvent(.actionStart,
                                                   count: 1)
            }
            return try await `continue`(existing,
                                        command: command,
                                        at: date)
        }

        await metricsRecorder?.recordEvent(.actionStart,
                                           count: 1)
        let plan = try await mutationStore.plan(command)
        let operation = try makeOperation(for: plan)
        do {
            _ = try await operationStore.prepare(operation)
        } catch let error as OrganizationOperationStoreError {
            throw OrganizationCommandServiceError.operationStore(error)
        }

        let mutation: OrganizationMutationResult
        do {
            mutation = try await mutationStore.apply(plan)
        } catch {
            await recordMutationFailure(operationID: operation.id, at: date)
            if let mutationError = error as? OrganizationMutationStoreError {
                throw mutationError
            }
            throw OrganizationCommandServiceError.mutationFailed(operationID: operation.id)
        }

        let appliedOperation: OrganizationOperation
        do {
            appliedOperation = try await advanceToAppApplied(operationID: operation.id,
                                                             mutation: mutation,
                                                             at: date)
        } catch let error as OrganizationCommandServiceError {
            throw error
        } catch is OrganizationOperationStoreError {
            throw OrganizationCommandServiceError.ledgerBoundary(operationID: operation.id,
                                                                  mutationApplied: true)
        } catch {
            throw OrganizationCommandServiceError.ledgerBoundary(operationID: operation.id,
                                                                  mutationApplied: true)
        }

        let finalOperation: OrganizationOperation
        do {
            finalOperation = try await finishAppApplied(appliedOperation,
                                                        at: date)
        } catch {
            throw OrganizationCommandServiceError.ledgerBoundary(operationID: operation.id,
                                                                  mutationApplied: true)
        }

        let undo = makeUndo(for: plan, at: date)
        if let undo {
            undoByOperationID[operation.id] = undo
        }
        return OrganizationCommandResult(operation: finalOperation,
                                         mutation: mutation,
                                         undo: undo)
    }

    /// Applies the in-memory conditional inverse only when the target Group
    /// still has the exact post-command fingerprint. Unrelated Groups are not
    /// touched, and later edits to the target are surfaced as a conflict.
    @discardableResult
    internal func undo(_ token: OrganizationConditionalUndo,
                       at date: Date = Date()) async throws -> OrganizationUndoResult {
        do {
            let result = try await undoImpl(token, at: date)
            await metricsRecorder?.recordEvent(.undo,
                                               count: 1,
                                               status: .success)
            return result
        } catch {
            await metricsRecorder?.recordEvent(.undo,
                                               count: 1,
                                               status: .failure)
            if Self.requiresRecoveryMetric(error) {
                await metricsRecorder?.recordEvent(.recovery,
                                                   count: 1,
                                                   status: .failure)
            }
            throw error
        }
    }

    private func undoImpl(_ token: OrganizationConditionalUndo,
                          at date: Date) async throws -> OrganizationUndoResult {
        let operation: OrganizationOperation
        do {
            guard let stored = try await operationStore.operation(id: token.operationID) else {
                throw OrganizationCommandServiceError.operationConflict
            }
            operation = stored
        } catch let error as OrganizationCommandServiceError {
            throw error
        } catch let error as OrganizationOperationStoreError {
            throw OrganizationCommandServiceError.operationStore(error)
        }

        guard operation.kind == .manualGroup || operation.kind == .manualUngroup else {
            throw OrganizationCommandServiceError.operationConflict
        }
        switch operation.phase {
        case .undone:
            return OrganizationUndoResult(operation: operation,
                                          mutation: replayResult(for: operation,
                                                                 command: token.inverseCommand),
                                          didApply: false)
        case .completed:
            break
        case .prepared, .appApplied, .layoutPending, .mailApplying, .partial, .recovery:
            throw OrganizationCommandServiceError.operationNeedsRecovery
        }

        let inverse = try token.inverseCommand.validated()
        guard inverse.expectedCurrentFingerprint == token.expectedCurrentFingerprint else {
            throw OrganizationCommandServiceError.conditionalUndoConflict
        }

        let plan: OrganizationMutationPlan
        do {
            plan = try await mutationStore.plan(inverse)
        } catch let error as OrganizationMutationStoreError {
            if case .staleMutation = error {
                throw OrganizationCommandServiceError.conditionalUndoConflict
            }
            throw error
        }
        guard plan.before.fingerprint == token.expectedCurrentFingerprint else {
            throw OrganizationCommandServiceError.conditionalUndoConflict
        }

        let mutation: OrganizationMutationResult
        do {
            mutation = try await mutationStore.apply(plan)
        } catch let error as OrganizationMutationStoreError {
            if case .staleMutation = error {
                throw OrganizationCommandServiceError.conditionalUndoConflict
            }
            throw error
        }

        let undoneOperation: OrganizationOperation
        do {
            undoneOperation = try await operationStore.advance(
                id: operation.id,
                to: .undone,
                receipt: OrganizationOperationReceipt(kind: .undo,
                                                       date: date,
                                                       expectedCount: 1,
                                                       completedCount: 1,
                                                       opaqueItemFingerprints: [OrganizationCommandFingerprint.digest(plan.after.fingerprint)]),
                at: date
            )
        } catch is OrganizationOperationStoreError {
            throw OrganizationCommandServiceError.ledgerBoundary(operationID: operation.id,
                                                                  mutationApplied: mutation.didChange)
        } catch {
            throw OrganizationCommandServiceError.ledgerBoundary(operationID: operation.id,
                                                                  mutationApplied: mutation.didChange)
        }

        undoByOperationID.removeValue(forKey: operation.id)
        return OrganizationUndoResult(operation: undoneOperation,
                                      mutation: mutation,
                                      didApply: mutation.didChange)
    }

    internal func undoToken(for operationID: String) -> OrganizationConditionalUndo? {
        undoByOperationID[operationID]
    }

    private nonisolated static func requiresRecoveryMetric(_ error: Error) -> Bool {
        guard let serviceError = error as? OrganizationCommandServiceError else {
            return false
        }
        switch serviceError {
        case .operationNeedsRecovery, .ledgerBoundary, .mutationFailed, .operationStore:
            return true
        case .operationConflict, .operationAlreadyUndone, .conditionalUndoConflict:
            return false
        }
    }

    private func `continue`(_ operation: OrganizationOperation,
                            command: OrganizationGroupCommand,
                            at date: Date) async throws -> OrganizationCommandResult {
        switch operation.phase {
        case .prepared:
            let plan = try await continuationPlan(for: command, operation: operation)
            let mutation = try await applyContinuation(plan,
                                                       operation: operation,
                                                       at: date)
            let appliedOperation = try await advanceToAppApplied(operationID: operation.id,
                                                                   mutation: mutation,
                                                                   at: date)
            let finalOperation: OrganizationOperation
            do {
                finalOperation = try await finishAppApplied(appliedOperation, at: date)
            } catch {
                throw OrganizationCommandServiceError.ledgerBoundary(operationID: operation.id,
                                                                      mutationApplied: true)
            }
            let undo = undoByOperationID[operation.id]
                ?? makeUndo(for: plan, operation: operation, at: date)
            if let undo {
                undoByOperationID[operation.id] = undo
            }
            return OrganizationCommandResult(operation: finalOperation,
                                             mutation: mutation,
                                             undo: undo)

        case .appApplied:
            let plan = try await continuationPlan(for: command, operation: operation)
            let mutation = try await applyContinuation(plan,
                                                       operation: operation,
                                                       at: date)
            let finalOperation: OrganizationOperation
            do {
                finalOperation = try await finishAppApplied(operation, at: date)
            } catch {
                throw OrganizationCommandServiceError.ledgerBoundary(operationID: operation.id,
                                                                      mutationApplied: true)
            }
            let undo = undoByOperationID[operation.id]
                ?? makeUndo(for: plan, operation: operation, at: date)
            if let undo {
                undoByOperationID[operation.id] = undo
            }
            return OrganizationCommandResult(operation: finalOperation,
                                             mutation: mutation,
                                             undo: undo)

        case .layoutPending:
            return OrganizationCommandResult(operation: operation,
                                             mutation: replayResult(for: operation,
                                                                    command: command),
                                             undo: undoByOperationID[operation.id])

        case .completed:
            return OrganizationCommandResult(operation: operation,
                                             mutation: replayResult(for: operation,
                                                                    command: command),
                                             undo: undoByOperationID[operation.id])

        case .undone:
            throw OrganizationCommandServiceError.operationAlreadyUndone

        case .partial, .recovery, .mailApplying:
            throw OrganizationCommandServiceError.operationNeedsRecovery
        }
    }

    private func continuationPlan(for command: OrganizationGroupCommand,
                                  operation: OrganizationOperation) async throws -> OrganizationMutationPlan {
        let directPlan: OrganizationMutationPlan?
        do {
            directPlan = try await mutationStore.plan(command)
        } catch let error as OrganizationMutationStoreError {
            guard case .staleMutation = error else {
                throw error
            }
            directPlan = nil
        }

        let storedAfter = try afterData(of: operation)
        if let directPlan {
            guard try encodedSnapshot(directPlan.after) == storedAfter else {
                throw OrganizationCommandServiceError.operationConflict
            }
            return directPlan
        }

        // A crash can occur after Core Data commits but before the ledger
        // phase advances. Retry with the conditional precondition removed,
        // then require the resulting opaque after snapshot to match the
        // prepared record before treating it as a replay.
        let relaxed = OrganizationGroupCommand(operationID: command.operationID,
                                                kind: command.kind,
                                                groupID: command.groupID,
                                                title: command.title,
                                                memberIDs: command.memberIDs,
                                                parentID: command.parentID,
                                                expectedCurrentFingerprint: nil,
                                                anchorIntent: command.anchorIntent,
                                                createdAt: command.createdAt)
        let recoveredPlan = try await mutationStore.plan(relaxed)
        guard try encodedSnapshot(recoveredPlan.after) == storedAfter else {
            throw OrganizationCommandServiceError.operationConflict
        }
        return recoveredPlan
    }

    private func applyContinuation(_ plan: OrganizationMutationPlan,
                                   operation: OrganizationOperation,
                                   at date: Date) async throws -> OrganizationMutationResult {
        do {
            let result = try await mutationStore.apply(plan)
            return result.didChange ? result : replayed(result)
        } catch {
            if let mutationError = error as? OrganizationMutationStoreError {
                if case .staleMutation = mutationError {
                    throw OrganizationCommandServiceError.operationNeedsRecovery
                }
                throw mutationError
            }
            throw OrganizationCommandServiceError.mutationFailed(operationID: operation.id)
        }
    }

    private func advanceToAppApplied(operationID: String,
                                     mutation: OrganizationMutationResult,
                                     at date: Date) async throws -> OrganizationOperation {
        try await operationStore.advance(
            id: operationID,
            to: .appApplied,
            receipt: OrganizationOperationReceipt(kind: .appApplied,
                                                   date: date,
                                                   expectedCount: 1,
                                                   completedCount: 1,
                                                   opaqueItemFingerprints: [
                                                       OrganizationCommandFingerprint.digest(mutation.groupID),
                                                       OrganizationCommandFingerprint.digest(mutation.afterFingerprint)
                                                   ]),
            at: date
        )
    }

    private func finishAppApplied(_ operation: OrganizationOperation,
                                  at date: Date) async throws -> OrganizationOperation {
        let nextPhase: OrganizationOperationPhase = operation.spatialAnchorIntent == nil
            ? .completed
            : .layoutPending
        return try await operationStore.advance(id: operation.id,
                                                to: nextPhase,
                                                at: date)
    }

    private func recordMutationFailure(operationID: String,
                                       at date: Date) async {
        let failure = OrganizationOperationFailure(code: "betterMailMutationFailed",
                                                    retryable: true,
                                                    attempt: 1,
                                                    date: date)
        do {
            _ = try await operationStore.advance(id: operationID,
                                                 to: .recovery,
                                                 failure: failure,
                                                 at: date)
        } catch {
            // The prepared record remains the write-ahead recovery marker if
            // failure metadata itself cannot be persisted.
        }
    }

    private func makeOperation(for plan: OrganizationMutationPlan) throws -> OrganizationOperation {
        let before = try encodedSnapshot(plan.before)
        let after = try encodedSnapshot(plan.after)
        return OrganizationOperation(id: plan.command.operationID,
                                     kind: operationKind(for: plan.command.kind),
                                     opaqueSourceFingerprints: plan.command.memberIDs
                                         .map(OrganizationCommandFingerprint.digest)
                                         .sorted(),
                                     opaqueTargetFingerprints: [OrganizationCommandFingerprint.group(plan.command.groupID)],
                                     betterMailDelta: OrganizationBetterMailDelta(
                                         formatIdentifier: "organization-group-v1",
                                         before: before,
                                         after: after
                                     ),
                                     spatialAnchorIntent: plan.command.anchorIntent,
                                     createdAt: plan.command.createdAt)
    }

    private func makeUndo(for plan: OrganizationMutationPlan,
                          at date: Date) -> OrganizationConditionalUndo? {
        guard !plan.wasNoop else {
            return nil
        }
        return makeUndo(for: plan, operation: nil, at: date)
    }

    private func makeUndo(for plan: OrganizationMutationPlan,
                          operation: OrganizationOperation?,
                          at date: Date) -> OrganizationConditionalUndo? {
        if let operation,
           let before = try? decodeSnapshot(operation.betterMailDelta.before),
           let after = try? decodeSnapshot(operation.betterMailDelta.after),
           before.groupFingerprint == after.groupFingerprint {
            return nil
        }
        let inverseID = "undo:\(plan.command.operationID)"
        let inverse: OrganizationGroupCommand
        switch plan.command.kind {
        case .createGroup:
            inverse = .delete(operationID: inverseID,
                               groupID: plan.command.groupID,
                               expectedCurrentFingerprint: plan.after.fingerprint,
                               createdAt: date)
        case .addToGroup:
            inverse = .remove(operationID: inverseID,
                              groupID: plan.command.groupID,
                              memberIDs: plan.addedMemberIDs,
                              expectedCurrentFingerprint: plan.after.fingerprint,
                              createdAt: date)
        case .removeFromGroup:
            inverse = .add(operationID: inverseID,
                           groupID: plan.command.groupID,
                           memberIDs: plan.removedMemberIDs,
                           expectedCurrentFingerprint: plan.after.fingerprint,
                           createdAt: date)
        case .deleteGroup:
            inverse = OrganizationGroupCommand(operationID: inverseID,
                                               kind: .createGroup,
                                               groupID: plan.command.groupID,
                                               title: plan.before.title,
                                               memberIDs: plan.before.memberIDs,
                                               parentID: plan.before.parentID,
                                               expectedCurrentFingerprint: plan.after.fingerprint,
                                               createdAt: date)
        }
        return OrganizationConditionalUndo(operationID: plan.command.operationID,
                                           expectedCurrentFingerprint: plan.after.fingerprint,
                                           inverseCommand: inverse)
    }

    private func validate(_ operation: OrganizationOperation,
                          against command: OrganizationGroupCommand) throws {
        guard operation.kind == operationKind(for: command.kind),
              operation.opaqueTargetFingerprints == [OrganizationCommandFingerprint.group(command.groupID)],
              operation.opaqueSourceFingerprints == command.memberIDs
                  .map(OrganizationCommandFingerprint.digest)
                  .sorted(),
              operation.spatialAnchorIntent == command.anchorIntent else {
            throw OrganizationCommandServiceError.operationConflict
        }

        guard let after = try? decodeSnapshot(operation.betterMailDelta.after) else {
            throw OrganizationCommandServiceError.operationConflict
        }
        if command.kind == .createGroup {
            guard after.exists,
                  after.titleFingerprint == command.title.map(OrganizationCommandFingerprint.digest),
                  after.parentFingerprint == command.parentID.map(OrganizationCommandFingerprint.digest),
                  after.memberFingerprints == command.memberIDs
                      .map(OrganizationCommandFingerprint.digest)
                      .sorted() else {
                throw OrganizationCommandServiceError.operationConflict
            }
        }
    }

    private func replayResult(for operation: OrganizationOperation,
                              command: OrganizationGroupCommand) -> OrganizationMutationResult {
        let before = (try? decodeSnapshot(operation.betterMailDelta.before))?.groupFingerprint ?? ""
        let after = (try? decodeSnapshot(operation.betterMailDelta.after))?.groupFingerprint ?? ""
        return OrganizationMutationResult(operationID: command.operationID,
                                          kind: command.kind,
                                          groupID: command.groupID,
                                          beforeFingerprint: before,
                                          afterFingerprint: after,
                                          addedMemberIDs: [],
                                          removedMemberIDs: [],
                                          didChange: false,
                                          replayed: true)
    }

    private func replayed(_ result: OrganizationMutationResult) -> OrganizationMutationResult {
        OrganizationMutationResult(operationID: result.operationID,
                                    kind: result.kind,
                                    groupID: result.groupID,
                                    beforeFingerprint: result.beforeFingerprint,
                                    afterFingerprint: result.afterFingerprint,
                                    addedMemberIDs: result.addedMemberIDs,
                                    removedMemberIDs: result.removedMemberIDs,
                                    didChange: false,
                                    replayed: true)
    }

    private func operationKind(for commandKind: OrganizationGroupCommandKind) -> OrganizationOperationKind {
        switch commandKind {
        case .createGroup, .addToGroup:
            return .manualGroup
        case .removeFromGroup, .deleteGroup:
            return .manualUngroup
        }
    }

    private struct LedgerSnapshot: Codable, Hashable, Sendable {
        let exists: Bool
        let groupFingerprint: String
        let titleFingerprint: String?
        let parentFingerprint: String?
        let memberFingerprints: [String]
    }

    private func encodedSnapshot(_ snapshot: OrganizationMutationSnapshot) throws -> Data {
        let ledgerSnapshot = LedgerSnapshot(exists: snapshot.exists,
                                             groupFingerprint: snapshot.fingerprint,
                                             titleFingerprint: snapshot.title.map(OrganizationCommandFingerprint.digest),
                                             parentFingerprint: snapshot.parentID.map(OrganizationCommandFingerprint.digest),
                                             memberFingerprints: snapshot.memberIDs
                                                 .map(OrganizationCommandFingerprint.digest)
                                                 .sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ledgerSnapshot)
    }

    private func decodeSnapshot(_ data: Data) throws -> LedgerSnapshot {
        try JSONDecoder().decode(LedgerSnapshot.self, from: data)
    }

    private func afterData(of operation: OrganizationOperation) throws -> Data {
        guard operation.betterMailDelta.formatIdentifier == "organization-group-v1" else {
            throw OrganizationCommandServiceError.operationConflict
        }
        return operation.betterMailDelta.after
    }
}

private nonisolated enum OrganizationCommandFingerprint {
    static func group(_ value: String) -> String {
        digest("group|\(value)")
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
