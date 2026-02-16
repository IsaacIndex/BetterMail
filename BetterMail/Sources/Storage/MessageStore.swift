import CoreData
import Foundation
import OSLog

internal extension Notification.Name {
    static let manualThreadGroupsReset = Notification.Name("MessageStore.manualThreadGroupsReset")
}

internal final class MessageStore {
    internal enum ThreadMessageBoundary {
        case oldest
        case newest
    }

    internal static let shared = MessageStore()

    private let container: NSPersistentContainer
    private let userDefaults: UserDefaults
    private let lastSyncKey = "MessageStore.lastSync"
    private let manualGroupMigrationKey = "MessageStore.manualGroupMigrationV1"
    private let folderMigrationKey = "MessageStore.threadFolderMigrationV1"
    private let summaryCacheMigrationKey = "MessageStore.threadSummaryCacheMigrationV1"
    private let scopedSummaryCacheMigrationKey = "MessageStore.scopedSummaryCacheMigrationV1"
    private let logger = Log.refresh

    internal var lastSyncDate: Date? {
        get { userDefaults.object(forKey: lastSyncKey) as? Date }
        set { userDefaults.set(newValue, forKey: lastSyncKey) }
    }

    internal init(userDefaults: UserDefaults = .standard,
                  storeURL: URL? = nil,
                  storeType: String = NSSQLiteStoreType) {
        self.userDefaults = userDefaults
        let model = MessageStore.makeModel()
        container = NSPersistentContainer(name: "BetterMailModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = storeType
        if storeType != NSInMemoryStoreType {
            let resolvedURL = storeURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("BetterMail", isDirectory: true)
                .appendingPathComponent("Messages.sqlite")
            if storeURL == nil {
                let directoryURL = resolvedURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            description.url = resolvedURL
        }
        description.shouldInferMappingModelAutomatically = true
        description.shouldMigrateStoreAutomatically = true
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Failed to load persistent store: \(error)")
            }
        }
        Task { [weak self] in
            await self?.migrateLegacyOverridesIfNeeded()
            await self?.migrateFoldersIfNeeded()
            await self?.migrateSummaryCacheIfNeeded()
            await self?.migrateScopedSummaryCacheIfNeeded()
        }
    }

    internal func upsert(messages: [EmailMessage]) async throws {
        guard !messages.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let encoder = JSONEncoder()
            let ids = messages.map { $0.messageID }
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            request.predicate = NSPredicate(format: "messageID IN %@", ids)
            let existing = try context.fetch(request)
            var lookup = Dictionary(uniqueKeysWithValues: existing.map { ($0.messageID, $0) })
            for message in messages {
                let entity = lookup[message.messageID] ?? MessageEntity(context: context)
                entity.id = message.id
                entity.messageID = message.messageID
                let normalized = message.normalizedMessageID.isEmpty ? message.id.uuidString.lowercased() : message.normalizedMessageID
                entity.normalizedMessageID = normalized
                entity.mailboxID = message.mailboxID
                entity.accountName = message.accountName
                entity.subject = message.subject
                entity.fromAddress = message.from
                entity.toAddress = message.to
                entity.date = message.date
                entity.snippet = message.snippet
                entity.isUnread = message.isUnread
                entity.inReplyTo = message.inReplyTo
                entity.referencesData = try encoder.encode(message.references)
                entity.threadID = message.threadID
                entity.rawSourcePath = message.rawSourceLocation?.path
                lookup[message.messageID] = entity
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func fetchMessages(limit: Int? = nil) async throws -> [EmailMessage] {
        try await fetchMessages(since: nil,
                                limit: limit,
                                mailbox: nil,
                                account: nil,
                                includeAllInboxesAliases: false)
    }

    internal func fetchMessages(since date: Date?,
                                limit: Int? = nil,
                                mailbox: String? = nil,
                                account: String? = nil,
                                includeAllInboxesAliases: Bool = false) async throws -> [EmailMessage] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: false),
                NSSortDescriptor(key: #keyPath(MessageEntity.messageID), ascending: true)
            ]
            var predicates: [NSPredicate] = []
            if let date {
                predicates.append(NSPredicate(format: "date >= %@", date as NSDate))
            }
            if let mailbox {
                predicates.append(self.mailboxPredicate(mailbox: mailbox,
                                                        includeAllInboxesAliases: includeAllInboxesAliases))
            }
            let trimmedAccount = account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedAccount.isEmpty {
                predicates.append(NSPredicate(format: "accountName ==[c] %@", trimmedAccount))
            }
            if !predicates.isEmpty {
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            }
            if let limit { request.fetchLimit = limit }
            let entities = try context.fetch(request)
            return entities.compactMap { $0.toModel() }
        }
    }

    internal func countMessages(in range: DateInterval, mailbox: String? = nil) async throws -> Int {
        try await container.performBackgroundTask { context in
            let basePredicates: [NSPredicate] = [
                NSPredicate(format: "date >= %@", range.start as NSDate),
                NSPredicate(format: "date <= %@", range.end as NSDate)
            ]
            let basePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: basePredicates)

            if let mailbox {
                let allRequest: NSFetchRequest<NSFetchRequestResult> = MessageEntity.fetchRequest()
                allRequest.predicate = basePredicate
                let totalCount = try context.count(for: allRequest)

                let mailboxRequest: NSFetchRequest<NSFetchRequestResult> = MessageEntity.fetchRequest()
                mailboxRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: basePredicates + [
                    NSPredicate(format: "mailboxID ==[c] %@", mailbox)
                ])
                let mailboxCount = try context.count(for: mailboxRequest)

                if mailboxCount == 0 {
                    if totalCount == 0 {
                        self.logger.info("MessageStore count: no messages in range; mailbox=\(mailbox, privacy: .public) rangeStart=\(range.start, privacy: .private) rangeEnd=\(range.end, privacy: .private)")
                    } else {
                        let sampleRequest = NSFetchRequest<NSDictionary>(entityName: "MessageEntity")
                        sampleRequest.resultType = .dictionaryResultType
                        sampleRequest.propertiesToFetch = [#keyPath(MessageEntity.mailboxID)]
                        sampleRequest.predicate = basePredicate
                        sampleRequest.fetchLimit = 25
                        let sampleResults = try context.fetch(sampleRequest)
                        let sampleMailboxIDs = sampleResults.compactMap { $0[#keyPath(MessageEntity.mailboxID)] as? String }
                        let uniqueSample = Array(Set(sampleMailboxIDs)).prefix(10)
                        self.logger.info("MessageStore count: range has messages but mailbox mismatch; mailbox=\(mailbox, privacy: .public) totalInRange=\(totalCount, privacy: .public) sampleMailboxIDs=\(uniqueSample.joined(separator: ","), privacy: .public)")
                    }
                }

                return mailboxCount
            } else {
                let request: NSFetchRequest<NSFetchRequestResult> = MessageEntity.fetchRequest()
                request.predicate = basePredicate
                return try context.count(for: request)
            }
        }
    }

    internal func fetchMessages(in range: DateInterval,
                                mailbox: String? = nil,
                                account: String? = nil,
                                includeAllInboxesAliases: Bool = false,
                                limit: Int? = nil,
                                offset: Int = 0) async throws -> [EmailMessage] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: false),
                NSSortDescriptor(key: #keyPath(MessageEntity.messageID), ascending: true)
            ]
            var predicates: [NSPredicate] = [
                NSPredicate(format: "date >= %@", range.start as NSDate),
                NSPredicate(format: "date <= %@", range.end as NSDate)
            ]
            if let mailbox {
                predicates.append(self.mailboxPredicate(mailbox: mailbox,
                                                        includeAllInboxesAliases: includeAllInboxesAliases))
            }
            let trimmedAccount = account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedAccount.isEmpty {
                predicates.append(NSPredicate(format: "accountName ==[c] %@", trimmedAccount))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            if let limit {
                request.fetchLimit = limit
            }
            request.fetchOffset = max(0, offset)
            let entities = try context.fetch(request)
            return entities.compactMap { $0.toModel() }
        }
    }

    internal func fetchMessages(threadIDs: Set<String>, limit: Int? = nil) async throws -> [EmailMessage] {
        guard !threadIDs.isEmpty else { return [] }
        return try await container.performBackgroundTask { context in
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: false),
                NSSortDescriptor(key: #keyPath(MessageEntity.messageID), ascending: true)
            ]
            request.predicate = NSPredicate(format: "threadID IN %@", Array(threadIDs))
            if let limit { request.fetchLimit = limit }
            let entities = try context.fetch(request)
            return entities.compactMap { $0.toModel() }
        }
    }

    internal func fetchBoundaryMessage(threadIDs: Set<String>,
                                       boundary: ThreadMessageBoundary) async throws -> EmailMessage? {
        guard !threadIDs.isEmpty else { return nil }
        return try await container.performBackgroundTask { context in
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            switch boundary {
            case .newest:
                request.sortDescriptors = [
                    NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: false),
                    NSSortDescriptor(key: #keyPath(MessageEntity.messageID), ascending: false)
                ]
            case .oldest:
                request.sortDescriptors = [
                    NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: true),
                    NSSortDescriptor(key: #keyPath(MessageEntity.messageID), ascending: true)
                ]
            }
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "threadID IN %@", Array(threadIDs))
            return try context.fetch(request).first?.toModel()
        }
    }

    internal func fetchThreads(limit: Int? = nil) async throws -> [EmailThread] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ThreadEntity> = ThreadEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(ThreadEntity.lastUpdated), ascending: false)]
            if let limit { request.fetchLimit = limit }
            return try context.fetch(request).map { $0.toModel() }
        }
    }

    internal func fetchManualThreadOverrides() async throws -> [String: String] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ManualThreadOverrideEntity> = ManualThreadOverrideEntity.fetchRequest()
            let overrides = try context.fetch(request)
            return overrides.reduce(into: [String: String]()) { result, override in
                result[override.messageKey] = override.threadID
            }
        }
    }

    internal func fetchManualThreadGroups() async throws -> [ManualThreadGroup] {
        try await container.performBackgroundTask { context in
            let groupRequest: NSFetchRequest<ManualThreadGroupEntity> = ManualThreadGroupEntity.fetchRequest()
            let groups = try context.fetch(groupRequest)

            let jwzRequest: NSFetchRequest<ManualThreadGroupJWZEntity> = ManualThreadGroupJWZEntity.fetchRequest()
            let jwzMappings = try context.fetch(jwzRequest)
            var jwzByGroupID: [String: Set<String>] = [:]
            for mapping in jwzMappings {
                jwzByGroupID[mapping.groupID, default: []].insert(mapping.jwzThreadID)
            }

            let messageRequest: NSFetchRequest<ManualThreadGroupMessageEntity> = ManualThreadGroupMessageEntity.fetchRequest()
            let messageMappings = try context.fetch(messageRequest)
            var messageKeysByGroupID: [String: Set<String>] = [:]
            for mapping in messageMappings {
                messageKeysByGroupID[mapping.groupID, default: []].insert(mapping.messageKey)
            }

            return groups.map { group in
                ManualThreadGroup(id: group.id,
                                  jwzThreadIDs: jwzByGroupID[group.id, default: []],
                                  manualMessageKeys: messageKeysByGroupID[group.id, default: []])
            }
        }
    }

    internal func fetchThreadFolders() async throws -> [ThreadFolder] {
        try await container.performBackgroundTask { context in
            let folderRequest: NSFetchRequest<ThreadFolderEntity> = ThreadFolderEntity.fetchRequest()
            let colorRequest: NSFetchRequest<ThreadFolderColorEntity> = ThreadFolderColorEntity.fetchRequest()
            let membershipRequest: NSFetchRequest<ThreadFolderMembershipEntity> = ThreadFolderMembershipEntity.fetchRequest()

            let colors = try context.fetch(colorRequest)
            let colorsByFolder = colors.reduce(into: [String: ThreadFolderColor]()) { result, entity in
                result[entity.folderID] = ThreadFolderColor(red: entity.red,
                                                            green: entity.green,
                                                            blue: entity.blue,
                                                            alpha: entity.alpha)
            }

            let memberships = try context.fetch(membershipRequest)
            let threadIDsByFolder = memberships.reduce(into: [String: Set<String>]()) { result, entity in
                result[entity.folderID, default: []].insert(entity.threadID)
            }

            let folders = try context.fetch(folderRequest)
            return folders.map { folder in
                ThreadFolder(id: folder.id,
                             title: folder.title,
                             color: colorsByFolder[folder.id] ?? ThreadFolderColor(red: 0.6, green: 0.6, blue: 0.7, alpha: 1),
                             threadIDs: threadIDsByFolder[folder.id, default: []],
                             parentID: folder.parentID)
            }
        }
    }

    internal func upsertThreadFolders(_ folders: [ThreadFolder]) async throws {
        guard !folders.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let ids = folders.map(\.id)
            let folderRequest: NSFetchRequest<ThreadFolderEntity> = ThreadFolderEntity.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "id IN %@", ids)
            let existing = try context.fetch(folderRequest)
            var folderLookup = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

            let colorRequest: NSFetchRequest<ThreadFolderColorEntity> = ThreadFolderColorEntity.fetchRequest()
            colorRequest.predicate = NSPredicate(format: "folderID IN %@", ids)
            for color in try context.fetch(colorRequest) {
                context.delete(color)
            }

            let membershipRequest: NSFetchRequest<ThreadFolderMembershipEntity> = ThreadFolderMembershipEntity.fetchRequest()
            membershipRequest.predicate = NSPredicate(format: "folderID IN %@", ids)
            for membership in try context.fetch(membershipRequest) {
                context.delete(membership)
            }

            for folder in folders {
                let entity = folderLookup[folder.id] ?? ThreadFolderEntity(context: context)
                entity.id = folder.id
                entity.title = folder.title
                entity.parentID = folder.parentID
                folderLookup[folder.id] = entity

                let color = ThreadFolderColorEntity(context: context)
                color.folderID = folder.id
                color.red = folder.color.red
                color.green = folder.color.green
                color.blue = folder.color.blue
                color.alpha = folder.color.alpha

                for threadID in folder.threadIDs {
                    let membership = ThreadFolderMembershipEntity(context: context)
                    membership.folderID = folder.id
                    membership.threadID = threadID
                }
            }

            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func deleteThreadFolders(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let folderRequest: NSFetchRequest<ThreadFolderEntity> = ThreadFolderEntity.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "id IN %@", ids)
            for folder in try context.fetch(folderRequest) {
                context.delete(folder)
            }

            let colorRequest: NSFetchRequest<ThreadFolderColorEntity> = ThreadFolderColorEntity.fetchRequest()
            colorRequest.predicate = NSPredicate(format: "folderID IN %@", ids)
            for color in try context.fetch(colorRequest) {
                context.delete(color)
            }

            let membershipRequest: NSFetchRequest<ThreadFolderMembershipEntity> = ThreadFolderMembershipEntity.fetchRequest()
            membershipRequest.predicate = NSPredicate(format: "folderID IN %@", ids)
            for membership in try context.fetch(membershipRequest) {
                context.delete(membership)
            }

            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func fetchThreadSummaries(for threadIDs: [String]) async throws -> [ThreadSummaryCacheEntry] {
        guard !threadIDs.isEmpty else { return [] }
        return try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ThreadSummaryEntity> = ThreadSummaryEntity.fetchRequest()
            request.predicate = NSPredicate(format: "threadID IN %@", threadIDs)
            return try context.fetch(request).map { $0.toModel() }
        }
    }

    internal func upsertThreadSummaries(_ summaries: [ThreadSummaryCacheEntry]) async throws {
        guard !summaries.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let ids = summaries.map(\.threadID)
            let request: NSFetchRequest<ThreadSummaryEntity> = ThreadSummaryEntity.fetchRequest()
            request.predicate = NSPredicate(format: "threadID IN %@", ids)
            let existing = try context.fetch(request)
            var lookup = Dictionary(uniqueKeysWithValues: existing.map { ($0.threadID, $0) })

            for summary in summaries {
                let entity = lookup[summary.threadID] ?? ThreadSummaryEntity(context: context)
                entity.threadID = summary.threadID
                entity.summaryText = summary.summaryText
                entity.generatedAt = summary.generatedAt
                entity.fingerprint = summary.fingerprint
                entity.provider = summary.provider
                lookup[summary.threadID] = entity
            }

            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func deleteThreadSummaries(for threadIDs: [String]) async throws {
        guard !threadIDs.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ThreadSummaryEntity> = ThreadSummaryEntity.fetchRequest()
            request.predicate = NSPredicate(format: "threadID IN %@", threadIDs)
            for entity in try context.fetch(request) {
                context.delete(entity)
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func fetchSummaries(scope: SummaryScope, ids: [String]) async throws -> [SummaryCacheEntry] {
        guard !ids.isEmpty else { return [] }
        return try await container.performBackgroundTask { context in
            let request: NSFetchRequest<SummaryCacheEntity> = SummaryCacheEntity.fetchRequest()
            request.predicate = NSPredicate(format: "scope == %@ AND scopeID IN %@", scope.rawValue, ids)
            return try context.fetch(request).map { $0.toModel() }
        }
    }

    internal func upsertSummaries(_ summaries: [SummaryCacheEntry]) async throws {
        guard !summaries.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let ids = summaries.map(\.scopeID)
            let scopes = Set(summaries.map(\.scope))
            let request: NSFetchRequest<SummaryCacheEntity> = SummaryCacheEntity.fetchRequest()
            request.predicate = NSPredicate(format: "scope IN %@ AND scopeID IN %@", scopes.map(\.rawValue), ids)
            let existing = try context.fetch(request)
            var lookup = Dictionary(uniqueKeysWithValues: existing.map { ("\($0.scope)|\($0.scopeID)", $0) })

            for summary in summaries {
                let key = "\(summary.scope.rawValue)|\(summary.scopeID)"
                let entity = lookup[key] ?? SummaryCacheEntity(context: context)
                entity.scope = summary.scope.rawValue
                entity.scopeID = summary.scopeID
                entity.summaryText = summary.summaryText
                entity.generatedAt = summary.generatedAt
                entity.fingerprint = summary.fingerprint
                entity.provider = summary.provider
                lookup[key] = entity
            }

            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func deleteSummaries(scope: SummaryScope, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<SummaryCacheEntity> = SummaryCacheEntity.fetchRequest()
            request.predicate = NSPredicate(format: "scope == %@ AND scopeID IN %@", scope.rawValue, ids)
            for entity in try context.fetch(request) {
                context.delete(entity)
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func upsertManualThreadGroups(_ groups: [ManualThreadGroup]) async throws {
        guard !groups.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let ids = groups.map(\.id)
            let request: NSFetchRequest<ManualThreadGroupEntity> = ManualThreadGroupEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids)
            let existing = try context.fetch(request)
            var lookup = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

            let jwzRequest: NSFetchRequest<ManualThreadGroupJWZEntity> = ManualThreadGroupJWZEntity.fetchRequest()
            jwzRequest.predicate = NSPredicate(format: "groupID IN %@", ids)
            for mapping in try context.fetch(jwzRequest) {
                context.delete(mapping)
            }

            let messageRequest: NSFetchRequest<ManualThreadGroupMessageEntity> = ManualThreadGroupMessageEntity.fetchRequest()
            messageRequest.predicate = NSPredicate(format: "groupID IN %@", ids)
            for mapping in try context.fetch(messageRequest) {
                context.delete(mapping)
            }

            for group in groups {
                let entity = lookup[group.id] ?? ManualThreadGroupEntity(context: context)
                entity.id = group.id
                lookup[group.id] = entity

                for jwzThreadID in group.jwzThreadIDs {
                    let mapping = ManualThreadGroupJWZEntity(context: context)
                    mapping.groupID = group.id
                    mapping.jwzThreadID = jwzThreadID
                }

                for messageKey in group.manualMessageKeys {
                    let mapping = ManualThreadGroupMessageEntity(context: context)
                    mapping.groupID = group.id
                    mapping.messageKey = messageKey
                }
            }

            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func deleteManualThreadGroup(id: String) async throws {
        try await container.performBackgroundTask { context in
            let groupRequest: NSFetchRequest<ManualThreadGroupEntity> = ManualThreadGroupEntity.fetchRequest()
            groupRequest.predicate = NSPredicate(format: "id == %@", id)
            for group in try context.fetch(groupRequest) {
                context.delete(group)
            }

            let jwzRequest: NSFetchRequest<ManualThreadGroupJWZEntity> = ManualThreadGroupJWZEntity.fetchRequest()
            jwzRequest.predicate = NSPredicate(format: "groupID == %@", id)
            for mapping in try context.fetch(jwzRequest) {
                context.delete(mapping)
            }

            let messageRequest: NSFetchRequest<ManualThreadGroupMessageEntity> = ManualThreadGroupMessageEntity.fetchRequest()
            messageRequest.predicate = NSPredicate(format: "groupID == %@", id)
            for mapping in try context.fetch(messageRequest) {
                context.delete(mapping)
            }

            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func resetManualThreadGroups() async throws {
        try await container.performBackgroundTask { context in
            let groupRequest: NSFetchRequest<ManualThreadGroupEntity> = ManualThreadGroupEntity.fetchRequest()
            for group in try context.fetch(groupRequest) {
                context.delete(group)
            }

            let jwzRequest: NSFetchRequest<ManualThreadGroupJWZEntity> = ManualThreadGroupJWZEntity.fetchRequest()
            for mapping in try context.fetch(jwzRequest) {
                context.delete(mapping)
            }

            let messageRequest: NSFetchRequest<ManualThreadGroupMessageEntity> = ManualThreadGroupMessageEntity.fetchRequest()
            for mapping in try context.fetch(messageRequest) {
                context.delete(mapping)
            }

            let overrideRequest: NSFetchRequest<ManualThreadOverrideEntity> = ManualThreadOverrideEntity.fetchRequest()
            for override in try context.fetch(overrideRequest) {
                context.delete(override)
            }

            if context.hasChanges {
                try context.save()
            }
        }
        NotificationCenter.default.post(name: .manualThreadGroupsReset, object: nil)
    }

    internal func upsertManualThreadOverrides(_ overrides: [String: String]) async throws {
        guard !overrides.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let keys = Array(overrides.keys)
            let request: NSFetchRequest<ManualThreadOverrideEntity> = ManualThreadOverrideEntity.fetchRequest()
            request.predicate = NSPredicate(format: "messageKey IN %@", keys)
            let existing = try context.fetch(request)
            var lookup = Dictionary(uniqueKeysWithValues: existing.map { ($0.messageKey, $0) })
            for (key, threadID) in overrides {
                let entity = lookup[key] ?? ManualThreadOverrideEntity(context: context)
                entity.messageKey = key
                entity.threadID = threadID
                lookup[key] = entity
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func deleteManualThreadOverrides(messageKeys: [String]) async throws {
        guard !messageKeys.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ManualThreadOverrideEntity> = ManualThreadOverrideEntity.fetchRequest()
            request.predicate = NSPredicate(format: "messageKey IN %@", messageKeys)
            let existing = try context.fetch(request)
            for entity in existing {
                context.delete(entity)
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func updateThreadMembership(_ map: [String: String], threads: [EmailThread]) async throws {
        guard !map.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let keys = Array(map.keys)
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            request.predicate = NSPredicate(format: "normalizedMessageID IN %@", keys)
            let entities = try context.fetch(request)
            for entity in entities {
                if let threadID = map[entity.normalizedMessageID] {
                    entity.threadID = threadID
                }
            }

            let threadRequest: NSFetchRequest<ThreadEntity> = ThreadEntity.fetchRequest()
            let existingThreads = try context.fetch(threadRequest)
            var threadLookup = Dictionary(uniqueKeysWithValues: existingThreads.map { ($0.id, $0) })
            for thread in threads {
                let entity = threadLookup[thread.id] ?? ThreadEntity(context: context)
                entity.id = thread.id
                entity.rootMessageID = thread.rootMessageID
                entity.subject = thread.subject
                entity.lastUpdated = thread.lastUpdated
                entity.unreadCount = Int32(thread.unreadCount)
                entity.messageCount = Int32(thread.messageCount)
                threadLookup[thread.id] = entity
            }

            if context.hasChanges {
                try context.save()
            }
        }
    }

    private func mailboxPredicate(mailbox: String, includeAllInboxesAliases: Bool) -> NSPredicate {
        if includeAllInboxesAliases {
            let inboxAliases = ["inbox", "all inboxes"]
            let aliasPredicates = inboxAliases.map {
                NSPredicate(format: "mailboxID ==[c] %@", $0)
            }
            return NSCompoundPredicate(orPredicateWithSubpredicates: aliasPredicates)
        }
        return NSPredicate(format: "mailboxID ==[c] %@", mailbox)
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let messageEntity = NSEntityDescription()
        messageEntity.name = "MessageEntity"
        messageEntity.managedObjectClassName = NSStringFromClass(MessageEntity.self)

        let idAttr = NSAttributeDescription()
        idAttr.name = "id"
        idAttr.attributeType = .UUIDAttributeType
        idAttr.isOptional = false

        let msgIDAttr = NSAttributeDescription()
        msgIDAttr.name = "messageID"
        msgIDAttr.attributeType = .stringAttributeType
        msgIDAttr.isOptional = false
        msgIDAttr.isIndexed = true

        let normalizedAttr = NSAttributeDescription()
        normalizedAttr.name = "normalizedMessageID"
        normalizedAttr.attributeType = .stringAttributeType
        normalizedAttr.isOptional = false
        normalizedAttr.isIndexed = true

        let mailboxAttr = NSAttributeDescription()
        mailboxAttr.name = "mailboxID"
        mailboxAttr.attributeType = .stringAttributeType
        mailboxAttr.isOptional = false

        let accountAttr = NSAttributeDescription()
        accountAttr.name = "accountName"
        accountAttr.attributeType = .stringAttributeType
        accountAttr.isOptional = true

        let subjectAttr = NSAttributeDescription()
        subjectAttr.name = "subject"
        subjectAttr.attributeType = .stringAttributeType
        subjectAttr.isOptional = false

        let fromAttr = NSAttributeDescription()
        fromAttr.name = "fromAddress"
        fromAttr.attributeType = .stringAttributeType
        fromAttr.isOptional = false

        let toAttr = NSAttributeDescription()
        toAttr.name = "toAddress"
        toAttr.attributeType = .stringAttributeType
        toAttr.isOptional = false

        let dateAttr = NSAttributeDescription()
        dateAttr.name = "date"
        dateAttr.attributeType = .dateAttributeType
        dateAttr.isOptional = false
        dateAttr.isIndexed = true

        let snippetAttr = NSAttributeDescription()
        snippetAttr.name = "snippet"
        snippetAttr.attributeType = .stringAttributeType
        snippetAttr.isOptional = false

        let unreadAttr = NSAttributeDescription()
        unreadAttr.name = "isUnread"
        unreadAttr.attributeType = .booleanAttributeType
        unreadAttr.isOptional = false

        let inReplyAttr = NSAttributeDescription()
        inReplyAttr.name = "inReplyTo"
        inReplyAttr.attributeType = .stringAttributeType
        inReplyAttr.isOptional = true

        let referencesAttr = NSAttributeDescription()
        referencesAttr.name = "referencesData"
        referencesAttr.attributeType = .binaryDataAttributeType
        referencesAttr.isOptional = true

        let threadAttr = NSAttributeDescription()
        threadAttr.name = "threadID"
        threadAttr.attributeType = .stringAttributeType
        threadAttr.isOptional = true
        threadAttr.isIndexed = true

        let rawAttr = NSAttributeDescription()
        rawAttr.name = "rawSourcePath"
        rawAttr.attributeType = .stringAttributeType
        rawAttr.isOptional = true

        messageEntity.properties = [
            idAttr,
            msgIDAttr,
            normalizedAttr,
            mailboxAttr,
            accountAttr,
            subjectAttr,
            fromAttr,
            toAttr,
            dateAttr,
            snippetAttr,
            unreadAttr,
            inReplyAttr,
            referencesAttr,
            threadAttr,
            rawAttr
        ]

        let threadEntity = NSEntityDescription()
        threadEntity.name = "ThreadEntity"
        threadEntity.managedObjectClassName = NSStringFromClass(ThreadEntity.self)

        let threadIDAttr = NSAttributeDescription()
        threadIDAttr.name = "id"
        threadIDAttr.attributeType = .stringAttributeType
        threadIDAttr.isOptional = false
        threadIDAttr.isIndexed = true

        let rootAttr = NSAttributeDescription()
        rootAttr.name = "rootMessageID"
        rootAttr.attributeType = .stringAttributeType
        rootAttr.isOptional = true

        let threadSubjectAttr = NSAttributeDescription()
        threadSubjectAttr.name = "subject"
        threadSubjectAttr.attributeType = .stringAttributeType
        threadSubjectAttr.isOptional = false

        let updatedAttr = NSAttributeDescription()
        updatedAttr.name = "lastUpdated"
        updatedAttr.attributeType = .dateAttributeType
        updatedAttr.isOptional = false
        updatedAttr.isIndexed = true

        let unreadCountAttr = NSAttributeDescription()
        unreadCountAttr.name = "unreadCount"
        unreadCountAttr.attributeType = .integer32AttributeType
        unreadCountAttr.isOptional = false

        let messageCountAttr = NSAttributeDescription()
        messageCountAttr.name = "messageCount"
        messageCountAttr.attributeType = .integer32AttributeType
        messageCountAttr.isOptional = false

        threadEntity.properties = [
            threadIDAttr,
            rootAttr,
            threadSubjectAttr,
            updatedAttr,
            unreadCountAttr,
            messageCountAttr
        ]

        let overrideEntity = NSEntityDescription()
        overrideEntity.name = "ManualThreadOverrideEntity"
        overrideEntity.managedObjectClassName = NSStringFromClass(ManualThreadOverrideEntity.self)

        let overrideMessageKeyAttr = NSAttributeDescription()
        overrideMessageKeyAttr.name = "messageKey"
        overrideMessageKeyAttr.attributeType = .stringAttributeType
        overrideMessageKeyAttr.isOptional = false
        overrideMessageKeyAttr.isIndexed = true

        let overrideThreadAttr = NSAttributeDescription()
        overrideThreadAttr.name = "threadID"
        overrideThreadAttr.attributeType = .stringAttributeType
        overrideThreadAttr.isOptional = false

        overrideEntity.properties = [
            overrideMessageKeyAttr,
            overrideThreadAttr
        ]

        let manualGroupEntity = NSEntityDescription()
        manualGroupEntity.name = "ManualThreadGroupEntity"
        manualGroupEntity.managedObjectClassName = NSStringFromClass(ManualThreadGroupEntity.self)

        let manualGroupIDAttr = NSAttributeDescription()
        manualGroupIDAttr.name = "id"
        manualGroupIDAttr.attributeType = .stringAttributeType
        manualGroupIDAttr.isOptional = false
        manualGroupIDAttr.isIndexed = true

        manualGroupEntity.properties = [manualGroupIDAttr]

        let manualGroupJWZEntity = NSEntityDescription()
        manualGroupJWZEntity.name = "ManualThreadGroupJWZEntity"
        manualGroupJWZEntity.managedObjectClassName = NSStringFromClass(ManualThreadGroupJWZEntity.self)

        let manualGroupJWZGroupIDAttr = NSAttributeDescription()
        manualGroupJWZGroupIDAttr.name = "groupID"
        manualGroupJWZGroupIDAttr.attributeType = .stringAttributeType
        manualGroupJWZGroupIDAttr.isOptional = false
        manualGroupJWZGroupIDAttr.isIndexed = true

        let manualGroupJWZThreadIDAttr = NSAttributeDescription()
        manualGroupJWZThreadIDAttr.name = "jwzThreadID"
        manualGroupJWZThreadIDAttr.attributeType = .stringAttributeType
        manualGroupJWZThreadIDAttr.isOptional = false
        manualGroupJWZThreadIDAttr.isIndexed = true

        manualGroupJWZEntity.properties = [
            manualGroupJWZGroupIDAttr,
            manualGroupJWZThreadIDAttr
        ]

        let manualGroupMessageEntity = NSEntityDescription()
        manualGroupMessageEntity.name = "ManualThreadGroupMessageEntity"
        manualGroupMessageEntity.managedObjectClassName = NSStringFromClass(ManualThreadGroupMessageEntity.self)

        let manualGroupMessageGroupIDAttr = NSAttributeDescription()
        manualGroupMessageGroupIDAttr.name = "groupID"
        manualGroupMessageGroupIDAttr.attributeType = .stringAttributeType
        manualGroupMessageGroupIDAttr.isOptional = false
        manualGroupMessageGroupIDAttr.isIndexed = true

        let manualGroupMessageKeyAttr = NSAttributeDescription()
        manualGroupMessageKeyAttr.name = "messageKey"
        manualGroupMessageKeyAttr.attributeType = .stringAttributeType
        manualGroupMessageKeyAttr.isOptional = false
        manualGroupMessageKeyAttr.isIndexed = true

        manualGroupMessageEntity.properties = [
            manualGroupMessageGroupIDAttr,
            manualGroupMessageKeyAttr
        ]

        let threadFolderEntity = NSEntityDescription()
        threadFolderEntity.name = "ThreadFolderEntity"
        threadFolderEntity.managedObjectClassName = NSStringFromClass(ThreadFolderEntity.self)

        let threadFolderIDAttr = NSAttributeDescription()
        threadFolderIDAttr.name = "id"
        threadFolderIDAttr.attributeType = .stringAttributeType
        threadFolderIDAttr.isOptional = false
        threadFolderIDAttr.isIndexed = true

        let threadFolderTitleAttr = NSAttributeDescription()
        threadFolderTitleAttr.name = "title"
        threadFolderTitleAttr.attributeType = .stringAttributeType
        threadFolderTitleAttr.isOptional = false

        let threadFolderParentIDAttr = NSAttributeDescription()
        threadFolderParentIDAttr.name = "parentID"
        threadFolderParentIDAttr.attributeType = .stringAttributeType
        threadFolderParentIDAttr.isOptional = true
        threadFolderParentIDAttr.isIndexed = true

        threadFolderEntity.properties = [threadFolderIDAttr, threadFolderTitleAttr, threadFolderParentIDAttr]

        let threadFolderColorEntity = NSEntityDescription()
        threadFolderColorEntity.name = "ThreadFolderColorEntity"
        threadFolderColorEntity.managedObjectClassName = NSStringFromClass(ThreadFolderColorEntity.self)

        let colorFolderIDAttr = NSAttributeDescription()
        colorFolderIDAttr.name = "folderID"
        colorFolderIDAttr.attributeType = .stringAttributeType
        colorFolderIDAttr.isOptional = false
        colorFolderIDAttr.isIndexed = true

        let colorRedAttr = NSAttributeDescription()
        colorRedAttr.name = "red"
        colorRedAttr.attributeType = .doubleAttributeType
        colorRedAttr.isOptional = false

        let colorGreenAttr = NSAttributeDescription()
        colorGreenAttr.name = "green"
        colorGreenAttr.attributeType = .doubleAttributeType
        colorGreenAttr.isOptional = false

        let colorBlueAttr = NSAttributeDescription()
        colorBlueAttr.name = "blue"
        colorBlueAttr.attributeType = .doubleAttributeType
        colorBlueAttr.isOptional = false

        let colorAlphaAttr = NSAttributeDescription()
        colorAlphaAttr.name = "alpha"
        colorAlphaAttr.attributeType = .doubleAttributeType
        colorAlphaAttr.isOptional = false

        threadFolderColorEntity.properties = [
            colorFolderIDAttr,
            colorRedAttr,
            colorGreenAttr,
            colorBlueAttr,
            colorAlphaAttr
        ]

        let threadFolderMembershipEntity = NSEntityDescription()
        threadFolderMembershipEntity.name = "ThreadFolderMembershipEntity"
        threadFolderMembershipEntity.managedObjectClassName = NSStringFromClass(ThreadFolderMembershipEntity.self)

        let membershipFolderIDAttr = NSAttributeDescription()
        membershipFolderIDAttr.name = "folderID"
        membershipFolderIDAttr.attributeType = .stringAttributeType
        membershipFolderIDAttr.isOptional = false
        membershipFolderIDAttr.isIndexed = true

        let membershipThreadIDAttr = NSAttributeDescription()
        membershipThreadIDAttr.name = "threadID"
        membershipThreadIDAttr.attributeType = .stringAttributeType
        membershipThreadIDAttr.isOptional = false
        membershipThreadIDAttr.isIndexed = true

        threadFolderMembershipEntity.properties = [
            membershipFolderIDAttr,
            membershipThreadIDAttr
        ]

        let threadSummaryEntity = NSEntityDescription()
        threadSummaryEntity.name = "ThreadSummaryEntity"
        threadSummaryEntity.managedObjectClassName = NSStringFromClass(ThreadSummaryEntity.self)

        let summaryThreadIDAttr = NSAttributeDescription()
        summaryThreadIDAttr.name = "threadID"
        summaryThreadIDAttr.attributeType = .stringAttributeType
        summaryThreadIDAttr.isOptional = false
        summaryThreadIDAttr.isIndexed = true

        let summaryTextAttr = NSAttributeDescription()
        summaryTextAttr.name = "summaryText"
        summaryTextAttr.attributeType = .stringAttributeType
        summaryTextAttr.isOptional = false

        let summaryGeneratedAtAttr = NSAttributeDescription()
        summaryGeneratedAtAttr.name = "generatedAt"
        summaryGeneratedAtAttr.attributeType = .dateAttributeType
        summaryGeneratedAtAttr.isOptional = false

        let summaryFingerprintAttr = NSAttributeDescription()
        summaryFingerprintAttr.name = "fingerprint"
        summaryFingerprintAttr.attributeType = .stringAttributeType
        summaryFingerprintAttr.isOptional = false

        let summaryProviderAttr = NSAttributeDescription()
        summaryProviderAttr.name = "provider"
        summaryProviderAttr.attributeType = .stringAttributeType
        summaryProviderAttr.isOptional = false

        threadSummaryEntity.properties = [
            summaryThreadIDAttr,
            summaryTextAttr,
            summaryGeneratedAtAttr,
            summaryFingerprintAttr,
            summaryProviderAttr
        ]

        let summaryCacheEntity = NSEntityDescription()
        summaryCacheEntity.name = "SummaryCacheEntity"
        summaryCacheEntity.managedObjectClassName = NSStringFromClass(SummaryCacheEntity.self)

        let summaryScopeAttr = NSAttributeDescription()
        summaryScopeAttr.name = "scope"
        summaryScopeAttr.attributeType = .stringAttributeType
        summaryScopeAttr.isOptional = false
        summaryScopeAttr.isIndexed = true

        let summaryScopeIDAttr = NSAttributeDescription()
        summaryScopeIDAttr.name = "scopeID"
        summaryScopeIDAttr.attributeType = .stringAttributeType
        summaryScopeIDAttr.isOptional = false
        summaryScopeIDAttr.isIndexed = true

        let summaryCacheTextAttr = NSAttributeDescription()
        summaryCacheTextAttr.name = "summaryText"
        summaryCacheTextAttr.attributeType = .stringAttributeType
        summaryCacheTextAttr.isOptional = false

        let summaryCacheGeneratedAtAttr = NSAttributeDescription()
        summaryCacheGeneratedAtAttr.name = "generatedAt"
        summaryCacheGeneratedAtAttr.attributeType = .dateAttributeType
        summaryCacheGeneratedAtAttr.isOptional = false

        let summaryCacheFingerprintAttr = NSAttributeDescription()
        summaryCacheFingerprintAttr.name = "fingerprint"
        summaryCacheFingerprintAttr.attributeType = .stringAttributeType
        summaryCacheFingerprintAttr.isOptional = false

        let summaryCacheProviderAttr = NSAttributeDescription()
        summaryCacheProviderAttr.name = "provider"
        summaryCacheProviderAttr.attributeType = .stringAttributeType
        summaryCacheProviderAttr.isOptional = false

        summaryCacheEntity.properties = [
            summaryScopeAttr,
            summaryScopeIDAttr,
            summaryCacheTextAttr,
            summaryCacheGeneratedAtAttr,
            summaryCacheFingerprintAttr,
            summaryCacheProviderAttr
        ]

        model.entities = [
            messageEntity,
            threadEntity,
            overrideEntity,
            manualGroupEntity,
            manualGroupJWZEntity,
            manualGroupMessageEntity,
            threadFolderEntity,
            threadFolderColorEntity,
            threadFolderMembershipEntity,
            threadSummaryEntity,
            summaryCacheEntity
        ]
        return model
    }

    private func migrateLegacyOverridesIfNeeded() async {
        guard !userDefaults.bool(forKey: manualGroupMigrationKey) else { return }
        do {
            let overrides = try await fetchManualThreadOverrides()
            guard !overrides.isEmpty else {
                userDefaults.set(true, forKey: manualGroupMigrationKey)
                return
            }

            let existingGroups = try await fetchManualThreadGroups()
            guard existingGroups.isEmpty else {
                userDefaults.set(true, forKey: manualGroupMigrationKey)
                return
            }

            let messages = try await fetchMessages()
            let baseResult = JWZThreader().buildThreads(from: messages)
            let groupedOverrides = Dictionary(grouping: overrides.keys, by: { overrides[$0] ?? "" })

            var migratedGroups: [ManualThreadGroup] = []
            migratedGroups.reserveCapacity(groupedOverrides.count)

            for (legacyThreadID, messageKeys) in groupedOverrides {
                guard !legacyThreadID.isEmpty else { continue }
                let jwzThreadIDs = Set(messageKeys.compactMap { baseResult.messageThreadMap[$0] })
                let group = ManualThreadGroup(id: legacyThreadID,
                                              jwzThreadIDs: jwzThreadIDs,
                                              manualMessageKeys: Set(messageKeys))
                migratedGroups.append(group)
            }

            if !migratedGroups.isEmpty {
                try await upsertManualThreadGroups(migratedGroups)
                try await deleteManualThreadOverrides(messageKeys: Array(overrides.keys))
            }
            userDefaults.set(true, forKey: manualGroupMigrationKey)
        } catch {
            Log.app.error("Manual thread override migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func migrateFoldersIfNeeded() async {
        guard !userDefaults.bool(forKey: folderMigrationKey) else { return }
        userDefaults.set(true, forKey: folderMigrationKey)
    }

    private func migrateSummaryCacheIfNeeded() async {
        guard !userDefaults.bool(forKey: summaryCacheMigrationKey) else { return }
        do {
            let threads = try await fetchThreads()
            let threadIDs = Set(threads.map(\.id))
            let cachedIDs = try await fetchSummaryThreadIDs()
            let orphaned = cachedIDs.filter { !threadIDs.contains($0) }
            if !orphaned.isEmpty {
                try await deleteThreadSummaries(for: orphaned)
            }
            userDefaults.set(true, forKey: summaryCacheMigrationKey)
        } catch {
            Log.app.error("Summary cache migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func migrateScopedSummaryCacheIfNeeded() async {
        guard !userDefaults.bool(forKey: scopedSummaryCacheMigrationKey) else { return }
        do {
            let messages = try await fetchMessages()
            let messageIDs = Set(messages.map(\.messageID))
            let folders = try await fetchThreadFolders()
            let folderIDs = Set(folders.map(\.id))
            let cachedIDs = try await fetchScopedSummaryIDs()
            let orphanedNodes = cachedIDs.nodeIDs.filter { !messageIDs.contains($0) }
            let orphanedFolders = cachedIDs.folderIDs.filter { !folderIDs.contains($0) }
            let orphanedTags = cachedIDs.tagIDs.filter { !messageIDs.contains($0) }
            if !orphanedNodes.isEmpty {
                try await deleteSummaries(scope: .emailNode, ids: orphanedNodes)
            }
            if !orphanedFolders.isEmpty {
                try await deleteSummaries(scope: .folder, ids: orphanedFolders)
            }
            if !orphanedTags.isEmpty {
                try await deleteSummaries(scope: .emailTag, ids: orphanedTags)
            }
            userDefaults.set(true, forKey: scopedSummaryCacheMigrationKey)
        } catch {
            Log.app.error("Scoped summary cache migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchSummaryThreadIDs() async throws -> [String] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ThreadSummaryEntity> = ThreadSummaryEntity.fetchRequest()
            return try context.fetch(request).map(\.threadID)
        }
    }

    private func fetchScopedSummaryIDs() async throws -> (nodeIDs: [String], folderIDs: [String], tagIDs: [String]) {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<SummaryCacheEntity> = SummaryCacheEntity.fetchRequest()
            let entries = try context.fetch(request)
            var nodeIDs: [String] = []
            var folderIDs: [String] = []
            var tagIDs: [String] = []
            nodeIDs.reserveCapacity(entries.count)
            folderIDs.reserveCapacity(entries.count)
            tagIDs.reserveCapacity(entries.count)
            for entry in entries {
                if entry.scope == SummaryScope.emailNode.rawValue {
                    nodeIDs.append(entry.scopeID)
                } else if entry.scope == SummaryScope.folder.rawValue {
                    folderIDs.append(entry.scopeID)
                } else if entry.scope == SummaryScope.emailTag.rawValue {
                    tagIDs.append(entry.scopeID)
                }
            }
            return (nodeIDs, folderIDs, tagIDs)
        }
    }
}

@objc(MessageEntity)
internal final class MessageEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var messageID: String
    @NSManaged var normalizedMessageID: String
    @NSManaged var mailboxID: String
    @NSManaged var accountName: String?
    @NSManaged var subject: String
    @NSManaged var fromAddress: String
    @NSManaged var toAddress: String
    @NSManaged var date: Date
    @NSManaged var snippet: String
    @NSManaged var isUnread: Bool
    @NSManaged var inReplyTo: String?
    @NSManaged var referencesData: Data?
    @NSManaged var threadID: String?
    @NSManaged var rawSourcePath: String?

    internal func toModel() -> EmailMessage? {
        let refs: [String]
        if let data = referencesData, let decoded = try? JSONDecoder().decode([String].self, from: data) {
            refs = decoded
        } else {
            refs = []
        }
        let rawURL = rawSourcePath.flatMap { URL(fileURLWithPath: $0) }
        return EmailMessage(id: id,
                            messageID: messageID,
                            mailboxID: mailboxID,
                            accountName: accountName ?? "",
                            subject: subject,
                            from: fromAddress,
                            to: toAddress,
                            date: date,
                            snippet: snippet,
                            isUnread: isUnread,
                            inReplyTo: inReplyTo,
                            references: refs,
                            threadID: threadID,
                            rawSourceLocation: rawURL)
    }
}

internal extension MessageEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<MessageEntity> {
        NSFetchRequest<MessageEntity>(entityName: "MessageEntity")
    }
}

@objc(ThreadEntity)
internal final class ThreadEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var rootMessageID: String?
    @NSManaged var subject: String
    @NSManaged var lastUpdated: Date
    @NSManaged var unreadCount: Int32
    @NSManaged var messageCount: Int32

    internal func toModel() -> EmailThread {
        EmailThread(id: id,
                    rootMessageID: rootMessageID,
                    subject: subject,
                    lastUpdated: lastUpdated,
                    unreadCount: Int(unreadCount),
                    messageCount: Int(messageCount))
    }
}

internal extension ThreadEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ThreadEntity> {
        NSFetchRequest<ThreadEntity>(entityName: "ThreadEntity")
    }
}

@objc(ManualThreadOverrideEntity)
internal final class ManualThreadOverrideEntity: NSManagedObject {
    @NSManaged var messageKey: String
    @NSManaged var threadID: String
}

internal extension ManualThreadOverrideEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ManualThreadOverrideEntity> {
        NSFetchRequest<ManualThreadOverrideEntity>(entityName: "ManualThreadOverrideEntity")
    }
}

@objc(ManualThreadGroupEntity)
internal final class ManualThreadGroupEntity: NSManagedObject {
    @NSManaged var id: String
}

internal extension ManualThreadGroupEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ManualThreadGroupEntity> {
        NSFetchRequest<ManualThreadGroupEntity>(entityName: "ManualThreadGroupEntity")
    }
}

@objc(ManualThreadGroupJWZEntity)
internal final class ManualThreadGroupJWZEntity: NSManagedObject {
    @NSManaged var groupID: String
    @NSManaged var jwzThreadID: String
}

internal extension ManualThreadGroupJWZEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ManualThreadGroupJWZEntity> {
        NSFetchRequest<ManualThreadGroupJWZEntity>(entityName: "ManualThreadGroupJWZEntity")
    }
}

@objc(ManualThreadGroupMessageEntity)
internal final class ManualThreadGroupMessageEntity: NSManagedObject {
    @NSManaged var groupID: String
    @NSManaged var messageKey: String
}

internal extension ManualThreadGroupMessageEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ManualThreadGroupMessageEntity> {
        NSFetchRequest<ManualThreadGroupMessageEntity>(entityName: "ManualThreadGroupMessageEntity")
    }
}

@objc(ThreadFolderEntity)
internal final class ThreadFolderEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var title: String
    @NSManaged var parentID: String?
}

internal extension ThreadFolderEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ThreadFolderEntity> {
        NSFetchRequest<ThreadFolderEntity>(entityName: "ThreadFolderEntity")
    }
}

@objc(ThreadFolderColorEntity)
internal final class ThreadFolderColorEntity: NSManagedObject {
    @NSManaged var folderID: String
    @NSManaged var red: Double
    @NSManaged var green: Double
    @NSManaged var blue: Double
    @NSManaged var alpha: Double
}

internal extension ThreadFolderColorEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ThreadFolderColorEntity> {
        NSFetchRequest<ThreadFolderColorEntity>(entityName: "ThreadFolderColorEntity")
    }
}

@objc(ThreadFolderMembershipEntity)
internal final class ThreadFolderMembershipEntity: NSManagedObject {
    @NSManaged var folderID: String
    @NSManaged var threadID: String
}

internal extension ThreadFolderMembershipEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ThreadFolderMembershipEntity> {
        NSFetchRequest<ThreadFolderMembershipEntity>(entityName: "ThreadFolderMembershipEntity")
    }
}

@objc(ThreadSummaryEntity)
internal final class ThreadSummaryEntity: NSManagedObject {
    @NSManaged var threadID: String
    @NSManaged var summaryText: String
    @NSManaged var generatedAt: Date
    @NSManaged var fingerprint: String
    @NSManaged var provider: String

    internal func toModel() -> ThreadSummaryCacheEntry {
        ThreadSummaryCacheEntry(threadID: threadID,
                                summaryText: summaryText,
                                generatedAt: generatedAt,
                                fingerprint: fingerprint,
                                provider: provider)
    }
}

internal extension ThreadSummaryEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ThreadSummaryEntity> {
        NSFetchRequest<ThreadSummaryEntity>(entityName: "ThreadSummaryEntity")
    }
}

@objc(SummaryCacheEntity)
internal final class SummaryCacheEntity: NSManagedObject {
    @NSManaged var scope: String
    @NSManaged var scopeID: String
    @NSManaged var summaryText: String
    @NSManaged var generatedAt: Date
    @NSManaged var fingerprint: String
    @NSManaged var provider: String

    internal func toModel() -> SummaryCacheEntry {
        SummaryCacheEntry(scope: SummaryScope(rawValue: scope) ?? .emailNode,
                          scopeID: scopeID,
                          summaryText: summaryText,
                          generatedAt: generatedAt,
                          fingerprint: fingerprint,
                          provider: provider)
    }
}

internal extension SummaryCacheEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<SummaryCacheEntity> {
        NSFetchRequest<SummaryCacheEntity>(entityName: "SummaryCacheEntity")
    }
}

private extension NSPersistentContainer {
    func performBackgroundTask<T>(_ work: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            performBackgroundTask { context in
                do {
                    let value = try work(context)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
