import XCTest
@testable import BetterMail

final class OrganizationSafetyContractTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OrganizationSafetyContractTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_effectDescriptor_isLocalizedReadyAndPreservesExactDisclosure() throws {
        let effect = makeMoveEffect()

        XCTAssertEqual(effect.category, .appleMailChanging)
        XCTAssertTrue(effect.requiresMailAuthorization)
        XCTAssertTrue(effect.hasCompleteMailDisclosure)
        XCTAssertEqual(effect.messageCount, 2)
        XCTAssertEqual(effect.sourceRoutes.count, 2)
        XCTAssertEqual(effect.sourceRoutes[0].messageID, "<A>")
        XCTAssertEqual(effect.sourceRoutes[0].account, "Work")
        XCTAssertEqual(effect.sourceRoutes[0].mailboxPath, "Inbox")
        XCTAssertEqual(effect.destination,
                       .mailbox(account: "Work", path: "Projects/Acme"))
        XCTAssertEqual(effect.reversibility, .conditionallyReversible)
        XCTAssertEqual(effect.localization.titleKey,
                       "organization.effect.messageMove.title")
        XCTAssertTrue(effect.localization.argumentKeys.contains("sourceRoutes"))
        XCTAssertTrue(effect.localization.argumentKeys.contains("reversibility"))
    }

    func test_effectDescriptor_groupsExactSourceRoutesWithoutExposingMessageIDs() {
        let routes = [
            OrganizationMailRoute(messageID: "message-b", account: "Work", mailboxPath: "Inbox"),
            OrganizationMailRoute(messageID: "message-a", account: "Work", mailboxPath: "Inbox"),
            OrganizationMailRoute(messageID: "message-c", account: "Work", mailboxPath: "Archive"),
            OrganizationMailRoute(messageID: "message-d", account: "Personal", mailboxPath: "Inbox")
        ]
        let effect = OrganizationEffect.appleMail(
            operation: .messageMove,
            mutation: .messageMove,
            messageCount: routes.count,
            sourceRoutes: routes,
            destination: .mailbox(account: "Work", path: "Filed"),
            reversibility: .conditionallyReversible
        )

        XCTAssertEqual(effect.sourceRouteGroups, [
            OrganizationMailRouteGroup(account: "Personal", mailboxPath: "Inbox", messageCount: 1),
            OrganizationMailRouteGroup(account: "Work", mailboxPath: "Archive", messageCount: 1),
            OrganizationMailRouteGroup(account: "Work", mailboxPath: "Inbox", messageCount: 2)
        ])
        XCTAssertFalse(effect.sourceRouteGroups.map(\.id).joined().contains("message-a"))
        XCTAssertEqual(effect.reversibility.localizationKey,
                       "organization.effect.reversibility.conditionallyReversible")
    }

    func test_userConfirmation_requiresMailAndUnchangedDisclosure() throws {
        let appOnly = OrganizationEffect.betterMailOnly(operation: .graphArchive,
                                                         change: .graphArchive)
        XCTAssertThrowsError(try OrganizationMailAuthorization.fromUserConfirmation(effect: appOnly)) { error in
            XCTAssertEqual(error as? OrganizationMailAuthorizationError, .mailEffectRequired)
        }

        let effect = makeMoveEffect()
        var changed = effect
        changed = OrganizationEffect(operation: effect.operation,
                                     mailMutations: effect.mailMutations,
                                     messageCount: effect.messageCount + 1,
                                     sourceRoutes: effect.sourceRoutes,
                                     destination: effect.destination,
                                     reversibility: effect.reversibility)
        XCTAssertThrowsError(try OrganizationMailAuthorization.fromUserConfirmation(effect: effect,
                                                                                       disclosedEffect: changed,
                                                                                       confirmedAt: Date())) { error in
            XCTAssertEqual(error as? OrganizationMailAuthorizationError, .disclosureChanged)
        }

        let incomplete = OrganizationEffect(operation: .messageMove,
                                            mailMutations: [.messageMove],
                                            messageCount: 1,
                                            sourceRoutes: [],
                                            destination: .mailbox(account: "work", path: "projects/acme"),
                                            reversibility: .fullyReversible)
        XCTAssertThrowsError(try OrganizationMailAuthorization.fromUserConfirmation(effect: incomplete)) { error in
            XCTAssertEqual(error as? OrganizationMailAuthorizationError, .incompleteDisclosure)
        }
    }

    func test_currentConsent_requiresCurrentVersionAndAllowedEffect() throws {
        let moveEffect = makeMoveEffect()
        let newUser = OrganizationMailAutomationConsent.newUser
        XCTAssertThrowsError(try OrganizationMailAuthorization.fromCurrentConsent(effect: moveEffect,
                                                                                    consent: newUser)) { error in
            XCTAssertEqual(error as? OrganizationMailAuthorizationError, .consentUnavailable)
        }

        let consent = OrganizationMailAutomationConsent.userGranted(
            at: Date(timeIntervalSince1970: 10),
            allowedEffects: [.messageMove]
        )
        let authorization = try OrganizationMailAuthorization.fromCurrentConsent(
            effect: moveEffect,
            consent: consent,
            now: Date(timeIntervalSince1970: 11)
        )
        XCTAssertEqual(authorization.source, .currentConsent)
        XCTAssertEqual(authorization.consentSchemaVersion,
                       OrganizationMailAutomationConsent.currentSchemaVersion)

        let mailboxEffect = OrganizationEffect.appleMail(operation: .mailboxCreation,
                                                         mutation: .mailboxCreation,
                                                         messageCount: 0,
                                                         sourceRoutes: [],
                                                         destination: .newMailbox(account: "work",
                                                                                  path: "projects/new"),
                                                         reversibility: .notReversible)
        XCTAssertThrowsError(try OrganizationMailAuthorization.fromCurrentConsent(effect: mailboxEffect,
                                                                                    consent: consent)) { error in
            XCTAssertEqual(error as? OrganizationMailAuthorizationError,
                           .consentDoesNotAllow(.mailboxCreation))
        }

        let futureConsent = OrganizationMailAutomationConsent.userGranted(
            at: Date(timeIntervalSince1970: 100),
            allowedEffects: [.messageMove]
        )
        XCTAssertThrowsError(try OrganizationMailAuthorization.fromCurrentConsent(effect: moveEffect,
                                                                                    consent: futureConsent,
                                                                                    now: Date(timeIntervalSince1970: 99))) { error in
            XCTAssertEqual(error as? OrganizationMailAuthorizationError, .consentUnavailable)
        }
    }

    func test_consentResolution_failsClosedForAbsentLegacyUnknownAndRevoked() throws {
        XCTAssertEqual(OrganizationMailAutomationConsent.resolve(from: defaults).status, .absent)

        defaults.set("old automatic setting", forKey: OrganizationMailAutomationConsent.storageKey)
        XCTAssertEqual(OrganizationMailAutomationConsent.resolve(from: defaults).status, .legacy)

        let unknownPayload = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": OrganizationMailAutomationConsent.currentSchemaVersion + 1,
            "enabled": true,
            "grantedAt": "2026-08-24T00:00:00Z",
            "allowedEffects": ["messageMove"]
        ])
        defaults.set(unknownPayload, forKey: OrganizationMailAutomationConsent.storageKey)
        XCTAssertEqual(OrganizationMailAutomationConsent.resolve(from: defaults).status,
                       .unknownSchema(version: OrganizationMailAutomationConsent.currentSchemaVersion + 1))

        let revoked = OrganizationMailAutomationConsent.revoked(at: Date())
        try revoked.save(to: defaults)
        let resolution = OrganizationMailAutomationConsent.resolve(from: defaults)
        XCTAssertEqual(resolution.status, .revoked)
        XCTAssertFalse(resolution.permitsMailAutomation)
        XCTAssertNil(OrganizationMailAutomationConsent.load(from: defaults))
    }

    func test_consentRoundTrip_keepsSeparateCurrentSchema() throws {
        let consent = OrganizationMailAutomationConsent.userGranted(
            at: Date(timeIntervalSince1970: 20),
            allowedEffects: [.messageMove, .messageRestore]
        )
        try consent.save(to: defaults)

        let loaded = try XCTUnwrap(OrganizationMailAutomationConsent.load(
            from: defaults,
            now: Date(timeIntervalSince1970: 21)
        ))
        XCTAssertEqual(loaded, consent)
        XCTAssertEqual(loaded.schemaVersion,
                       OrganizationMailAutomationConsent.currentSchemaVersion)
        XCTAssertTrue(loaded.enabled)
        XCTAssertEqual(loaded.allowedEffects,
                       [.messageMove, .messageRestore])
    }

    @MainActor
    func test_consentSettings_requiresExplicitGrantAndRevokesWithoutMigratingGraphModes() throws {
        defaults.set(GraphAutomationMode.automatic.rawValue,
                     forKey: "graphAutomationAttachMode")
        let settings = OrganizationMailAutomationConsentSettings(
            userDefaults: defaults,
            now: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(settings.resolution.status, .absent)
        XCTAssertTrue(settings.allowedEffects.isEmpty)

        try settings.grant(allowedEffects: [.messageMove, .messageRestore],
                           at: Date(timeIntervalSince1970: 21))
        XCTAssertEqual(settings.resolution.status, .current)
        XCTAssertEqual(settings.allowedEffects, [.messageMove, .messageRestore])
        XCTAssertEqual(defaults.string(forKey: "graphAutomationAttachMode"),
                       GraphAutomationMode.automatic.rawValue)

        try settings.revoke(at: Date(timeIntervalSince1970: 22))
        XCTAssertEqual(settings.resolution.status, .revoked)
        XCTAssertTrue(settings.allowedEffects.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "graphAutomationAttachMode"),
                       GraphAutomationMode.automatic.rawValue)
    }

    func test_revocation_blocksPreparedButAllowsInFlightReceipt() throws {
        let consent = OrganizationMailAutomationConsent.userGranted(
            at: Date(timeIntervalSince1970: 10),
            allowedEffects: [.messageMove]
        )
        let authorization = try OrganizationMailAuthorization.fromCurrentConsent(
            effect: makeMoveEffect(),
            consent: consent,
            now: Date(timeIntervalSince1970: 11)
        )
        let revoked = OrganizationMailAutomationConsent.revoked(at: Date(timeIntervalSince1970: 12))

        XCTAssertEqual(authorization.decision(using: revoked,
                                              phase: .preparedNotStarted,
                                              now: Date(timeIntervalSince1970: 13)),
                       .blockedBeforeStart)
        XCTAssertEqual(authorization.decision(using: revoked,
                                              phase: .inFlight,
                                              now: Date(timeIntervalSince1970: 13)),
                       .allowInFlightToFinish)
        XCTAssertFalse(authorization.isAllowed(using: revoked,
                                                phase: .preparedNotStarted,
                                                now: Date(timeIntervalSince1970: 13)))
    }

    func test_userConfirmation_isIndependentOfAutomationConsentRevocation() throws {
        let authorization = try OrganizationMailAuthorization.fromUserConfirmation(
            effect: makeMoveEffect(),
            confirmedAt: Date(timeIntervalSince1970: 10),
            now: Date(timeIntervalSince1970: 11)
        )
        XCTAssertEqual(authorization.decision(using: OrganizationMailAutomationConsent.revoked(),
                                              phase: .preparedNotStarted),
                       .allowed)
    }

    private func makeMoveEffect() -> OrganizationEffect {
        OrganizationEffect.appleMail(operation: .messageMove,
                                      mutation: .messageMove,
                                      messageCount: 2,
                                      sourceRoutes: [
                                          OrganizationMailRoute(messageID: "<A>",
                                                                account: "Work",
                                                                mailboxPath: "Inbox"),
                                          OrganizationMailRoute(messageID: "<B>",
                                                                account: "Work",
                                                                mailboxPath: "Inbox")
                                      ],
                                      destination: .mailbox(account: "Work",
                                                            path: "Projects/Acme"),
                                      reversibility: .conditionallyReversible)
    }
}
