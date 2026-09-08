import CoreData
import CryptoKit
import Foundation

internal nonisolated enum OrganizationGroupCommandKind: String, Codable, CaseIterable, Hashable, Sendable {
    case createGroup
    case addToGroup
    case removeFromGroup
    case deleteGroup

    internal static let create = Self.createGroup
    internal static let add = Self.addToGroup
    internal static let remove = Self.removeFromGroup
    internal static let delete = Self.deleteGroup
}

/// A BetterMail-only Group command. `memberIDs` are effective conversation IDs
/// in memory; the command service persists only opaque fingerprints in the
/// operation ledger.
internal nonisolated struct OrganizationGroupCommand: Codable, Hashable, Sendable {
    internal let operationID: String
    internal let kind: OrganizationGroupCommandKind
    internal let groupID: String
    internal let title: String?
    internal let memberIDs: [String]
    internal let parentID: String?
    internal let expectedCurrentFingerprint: String?
    internal let anchorIntent: OrganizationSpatialAnchorIntent?
    internal let createdAt: Date

    internal init(operationID: String,
                  kind: OrganizationGroupCommandKind,
                  groupID: String,
                  title: String? = nil,
                  memberIDs: [String],
                  parentID: String? = nil,
                  expectedCurrentFingerprint: String? = nil,
                  anchorIntent: OrganizationSpatialAnchorIntent? = nil,
                  createdAt: Date = Date()) {
        self.operationID = operationID
        self.kind = kind
        self.groupID = groupID
        self.title = title
        self.memberIDs = memberIDs
        self.parentID = parentID
        self.expectedCurrentFingerprint = expectedCurrentFingerprint
        self.anchorIntent = anchorIntent
        self.createdAt = createdAt
    }

    internal static func create(operationID: String,
                                groupID: String,
                                title: String,
                                memberIDs: [String],
                                parentID: String? = nil,
                                anchorIntent: OrganizationSpatialAnchorIntent? = nil,
                                createdAt: Date = Date()) -> Self {
        Self(operationID: operationID,
             kind: .createGroup,
             groupID: groupID,
             title: title,
             memberIDs: memberIDs,
             parentID: parentID,
             anchorIntent: anchorIntent,
             createdAt: createdAt)
    }

    internal static func add(operationID: String,
                             groupID: String,
                             memberIDs: [String],
                             expectedCurrentFingerprint: String? = nil,
                             createdAt: Date = Date()) -> Self {
        Self(operationID: operationID,
             kind: .addToGroup,
             groupID: groupID,
             memberIDs: memberIDs,
             expectedCurrentFingerprint: expectedCurrentFingerprint,
             createdAt: createdAt)
    }

    internal static func remove(operationID: String,
                                groupID: String,
                                memberIDs: [String],
                                expectedCurrentFingerprint: String? = nil,
                                createdAt: Date = Date()) -> Self {
        Self(operationID: operationID,
             kind: .removeFromGroup,
             groupID: groupID,
             memberIDs: memberIDs,
             expectedCurrentFingerprint: expectedCurrentFingerprint,
             createdAt: createdAt)
    }

    internal static func delete(operationID: String,
                                groupID: String,
                                expectedCurrentFingerprint: String,
                                createdAt: Date) -> Self {
        Self(operationID: operationID,
             kind: .deleteGroup,
             groupID: groupID,
             memberIDs: [],
             expectedCurrentFingerprint: expectedCurrentFingerprint,
             createdAt: createdAt)
    }

    internal func validated() throws -> Self {
        let normalizedOperationID = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOperationID.isEmpty, !normalizedGroupID.isEmpty else {
            throw OrganizationMutationStoreError.invalidCommand("operation and Group IDs are required")
        }

        let normalizedMembers = memberIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !normalizedMembers.contains(where: \.isEmpty) else {
            throw OrganizationMutationStoreError.invalidCommand("member IDs must be non-empty")
        }
        guard Set(normalizedMembers).count == normalizedMembers.count else {
            throw OrganizationMutationStoreError.duplicateInput
        }
        if kind == .createGroup {
            let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalizedTitle.isEmpty else {
                throw OrganizationMutationStoreError.invalidCommand("Group title is required")
            }
        }
        if kind == .deleteGroup, !normalizedMembers.isEmpty {
            throw OrganizationMutationStoreError.invalidCommand("delete commands cannot carry members")
        }

        let normalizedParent = parentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpected = expectedCurrentFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(operationID: normalizedOperationID,
                    kind: kind,
                    groupID: normalizedGroupID,
                    title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                    memberIDs: normalizedMembers.sorted(),
                    parentID: normalizedParent?.isEmpty == true ? nil : normalizedParent,
                    expectedCurrentFingerprint: normalizedExpected?.isEmpty == true ? nil : normalizedExpected,
                    anchorIntent: anchorIntent,
                    createdAt: createdAt)
    }
}

internal nonisolated struct OrganizationMutationSnapshot: Codable, Hashable, Sendable {
    internal let groupID: String
    internal let exists: Bool
    internal let title: String?
    internal let parentID: String?
    internal let memberIDs: [String]

    internal var fingerprint: String {
        OrganizationMutationFingerprint.digest([
            groupID,
            exists ? "exists" : "missing",
            title ?? "",
            parentID ?? "",
            memberIDs.sorted().joined(separator: "\u{1F}")
        ])
    }

    internal static func missing(groupID: String) -> Self {
        Self(groupID: groupID, exists: false, title: nil, parentID: nil, memberIDs: [])
    }
}

internal nonisolated struct OrganizationMutationPlan: Hashable, Sendable {
    internal let command: OrganizationGroupCommand
    internal let before: OrganizationMutationSnapshot
    internal let after: OrganizationMutationSnapshot
    internal let addedMemberIDs: [String]
    internal let removedMemberIDs: [String]
    internal let createdGroup: Bool
    internal let deletedGroup: Bool
    internal let wasNoop: Bool
}

internal nonisolated struct OrganizationMutationResult: Hashable, Sendable {
    internal let operationID: String
    internal let kind: OrganizationGroupCommandKind
    internal let groupID: String
    internal let beforeFingerprint: String
    internal let afterFingerprint: String
    internal let addedMemberIDs: [String]
    internal let removedMemberIDs: [String]
    internal let didChange: Bool
    internal let replayed: Bool
}

internal nonisolated enum OrganizationMutationStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidCommand(String)
    case duplicateInput
    case missingGroup(String)
    case groupAlreadyExists(String)
    case staleMutation

    internal var errorDescription: String? {
        switch self {
        case .invalidCommand:
            return "The organization command is invalid."
        case .duplicateInput:
            return "The organization command contains duplicate members."
        case .missingGroup:
            return "The target Group no longer exists."
        case .groupAlreadyExists:
            return "The target Group already exists with different contents."
        case .staleMutation:
            return "The Group changed before this operation could commit."
        }
    }
}

internal nonisolated protocol OrganizationMutationStoring: Sendable {
    func plan(_ command: OrganizationGroupCommand) async throws -> OrganizationMutationPlan
    func apply(_ plan: OrganizationMutationPlan) async throws -> OrganizationMutationResult
}

internal actor OrganizationMutationStore: OrganizationMutationStoring {
    private let messageStore: MessageStore

    internal init(messageStore: MessageStore) {
        self.messageStore = messageStore
    }

    internal func plan(_ command: OrganizationGroupCommand) async throws -> OrganizationMutationPlan {
        let validated = try command.validated()
        return try await messageStore.performOrganizationMutationTransaction { context in
            let current = try Self.fetchFolder(id: validated.groupID, in: context)
            return try Self.makePlan(validated, current: current)
        }
    }

    @discardableResult
    internal func apply(_ plan: OrganizationMutationPlan) async throws -> OrganizationMutationResult {
        let validated = try plan.command.validated()
        guard validated == plan.command else {
            throw OrganizationMutationStoreError.invalidCommand("plan command was not normalized")
        }
        return try await messageStore.performOrganizationMutationTransaction { context in
            let current = try Self.fetchFolder(id: plan.command.groupID, in: context)
            return try Self.apply(plan, current: current, in: context)
        }
    }

    @discardableResult
    internal func apply(_ command: OrganizationGroupCommand) async throws -> OrganizationMutationResult {
        try await apply(plan(command))
    }

    private nonisolated static func makePlan(_ command: OrganizationGroupCommand,
                                             current: OrganizationMutationSnapshot?) throws -> OrganizationMutationPlan {
        let currentSnapshot = current ?? .missing(groupID: command.groupID)
        if let expected = command.expectedCurrentFingerprint,
           currentSnapshot.fingerprint != expected {
            throw OrganizationMutationStoreError.staleMutation
        }

        switch command.kind {
        case .createGroup:
            let desired = OrganizationMutationSnapshot(groupID: command.groupID,
                                                        exists: true,
                                                        title: command.title,
                                                        parentID: command.parentID,
                                                        memberIDs: command.memberIDs)
            guard current == nil else {
                guard currentSnapshot.title == command.title,
                      currentSnapshot.parentID == command.parentID,
                      Set(currentSnapshot.memberIDs) == Set(command.memberIDs) else {
                    throw OrganizationMutationStoreError.groupAlreadyExists(command.groupID)
                }
                return OrganizationMutationPlan(command: command,
                                                before: currentSnapshot,
                                                after: currentSnapshot,
                                                addedMemberIDs: [],
                                                removedMemberIDs: [],
                                                createdGroup: false,
                                                deletedGroup: false,
                                                wasNoop: true)
            }
            return OrganizationMutationPlan(command: command,
                                            before: currentSnapshot,
                                            after: desired,
                                            addedMemberIDs: command.memberIDs,
                                            removedMemberIDs: [],
                                            createdGroup: true,
                                            deletedGroup: false,
                                            wasNoop: false)

        case .addToGroup:
            guard current != nil else {
                throw OrganizationMutationStoreError.missingGroup(command.groupID)
            }
            let existing = Set(currentSnapshot.memberIDs)
            let desiredMembers = existing.union(command.memberIDs).sorted()
            let desired = OrganizationMutationSnapshot(groupID: currentSnapshot.groupID,
                                                        exists: true,
                                                        title: currentSnapshot.title,
                                                        parentID: currentSnapshot.parentID,
                                                        memberIDs: desiredMembers)
            let added = desiredMembers.filter { !existing.contains($0) }
            return OrganizationMutationPlan(command: command,
                                            before: currentSnapshot,
                                            after: desired,
                                            addedMemberIDs: added,
                                            removedMemberIDs: [],
                                            createdGroup: false,
                                            deletedGroup: false,
                                            wasNoop: added.isEmpty)

        case .removeFromGroup:
            guard current != nil else {
                throw OrganizationMutationStoreError.missingGroup(command.groupID)
            }
            let existing = Set(currentSnapshot.memberIDs)
            let removed = command.memberIDs.filter(existing.contains).sorted()
            let desired = OrganizationMutationSnapshot(groupID: currentSnapshot.groupID,
                                                        exists: true,
                                                        title: currentSnapshot.title,
                                                        parentID: currentSnapshot.parentID,
                                                        memberIDs: existing.subtracting(command.memberIDs).sorted())
            return OrganizationMutationPlan(command: command,
                                            before: currentSnapshot,
                                            after: desired,
                                            addedMemberIDs: [],
                                            removedMemberIDs: removed,
                                            createdGroup: false,
                                            deletedGroup: false,
                                            wasNoop: removed.isEmpty)

        case .deleteGroup:
            guard let current else {
                return OrganizationMutationPlan(command: command,
                                                before: currentSnapshot,
                                                after: currentSnapshot,
                                                addedMemberIDs: [],
                                                removedMemberIDs: [],
                                                createdGroup: false,
                                                deletedGroup: false,
                                                wasNoop: true)
            }
            return OrganizationMutationPlan(command: command,
                                            before: current,
                                            after: .missing(groupID: command.groupID),
                                            addedMemberIDs: [],
                                            removedMemberIDs: current.memberIDs,
                                            createdGroup: false,
                                            deletedGroup: true,
                                            wasNoop: false)
        }
    }

    private nonisolated static func apply(_ plan: OrganizationMutationPlan,
                                          current: OrganizationMutationSnapshot?,
                                          in context: NSManagedObjectContext) throws -> OrganizationMutationResult {
        let currentSnapshot = current ?? .missing(groupID: plan.command.groupID)
        if currentSnapshot.fingerprint == plan.after.fingerprint {
            return makeResult(plan, didChange: false, replayed: !plan.wasNoop)
        }
        guard currentSnapshot.fingerprint == plan.before.fingerprint else {
            throw OrganizationMutationStoreError.staleMutation
        }
        guard !plan.wasNoop else {
            return makeResult(plan, didChange: false, replayed: false)
        }

        switch plan.command.kind {
        case .deleteGroup:
            try deleteFolder(id: plan.command.groupID, in: context)
        case .createGroup, .addToGroup, .removeFromGroup:
            try writeFolder(plan.after, creating: plan.createdGroup, in: context)
        }
        if context.hasChanges {
            try context.save()
        }
        return makeResult(plan, didChange: true, replayed: false)
    }

    private nonisolated static func makeResult(_ plan: OrganizationMutationPlan,
                                               didChange: Bool,
                                               replayed: Bool) -> OrganizationMutationResult {
        OrganizationMutationResult(operationID: plan.command.operationID,
                                   kind: plan.command.kind,
                                   groupID: plan.command.groupID,
                                   beforeFingerprint: plan.before.fingerprint,
                                   afterFingerprint: plan.after.fingerprint,
                                   addedMemberIDs: plan.addedMemberIDs,
                                   removedMemberIDs: plan.removedMemberIDs,
                                   didChange: didChange,
                                   replayed: replayed)
    }

    private nonisolated static func fetchFolder(id: String,
                                                in context: NSManagedObjectContext) throws -> OrganizationMutationSnapshot? {
        let folderRequest: NSFetchRequest<ThreadFolderEntity> = ThreadFolderEntity.fetchRequest()
        folderRequest.fetchLimit = 1
        folderRequest.predicate = NSPredicate(format: "id == %@", id)
        guard let folder = try context.fetch(folderRequest).first else {
            return nil
        }

        let membershipRequest: NSFetchRequest<ThreadFolderMembershipEntity> = ThreadFolderMembershipEntity.fetchRequest()
        membershipRequest.predicate = NSPredicate(format: "folderID == %@", id)
        let memberIDs = try context.fetch(membershipRequest).map(\.threadID).sorted()
        return OrganizationMutationSnapshot(groupID: folder.id,
                                             exists: true,
                                             title: folder.title,
                                             parentID: folder.parentID,
                                             memberIDs: memberIDs)
    }

    private nonisolated static func writeFolder(_ snapshot: OrganizationMutationSnapshot,
                                                creating: Bool,
                                                in context: NSManagedObjectContext) throws {
        let folderRequest: NSFetchRequest<ThreadFolderEntity> = ThreadFolderEntity.fetchRequest()
        folderRequest.fetchLimit = 1
        folderRequest.predicate = NSPredicate(format: "id == %@", snapshot.groupID)
        let folder = try context.fetch(folderRequest).first ?? ThreadFolderEntity(context: context)
        if creating {
            folder.id = snapshot.groupID
            folder.title = snapshot.title ?? snapshot.groupID
            folder.parentID = snapshot.parentID
            folder.mailboxAccount = nil
            folder.mailboxPath = nil

            let color = ThreadFolderColorEntity(context: context)
            color.folderID = snapshot.groupID
            color.red = ThreadFolderColor.defaultNewFolder.red
            color.green = ThreadFolderColor.defaultNewFolder.green
            color.blue = ThreadFolderColor.defaultNewFolder.blue
            color.alpha = ThreadFolderColor.defaultNewFolder.alpha
        }

        let membershipRequest: NSFetchRequest<ThreadFolderMembershipEntity> = ThreadFolderMembershipEntity.fetchRequest()
        membershipRequest.predicate = NSPredicate(format: "folderID == %@", snapshot.groupID)
        for membership in try context.fetch(membershipRequest) {
            context.delete(membership)
        }
        for memberID in snapshot.memberIDs.sorted() {
            let membership = ThreadFolderMembershipEntity(context: context)
            membership.folderID = snapshot.groupID
            membership.threadID = memberID
        }
    }

    private nonisolated static func deleteFolder(id: String,
                                                 in context: NSManagedObjectContext) throws {
        let folderRequest: NSFetchRequest<ThreadFolderEntity> = ThreadFolderEntity.fetchRequest()
        folderRequest.predicate = NSPredicate(format: "id == %@", id)
        for folder in try context.fetch(folderRequest) {
            context.delete(folder)
        }

        let colorRequest: NSFetchRequest<ThreadFolderColorEntity> = ThreadFolderColorEntity.fetchRequest()
        colorRequest.predicate = NSPredicate(format: "folderID == %@", id)
        for color in try context.fetch(colorRequest) {
            context.delete(color)
        }

        let membershipRequest: NSFetchRequest<ThreadFolderMembershipEntity> = ThreadFolderMembershipEntity.fetchRequest()
        membershipRequest.predicate = NSPredicate(format: "folderID == %@", id)
        for membership in try context.fetch(membershipRequest) {
            context.delete(membership)
        }
    }
}

private nonisolated enum OrganizationMutationFingerprint {
    static func digest(_ components: [String]) -> String {
        let canonical = components.map { "\($0.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
