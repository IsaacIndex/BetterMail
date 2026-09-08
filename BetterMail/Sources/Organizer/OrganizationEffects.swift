import CryptoKit
import Foundation

internal nonisolated enum OrganizationOpaqueFingerprint {
    internal static func digest(namespace: String, rawValue: String) -> String {
        let normalizedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Data("organization-v1|\(normalizedNamespace)|\(rawValue)".utf8)
        return SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// The boundary a user sees before an organization command is executed.
internal nonisolated enum OrganizationEffectCategory: String, Codable, CaseIterable, Sendable {
    case betterMailOnly
    case appleMailChanging
    case mixed

    internal var localizationKey: String {
        "organization.effect.category.\(rawValue)"
    }
}

/// The concrete operation represented by an effect descriptor.
internal nonisolated enum OrganizationEffectOperationKind: String, Codable, CaseIterable, Sendable {
    case manualGroupMembership
    case suggestionReview
    case suggestionAcceptance
    case graphArchive
    case spatialLayout
    case snip
    case messageMove
    case messageRestore
    case mailboxCreation
    case mailboxCreateAndMove
    case automationReview
    case automationApproval
    case automationRetry
    case automationRecovery
    case mappedAutomation
    case mappedFolderMove

    // Short aliases keep call sites readable without creating duplicate wire values.
    internal static let manualGroup = Self.manualGroupMembership
    internal static let suggestion = Self.suggestionReview
    internal static let archive = Self.graphArchive
    internal static let move = Self.messageMove
    internal static let restore = Self.messageRestore
    internal static let mailboxCreate = Self.mailboxCreation
    internal static let retry = Self.automationRetry
    internal static let recovery = Self.automationRecovery
}

/// The physical Apple Mail mutation that an operation may request.
internal nonisolated enum OrganizationMailMutation: String, Codable, CaseIterable, Hashable, Sendable {
    case messageMove
    case mailboxCreation
    case messageRestore

    internal static let mailboxCreate = Self.mailboxCreation
}

/// The BetterMail-side state change, if any, in an organization operation.
internal nonisolated enum OrganizationBetterMailChange: String, Codable, CaseIterable, Sendable {
    case none
    case groupMembership
    case graphArchive
    case spatialLayout
    case suggestionState

    internal var changesBetterMail: Bool {
        self != .none
    }
}

/// The reversibility promise that can be disclosed before a command runs.
internal nonisolated enum OrganizationReversibility: String, Codable, CaseIterable, Sendable {
    case fullyReversible
    case conditionallyReversible
    case partiallyReversible
    case notReversible
    case unknown

    internal static let reversible = Self.fullyReversible
    internal static let conditional = Self.conditionallyReversible
    internal static let irreversible = Self.notReversible

    internal var localizationKey: String {
        "organization.effect.reversibility.\(rawValue)"
    }
}

/// One exact source route for one physical message.
///
/// Values are trimmed at construction, but their case is preserved. Apple Mail
/// account names, mailbox paths, and RFC message identifiers are exact route
/// components; case-folding them could authorize one route and execute another.
internal nonisolated struct OrganizationMailRoute: Codable, Equatable, Hashable, Sendable {
    internal let messageID: String
    internal let account: String
    internal let mailboxPath: String

    internal init(messageID: String, account: String, mailboxPath: String) {
        self.messageID = Self.trim(messageID)
        self.account = Self.trim(account)
        self.mailboxPath = Self.trim(mailboxPath)
    }

    internal var sourceAccount: String { account }
    internal var sourceMailboxPath: String { mailboxPath }

    internal var isExact: Bool {
        !messageID.isEmpty && !account.isEmpty && !mailboxPath.isEmpty
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A presentation-safe grouping of exact source account/mailbox routes. Raw
/// message identifiers remain in the immutable effect used for authorization,
/// while confirmation UI can disclose every source route and its affected
/// message count without unnecessarily displaying identifiers.
internal nonisolated struct OrganizationMailRouteGroup: Identifiable, Equatable, Hashable, Sendable {
    internal let account: String
    internal let mailboxPath: String
    internal let messageCount: Int

    internal var id: String {
        "\(account.utf8.count):\(account)|\(mailboxPath.utf8.count):\(mailboxPath)"
    }

    internal static func make(from routes: [OrganizationMailRoute]) -> [Self] {
        struct Source: Hashable {
            let account: String
            let mailboxPath: String
        }
        let grouped = Dictionary(grouping: routes) {
            Source(account: $0.account, mailboxPath: $0.mailboxPath)
        }
        return grouped.map { source, routes in
            Self(account: source.account,
                 mailboxPath: source.mailboxPath,
                 messageCount: routes.count)
        }.sorted {
            if $0.account != $1.account { return $0.account < $1.account }
            return $0.mailboxPath < $1.mailboxPath
        }
    }
}

/// A destination disclosed for a physical Mail effect.
internal nonisolated enum OrganizationMailDestination: Codable, Equatable, Hashable, Sendable {
    case mailbox(account: String, path: String)
    case newMailbox(account: String, path: String)
    case originalSourceRoutes
    case none

    internal var account: String? {
        switch self {
        case .mailbox(let account, _), .newMailbox(let account, _):
            return account
        case .originalSourceRoutes, .none:
            return nil
        }
    }

    internal var path: String? {
        switch self {
        case .mailbox(_, let path), .newMailbox(_, let path):
            return path
        case .originalSourceRoutes, .none:
            return nil
        }
    }

    internal var isMailboxCreation: Bool {
        if case .newMailbox = self { return true }
        return false
    }

    internal var normalized: Self {
        switch self {
        case .mailbox(let account, let path):
            return .mailbox(account: Self.trim(account), path: Self.trim(path))
        case .newMailbox(let account, let path):
            return .newMailbox(account: Self.trim(account), path: Self.trim(path))
        case .originalSourceRoutes:
            return .originalSourceRoutes
        case .none:
            return .none
        }
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Localization metadata rather than rendered copy. Views resolve these keys
/// through the app's localization layer and format the disclosed fields.
internal nonisolated struct OrganizationEffectLocalization: Codable, Equatable, Sendable {
    internal let categoryKey: String
    internal let titleKey: String
    internal let detailKey: String
    internal let argumentKeys: [String]

    internal init(operation: OrganizationEffectOperationKind) {
        let operationKey = operation.rawValue
        categoryKey = "organization.effect.category"
        titleKey = "organization.effect.\(operationKey).title"
        detailKey = "organization.effect.\(operationKey).detail"
        argumentKeys = ["messageCount", "sourceRoutes", "destination", "reversibility"]
    }
}

/// A complete, immutable preview of an organization command's side effects.
///
/// This type deliberately contains no rendered user-facing text. It is the
/// single disclosure object passed to confirmation and authorization factories.
internal nonisolated struct OrganizationEffect: Codable, Equatable, Sendable {
    internal let operation: OrganizationEffectOperationKind
    internal let betterMailChange: OrganizationBetterMailChange
    internal let mailMutations: Set<OrganizationMailMutation>
    internal let messageCount: Int
    internal let sourceRoutes: [OrganizationMailRoute]
    internal let destination: OrganizationMailDestination?
    internal let reversibility: OrganizationReversibility
    internal let localization: OrganizationEffectLocalization

    internal init(operation: OrganizationEffectOperationKind,
                  betterMailChange: OrganizationBetterMailChange = .none,
                  mailMutations: Set<OrganizationMailMutation> = [],
                  messageCount: Int = 0,
                  sourceRoutes: [OrganizationMailRoute] = [],
                  destination: OrganizationMailDestination? = nil,
                  reversibility: OrganizationReversibility = .fullyReversible) {
        self.operation = operation
        self.betterMailChange = betterMailChange
        self.mailMutations = mailMutations
        self.messageCount = messageCount
        self.sourceRoutes = sourceRoutes
        self.destination = destination?.normalized
        self.reversibility = reversibility
        localization = OrganizationEffectLocalization(operation: operation)
    }

    internal var category: OrganizationEffectCategory {
        let hasMailMutation = !mailMutations.isEmpty
        switch (betterMailChange.changesBetterMail, hasMailMutation) {
        case (false, false), (true, false):
            return .betterMailOnly
        case (false, true):
            return .appleMailChanging
        case (true, true):
            return .mixed
        }
    }

    internal var requiresMailAuthorization: Bool {
        !mailMutations.isEmpty
    }

    internal var requiredMailEffects: Set<OrganizationMailMutation> {
        mailMutations
    }

    internal var sourceRouteGroups: [OrganizationMailRouteGroup] {
        OrganizationMailRouteGroup.make(from: sourceRoutes)
    }

    /// True only when the preview contains enough exact data for a Mail call.
    internal var hasCompleteMailDisclosure: Bool {
        guard requiresMailAuthorization else { return true }
        guard messageCount >= 0 else { return false }

        let distinctRoutes = Set(sourceRoutes)
        guard distinctRoutes.count == sourceRoutes.count else { return false }
        guard sourceRoutes.allSatisfy(\.isExact) else { return false }

        let includesMessageMutation = mailMutations.contains(.messageMove)
            || mailMutations.contains(.messageRestore)
        if includesMessageMutation {
            guard messageCount > 0,
                  sourceRoutes.count == messageCount,
                  destination != nil else {
                return false
            }
        }

        if mailMutations.contains(.mailboxCreation) {
            guard let destination, destination.isMailboxCreation else { return false }
        }

        return true
    }

    internal static func betterMailOnly(operation: OrganizationEffectOperationKind,
                                        change: OrganizationBetterMailChange = .groupMembership,
                                        reversibility: OrganizationReversibility = .fullyReversible) -> Self {
        Self(operation: operation,
             betterMailChange: change,
             reversibility: reversibility)
    }

    internal static func appleMail(operation: OrganizationEffectOperationKind,
                                   mutation: OrganizationMailMutation,
                                   messageCount: Int,
                                   sourceRoutes: [OrganizationMailRoute],
                                   destination: OrganizationMailDestination,
                                   reversibility: OrganizationReversibility) -> Self {
        Self(operation: operation,
             mailMutations: [mutation],
             messageCount: messageCount,
             sourceRoutes: sourceRoutes,
             destination: destination,
             reversibility: reversibility)
    }

    internal static func mixed(operation: OrganizationEffectOperationKind,
                               betterMailChange: OrganizationBetterMailChange,
                               mailMutations: Set<OrganizationMailMutation>,
                               messageCount: Int,
                               sourceRoutes: [OrganizationMailRoute],
                               destination: OrganizationMailDestination,
                               reversibility: OrganizationReversibility) -> Self {
        Self(operation: operation,
             betterMailChange: betterMailChange,
             mailMutations: mailMutations,
             messageCount: messageCount,
             sourceRoutes: sourceRoutes,
             destination: destination,
             reversibility: reversibility)
    }
}

internal typealias OrganizationEffectDescriptor = OrganizationEffect
