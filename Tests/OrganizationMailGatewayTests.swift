import CryptoKit
import Foundation
import XCTest
@testable import BetterMail

final class OrganizationMailGatewayTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testBetterMailOnlyEffectsCannotReachMailTransport() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let effect = OrganizationEffect.betterMailOnly(operation: .manualGroupMembership)

        for operationKind in [OrganizationOperationKind.manualGroup,
                              .graphArchive,
                              .automation] {
            let operation = try await makeAppAppliedOperation(store: store,
                                                               kind: operationKind)
            do {
                _ = try await gateway.createMailbox(operationID: operation.id,
                                                     effect: effect,
                                                     authorization: nil,
                                                     now: baseDate)
                XCTFail("BetterMail-only effect must not be accepted by mailbox gateway")
            } catch let error as OrganizationMailGatewayError {
                XCTAssertEqual(error, .unsupportedEffect)
            }
        }

        let counts = await spy.counts()
        XCTAssertEqual(counts.create, 0)
        XCTAssertEqual(counts.move, 0)
        XCTAssertEqual(counts.restore, 0)
    }

    func testEveryMailChangingCommandWithoutAuthorizationMakesZeroCalls() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let route = makeRoute()
        let destination = OrganizationMailDestination.mailbox(account: "Work",
                                                               path: "Projects/Target")
        let moveEffect = makeMoveEffect(routes: [route], destination: destination)
        let moveOperation = try await makeAppAppliedOperation(store: store,
                                                              kind: .mailMove)
        let createDestination = OrganizationMailDestination.newMailbox(account: "Work",
                                                                        path: "Projects/New")
        let createEffect = OrganizationEffect.appleMail(operation: .mailboxCreation,
                                                        mutation: .mailboxCreation,
                                                        messageCount: 0,
                                                        sourceRoutes: [],
                                                        destination: createDestination,
                                                        reversibility: .notReversible)
        let createOperation = try await makeAppAppliedOperation(store: store,
                                                                kind: .mailboxCreation)
        let restoreRoute = OrganizationMailRestoreRoute(
            current: route,
            destination: OrganizationMailRoute(messageID: route.messageID,
                                                account: route.account,
                                                mailboxPath: "Archive")
        )
        let restoreEffect = OrganizationEffect.appleMail(operation: .messageRestore,
                                                         mutation: .messageRestore,
                                                         messageCount: 1,
                                                         sourceRoutes: [route],
                                                         destination: .originalSourceRoutes,
                                                         reversibility: .conditionallyReversible)
        let restoreOperation = try await makeAppAppliedOperation(store: store,
                                                                 kind: .recovery)

        do {
            _ = try await gateway.move(operationID: moveOperation.id,
                                       effect: moveEffect,
                                       authorization: nil,
                                       routes: [route],
                                       destination: destination,
                                       now: baseDate)
            XCTFail("move without authorization must fail")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .authorizationRequired)
        }
        do {
            _ = try await gateway.createMailbox(operationID: createOperation.id,
                                                effect: createEffect,
                                                authorization: nil,
                                                now: baseDate)
            XCTFail("mailbox creation without authorization must fail")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .authorizationRequired)
        }
        do {
            _ = try await gateway.restore(operationID: restoreOperation.id,
                                          effect: restoreEffect,
                                          authorization: nil,
                                          routes: [restoreRoute],
                                          now: baseDate)
            XCTFail("restore without authorization must fail")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .authorizationRequired)
        }

        let counts = await spy.counts()
        XCTAssertEqual(counts.create, 0)
        XCTAssertEqual(counts.move, 0)
        XCTAssertEqual(counts.restore, 0)
        let moveLedger = try await store.operation(id: moveOperation.id)
        let createLedger = try await store.operation(id: createOperation.id)
        let restoreLedger = try await store.operation(id: restoreOperation.id)
        XCTAssertEqual(moveLedger?.phase, .appApplied)
        XCTAssertEqual(createLedger?.phase, .appApplied)
        XCTAssertEqual(restoreLedger?.phase, .appApplied)
    }

    func testCreateAndMoveCannotBeMarkedCompleteByMailboxOnlyEndpoint() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let route = makeRoute()
        let destination = OrganizationMailDestination.newMailbox(account: "Work",
                                                                  path: "Projects/New")
        let effect = OrganizationEffect.mixed(operation: .mailboxCreateAndMove,
                                              betterMailChange: .groupMembership,
                                              mailMutations: [.mailboxCreation, .messageMove],
                                              messageCount: 1,
                                              sourceRoutes: [route],
                                              destination: destination,
                                              reversibility: .notReversible)
        let operation = try await makeAppAppliedOperation(store: store,
                                                           kind: .mailboxCreation)

        do {
            _ = try await gateway.createMailbox(operationID: operation.id,
                                                effect: effect,
                                                authorization: nil,
                                                now: baseDate)
            XCTFail("create-and-move must not be reported complete by mailbox creation")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .unsupportedEffect)
        }

        let counts = await spy.counts()
        XCTAssertEqual(counts.create, 0)
        let ledger = try await store.operation(id: operation.id)
        XCTAssertEqual(ledger?.phase, .appApplied)
    }

    func testAuthorizationAndExactDisclosureMismatchesFailClosed() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let sourceRoute = makeRoute()
        let alternateRoute = makeRoute(messageID: "message-2", mailboxPath: "Inbox/Other")
        let destination = OrganizationMailDestination.mailbox(account: "Work",
                                                               path: "Projects/Target")
        let alternateDestination = OrganizationMailDestination.mailbox(account: "Work",
                                                                        path: "Projects/Other")
        let effect = makeMoveEffect(routes: [sourceRoute], destination: destination)
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: effect,
            confirmedAt: baseDate,
            now: baseDate
        )

        let routeOperation = try await makeAppAppliedOperation(store: store, kind: .mailMove)
        do {
            _ = try await gateway.move(operationID: routeOperation.id,
                                       effect: effect,
                                       authorization: authorization,
                                       routes: [alternateRoute],
                                       destination: destination,
                                       now: baseDate)
            XCTFail("changed route must not be substituted")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .exactRouteMismatch)
        }

        let destinationOperation = try await makeAppAppliedOperation(store: store, kind: .mailMove)
        do {
            _ = try await gateway.move(operationID: destinationOperation.id,
                                       effect: effect,
                                       authorization: authorization,
                                       routes: [sourceRoute],
                                       destination: alternateDestination,
                                       now: baseDate)
            XCTFail("changed destination must not be substituted")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .exactDestinationMismatch)
        }

        let changedEffect = makeMoveEffect(routes: [alternateRoute], destination: destination)
        let authorizationOperation = try await makeAppAppliedOperation(store: store, kind: .mailMove)
        do {
            _ = try await gateway.move(operationID: authorizationOperation.id,
                                       effect: changedEffect,
                                       authorization: authorization,
                                       routes: [alternateRoute],
                                       destination: destination,
                                       now: baseDate)
            XCTFail("authorization for another disclosure must not be reused")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .authorizationMismatch)
        }

        let counts = await spy.counts()
        XCTAssertEqual(counts.move, 0)
    }

    func testRevokedCurrentConsentBlocksPreparedWorkBeforeExternalCall() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let route = makeRoute()
        let destination = OrganizationMailDestination.mailbox(account: "Work",
                                                               path: "Projects/Target")
        let effect = makeMoveEffect(routes: [route], destination: destination)
        let consent = OrganizationMailAutomationConsent.userGranted(
            at: baseDate,
            allowedEffects: [.messageMove]
        )
        let authorization = try OrganizationMailAuthorization.fromCurrentConsent(
            effect: effect,
            consent: consent,
            now: baseDate
        )
        let operation = try await makeAppAppliedOperation(store: store, kind: .mailMove)

        do {
            _ = try await gateway.move(operationID: operation.id,
                                       effect: effect,
                                       authorization: authorization,
                                       routes: [route],
                                       destination: destination,
                                       currentConsent: .revoked(at: baseDate.addingTimeInterval(1)),
                                       now: baseDate.addingTimeInterval(1))
            XCTFail("revoked consent must block before transport")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .authorizationRevoked)
        }

        let counts = await spy.counts()
        XCTAssertEqual(counts.move, 0)
        let ledger = try await store.operation(id: operation.id)
        XCTAssertEqual(ledger?.phase, .appApplied)
    }

    func testExactMoveCompletesAndRecordsOpaqueMailReceipt() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let route = makeRoute()
        let destination = OrganizationMailDestination.mailbox(account: "Work",
                                                               path: "Projects/Target")
        let effect = makeMoveEffect(routes: [route], destination: destination)
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: effect,
            confirmedAt: baseDate,
            now: baseDate
        )
        await spy.setMoveResult(OrganizationMailTransportResult(completedRoutes: [route]))
        let operation = try await makeAppAppliedOperation(store: store, kind: .mailMove)

        let outcome = try await gateway.move(operationID: operation.id,
                                             effect: effect,
                                             authorization: authorization,
                                             routes: [route],
                                             destination: destination,
                                             now: baseDate)

        XCTAssertEqual(outcome.phase, .completed)
        XCTAssertEqual(outcome.expectedCount, 1)
        XCTAssertEqual(outcome.completedCount, 1)
        XCTAssertTrue(outcome.externalCallStarted)
        let counts = await spy.counts()
        XCTAssertEqual(counts.move, 1)
        let storedCompleted = try await store.operation(id: operation.id)
        let completed = try XCTUnwrap(storedCompleted)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.receipts.last?.kind, .mail)
        XCTAssertEqual(completed.receipts.last?.expectedCount, 1)
        XCTAssertEqual(completed.receipts.last?.completedCount, 1)
        XCTAssertEqual(completed.receipts.last?.opaqueItemFingerprints.count, 1)
        XCTAssertFalse(completed.receipts.last?.opaqueItemFingerprints.contains(route.mailboxPath) == true)
    }

    func testPartialMoveRecordsResidualStateAndRetryableFailure() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let firstRoute = makeRoute()
        let secondRoute = makeRoute(messageID: "message-2", mailboxPath: "Inbox/Other")
        let routes = [firstRoute, secondRoute]
        let destination = OrganizationMailDestination.mailbox(account: "Work",
                                                               path: "Projects/Target")
        let effect = makeMoveEffect(routes: routes, destination: destination)
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: effect,
            confirmedAt: baseDate,
            now: baseDate
        )
        await spy.setMoveResult(OrganizationMailTransportResult(
            completedRoutes: [firstRoute],
            failureCode: "mail-message-not-moved"
        ))
        let operation = try await makeAppAppliedOperation(store: store, kind: .mailMove)

        let outcome = try await gateway.move(operationID: operation.id,
                                             effect: effect,
                                             authorization: authorization,
                                             routes: routes,
                                             destination: destination,
                                             now: baseDate)

        XCTAssertEqual(outcome.phase, .partial)
        XCTAssertEqual(outcome.expectedCount, 2)
        XCTAssertEqual(outcome.completedCount, 1)
        XCTAssertEqual(outcome.failureCode, "mail-message-not-moved")
        let storedPartial = try await store.operation(id: operation.id)
        let partial = try XCTUnwrap(storedPartial)
        XCTAssertEqual(partial.phase, .partial)
        XCTAssertEqual(partial.lastFailure?.code, "mail-message-not-moved")
        XCTAssertEqual(partial.lastFailure?.retryable, true)
        XCTAssertEqual(partial.receipts.last?.expectedCount, 2)
        XCTAssertEqual(partial.receipts.last?.completedCount, 1)
    }

    func testMalformedTransportReceiptEntersRecoveryAndThrows() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let route = makeRoute()
        let unknownRoute = makeRoute(messageID: "unknown")
        let destination = OrganizationMailDestination.mailbox(account: "Work",
                                                               path: "Projects/Target")
        let effect = makeMoveEffect(routes: [route], destination: destination)
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: effect,
            confirmedAt: baseDate,
            now: baseDate
        )
        await spy.setMoveResult(OrganizationMailTransportResult(completedRoutes: [unknownRoute]))
        let operation = try await makeAppAppliedOperation(store: store, kind: .mailMove)

        do {
            _ = try await gateway.move(operationID: operation.id,
                                       effect: effect,
                                       authorization: authorization,
                                       routes: [route],
                                       destination: destination,
                                       now: baseDate)
            XCTFail("an unknown completed route must not be accepted")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .invalidTransportResult)
        }

        let storedRecovery = try await store.operation(id: operation.id)
        let recovery = try XCTUnwrap(storedRecovery)
        XCTAssertEqual(recovery.phase, .recovery)
        XCTAssertEqual(recovery.lastFailure?.code, "mail-transport-result-mismatch")
    }

    func testTransportFailureEntersRecoveryAndDoesNotDisappear() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        await spy.setShouldThrow(true)
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let route = makeRoute()
        let destination = OrganizationMailDestination.mailbox(account: "Work",
                                                               path: "Projects/Target")
        let effect = makeMoveEffect(routes: [route], destination: destination)
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: effect,
            confirmedAt: baseDate,
            now: baseDate
        )
        let operation = try await makeAppAppliedOperation(store: store, kind: .mailMove)

        do {
            _ = try await gateway.move(operationID: operation.id,
                                       effect: effect,
                                       authorization: authorization,
                                       routes: [route],
                                       destination: destination,
                                       now: baseDate)
            XCTFail("transport failure must be surfaced")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .transportFailed)
        }

        let counts = await spy.counts()
        XCTAssertEqual(counts.move, 1)
        let storedRecovery = try await store.operation(id: operation.id)
        let recovery = try XCTUnwrap(storedRecovery)
        XCTAssertEqual(recovery.phase, .recovery)
        XCTAssertEqual(recovery.lastFailure?.code, "mail-move-failed")
        XCTAssertEqual(recovery.receipts.last?.kind, .recovery)
    }

    func testMailboxCreationUsesAuthorizationAndCompletesWithReceipt() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        await spy.setCreateResult(OrganizationMailTransportResult(createdMailboxPath: "Projects/New"))
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let destination = OrganizationMailDestination.newMailbox(account: "Work",
                                                                  path: "Projects/New")
        let effect = OrganizationEffect.appleMail(operation: .mailboxCreation,
                                                  mutation: .mailboxCreation,
                                                  messageCount: 0,
                                                  sourceRoutes: [],
                                                  destination: destination,
                                                  reversibility: .notReversible)
        let consent = OrganizationMailAutomationConsent.userGranted(
            at: baseDate,
            allowedEffects: [.mailboxCreation]
        )
        let authorization = try OrganizationMailAuthorization.fromCurrentConsent(
            effect: effect,
            consent: consent,
            now: baseDate
        )
        let operation = try await makeAppAppliedOperation(store: store, kind: .mailboxCreation)

        let outcome = try await gateway.createMailbox(operationID: operation.id,
                                                       effect: effect,
                                                       authorization: authorization,
                                                       currentConsent: consent,
                                                       now: baseDate)

        XCTAssertEqual(outcome.phase, .completed)
        XCTAssertEqual(outcome.createdMailboxPath, "Projects/New")
        let counts = await spy.counts()
        XCTAssertEqual(counts.create, 1)
        let storedCompleted = try await store.operation(id: operation.id)
        let completed = try XCTUnwrap(storedCompleted)
        XCTAssertEqual(completed.receipts.last?.kind, .mail)
        XCTAssertEqual(completed.receipts.last?.expectedCount, 0)
        XCTAssertEqual(completed.receipts.last?.completedCount, 0)
        XCTAssertEqual(completed.receipts.last?.opaqueItemFingerprints.count, 1)
    }

    func testMailboxCreationInvalidResultPreservesReportedPathInRecoveryReceipt() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        await spy.setCreateResult(OrganizationMailTransportResult(
            createdMailboxPath: "Projects/Unexpected",
            mayHaveCompleted: true
        ))
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let destination = OrganizationMailDestination.newMailbox(account: "Work",
                                                                  path: "Projects/New")
        let effect = OrganizationEffect.appleMail(operation: .mailboxCreation,
                                                  mutation: .mailboxCreation,
                                                  messageCount: 0,
                                                  sourceRoutes: [],
                                                  destination: destination,
                                                  reversibility: .notReversible)
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: effect,
            confirmedAt: baseDate,
            now: baseDate
        )
        let operation = try await makeAppAppliedOperation(store: store, kind: .mailboxCreation)

        do {
            _ = try await gateway.createMailbox(operationID: operation.id,
                                                effect: effect,
                                                authorization: authorization,
                                                now: baseDate)
            XCTFail("a mismatched or ambiguous mailbox-create result must enter recovery")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .invalidTransportResult)
        }

        let storedRecovery = try await store.operation(id: operation.id)
        let recovery = try XCTUnwrap(storedRecovery)
        XCTAssertEqual(recovery.phase, .recovery)
        XCTAssertEqual(recovery.receipts.last?.kind, .recovery)
        let expectedPathFingerprint = SHA256.hash(
            data: Data("mailbox|Projects/Unexpected".utf8)
        ).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(recovery.receipts.last?.opaqueItemFingerprints,
                       [expectedPathFingerprint])
        XCTAssertFalse(fileIO.persistedData().contains { data in
            String(data: data, encoding: .utf8)?.contains("Projects/Unexpected") == true
        })
    }

    func testRestoreRequiresExactCurrentAndDestinationRoutes() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let current = makeRoute(messageID: "message-restore", mailboxPath: "Projects/Target")
        let original = OrganizationMailRoute(messageID: current.messageID,
                                              account: current.account,
                                              mailboxPath: "Inbox")
        let restoreRoute = OrganizationMailRestoreRoute(current: current,
                                                        destination: original)
        let effect = OrganizationEffect.appleMail(operation: .messageRestore,
                                                  mutation: .messageRestore,
                                                  messageCount: 1,
                                                  sourceRoutes: [current],
                                                  destination: .originalSourceRoutes,
                                                  reversibility: .conditionallyReversible)
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: effect,
            confirmedAt: baseDate,
            now: baseDate
        )
        await spy.setRestoreResult(OrganizationMailTransportResult(completedRoutes: [current]))
        let operation = try await makeAppAppliedOperation(store: store, kind: .recovery)

        let outcome = try await gateway.restore(operationID: operation.id,
                                                effect: effect,
                                                authorization: authorization,
                                                routes: [restoreRoute],
                                                now: baseDate)

        XCTAssertEqual(outcome.phase, .completed)
        XCTAssertEqual(outcome.completedCount, 1)
        let counts = await spy.counts()
        XCTAssertEqual(counts.restore, 1)
        let storedCompleted = try await store.operation(id: operation.id)
        let completed = try XCTUnwrap(storedCompleted)
        XCTAssertEqual(completed.receipts.last?.kind, .mail)
        XCTAssertEqual(completed.receipts.last?.completedCount, 1)
    }

    func testPreparedOperationCannotSkipAppAppliedLedgerPhase() async throws {
        let fileIO = GatewayTestFileIO()
        let store = makeStore(fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let route = makeRoute()
        let destination = OrganizationMailDestination.mailbox(account: "Work",
                                                               path: "Projects/Target")
        let effect = makeMoveEffect(routes: [route], destination: destination)
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: effect,
            confirmedAt: baseDate,
            now: baseDate
        )
        let operation = try await makePreparedOperation(store: store, kind: .mailMove)

        do {
            _ = try await gateway.move(operationID: operation.id,
                                       effect: effect,
                                       authorization: authorization,
                                       routes: [route],
                                       destination: destination,
                                       now: baseDate)
            XCTFail("prepared operation must not skip the app-applied phase")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .invalidOperationPhase(.prepared))
        }
        let counts = await spy.counts()
        XCTAssertEqual(counts.move, 0)
        let ledger = try await store.operation(id: operation.id)
        XCTAssertEqual(ledger?.phase, .prepared)
    }

    func testExecutionServiceFailsClosedForEveryNonCurrentConsentResolution() async throws {
        let fileIO = InMemoryOrganizationMailOperationFileIO()
        let store = makeInMemoryOrganizationOperationStore(label: "consent-matrix", fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let service = OrganizationMailExecutionService(
            operationStore: store,
            gateway: OrganizationMailGateway(transport: spy, operationStore: store)
        )
        let route = makeRoute()
        let destination = OrganizationMailDestination.mailbox(account: "Work",
                                                               path: "Projects/Target")
        let effect = makeMoveEffect(routes: [route], destination: destination)
        let unsafeResolutions: [OrganizationMailAutomationConsentResolution] = [
            .absent,
            .legacy,
            .malformed,
            .unknownSchema(version: 99),
            .disabled(.newUser),
            .revoked(.revoked(at: baseDate))
        ]

        for (index, resolution) in unsafeResolutions.enumerated() {
            let consent: OrganizationMailAutomationConsent?
            let authorization: OrganizationMailAuthorization?
            if case .current(let current) = resolution {
                consent = current
                authorization = try? OrganizationMailAuthorization.fromCurrentConsent(
                    effect: effect,
                    consent: current,
                    now: baseDate
                )
            } else {
                consent = resolution.consent
                authorization = nil
            }

            do {
                _ = try await service.move(
                    OrganizationMailMoveExecution(operationID: "unsafe-consent-\(index)",
                                                  kind: .automation,
                                                  effect: effect,
                                                  authorization: authorization,
                                                  currentConsent: consent,
                                                  routes: [route],
                                                  destination: destination,
                                                  now: baseDate)
                )
                XCTFail("\(resolution.status) must fail closed")
            } catch {
                // Any policy error is acceptable here; transport and ledger
                // counts are the release-blocking invariant.
            }
        }

        let granted = OrganizationMailAutomationConsent.userGranted(
            at: baseDate,
            allowedEffects: [.messageMove]
        )
        let issued = try OrganizationMailAuthorization.fromCurrentConsent(
            effect: effect,
            consent: granted,
            now: baseDate
        )
        do {
            _ = try await service.move(
                OrganizationMailMoveExecution(operationID: "revoked-after-prepare",
                                              kind: .automation,
                                              effect: effect,
                                              authorization: issued,
                                              currentConsent: .revoked(at: baseDate.addingTimeInterval(1)),
                                              routes: [route],
                                              destination: destination,
                                              now: baseDate.addingTimeInterval(1))
            )
            XCTFail("revocation after authorization must fail closed before transport")
        } catch {
            // Expected.
        }

        let counts = await spy.counts()
        XCTAssertEqual(counts.create, 0)
        XCTAssertEqual(counts.move, 0)
        XCTAssertEqual(counts.restore, 0)
        let rejectedOperations = try await store.allOperations()
        XCTAssertTrue(rejectedOperations.isEmpty,
                      "Rejected work must not create misleading prepared ledger rows")
        XCTAssertTrue(fileIO.persistedData().isEmpty)
    }

    func testAuthorizationInvariantMatrixBlocksEveryOperationKindAndMailMutationWithoutAuthorization() async throws {
        let fileIO = InMemoryOrganizationMailOperationFileIO()
        let store = makeInMemoryOrganizationOperationStore(label: "authorization-entrypoint-matrix",
                                                            fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let service = OrganizationMailExecutionService(
            operationStore: store,
            gateway: OrganizationMailGateway(transport: spy, operationStore: store)
        )
        let source = makeRoute()
        let moveDestination = OrganizationMailDestination.mailbox(account: "Work",
                                                                   path: "Projects/Target")
        let moveEffect = makeMoveEffect(routes: [source], destination: moveDestination)
        let restoreRoute = OrganizationMailRestoreRoute(
            current: OrganizationMailRoute(messageID: source.messageID,
                                           account: source.account,
                                           mailboxPath: "Projects/Target"),
            destination: source
        )
        let restoreEffect = OrganizationEffect.appleMail(
            operation: .messageRestore,
            mutation: .messageRestore,
            messageCount: 1,
            sourceRoutes: [restoreRoute.current],
            destination: .originalSourceRoutes,
            reversibility: .conditionallyReversible
        )
        let createEffect = OrganizationEffect.appleMail(
            operation: .mailboxCreation,
            mutation: .mailboxCreation,
            messageCount: 0,
            sourceRoutes: [],
            destination: .newMailbox(account: "Work", path: "Projects/New"),
            reversibility: .notReversible
        )

        for (index, kind) in OrganizationOperationKind.allCases.enumerated() {
            do {
                _ = try await service.move(
                    OrganizationMailMoveExecution(
                        operationID: "blocked-move-\(index)",
                        kind: kind,
                        effect: moveEffect,
                        authorization: nil,
                        currentConsent: nil,
                        routes: [source],
                        destination: moveDestination,
                        now: baseDate
                    )
                )
                XCTFail("\(kind) move must require authorization")
            } catch {
                // The invariant below is the release gate: no transport and
                // no misleading prepared ledger record may be produced.
            }

            do {
                _ = try await service.restore(
                    OrganizationMailRestoreExecution(
                        operationID: "blocked-restore-\(index)",
                        kind: kind,
                        effect: restoreEffect,
                        authorization: nil,
                        currentConsent: nil,
                        routes: [restoreRoute],
                        now: baseDate
                    )
                )
                XCTFail("\(kind) restore must require authorization")
            } catch {
                // Expected.
            }

            do {
                _ = try await service.createMailbox(
                    OrganizationMailboxCreationExecution(
                        operationID: "blocked-create-\(index)",
                        kind: kind,
                        effect: createEffect,
                        authorization: nil,
                        currentConsent: nil,
                        now: baseDate
                    )
                )
                XCTFail("\(kind) mailbox creation must require authorization")
            } catch {
                // Expected.
            }
        }

        let counts = await spy.counts()
        XCTAssertEqual(counts.create, 0)
        XCTAssertEqual(counts.move, 0)
        XCTAssertEqual(counts.restore, 0)
        let blockedOperations = try await store.allOperations()
        XCTAssertTrue(blockedOperations.isEmpty)
        XCTAssertTrue(fileIO.persistedData().isEmpty)
    }

    func testExecutionServicePreparesEncryptedLedgerAndReplaysWithoutSecondTransportCall() async throws {
        let fileIO = InMemoryOrganizationMailOperationFileIO()
        let store = makeInMemoryOrganizationOperationStore(label: "execution-replay", fileIO: fileIO)
        let spy = SpyOrganizationMailGatewayTransport()
        let gateway = OrganizationMailGateway(transport: spy, operationStore: store)
        let service = OrganizationMailExecutionService(operationStore: store, gateway: gateway)
        let route = makeRoute(messageID: "private-message@example.com",
                              mailboxPath: "Private/Inbox")
        let destination = OrganizationMailDestination.mailbox(account: "Private Work",
                                                               path: "Private/Target")
        let effect = makeMoveEffect(routes: [route], destination: destination)
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: effect,
            confirmedAt: baseDate,
            now: baseDate
        )
        await spy.setMoveResult(OrganizationMailTransportResult(completedRoutes: [route]))
        let request = OrganizationMailMoveExecution(operationID: "service-move",
                                                    kind: .mailMove,
                                                    effect: effect,
                                                    authorization: authorization,
                                                    currentConsent: nil,
                                                    routes: [route],
                                                    destination: destination,
                                                    now: baseDate)

        let first = try await service.move(request)
        let replay = try await service.move(request)

        XCTAssertTrue(first.isComplete)
        XCTAssertTrue(first.externalCallStarted)
        XCTAssertTrue(replay.isComplete)
        XCTAssertFalse(replay.externalCallStarted)
        let counts = await spy.counts()
        XCTAssertEqual(counts.move, 1)
        let storedOperation = try await store.operation(id: request.operationID)
        let operation = try XCTUnwrap(storedOperation)
        XCTAssertEqual(operation.phase, .completed)
        XCTAssertNotNil(operation.mailRouteEnvelope)
        XCTAssertFalse(operation.opaqueSourceFingerprints.contains(route.messageID))
        let persistedText = fileIO.persistedData()
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(persistedText.contains(route.messageID))
        XCTAssertFalse(persistedText.contains(route.mailboxPath))
        XCTAssertFalse(persistedText.contains("Private Work"))
        XCTAssertFalse(persistedText.contains("Private/Target"))
    }

    func testExecutionServiceNeverReplaysPartialOrUnknownMailOutcomeUnderSameOperationID() async throws {
        let partialStore = makeInMemoryOrganizationOperationStore(label: "partial-no-replay")
        let partialSpy = SpyOrganizationMailGatewayTransport()
        let partialService = OrganizationMailExecutionService(
            operationStore: partialStore,
            gateway: OrganizationMailGateway(transport: partialSpy,
                                             operationStore: partialStore)
        )
        let firstRoute = makeRoute(messageID: "first@example.com")
        let secondRoute = makeRoute(messageID: "second@example.com")
        let routes = [firstRoute, secondRoute]
        let destination = OrganizationMailDestination.mailbox(account: "Work",
                                                               path: "Projects/Target")
        let effect = makeMoveEffect(routes: routes, destination: destination)
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: effect,
            confirmedAt: baseDate,
            now: baseDate
        )
        await partialSpy.setMoveResult(OrganizationMailTransportResult(
            completedRoutes: [firstRoute],
            failureCode: "mail-message-not-moved"
        ))
        let partialRequest = OrganizationMailMoveExecution(
            operationID: "partial-no-replay",
            kind: .mailMove,
            effect: effect,
            authorization: authorization,
            currentConsent: nil,
            routes: routes,
            destination: destination,
            now: baseDate
        )

        let partial = try await partialService.move(partialRequest)
        XCTAssertEqual(partial.phase, .partial)
        do {
            _ = try await partialService.move(partialRequest)
            XCTFail("A partial result must require a new residual-bound operation")
        } catch let error as OrganizationMailExecutionServiceError {
            XCTAssertEqual(error, .operationCannotResume(.partial))
        }
        let partialCounts = await partialSpy.counts()
        XCTAssertEqual(partialCounts.move, 1)

        let recoveryStore = makeInMemoryOrganizationOperationStore(label: "unknown-no-replay")
        let recoverySpy = SpyOrganizationMailGatewayTransport()
        let recoveryService = OrganizationMailExecutionService(
            operationStore: recoveryStore,
            gateway: OrganizationMailGateway(transport: recoverySpy,
                                             operationStore: recoveryStore)
        )
        await recoverySpy.setShouldThrow(true)
        let recoveryRequest = OrganizationMailMoveExecution(
            operationID: "unknown-no-replay",
            kind: .automation,
            effect: makeMoveEffect(routes: [firstRoute], destination: destination),
            authorization: try OrganizationMailAuthorization.fromUserConfirmation(
                effect: makeMoveEffect(routes: [firstRoute], destination: destination),
                confirmedAt: baseDate,
                now: baseDate
            ),
            currentConsent: nil,
            routes: [firstRoute],
            destination: destination,
            now: baseDate
        )
        do {
            _ = try await recoveryService.move(recoveryRequest)
            XCTFail("The injected transport failure should require recovery")
        } catch let error as OrganizationMailGatewayError {
            XCTAssertEqual(error, .transportFailed)
        }
        await recoverySpy.setShouldThrow(false)
        do {
            _ = try await recoveryService.move(recoveryRequest)
            XCTFail("An unknown outcome must never be repeated implicitly")
        } catch let error as OrganizationMailExecutionServiceError {
            XCTAssertEqual(error, .operationCannotResume(.recovery))
        }
        let recoveryCounts = await recoverySpy.counts()
        XCTAssertEqual(recoveryCounts.move, 1)
    }

    func testRestoreOperationIdentifierIsOrderIndependentAndChangesWithResidualRoutes() {
        let first = OrganizationMailRestoreRoute(
            current: makeRoute(messageID: "first@example.com", mailboxPath: "Filed"),
            destination: makeRoute(messageID: "first@example.com", mailboxPath: "Inbox")
        )
        let second = OrganizationMailRestoreRoute(
            current: makeRoute(messageID: "second@example.com", mailboxPath: "Filed"),
            destination: makeRoute(messageID: "second@example.com", mailboxPath: "Archive")
        )

        let full = OrganizationMailOperationIdentifier.makeRestore(
            namespace: "restore-test",
            seed: "history-entry",
            routes: [first, second]
        )
        let reordered = OrganizationMailOperationIdentifier.makeRestore(
            namespace: "restore-test",
            seed: "history-entry",
            routes: [second, first]
        )
        let residual = OrganizationMailOperationIdentifier.makeRestore(
            namespace: "restore-test",
            seed: "history-entry",
            routes: [second]
        )

        XCTAssertEqual(full, reordered)
        XCTAssertNotEqual(full, residual)
        XCTAssertFalse(full.contains("first@example.com"))
        XCTAssertFalse(residual.contains("Archive"))
    }

    func testProductionOrganizationSourcesHaveNoRawMailMutationCallsOutsideGatewayTransport() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testURL.deletingLastPathComponent().deletingLastPathComponent()
        let productionRoot = projectRoot.appendingPathComponent("BetterMail")
        let forbidden = [
            "MailControl.createMailbox(",
            "MailControl.moveMessagesByInternalID(",
            "MailControl.moveSelection(",
            "mailClient.moveMessages("
        ]
        let allowedTransportPath = productionRoot
            .appendingPathComponent("Sources/Organizer/OrganizationMailGateway.swift")
            .standardizedFileURL.path
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: productionRoot,
                                           includingPropertiesForKeys: nil)
        )
        var checkedFiles = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard fileURL.standardizedFileURL.path != allowedTransportPath else { continue }
            checkedFiles += 1
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.contains(token),
                               "\(fileURL.path) bypasses OrganizationMailExecutionService with \(token)")
            }
        }
        XCTAssertGreaterThan(checkedFiles, 50,
                             "The invariant scan must cover the production Swift source tree")

        let entryPointContracts: [(String, [String])] = [
            ("BetterMail/Sources/ViewModels/GraphCanvasViewModel.swift",
             ["confirmSnipBatch", "internal func restore", "organizationMailService.move(",
              "organizationMailService.restore("]),
            ("BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift",
             ["moveSelectionToMailboxFolder", "createMailboxFolderAndMoveSelection",
              "moveThreadToAssignedFolderMailbox", "organizationMailService.createMailbox(",
              "organizationMailService.move("]),
            ("BetterMail/Sources/Services/GraphAutomationCoordinator.swift",
             ["executeMailboxPhase", "finishMailRestore", "organizationMailService.move(",
              "organizationMailService.restore("])
        ]
        for (relativePath, requiredTokens) in entryPointContracts {
            let source = try String(contentsOf: projectRoot.appendingPathComponent(relativePath),
                                    encoding: .utf8)
            for token in requiredTokens {
                XCTAssertTrue(source.contains(token),
                              "\(relativePath) lost required organization boundary token \(token)")
            }
        }
    }

    func testProductionLogsDoNotMarkMailRoutesIdentifiersOrErrorTextPublic() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testURL.deletingLastPathComponent().deletingLastPathComponent()
        let productionRoot = projectRoot.appendingPathComponent("BetterMail")
        let forbiddenPublicInterpolations = [
            #"\(preview, privacy: .public)"#,
            #"\(summary, privacy: .public)"#,
            #"\(account, privacy: .public)"#,
            #"\(account ?? "", privacy: .public)"#,
            #"\(trimmedAccount, privacy: .public)"#,
            #"\(mailbox, privacy: .public)"#,
            #"\(mailboxLabel, privacy: .public)"#,
            #"\(mailboxPath, privacy: .public)"#,
            #"\(trimmedMailboxPath, privacy: .public)"#,
            #"\(resolvedID, privacy: .public)"#,
            #"\(folderID, privacy: .public)"#,
            #"\(context.folderID, privacy: .public)"#,
            #"\(existingContext.folderID, privacy: .public)"#,
            #"\(messageKey, privacy: .public)"#,
            #"\(request.nodeID, privacy: .public)"#,
            #"\(context.targetNodeID, privacy: .public)"#,
            #"\(existingContext.targetNodeID, privacy: .public)"#,
            #"\(target.messageID, privacy: .public)"#,
            #"\(targetID, privacy: .public)"#,
            #"\(scrollTargetID, privacy: .public)"#,
            #"\(preferredNodeID, privacy: .public)"#,
            #"\(fallbackTargetID, privacy: .public)"#,
            #"error.localizedDescription, privacy: .public"#,
            #"String(describing: error), privacy: .public"#,
            #"sampleMailboxIDs=\(uniqueSample.joined(separator: ","), privacy: .public)"#,
            "print(summary)"
        ]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: productionRoot,
                                           includingPropertiesForKeys: nil)
        )
        var checkedFiles = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            checkedFiles += 1
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbiddenPublicInterpolations {
                XCTAssertFalse(source.contains(token),
                               "\(fileURL.path) exposes a sensitive log field through \(token)")
            }
        }
        XCTAssertGreaterThan(checkedFiles, 50,
                             "The privacy scan must cover the production Swift source tree")
    }

    private func makeMoveEffect(routes: [OrganizationMailRoute],
                                destination: OrganizationMailDestination) -> OrganizationEffect {
        OrganizationEffect.appleMail(operation: .messageMove,
                                      mutation: .messageMove,
                                      messageCount: routes.count,
                                      sourceRoutes: routes,
                                      destination: destination,
                                      reversibility: .fullyReversible)
    }

    private func makeRoute(messageID: String = "message-1",
                           mailboxPath: String = "Inbox") -> OrganizationMailRoute {
        OrganizationMailRoute(messageID: messageID,
                              account: "Work",
                              mailboxPath: mailboxPath)
    }

    private func makeStore(fileIO: GatewayTestFileIO) -> OrganizationOperationStore {
        OrganizationOperationStore(fileURL: URL(fileURLWithPath: "/tmp/organization-mail-gateway-(UUID().uuidString).json"),
                                   fileIO: fileIO)
    }

    private func makePreparedOperation(store: OrganizationOperationStore,
                                       kind: OrganizationOperationKind) async throws -> OrganizationOperation {
        let operation = OrganizationOperation(id: UUID().uuidString,
                                              kind: kind,
                                              opaqueSourceFingerprints: ["source"],
                                              opaqueTargetFingerprints: ["target"],
                                              betterMailDelta: OrganizationBetterMailDelta(formatIdentifier: "gateway-test-v1",
                                                                                           before: Data([0]),
                                                                                           after: Data([1])),
                                              createdAt: baseDate)
        return try await store.prepare(operation)
    }

    private func makeAppAppliedOperation(store: OrganizationOperationStore,
                                         kind: OrganizationOperationKind) async throws -> OrganizationOperation {
        let operation = try await makePreparedOperation(store: store, kind: kind)
        return try await store.advance(id: operation.id,
                                       to: .appApplied,
                                       at: baseDate)
    }
}

private actor SpyOrganizationMailGatewayTransport: OrganizationMailGatewayTransport {
    private var createCallCount = 0
    private var moveCallCount = 0
    private var restoreCallCount = 0
    private var createResult = OrganizationMailTransportResult(createdMailboxPath: "Mailbox")
    private var moveResult = OrganizationMailTransportResult()
    private var restoreResult = OrganizationMailTransportResult()
    private var shouldThrow = false

    func setCreateResult(_ result: OrganizationMailTransportResult) {
        createResult = result
    }

    func setMoveResult(_ result: OrganizationMailTransportResult) {
        moveResult = result
    }

    func setRestoreResult(_ result: OrganizationMailTransportResult) {
        restoreResult = result
    }

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func counts() -> (create: Int, move: Int, restore: Int) {
        (createCallCount, moveCallCount, restoreCallCount)
    }

    func createMailbox(destination: OrganizationMailDestination) async throws -> OrganizationMailTransportResult {
        createCallCount += 1
        if shouldThrow { throw SpyOrganizationMailGatewayError.failed }
        return createResult
    }

    func move(routes: [OrganizationMailRoute],
              destination: OrganizationMailDestination) async throws -> OrganizationMailTransportResult {
        moveCallCount += 1
        if shouldThrow { throw SpyOrganizationMailGatewayError.failed }
        return moveResult
    }

    func restore(routes: [OrganizationMailRestoreRoute]) async throws -> OrganizationMailTransportResult {
        restoreCallCount += 1
        if shouldThrow { throw SpyOrganizationMailGatewayError.failed }
        return restoreResult
    }
}

private enum SpyOrganizationMailGatewayError: Error, Sendable {
    case failed
}

private final class GatewayTestFileIO: OrganizationOperationFileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: Data] = [:]

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

    func persistedData() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values.values)
    }
}
