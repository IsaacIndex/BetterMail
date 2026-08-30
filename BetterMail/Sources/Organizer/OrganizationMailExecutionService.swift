import Foundation

internal nonisolated enum OrganizationMailOperationIdentifier {
    internal static func make(namespace: String, seed: String) -> String {
        "mail:\(OrganizationOpaqueFingerprint.digest(namespace: namespace, rawValue: seed))"
    }

    /// Restore retries must bind their operation identity to the exact current
    /// residual set. A partial restore therefore gets a new durable operation
    /// rather than replaying routes that already completed.
    internal static func makeRestore(namespace: String,
                                     seed: String,
                                     routes: [OrganizationMailRestoreRoute]) -> String {
        let exactResidual = routes.map { route in
            [route.current.messageID,
             route.current.account,
             route.current.mailboxPath,
             route.destination.messageID,
             route.destination.account,
             route.destination.mailboxPath]
                .map(lengthPrefixed)
                .joined(separator: "|")
        }.sorted().joined(separator: "||")
        return make(namespace: namespace,
                    seed: "\(lengthPrefixed(seed))|\(exactResidual)")
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

/// Foreground and automatic callers provide the complete immutable request
/// they disclosed. The execution service owns write-ahead ledger preparation;
/// callers never receive a raw Mail transport.
internal nonisolated struct OrganizationMailMoveExecution: Sendable {
    internal let operationID: String
    internal let kind: OrganizationOperationKind
    internal let effect: OrganizationEffect
    internal let authorization: OrganizationMailAuthorization?
    internal let currentConsent: OrganizationMailAutomationConsent?
    internal let routes: [OrganizationMailRoute]
    internal let destination: OrganizationMailDestination
    internal let now: Date
}

internal nonisolated struct OrganizationMailRestoreExecution: Sendable {
    internal let operationID: String
    internal let kind: OrganizationOperationKind
    internal let effect: OrganizationEffect
    internal let authorization: OrganizationMailAuthorization?
    internal let currentConsent: OrganizationMailAutomationConsent?
    internal let routes: [OrganizationMailRestoreRoute]
    internal let now: Date
}

internal nonisolated struct OrganizationMailboxCreationExecution: Sendable {
    internal let operationID: String
    internal let kind: OrganizationOperationKind
    internal let effect: OrganizationEffect
    internal let authorization: OrganizationMailAuthorization?
    internal let currentConsent: OrganizationMailAutomationConsent?
    internal let now: Date
}

internal nonisolated protocol OrganizationMailExecutionServicing: Sendable {
    func move(_ request: OrganizationMailMoveExecution) async throws -> OrganizationMailGatewayOutcome
    func restore(_ request: OrganizationMailRestoreExecution) async throws -> OrganizationMailGatewayOutcome
    func createMailbox(_ request: OrganizationMailboxCreationExecution) async throws -> OrganizationMailGatewayOutcome
}

internal nonisolated enum OrganizationMailExecutionServiceError: Error, Equatable, Sendable {
    case invalidRequest
    case operationIdentityMismatch
    case operationInFlight
    case operationCannotResume(OrganizationOperationPhase)
    case operationStore(OrganizationOperationStoreError)
}

/// Ledger-preparing boundary shared by every production Apple Mail mutation.
/// Authorization is checked before any durable preparation and again inside
/// `OrganizationMailGateway` immediately before the external transport call.
internal actor OrganizationMailExecutionService: OrganizationMailExecutionServicing {
    internal static let shared = OrganizationMailExecutionService(operationStore: .shared)

    private struct RouteManifest: Codable, Sendable {
        let schemaVersion: Int
        let effect: OrganizationEffect
        let moveRoutes: [OrganizationMailRoute]
        let restoreRoutes: [OrganizationMailRestoreRoute]
        let destination: OrganizationMailDestination?
    }

    private let operationStore: OrganizationOperationStore
    private let gateway: any OrganizationMailGatewayExecuting
    private let metricsRecorder: OrganizerMetricsRecorder?

    internal init(operationStore: OrganizationOperationStore,
                  transport: any OrganizationMailGatewayTransport = DefaultOrganizationMailGatewayTransport(),
                  metricsRecorder: OrganizerMetricsRecorder? = nil) {
        self.operationStore = operationStore
        self.gateway = OrganizationMailGateway(transport: transport,
                                               operationStore: operationStore)
        self.metricsRecorder = metricsRecorder
    }

    internal init(operationStore: OrganizationOperationStore,
                  gateway: any OrganizationMailGatewayExecuting,
                  metricsRecorder: OrganizerMetricsRecorder? = nil) {
        self.operationStore = operationStore
        self.gateway = gateway
        self.metricsRecorder = metricsRecorder
    }

    internal func move(_ request: OrganizationMailMoveExecution) async throws -> OrganizationMailGatewayOutcome {
        do {
            try await validateAuthorization(effect: request.effect,
                                            authorization: request.authorization,
                                            currentConsent: request.currentConsent,
                                            now: request.now)
            let outcome = try await performMove(request)
            await recordMailResult(outcome: outcome,
                                   messageCount: request.effect.messageCount)
            return outcome
        } catch {
            await recordMailResult(outcome: nil,
                                   messageCount: request.effect.messageCount)
            throw error
        }
    }

    private func performMove(_ request: OrganizationMailMoveExecution) async throws -> OrganizationMailGatewayOutcome {
        guard request.effect.mailMutations == [.messageMove],
              case .mailbox = request.destination,
              request.effect.destination == request.destination.normalized,
              request.effect.messageCount == request.routes.count,
              !request.routes.isEmpty,
              Set(request.effect.sourceRoutes) == Set(request.routes),
              request.effect.sourceRoutes.count == request.routes.count,
              request.routes.allSatisfy(\.isExact) else {
            throw OrganizationMailExecutionServiceError.invalidRequest
        }

        if let replay = try await prepareIfNeeded(operationID: request.operationID,
                                                  kind: request.kind,
                                                  effect: request.effect,
                                                  authorization: request.authorization,
                                                  moveRoutes: request.routes,
                                                  restoreRoutes: [],
                                                  destination: request.destination,
                                                  now: request.now) {
            return replay
        }
        return try await gateway.move(operationID: request.operationID,
                                      effect: request.effect,
                                      authorization: request.authorization,
                                      routes: request.routes,
                                      destination: request.destination,
                                      currentConsent: request.currentConsent,
                                      now: request.now)
    }

    internal func restore(_ request: OrganizationMailRestoreExecution) async throws -> OrganizationMailGatewayOutcome {
        do {
            try await validateAuthorization(effect: request.effect,
                                            authorization: request.authorization,
                                            currentConsent: request.currentConsent,
                                            now: request.now)
            let outcome = try await performRestore(request)
            await recordMailResult(outcome: outcome,
                                   messageCount: request.effect.messageCount)
            return outcome
        } catch {
            await recordMailResult(outcome: nil,
                                   messageCount: request.effect.messageCount)
            throw error
        }
    }

    private func performRestore(_ request: OrganizationMailRestoreExecution) async throws -> OrganizationMailGatewayOutcome {
        guard request.effect.mailMutations == [.messageRestore],
              request.effect.messageCount == request.routes.count,
              !request.routes.isEmpty,
              request.routes.allSatisfy(\.isExact),
              Set(request.effect.sourceRoutes) == Set(request.routes.map(\.current)),
              request.effect.sourceRoutes.count == request.routes.count else {
            throw OrganizationMailExecutionServiceError.invalidRequest
        }
        switch request.effect.destination {
        case .originalSourceRoutes:
            break
        case .mailbox(let account, let path):
            guard request.routes.allSatisfy({
                $0.destination.account == account && $0.destination.mailboxPath == path
            }) else {
                throw OrganizationMailExecutionServiceError.invalidRequest
            }
        default:
            throw OrganizationMailExecutionServiceError.invalidRequest
        }

        if let replay = try await prepareIfNeeded(operationID: request.operationID,
                                                  kind: request.kind,
                                                  effect: request.effect,
                                                  authorization: request.authorization,
                                                  moveRoutes: [],
                                                  restoreRoutes: request.routes,
                                                  destination: request.effect.destination,
                                                  now: request.now) {
            return replay
        }
        return try await gateway.restore(operationID: request.operationID,
                                         effect: request.effect,
                                         authorization: request.authorization,
                                         routes: request.routes,
                                         currentConsent: request.currentConsent,
                                         now: request.now)
    }

    internal func createMailbox(_ request: OrganizationMailboxCreationExecution) async throws -> OrganizationMailGatewayOutcome {
        do {
            try await validateAuthorization(effect: request.effect,
                                            authorization: request.authorization,
                                            currentConsent: request.currentConsent,
                                            now: request.now)
            let outcome = try await performCreateMailbox(request)
            await recordMailResult(outcome: outcome, messageCount: 1)
            return outcome
        } catch {
            await recordMailResult(outcome: nil, messageCount: 1)
            throw error
        }
    }

    private func performCreateMailbox(_ request: OrganizationMailboxCreationExecution) async throws -> OrganizationMailGatewayOutcome {
        guard request.effect.mailMutations == [.mailboxCreation],
              request.effect.messageCount == 0,
              request.effect.sourceRoutes.isEmpty,
              case .newMailbox = request.effect.destination else {
            throw OrganizationMailExecutionServiceError.invalidRequest
        }

        if let replay = try await prepareIfNeeded(operationID: request.operationID,
                                                  kind: request.kind,
                                                  effect: request.effect,
                                                  authorization: request.authorization,
                                                  moveRoutes: [],
                                                  restoreRoutes: [],
                                                  destination: request.effect.destination,
                                                  now: request.now) {
            return replay
        }
        return try await gateway.createMailbox(operationID: request.operationID,
                                               effect: request.effect,
                                               authorization: request.authorization,
                                               currentConsent: request.currentConsent,
                                               now: request.now)
    }

    private func validateAuthorization(
        effect: OrganizationEffect,
        authorization: OrganizationMailAuthorization?,
        currentConsent: OrganizationMailAutomationConsent?,
        now: Date
    ) async throws {
        do {
            try OrganizationMailAuthorizationPolicy.validate(effect: effect,
                                                             authorization: authorization,
                                                             currentConsent: currentConsent,
                                                             now: now)
            await metricsRecorder?.recordEvent(.mailAuthorization,
                                               count: max(effect.messageCount, 1),
                                               status: .success)
        } catch {
            await metricsRecorder?.recordEvent(.mailAuthorization,
                                               count: max(effect.messageCount, 1),
                                               status: .failure)
            throw error
        }
    }

    private func recordMailResult(outcome: OrganizationMailGatewayOutcome?,
                                  messageCount: Int) async {
        if let outcome,
           outcome.phase == .completed,
           !outcome.externalCallStarted {
            return
        }
        let status: OrganizerMetricOutcome = outcome?.phase == .completed ? .success : .failure
        await metricsRecorder?.recordEvent(.mailResult,
                                           count: max(messageCount, 1),
                                           status: status,
                                           failureReason: status == .failure ? .actionFailure : nil,
                                           externalMailCallCount: outcome?.externalCallStarted == true ? 1 : 0)
    }

    /// Returns a completed replay when no external call is needed; otherwise
    /// leaves the operation in an allowed gateway start phase.
    private func prepareIfNeeded(operationID rawOperationID: String,
                                 kind: OrganizationOperationKind,
                                 effect: OrganizationEffect,
                                 authorization: OrganizationMailAuthorization?,
                                 moveRoutes: [OrganizationMailRoute],
                                 restoreRoutes: [OrganizationMailRestoreRoute],
                                 destination: OrganizationMailDestination?,
                                 now: Date) async throws -> OrganizationMailGatewayOutcome? {
        let operationID = rawOperationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operationID.isEmpty, let authorization else {
            throw OrganizationMailExecutionServiceError.invalidRequest
        }

        let manifest = RouteManifest(schemaVersion: 1,
                                     effect: effect,
                                     moveRoutes: moveRoutes,
                                     restoreRoutes: restoreRoutes,
                                     destination: destination)
        let payload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            payload = try encoder.encode(manifest)
        } catch {
            throw OrganizationMailExecutionServiceError.invalidRequest
        }

        let identity = operationIdentity(kind: kind,
                                         effect: effect,
                                         authorization: authorization,
                                         moveRoutes: moveRoutes,
                                         restoreRoutes: restoreRoutes,
                                         destination: destination)

        let existing: OrganizationOperation?
        do {
            existing = try await operationStore.operation(id: operationID)
        } catch let error as OrganizationOperationStoreError {
            throw OrganizationMailExecutionServiceError.operationStore(error)
        }

        if let existing {
            guard operationMatches(existing, identity: identity) else {
                throw OrganizationMailExecutionServiceError.operationIdentityMismatch
            }
            switch existing.phase {
            case .prepared:
                _ = try await advanceToAppApplied(operationID: operationID,
                                                  expectedCount: effect.messageCount,
                                                  fingerprints: identity.sourceFingerprints,
                                                  now: now)
                return nil
            case .appApplied:
                return nil
            case .partial, .recovery:
                // A partial receipt may already represent externally completed
                // routes, while recovery can mean the external outcome is
                // unknown. Replaying the original manifest could duplicate a
                // Mail mutation. Callers must create a new operation bound to
                // the exact known residual set after explicit review.
                throw OrganizationMailExecutionServiceError.operationCannotResume(existing.phase)
            case .mailApplying:
                throw OrganizationMailExecutionServiceError.operationInFlight
            case .completed:
                return OrganizationMailGatewayOutcome(
                    operationID: operationID,
                    phase: .completed,
                    expectedCount: effect.messageCount,
                    completedCount: effect.messageCount,
                    completedRoutes: moveRoutes.isEmpty ? restoreRoutes.map(\.current) : moveRoutes,
                    createdMailboxPath: effect.mailMutations == [.mailboxCreation]
                        ? destination?.path
                        : nil,
                    failureCode: nil,
                    externalCallStarted: false
                )
            case .layoutPending, .undone:
                throw OrganizationMailExecutionServiceError.operationCannotResume(existing.phase)
            }
        }

        let operation = OrganizationOperation(
            id: operationID,
            kind: kind,
            opaqueSourceFingerprints: identity.sourceFingerprints,
            opaqueTargetFingerprints: identity.targetFingerprints,
            betterMailDelta: OrganizationBetterMailDelta(formatIdentifier: "organization-mail-v1",
                                                         before: Data(),
                                                         after: Data()),
            authorizationReference: identity.authorizationReference,
            createdAt: now
        )
        do {
            _ = try await operationStore.prepare(operation, mailRoutePayload: payload)
            _ = try await advanceToAppApplied(operationID: operationID,
                                              expectedCount: effect.messageCount,
                                              fingerprints: identity.sourceFingerprints,
                                              now: now)
        } catch let error as OrganizationOperationStoreError {
            throw OrganizationMailExecutionServiceError.operationStore(error)
        }
        return nil
    }

    private func advanceToAppApplied(operationID: String,
                                     expectedCount: Int,
                                     fingerprints: [String],
                                     now: Date) async throws -> OrganizationOperation {
        try await operationStore.advance(
            id: operationID,
            to: .appApplied,
            receipt: OrganizationOperationReceipt(kind: .appApplied,
                                                   date: now,
                                                   expectedCount: expectedCount,
                                                   completedCount: expectedCount,
                                                   opaqueItemFingerprints: fingerprints),
            at: now
        )
    }

    private struct OperationIdentity {
        let kind: OrganizationOperationKind
        let sourceFingerprints: [String]
        let targetFingerprints: [String]
        let authorizationReference: OrganizationAuthorizationReference
    }

    private func operationIdentity(kind: OrganizationOperationKind,
                                   effect: OrganizationEffect,
                                   authorization: OrganizationMailAuthorization,
                                   moveRoutes: [OrganizationMailRoute],
                                   restoreRoutes: [OrganizationMailRestoreRoute],
                                   destination: OrganizationMailDestination?) -> OperationIdentity {
        let sourceValues: [String]
        if !restoreRoutes.isEmpty {
            sourceValues = restoreRoutes.map {
                "\(routeValue($0.current))|\(routeValue($0.destination))"
            }
        } else {
            sourceValues = moveRoutes.map(routeValue)
        }
        let sourceFingerprints = sourceValues.map {
            OrganizationOpaqueFingerprint.digest(namespace: "mail-source", rawValue: $0)
        }.sorted()
        let destinationValue = destination.map(Self.destinationValue) ?? "none"
        let targetFingerprints = [OrganizationOpaqueFingerprint.digest(namespace: "mail-target",
                                                                       rawValue: destinationValue)]
        let disclosureFingerprint = OrganizationOpaqueFingerprint.digest(
            namespace: "mail-disclosure",
            rawValue: effectValue(effect)
        )
        let authorizationID = OrganizationOpaqueFingerprint.digest(
            namespace: "mail-authorization",
            rawValue: "\(authorization.source.rawValue)|\(authorization.issuedAt.timeIntervalSince1970)|\(disclosureFingerprint)"
        )
        let reference = OrganizationAuthorizationReference(
            authorizationID: authorizationID,
            consentSchemaVersion: authorization.consentSchemaVersion ?? 0,
            effect: operationEffect(effect),
            issuedAt: authorization.issuedAt,
            disclosureFingerprint: disclosureFingerprint
        )
        return OperationIdentity(kind: kind,
                                 sourceFingerprints: sourceFingerprints,
                                 targetFingerprints: targetFingerprints,
                                 authorizationReference: reference)
    }

    private func operationMatches(_ operation: OrganizationOperation,
                                  identity: OperationIdentity) -> Bool {
        operation.kind == identity.kind
            && operation.opaqueSourceFingerprints == identity.sourceFingerprints
            && operation.opaqueTargetFingerprints == identity.targetFingerprints
            && operation.authorizationReference?.effect == identity.authorizationReference.effect
            && operation.authorizationReference?.disclosureFingerprint
                == identity.authorizationReference.disclosureFingerprint
    }

    private func routeValue(_ route: OrganizationMailRoute) -> String {
        "\(route.messageID)|\(route.account)|\(route.mailboxPath)"
    }

    private func effectValue(_ effect: OrganizationEffect) -> String {
        let routes = effect.sourceRoutes.map(routeValue).sorted().joined(separator: "|")
        return [
            effect.operation.rawValue,
            effect.betterMailChange.rawValue,
            effect.mailMutations.map(\.rawValue).sorted().joined(separator: ","),
            String(effect.messageCount),
            routes,
            effect.destination.map(Self.destinationValue) ?? "none",
            effect.reversibility.rawValue
        ].joined(separator: "|")
    }

    private static func destinationValue(_ destination: OrganizationMailDestination) -> String {
        switch destination {
        case .mailbox(let account, let path):
            return "mailbox|\(account)|\(path)"
        case .newMailbox(let account, let path):
            return "newMailbox|\(account)|\(path)"
        case .originalSourceRoutes:
            return "originalSourceRoutes"
        case .none:
            return "none"
        }
    }

    private func operationEffect(_ effect: OrganizationEffect) -> OrganizationOperationEffect {
        switch effect.category {
        case .betterMailOnly:
            return .betterMailOnly
        case .mixed:
            return .mixed
        case .appleMailChanging:
            if effect.mailMutations == [.mailboxCreation] { return .mailboxCreation }
            if effect.mailMutations == [.messageRestore] { return .restore }
            return .messageMove
        }
    }
}
