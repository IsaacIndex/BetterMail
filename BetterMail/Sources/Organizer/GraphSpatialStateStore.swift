import CryptoKit
import Foundation
import Security

/// The small external boundary used by `GraphSpatialStateStore` to read and
/// atomically replace its Application Support file.
internal nonisolated protocol GraphSpatialFileAccessing: Sendable {
    func read() throws -> Data
    func writeAtomically(_ data: Data) throws
}

/// A Keychain-backed secret is deliberately abstracted so persistence tests do
/// not need to touch the user's Keychain.
internal nonisolated protocol GraphSpatialSecretProviding: Sendable {
    func loadOrCreateSecret() throws -> Data
}

internal nonisolated enum GraphSpatialFileAccessError: Error, Equatable, Sendable {
    case notFound
}

internal nonisolated enum GraphSpatialSecretError: Error, Equatable, Sendable {
    case keychainStatus(Int32)
    case invalidStoredSecret
    case randomGenerationFailed
}

internal nonisolated enum GraphSpatialStateStoreError: Error, Equatable, Sendable {
    case invalidScopeID
    case unsupportedSchemaVersion(Int)
    case encodingFailed
    case writeFailed
}

internal nonisolated enum GraphSpatialStoreStatus: Equatable, Sendable {
    case uninitialized
    case ready
    case missing
    case corrupt
    case futureVersion(Int)
    case secretUnavailable
}

/// A platform-neutral, Codable position used by the durable store. Keeping
/// this as doubles avoids encoding platform-specific `CGPoint` details.
internal nonisolated struct GraphSpatialPoint: Codable, Equatable, Hashable, Sendable {
    internal let x: Double
    internal let y: Double

    internal init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    nonisolated internal static let zero = GraphSpatialPoint(x: 0, y: 0)

    internal var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

/// The in-memory/raw-identifier view used by the graph presenter. Raw IDs are
/// translated to opaque HMAC tokens before this value reaches disk.
internal nonisolated struct GraphSpatialSnapshot: Equatable, Sendable {
    internal var nodePositions: [String: GraphSpatialPoint]
    internal var confirmedGroupAnchors: [String: GraphSpatialPoint]
    internal var zoomScale: Double
    internal var panOffset: GraphSpatialPoint
    internal var updatedAt: Date

    internal init(nodePositions: [String: GraphSpatialPoint] = [:],
                  confirmedGroupAnchors: [String: GraphSpatialPoint] = [:],
                  zoomScale: Double = 1,
                  panOffset: GraphSpatialPoint = .zero,
                  updatedAt: Date = Date()) {
        self.nodePositions = nodePositions
        self.confirmedGroupAnchors = confirmedGroupAnchors
        self.zoomScale = zoomScale
        self.panOffset = panOffset
        self.updatedAt = updatedAt
    }

    nonisolated internal static let empty = GraphSpatialSnapshot()
}

/// The only values written to the spatial file. Scope and Group/node
/// identifiers in this model are opaque HMAC tokens, never application IDs.
internal nonisolated struct GraphSpatialPersistedDocument: Codable, Equatable, Sendable {
    nonisolated internal static let currentSchemaVersion = 1

    internal var schemaVersion: Int
    internal var scopes: [String: GraphSpatialPersistedScope]

    internal init(schemaVersion: Int = GraphSpatialPersistedDocument.currentSchemaVersion,
                  scopes: [String: GraphSpatialPersistedScope] = [:]) {
        self.schemaVersion = schemaVersion
        self.scopes = scopes
    }
}

internal nonisolated struct GraphSpatialPersistedScope: Codable, Equatable, Sendable {
    internal var schemaVersion: Int
    internal var nodePositions: [String: GraphSpatialPoint]
    internal var confirmedGroupAnchors: [String: GraphSpatialPoint]
    internal var zoomScale: Double
    internal var panOffset: GraphSpatialPoint
    internal var updatedAt: Date

    internal init(schemaVersion: Int = GraphSpatialPersistedDocument.currentSchemaVersion,
                  nodePositions: [String: GraphSpatialPoint],
                  confirmedGroupAnchors: [String: GraphSpatialPoint],
                  zoomScale: Double,
                  panOffset: GraphSpatialPoint,
                  updatedAt: Date) {
        self.schemaVersion = schemaVersion
        self.nodePositions = nodePositions
        self.confirmedGroupAnchors = confirmedGroupAnchors
        self.zoomScale = zoomScale
        self.panOffset = panOffset
        self.updatedAt = updatedAt
    }
}

/// Derives stable, per-install opaque IDs. HMAC makes the values stable for
/// the installation while preventing a persisted file from exposing the raw
/// scope, node, or Group identifiers.
internal nonisolated enum GraphSpatialOpaqueToken {
    nonisolated internal static let tokenVersion = "gsp-v1"

    internal static func scopeToken(for scopeID: String, secret: Data) -> String {
        derive(kind: "scope", rawID: scopeID, secret: secret)
    }

    internal static func nodeToken(for nodeID: String, secret: Data) -> String {
        derive(kind: "node", rawID: nodeID, secret: secret)
    }

    internal static func groupToken(for groupID: String, secret: Data) -> String {
        derive(kind: "group", rawID: groupID, secret: secret)
    }

    internal static func isVirtualRemainingNodeID(_ nodeID: String) -> Bool {
        nodeID.hasPrefix("remaining:")
    }

    internal static func shouldPersistNodeID(_ nodeID: String) -> Bool {
        !nodeID.isEmpty && !isVirtualRemainingNodeID(nodeID)
    }

    private static func derive(kind: String, rawID: String, secret: Data) -> String {
        guard !rawID.isEmpty, !secret.isEmpty else { return "" }
        let message = Data("\(tokenVersion)|\(kind)|\(rawID)".utf8)
        let key = SymmetricKey(data: secret)
        let digest = HMAC<SHA256>.authenticationCode(for: message, using: key)
        let encoded = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(tokenVersion)-\(encoded)"
    }
}

/// The production file boundary. Its URL is rooted in Application Support,
/// and each write uses Foundation's atomic replacement option.
internal nonisolated struct ApplicationSupportGraphSpatialFileAccessor: GraphSpatialFileAccessing {
    internal let fileURL: URL

    internal init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.fileURL = applicationSupport
            .appendingPathComponent("BetterMail", isDirectory: true)
            .appendingPathComponent("GraphSpatialState.json", isDirectory: false)
    }

    internal func read() throws -> Data {
        do {
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            throw GraphSpatialFileAccessError.notFound
        }
    }

    internal func writeAtomically(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// A per-install secret held in the user's Keychain. The stable service and
/// account names contain no mailbox, message, or other user identifiers.
internal nonisolated struct KeychainGraphSpatialSecretProvider: GraphSpatialSecretProviding {
    nonisolated internal static let service = "com.bettermail.graph-spatial"
    nonisolated internal static let account = "installation-secret-v1"
    private nonisolated static let secretByteCount = 32

    internal init() {}

    internal func loadOrCreateSecret() throws -> Data {
        if let existing = try existingSecret() {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: Self.secretByteCount)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw GraphSpatialSecretError.randomGenerationFailed
        }
        let generated = Data(bytes)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = generated
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            if let existing = try existingSecret() {
                return existing
            }
        }
        guard addStatus == errSecSuccess else {
            throw GraphSpatialSecretError.keychainStatus(addStatus)
        }
        return generated
    }

    private func existingSecret() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                throw GraphSpatialSecretError.invalidStoredSecret
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw GraphSpatialSecretError.keychainStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }
}

/// Serialized access to all graph spatial state. Reads are deliberately
/// fail-safe: an unavailable secret, missing file, malformed file, or future
/// schema returns the empty seeded-layout snapshot. Writes remain explicit and
/// throw on an atomic file failure so callers can surface/recover the error.
internal actor GraphSpatialStateStore {
    private let fileAccessor: any GraphSpatialFileAccessing
    private let secretProvider: any GraphSpatialSecretProviding
    private var document = GraphSpatialPersistedDocument()
    private var hasLoadedDocument = false
    private var canPersist = true
    private var secret: Data?
    private var hasResolvedSecret = false
    private var currentStatus: GraphSpatialStoreStatus = .uninitialized

    internal init(fileAccessor: any GraphSpatialFileAccessing = ApplicationSupportGraphSpatialFileAccessor(),
                  secretProvider: any GraphSpatialSecretProviding = KeychainGraphSpatialSecretProvider()) {
        self.fileAccessor = fileAccessor
        self.secretProvider = secretProvider
    }

    /// Loads only source IDs supplied by the caller. The caller should pass
    /// the complete stable source inventory (not merely currently visible
    /// paged nodes) when it needs hidden positions retained.
    internal func load(scopeID: String,
                       sourceNodeIDs: Set<String> = [],
                       confirmedGroupIDs: Set<String> = []) -> GraphSpatialSnapshot {
        ensureLoaded()
        guard let secret, let scopeToken = validScopeToken(scopeID, secret: secret),
              let persistedScope = document.scopes[scopeToken] else {
            return .empty
        }

        let nodePositions = sourceNodeIDs.reduce(into: [String: GraphSpatialPoint]()) { result, nodeID in
            guard GraphSpatialOpaqueToken.shouldPersistNodeID(nodeID) else { return }
            let token = GraphSpatialOpaqueToken.nodeToken(for: nodeID, secret: secret)
            if let point = persistedScope.nodePositions[token] {
                result[nodeID] = point
            }
        }
        let confirmedGroupAnchors = confirmedGroupIDs.reduce(into: [String: GraphSpatialPoint]()) { result, groupID in
            let token = GraphSpatialOpaqueToken.groupToken(for: groupID, secret: secret)
            if let point = persistedScope.confirmedGroupAnchors[token] {
                result[groupID] = point
            }
        }
        return GraphSpatialSnapshot(nodePositions: nodePositions,
                                    confirmedGroupAnchors: confirmedGroupAnchors,
                                    zoomScale: persistedScope.zoomScale,
                                    panOffset: persistedScope.panOffset,
                                    updatedAt: persistedScope.updatedAt)
    }

    /// Saves raw in-memory IDs only after translating them into opaque tokens.
    /// Virtual remainder IDs are intentionally excluded.
    internal func save(_ snapshot: GraphSpatialSnapshot, forScopeID scopeID: String) throws {
        guard !scopeID.isEmpty else { throw GraphSpatialStateStoreError.invalidScopeID }
        ensureLoaded()
        guard let secret, let scopeToken = validScopeToken(scopeID, secret: secret) else {
            return
        }
        guard canPersist else {
            if case .futureVersion(let version) = currentStatus {
                throw GraphSpatialStateStoreError.unsupportedSchemaVersion(version)
            }
            return
        }

        let persistedScope = makePersistedScope(from: snapshot, secret: secret)
        var candidate = document
        candidate.scopes[scopeToken] = persistedScope
        try persist(candidate)
    }

    /// Clears only the selected mailbox scope. Other scope entries remain in
    /// the same atomic document.
    internal func resetActiveScope(scopeID: String) throws {
        guard !scopeID.isEmpty else { throw GraphSpatialStateStoreError.invalidScopeID }
        ensureLoaded()
        guard let secret, let scopeToken = validScopeToken(scopeID, secret: secret) else {
            return
        }
        guard document.scopes[scopeToken] != nil else { return }
        guard canPersist else {
            if case .futureVersion(let version) = currentStatus {
                throw GraphSpatialStateStoreError.unsupportedSchemaVersion(version)
            }
            return
        }

        var candidate = document
        candidate.scopes.removeValue(forKey: scopeToken)
        try persist(candidate)
    }

    internal func reset(scopeID: String) throws {
        try resetActiveScope(scopeID: scopeID)
    }

    /// Removes only IDs absent from the complete source inventories supplied
    /// by the caller. Passing a visible page instead of the complete source
    /// set would intentionally prune hidden IDs, so callers must use their
    /// source/root inventory here.
    internal func prune(scopeID: String,
                        sourceNodeIDs: Set<String>,
                        confirmedGroupIDs: Set<String>) throws {
        guard !scopeID.isEmpty else { throw GraphSpatialStateStoreError.invalidScopeID }
        ensureLoaded()
        guard let secret, let scopeToken = validScopeToken(scopeID, secret: secret),
              let existingScope = document.scopes[scopeToken] else {
            return
        }
        guard canPersist else {
            if case .futureVersion(let version) = currentStatus {
                throw GraphSpatialStateStoreError.unsupportedSchemaVersion(version)
            }
            return
        }

        let validNodeTokens = Set(sourceNodeIDs.compactMap { nodeID -> String? in
            guard GraphSpatialOpaqueToken.shouldPersistNodeID(nodeID) else { return nil }
            let token = GraphSpatialOpaqueToken.nodeToken(for: nodeID, secret: secret)
            return token.isEmpty ? nil : token
        })
        let validGroupTokens = Set(confirmedGroupIDs.compactMap { groupID -> String? in
            let token = GraphSpatialOpaqueToken.groupToken(for: groupID, secret: secret)
            return token.isEmpty ? nil : token
        })

        var prunedScope = existingScope
        prunedScope.nodePositions = existingScope.nodePositions.filter { validNodeTokens.contains($0.key) }
        prunedScope.confirmedGroupAnchors = existingScope.confirmedGroupAnchors.filter {
            validGroupTokens.contains($0.key)
        }
        guard prunedScope != existingScope else { return }

        var candidate = document
        candidate.scopes[scopeToken] = prunedScope
        try persist(candidate)
    }

    internal func persistenceStatus() -> GraphSpatialStoreStatus {
        currentStatus
    }

    private func ensureLoaded() {
        guard !hasLoadedDocument else { return }
        hasLoadedDocument = true

        guard resolvedSecret() != nil else {
            canPersist = false
            currentStatus = .secretUnavailable
            return
        }

        do {
            let data = try fileAccessor.read()
            let decoded = try decodeDocument(data)
            guard decoded.schemaVersion == GraphSpatialPersistedDocument.currentSchemaVersion else {
                document = GraphSpatialPersistedDocument()
                canPersist = false
                currentStatus = decoded.schemaVersion > GraphSpatialPersistedDocument.currentSchemaVersion
                    ? .futureVersion(decoded.schemaVersion)
                    : .corrupt
                return
            }

            var usableScopes: [String: GraphSpatialPersistedScope] = [:]
            var futureVersion: Int?
            for (scopeToken, scope) in decoded.scopes {
                if scope.schemaVersion == GraphSpatialPersistedDocument.currentSchemaVersion {
                    usableScopes[scopeToken] = scope
                } else if scope.schemaVersion > GraphSpatialPersistedDocument.currentSchemaVersion {
                    futureVersion = max(futureVersion ?? scope.schemaVersion, scope.schemaVersion)
                }
            }
            document = GraphSpatialPersistedDocument(schemaVersion: decoded.schemaVersion,
                                                     scopes: usableScopes)
            if let futureVersion {
                canPersist = false
                currentStatus = .futureVersion(futureVersion)
            } else {
                currentStatus = .ready
            }
        } catch GraphSpatialFileAccessError.notFound {
            document = GraphSpatialPersistedDocument()
            currentStatus = .missing
        } catch {
            document = GraphSpatialPersistedDocument()
            currentStatus = .corrupt
        }
    }

    private func resolvedSecret() -> Data? {
        guard !hasResolvedSecret else { return secret }
        hasResolvedSecret = true
        do {
            let candidate = try secretProvider.loadOrCreateSecret()
            guard !candidate.isEmpty else {
                throw GraphSpatialSecretError.invalidStoredSecret
            }
            secret = candidate
            return candidate
        } catch {
            secret = nil
            return nil
        }
    }

    private func validScopeToken(_ scopeID: String, secret: Data) -> String? {
        let token = GraphSpatialOpaqueToken.scopeToken(for: scopeID, secret: secret)
        return token.isEmpty ? nil : token
    }

    private func makePersistedScope(from snapshot: GraphSpatialSnapshot,
                                    secret: Data) -> GraphSpatialPersistedScope {
        var nodePositions: [String: GraphSpatialPoint] = [:]
        for (nodeID, point) in snapshot.nodePositions {
            guard GraphSpatialOpaqueToken.shouldPersistNodeID(nodeID),
                  point.isFinite else { continue }
            let token = GraphSpatialOpaqueToken.nodeToken(for: nodeID, secret: secret)
            guard !token.isEmpty else { continue }
            nodePositions[token] = point
        }

        var confirmedGroupAnchors: [String: GraphSpatialPoint] = [:]
        for (groupID, point) in snapshot.confirmedGroupAnchors {
            guard point.isFinite else { continue }
            let token = GraphSpatialOpaqueToken.groupToken(for: groupID, secret: secret)
            guard !token.isEmpty else { continue }
            confirmedGroupAnchors[token] = point
        }

        let zoomScale = snapshot.zoomScale.isFinite && snapshot.zoomScale > 0
            ? snapshot.zoomScale
            : 1
        let panOffset = snapshot.panOffset.isFinite ? snapshot.panOffset : .zero
        let updatedAt = snapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite
            ? snapshot.updatedAt
            : Date(timeIntervalSinceReferenceDate: 0)
        return GraphSpatialPersistedScope(nodePositions: nodePositions,
                                          confirmedGroupAnchors: confirmedGroupAnchors,
                                          zoomScale: zoomScale,
                                          panOffset: panOffset,
                                          updatedAt: updatedAt)
    }

    private func persist(_ candidate: GraphSpatialPersistedDocument) throws {
        guard canPersist else {
            if case .futureVersion(let version) = currentStatus {
                throw GraphSpatialStateStoreError.unsupportedSchemaVersion(version)
            }
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(candidate)
            try fileAccessor.writeAtomically(data)
        } catch is EncodingError {
            throw GraphSpatialStateStoreError.encodingFailed
        } catch {
            throw GraphSpatialStateStoreError.writeFailed
        }
        document = candidate
        currentStatus = .ready
    }

    private func decodeDocument(_ data: Data) throws -> GraphSpatialPersistedDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(GraphSpatialPersistedDocument.self, from: data)
    }
}
