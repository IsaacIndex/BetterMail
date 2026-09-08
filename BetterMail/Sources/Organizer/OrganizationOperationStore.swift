import Foundation

internal nonisolated enum OrganizationOperationFileIOError: Error, Equatable, Sendable {
    case notFound
    case readFailed
    case writeFailed
}

/// The store only needs two file primitives. Keeping them behind this seam
/// lets tests model relaunch, corruption, and atomic-write failures without
/// touching the real filesystem.
internal nonisolated protocol OrganizationOperationFileIO: Sendable {
    func read(at url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
}

internal nonisolated struct DefaultOrganizationOperationFileIO: OrganizationOperationFileIO, Sendable {
    internal init() {}

    internal func read(at url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OrganizationOperationFileIOError.notFound
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw OrganizationOperationFileIOError.readFailed
        }
    }

    internal func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            let directoryURL = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL,
                                                     withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw OrganizationOperationFileIOError.writeFailed
        }
    }
}

/// Durable operation-ledger storage. The prepared operation is the write-ahead
/// boundary around the separate Core Data transaction. These independent stores
/// intentionally use crash-consistent, idempotent recovery; they do not claim
/// an impossible cross-store atomic commit.
internal actor OrganizationOperationStore {
    /// The production ledger is process-wide so independent UI/service entry
    /// points cannot race separate actor instances against the same JSON file.
    internal static let shared = OrganizationOperationStore()
    internal static let routeRetention: TimeInterval = 30 * 24 * 60 * 60

    internal nonisolated static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("BetterMail", isDirectory: true)
            .appendingPathComponent("OrganizationOperations.json", isDirectory: false)
    }

    private let fileURL: URL
    private let fileIO: any OrganizationOperationFileIO
    private let routeCrypto: any OrganizationRouteCryptoProviding
    private var loaded = false
    private var operationsByID: [String: OrganizationOperation] = [:]
    private var quarantines: [OrganizationOperationQuarantineRecord] = []

    internal init(fileURL: URL = OrganizationOperationStore.defaultFileURL(),
                  fileIO: any OrganizationOperationFileIO = DefaultOrganizationOperationFileIO(),
                  routeCrypto: any OrganizationRouteCryptoProviding = KeychainOrganizationRouteCryptoProvider()) {
        self.fileURL = fileURL
        self.fileIO = fileIO
        self.routeCrypto = routeCrypto
    }

    /// Loads the ledger, treating a missing file as an empty store. A corrupt
    /// or future document is copied to a unique quarantine artifact and is
    /// never overwritten as part of recovery.
    internal func load() throws {
        try ensureLoaded()
    }

    /// Returns the prepared operation after it has been durably written. A
    /// caller can use this as the boundary around its BetterMail transaction.
    @discardableResult
    internal func prepare(_ operation: OrganizationOperation,
                          mailRoutePayload: Data? = nil) throws -> OrganizationOperation {
        try ensureLoaded()
        guard operationsByID[operation.id] == nil else {
            throw OrganizationOperationStoreError.duplicateOperation
        }
        guard operation.phase == .prepared else {
            throw OrganizationOperationStoreError.invalidOperation("operation must begin prepared")
        }

        var candidate = try normalized(operation)
        if let mailRoutePayload {
            do {
                candidate.mailRouteEnvelope = try routeCrypto.encrypt(mailRoutePayload)
            } catch let error as OrganizationRouteCryptoError {
                if case .keyUnavailable = error {
                    throw OrganizationOperationStoreError.recoveryKeyUnavailable
                }
                throw OrganizationOperationStoreError.routeEncryptionFailed
            } catch {
                throw OrganizationOperationStoreError.routeEncryptionFailed
            }
        }

        var nextOperations = operationsByID
        nextOperations[candidate.id] = candidate
        try persist(nextOperations)
        operationsByID = nextOperations
        return candidate
    }

    internal func operation(id: String) throws -> OrganizationOperation? {
        try ensureLoaded()
        return operationsByID[id]
    }

    internal func allOperations() throws -> [OrganizationOperation] {
        try ensureLoaded()
        return operationsByID.values.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id < $1.id
            }
            return $0.createdAt < $1.createdAt
        }
    }

    /// A process that relaunches with an operation in `mailApplying` cannot
    /// know whether Apple Mail completed before termination. Persist the
    /// uncertainty once and never infer success or schedule an implicit replay.
    @discardableResult
    internal func markInterruptedMailOperationsForRecovery(
        at date: Date = Date()
    ) throws -> [OrganizationOperation] {
        try ensureLoaded()
        var nextOperations = operationsByID
        var recovered: [OrganizationOperation] = []

        for (id, operation) in operationsByID where operation.phase == .mailApplying {
            let expectedCount = max(operation.opaqueSourceFingerprints.count,
                                    operation.receipts.map(\.expectedCount).max() ?? 0)
            let attempt = max(operation.retryCount + 1, 1)
            var candidate = operation
            candidate.phase = .recovery
            candidate.updatedAt = date
            candidate.retryCount = attempt
            candidate.phaseTimestamps.append(
                OrganizationOperationPhaseTimestamp(phase: .recovery, date: date)
            )
            candidate.receipts.append(
                OrganizationOperationReceipt(kind: .recovery,
                                             date: date,
                                             expectedCount: expectedCount,
                                             completedCount: 0,
                                             opaqueItemFingerprints: [])
            )
            candidate.lastFailure = OrganizationOperationFailure(
                code: "mail-interrupted-during-external-call",
                retryable: false,
                attempt: attempt,
                date: date
            )
            nextOperations[id] = candidate
            recovered.append(candidate)
        }

        guard !recovered.isEmpty else { return [] }
        try persist(nextOperations)
        operationsByID = nextOperations
        return recovered.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }

    /// Records the concrete layout receipt separately from the generic event
    /// receipt. It is intentionally not a phase transition: layout and Mail
    /// work can complete on different clocks.
    @discardableResult
    internal func recordSpatialAnchorReceipt(id: String,
                                             receipt: OrganizationSpatialAnchorReceipt,
                                             at date: Date = Date()) throws -> OrganizationOperation {
        try ensureLoaded()
        guard let current = operationsByID[id] else {
            throw OrganizationOperationStoreError.operationNotFound
        }
        guard let intent = current.spatialAnchorIntent,
              intent.intentID == receipt.intentID else {
            throw OrganizationOperationStoreError.invalidOperation("spatial anchor receipt does not match intent")
        }

        var candidate = current
        candidate.spatialAnchorReceipt = receipt
        candidate.receipts.append(OrganizationOperationReceipt(kind: .spatialAnchor,
                                                                date: date,
                                                                opaqueItemFingerprints: [intent.opaqueScopeFingerprint]))
        candidate.updatedAt = date
        var nextOperations = operationsByID
        nextOperations[id] = candidate
        try persist(nextOperations)
        operationsByID = nextOperations
        return candidate
    }

    internal func quarantinedRecords() throws -> [OrganizationOperationQuarantineRecord] {
        try ensureLoaded()
        return quarantines
    }

    /// Advances a phase only through the lifecycle graph. The candidate is
    /// persisted first; an I/O error leaves the in-memory operation unchanged.
    @discardableResult
    internal func advance(id: String,
                          to nextPhase: OrganizationOperationPhase,
                          receipt: OrganizationOperationReceipt? = nil,
                          failure: OrganizationOperationFailure? = nil,
                          at date: Date = Date()) throws -> OrganizationOperation {
        try ensureLoaded()
        guard let current = operationsByID[id] else {
            throw OrganizationOperationStoreError.operationNotFound
        }
        guard current.phase.canTransition(to: nextPhase) else {
            throw OrganizationOperationStoreError.invalidTransition(from: current.phase, to: nextPhase)
        }

        var candidate = current
        candidate.phase = nextPhase
        candidate.updatedAt = date
        candidate.phaseTimestamps.append(OrganizationOperationPhaseTimestamp(phase: nextPhase, date: date))
        if let receipt {
            candidate.receipts.append(receipt)
        }
        if let failure {
            candidate.lastFailure = failure
            candidate.retryCount = max(candidate.retryCount, failure.attempt)
        }

        var nextOperations = operationsByID
        nextOperations[id] = candidate
        try persist(nextOperations)
        operationsByID = nextOperations
        return candidate
    }

    /// Decrypts the exact stored Mail route. Missing keys enter recovery and
    /// persist a stable failure code while leaving every envelope byte intact.
    internal func readMailRoutePayload(for id: String,
                                       at date: Date = Date()) throws -> Data {
        try ensureLoaded()
        guard let operation = operationsByID[id] else {
            throw OrganizationOperationStoreError.operationNotFound
        }
        guard operation.routesRedactedAt == nil else {
            throw OrganizationOperationStoreError.routeRedacted
        }
        guard let envelope = operation.mailRouteEnvelope else {
            throw OrganizationOperationStoreError.routeUnavailable
        }

        do {
            return try routeCrypto.decrypt(envelope)
        } catch let error as OrganizationRouteCryptoError {
            if case .keyUnavailable = error {
                try markRecoveryKeyUnavailable(operation: operation, at: date)
                throw OrganizationOperationStoreError.recoveryKeyUnavailable
            }
            throw OrganizationOperationStoreError.routeDecryptionFailed
        } catch {
            throw OrganizationOperationStoreError.routeDecryptionFailed
        }
    }

    /// Removes only terminal exact-route envelopes after the retention window.
    /// The operation and its opaque receipt/fingerprint history remain.
    @discardableResult
    internal func redactTerminalRoutes(now: Date = Date()) throws -> [String] {
        try ensureLoaded()
        let cutoff = now.addingTimeInterval(-Self.routeRetention)
        var nextOperations = operationsByID
        var redactedIDs: [String] = []

        for (id, operation) in operationsByID {
            guard operation.phase.isTerminal,
                  operation.mailRouteEnvelope != nil,
                  operation.routesRedactedAt == nil,
                  let terminalDate = terminalDate(for: operation),
                  terminalDate <= cutoff else {
                continue
            }

            var redacted = operation
            redacted.mailRouteEnvelope = nil
            redacted.routesRedactedAt = now
            redacted.updatedAt = now
            nextOperations[id] = redacted
            redactedIDs.append(id)
        }

        guard !redactedIDs.isEmpty else {
            return []
        }

        do {
            try persist(nextOperations)
        } catch {
            throw error
        }
        operationsByID = nextOperations
        return redactedIDs.sorted()
    }

    /// Copies arbitrary bytes to a unique quarantine artifact without
    /// replacing the ledger source. This is useful for manual migration and
    /// for recovery tooling that cannot safely decode an operation.
    @discardableResult
    internal func quarantine(data: Data,
                             reason: OrganizationOperationQuarantineReason,
                             operationID: String? = nil,
                             at date: Date = Date()) throws -> OrganizationOperationQuarantineRecord {
        try ensureLoaded()
        return try writeQuarantine(data: data, reason: reason, operationID: operationID, at: date)
    }

    /// Quarantines one decoded operation as an immutable recovery artifact.
    /// The active operation remains in the ledger so no source record is
    /// silently discarded.
    @discardableResult
    internal func quarantineOperation(id: String,
                                      reason: OrganizationOperationQuarantineReason,
                                      at date: Date = Date()) throws -> OrganizationOperationQuarantineRecord {
        try ensureLoaded()
        guard let operation = operationsByID[id] else {
            throw OrganizationOperationStoreError.operationNotFound
        }
        let data: Data
        do {
            data = try encode(operation)
        } catch {
            throw OrganizationOperationStoreError.quarantineFailed
        }
        return try writeQuarantine(data: data, reason: reason, operationID: id, at: date)
    }

    private func ensureLoaded() throws {
        guard !loaded else {
            return
        }

        let data: Data
        do {
            data = try fileIO.read(at: fileURL)
        } catch let error as OrganizationOperationFileIOError {
            if error == .notFound {
                loaded = true
                return
            }
            throw OrganizationOperationStoreError.fileReadFailed
        } catch {
            throw OrganizationOperationStoreError.fileReadFailed
        }

        let archive: OrganizationOperationArchive
        do {
            archive = try decodeArchive(data)
        } catch {
            try quarantineLoadedDocument(data, reason: .corruptDocument)
            loaded = true
            return
        }

        if archive.schemaVersion > OrganizationOperation.currentSchemaVersion
            || archive.operations.contains(where: { $0.schemaVersion > OrganizationOperation.currentSchemaVersion }) {
            try quarantineLoadedDocument(data, reason: .futureSchema)
            loaded = true
            return
        }

        do {
            var migrated: [String: OrganizationOperation] = [:]
            for operation in archive.operations {
                let normalizedOperation = try normalized(operation)
                guard migrated[normalizedOperation.id] == nil else {
                    throw OrganizationOperationStoreError.invalidOperation("duplicate operation id")
                }
                migrated[normalizedOperation.id] = normalizedOperation
            }
            operationsByID = migrated
        } catch {
            operationsByID = [:]
            try quarantineLoadedDocument(data, reason: .unsafeLegacyPayload)
            loaded = true
            return
        }

        loaded = true
        if archive.schemaVersion < OrganizationOperation.currentSchemaVersion
            || archive.operations.contains(where: { $0.schemaVersion < OrganizationOperation.currentSchemaVersion }) {
            do {
                try persist(operationsByID)
            } catch {
                loaded = false
                throw error
            }
        }
    }

    private func normalized(_ operation: OrganizationOperation) throws -> OrganizationOperation {
        guard !operation.id.isEmpty else {
            throw OrganizationOperationStoreError.invalidOperation("operation id is empty")
        }
        guard operation.schemaVersion >= 0,
              operation.schemaVersion <= OrganizationOperation.currentSchemaVersion else {
            throw OrganizationOperationStoreError.invalidOperation("unsupported operation schema")
        }
        guard operation.retryCount >= 0 else {
            throw OrganizationOperationStoreError.invalidOperation("negative retry count")
        }

        var normalizedOperation = operation
        normalizedOperation.schemaVersion = OrganizationOperation.currentSchemaVersion
        if normalizedOperation.phaseTimestamps.isEmpty {
            normalizedOperation.phaseTimestamps = [OrganizationOperationPhaseTimestamp(phase: normalizedOperation.phase,
                                                                                          date: normalizedOperation.createdAt)]
        }
        return normalizedOperation
    }

    private func markRecoveryKeyUnavailable(operation: OrganizationOperation, at date: Date) throws {
        guard operation.phase != .undone else {
            return
        }

        var candidate = operation
        if operation.phase != .recovery {
            guard operation.phase.canTransition(to: .recovery) else {
                return
            }
            candidate.phase = .recovery
            candidate.phaseTimestamps.append(OrganizationOperationPhaseTimestamp(phase: .recovery, date: date))
        }
        candidate.retryCount += 1
        candidate.lastFailure = OrganizationOperationFailure(code: "recoveryKeyUnavailable",
                                                             retryable: true,
                                                             attempt: candidate.retryCount,
                                                             date: date)
        candidate.updatedAt = date

        var nextOperations = operationsByID
        nextOperations[operation.id] = candidate
        try persist(nextOperations)
        operationsByID = nextOperations
    }

    private func terminalDate(for operation: OrganizationOperation) -> Date? {
        operation.phaseTimestamps.last(where: { $0.phase == operation.phase })?.date ?? operation.updatedAt
    }

    private func decodeArchive(_ data: Data) throws -> OrganizationOperationArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OrganizationOperationArchive.self, from: data)
    }

    private func encode(_ operation: OrganizationOperation) throws -> Data {
        try encodeArchive(OrganizationOperationArchive(operations: [operation]))
    }

    private func encode(_ operations: [String: OrganizationOperation]) throws -> Data {
        let archive = OrganizationOperationArchive(operations: operations.values.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id < $1.id
            }
            return $0.createdAt < $1.createdAt
        })
        return try encodeArchive(archive)
    }

    private func encodeArchive(_ archive: OrganizationOperationArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    private func persist(_ operations: [String: OrganizationOperation]) throws {
        do {
            try fileIO.writeAtomically(try encode(operations), to: fileURL)
        } catch is OrganizationOperationFileIOError {
            throw OrganizationOperationStoreError.fileWriteFailed
        } catch {
            throw OrganizationOperationStoreError.fileWriteFailed
        }
    }

    private func quarantineLoadedDocument(_ data: Data,
                                          reason: OrganizationOperationQuarantineReason,
                                          at date: Date = Date()) throws {
        do {
            _ = try writeQuarantine(data: data, reason: reason, operationID: nil, at: date)
        } catch {
            throw OrganizationOperationStoreError.quarantineFailed
        }
    }

    private func writeQuarantine(data: Data,
                                 reason: OrganizationOperationQuarantineReason,
                                 operationID: String?,
                                 at date: Date) throws -> OrganizationOperationQuarantineRecord {
        let directoryURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("organization-operation-quarantine", isDirectory: true)
        let artifactURL = directoryURL.appendingPathComponent(UUID().uuidString + ".bin")

        do {
            try fileIO.writeAtomically(data, to: artifactURL)
        } catch {
            throw OrganizationOperationStoreError.quarantineFailed
        }

        let record = OrganizationOperationQuarantineRecord(reason: reason,
                                                           createdAt: date,
                                                           byteCount: data.count,
                                                           operationID: operationID,
                                                           quarantineURL: artifactURL.path)
        quarantines.append(record)
        return record
    }
}
