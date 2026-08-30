import XCTest
@testable import BetterMail

@MainActor
final class OrganizationHistoryCoordinatorTests: XCTestCase {
    func testProjection_coversEveryLedgerKindWithSafeUndoAndRecoveryMetadata() {
        let date = Date(timeIntervalSince1970: 100)
        let expectedEffects: [OrganizationOperationKind: OrganizationOperationEffect] = [
            .manualGroup: .betterMailOnly,
            .manualUngroup: .betterMailOnly,
            .suggestionAcceptance: .betterMailOnly,
            .graphArchive: .betterMailOnly,
            .snip: .messageMove,
            .mailMove: .messageMove,
            .mailboxCreation: .mailboxCreation,
            .automation: .mixed,
            .retry: .restore,
            .recovery: .restore,
            .undo: .restore
        ]
        let routeEnvelope = OrganizationEncryptedMailRouteEnvelope(
            keyIdentifier: "test-key",
            nonce: Data([1]),
            ciphertext: Data([2]),
            tag: Data([3]),
            createdAt: date
        )
        let operations = OrganizationOperationKind.allCases.enumerated().map { index, kind in
            let effect = expectedEffects[kind] ?? .betterMailOnly
            let hasMailEffect = effect != .betterMailOnly
            return OrganizationOperation(
                id: "ledger-\(kind.rawValue)",
                kind: kind,
                opaqueSourceFingerprints: ["opaque-\(index)"],
                opaqueTargetFingerprints: ["opaque-target"],
                betterMailDelta: OrganizationBetterMailDelta(
                    formatIdentifier: "test",
                    before: Data(),
                    after: Data([1])
                ),
                mailRouteEnvelope: hasMailEffect ? routeEnvelope : nil,
                authorizationReference: hasMailEffect
                    ? OrganizationAuthorizationReference(
                        authorizationID: "opaque-auth-\(index)",
                        consentSchemaVersion: 1,
                        effect: effect,
                        issuedAt: date,
                        disclosureFingerprint: "opaque-disclosure-\(index)"
                    )
                    : nil,
                phase: kind == .recovery ? .recovery : .completed,
                retryCount: kind == .recovery ? 1 : 0,
                createdAt: date.addingTimeInterval(Double(index))
            )
        }

        let items = OrganizationHistoryProjection.make(operations: operations,
                                                       legacyCompost: [],
                                                       legacyAutomation: [])

        XCTAssertEqual(Set(items.map(\.kind)), Set(OrganizationOperationKind.allCases))
        for item in items {
            XCTAssertEqual(item.effect, expectedEffects[item.kind])
        }
        XCTAssertEqual(items.first(where: { $0.kind == .mailboxCreation })?.canUndo, false)
        XCTAssertEqual(items.first(where: { $0.kind == .manualGroup })?.canUndo, true)
        XCTAssertEqual(items.first(where: { $0.kind == .manualUngroup })?.canUndo, true)
        for item in items where item.kind != .manualGroup && item.kind != .manualUngroup {
            XCTAssertFalse(item.canUndo, "\(item.kind) has no durable command-service undo route")
        }
        XCTAssertEqual(items.first(where: { $0.kind == .recovery })?.needsRecovery, true)
        XCTAssertEqual(items.first(where: { $0.kind == .recovery })?.canUndo, false)
    }

    func testProjection_partialManualOperationNeedsRecoveryAndDoesNotAdvertiseUndo() {
        let operation = OrganizationOperation(
            id: "partial-manual",
            kind: .manualGroup,
            opaqueSourceFingerprints: ["opaque"],
            opaqueTargetFingerprints: ["opaque-group"],
            betterMailDelta: OrganizationBetterMailDelta(
                formatIdentifier: "test",
                before: Data(),
                after: Data([1])
            ),
            phase: .partial,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        let item = OrganizationHistoryProjection.make(operations: [operation],
                                                       legacyCompost: [],
                                                       legacyAutomation: []).first

        XCTAssertEqual(item?.status, .partial)
        XCTAssertEqual(item?.needsRecovery, true)
        XCTAssertEqual(item?.canUndo, false)
    }

    func testProjection_unifiesLedgerAndLegacyWithoutExactRouteContent() {
        let date = Date(timeIntervalSince1970: 100)
        let operation = OrganizationOperation(
            id: "ledger-group",
            kind: .manualGroup,
            opaqueSourceFingerprints: ["opaque-a", "opaque-b"],
            opaqueTargetFingerprints: ["opaque-group"],
            betterMailDelta: OrganizationBetterMailDelta(
                formatIdentifier: "test",
                before: Data(),
                after: Data([1])
            ),
            createdAt: date
        )
        let archive = GraphCompostEntry(id: "archive-a",
                                        threadID: "raw-thread-id",
                                        rootNodeID: "raw-node-id",
                                        subject: "Private subject",
                                        action: .archive,
                                        messageIDs: ["private-message-id"],
                                        priorMailboxPath: nil,
                                        priorAccountName: nil,
                                        createdAt: date.addingTimeInterval(1))

        let items = OrganizationHistoryProjection.make(operations: [operation],
                                                       legacyCompost: [archive],
                                                       legacyAutomation: [])
        XCTAssertEqual(items.map(\.id), ["legacy-compost:archive-a", "ledger-group"])
        XCTAssertEqual(items.last?.affectedCount, 2)
        XCTAssertFalse(items.map(\.titleLocalizationKey).joined().contains("Private subject"))
        XCTAssertFalse(items.map(\.id).contains("raw-thread-id"))
    }

    func testDismiss_hidesPresentationOnlyAndRevealRestores() {
        let coordinator = OrganizationHistoryCoordinator()
        let operation = OrganizationOperation(id: "operation-a",
                                              kind: .manualGroup,
                                              opaqueSourceFingerprints: ["opaque"],
                                              opaqueTargetFingerprints: ["opaque-group"],
                                              betterMailDelta: OrganizationBetterMailDelta(
                                                  formatIdentifier: "test",
                                                  before: Data(),
                                                  after: Data([1])
                                              ),
                                              createdAt: Date(timeIntervalSince1970: 100))
        coordinator.refresh(operations: [operation],
                            legacyCompost: [],
                            legacyAutomation: [])
        XCTAssertEqual(coordinator.visibleItems.map(\.id), ["operation-a"])

        coordinator.dismiss(id: "operation-a")
        XCTAssertTrue(coordinator.visibleItems.isEmpty)
        coordinator.revealAll()
        XCTAssertEqual(coordinator.visibleItems.map(\.id), ["operation-a"])
    }
}
