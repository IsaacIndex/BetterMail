import CryptoKit
import Foundation
import Security

/// The durable kind of an organizer operation. The ledger deliberately records
/// intent and opaque identities rather than message bodies or route strings.
internal nonisolated enum OrganizationOperationKind: String, Codable, CaseIterable, Sendable {
    case manualGroup
    case manualUngroup
    case suggestionAcceptance
    case graphArchive
    case snip
    case mailMove
    case mailboxCreation
    case automation
    case retry
    case recovery
    case undo
}

internal nonisolated enum OrganizationOperationEffect: String, Codable, CaseIterable, Sendable {
    case betterMailOnly
    case mailboxCreation
    case messageMove
    case restore
    case mixed
}

/// A phase is intentionally narrower than a UI status. Every mutation of a
/// phase is checked by `canTransition(to:)` before it is persisted.
internal nonisolated enum OrganizationOperationPhase: String, Codable, CaseIterable, Sendable {
    case prepared
    case appApplied
    case layoutPending
    case mailApplying
    case completed
    case partial
    case recovery
    case undone

    internal func canTransition(to next: OrganizationOperationPhase) -> Bool {
        switch (self, next) {
        case (.prepared, .appApplied),
             (.prepared, .recovery),
             (.appApplied, .layoutPending),
             (.appApplied, .mailApplying),
             (.appApplied, .completed),
             (.appApplied, .partial),
             (.appApplied, .recovery),
             (.layoutPending, .mailApplying),
             (.layoutPending, .completed),
             (.layoutPending, .partial),
             (.layoutPending, .recovery),
             (.mailApplying, .completed),
             (.mailApplying, .partial),
             (.mailApplying, .recovery),
             (.partial, .layoutPending),
             (.partial, .mailApplying),
             (.partial, .recovery),
             (.partial, .undone),
             (.recovery, .layoutPending),
             (.recovery, .mailApplying),
             (.recovery, .partial),
             (.recovery, .undone),
             (.completed, .undone),
             (.completed, .recovery):
            return true
        default:
            return false
        }
    }

    internal var isTerminal: Bool {
        switch self {
        case .completed, .undone:
            return true
        case .prepared, .appApplied, .layoutPending, .mailApplying, .partial, .recovery:
            return false
        }
    }
}

internal nonisolated enum OrganizationOperationReceiptKind: String, Codable, CaseIterable, Sendable {
    case appApplied
    case spatialAnchor
    case mail
    case compensation
    case recovery
    case undo
}

internal nonisolated struct OrganizationOperationPhaseTimestamp: Codable, Hashable, Sendable {
    internal let phase: OrganizationOperationPhase
    internal let date: Date

    internal init(phase: OrganizationOperationPhase, date: Date) {
        self.phase = phase
        self.date = date
    }
}

internal nonisolated struct OrganizationOperationFailure: Codable, Hashable, Sendable {
    /// Stable, non-sensitive failure code. Raw Mail errors and route strings
    /// must not be placed in this field.
    internal let code: String
    internal let retryable: Bool
    internal let attempt: Int
    internal let date: Date

    internal init(code: String, retryable: Bool, attempt: Int, date: Date) {
        self.code = code
        self.retryable = retryable
        self.attempt = attempt
        self.date = date
    }
}

internal nonisolated struct OrganizationOperationReceipt: Codable, Hashable, Sendable {
    internal let id: String
    internal let kind: OrganizationOperationReceiptKind
    internal let date: Date
    internal let expectedCount: Int
    internal let completedCount: Int
    internal let opaqueItemFingerprints: [String]

    internal init(id: String = UUID().uuidString,
                  kind: OrganizationOperationReceiptKind,
                  date: Date,
                  expectedCount: Int = 0,
                  completedCount: Int = 0,
                  opaqueItemFingerprints: [String] = []) {
        self.id = id
        self.kind = kind
        self.date = date
        self.expectedCount = expectedCount
        self.completedCount = completedCount
        self.opaqueItemFingerprints = opaqueItemFingerprints
    }
}

/// An opaque before/after representation supplied by the BetterMail
/// transaction integration. This type does not claim Core Data atomicity.
internal nonisolated struct OrganizationBetterMailDelta: Codable, Hashable, Sendable {
    internal let formatIdentifier: String
    internal let before: Data
    internal let after: Data

    internal init(formatIdentifier: String, before: Data, after: Data) {
        self.formatIdentifier = formatIdentifier
        self.before = before
        self.after = after
    }
}

internal nonisolated struct OrganizationAuthorizationReference: Codable, Hashable, Sendable {
    internal let authorizationID: String
    internal let consentSchemaVersion: Int
    internal let effect: OrganizationOperationEffect
    internal let issuedAt: Date
    internal let disclosureFingerprint: String

    internal init(authorizationID: String,
                  consentSchemaVersion: Int,
                  effect: OrganizationOperationEffect,
                  issuedAt: Date,
                  disclosureFingerprint: String) {
        self.authorizationID = authorizationID
        self.consentSchemaVersion = consentSchemaVersion
        self.effect = effect
        self.issuedAt = issuedAt
        self.disclosureFingerprint = disclosureFingerprint
    }
}

internal nonisolated struct OrganizationSpatialAnchorIntent: Codable, Hashable, Sendable {
    internal let intentID: String
    internal let opaqueScopeFingerprint: String
    internal let opaqueGroupFingerprint: String?
    internal let x: Double
    internal let y: Double
    internal let zoom: Double

    internal init(intentID: String = UUID().uuidString,
                  opaqueScopeFingerprint: String,
                  opaqueGroupFingerprint: String? = nil,
                  x: Double,
                  y: Double,
                  zoom: Double) {
        self.intentID = intentID
        self.opaqueScopeFingerprint = opaqueScopeFingerprint
        self.opaqueGroupFingerprint = opaqueGroupFingerprint
        self.x = x
        self.y = y
        self.zoom = zoom
    }
}

internal nonisolated struct OrganizationSpatialAnchorReceipt: Codable, Hashable, Sendable {
    internal let intentID: String
    internal let appliedAt: Date
    internal let opaqueStoreRevision: String

    internal init(intentID: String, appliedAt: Date, opaqueStoreRevision: String) {
        self.intentID = intentID
        self.appliedAt = appliedAt
        self.opaqueStoreRevision = opaqueStoreRevision
    }
}

/// AES-GCM envelope for the exact Mail route needed during recovery. The
/// nonce, ciphertext, and tag are all retained as bytes so key loss never
/// causes a replacement envelope or an accidental retry.
internal nonisolated struct OrganizationEncryptedMailRouteEnvelope: Codable, Hashable, Sendable {
    internal let algorithm: String
    internal let keyIdentifier: String
    internal let nonce: Data
    internal let ciphertext: Data
    internal let tag: Data
    internal let createdAt: Date

    internal init(algorithm: String = "AES.GCM",
                  keyIdentifier: String,
                  nonce: Data,
                  ciphertext: Data,
                  tag: Data,
                  createdAt: Date) {
        self.algorithm = algorithm
        self.keyIdentifier = keyIdentifier
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.createdAt = createdAt
    }
}

internal nonisolated struct OrganizationOperation: Identifiable, Codable, Hashable, Sendable {
    internal static let currentSchemaVersion = 1

    internal let id: String
    internal let kind: OrganizationOperationKind
    internal let opaqueSourceFingerprints: [String]
    internal let opaqueTargetFingerprints: [String]
    internal let betterMailDelta: OrganizationBetterMailDelta
    internal var mailRouteEnvelope: OrganizationEncryptedMailRouteEnvelope?
    internal let authorizationReference: OrganizationAuthorizationReference?
    internal let spatialAnchorIntent: OrganizationSpatialAnchorIntent?
    internal var spatialAnchorReceipt: OrganizationSpatialAnchorReceipt?
    internal var schemaVersion: Int
    internal var phase: OrganizationOperationPhase
    internal var retryCount: Int
    internal var lastFailure: OrganizationOperationFailure?
    internal var receipts: [OrganizationOperationReceipt]
    internal var phaseTimestamps: [OrganizationOperationPhaseTimestamp]
    internal let createdAt: Date
    internal var updatedAt: Date
    internal var routesRedactedAt: Date?

    internal init(id: String = UUID().uuidString,
                  kind: OrganizationOperationKind,
                  opaqueSourceFingerprints: [String],
                  opaqueTargetFingerprints: [String],
                  betterMailDelta: OrganizationBetterMailDelta,
                  mailRouteEnvelope: OrganizationEncryptedMailRouteEnvelope? = nil,
                  authorizationReference: OrganizationAuthorizationReference? = nil,
                  spatialAnchorIntent: OrganizationSpatialAnchorIntent? = nil,
                  spatialAnchorReceipt: OrganizationSpatialAnchorReceipt? = nil,
                  schemaVersion: Int = OrganizationOperation.currentSchemaVersion,
                  phase: OrganizationOperationPhase = .prepared,
                  retryCount: Int = 0,
                  lastFailure: OrganizationOperationFailure? = nil,
                  receipts: [OrganizationOperationReceipt] = [],
                  phaseTimestamps: [OrganizationOperationPhaseTimestamp]? = nil,
                  createdAt: Date,
                  updatedAt: Date? = nil,
                  routesRedactedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.opaqueSourceFingerprints = opaqueSourceFingerprints
        self.opaqueTargetFingerprints = opaqueTargetFingerprints
        self.betterMailDelta = betterMailDelta
        self.mailRouteEnvelope = mailRouteEnvelope
        self.authorizationReference = authorizationReference
        self.spatialAnchorIntent = spatialAnchorIntent
        self.spatialAnchorReceipt = spatialAnchorReceipt
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.retryCount = retryCount
        self.lastFailure = lastFailure
        self.receipts = receipts
        self.phaseTimestamps = phaseTimestamps ?? [OrganizationOperationPhaseTimestamp(phase: phase, date: createdAt)]
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.routesRedactedAt = routesRedactedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case opaqueSourceFingerprints
        case opaqueTargetFingerprints
        case betterMailDelta
        case mailRouteEnvelope
        case authorizationReference
        case spatialAnchorIntent
        case spatialAnchorReceipt
        case schemaVersion
        case phase
        case retryCount
        case lastFailure
        case receipts
        case phaseTimestamps
        case createdAt
        case updatedAt
        case routesRedactedAt
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        self.id = try container.decode(String.self, forKey: .id)
        self.kind = try container.decodeIfPresent(OrganizationOperationKind.self, forKey: .kind) ?? .manualGroup
        self.opaqueSourceFingerprints = try container.decodeIfPresent([String].self, forKey: .opaqueSourceFingerprints) ?? []
        self.opaqueTargetFingerprints = try container.decodeIfPresent([String].self, forKey: .opaqueTargetFingerprints) ?? []
        self.betterMailDelta = try container.decodeIfPresent(OrganizationBetterMailDelta.self, forKey: .betterMailDelta)
            ?? OrganizationBetterMailDelta(formatIdentifier: "legacy-opaque", before: Data(), after: Data())
        self.mailRouteEnvelope = try container.decodeIfPresent(OrganizationEncryptedMailRouteEnvelope.self, forKey: .mailRouteEnvelope)
        self.authorizationReference = try container.decodeIfPresent(OrganizationAuthorizationReference.self, forKey: .authorizationReference)
        self.spatialAnchorIntent = try container.decodeIfPresent(OrganizationSpatialAnchorIntent.self, forKey: .spatialAnchorIntent)
        self.spatialAnchorReceipt = try container.decodeIfPresent(OrganizationSpatialAnchorReceipt.self, forKey: .spatialAnchorReceipt)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        self.phase = try container.decodeIfPresent(OrganizationOperationPhase.self, forKey: .phase) ?? .prepared
        self.retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        self.lastFailure = try container.decodeIfPresent(OrganizationOperationFailure.self, forKey: .lastFailure)
        self.receipts = try container.decodeIfPresent([OrganizationOperationReceipt].self, forKey: .receipts) ?? []
        self.phaseTimestamps = try container.decodeIfPresent([OrganizationOperationPhaseTimestamp].self, forKey: .phaseTimestamps)
            ?? [OrganizationOperationPhaseTimestamp(phase: self.phase, date: createdAt)]
        self.createdAt = createdAt
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        self.routesRedactedAt = try container.decodeIfPresent(Date.self, forKey: .routesRedactedAt)
    }
}

internal nonisolated struct OrganizationOperationArchive: Codable, Hashable, Sendable {
    internal let schemaVersion: Int
    internal let operations: [OrganizationOperation]

    internal init(schemaVersion: Int = OrganizationOperation.currentSchemaVersion,
                  operations: [OrganizationOperation]) {
        self.schemaVersion = schemaVersion
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operations
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        self.operations = try container.decode([OrganizationOperation].self, forKey: .operations)
    }
}

internal nonisolated enum OrganizationOperationQuarantineReason: String, Codable, CaseIterable, Sendable {
    case corruptDocument
    case futureSchema
    case unsafeLegacyPayload
    case manual
}

internal nonisolated struct OrganizationOperationQuarantineRecord: Codable, Hashable, Sendable {
    internal let id: String
    internal let reason: OrganizationOperationQuarantineReason
    internal let createdAt: Date
    internal let byteCount: Int
    internal let operationID: String?
    internal let quarantineURL: String

    internal init(id: String = UUID().uuidString,
                  reason: OrganizationOperationQuarantineReason,
                  createdAt: Date,
                  byteCount: Int,
                  operationID: String?,
                  quarantineURL: String) {
        self.id = id
        self.reason = reason
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.operationID = operationID
        self.quarantineURL = quarantineURL
    }
}

internal nonisolated enum OrganizationRouteCryptoError: Error, Equatable, Sendable {
    case keyUnavailable(String)
    case invalidCiphertext
    case encryptionFailed
}

internal nonisolated protocol OrganizationRouteCryptoProviding: Sendable {
    func encrypt(_ plaintext: Data) throws -> OrganizationEncryptedMailRouteEnvelope
    func decrypt(_ envelope: OrganizationEncryptedMailRouteEnvelope) throws -> Data
}

/// The Keychain boundary is intentionally narrower than the crypto provider so
/// tests can prove that decryption never manufactures a replacement key.
internal nonisolated protocol OrganizationRouteKeyProviding: Sendable {
    func existingKey(identifier: String) throws -> Data?
    func loadOrCreateKey(identifier: String) throws -> Data
}

internal nonisolated enum OrganizationRouteKeyError: Error, Equatable, Sendable {
    case keychainStatus(Int32)
    case invalidStoredKey
    case randomGenerationFailed
}

/// A route-encryption key that is separate from the graph-spatial HMAC secret.
/// Its stable service/account names contain no mailbox or message data.
internal nonisolated struct KeychainOrganizationRouteKeyProvider: OrganizationRouteKeyProviding, Sendable {
    internal static let service = "com.bettermail.organization-route"
    internal static let defaultKeyIdentifier = "route-encryption-v1"
    private static let keyByteCount = 32

    internal init() {}

    internal func existingKey(identifier: String) throws -> Data? {
        var query = baseQuery(identifier: identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == Self.keyByteCount else {
                throw OrganizationRouteKeyError.invalidStoredKey
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw OrganizationRouteKeyError.keychainStatus(status)
        }
    }

    internal func loadOrCreateKey(identifier: String) throws -> Data {
        if let existing = try existingKey(identifier: identifier) {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: Self.keyByteCount)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw OrganizationRouteKeyError.randomGenerationFailed
        }
        let generated = Data(bytes)

        var addQuery = baseQuery(identifier: identifier)
        addQuery[kSecValueData as String] = generated
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem,
           let existing = try existingKey(identifier: identifier) {
            return existing
        }
        guard addStatus == errSecSuccess else {
            throw OrganizationRouteKeyError.keychainStatus(addStatus)
        }
        return generated
    }

    private func baseQuery(identifier: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: identifier
        ]
    }
}

/// Production route crypto. Encryption may create the per-install key, while
/// decryption only loads the key named by the envelope. If that key is missing,
/// ciphertext is preserved and recovery fails closed.
internal nonisolated struct KeychainOrganizationRouteCryptoProvider: OrganizationRouteCryptoProviding, Sendable {
    internal let keyIdentifier: String
    private let keyProvider: any OrganizationRouteKeyProviding

    internal init(keyIdentifier: String = KeychainOrganizationRouteKeyProvider.defaultKeyIdentifier,
                  keyProvider: any OrganizationRouteKeyProviding = KeychainOrganizationRouteKeyProvider()) {
        self.keyIdentifier = keyIdentifier
        self.keyProvider = keyProvider
    }

    internal func encrypt(_ plaintext: Data) throws -> OrganizationEncryptedMailRouteEnvelope {
        let keyData: Data
        do {
            keyData = try keyProvider.loadOrCreateKey(identifier: keyIdentifier)
        } catch {
            throw OrganizationRouteCryptoError.keyUnavailable(keyIdentifier)
        }
        return try Self.encrypt(plaintext,
                                keyData: keyData,
                                keyIdentifier: keyIdentifier,
                                createdAt: Date())
    }

    internal func decrypt(_ envelope: OrganizationEncryptedMailRouteEnvelope) throws -> Data {
        guard envelope.keyIdentifier == keyIdentifier else {
            throw OrganizationRouteCryptoError.keyUnavailable(envelope.keyIdentifier)
        }

        let keyData: Data
        do {
            guard let existing = try keyProvider.existingKey(identifier: envelope.keyIdentifier) else {
                throw OrganizationRouteCryptoError.keyUnavailable(envelope.keyIdentifier)
            }
            keyData = existing
        } catch let error as OrganizationRouteCryptoError {
            throw error
        } catch {
            throw OrganizationRouteCryptoError.keyUnavailable(envelope.keyIdentifier)
        }
        return try Self.decrypt(envelope, keyData: keyData)
    }

    private static func encrypt(_ plaintext: Data,
                                keyData: Data,
                                keyIdentifier: String,
                                createdAt: Date) throws -> OrganizationEncryptedMailRouteEnvelope {
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
            return OrganizationEncryptedMailRouteEnvelope(keyIdentifier: keyIdentifier,
                                                           nonce: Data(sealedBox.nonce),
                                                           ciphertext: sealedBox.ciphertext,
                                                           tag: sealedBox.tag,
                                                           createdAt: createdAt)
        } catch {
            throw OrganizationRouteCryptoError.encryptionFailed
        }
    }

    private static func decrypt(_ envelope: OrganizationEncryptedMailRouteEnvelope,
                                keyData: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: envelope.ciphertext,
                tag: envelope.tag
            )
            return try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
        } catch {
            throw OrganizationRouteCryptoError.invalidCiphertext
        }
    }
}

/// A CryptoKit seam that can later be backed by a Keychain/key-management
/// provider. A missing key is deliberate fail-closed behavior.
internal nonisolated struct CryptoKitOrganizationRouteCryptoProvider: OrganizationRouteCryptoProviding, Sendable {
    internal let keyIdentifier: String
    internal let keyData: Data?
    internal let now: Date

    internal init(keyIdentifier: String, keyData: Data?, now: Date = Date()) {
        self.keyIdentifier = keyIdentifier
        self.keyData = keyData
        self.now = now
    }

    internal func encrypt(_ plaintext: Data) throws -> OrganizationEncryptedMailRouteEnvelope {
        guard let keyData, !keyData.isEmpty else {
            throw OrganizationRouteCryptoError.keyUnavailable(keyIdentifier)
        }

        do {
            let key = SymmetricKey(data: keyData)
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            return OrganizationEncryptedMailRouteEnvelope(keyIdentifier: keyIdentifier,
                                                           nonce: Data(sealedBox.nonce),
                                                           ciphertext: sealedBox.ciphertext,
                                                           tag: sealedBox.tag,
                                                           createdAt: now)
        } catch {
            throw OrganizationRouteCryptoError.encryptionFailed
        }
    }

    internal func decrypt(_ envelope: OrganizationEncryptedMailRouteEnvelope) throws -> Data {
        guard envelope.keyIdentifier == keyIdentifier,
              let keyData,
              !keyData.isEmpty else {
            throw OrganizationRouteCryptoError.keyUnavailable(envelope.keyIdentifier)
        }

        do {
            let key = SymmetricKey(data: keyData)
            let nonce = try AES.GCM.Nonce(data: envelope.nonce)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce,
                                                  ciphertext: envelope.ciphertext,
                                                  tag: envelope.tag)
            return try AES.GCM.open(sealedBox, using: key)
        } catch let error as OrganizationRouteCryptoError {
            throw error
        } catch {
            throw OrganizationRouteCryptoError.invalidCiphertext
        }
    }
}

internal nonisolated enum OrganizationOperationStoreError: Error, Equatable, Sendable {
    case operationNotFound
    case duplicateOperation
    case invalidOperation(String)
    case invalidTransition(from: OrganizationOperationPhase, to: OrganizationOperationPhase)
    case fileReadFailed
    case fileWriteFailed
    case recoveryKeyUnavailable
    case routeEncryptionFailed
    case routeDecryptionFailed
    case routeUnavailable
    case routeRedacted
    case quarantineFailed
}
