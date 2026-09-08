import Foundation

internal nonisolated enum OrganizationMailAuthorizationSource: String, Codable, Sendable {
    case userConfirmation
    case currentConsent
}

/// The point at which a prepared Mail phase is being reconsidered.
internal nonisolated enum OrganizationMailExecutionPhase: String, Codable, Sendable {
    case preparedNotStarted
    case inFlight
    case receiptPending
    case completed
    case partial
    case recovery
}

internal nonisolated enum OrganizationMailAuthorizationDecision: Equatable, Sendable {
    case allowed
    case blockedBeforeStart
    case allowInFlightToFinish
}

internal nonisolated enum OrganizationMailAuthorizationError: Error, Equatable, Sendable {
    case mailEffectRequired
    case incompleteDisclosure
    case disclosureChanged
    case consentUnavailable
    case consentDoesNotAllow(OrganizationMailAutomationEffect)
    case confirmationFromFuture

    internal var localizationKey: String {
        switch self {
        case .mailEffectRequired:
            return "organization.mail.authorization.error.mail_effect_required"
        case .incompleteDisclosure:
            return "organization.mail.authorization.error.incomplete_disclosure"
        case .disclosureChanged:
            return "organization.mail.authorization.error.disclosure_changed"
        case .consentUnavailable:
            return "organization.mail.authorization.error.consent_unavailable"
        case .consentDoesNotAllow:
            return "organization.mail.authorization.error.effect_not_allowed"
        case .confirmationFromFuture:
            return "organization.mail.authorization.error.confirmation_from_future"
        }
    }
}

/// A non-forgeable snapshot of an explicitly disclosed Mail effect.
///
/// The initializer is private. Callers can obtain a value only through
/// `fromUserConfirmation` or `fromCurrentConsent`; automatic recommendations,
/// Graph modes, mailbox mappings, and refresh callbacks have no construction
/// path that omits disclosure and authorization checks.
internal nonisolated struct OrganizationMailAuthorization: Equatable, Sendable {
    internal let effect: OrganizationEffect
    internal let issuedAt: Date
    internal let source: OrganizationMailAuthorizationSource
    internal let consentSchemaVersion: Int?

    private let requiresCurrentConsent: Bool

    private init(effect: OrganizationEffect,
                 issuedAt: Date,
                 source: OrganizationMailAuthorizationSource,
                 consentSchemaVersion: Int?,
                 requiresCurrentConsent: Bool) {
        self.effect = effect
        self.issuedAt = issuedAt
        self.source = source
        self.consentSchemaVersion = consentSchemaVersion
        self.requiresCurrentConsent = requiresCurrentConsent
    }

    /// Factory for a foreground confirmation that has shown the exact effect.
    internal static func fromUserConfirmation(effect: OrganizationEffect,
                                              confirmedAt: Date = Date(),
                                              now: Date = Date()) throws -> Self {
        try fromUserConfirmation(effect: effect,
                                 disclosedEffect: effect,
                                 confirmedAt: confirmedAt,
                                 now: now)
    }

    /// Variant used when a confirmation surface retains a separately captured
    /// disclosure snapshot. Any change in count, route, destination, or
    /// reversibility invalidates the confirmation rather than being silently
    /// substituted.
    internal static func fromUserConfirmation(effect: OrganizationEffect,
                                              disclosedEffect: OrganizationEffect,
                                              confirmedAt: Date,
                                              now: Date = Date()) throws -> Self {
        guard effect == disclosedEffect else {
            throw OrganizationMailAuthorizationError.disclosureChanged
        }
        try validate(effect: effect)
        guard confirmedAt <= now else {
            throw OrganizationMailAuthorizationError.confirmationFromFuture
        }
        return Self(effect: effect,
                    issuedAt: confirmedAt,
                    source: .userConfirmation,
                    consentSchemaVersion: nil,
                    requiresCurrentConsent: false)
    }

    /// Factory for an explicitly granted current-version automatic consent.
    internal static func fromCurrentConsent(effect: OrganizationEffect,
                                            consent: OrganizationMailAutomationConsent,
                                            now: Date = Date()) throws -> Self {
        try validate(effect: effect)
        guard consent.isCurrent(at: now) else {
            throw OrganizationMailAuthorizationError.consentUnavailable
        }
        for mutation in effect.requiredMailEffects where !consent.allows(mutation, at: now) {
            throw OrganizationMailAuthorizationError.consentDoesNotAllow(mutation)
        }
        return Self(effect: effect,
                    issuedAt: now,
                    source: .currentConsent,
                    consentSchemaVersion: consent.schemaVersion,
                    requiresCurrentConsent: true)
    }

    // Naming aliases make the allowed construction paths obvious at call sites.
    internal static func userConfirmed(effect: OrganizationEffect,
                                       confirmedAt: Date = Date(),
                                       now: Date = Date()) throws -> Self {
        try fromUserConfirmation(effect: effect, confirmedAt: confirmedAt, now: now)
    }

    internal static func authorizedByCurrentConsent(effect: OrganizationEffect,
                                                    consent: OrganizationMailAutomationConsent,
                                                    now: Date = Date()) throws -> Self {
        try fromCurrentConsent(effect: effect, consent: consent, now: now)
    }

    /// Re-check consent immediately before an external call or after a reload.
    /// Revocation blocks prepared work but never causes an already-running
    /// external call to be repeated or cancelled implicitly.
    internal func decision(using currentConsent: OrganizationMailAutomationConsent?,
                          phase: OrganizationMailExecutionPhase,
                          now: Date = Date()) -> OrganizationMailAuthorizationDecision {
        guard requiresCurrentConsent else {
            return .allowed
        }

        let isCurrent = currentConsent?.isCurrent(at: now) == true
            && currentConsent?.allowedEffects.isSuperset(of: effect.requiredMailEffects) == true
        guard !isCurrent else { return .allowed }

        switch phase {
        case .inFlight, .receiptPending:
            return .allowInFlightToFinish
        case .preparedNotStarted, .completed, .partial, .recovery:
            return .blockedBeforeStart
        }
    }

    internal func isAllowed(using currentConsent: OrganizationMailAutomationConsent?,
                            phase: OrganizationMailExecutionPhase,
                            now: Date = Date()) -> Bool {
        decision(using: currentConsent, phase: phase, now: now) == .allowed
    }

    private static func validate(effect: OrganizationEffect) throws {
        guard effect.requiresMailAuthorization else {
            throw OrganizationMailAuthorizationError.mailEffectRequired
        }
        guard effect.hasCompleteMailDisclosure else {
            throw OrganizationMailAuthorizationError.incompleteDisclosure
        }
    }
}
