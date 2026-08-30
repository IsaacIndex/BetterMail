import Foundation
import XCTest
@testable import BetterMail

@MainActor
final class GraphSpatialStateStoreTests: XCTestCase {
    func test_saveAndLoad_roundTripsRawProjectionThroughOpaqueFileValues() async throws {
        let accessor = TestGraphSpatialFileAccessor()
        let store = GraphSpatialStateStore(fileAccessor: accessor,
                                            secretProvider: FixedGraphSpatialSecretProvider())
        let timestamp = Date(timeIntervalSinceReferenceDate: 12_345)
        let snapshot = GraphSpatialSnapshot(
            nodePositions: [
                "thread-1": GraphSpatialPoint(x: 12.5, y: -8),
                "message-1": GraphSpatialPoint(x: -4, y: 31)
            ],
            confirmedGroupAnchors: [
                "group-1": GraphSpatialPoint(x: 88, y: 144)
            ],
            zoomScale: 1.75,
            panOffset: GraphSpatialPoint(x: -20, y: 42),
            updatedAt: timestamp
        )

        try await store.save(snapshot, forScopeID: "mailbox:work|inbox")
        let restored = await store.load(scopeID: "mailbox:work|inbox",
                                        sourceNodeIDs: ["thread-1", "message-1"],
                                        confirmedGroupIDs: ["group-1"])

        XCTAssertEqual(restored, snapshot)
        let status = await store.persistenceStatus()
        XCTAssertEqual(status, .ready)
        XCTAssertNotNil(accessor.data)
        let serialized = String(data: accessor.data!, encoding: .utf8)!
        for rawIdentifier in ["mailbox:work|inbox", "thread-1", "message-1", "group-1"] {
            XCTAssertFalse(serialized.contains(rawIdentifier), "Raw identifier leaked: \(rawIdentifier)")
        }
    }

    func test_saveAndLoad_scopesRemainIsolated() async throws {
        let accessor = TestGraphSpatialFileAccessor()
        let store = GraphSpatialStateStore(fileAccessor: accessor,
                                            secretProvider: FixedGraphSpatialSecretProvider())
        let work = GraphSpatialSnapshot(nodePositions: ["thread-work": GraphSpatialPoint(x: 1, y: 2)],
                                        zoomScale: 1.2,
                                        updatedAt: Date(timeIntervalSinceReferenceDate: 1))
        let personal = GraphSpatialSnapshot(nodePositions: ["thread-personal": GraphSpatialPoint(x: 3, y: 4)],
                                            zoomScale: 2.4,
                                            updatedAt: Date(timeIntervalSinceReferenceDate: 2))

        try await store.save(work, forScopeID: "scope-work")
        try await store.save(personal, forScopeID: "scope-personal")

        let restoredWork = await store.load(scopeID: "scope-work", sourceNodeIDs: ["thread-work", "thread-personal"])
        let restoredPersonal = await store.load(scopeID: "scope-personal", sourceNodeIDs: ["thread-work", "thread-personal"])

        XCTAssertEqual(restoredWork.nodePositions, work.nodePositions)
        XCTAssertEqual(restoredWork.zoomScale, work.zoomScale)
        XCTAssertEqual(restoredPersonal.nodePositions, personal.nodePositions)
        XCTAssertEqual(restoredPersonal.zoomScale, personal.zoomScale)
    }

    func test_opaqueTokenDerivation_isStableAndDomainSeparated() {
        let secret = Data(repeating: 0x42, count: 32)
        let scopeToken = GraphSpatialOpaqueToken.scopeToken(for: "scope-a", secret: secret)
        let repeatedScopeToken = GraphSpatialOpaqueToken.scopeToken(for: "scope-a", secret: secret)
        let nodeToken = GraphSpatialOpaqueToken.nodeToken(for: "scope-a", secret: secret)
        let groupToken = GraphSpatialOpaqueToken.groupToken(for: "scope-a", secret: secret)

        XCTAssertEqual(scopeToken, repeatedScopeToken)
        XCTAssertNotEqual(scopeToken, nodeToken)
        XCTAssertNotEqual(nodeToken, groupToken)
        XCTAssertFalse(scopeToken.contains("scope-a"))
        XCTAssertFalse(GraphSpatialOpaqueToken.isVirtualRemainingNodeID("thread-1"))
        XCTAssertTrue(GraphSpatialOpaqueToken.isVirtualRemainingNodeID("remaining:thread-1"))
        XCTAssertTrue(GraphSpatialOpaqueToken.shouldPersistNodeID("thread-1"))
        XCTAssertFalse(GraphSpatialOpaqueToken.shouldPersistNodeID("remaining:thread-1"))
    }

    func test_prune_retainsCompleteSourceInventoryAndResetClearsOnlyActiveScope() async throws {
        let accessor = TestGraphSpatialFileAccessor()
        let store = GraphSpatialStateStore(fileAccessor: accessor,
                                            secretProvider: FixedGraphSpatialSecretProvider())
        let snapshot = GraphSpatialSnapshot(
            nodePositions: [
                "thread-live": GraphSpatialPoint(x: 1, y: 1),
                "thread-hidden": GraphSpatialPoint(x: 2, y: 2),
                "thread-stale": GraphSpatialPoint(x: 3, y: 3),
                "remaining:thread-virtual": GraphSpatialPoint(x: 4, y: 4)
            ],
            confirmedGroupAnchors: [
                "group-live": GraphSpatialPoint(x: 5, y: 5),
                "group-stale": GraphSpatialPoint(x: 6, y: 6)
            ],
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let otherScope = GraphSpatialSnapshot(nodePositions: ["thread-other": GraphSpatialPoint(x: 7, y: 7)],
                                              updatedAt: Date(timeIntervalSinceReferenceDate: 101))

        try await store.save(snapshot, forScopeID: "scope-a")
        try await store.save(otherScope, forScopeID: "scope-b")
        try await store.prune(scopeID: "scope-a",
                              sourceNodeIDs: ["thread-live", "thread-hidden", "remaining:thread-virtual"],
                              confirmedGroupIDs: ["group-live"])

        let pruned = await store.load(scopeID: "scope-a",
                                      sourceNodeIDs: ["thread-live", "thread-hidden", "thread-stale", "remaining:thread-virtual"],
                                      confirmedGroupIDs: ["group-live", "group-stale"])
        XCTAssertEqual(pruned.nodePositions["thread-live"], GraphSpatialPoint(x: 1, y: 1))
        XCTAssertEqual(pruned.nodePositions["thread-hidden"], GraphSpatialPoint(x: 2, y: 2))
        XCTAssertNil(pruned.nodePositions["thread-stale"])
        XCTAssertNil(pruned.nodePositions["remaining:thread-virtual"])
        XCTAssertEqual(pruned.confirmedGroupAnchors["group-live"], GraphSpatialPoint(x: 5, y: 5))
        XCTAssertNil(pruned.confirmedGroupAnchors["group-stale"])

        try await store.resetActiveScope(scopeID: "scope-a")
        let resetScope = await store.load(scopeID: "scope-a",
                                          sourceNodeIDs: ["thread-live", "thread-hidden"])
        let otherScopeRestored = await store.load(scopeID: "scope-b", sourceNodeIDs: ["thread-other"])
        XCTAssertEqual(resetScope.nodePositions, [:])
        XCTAssertEqual(otherScopeRestored.nodePositions, otherScope.nodePositions)
    }

    func test_load_missingFile_fallsBackToSeededSnapshot() async {
        let store = GraphSpatialStateStore(fileAccessor: TestGraphSpatialFileAccessor(),
                                           secretProvider: FixedGraphSpatialSecretProvider())

        let snapshot = await store.load(scopeID: "scope-a", sourceNodeIDs: ["thread-a"])

        XCTAssertEqual(snapshot, .empty)
        let status = await store.persistenceStatus()
        XCTAssertEqual(status, .missing)
    }

    func test_load_corruptFile_fallsBackWithoutWriting() async {
        let accessor = TestGraphSpatialFileAccessor()
        accessor.data = Data("not-json".utf8)
        let store = GraphSpatialStateStore(fileAccessor: accessor,
                                           secretProvider: FixedGraphSpatialSecretProvider())

        let snapshot = await store.load(scopeID: "scope-a", sourceNodeIDs: ["thread-a"])

        XCTAssertEqual(snapshot, .empty)
        let status = await store.persistenceStatus()
        XCTAssertEqual(status, .corrupt)
        XCTAssertEqual(accessor.writeCount, 0)
    }

    func test_loadFutureVersion_fallsBackAndRefusesDestructiveOverwrite() async throws {
        let accessor = TestGraphSpatialFileAccessor()
        let future = GraphSpatialPersistedDocument(schemaVersion: GraphSpatialPersistedDocument.currentSchemaVersion + 1)
        let encoder = JSONEncoder()
        accessor.data = try encoder.encode(future)
        let store = GraphSpatialStateStore(fileAccessor: accessor,
                                           secretProvider: FixedGraphSpatialSecretProvider())

        let fallback = await store.load(scopeID: "scope-a")
        let status = await store.persistenceStatus()
        XCTAssertEqual(fallback, .empty)
        XCTAssertEqual(status, .futureVersion(2))
        do {
            try await store.save(GraphSpatialSnapshot(nodePositions: ["thread-a": GraphSpatialPoint(x: 1, y: 1)]),
                                 forScopeID: "scope-a")
            XCTFail("A future-version file must not be overwritten")
        } catch let error as GraphSpatialStateStoreError {
            XCTAssertEqual(error, .unsupportedSchemaVersion(2))
        }
        XCTAssertEqual(accessor.writeCount, 0)
    }

    func test_secretLoss_fallsBackWithoutReadingOrWritingRawIdentifiers() async throws {
        let accessor = TestGraphSpatialFileAccessor()
        let writer = GraphSpatialStateStore(fileAccessor: accessor,
                                             secretProvider: FixedGraphSpatialSecretProvider())
        try await writer.save(GraphSpatialSnapshot(nodePositions: ["thread-secret": GraphSpatialPoint(x: 2, y: 3)]),
                              forScopeID: "scope-secret")
        let writeCountBeforeLoss = accessor.writeCount

        let reader = GraphSpatialStateStore(fileAccessor: accessor,
                                             secretProvider: FailingGraphSpatialSecretProvider())
        let fallback = await reader.load(scopeID: "scope-secret", sourceNodeIDs: ["thread-secret"])

        XCTAssertEqual(fallback, .empty)
        let status = await reader.persistenceStatus()
        XCTAssertEqual(status, .secretUnavailable)
        XCTAssertEqual(accessor.writeCount, writeCountBeforeLoss)
    }

    func test_save_atomicWriteFailure_keepsPreviousInMemoryDocument() async throws {
        let accessor = TestGraphSpatialFileAccessor()
        accessor.writeError = TestGraphSpatialFileError.writeFailed
        let store = GraphSpatialStateStore(fileAccessor: accessor,
                                           secretProvider: FixedGraphSpatialSecretProvider())

        do {
            try await store.save(GraphSpatialSnapshot(nodePositions: ["thread-failed": GraphSpatialPoint(x: 1, y: 1)]),
                                 forScopeID: "scope-failed")
            XCTFail("Expected the injected atomic write failure")
        } catch let error as GraphSpatialStateStoreError {
            XCTAssertEqual(error, .writeFailed)
        }

        accessor.writeError = nil
        let afterFailure = await store.load(scopeID: "scope-failed", sourceNodeIDs: ["thread-failed"])
        XCTAssertEqual(afterFailure, .empty)
        try await store.save(GraphSpatialSnapshot(nodePositions: ["thread-failed": GraphSpatialPoint(x: 9, y: 9)]),
                             forScopeID: "scope-failed")
        let restored = await store.load(scopeID: "scope-failed", sourceNodeIDs: ["thread-failed"])
        XCTAssertEqual(restored.nodePositions["thread-failed"], GraphSpatialPoint(x: 9, y: 9))
    }
}

private struct FixedGraphSpatialSecretProvider: GraphSpatialSecretProviding {
    let secret = Data(repeating: 0x42, count: 32)

    func loadOrCreateSecret() throws -> Data {
        secret
    }
}

private struct FailingGraphSpatialSecretProvider: GraphSpatialSecretProviding {
    func loadOrCreateSecret() throws -> Data {
        throw GraphSpatialSecretError.keychainStatus(-50)
    }
}

private enum TestGraphSpatialFileError: Error {
    case writeFailed
}

private final class TestGraphSpatialFileAccessor: GraphSpatialFileAccessing, @unchecked Sendable {
    var data: Data?
    var writeError: Error?
    private(set) var writeCount = 0

    func read() throws -> Data {
        guard let data else { throw GraphSpatialFileAccessError.notFound }
        return data
    }

    func writeAtomically(_ data: Data) throws {
        if let writeError { throw writeError }
        writeCount += 1
        self.data = data
    }
}
