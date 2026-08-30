import Combine
import Foundation

/// The independently consentable classes of physical Apple Mail work.
internal typealias OrganizationMailAutomationEffect = OrganizationMailMutation

internal nonisolated enum OrganizationMailAutomationConsentStatus: Equatable, Sendable {
    case absent
    case legacy
    case malformed
    case unknownSchema(version: Int)
    case disabled
    case revoked
    case current

    internal var localizationKey: String {
        switch self {
        case .absent: "organization.mail.consent.status.absent"
        case .legacy: "organization.mail.consent.status.legacy"
        case .malformed: "organization.mail.consent.status.malformed"
        case .unknownSchema: "organization.mail.consent.status.unknown"
        case .disabled: "organization.mail.consent.status.disabled"
        case .revoked: "organization.mail.consent.status.revoked"
        case .current: "organization.mail.consent.status.current"
        }
    }
}

/// Observable settings boundary for the separate Apple Mail automation
/// consent record. Existing Graph Automation modes are never migrated into
/// this record; only an explicit grant from the consent UI can enable it.
@MainActor
internal final class OrganizationMailAutomationConsentSettings: ObservableObject {
    @Published internal private(set) var resolution: OrganizationMailAutomationConsentResolution

    private let userDefaults: UserDefaults

    internal init(userDefaults: UserDefaults = .standard, now: Date = Date()) {
        self.userDefaults = userDefaults
        resolution = OrganizationMailAutomationConsent.resolve(from: userDefaults, now: now)
    }

    internal var allowedEffects: Set<OrganizationMailAutomationEffect> {
        guard case .current(let consent) = resolution else { return [] }
        return consent.allowedEffects
    }

    internal func reload(now: Date = Date()) {
        resolution = OrganizationMailAutomationConsent.resolve(from: userDefaults, now: now)
    }

    internal func grant(allowedEffects: Set<OrganizationMailAutomationEffect>,
                        at date: Date = Date()) throws {
        let consent = OrganizationMailAutomationConsent.userGranted(
            at: date,
            allowedEffects: allowedEffects
        )
        try consent.save(to: userDefaults)
        reload(now: date)
    }

    internal func revoke(at date: Date = Date()) throws {
        try OrganizationMailAutomationConsent.revoked(at: date).save(to: userDefaults)
        reload(now: date)
    }
}

internal nonisolated enum OrganizationMailAutomationConsentResolution: Equatable, Sendable {
    case absent
    case legacy
    case malformed
    case unknownSchema(version: Int)
    case disabled(OrganizationMailAutomationConsent)
    case revoked(OrganizationMailAutomationConsent)
    case current(OrganizationMailAutomationConsent)

    internal var consent: OrganizationMailAutomationConsent? {
        switch self {
        case .disabled(let consent), .revoked(let consent), .current(let consent):
            return consent
        case .absent, .legacy, .malformed, .unknownSchema:
            return nil
        }
    }

    internal var status: OrganizationMailAutomationConsentStatus {
        switch self {
        case .absent: return .absent
        case .legacy: return .legacy
        case .malformed: return .malformed
        case .unknownSchema(let version): return .unknownSchema(version: version)
        case .disabled: return .disabled
        case .revoked: return .revoked
        case .current: return .current
        }
    }

    internal var permitsMailAutomation: Bool {
        permitsMailAutomation(at: Date())
    }

    internal func permitsMailAutomation(at now: Date = Date()) -> Bool {
        guard case .current(let consent) = self else { return false }
        return consent.isCurrent(at: now)
    }
}

/// Versioned, separate consent for automatic physical Apple Mail work.
///
/// Existing Graph Automation modes and mailbox mappings are deliberately not
/// read here. A missing, legacy, unknown, disabled, or revoked record fails
/// closed. New users therefore begin with BetterMail organization available but
/// automatic Mail mutation disabled.
internal nonisolated struct OrganizationMailAutomationConsent: Codable, Equatable, Sendable {
    internal static let currentSchemaVersion = 1
    internal static let storageKey = "organization.mail.automation.consent"

    internal let schemaVersion: Int
    internal let enabled: Bool
    internal let grantedAt: Date?
    internal let allowedEffects: Set<OrganizationMailAutomationEffect>

    private init(schemaVersion: Int,
                 enabled: Bool,
                 grantedAt: Date?,
                 allowedEffects: Set<OrganizationMailAutomationEffect>) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.grantedAt = grantedAt
        self.allowedEffects = allowedEffects
    }

    /// Safe default for a new installation.
    internal static var newUser: Self {
        Self(schemaVersion: currentSchemaVersion,
             enabled: false,
             grantedAt: nil,
             allowedEffects: [])
    }

    /// The only normal way to create enabled automatic Mail consent.
    internal static func userGranted(at date: Date = Date(),
                                     allowedEffects: Set<OrganizationMailAutomationEffect>) -> Self {
        let trimmedDate = date
        guard !allowedEffects.isEmpty else { return newUser }
        return Self(schemaVersion: currentSchemaVersion,
                    enabled: true,
                    grantedAt: trimmedDate,
                    allowedEffects: allowedEffects)
    }

    /// Revocation preserves a timestamp so it can be distinguished from a
    /// never-configured new-user default without expanding the stored schema.
    internal static func revoked(at date: Date = Date()) -> Self {
        Self(schemaVersion: currentSchemaVersion,
             enabled: false,
             grantedAt: date,
             allowedEffects: [])
    }

    internal var status: OrganizationMailAutomationConsentStatus {
        guard schemaVersion == Self.currentSchemaVersion else {
            return .unknownSchema(version: schemaVersion)
        }
        if enabled && grantedAt != nil && !allowedEffects.isEmpty {
            return .current
        }
        if !enabled && grantedAt != nil {
            return .revoked
        }
        return .disabled
    }

    /// Current means current schema, enabled, granted, and not from the future.
    /// Consent has no implicit expiry; revocation is explicit and fail-closed.
    internal func isCurrent(at now: Date = Date()) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              enabled,
              !allowedEffects.isEmpty,
              let grantedAt else {
            return false
        }
        return grantedAt <= now
    }

    internal func allows(_ effect: OrganizationMailAutomationEffect,
                         at now: Date = Date()) -> Bool {
        isCurrent(at: now) && allowedEffects.contains(effect)
    }

    /// Persist only the separate consent record. Existing automation settings
    /// are intentionally left untouched and cannot be upgraded into consent.
    internal func save(to userDefaults: UserDefaults) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        userDefaults.set(try encoder.encode(self), forKey: Self.storageKey)
    }

    /// Returns a current consent only. All unsafe states resolve to nil.
    internal static func load(from userDefaults: UserDefaults,
                              now: Date = Date()) -> Self? {
        guard case .current(let consent) = resolve(from: userDefaults),
              consent.isCurrent(at: now) else {
            return nil
        }
        return consent
    }

    internal static func resolve(from userDefaults: UserDefaults,
                                 now: Date = Date()) -> OrganizationMailAutomationConsentResolution {
        guard let storedObject = userDefaults.object(forKey: Self.storageKey) else {
            return .absent
        }

        guard let data = userDefaults.data(forKey: Self.storageKey) else {
            return .legacy
        }

        // Inspect the schema before decoding the full payload so a future
        // version cannot accidentally be treated as the current model.
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any],
           let rawVersion = dictionary["schemaVersion"] as? NSNumber {
            let version = rawVersion.intValue
            guard version == Self.currentSchemaVersion else {
                return .unknownSchema(version: version)
            }
        } else if storedObject is Data {
            return .malformed
        } else {
            return .legacy
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let consent = try? decoder.decode(Self.self, from: data) else {
            return .malformed
        }

        switch consent.status {
        case .current:
            return consent.isCurrent(at: now) ? .current(consent) : .disabled(consent)
        case .revoked:
            return .revoked(consent)
        case .disabled, .unknownSchema:
            return .disabled(consent)
        case .absent, .legacy, .malformed:
            return .malformed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabled
        case grantedAt
        case allowedEffects
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
                  enabled: try container.decode(Bool.self, forKey: .enabled),
                  grantedAt: try container.decodeIfPresent(Date.self, forKey: .grantedAt),
                  allowedEffects: try container.decode(Set<OrganizationMailAutomationEffect>.self,
                                                       forKey: .allowedEffects))
    }
}
