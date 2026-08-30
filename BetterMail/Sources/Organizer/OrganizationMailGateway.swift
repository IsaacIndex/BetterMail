import CryptoKit
import Foundation

/// A restore request keeps the current and destination route together. Mail
/// restore is never allowed to infer a destination from a message ID alone.
internal nonisolated struct OrganizationMailRestoreRoute: Codable, Equatable, Hashable, Sendable {
    internal let current: OrganizationMailRoute
    internal let destination: OrganizationMailRoute

    internal init(current: OrganizationMailRoute,
                  destination: OrganizationMailRoute) {
        self.current = current
        self.destination = destination
    }

    internal var isExact: Bool {
        current.isExact
            && destination.isExact
            && current.messageID.lowercased() == destination.messageID.lowercased()
    }
}

/// The only external transport seam used by organization Mail mutations.
/// BetterMail-only commands do not have a gateway operation and therefore
/// cannot reach this protocol.
internal nonisolated protocol OrganizationMailGatewayTransport: Sendable {
    func createMailbox(destination: OrganizationMailDestination) async throws -> OrganizationMailTransportResult
    func move(routes: [OrganizationMailRoute],
              destination: OrganizationMailDestination) async throws -> OrganizationMailTransportResult
    func restore(routes: [OrganizationMailRestoreRoute]) async throws -> OrganizationMailTransportResult
}

/// A transport result contains no raw Mail error or message body. The gateway
/// turns these exact in-memory route results into opaque ledger fingerprints.
internal nonisolated struct OrganizationMailTransportResult: Equatable, Sendable {
    internal let completedRoutes: [OrganizationMailRoute]
    internal let createdMailboxPath: String?
    internal let failureCode: String?
    internal let mayHaveCompleted: Bool

    internal init(completedRoutes: [OrganizationMailRoute] = [],
                  createdMailboxPath: String? = nil,
                  failureCode: String? = nil,
                  mayHaveCompleted: Bool = false) {
        self.completedRoutes = completedRoutes
        self.createdMailboxPath = createdMailboxPath
        self.failureCode = failureCode
        self.mayHaveCompleted = mayHaveCompleted
    }
}

/// The production transport adapts existing Mail clients without making
/// those clients authorization-aware. All callers still enter through the
/// gateway before this adapter can invoke Apple Mail.
internal nonisolated struct DefaultOrganizationMailGatewayTransport: OrganizationMailGatewayTransport, Sendable {
    private let mailClient: any GraphSnipMailMoving

    internal init(mailClient: any GraphSnipMailMoving = MailAppleScriptClient()) {
        self.mailClient = mailClient
    }

    internal func createMailbox(destination: OrganizationMailDestination) async throws -> OrganizationMailTransportResult {
        guard case .newMailbox(let account, let path) = destination,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrganizationMailGatewayError.invalidDestination
        }

        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let mailboxName = components.last, !mailboxName.isEmpty else {
            throw OrganizationMailGatewayError.invalidDestination
        }
        let parentPath = components.dropLast().joined(separator: "/")
        let createdPath = try await MailControl.createMailbox(named: mailboxName,
                                                              in: account,
                                                              parentPath: parentPath.isEmpty ? nil : parentPath)
        return OrganizationMailTransportResult(createdMailboxPath: createdPath)
    }

    internal func move(routes: [OrganizationMailRoute],
                       destination: OrganizationMailDestination) async throws -> OrganizationMailTransportResult {
        guard case .mailbox(let account, let path) = destination,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrganizationMailGatewayError.invalidDestination
        }

        struct Source: Hashable {
            let account: String
            let mailboxPath: String
        }
        let grouped = Dictionary(grouping: routes) {
            Source(account: $0.account, mailboxPath: $0.mailboxPath)
        }
        var completedRoutes: [OrganizationMailRoute] = []
        for (source, sourceRoutes) in grouped.sorted(by: {
            if $0.key.account == $1.key.account {
                return $0.key.mailboxPath < $1.key.mailboxPath
            }
            return $0.key.account < $1.key.account
        }) {
            do {
                let result = try await mailClient.moveMessages(
                    messageIDs: sourceRoutes.map(\.messageID),
                    toMailboxPath: path,
                    account: account,
                    sourceMailboxPath: source.mailboxPath,
                    sourceAccount: source.account
                )
                let completedInGroup = sourceRoutes.filter { result.contains($0.messageID) }
                completedRoutes.append(contentsOf: completedInGroup)
                guard completedInGroup.count == sourceRoutes.count else {
                    return OrganizationMailTransportResult(
                        completedRoutes: completedRoutes,
                        failureCode: "mail-message-not-moved",
                        mayHaveCompleted: false
                    )
                }
            } catch {
                return OrganizationMailTransportResult(
                    completedRoutes: completedRoutes,
                    failureCode: "mail-move-failed",
                    mayHaveCompleted: true
                )
            }
        }
        return OrganizationMailTransportResult(completedRoutes: completedRoutes)
    }

    internal func restore(routes: [OrganizationMailRestoreRoute]) async throws -> OrganizationMailTransportResult {
        struct RestoreGroup: Hashable {
            let currentAccount: String
            let currentMailboxPath: String
            let destinationAccount: String
            let destinationMailboxPath: String
        }
        let grouped = Dictionary(grouping: routes) {
            RestoreGroup(currentAccount: $0.current.account,
                         currentMailboxPath: $0.current.mailboxPath,
                         destinationAccount: $0.destination.account,
                         destinationMailboxPath: $0.destination.mailboxPath)
        }

        var completedRoutes: [OrganizationMailRoute] = []
        for (group, groupRoutes) in grouped.sorted(by: {
            let lhs = "\($0.key.currentAccount)|\($0.key.currentMailboxPath)|\($0.key.destinationAccount)|\($0.key.destinationMailboxPath)"
            let rhs = "\($1.key.currentAccount)|\($1.key.currentMailboxPath)|\($1.key.destinationAccount)|\($1.key.destinationMailboxPath)"
            return lhs < rhs
        }) {
            do {
                let result = try await mailClient.moveMessages(
                    messageIDs: groupRoutes.map(\.current.messageID),
                    toMailboxPath: group.destinationMailboxPath,
                    account: group.destinationAccount,
                    sourceMailboxPath: group.currentMailboxPath,
                    sourceAccount: group.currentAccount
                )
                let completedInGroup = groupRoutes
                    .filter { result.contains($0.current.messageID) }
                    .map(\.current)
                completedRoutes.append(contentsOf: completedInGroup)
                guard completedInGroup.count == groupRoutes.count else {
                    return OrganizationMailTransportResult(
                        completedRoutes: completedRoutes,
                        failureCode: "mail-message-not-restored",
                        mayHaveCompleted: false
                    )
                }
            } catch {
                return OrganizationMailTransportResult(
                    completedRoutes: completedRoutes,
                    failureCode: "mail-restore-failed",
                    mayHaveCompleted: true
                )
            }
        }
        return OrganizationMailTransportResult(completedRoutes: completedRoutes)
    }
}

internal nonisolated struct OrganizationMailGatewayOutcome: Equatable, Sendable {
    internal let operationID: String
    internal let phase: OrganizationOperationPhase
    internal let expectedCount: Int
    internal let completedCount: Int
    /// Exact routes are returned only in memory so callers can compensate or
    /// update local projections without inferring success from a count. The
    /// durable ledger stores only encrypted manifests and opaque receipts.
    internal let completedRoutes: [OrganizationMailRoute]
    internal let createdMailboxPath: String?
    internal let failureCode: String?
    internal let externalCallStarted: Bool

    internal var isComplete: Bool {
        phase == .completed
    }
}

/// Injectable authorization-aware gateway seam. Production transports remain
/// private to `OrganizationMailGateway`; view models and coordinators depend on
/// the higher-level execution service rather than a raw Mail client.
internal nonisolated protocol OrganizationMailGatewayExecuting: Sendable {
    func createMailbox(operationID: String,
                       effect: OrganizationEffect,
                       authorization: OrganizationMailAuthorization?,
                       currentConsent: OrganizationMailAutomationConsent?,
                       now: Date) async throws -> OrganizationMailGatewayOutcome
    func move(operationID: String,
              effect: OrganizationEffect,
              authorization: OrganizationMailAuthorization?,
              routes: [OrganizationMailRoute],
              destination: OrganizationMailDestination,
              currentConsent: OrganizationMailAutomationConsent?,
              now: Date) async throws -> OrganizationMailGatewayOutcome
    func restore(operationID: String,
                 effect: OrganizationEffect,
                 authorization: OrganizationMailAuthorization?,
                 routes: [OrganizationMailRestoreRoute],
                 currentConsent: OrganizationMailAutomationConsent?,
                 now: Date) async throws -> OrganizationMailGatewayOutcome
}

/// Shared fail-closed policy used before ledger preparation and again at the
/// final gateway boundary immediately before transport.
internal nonisolated enum OrganizationMailAuthorizationPolicy {
    internal static func validate(effect: OrganizationEffect,
                                  authorization: OrganizationMailAuthorization?,
                                  currentConsent: OrganizationMailAutomationConsent?,
                                  now: Date) throws {
        guard effect.requiresMailAuthorization,
              effect.hasCompleteMailDisclosure else {
            throw OrganizationMailGatewayError.incompleteDisclosure
        }
        guard let authorization else {
            throw OrganizationMailGatewayError.authorizationRequired
        }
        guard authorization.effect == effect else {
            throw OrganizationMailGatewayError.authorizationMismatch
        }
        guard authorization.decision(using: currentConsent,
                                     phase: .preparedNotStarted,
                                     now: now) == .allowed else {
            throw OrganizationMailGatewayError.authorizationRevoked
        }
    }
}

internal nonisolated enum OrganizationMailGatewayError: Error, Equatable, Sendable {
    case authorizationRequired
    case authorizationMismatch
    case authorizationRevoked
    case incompleteDisclosure
    case unsupportedEffect
    case invalidDestination
    case invalidRestoreRoute
    case exactRouteMismatch
    case exactDestinationMismatch
    case missingOperation
    case invalidOperationPhase(OrganizationOperationPhase)
    case invalidTransportResult
    case transportFailed
    case ledgerFailureBeforeExternalCall
    case ledgerFailureAfterExternalCall

    internal var localizationKey: String {
        switch self {
        case .authorizationRequired:
            return "organization.mail.gateway.error.authorization_required"
        case .authorizationMismatch:
            return "organization.mail.gateway.error.authorization_mismatch"
        case .authorizationRevoked:
            return "organization.mail.gateway.error.authorization_revoked"
        case .incompleteDisclosure:
            return "organization.mail.gateway.error.incomplete_disclosure"
        case .unsupportedEffect:
            return "organization.mail.gateway.error.unsupported_effect"
        case .invalidDestination:
            return "organization.mail.gateway.error.invalid_destination"
        case .invalidRestoreRoute:
            return "organization.mail.gateway.error.invalid_restore_route"
        case .exactRouteMismatch:
            return "organization.mail.gateway.error.exact_route_mismatch"
        case .exactDestinationMismatch:
            return "organization.mail.gateway.error.exact_destination_mismatch"
        case .missingOperation:
            return "organization.mail.gateway.error.missing_operation"
        case .invalidOperationPhase:
            return "organization.mail.gateway.error.invalid_operation_phase"
        case .invalidTransportResult:
            return "organization.mail.gateway.error.invalid_transport_result"
        case .transportFailed:
            return "organization.mail.gateway.error.transport_failed"
        case .ledgerFailureBeforeExternalCall:
            return "organization.mail.gateway.error.ledger_failure_before_external_call"
        case .ledgerFailureAfterExternalCall:
            return "organization.mail.gateway.error.ledger_failure_after_external_call"
        }
    }
}

/// The authorization and ledger boundary for every organization Mail effect.
/// This actor intentionally exposes no BetterMail-only method: local changes
/// must complete through their own local transaction and never call Mail.
internal actor OrganizationMailGateway {
    private let transport: any OrganizationMailGatewayTransport
    private let operationStore: OrganizationOperationStore

    internal init(transport: any OrganizationMailGatewayTransport = DefaultOrganizationMailGatewayTransport(),
                  operationStore: OrganizationOperationStore = .shared) {
        self.transport = transport
        self.operationStore = operationStore
    }

    @discardableResult
    internal func createMailbox(operationID: String,
                                 effect: OrganizationEffect,
                                 authorization: OrganizationMailAuthorization?,
                                 currentConsent: OrganizationMailAutomationConsent? = nil,
                                 now: Date = Date()) async throws -> OrganizationMailGatewayOutcome {
        guard effect.mailMutations == [.mailboxCreation],
              effect.messageCount == 0,
              effect.sourceRoutes.isEmpty,
              case .newMailbox = effect.destination else {
            throw OrganizationMailGatewayError.unsupportedEffect
        }
        guard let destination = effect.destination else {
            throw OrganizationMailGatewayError.invalidDestination
        }
        guard case .newMailbox(let account, let path) = destination,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrganizationMailGatewayError.invalidDestination
        }

        try authorize(effect: effect,
                      authorization: authorization,
                      currentConsent: currentConsent,
                      now: now)
        let operation = try await begin(operationID: operationID, now: now)
        let result: OrganizationMailTransportResult
        do {
            result = try await transport.createMailbox(destination: destination)
        } catch {
            throw try await transportFailure(operation: operation,
                                              expectedCount: 0,
                                              failureCode: "mail-mailbox-create-failed",
                                              now: now)
        }
        let reportedCreatedPath = result.createdMailboxPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let createdPath = reportedCreatedPath,
              !createdPath.isEmpty,
              createdPath == path,
              result.completedRoutes.isEmpty,
              result.failureCode == nil,
              !result.mayHaveCompleted else {
            _ = try await recover(operation: operation,
                                  expectedCount: 0,
                                  completedCount: 0,
                                  failureCode: result.failureCode ?? "mail-mailbox-create-result-invalid",
                                  now: now,
                                  createdMailboxPath: reportedCreatedPath?.isEmpty == false
                                      ? reportedCreatedPath
                                      : nil)
            throw OrganizationMailGatewayError.invalidTransportResult
        }
        return try await complete(operation: operation,
                                  expectedCount: 0,
                                  completedRoutes: [],
                                  createdMailboxPath: createdPath,
                                  now: now)
    }

    @discardableResult
    internal func move(operationID: String,
                       effect: OrganizationEffect,
                       authorization: OrganizationMailAuthorization?,
                       routes: [OrganizationMailRoute],
                       destination: OrganizationMailDestination,
                       currentConsent: OrganizationMailAutomationConsent? = nil,
                       now: Date = Date()) async throws -> OrganizationMailGatewayOutcome {
        guard effect.mailMutations == [.messageMove] else {
            throw OrganizationMailGatewayError.unsupportedEffect
        }
        let normalizedDestination = destination.normalized
        try validateMove(effect: effect, routes: routes, destination: normalizedDestination)
        try authorize(effect: effect,
                      authorization: authorization,
                      currentConsent: currentConsent,
                      now: now)
        let operation = try await begin(operationID: operationID, now: now)
        let result: OrganizationMailTransportResult
        do {
            result = try await transport.move(routes: routes, destination: normalizedDestination)
        } catch {
            throw try await transportFailure(operation: operation,
                                              expectedCount: routes.count,
                                              failureCode: "mail-move-failed",
                                              now: now)
        }
        return try await finish(operation: operation,
                                expectedRoutes: routes,
                                result: result,
                                now: now)
    }

    /// Alias retained for call sites whose domain language is “move
    /// messages”. It has exactly the same authorization and ledger boundary.
    @discardableResult
    internal func moveMessages(operationID: String,
                               effect: OrganizationEffect,
                               authorization: OrganizationMailAuthorization?,
                               routes: [OrganizationMailRoute],
                               destination: OrganizationMailDestination,
                               currentConsent: OrganizationMailAutomationConsent? = nil,
                               now: Date = Date()) async throws -> OrganizationMailGatewayOutcome {
        try await move(operationID: operationID,
                       effect: effect,
                       authorization: authorization,
                       routes: routes,
                       destination: destination,
                       currentConsent: currentConsent,
                       now: now)
    }

    @discardableResult
    internal func restore(operationID: String,
                          effect: OrganizationEffect,
                          authorization: OrganizationMailAuthorization?,
                          routes: [OrganizationMailRestoreRoute],
                          currentConsent: OrganizationMailAutomationConsent? = nil,
                          now: Date = Date()) async throws -> OrganizationMailGatewayOutcome {
        guard effect.mailMutations == [.messageRestore] else {
            throw OrganizationMailGatewayError.unsupportedEffect
        }
        try validateRestore(effect: effect, routes: routes)
        try authorize(effect: effect,
                      authorization: authorization,
                      currentConsent: currentConsent,
                      now: now)
        let operation = try await begin(operationID: operationID, now: now)
        let result: OrganizationMailTransportResult
        do {
            result = try await transport.restore(routes: routes)
        } catch {
            throw try await transportFailure(operation: operation,
                                              expectedCount: routes.count,
                                              failureCode: "mail-restore-failed",
                                              now: now)
        }
        let completedReceiptValues = result.completedRoutes.compactMap { completedRoute in
            routes.first(where: { $0.current == completedRoute }).map(restoreReceiptValue)
        }
        return try await finish(operation: operation,
                                expectedRoutes: routes.map(\.current),
                                result: result,
                                now: now,
                                completedReceiptValues: completedReceiptValues)
    }

    private func authorize(effect: OrganizationEffect,
                           authorization: OrganizationMailAuthorization?,
                           currentConsent: OrganizationMailAutomationConsent?,
                           now: Date) throws {
        try OrganizationMailAuthorizationPolicy.validate(effect: effect,
                                                         authorization: authorization,
                                                         currentConsent: currentConsent,
                                                         now: now)
    }

    private func validateMove(effect: OrganizationEffect,
                              routes: [OrganizationMailRoute],
                              destination: OrganizationMailDestination) throws {
        guard case .mailbox = destination else {
            throw OrganizationMailGatewayError.invalidDestination
        }
        guard effect.destination == destination else {
            throw OrganizationMailGatewayError.exactDestinationMismatch
        }
        guard effect.messageCount == routes.count,
              !routes.isEmpty,
              sameRoutes(effect.sourceRoutes, routes),
              routes.allSatisfy(\.isExact) else {
            throw OrganizationMailGatewayError.exactRouteMismatch
        }
    }

    private func validateRestore(effect: OrganizationEffect,
                                 routes: [OrganizationMailRestoreRoute]) throws {
        guard !routes.isEmpty,
              effect.messageCount == routes.count,
              routes.allSatisfy(\.isExact),
              sameRoutes(effect.sourceRoutes, routes.map(\.current)) else {
            throw OrganizationMailGatewayError.exactRouteMismatch
        }
        let currentRoutes = routes.map(\.current)
        let destinationRoutes = routes.map(\.destination)
        guard Set(currentRoutes).count == routes.count,
              Set(destinationRoutes).count == routes.count else {
            throw OrganizationMailGatewayError.invalidRestoreRoute
        }

        switch effect.destination {
        case .originalSourceRoutes:
            // Each exact destination is carried in the restore manifest. The
            // authorization discloses that this is an original-route restore;
            // the gateway still refuses any missing or malformed pair.
            return
        case .mailbox(let account, let path):
            guard destinationRoutes.allSatisfy({ $0.account == account && $0.mailboxPath == path }) else {
                throw OrganizationMailGatewayError.exactDestinationMismatch
            }
        default:
            throw OrganizationMailGatewayError.invalidDestination
        }
    }

    private func begin(operationID: String,
                       now: Date) async throws -> OrganizationOperation {
        guard let operation = try await operationStore.operation(id: operationID) else {
            throw OrganizationMailGatewayError.missingOperation
        }
        guard operation.phase == .appApplied
                || operation.phase == .partial
                || operation.phase == .recovery else {
            throw OrganizationMailGatewayError.invalidOperationPhase(operation.phase)
        }
        do {
            return try await operationStore.advance(id: operationID,
                                                    to: .mailApplying,
                                                    at: now)
        } catch {
            throw OrganizationMailGatewayError.ledgerFailureBeforeExternalCall
        }
    }

    private func finish(operation: OrganizationOperation,
                        expectedRoutes: [OrganizationMailRoute],
                        result: OrganizationMailTransportResult,
                        now: Date,
                        completedReceiptValues: [String]? = nil) async throws -> OrganizationMailGatewayOutcome {
        let expected = Set(expectedRoutes)
        let completed = result.completedRoutes
        let completedSet = Set(completed)
        guard completed.count == completedSet.count,
              completedSet.isSubset(of: expected),
              result.createdMailboxPath == nil else {
            _ = try await recover(operation: operation,
                                  expectedCount: expectedRoutes.count,
                                  completedCount: 0,
                                  failureCode: "mail-transport-result-mismatch",
                                  now: now)
            throw OrganizationMailGatewayError.invalidTransportResult
        }

        let completedCount = completed.count
        if completedCount == expectedRoutes.count,
           result.failureCode == nil,
           !result.mayHaveCompleted {
            return try await complete(operation: operation,
                                      expectedCount: expectedRoutes.count,
                                      completedRoutes: completed,
                                      createdMailboxPath: nil,
                                      now: now,
                                      receiptValues: completedReceiptValues)
        }

        let failureCode = result.failureCode ?? "mail-transport-result-partial"
        if completedCount > 0, completedCount < expectedRoutes.count, !result.mayHaveCompleted {
            return try await partial(operation: operation,
                                     expectedCount: expectedRoutes.count,
                                     completedRoutes: completed,
                                     failureCode: failureCode,
                                     now: now,
                                     receiptValues: completedReceiptValues)
        }
        return try await recover(operation: operation,
                                 expectedCount: expectedRoutes.count,
                                 completedCount: completedCount,
                                 failureCode: failureCode,
                                 now: now,
                                 completedRoutes: completed,
                                 receiptValues: completedReceiptValues)
    }

    private func complete(operation: OrganizationOperation,
                          expectedCount: Int,
                          completedRoutes: [OrganizationMailRoute],
                          createdMailboxPath: String?,
                          now: Date,
                          receiptValues: [String]? = nil) async throws -> OrganizationMailGatewayOutcome {
        let receipt = makeReceipt(kind: .mail,
                                  expectedCount: expectedCount,
                                  completedRoutes: completedRoutes,
                                  createdMailboxPath: createdMailboxPath,
                                  date: now,
                                  receiptValues: receiptValues)
        do {
            let updated = try await operationStore.advance(id: operation.id,
                                                            to: .completed,
                                                            receipt: receipt,
                                                            at: now)
            return OrganizationMailGatewayOutcome(operationID: operation.id,
                                                  phase: updated.phase,
                                                  expectedCount: expectedCount,
                                                  completedCount: expectedCount,
                                                  completedRoutes: completedRoutes,
                                                  createdMailboxPath: createdMailboxPath,
                                                  failureCode: nil,
                                                  externalCallStarted: true)
        } catch {
            throw OrganizationMailGatewayError.ledgerFailureAfterExternalCall
        }
    }

    private func partial(operation: OrganizationOperation,
                         expectedCount: Int,
                         completedRoutes: [OrganizationMailRoute],
                         failureCode: String,
                         now: Date,
                         receiptValues: [String]? = nil) async throws -> OrganizationMailGatewayOutcome {
        let receipt = makeReceipt(kind: .mail,
                                  expectedCount: expectedCount,
                                  completedRoutes: completedRoutes,
                                  createdMailboxPath: nil,
                                  date: now,
                                  receiptValues: receiptValues)
        let failure = OrganizationOperationFailure(code: failureCode,
                                                   retryable: true,
                                                   attempt: max(operation.retryCount + 1, 1),
                                                   date: now)
        do {
            let updated = try await operationStore.advance(id: operation.id,
                                                            to: .partial,
                                                            receipt: receipt,
                                                            failure: failure,
                                                            at: now)
            return OrganizationMailGatewayOutcome(operationID: operation.id,
                                                  phase: updated.phase,
                                                  expectedCount: expectedCount,
                                                  completedCount: completedRoutes.count,
                                                  completedRoutes: completedRoutes,
                                                  createdMailboxPath: nil,
                                                  failureCode: failureCode,
                                                  externalCallStarted: true)
        } catch {
            throw OrganizationMailGatewayError.ledgerFailureAfterExternalCall
        }
    }

    private func recover(operation: OrganizationOperation,
                         expectedCount: Int,
                         completedCount: Int,
                         failureCode: String,
                         now: Date,
                         completedRoutes: [OrganizationMailRoute] = [],
                         createdMailboxPath: String? = nil,
                         receiptValues: [String]? = nil) async throws -> OrganizationMailGatewayOutcome {
        let receipt = makeReceipt(kind: .recovery,
                                  expectedCount: expectedCount,
                                  completedRoutes: completedRoutes,
                                  createdMailboxPath: createdMailboxPath,
                                  date: now,
                                  receiptValues: receiptValues)
        let failure = OrganizationOperationFailure(code: failureCode,
                                                   retryable: true,
                                                   attempt: max(operation.retryCount + 1, 1),
                                                   date: now)
        do {
            let updated = try await operationStore.advance(id: operation.id,
                                                            to: .recovery,
                                                            receipt: receipt,
                                                            failure: failure,
                                                            at: now)
            return OrganizationMailGatewayOutcome(operationID: operation.id,
                                                  phase: updated.phase,
                                                  expectedCount: expectedCount,
                                                  completedCount: completedCount,
                                                  completedRoutes: completedRoutes,
                                                  createdMailboxPath: createdMailboxPath,
                                                  failureCode: failureCode,
                                                  externalCallStarted: true)
        } catch {
            throw OrganizationMailGatewayError.ledgerFailureAfterExternalCall
        }
    }

    private func transportFailure(operation: OrganizationOperation,
                                  expectedCount: Int,
                                  failureCode: String,
                                  now: Date) async throws -> OrganizationMailGatewayError {
        _ = try await recover(operation: operation,
                              expectedCount: expectedCount,
                              completedCount: 0,
                              failureCode: failureCode,
                              now: now)
        return .transportFailed
    }

    private func makeReceipt(kind: OrganizationOperationReceiptKind,
                             expectedCount: Int,
                             completedRoutes: [OrganizationMailRoute],
                             createdMailboxPath: String?,
                             date: Date,
                             receiptValues: [String]? = nil) -> OrganizationOperationReceipt {
        var fingerprints = (receiptValues ?? completedRoutes.map(routeReceiptValue)).map(opaqueFingerprint)
        if let createdMailboxPath {
            fingerprints.append(opaqueFingerprint("mailbox|\(createdMailboxPath)"))
        }
        return OrganizationOperationReceipt(kind: kind,
                                            date: date,
                                            expectedCount: expectedCount,
                                            completedCount: completedRoutes.count,
                                            opaqueItemFingerprints: fingerprints)
    }

    private func routeReceiptValue(_ route: OrganizationMailRoute) -> String {
        "route|\(route.messageID)|\(route.account)|\(route.mailboxPath)"
    }

    private func restoreReceiptValue(_ route: OrganizationMailRestoreRoute) -> String {
        "restore|\(routeReceiptValue(route.current))|\(routeReceiptValue(route.destination))"
    }

    private func opaqueFingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func sameRoutes(_ lhs: [OrganizationMailRoute],
                            _ rhs: [OrganizationMailRoute]) -> Bool {
        lhs.count == rhs.count && Set(lhs) == Set(rhs)
    }
}

extension OrganizationMailGateway: OrganizationMailGatewayExecuting {}
