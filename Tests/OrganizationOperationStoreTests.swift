import Foundation
import XCTest
@testable import BetterMail

final class OrganizationOperationStoreTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testLifecycleGuardsAndAdvancesThroughUndo() async throws {
        let fileIO = InMemoryOrganizationOperationFileIO()
        let store = makeStore(fileIO: fileIO)
        let operation = makeOperation(id: "lifecycle", createdAt: baseDate)

        _ = try await store.prepare(operation)
        let appApplied = try await store.advance(id: operation.id,
                                                  to: .appApplied,
                                                  receipt: OrganizationOperationReceipt(kind: .appApplied,
                                                                                       date: baseDate.addingTimeInterval(1),
                                                                                       expectedCount: 1,
                                                                                       completedCount: 1),
                                                  at: baseDate.addingTimeInterval(1))
        XCTAssertEqual(appApplied.phase, .appApplied)

        _ = try await store.advance(id: operation.id, to: .layoutPending, at: baseDate.addingTimeInterval(2))
        _ = try await store.advance(id: operation.id, to: .mailApplying, at: baseDate.addingTimeInterval(3))
        let completed = try await store.advance(id: operation.id,
                                                to: .completed,
                                                receipt: OrganizationOperationReceipt(kind: .mail,
                                                                                     date: baseDate.addingTimeInterval(4),
                                                                                     expectedCount: 1,
                                                                                     completedCount: 1),
                                                at: baseDate.addingTimeInterval(4))
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.receipts.count, 2)

        let undone = try await store.advance(id: operation.id,
                                             to: .undone,
                                             receipt: OrganizationOperationReceipt(kind: .undo,
                                                                                  date: baseDate.addingTimeInterval(5)),
                                             at: baseDate.addingTimeInterval(5))
        XCTAssertEqual(undone.phase, .undone)
        XCTAssertEqual(undone.phaseTimestamps.map(\.phase),
                       [.prepared, .appApplied, .layoutPending, .mailApplying, .completed, .undone])
    }

    func testPersistenceSurvivesRelaunch() async throws {
        let fileIO = InMemoryOrganizationOperationFileIO()
        let operation = makeOperation(id: "relaunch", createdAt: baseDate)
        let firstStore = makeStore(fileIO: fileIO)

        _ = try await firstStore.prepare(operation)
        _ = try await firstStore.advance(id: operation.id, to: .appApplied, at: baseDate.addingTimeInterval(1))

        let secondStore = makeStore(fileIO: fileIO)
        let restored = try await secondStore.operation(id: operation.id)
        XCTAssertEqual(restored?.phase, .appApplied)
        XCTAssertEqual(restored?.betterMailDelta, operation.betterMailDelta)
        XCTAssertEqual(restored?.opaqueSourceFingerprints, operation.opaqueSourceFingerprints)
    }

    func testRelaunchMarksOnlyInterruptedExternalCallsRecoveryWithoutImplicitReplay() async throws {
        let fileIO = InMemoryOrganizationOperationFileIO()
        let fileURL = testFileURL("interrupted-mail")
        let firstStore = makeStore(fileIO: fileIO, fileURL: fileURL)
        let interrupted = makeOperation(id: "interrupted", createdAt: baseDate)
        let notStarted = makeOperation(id: "not-started", createdAt: baseDate.addingTimeInterval(1))
        let routePayload = Data("exact encrypted route".utf8)

        _ = try await firstStore.prepare(interrupted, mailRoutePayload: routePayload)
        _ = try await firstStore.advance(id: interrupted.id,
                                         to: .appApplied,
                                         at: baseDate.addingTimeInterval(2))
        _ = try await firstStore.advance(id: interrupted.id,
                                         to: .mailApplying,
                                         at: baseDate.addingTimeInterval(3))
        _ = try await firstStore.prepare(notStarted, mailRoutePayload: routePayload)
        _ = try await firstStore.advance(id: notStarted.id,
                                         to: .appApplied,
                                         at: baseDate.addingTimeInterval(3))
        let interruptedBeforeRelaunch = try await firstStore.operation(id: interrupted.id)
        let envelopeBeforeRelaunch = try XCTUnwrap(interruptedBeforeRelaunch?.mailRouteEnvelope)

        let relaunchedStore = makeStore(fileIO: fileIO, fileURL: fileURL)
        let recovered = try await relaunchedStore.markInterruptedMailOperationsForRecovery(
            at: baseDate.addingTimeInterval(10)
        )

        XCTAssertEqual(recovered.map(\.id), [interrupted.id])
        let interruptedAfterRelaunchValue = try await relaunchedStore.operation(id: interrupted.id)
        let interruptedAfterRelaunch = try XCTUnwrap(interruptedAfterRelaunchValue)
        XCTAssertEqual(interruptedAfterRelaunch.phase, .recovery)
        XCTAssertEqual(interruptedAfterRelaunch.lastFailure?.code,
                       "mail-interrupted-during-external-call")
        XCTAssertEqual(interruptedAfterRelaunch.lastFailure?.retryable, false)
        XCTAssertEqual(interruptedAfterRelaunch.receipts.last?.kind, .recovery)
        XCTAssertEqual(interruptedAfterRelaunch.mailRouteEnvelope, envelopeBeforeRelaunch)
        let notStartedAfterRelaunch = try await relaunchedStore.operation(id: notStarted.id)
        XCTAssertEqual(notStartedAfterRelaunch?.phase,
                       .appApplied,
                       "Prepared-but-not-started Mail remains resumable only after fresh authorization")

        let secondAudit = try await relaunchedStore.markInterruptedMailOperationsForRecovery(
            at: baseDate.addingTimeInterval(11)
        )
        XCTAssertTrue(secondAudit.isEmpty)
    }

    func testInvalidTransitionDoesNotPersist() async throws {
        let fileIO = InMemoryOrganizationOperationFileIO()
        let store = makeStore(fileIO: fileIO)
        let operation = makeOperation(id: "invalid-transition", createdAt: baseDate)
        _ = try await store.prepare(operation)

        do {
            _ = try await store.advance(id: operation.id, to: .completed, at: baseDate.addingTimeInterval(1))
            XCTFail("prepared must not jump directly to completed")
        } catch let error as OrganizationOperationStoreError {
            XCTAssertEqual(error,
                           .invalidTransition(from: .prepared, to: .completed))
        }

        let current = try await store.operation(id: operation.id)
        XCTAssertEqual(current?.phase, .prepared)
    }

    func testPartialAndRecoveryRecordFailureAndAllowRetry() async throws {
        let fileIO = InMemoryOrganizationOperationFileIO()
        let store = makeStore(fileIO: fileIO)
        let operation = makeOperation(id: "partial-recovery", createdAt: baseDate)
        _ = try await store.prepare(operation)
        _ = try await store.advance(id: operation.id, to: .appApplied, at: baseDate.addingTimeInterval(1))
        _ = try await store.advance(id: operation.id, to: .mailApplying, at: baseDate.addingTimeInterval(2))

        let failure = OrganizationOperationFailure(code: "mailMovePartial",
                                                    retryable: true,
                                                    attempt: 1,
                                                    date: baseDate.addingTimeInterval(3))
        let partial = try await store.advance(id: operation.id,
                                              to: .partial,
                                              failure: failure,
                                              at: baseDate.addingTimeInterval(3))
        XCTAssertEqual(partial.phase, .partial)
        XCTAssertEqual(partial.lastFailure?.code, "mailMovePartial")
        XCTAssertEqual(partial.retryCount, 1)

        _ = try await store.advance(id: operation.id,
                                    to: .recovery,
                                    receipt: OrganizationOperationReceipt(kind: .recovery,
                                                                         date: baseDate.addingTimeInterval(4)),
                                    at: baseDate.addingTimeInterval(4))
        let retry = try await store.advance(id: operation.id,
                                            to: .mailApplying,
                                            at: baseDate.addingTimeInterval(5))
        XCTAssertEqual(retry.phase, .mailApplying)
        XCTAssertEqual(retry.retryCount, 1)
    }

    func testTerminalRouteRedactionAfterThirtyDays() async throws {
        let fileIO = InMemoryOrganizationOperationFileIO()
        let crypto = makeCrypto(keyData: routeKey)
        let store = makeStore(fileIO: fileIO, crypto: crypto)
        let operation = makeOperation(id: "redaction", createdAt: baseDate)

        _ = try await store.prepare(operation, mailRoutePayload: Data("exact Mail route".utf8))
        _ = try await store.advance(id: operation.id, to: .appApplied, at: baseDate.addingTimeInterval(1))
        _ = try await store.advance(id: operation.id, to: .mailApplying, at: baseDate.addingTimeInterval(2))
        _ = try await store.advance(id: operation.id, to: .completed, at: baseDate.addingTimeInterval(3))

        let redactedIDs = try await store.redactTerminalRoutes(now: baseDate.addingTimeInterval(31 * 24 * 60 * 60))
        XCTAssertEqual(redactedIDs, [operation.id])
        let redactedOperation = try await store.operation(id: operation.id)
        let redacted = try XCTUnwrap(redactedOperation)
        XCTAssertNil(redacted.mailRouteEnvelope)
        XCTAssertNotNil(redacted.routesRedactedAt)

        do {
            _ = try await store.readMailRoutePayload(for: operation.id)
            XCTFail("redacted route must not be readable")
        } catch let error as OrganizationOperationStoreError {
            XCTAssertEqual(error, .routeRedacted)
        }
    }

    func testMissingRouteKeyFailsClosedPreservesCiphertextAndRestores() async throws {
        let fileIO = InMemoryOrganizationOperationFileIO()
        let operation = makeOperation(id: "key-loss", createdAt: baseDate)
        let payload = Data("account|mailbox|message route".utf8)
        let writingStore = makeStore(fileIO: fileIO, crypto: makeCrypto(keyData: routeKey))
        _ = try await writingStore.prepare(operation, mailRoutePayload: payload)
        let writtenOperation = try await writingStore.operation(id: operation.id)
        let originalEnvelope = try XCTUnwrap(writtenOperation?.mailRouteEnvelope)

        let missingKeyStore = makeStore(fileIO: fileIO, crypto: makeCrypto(keyData: nil))
        do {
            _ = try await missingKeyStore.readMailRoutePayload(for: operation.id,
                                                               at: baseDate.addingTimeInterval(10))
            XCTFail("missing key must fail closed")
        } catch let error as OrganizationOperationStoreError {
            XCTAssertEqual(error, .recoveryKeyUnavailable)
        }

        let recoveryOperation = try await missingKeyStore.operation(id: operation.id)
        let recovery = try XCTUnwrap(recoveryOperation)
        XCTAssertEqual(recovery.phase, .recovery)
        XCTAssertEqual(recovery.lastFailure?.code, "recoveryKeyUnavailable")
        XCTAssertEqual(recovery.mailRouteEnvelope?.nonce, originalEnvelope.nonce)
        XCTAssertEqual(recovery.mailRouteEnvelope?.ciphertext, originalEnvelope.ciphertext)
        XCTAssertEqual(recovery.mailRouteEnvelope?.tag, originalEnvelope.tag)
        XCTAssertEqual(recovery.mailRouteEnvelope?.keyIdentifier, originalEnvelope.keyIdentifier)

        let restoredKeyStore = makeStore(fileIO: fileIO, crypto: makeCrypto(keyData: routeKey))
        let restoredPayload = try await restoredKeyStore.readMailRoutePayload(for: operation.id)
        XCTAssertEqual(restoredPayload, payload)
        _ = try await restoredKeyStore.advance(id: operation.id,
                                               to: .mailApplying,
                                               at: baseDate.addingTimeInterval(11))
        let retried = try await restoredKeyStore.operation(id: operation.id)
        XCTAssertEqual(retried?.phase, .mailApplying)
    }

    func testProductionCryptoSeam_neverCreatesReplacementKeyDuringDecrypt() throws {
        let provider = InMemoryOrganizationRouteKeyProvider(key: routeKey)
        let crypto = KeychainOrganizationRouteCryptoProvider(
            keyIdentifier: "test-keychain-route-v1",
            keyProvider: provider
        )
        let payload = Data("exact route".utf8)
        let envelope = try crypto.encrypt(payload)
        XCTAssertEqual(provider.createCallCount, 1)

        provider.key = nil
        XCTAssertThrowsError(try crypto.decrypt(envelope)) { error in
            XCTAssertEqual(error as? OrganizationRouteCryptoError,
                           .keyUnavailable("test-keychain-route-v1"))
        }
        XCTAssertEqual(provider.createCallCount, 1,
                       "decrypt must not manufacture a replacement key")

        provider.key = routeKey
        XCTAssertEqual(try crypto.decrypt(envelope), payload)
        XCTAssertEqual(provider.createCallCount, 1)
    }

    func testCorruptArchiveIsQuarantinedWithoutDestroyingOriginal() async throws {
        let fileIO = InMemoryOrganizationOperationFileIO()
        let original = Data([0xde, 0xad, 0xbe, 0xef])
        let fileURL = testFileURL("corrupt")
        fileIO.seed(original, at: fileURL)
        let store = makeStore(fileIO: fileIO, fileURL: fileURL)

        try await store.load()
        let operations = try await store.allOperations()
        XCTAssertTrue(operations.isEmpty)
        let records = try await store.quarantinedRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.reason, .corruptDocument)
        XCTAssertEqual(records.first?.byteCount, original.count)
        XCTAssertEqual(fileIO.snapshot(at: fileURL), original)
        XCTAssertEqual(fileIO.snapshot(at: URL(fileURLWithPath: records[0].quarantineURL)), original)
    }

    func testFutureArchiveIsQuarantinedWithoutDecodingAsCurrent() async throws {
        let fileIO = InMemoryOrganizationOperationFileIO()
        let fileURL = testFileURL("future")
        let futureArchive = OrganizationOperationArchive(schemaVersion: OrganizationOperation.currentSchemaVersion + 1,
                                                         operations: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(futureArchive)
        fileIO.seed(data, at: fileURL)
        let store = makeStore(fileIO: fileIO, fileURL: fileURL)

        try await store.load()
        let operations = try await store.allOperations()
        XCTAssertTrue(operations.isEmpty)
        let records = try await store.quarantinedRecords()
        XCTAssertEqual(records.first?.reason, .futureSchema)
        XCTAssertEqual(fileIO.snapshot(at: fileURL), data)
    }

    func testLegacyArchiveMigratesToCurrentVersion() async throws {
        let fileIO = InMemoryOrganizationOperationFileIO()
        let fileURL = testFileURL("legacy")
        let legacy = makeOperation(id: "legacy", createdAt: baseDate, schemaVersion: 0)
        let archive = OrganizationOperationArchive(schemaVersion: 0, operations: [legacy])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode(archive)
        fileIO.seed(legacyData, at: fileURL)
        let store = makeStore(fileIO: fileIO, fileURL: fileURL)

        let migratedOperation = try await store.operation(id: legacy.id)
        let migrated = try XCTUnwrap(migratedOperation)
        XCTAssertEqual(migrated.schemaVersion, OrganizationOperation.currentSchemaVersion)
        let migratedData = try XCTUnwrap(fileIO.snapshot(at: fileURL))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(OrganizationOperationArchive.self, from: migratedData).schemaVersion,
                       OrganizationOperation.currentSchemaVersion)
    }

    private var routeKey: Data {
        Data(repeating: 0x1f, count: 32)
    }

    private func makeStore(fileIO: InMemoryOrganizationOperationFileIO,
                           fileURL: URL? = nil,
                           crypto: CryptoKitOrganizationRouteCryptoProvider? = nil) -> OrganizationOperationStore {
        OrganizationOperationStore(fileURL: fileURL ?? testFileURL("store"),
                                   fileIO: fileIO,
                                   routeCrypto: crypto ?? makeCrypto(keyData: routeKey))
    }

    private func makeCrypto(keyData: Data?) -> CryptoKitOrganizationRouteCryptoProvider {
        CryptoKitOrganizationRouteCryptoProvider(keyIdentifier: "test-route-v1",
                                                  keyData: keyData,
                                                  now: baseDate)
    }

    private func makeOperation(id: String,
                               createdAt: Date,
                               schemaVersion: Int = OrganizationOperation.currentSchemaVersion) -> OrganizationOperation {
        OrganizationOperation(id: id,
                              kind: .mailMove,
                              opaqueSourceFingerprints: ["source-\(id)"],
                              opaqueTargetFingerprints: ["target-\(id)"],
                              betterMailDelta: OrganizationBetterMailDelta(formatIdentifier: "test-delta-v1",
                                                                            before: Data([0x00]),
                                                                            after: Data([0x01])),
                              authorizationReference: OrganizationAuthorizationReference(authorizationID: "consent-\(id)",
                                                                                          consentSchemaVersion: 1,
                                                                                          effect: .messageMove,
                                                                                          issuedAt: createdAt,
                                                                                          disclosureFingerprint: "disclosure-\(id)"),
                              spatialAnchorIntent: OrganizationSpatialAnchorIntent(opaqueScopeFingerprint: "scope-\(id)",
                                                                                   x: 10,
                                                                                   y: 20,
                                                                                   zoom: 1),
                              schemaVersion: schemaVersion,
                              createdAt: createdAt)
    }

    private func testFileURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/organization-operation-\(name)-\(ObjectIdentifier(self).hashValue).json")
    }
}

private final class InMemoryOrganizationOperationFileIO: OrganizationOperationFileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: Data] = [:]

    func seed(_ data: Data, at url: URL) {
        lock.lock()
        values[url] = data
        lock.unlock()
    }

    func snapshot(at url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[url]
    }

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
        values[url] = data
        lock.unlock()
    }
}

private final class InMemoryOrganizationRouteKeyProvider: OrganizationRouteKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?
    private var storedCreateCallCount = 0

    init(key: Data?) {
        storedKey = key
    }

    var key: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedKey
        }
        set {
            lock.lock()
            storedKey = newValue
            lock.unlock()
        }
    }

    var createCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCreateCallCount
    }

    func existingKey(identifier: String) throws -> Data? {
        key
    }

    func loadOrCreateKey(identifier: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        storedCreateCallCount += 1
        if let storedKey {
            return storedKey
        }
        let generated = Data(repeating: 0x7a, count: 32)
        storedKey = generated
        return generated
    }
}
