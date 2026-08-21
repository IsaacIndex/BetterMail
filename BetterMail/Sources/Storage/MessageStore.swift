import CoreData
import Foundation
import OSLog

internal extension Notification.Name {
    static let manualThreadGroupsReset = Notification.Name("MessageStore.manualThreadGroupsReset")
    static let dayFetchCoverageDidChange = Notification.Name("MessageStore.dayFetchCoverageDidChange")
}

internal final class MessageStore {
    internal enum ThreadMessageBoundary {
        case oldest
        case newest
    }

    internal static let shared = MessageStore()

    private let container: NSPersistentContainer
    /// All scoped-summary upserts share one private context so their
    /// fetch/compare/save transaction is serialized. Independent background
    /// contexts can otherwise both accept an older/newer result and race at
    /// save time.
    private let summaryWriteContext: NSManagedObjectContext
    /// Manual-group, folder-membership, and automation-record writes share a
    /// single context. This is the transaction boundary for batch approval and
    /// delta-based undo; independent background contexts can otherwise lose a
    /// concurrent folder member.
    private let organizationWriteContext: NSManagedObjectContext
    private let userDefaults: UserDefaults
    private let lastSyncKey = "MessageStore.lastSync"
    private let manualGroupMigrationKey = "MessageStore.manualGroupMigrationV1"
    private let folderMigrationKey = "MessageStore.threadFolderMigrationV1"
    private let summaryCacheMigrationKey = "MessageStore.threadSummaryCacheMigrationV1"
    private let scopedSummaryCacheMigrationKey = "MessageStore.scopedSummaryCacheMigrationV1"
    private let calendarClassificationRepairKey = "MessageStore.calendarClassificationRepairV2"
    private let calendarClassificationRepairRevision = 2
    private let logger = Log.refresh
    private nonisolated static let messageFetchBatchSize = 128

    internal var lastSyncDate: Date? {
        get { userDefaults.object(forKey: lastSyncKey) as? Date }
        set { userDefaults.set(newValue, forKey: lastSyncKey) }
    }

    internal init(userDefaults: UserDefaults = .standard,
                  storeURL: URL? = nil,
                  storeType: String = NSSQLiteStoreType) {
        self.userDefaults = userDefaults
        let model = MessageStore.makeModel()
        let persistentContainer = NSPersistentContainer(name: "BetterMailModel",
                                                        managedObjectModel: model)
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
        persistentContainer.persistentStoreDescriptions = [description]
        persistentContainer.loadPersistentStores { _, error in
            if let error {
                fatalError("Failed to load persistent store: \(error)")
            }
        }
        container = persistentContainer
        summaryWriteContext = persistentContainer.newBackgroundContext()
        summaryWriteContext.undoManager = nil
        organizationWriteContext = persistentContainer.newBackgroundContext()
        organizationWriteContext.undoManager = nil
        Task { [weak self] in
            await self?.migrateLegacyOverridesIfNeeded()
            await self?.migrateFoldersIfNeeded()
            await self?.migrateSummaryCacheIfNeeded()
            await self?.migrateScopedSummaryCacheIfNeeded()
        }
    }

    private nonisolated static func configureMessageWindowFetch(_ request: NSFetchRequest<MessageEntity>) {
        request.fetchBatchSize = messageFetchBatchSize
    }

    private static var visibleMessagePredicate: NSPredicate {
        NSPredicate(format: "sourceAbsentAt == nil")
    }

    private static func sourceIdentity(internalMailID: String?,
                                       messageID: String,
                                       account: String,
                                       mailbox: String) -> String {
        let trimmedInternalID = internalMailID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedInternalID.isEmpty {
            return "mail|\(account.lowercased())|\(mailbox.lowercased())|\(trimmedInternalID)"
        }
        return "message|\(account.lowercased())|\(mailbox.lowercased())|\(messageID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func accountScopedMessageKey(messageID: String, account: String) -> String? {
        let normalizedMessageID = JWZThreader.normalizeIdentifier(messageID)
        guard !normalizedMessageID.isEmpty else { return nil }
        return "\(account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(normalizedMessageID)"
    }

    internal func upsert(messages: [EmailMessage]) async throws {
        guard !messages.isEmpty else { return }
        try await container.performBackgroundTask { context in
            let encoder = JSONEncoder()
            let ids = messages.map(\.messageID)
            let internalIDs = messages.compactMap(\.internalMailID)
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            var lookupPredicates = [NSPredicate(format: "messageID IN %@", ids)]
            if !internalIDs.isEmpty {
                lookupPredicates.append(NSPredicate(format: "internalMailID IN %@", internalIDs))
            }
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: lookupPredicates)
            let existing = try context.fetch(request)
            var lookup = Dictionary(existing.map { entity in
                (Self.sourceIdentity(internalMailID: entity.internalMailID,
                                     messageID: entity.messageID,
                                     account: entity.accountName ?? "",
                                     mailbox: entity.mailboxID), entity)
            }, uniquingKeysWith: { current, _ in current })
            var legacyLookup = Dictionary(existing.compactMap { entity -> (String, MessageEntity)? in
                let internalID = entity.internalMailID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard internalID.isEmpty else { return nil }
                return (Self.sourceIdentity(internalMailID: nil,
                                            messageID: entity.messageID,
                                            account: entity.accountName ?? "",
                                            mailbox: entity.mailboxID), entity)
            }, uniquingKeysWith: { current, _ in current })
            for message in messages {
                let sourceIdentity = Self.sourceIdentity(internalMailID: message.internalMailID,
                                                         messageID: message.messageID,
                                                         account: message.accountName,
                                                         mailbox: message.mailboxID)
                let legacyKey = Self.sourceIdentity(internalMailID: nil,
                                                    messageID: message.messageID,
                                                    account: message.accountName,
                                                    mailbox: message.mailboxID)
                let entity = lookup[sourceIdentity]
                    ?? legacyLookup[legacyKey]
                    ?? MessageEntity(context: context)
                entity.id = message.id
                entity.messageID = message.messageID
                let normalized = message.normalizedMessageID.isEmpty ? message.id.uuidString.lowercased() : message.normalizedMessageID
                entity.normalizedMessageID = normalized
                entity.internalMailID = message.internalMailID
                entity.mailboxID = message.mailboxID
                entity.accountName = message.accountName
                entity.subject = message.subject
                entity.fromAddress = message.from
                entity.toAddress = message.to
                entity.date = message.date
                entity.snippet = message.snippet
                entity.isUnread = message.isUnread
                entity.isCalendarRSVP = message.isCalendarRSVP
                entity.calendarMessageKindRaw = message.calendarMessageKind?.rawValue
                entity.inReplyTo = message.inReplyTo
                entity.referencesData = try encoder.encode(message.references)
                entity.embeddedMessagesData = message.embeddedMessages.isEmpty
                    ? nil
                    : try encoder.encode(message.embeddedMessages)
                entity.threadID = message.threadID
                entity.rawSourcePath = message.rawSourceLocation?.path
                entity.sourceAbsentAt = nil
                entity.sourceAbsentScopeKey = nil
                lookup[sourceIdentity] = entity
                legacyLookup.removeValue(forKey: legacyKey)
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
            Self.configureMessageWindowFetch(request)
            request.sortDescriptors = [
                NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: false),
                NSSortDescriptor(key: #keyPath(MessageEntity.messageID), ascending: true)
            ]
            var predicates: [NSPredicate] = [Self.visibleMessagePredicate]
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
            return autoreleasepool {
                entities.compactMap { $0.toModel() }.filter { !$0.isCalendarRSVP }
            }
        }
    }

    /// Returns the display-window messages plus hidden calendar responses and
    /// every cached ancestor reachable through References/In-Reply-To. Ancestor
    /// matching is scoped to the originating account and is intentionally not
    /// constrained by the display date or mailbox.
    internal func fetchMessagesForThreading(since date: Date?,
                                            mailbox: String? = nil,
                                            account: String? = nil,
                                            includeAllInboxesAliases: Bool = false,
                                            includeThreadIDs: Set<String> = [],
                                            includeMessageKeys: Set<String> = []) async throws -> [EmailMessage] {
        try await container.performBackgroundTask { context in
            func models(for request: NSFetchRequest<MessageEntity>) throws -> [EmailMessage] {
                Self.configureMessageWindowFetch(request)
                return try context.fetch(request).compactMap { $0.toModel() }
            }

            let scopedRequest: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            scopedRequest.sortDescriptors = [
                NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: false),
                NSSortDescriptor(key: #keyPath(MessageEntity.messageID), ascending: true)
            ]
            var scopedPredicates: [NSPredicate] = [Self.visibleMessagePredicate]
            if let date {
                scopedPredicates.append(NSPredicate(format: "date >= %@", date as NSDate))
            }
            if let mailbox {
                scopedPredicates.append(self.mailboxPredicate(mailbox: mailbox,
                                                              includeAllInboxesAliases: includeAllInboxesAliases))
            }
            let trimmedAccount = account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedAccount.isEmpty {
                scopedPredicates.append(NSPredicate(format: "accountName ==[c] %@", trimmedAccount))
            }
            scopedRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: scopedPredicates)

            var initialMessages = try models(for: scopedRequest)
            if !includeThreadIDs.isEmpty {
                let includedRequest: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
                includedRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    Self.visibleMessagePredicate,
                    NSPredicate(format: "threadID IN %@", Array(includeThreadIDs))
                ])
                initialMessages.append(contentsOf: try models(for: includedRequest))
            }
            if !includeMessageKeys.isEmpty {
                let normalizedMessageIDs = includeMessageKeys
                    .map(JWZThreader.normalizeIdentifier)
                    .filter { !$0.isEmpty }
                let fallbackUUIDs = includeMessageKeys.compactMap(UUID.init(uuidString:))
                var identityPredicates: [NSPredicate] = []
                if !normalizedMessageIDs.isEmpty {
                    identityPredicates.append(
                        NSPredicate(format: "normalizedMessageID IN %@", normalizedMessageIDs)
                    )
                }
                if !fallbackUUIDs.isEmpty {
                    identityPredicates.append(NSPredicate(format: "id IN %@", fallbackUUIDs))
                }
                if !identityPredicates.isEmpty {
                    let includedMessageRequest: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
                    includedMessageRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        Self.visibleMessagePredicate,
                        NSCompoundPredicate(orPredicateWithSubpredicates: identityPredicates)
                    ])
                    initialMessages.append(contentsOf: try models(for: includedMessageRequest))
                }
            }

            var messagesByKey: [String: EmailMessage] = [:]
            for message in initialMessages {
                guard let key = Self.accountScopedMessageKey(messageID: message.messageID,
                                                             account: message.accountName) else { continue }
                messagesByKey[key] = message
            }

            var examinedAncestorKeys: Set<String> = []
            for _ in 0..<64 {
                var unresolvedKeys: Set<String> = []
                var normalizedIDs: Set<String> = []
                for message in messagesByKey.values {
                    let parentIDs = message.references + (message.inReplyTo.map { [$0] } ?? [])
                    for parentID in parentIDs {
                        guard let key = Self.accountScopedMessageKey(messageID: parentID,
                                                                    account: message.accountName),
                              messagesByKey[key] == nil,
                              !examinedAncestorKeys.contains(key) else { continue }
                        unresolvedKeys.insert(key)
                        let normalizedID = JWZThreader.normalizeIdentifier(parentID)
                        if !normalizedID.isEmpty { normalizedIDs.insert(normalizedID) }
                    }
                }
                guard !unresolvedKeys.isEmpty else { break }
                examinedAncestorKeys.formUnion(unresolvedKeys)

                let sortedIDs = normalizedIDs.sorted()
                for start in stride(from: 0, to: sortedIDs.count, by: Self.messageFetchBatchSize) {
                    let end = min(start + Self.messageFetchBatchSize, sortedIDs.count)
                    let ancestorRequest: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
                    ancestorRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        Self.visibleMessagePredicate,
                        NSPredicate(format: "normalizedMessageID IN %@", Array(sortedIDs[start..<end]))
                    ])
                    for message in try models(for: ancestorRequest) {
                        guard let key = Self.accountScopedMessageKey(messageID: message.messageID,
                                                                     account: message.accountName),
                              unresolvedKeys.contains(key) else { continue }
                        messagesByKey[key] = message
                    }
                }
            }

            return messagesByKey.values.sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.messageID < rhs.messageID }
                return lhs.date > rhs.date
            }
        }
    }

    internal var needsCalendarClassificationRepair: Bool {
        userDefaults.integer(forKey: calendarClassificationRepairKey) < calendarClassificationRepairRevision
    }

    internal func fetchCalendarClassificationRepairCandidates() async throws -> [EmailMessage] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            Self.configureMessageWindowFetch(request)
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: false)]
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                Self.visibleMessagePredicate,
                NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "isCalendarRSVP == YES"),
                    NSPredicate(format: "calendarMessageKindRaw == nil")
                ])
            ])
            return try context.fetch(request)
                .compactMap { entity -> EmailMessage? in
                    guard let message = entity.toModel(),
                          message.isCalendarRSVP
                            || Self.isLegacyCalendarClassificationRepairCandidate(entity) else { return nil }
                    return message
                }
        }
    }

    /// Applies repair results authoritatively by account + Message-ID. A sole
    /// legacy row with no stored account may be promoted to the fetched
    /// account; ambiguous Message-ID matches remain untouched.
    @discardableResult
    internal func applyCalendarClassificationRepair(_ messages: [EmailMessage]) async throws -> Int {
        guard !messages.isEmpty else { return 0 }
        return try await container.performBackgroundTask { context in
            let normalizedIDs = Set(messages.map(\.normalizedMessageID).filter { !$0.isEmpty })
            guard !normalizedIDs.isEmpty else { return 0 }
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            request.predicate = NSPredicate(format: "normalizedMessageID IN %@", Array(normalizedIDs))
            let entities = try context.fetch(request)
            let entitiesByKey = Dictionary(grouping: entities) { entity in
                Self.accountScopedMessageKey(messageID: entity.messageID,
                                             account: entity.accountName ?? "") ?? UUID().uuidString
            }
            let entitiesByNormalizedID = Dictionary(grouping: entities) {
                $0.normalizedMessageID.lowercased()
            }
            let encoder = JSONEncoder()
            var updatedCount = 0

            func apply(_ message: EmailMessage, to entity: MessageEntity) throws {
                entity.snippet = message.snippet
                entity.isCalendarRSVP = message.isCalendarRSVP
                entity.calendarMessageKindRaw = message.calendarMessageKind?.rawValue
                entity.mailboxID = message.mailboxID
                entity.accountName = message.accountName
                entity.internalMailID = message.internalMailID
                entity.inReplyTo = message.inReplyTo
                entity.referencesData = try encoder.encode(message.references)
                entity.sourceAbsentAt = nil
                entity.sourceAbsentScopeKey = nil
            }

            for message in messages {
                var didUpdate = false
                if let key = Self.accountScopedMessageKey(messageID: message.messageID,
                                                         account: message.accountName),
                   let matches = entitiesByKey[key] {
                    for entity in matches {
                        try apply(message, to: entity)
                        updatedCount += 1
                        didUpdate = true
                    }
                }

                if didUpdate { continue }

                let fetchedAccount = message.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackMatches = entitiesByNormalizedID[message.normalizedMessageID.lowercased()] ?? []
                guard !fetchedAccount.isEmpty,
                      fallbackMatches.count == 1,
                      let entity = fallbackMatches.first,
                      (entity.accountName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                try apply(message, to: entity)
                updatedCount += 1
            }
            if context.hasChanges { try context.save() }
            return updatedCount
        }
    }

    internal func markCalendarClassificationRepairComplete() {
        userDefaults.set(calendarClassificationRepairRevision, forKey: calendarClassificationRepairKey)
    }

    /// Early caches sometimes retained only MIME framing rather than enough
    /// iCalendar payload for a conclusive local classification. Re-fetching
    /// these broad candidates is safe because source classification remains
    /// fail-open and is the only operation that can suppress the row.
    private nonisolated static func isLegacyCalendarClassificationRepairCandidate(
        _ entity: MessageEntity
    ) -> Bool {
        guard entity.calendarMessageKindRaw == nil else { return false }
        let snippet = entity.snippet.lowercased()
        return snippet.contains("content-type: text/calendar")
            || snippet.contains("begin:vcalendar")
            || snippet.contains("method:reply")
            || snippet.contains("method=reply")
            || snippet.contains("urn:content-classes:calendarmessage")
    }

    internal func countMessages(in range: DateInterval, mailbox: String? = nil) async throws -> Int {
        try await container.performBackgroundTask { context in
            let basePredicates: [NSPredicate] = [
                Self.visibleMessagePredicate,
                NSPredicate(format: "date >= %@", range.start as NSDate),
                NSPredicate(format: "date < %@", range.end as NSDate)
            ]
            let basePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: basePredicates)

            if let mailbox {
                let allRequest: NSFetchRequest<NSFetchRequestResult> = MessageEntity.fetchRequest()
                allRequest.predicate = basePredicate
                let totalCount = try context.count(for: allRequest)

                let mailboxRequest: NSFetchRequest<NSFetchRequestResult> = MessageEntity.fetchRequest()
                mailboxRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: basePredicates + [
                    self.mailboxPredicate(mailbox: mailbox, includeAllInboxesAliases: false)
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
            Self.configureMessageWindowFetch(request)
            request.sortDescriptors = [
                NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: false),
                NSSortDescriptor(key: #keyPath(MessageEntity.messageID), ascending: true)
            ]
            var predicates: [NSPredicate] = [
                Self.visibleMessagePredicate,
                NSPredicate(format: "date >= %@", range.start as NSDate),
                NSPredicate(format: "date < %@", range.end as NSDate)
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
            return autoreleasepool {
                entities.compactMap { $0.toModel() }.filter { !$0.isCalendarRSVP }
            }
        }
    }

    internal func fetchMessages(threadIDs: Set<String>, limit: Int? = nil) async throws -> [EmailMessage] {
        guard !threadIDs.isEmpty else { return [] }
        return try await container.performBackgroundTask { context in
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            Self.configureMessageWindowFetch(request)
            request.sortDescriptors = [
                NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: false),
                NSSortDescriptor(key: #keyPath(MessageEntity.messageID), ascending: true)
            ]
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                Self.visibleMessagePredicate,
                NSPredicate(format: "threadID IN %@", Array(threadIDs))
            ])
            if let limit { request.fetchLimit = limit }
            let entities = try context.fetch(request)
            return autoreleasepool {
                entities.compactMap { $0.toModel() }.filter { !$0.isCalendarRSVP }
            }
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
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                Self.visibleMessagePredicate,
                NSPredicate(format: "threadID IN %@", Array(threadIDs))
            ])
            return try context.fetch(request)
                .compactMap { $0.toModel() }
                .first { !$0.isCalendarRSVP }
        }
    }

    internal func fetchMessagesForReconciliation(in range: DateInterval,
                                                  scope: DayFetchScope) async throws -> [EmailMessage] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            Self.configureMessageWindowFetch(request)
            var predicates: [NSPredicate] = [
                NSPredicate(format: "date >= %@", range.start as NSDate),
                NSPredicate(format: "date < %@", range.end as NSDate),
                self.mailboxPredicate(mailbox: scope.mailbox,
                                      includeAllInboxesAliases: scope.includesAllInboxAliases)
            ]
            if let account = scope.account {
                predicates.append(NSPredicate(format: "accountName ==[c] %@", account))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            return try context.fetch(request).compactMap { $0.toModel() }
        }
    }

    internal func reconcileSourcePresence(in range: DateInterval,
                                          scope: DayFetchScope,
                                          manifest: [MessageReference],
                                          checkedAt: Date) async throws -> Int {
        let absentCount = try await container.performBackgroundTask { context in
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            var predicates: [NSPredicate] = [
                NSPredicate(format: "date >= %@", range.start as NSDate),
                NSPredicate(format: "date < %@", range.end as NSDate),
                self.mailboxPredicate(mailbox: scope.mailbox,
                                      includeAllInboxesAliases: scope.includesAllInboxAliases)
            ]
            if let account = scope.account {
                predicates.append(NSPredicate(format: "accountName ==[c] %@", account))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

            let manifestInternalIdentities = Set(manifest.compactMap { reference -> String? in
                guard reference.internalMailID != nil else { return nil }
                return reference.stableIdentity
            })
            let manifestMessageIdentities = Set(manifest.map { $0.normalizedMessageIdentity })
            let entities = try context.fetch(request)
            var absentCount = 0
            for entity in entities {
                let isPresent: Bool
                if let internalMailID = entity.internalMailID?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !internalMailID.isEmpty {
                    let reference = MessageReference(internalMailID: internalMailID,
                                                     messageID: entity.messageID,
                                                     mailbox: entity.mailboxID,
                                                     account: entity.accountName ?? "",
                                                     subject: entity.subject,
                                                     date: entity.date,
                                                     isUnread: entity.isUnread)
                    isPresent = manifestInternalIdentities.contains(reference.stableIdentity)
                } else {
                    let reference = MessageReference(internalMailID: nil,
                                                     messageID: entity.messageID,
                                                     mailbox: entity.mailboxID,
                                                     account: entity.accountName ?? "",
                                                     subject: entity.subject,
                                                     date: entity.date,
                                                     isUnread: entity.isUnread)
                    isPresent = manifestMessageIdentities.contains(reference.normalizedMessageIdentity)
                }

                if isPresent {
                    entity.sourceAbsentAt = nil
                    entity.sourceAbsentScopeKey = nil
                } else {
                    entity.sourceAbsentAt = checkedAt
                    entity.sourceAbsentScopeKey = scope.key
                    absentCount += 1
                }
            }
            if context.hasChanges {
                try context.save()
            }
            return absentCount
        }
        logger.info("Source reconciliation completed. scope=\(scope.key, privacy: .private) absent=\(absentCount, privacy: .public)")
        return absentCount
    }

    internal func beginDayFetchCoverage(scope: DayFetchScope,
                                        dayInterval: DateInterval,
                                        attemptedAt: Date) async throws {
        let identifier = coverageIdentifier(scope: scope, dayStart: dayInterval.start)
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<DayFetchCoverageEntity> = DayFetchCoverageEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", identifier)
            request.fetchLimit = 1
            let entity = try context.fetch(request).first ?? DayFetchCoverageEntity(context: context)
            if entity.isInserted {
                entity.id = identifier
                entity.scopeKey = scope.key
                entity.mailbox = scope.mailbox
                entity.account = scope.account
                entity.dayStart = dayInterval.start
                entity.dayEnd = dayInterval.end
                entity.firstTouchedAt = attemptedAt
                entity.expectedCount = 0
                entity.fetchedCount = 0
                entity.absentCount = 0
            }
            entity.lastAttemptAt = attemptedAt
            entity.stateRaw = DayCoverageState.fetching.rawValue
            entity.errorMessage = nil
            try context.save()
        }
        NotificationCenter.default.post(name: .dayFetchCoverageDidChange, object: nil)
    }

    internal func completeDayFetchCoverage(scope: DayFetchScope,
                                           dayInterval: DateInterval,
                                           coveredThrough: Date,
                                           expectedCount: Int,
                                           fetchedCount: Int,
                                           absentCount: Int,
                                           state: DayCoverageState,
                                           completedAt: Date) async throws -> DayFetchCoverage {
        let identifier = coverageIdentifier(scope: scope, dayStart: dayInterval.start)
        let coverage = try await container.performBackgroundTask { context -> DayFetchCoverage in
            let request: NSFetchRequest<DayFetchCoverageEntity> = DayFetchCoverageEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", identifier)
            request.fetchLimit = 1
            let entity = try context.fetch(request).first ?? DayFetchCoverageEntity(context: context)
            if entity.isInserted {
                entity.id = identifier
                entity.scopeKey = scope.key
                entity.mailbox = scope.mailbox
                entity.account = scope.account
                entity.dayStart = dayInterval.start
                entity.dayEnd = dayInterval.end
                entity.firstTouchedAt = completedAt
                entity.expectedCount = 0
                entity.fetchedCount = 0
                entity.absentCount = 0
            }
            entity.lastAttemptAt = completedAt
            entity.lastSuccessAt = completedAt
            entity.coveredThrough = coveredThrough
            entity.expectedCount = Int64(expectedCount)
            entity.fetchedCount = Int64(fetchedCount)
            entity.absentCount = Int64(absentCount)
            entity.stateRaw = state.rawValue
            entity.errorMessage = nil
            try context.save()
            return entity.toModel()
        }
        NotificationCenter.default.post(name: .dayFetchCoverageDidChange, object: nil)
        return coverage
    }

    internal func failDayFetchCoverage(scope: DayFetchScope,
                                       dayInterval: DateInterval,
                                       attemptedAt: Date,
                                       errorMessage: String) async throws {
        let identifier = coverageIdentifier(scope: scope, dayStart: dayInterval.start)
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<DayFetchCoverageEntity> = DayFetchCoverageEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", identifier)
            request.fetchLimit = 1
            let entity = try context.fetch(request).first ?? DayFetchCoverageEntity(context: context)
            if entity.isInserted {
                entity.id = identifier
                entity.scopeKey = scope.key
                entity.mailbox = scope.mailbox
                entity.account = scope.account
                entity.dayStart = dayInterval.start
                entity.dayEnd = dayInterval.end
                entity.firstTouchedAt = attemptedAt
                entity.expectedCount = 0
                entity.fetchedCount = 0
                entity.absentCount = 0
            }
            entity.lastAttemptAt = attemptedAt
            entity.stateRaw = DayCoverageState.failed.rawValue
            entity.errorMessage = errorMessage
            try context.save()
        }
        NotificationCenter.default.post(name: .dayFetchCoverageDidChange, object: nil)
    }

    internal func fetchDayFetchCoverages(scope: DayFetchScope,
                                         concreteScopes: [DayFetchScope]? = nil) async throws -> [DayFetchCoverage] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<DayFetchCoverageEntity> = DayFetchCoverageEntity.fetchRequest()
            guard scope.account == nil, scope.includesAllInboxAliases else {
                request.predicate = NSPredicate(format: "scopeKey == %@", scope.key)
                request.sortDescriptors = [NSSortDescriptor(key: "dayStart", ascending: false)]
                return try context.fetch(request).map { $0.toModel() }
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "mailbox ==[c] %@", "inbox"),
                    NSPredicate(format: "mailbox ==[c] %@", "all inboxes")
                ]),
                NSPredicate(format: "account != nil")
            ])
            request.sortDescriptors = [NSSortDescriptor(key: "dayStart", ascending: false)]
            let concreteCoverages = try context.fetch(request).map { $0.toModel() }
            let aggregateRequest: NSFetchRequest<DayFetchCoverageEntity> = DayFetchCoverageEntity.fetchRequest()
            aggregateRequest.predicate = NSPredicate(format: "scopeKey == %@", scope.key)
            aggregateRequest.sortDescriptors = [NSSortDescriptor(key: "dayStart", ascending: false)]
            let aggregateAttempts = try context.fetch(aggregateRequest).map { $0.toModel() }
            guard !concreteCoverages.isEmpty else {
                return aggregateAttempts
            }

            let expectedScopeKeys: Set<String>
            let relevantConcreteCoverages: [DayFetchCoverage]
            if let concreteScopes, !concreteScopes.isEmpty {
                expectedScopeKeys = Set(concreteScopes.map(\.key))
                relevantConcreteCoverages = concreteCoverages.filter {
                    expectedScopeKeys.contains($0.scopeKey)
                }
            } else {
                expectedScopeKeys = Set(concreteCoverages.map(\.scopeKey))
                relevantConcreteCoverages = concreteCoverages
            }
            var coverageByDay = Dictionary(grouping: relevantConcreteCoverages, by: \.dayStart)
                .map { dayStart, dayCoverages in
                    self.aggregateDayFetchCoverage(dayCoverages,
                                                   requestedScope: scope,
                                                   dayStart: dayStart,
                                                   expectedScopeKeys: expectedScopeKeys)
                }
                .reduce(into: [Date: DayFetchCoverage]()) { result, coverage in
                    result[coverage.dayStart] = coverage
                }
            for aggregateAttempt in aggregateAttempts {
                if let concreteAttempt = coverageByDay[aggregateAttempt.dayStart],
                   concreteAttempt.lastAttemptAt >= aggregateAttempt.lastAttemptAt {
                    continue
                }
                coverageByDay[aggregateAttempt.dayStart] = aggregateAttempt
            }
            return coverageByDay.values.sorted { $0.dayStart > $1.dayStart }
        }
    }

    internal func markInterruptedDayFetchCoverageFailed(at date: Date = Date()) async throws {
        let changed = try await container.performBackgroundTask { context -> Bool in
            let request: NSFetchRequest<DayFetchCoverageEntity> = DayFetchCoverageEntity.fetchRequest()
            request.predicate = NSPredicate(format: "stateRaw == %@", DayCoverageState.fetching.rawValue)
            let entities = try context.fetch(request)
            guard !entities.isEmpty else { return false }
            for entity in entities {
                entity.lastAttemptAt = date
                entity.stateRaw = DayCoverageState.failed.rawValue
                entity.errorMessage = NSLocalizedString("dayfetch.error.interrupted",
                                                        comment: "Persisted failure after an interrupted day fetch")
            }
            try context.save()
            return true
        }
        if changed {
            NotificationCenter.default.post(name: .dayFetchCoverageDidChange, object: nil)
        }
    }

    private func coverageIdentifier(scope: DayFetchScope, dayStart: Date) -> String {
        "\(scope.key)|\(Int64(dayStart.timeIntervalSinceReferenceDate))"
    }

    private func aggregateDayFetchCoverage(_ coverages: [DayFetchCoverage],
                                           requestedScope: DayFetchScope,
                                           dayStart: Date,
                                           expectedScopeKeys: Set<String>) -> DayFetchCoverage {
        let presentScopeKeys = Set(coverages.map(\.scopeKey))
        let hasMissingScope = !expectedScopeKeys.isSubset(of: presentScopeKeys)
        let allSucceeded = !hasMissingScope && coverages.allSatisfy { $0.lastSuccessAt != nil }
        return DayFetchCoverage(
            id: coverageIdentifier(scope: requestedScope, dayStart: dayStart),
            scopeKey: requestedScope.key,
            mailbox: requestedScope.mailbox,
            account: requestedScope.account,
            dayStart: dayStart,
            dayEnd: coverages.map(\.dayEnd).max() ?? dayStart,
            firstTouchedAt: coverages.map(\.firstTouchedAt).min() ?? dayStart,
            lastAttemptAt: coverages.map(\.lastAttemptAt).max() ?? dayStart,
            lastSuccessAt: allSucceeded ? coverages.compactMap(\.lastSuccessAt).min() : nil,
            coveredThrough: allSucceeded ? coverages.compactMap(\.coveredThrough).min() : nil,
            expectedCount: coverages.reduce(0) { $0 + $1.expectedCount },
            fetchedCount: coverages.reduce(0) { $0 + $1.fetchedCount },
            absentCount: coverages.reduce(0) { $0 + $1.absentCount },
            state: DayFetchCoordinator.aggregateState(coverages.map(\.state),
                                                      hasMissingScope: hasMissingScope),
            errorMessage: coverages
                .filter { $0.state == .failed }
                .max(by: { $0.lastAttemptAt < $1.lastAttemptAt })?
                .errorMessage
        )
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

    internal func fetchArchivedInGraphEntries() async throws -> [ArchivedInGraphEntry] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ArchivedInGraphEntity> = ArchivedInGraphEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(ArchivedInGraphEntity.archivedAt),
                                                        ascending: false)]
            return try context.fetch(request).map { $0.toModel() }
        }
    }

    internal func upsertArchivedInGraphEntry(_ entry: ArchivedInGraphEntry) async throws {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ArchivedInGraphEntity> = ArchivedInGraphEntity.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "threadID == %@", entry.threadID)
            let entity = try context.fetch(request).first ?? ArchivedInGraphEntity(context: context)
            entity.threadID = entry.threadID
            entity.archivedAt = entry.archivedAt
            if context.hasChanges {
                try context.save()
            }
        }
    }

    internal func deleteArchivedInGraphEntry(threadID: String) async throws {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ArchivedInGraphEntity> = ArchivedInGraphEntity.fetchRequest()
            request.predicate = NSPredicate(format: "threadID == %@", threadID)
            for entity in try context.fetch(request) {
                context.delete(entity)
            }
            if context.hasChanges {
                try context.save()
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
                             parentID: folder.parentID,
                             mailboxAccount: folder.mailboxAccount,
                             mailboxPath: folder.mailboxPath)
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
                entity.mailboxAccount = folder.mailboxDestination?.account
                entity.mailboxPath = folder.mailboxDestination?.path
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
            let entities = try context.fetch(request)
            return Self.deduplicatedSummaryEntries(from: entities.map { $0.toModel() })
        }
    }

    internal func upsertSummaries(_ summaries: [SummaryCacheEntry]) async throws {
        guard !summaries.isEmpty else { return }
        try await summaryWriteContext.perform {
            let context = self.summaryWriteContext
            let dedupedSummaries = Self.deduplicatedSummaryEntries(from: summaries)
            let ids = dedupedSummaries.map(\.scopeID)
            let scopes = Set(dedupedSummaries.map(\.scope))
            let request: NSFetchRequest<SummaryCacheEntity> = SummaryCacheEntity.fetchRequest()
            request.predicate = NSPredicate(format: "scope IN %@ AND scopeID IN %@", scopes.map(\.rawValue), ids)
            let existing = try context.fetch(request)
            var lookup: [String: SummaryCacheEntity] = [:]

            for entity in existing {
                let key = "\(entity.scope)|\(entity.scopeID)"
                if let prior = lookup[key] {
                    let shouldKeepEntity = prior.generatedAt >= entity.generatedAt
                    if shouldKeepEntity {
                        context.delete(entity)
                    } else {
                        context.delete(prior)
                        lookup[key] = entity
                    }
                } else {
                    lookup[key] = entity
                }
            }

            for summary in dedupedSummaries {
                let key = "\(summary.scope.rawValue)|\(summary.scopeID)"
                if let existingEntity = lookup[key],
                   existingEntity.generatedAt > summary.generatedAt {
                    // A superseded async generation may finish persisting
                    // after its replacement. Never let that older result
                    // overwrite the newer cache entry.
                    continue
                }
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

    internal func fetchGraphAutomationProposals() async throws -> [GraphAutomationProposal] {
        try await organizationWriteContext.perform {
            let request: NSFetchRequest<GraphAutomationRecordEntity> = GraphAutomationRecordEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(GraphAutomationRecordEntity.updatedAt),
                                                        ascending: false)]
            let decoder = JSONDecoder()
            return try self.organizationWriteContext.fetch(request).compactMap { entity in
                try? decoder.decode(GraphAutomationProposal.self, from: entity.payload)
            }
        }
    }

    internal func upsertGraphAutomationProposals(_ proposals: [GraphAutomationProposal]) async throws {
        guard !proposals.isEmpty else { return }
        try await organizationWriteContext.perform {
            let context = self.organizationWriteContext
            try Self.upsertGraphAutomationProposals(proposals, in: context)
            if context.hasChanges { try context.save() }
        }
    }

    internal func fetchGraphAutomationObservations(
        scopeID: String? = nil
    ) async throws -> [GraphAutomationObservation] {
        try await organizationWriteContext.perform {
            let request: NSFetchRequest<GraphAutomationObservationEntity> = GraphAutomationObservationEntity.fetchRequest()
            if let scopeID {
                request.predicate = NSPredicate(format: "scopeID == %@", scopeID)
            }
            return try self.organizationWriteContext.fetch(request).map { $0.toModel() }
        }
    }

    internal func upsertGraphAutomationObservations(
        _ observations: [GraphAutomationObservation]
    ) async throws {
        guard !observations.isEmpty else { return }
        try await organizationWriteContext.perform {
            let context = self.organizationWriteContext
            let ids = observations.map(\.id)
            let request: NSFetchRequest<GraphAutomationObservationEntity> = GraphAutomationObservationEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids)
            let existing = try context.fetch(request)
            var lookup = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for observation in observations {
                let entity = lookup[observation.id] ?? GraphAutomationObservationEntity(context: context)
                entity.id = observation.id
                entity.scopeID = observation.scopeID
                entity.sourceID = observation.sourceID
                entity.fingerprint = observation.fingerprint
                entity.providerVersion = observation.providerVersion
                entity.wasBaseline = observation.wasBaseline
                entity.evaluatedAt = observation.evaluatedAt
                lookup[observation.id] = entity
            }
            if context.hasChanges { try context.save() }
        }
    }

    /// Applies every valid automation row in one Core Data save. The caller
    /// performs semantic and source-fingerprint preflight immediately before
    /// entering this serialized organization transaction.
    internal func applyGraphAutomationBatch(
        _ inputProposals: [GraphAutomationProposal]
    ) async throws -> GraphAutomationBatchPersistenceResult {
        guard !inputProposals.isEmpty else {
            return GraphAutomationBatchPersistenceResult(proposals: [],
                                                         manualGroups: try await fetchManualThreadGroups(),
                                                         folders: try await fetchThreadFolders())
        }

        return try await organizationWriteContext.perform {
            let context = self.organizationWriteContext
            do {
                var groups = try Self.fetchManualThreadGroups(in: context)
                var folders = try Self.fetchThreadFolders(in: context)
                var deletedGroupIDs = Set<String>()
                var persisted: [GraphAutomationProposal] = []

                let ordered = inputProposals.sorted { lhs, rhs in
                    if lhs.action != rhs.action {
                        return lhs.action == .attachToThread
                    }
                    return lhs.id < rhs.id
                }

                for original in ordered {
                    var proposal = original
                    proposal.status = .applying
                    proposal.updatedAt = Date()

                    switch proposal.action {
                    case .attachToThread:
                        guard let targetThreadID = proposal.target.threadID,
                              let resultingThreadID = proposal.steps.compactMap({ step -> String? in
                                  guard case .attach(_, _, let result) = step else { return nil }
                                  return result
                              }).first else {
                            throw GraphAutomationPersistenceError.invalidProposal
                        }

                        let sourceGroupID = proposal.source.manualGroupID
                        let targetGroup = groups[targetThreadID]
                        let sourceGroup = sourceGroupID.flatMap { groups[$0] }

                        let destinationFolderID = proposal.target.folderID
                            ?? folders.first(where: { $0.threadIDs.contains(targetThreadID) })?.id
                        if let destinationFolderID,
                           !folders.contains(where: { $0.id == destinationFolderID }) {
                            throw GraphAutomationPersistenceError.missingTargetFolder(destinationFolderID)
                        }

                        let sourceFolderID = folders.first {
                            $0.threadIDs.contains(proposal.source.effectiveThreadID)
                        }?.id
                        let targetFolderID = folders.first { $0.threadIDs.contains(targetThreadID) }?.id
                        let groupBefore = groups[resultingThreadID]
                        let resultWasPreexisting = sourceGroupID == resultingThreadID ||
                            targetGroup?.id == resultingThreadID
                        let removedSourceGroup = sourceGroupID.flatMap { sourceGroupID in
                            sourceGroupID == resultingThreadID ? nil : sourceGroup
                        }
                        var group = groupBefore
                            ?? targetGroup
                            ?? sourceGroup
                            ?? ManualThreadGroup(id: resultingThreadID,
                                                 jwzThreadIDs: [targetThreadID],
                                                 manualMessageKeys: [])
                        if group.id != resultingThreadID {
                            group = ManualThreadGroup(id: resultingThreadID,
                                                      jwzThreadIDs: group.jwzThreadIDs,
                                                      manualMessageKeys: group.manualMessageKeys)
                        }

                        let sourceJWZ = proposal.source.jwzThreadIDs
                        let sourceManual = proposal.source.manualMessageKeys
                        let jwzBefore = group.jwzThreadIDs
                        let manualBefore = group.manualMessageKeys
                        group.jwzThreadIDs.formUnion(sourceJWZ)
                        group.manualMessageKeys.formUnion(sourceManual)
                        if targetGroup == nil {
                            group.jwzThreadIDs.insert(targetThreadID)
                        }
                        let addedJWZ = group.jwzThreadIDs.subtracting(jwzBefore)
                        let addedManual = group.manualMessageKeys.subtracting(manualBefore)
                        groups[resultingThreadID] = group

                        if let sourceGroupID, sourceGroupID != resultingThreadID {
                            groups.removeValue(forKey: sourceGroupID)
                            deletedGroupIDs.insert(sourceGroupID)
                        }
                        if targetThreadID != resultingThreadID, targetGroup != nil {
                            groups.removeValue(forKey: targetThreadID)
                            deletedGroupIDs.insert(targetThreadID)
                        }

                        let remappedIDs = Set([
                            proposal.source.effectiveThreadID,
                            targetThreadID,
                            sourceGroupID
                        ].compactMap { $0 })
                        for index in folders.indices {
                            folders[index].threadIDs.subtract(remappedIDs)
                        }
                        if let destinationFolderID,
                           let index = folders.firstIndex(where: { $0.id == destinationFolderID }) {
                            folders[index].threadIDs.insert(resultingThreadID)
                        }

                        proposal.mutationDelta = GraphAutomationMutationDelta(
                            resultingManualGroupID: resultingThreadID,
                            manualGroupBefore: groupBefore,
                            removedSourceManualGroup: removedSourceGroup,
                            resultingManualGroupWasPreexisting: resultWasPreexisting,
                            addedJWZThreadIDs: addedJWZ,
                            addedManualMessageKeys: addedManual,
                            sourceThreadIDBefore: proposal.source.effectiveThreadID,
                            targetThreadIDBefore: targetThreadID,
                            sourceFolderIDBefore: sourceFolderID,
                            targetFolderIDBefore: targetFolderID,
                            destinationFolderID: destinationFolderID
                        )

                    case .appendToFolder:
                        guard let destinationFolderID = proposal.target.folderID,
                              let destinationIndex = folders.firstIndex(where: { $0.id == destinationFolderID }) else {
                            throw GraphAutomationPersistenceError.missingTargetFolder(proposal.target.folderID ?? "")
                        }
                        let sourceFolderID = folders.first {
                            $0.threadIDs.contains(proposal.source.effectiveThreadID)
                        }?.id
                        for index in folders.indices {
                            folders[index].threadIDs.remove(proposal.source.effectiveThreadID)
                        }
                        folders[destinationIndex].threadIDs.insert(proposal.source.effectiveThreadID)
                        proposal.mutationDelta = GraphAutomationMutationDelta(
                            resultingManualGroupID: nil,
                            manualGroupBefore: nil,
                            removedSourceManualGroup: nil,
                            resultingManualGroupWasPreexisting: false,
                            addedJWZThreadIDs: [],
                            addedManualMessageKeys: [],
                            sourceThreadIDBefore: proposal.source.effectiveThreadID,
                            targetThreadIDBefore: nil,
                            sourceFolderIDBefore: sourceFolderID,
                            targetFolderIDBefore: nil,
                            destinationFolderID: destinationFolderID
                        )
                    }

                    proposal.status = .applied
                    proposal.mailStatus = proposal.steps.contains { step in
                        if case .mailbox = step { return true }
                        return false
                    } ? .pending : .notRequired
                    proposal.lastError = nil
                    proposal.updatedAt = Date()
                    persisted.append(proposal)
                }

                try Self.replaceManualThreadGroups(Array(groups.values),
                                                   deleting: deletedGroupIDs,
                                                   in: context)
                try Self.replaceThreadFolders(folders, in: context)
                try Self.upsertGraphAutomationProposals(persisted, in: context)
                if context.hasChanges { try context.save() }
                return GraphAutomationBatchPersistenceResult(
                    proposals: persisted,
                    manualGroups: groups.values.sorted { $0.id < $1.id },
                    folders: folders
                )
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    internal func undoGraphAutomationMembership(
        _ original: GraphAutomationProposal
    ) async throws -> GraphAutomationBatchPersistenceResult {
        try await organizationWriteContext.perform {
            let context = self.organizationWriteContext
            do {
                guard let delta = original.mutationDelta else {
                    throw GraphAutomationPersistenceError.invalidProposal
                }
                var proposal = original
                var groups = try Self.fetchManualThreadGroups(in: context)
                var folders = try Self.fetchThreadFolders(in: context)
                var deletedGroupIDs = Set<String>()

                if let groupID = delta.resultingManualGroupID,
                   var currentGroup = groups[groupID] {
                    guard delta.addedJWZThreadIDs.isSubset(of: currentGroup.jwzThreadIDs),
                          delta.addedManualMessageKeys.isSubset(of: currentGroup.manualMessageKeys) else {
                        throw GraphAutomationPersistenceError.staleMutation
                    }
                    currentGroup.jwzThreadIDs.subtract(delta.addedJWZThreadIDs)
                    currentGroup.manualMessageKeys.subtract(delta.addedManualMessageKeys)

                    let targetOnlyJWZ = Set([delta.targetThreadIDBefore].compactMap { $0 })
                    let canRestoreIdentity = !delta.resultingManualGroupWasPreexisting &&
                        currentGroup.jwzThreadIDs == targetOnlyJWZ &&
                        currentGroup.manualMessageKeys.isEmpty
                    if canRestoreIdentity {
                        groups.removeValue(forKey: groupID)
                        deletedGroupIDs.insert(groupID)
                        for index in folders.indices {
                            if folders[index].threadIDs.remove(groupID) != nil,
                               folders[index].id == delta.targetFolderIDBefore,
                               let targetThreadID = delta.targetThreadIDBefore {
                                folders[index].threadIDs.insert(targetThreadID)
                            }
                        }
                    } else {
                        groups[groupID] = currentGroup
                    }
                }

                if let removedSourceGroup = delta.removedSourceManualGroup {
                    guard groups[removedSourceGroup.id] == nil else {
                        throw GraphAutomationPersistenceError.staleMutation
                    }
                    groups[removedSourceGroup.id] = removedSourceGroup
                }

                if original.action == .appendToFolder {
                    for index in folders.indices {
                        if folders[index].id == delta.destinationFolderID {
                            folders[index].threadIDs.remove(delta.sourceThreadIDBefore)
                        }
                    }
                }
                if let sourceFolderID = delta.sourceFolderIDBefore,
                   let index = folders.firstIndex(where: { $0.id == sourceFolderID }) {
                    folders[index].threadIDs.insert(delta.sourceThreadIDBefore)
                }

                proposal.status = .undoing
                proposal.mailStatus = proposal.movedMessages.isEmpty ? .restored : .restoring
                proposal.updatedAt = Date()
                proposal.lastError = nil
                try Self.replaceManualThreadGroups(Array(groups.values),
                                                   deleting: deletedGroupIDs,
                                                   in: context)
                try Self.replaceThreadFolders(folders, in: context)
                try Self.upsertGraphAutomationProposals([proposal], in: context)
                if context.hasChanges { try context.save() }
                return GraphAutomationBatchPersistenceResult(
                    proposals: [proposal],
                    manualGroups: groups.values.sorted { $0.id < $1.id },
                    folders: folders
                )
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    internal func pruneGraphAutomationHistory(now: Date = Date()) async throws {
        try await organizationWriteContext.perform {
            let context = self.organizationWriteContext
            let request: NSFetchRequest<GraphAutomationRecordEntity> = GraphAutomationRecordEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(GraphAutomationRecordEntity.updatedAt),
                                                        ascending: false)]
            let terminal: Set<String> = [
                GraphAutomationExecutionStatus.applied.rawValue,
                GraphAutomationExecutionStatus.rejected.rawValue,
                GraphAutomationExecutionStatus.undone.rawValue,
                GraphAutomationExecutionStatus.stale.rawValue
            ]
            let cutoff = now.addingTimeInterval(-30 * 86_400)
            var retainedTerminal = 0
            for entity in try context.fetch(request) where terminal.contains(entity.status) {
                retainedTerminal += 1
                if entity.updatedAt < cutoff || retainedTerminal > 500 {
                    context.delete(entity)
                }
            }
            if context.hasChanges { try context.save() }
        }
    }

    internal func resetGraphAutomationHistory(includeObservations: Bool) async throws {
        try await organizationWriteContext.perform {
            let context = self.organizationWriteContext
            for entity in try context.fetch(GraphAutomationRecordEntity.fetchRequest()) {
                context.delete(entity)
            }
            if includeObservations {
                for entity in try context.fetch(GraphAutomationObservationEntity.fetchRequest()) {
                    context.delete(entity)
                }
            }
            if context.hasChanges { try context.save() }
        }
    }

    private static func fetchManualThreadGroups(
        in context: NSManagedObjectContext
    ) throws -> [String: ManualThreadGroup] {
        let groupEntities = try context.fetch(ManualThreadGroupEntity.fetchRequest())
        let jwzMappings = try context.fetch(ManualThreadGroupJWZEntity.fetchRequest())
        let messageMappings = try context.fetch(ManualThreadGroupMessageEntity.fetchRequest())
        let jwzByGroup = Dictionary(grouping: jwzMappings, by: \.groupID)
        let messagesByGroup = Dictionary(grouping: messageMappings, by: \.groupID)
        return Dictionary(uniqueKeysWithValues: groupEntities.map { entity in
            let group = ManualThreadGroup(
                id: entity.id,
                jwzThreadIDs: Set(jwzByGroup[entity.id, default: []].map(\.jwzThreadID)),
                manualMessageKeys: Set(messagesByGroup[entity.id, default: []].map(\.messageKey))
            )
            return (group.id, group)
        })
    }

    private static func fetchThreadFolders(
        in context: NSManagedObjectContext
    ) throws -> [ThreadFolder] {
        let folderEntities = try context.fetch(ThreadFolderEntity.fetchRequest())
        let colors = Dictionary(uniqueKeysWithValues: try context.fetch(ThreadFolderColorEntity.fetchRequest()).map {
            ($0.folderID, ThreadFolderColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha))
        })
        let memberships = Dictionary(grouping: try context.fetch(ThreadFolderMembershipEntity.fetchRequest()),
                                     by: \.folderID)
        return folderEntities.map { entity in
            ThreadFolder(id: entity.id,
                         title: entity.title,
                         color: colors[entity.id] ?? .defaultNewFolder,
                         threadIDs: Set(memberships[entity.id, default: []].map(\.threadID)),
                         parentID: entity.parentID,
                         mailboxAccount: entity.mailboxAccount,
                         mailboxPath: entity.mailboxPath)
        }
    }

    private static func replaceManualThreadGroups(
        _ groups: [ManualThreadGroup],
        deleting deletedIDs: Set<String>,
        in context: NSManagedObjectContext
    ) throws {
        let affectedIDs = Set(groups.map(\.id)).union(deletedIDs)
        guard !affectedIDs.isEmpty else { return }
        let groupRequest: NSFetchRequest<ManualThreadGroupEntity> = ManualThreadGroupEntity.fetchRequest()
        groupRequest.predicate = NSPredicate(format: "id IN %@", Array(affectedIDs))
        var entities = Dictionary(uniqueKeysWithValues: try context.fetch(groupRequest).map { ($0.id, $0) })
        let jwzRequest: NSFetchRequest<ManualThreadGroupJWZEntity> = ManualThreadGroupJWZEntity.fetchRequest()
        jwzRequest.predicate = NSPredicate(format: "groupID IN %@", Array(affectedIDs))
        try context.fetch(jwzRequest).forEach(context.delete)
        let messageRequest: NSFetchRequest<ManualThreadGroupMessageEntity> = ManualThreadGroupMessageEntity.fetchRequest()
        messageRequest.predicate = NSPredicate(format: "groupID IN %@", Array(affectedIDs))
        try context.fetch(messageRequest).forEach(context.delete)
        for deletedID in deletedIDs {
            if let entity = entities.removeValue(forKey: deletedID) { context.delete(entity) }
        }
        for group in groups {
            let entity = entities[group.id] ?? ManualThreadGroupEntity(context: context)
            entity.id = group.id
            for threadID in group.jwzThreadIDs {
                let mapping = ManualThreadGroupJWZEntity(context: context)
                mapping.groupID = group.id
                mapping.jwzThreadID = threadID
            }
            for messageKey in group.manualMessageKeys {
                let mapping = ManualThreadGroupMessageEntity(context: context)
                mapping.groupID = group.id
                mapping.messageKey = messageKey
            }
        }
    }

    private static func replaceThreadFolders(
        _ folders: [ThreadFolder],
        in context: NSManagedObjectContext
    ) throws {
        let ids = folders.map(\.id)
        guard !ids.isEmpty else { return }
        let folderRequest: NSFetchRequest<ThreadFolderEntity> = ThreadFolderEntity.fetchRequest()
        folderRequest.predicate = NSPredicate(format: "id IN %@", ids)
        var folderEntities = Dictionary(uniqueKeysWithValues: try context.fetch(folderRequest).map { ($0.id, $0) })
        let colorRequest: NSFetchRequest<ThreadFolderColorEntity> = ThreadFolderColorEntity.fetchRequest()
        colorRequest.predicate = NSPredicate(format: "folderID IN %@", ids)
        try context.fetch(colorRequest).forEach(context.delete)
        let membershipRequest: NSFetchRequest<ThreadFolderMembershipEntity> = ThreadFolderMembershipEntity.fetchRequest()
        membershipRequest.predicate = NSPredicate(format: "folderID IN %@", ids)
        try context.fetch(membershipRequest).forEach(context.delete)
        for folder in folders {
            let entity = folderEntities[folder.id] ?? ThreadFolderEntity(context: context)
            entity.id = folder.id
            entity.title = folder.title
            entity.parentID = folder.parentID
            entity.mailboxAccount = folder.mailboxDestination?.account
            entity.mailboxPath = folder.mailboxDestination?.path
            folderEntities[folder.id] = entity
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
    }

    private static func upsertGraphAutomationProposals(
        _ proposals: [GraphAutomationProposal],
        in context: NSManagedObjectContext
    ) throws {
        guard !proposals.isEmpty else { return }
        let ids = proposals.map(\.id)
        let request: NSFetchRequest<GraphAutomationRecordEntity> = GraphAutomationRecordEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids)
        var lookup = Dictionary(uniqueKeysWithValues: try context.fetch(request).map { ($0.id, $0) })
        let encoder = JSONEncoder()
        for proposal in proposals {
            let entity = lookup[proposal.id] ?? GraphAutomationRecordEntity(context: context)
            entity.id = proposal.id
            entity.status = proposal.status.rawValue
            entity.updatedAt = proposal.updatedAt
            entity.payload = try encoder.encode(proposal)
            lookup[proposal.id] = entity
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
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMailbox.isEmpty else {
            return NSPredicate(value: false)
        }

        if includeAllInboxesAliases {
            let inboxAliases = ["inbox", "all inboxes"]
            let aliasPredicates = inboxAliases.map {
                NSPredicate(format: "mailboxID ==[c] %@", $0)
            }
            return NSCompoundPredicate(orPredicateWithSubpredicates: aliasPredicates)
        }

        return NSPredicate(format: "mailboxID ==[c] %@", trimmedMailbox)
    }

    private static func deduplicatedSummaryEntries(from entries: [SummaryCacheEntry]) -> [SummaryCacheEntry] {
        var deduped: [String: SummaryCacheEntry] = [:]
        deduped.reserveCapacity(entries.count)

        for entry in entries {
            let key = "\(entry.scope.rawValue)|\(entry.scopeID)"
            if let prior = deduped[key], prior.generatedAt >= entry.generatedAt {
                continue
            }
            deduped[key] = entry
        }

        return Array(deduped.values)
    }

    internal static func makeModel(includeCalendarMessageKind: Bool = true,
                                   includeEmbeddedMessages: Bool = true) -> NSManagedObjectModel {
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

        let internalMailIDAttr = NSAttributeDescription()
        internalMailIDAttr.name = "internalMailID"
        internalMailIDAttr.attributeType = .stringAttributeType
        internalMailIDAttr.isOptional = true
        internalMailIDAttr.isIndexed = true

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

        let calendarRSVPAttr = NSAttributeDescription()
        calendarRSVPAttr.name = "isCalendarRSVP"
        calendarRSVPAttr.attributeType = .booleanAttributeType
        calendarRSVPAttr.isOptional = false
        calendarRSVPAttr.defaultValue = false

        let calendarMessageKindAttr = NSAttributeDescription()
        calendarMessageKindAttr.name = "calendarMessageKindRaw"
        calendarMessageKindAttr.attributeType = .stringAttributeType
        calendarMessageKindAttr.isOptional = true

        let inReplyAttr = NSAttributeDescription()
        inReplyAttr.name = "inReplyTo"
        inReplyAttr.attributeType = .stringAttributeType
        inReplyAttr.isOptional = true

        let referencesAttr = NSAttributeDescription()
        referencesAttr.name = "referencesData"
        referencesAttr.attributeType = .binaryDataAttributeType
        referencesAttr.isOptional = true

        let embeddedMessagesAttr = NSAttributeDescription()
        embeddedMessagesAttr.name = "embeddedMessagesData"
        embeddedMessagesAttr.attributeType = .binaryDataAttributeType
        embeddedMessagesAttr.isOptional = true

        let threadAttr = NSAttributeDescription()
        threadAttr.name = "threadID"
        threadAttr.attributeType = .stringAttributeType
        threadAttr.isOptional = true
        threadAttr.isIndexed = true

        let rawAttr = NSAttributeDescription()
        rawAttr.name = "rawSourcePath"
        rawAttr.attributeType = .stringAttributeType
        rawAttr.isOptional = true

        let sourceAbsentAtAttr = NSAttributeDescription()
        sourceAbsentAtAttr.name = "sourceAbsentAt"
        sourceAbsentAtAttr.attributeType = .dateAttributeType
        sourceAbsentAtAttr.isOptional = true
        sourceAbsentAtAttr.isIndexed = true

        let sourceAbsentScopeKeyAttr = NSAttributeDescription()
        sourceAbsentScopeKeyAttr.name = "sourceAbsentScopeKey"
        sourceAbsentScopeKeyAttr.attributeType = .stringAttributeType
        sourceAbsentScopeKeyAttr.isOptional = true

        var messageProperties: [NSPropertyDescription] = [
            idAttr,
            msgIDAttr,
            normalizedAttr,
            internalMailIDAttr,
            mailboxAttr,
            accountAttr,
            subjectAttr,
            fromAttr,
            toAttr,
            dateAttr,
            snippetAttr,
            unreadAttr,
            calendarRSVPAttr,
            inReplyAttr,
            referencesAttr,
            threadAttr,
            rawAttr,
            sourceAbsentAtAttr,
            sourceAbsentScopeKeyAttr
        ]
        if includeCalendarMessageKind {
            messageProperties.insert(calendarMessageKindAttr,
                                     at: messageProperties.firstIndex(of: inReplyAttr) ?? messageProperties.endIndex)
        }
        if includeEmbeddedMessages {
            messageProperties.insert(embeddedMessagesAttr,
                                     at: messageProperties.firstIndex(of: threadAttr) ?? messageProperties.endIndex)
        }
        messageEntity.properties = messageProperties

        let dayFetchCoverageEntity = NSEntityDescription()
        dayFetchCoverageEntity.name = "DayFetchCoverageEntity"
        dayFetchCoverageEntity.managedObjectClassName = NSStringFromClass(DayFetchCoverageEntity.self)

        func coverageAttribute(_ name: String,
                               type: NSAttributeType,
                               optional: Bool = false,
                               indexed: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            attribute.isIndexed = indexed
            return attribute
        }

        dayFetchCoverageEntity.properties = [
            coverageAttribute("id", type: .stringAttributeType, indexed: true),
            coverageAttribute("scopeKey", type: .stringAttributeType, indexed: true),
            coverageAttribute("mailbox", type: .stringAttributeType),
            coverageAttribute("account", type: .stringAttributeType, optional: true),
            coverageAttribute("dayStart", type: .dateAttributeType, indexed: true),
            coverageAttribute("dayEnd", type: .dateAttributeType),
            coverageAttribute("firstTouchedAt", type: .dateAttributeType),
            coverageAttribute("lastAttemptAt", type: .dateAttributeType),
            coverageAttribute("lastSuccessAt", type: .dateAttributeType, optional: true),
            coverageAttribute("coveredThrough", type: .dateAttributeType, optional: true),
            coverageAttribute("expectedCount", type: .integer64AttributeType),
            coverageAttribute("fetchedCount", type: .integer64AttributeType),
            coverageAttribute("absentCount", type: .integer64AttributeType),
            coverageAttribute("stateRaw", type: .stringAttributeType),
            coverageAttribute("errorMessage", type: .stringAttributeType, optional: true)
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

        let threadFolderMailboxAccountAttr = NSAttributeDescription()
        threadFolderMailboxAccountAttr.name = "mailboxAccount"
        threadFolderMailboxAccountAttr.attributeType = .stringAttributeType
        threadFolderMailboxAccountAttr.isOptional = true

        let threadFolderMailboxPathAttr = NSAttributeDescription()
        threadFolderMailboxPathAttr.name = "mailboxPath"
        threadFolderMailboxPathAttr.attributeType = .stringAttributeType
        threadFolderMailboxPathAttr.isOptional = true

        threadFolderEntity.properties = [
            threadFolderIDAttr,
            threadFolderTitleAttr,
            threadFolderParentIDAttr,
            threadFolderMailboxAccountAttr,
            threadFolderMailboxPathAttr
        ]

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

        let actionItemEntity = NSEntityDescription()
        actionItemEntity.name = "ActionItemEntity"
        actionItemEntity.managedObjectClassName = NSStringFromClass(ActionItemEntity.self)

        let aiMessageIDAttr = NSAttributeDescription()
        aiMessageIDAttr.name = "messageID"
        aiMessageIDAttr.attributeType = .stringAttributeType
        aiMessageIDAttr.isOptional = false
        aiMessageIDAttr.isIndexed = true

        let aiAccountNameAttr = NSAttributeDescription()
        aiAccountNameAttr.name = "accountName"
        aiAccountNameAttr.attributeType = .stringAttributeType
        aiAccountNameAttr.isOptional = true
        aiAccountNameAttr.isIndexed = true

        let aiThreadIDAttr = NSAttributeDescription()
        aiThreadIDAttr.name = "threadID"
        aiThreadIDAttr.attributeType = .stringAttributeType
        aiThreadIDAttr.isOptional = false

        let aiSubjectAttr = NSAttributeDescription()
        aiSubjectAttr.name = "subject"
        aiSubjectAttr.attributeType = .stringAttributeType
        aiSubjectAttr.isOptional = false

        let aiFromAttr = NSAttributeDescription()
        aiFromAttr.name = "fromAddress"
        aiFromAttr.attributeType = .stringAttributeType
        aiFromAttr.isOptional = false

        let aiDateAttr = NSAttributeDescription()
        aiDateAttr.name = "date"
        aiDateAttr.attributeType = .dateAttributeType
        aiDateAttr.isOptional = false

        let aiFolderIDAttr = NSAttributeDescription()
        aiFolderIDAttr.name = "folderID"
        aiFolderIDAttr.attributeType = .stringAttributeType
        aiFolderIDAttr.isOptional = true

        let aiTagsAttr = NSAttributeDescription()
        aiTagsAttr.name = "tagsData"
        aiTagsAttr.attributeType = .binaryDataAttributeType
        aiTagsAttr.isOptional = true

        let aiIsDoneAttr = NSAttributeDescription()
        aiIsDoneAttr.name = "isDone"
        aiIsDoneAttr.attributeType = .booleanAttributeType
        aiIsDoneAttr.isOptional = false
        aiIsDoneAttr.defaultValue = false

        let aiAddedAtAttr = NSAttributeDescription()
        aiAddedAtAttr.name = "addedAt"
        aiAddedAtAttr.attributeType = .dateAttributeType
        aiAddedAtAttr.isOptional = false

        actionItemEntity.properties = [
            aiMessageIDAttr,
            aiAccountNameAttr,
            aiThreadIDAttr,
            aiSubjectAttr,
            aiFromAttr,
            aiDateAttr,
            aiFolderIDAttr,
            aiTagsAttr,
            aiIsDoneAttr,
            aiAddedAtAttr
        ]

        let archivedInGraphEntity = NSEntityDescription()
        archivedInGraphEntity.name = "ArchivedInGraphEntity"
        archivedInGraphEntity.managedObjectClassName = NSStringFromClass(ArchivedInGraphEntity.self)

        let archivedThreadIDAttr = NSAttributeDescription()
        archivedThreadIDAttr.name = "threadID"
        archivedThreadIDAttr.attributeType = .stringAttributeType
        archivedThreadIDAttr.isOptional = false
        archivedThreadIDAttr.isIndexed = true

        let archivedAtAttr = NSAttributeDescription()
        archivedAtAttr.name = "archivedAt"
        archivedAtAttr.attributeType = .dateAttributeType
        archivedAtAttr.isOptional = false

        archivedInGraphEntity.properties = [
            archivedThreadIDAttr,
            archivedAtAttr
        ]

        let graphAutomationRecordEntity = NSEntityDescription()
        graphAutomationRecordEntity.name = "GraphAutomationRecordEntity"
        graphAutomationRecordEntity.managedObjectClassName = NSStringFromClass(GraphAutomationRecordEntity.self)

        let graphAutomationRecordIDAttr = NSAttributeDescription()
        graphAutomationRecordIDAttr.name = "id"
        graphAutomationRecordIDAttr.attributeType = .stringAttributeType
        graphAutomationRecordIDAttr.isOptional = false
        graphAutomationRecordIDAttr.isIndexed = true

        let graphAutomationRecordStatusAttr = NSAttributeDescription()
        graphAutomationRecordStatusAttr.name = "status"
        graphAutomationRecordStatusAttr.attributeType = .stringAttributeType
        graphAutomationRecordStatusAttr.isOptional = false
        graphAutomationRecordStatusAttr.isIndexed = true

        let graphAutomationRecordUpdatedAtAttr = NSAttributeDescription()
        graphAutomationRecordUpdatedAtAttr.name = "updatedAt"
        graphAutomationRecordUpdatedAtAttr.attributeType = .dateAttributeType
        graphAutomationRecordUpdatedAtAttr.isOptional = false

        let graphAutomationRecordPayloadAttr = NSAttributeDescription()
        graphAutomationRecordPayloadAttr.name = "payload"
        graphAutomationRecordPayloadAttr.attributeType = .binaryDataAttributeType
        graphAutomationRecordPayloadAttr.isOptional = false
        graphAutomationRecordPayloadAttr.allowsExternalBinaryDataStorage = true

        graphAutomationRecordEntity.properties = [
            graphAutomationRecordIDAttr,
            graphAutomationRecordStatusAttr,
            graphAutomationRecordUpdatedAtAttr,
            graphAutomationRecordPayloadAttr
        ]

        let graphAutomationObservationEntity = NSEntityDescription()
        graphAutomationObservationEntity.name = "GraphAutomationObservationEntity"
        graphAutomationObservationEntity.managedObjectClassName = NSStringFromClass(GraphAutomationObservationEntity.self)

        let graphAutomationObservationIDAttr = NSAttributeDescription()
        graphAutomationObservationIDAttr.name = "id"
        graphAutomationObservationIDAttr.attributeType = .stringAttributeType
        graphAutomationObservationIDAttr.isOptional = false
        graphAutomationObservationIDAttr.isIndexed = true

        let graphAutomationObservationScopeAttr = NSAttributeDescription()
        graphAutomationObservationScopeAttr.name = "scopeID"
        graphAutomationObservationScopeAttr.attributeType = .stringAttributeType
        graphAutomationObservationScopeAttr.isOptional = false
        graphAutomationObservationScopeAttr.isIndexed = true

        let graphAutomationObservationSourceAttr = NSAttributeDescription()
        graphAutomationObservationSourceAttr.name = "sourceID"
        graphAutomationObservationSourceAttr.attributeType = .stringAttributeType
        graphAutomationObservationSourceAttr.isOptional = false
        graphAutomationObservationSourceAttr.isIndexed = true

        let graphAutomationObservationFingerprintAttr = NSAttributeDescription()
        graphAutomationObservationFingerprintAttr.name = "fingerprint"
        graphAutomationObservationFingerprintAttr.attributeType = .stringAttributeType
        graphAutomationObservationFingerprintAttr.isOptional = false

        let graphAutomationObservationProviderAttr = NSAttributeDescription()
        graphAutomationObservationProviderAttr.name = "providerVersion"
        graphAutomationObservationProviderAttr.attributeType = .stringAttributeType
        graphAutomationObservationProviderAttr.isOptional = false

        let graphAutomationObservationBaselineAttr = NSAttributeDescription()
        graphAutomationObservationBaselineAttr.name = "wasBaseline"
        graphAutomationObservationBaselineAttr.attributeType = .booleanAttributeType
        graphAutomationObservationBaselineAttr.isOptional = false
        graphAutomationObservationBaselineAttr.defaultValue = false

        let graphAutomationObservationEvaluatedAtAttr = NSAttributeDescription()
        graphAutomationObservationEvaluatedAtAttr.name = "evaluatedAt"
        graphAutomationObservationEvaluatedAtAttr.attributeType = .dateAttributeType
        graphAutomationObservationEvaluatedAtAttr.isOptional = false

        graphAutomationObservationEntity.properties = [
            graphAutomationObservationIDAttr,
            graphAutomationObservationScopeAttr,
            graphAutomationObservationSourceAttr,
            graphAutomationObservationFingerprintAttr,
            graphAutomationObservationProviderAttr,
            graphAutomationObservationBaselineAttr,
            graphAutomationObservationEvaluatedAtAttr
        ]

        model.entities = [
            messageEntity,
            dayFetchCoverageEntity,
            threadEntity,
            overrideEntity,
            manualGroupEntity,
            manualGroupJWZEntity,
            manualGroupMessageEntity,
            threadFolderEntity,
            threadFolderColorEntity,
            threadFolderMembershipEntity,
            threadSummaryEntity,
            summaryCacheEntity,
            actionItemEntity,
            archivedInGraphEntity,
            graphAutomationRecordEntity,
            graphAutomationObservationEntity
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

    // Note: `tags:` extends the spec's 2-param signature to support tag snapshotting.
    internal func addActionItem(for message: EmailMessage,
                                 folderID: String?,
                                 tags: [String]) async {
        _ = try? await container.performBackgroundTask { context -> Void in
            let request = ActionItemEntity.fetchRequest()
            request.predicate = NSPredicate(format: "messageID == %@", message.messageID)
            let existing = try context.fetch(request)
            let normalizedAccount = message.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.contains(where: {
                ($0.accountName ?? "").caseInsensitiveCompare(normalizedAccount) == .orderedSame
            }) {
                return // idempotent within the physical account
            }
            if let legacy = existing.first(where: {
                ($0.accountName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                legacy.accountName = normalizedAccount
                try context.save()
                return
            }
            let entity = ActionItemEntity(context: context)
            entity.messageID = message.messageID
            entity.accountName = normalizedAccount
            entity.threadID = message.threadID ?? message.messageID
            entity.subject = message.subject
            entity.fromAddress = message.from
            entity.date = message.date
            entity.folderID = folderID
            entity.tagsData = try? JSONEncoder().encode(Array(tags.prefix(3)))
            entity.isDone = false
            entity.addedAt = Date()
            try context.save()
        }
    }

    internal func removeActionItem(for message: EmailMessage) async {
        _ = try? await container.performBackgroundTask { context -> Void in
            let request = ActionItemEntity.fetchRequest()
            request.predicate = NSPredicate(format: "messageID == %@", message.messageID)
            let entities = try context.fetch(request)
            let normalizedAccount = message.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            entities.filter {
                let storedAccount = ($0.accountName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return storedAccount.isEmpty ||
                    storedAccount.caseInsensitiveCompare(normalizedAccount) == .orderedSame
            }.forEach { context.delete($0) }
            try context.save()
        }
    }

    internal func toggleActionItemDone(_ item: ActionItem) async {
        _ = try? await container.performBackgroundTask { context -> Void in
            let request = ActionItemEntity.fetchRequest()
            request.predicate = NSPredicate(format: "messageID == %@", item.messageID)
            let entities = try context.fetch(request)
            let normalizedAccount = item.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let entity = entities.first(where: {
                let storedAccount = ($0.accountName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if normalizedAccount.isEmpty {
                    return storedAccount.isEmpty
                }
                return storedAccount.caseInsensitiveCompare(normalizedAccount) == .orderedSame
            }) else { return }
            entity.isDone.toggle()
            try context.save()
        }
    }

    internal func fetchActionItems() async -> [ActionItem] {
        (try? await container.performBackgroundTask { context -> [ActionItem] in
            let request = ActionItemEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "addedAt", ascending: false)]
            let entities = try context.fetch(request)
            let messageIDs = entities.map(\.messageID)
            guard !messageIDs.isEmpty else { return [] }
            let messageRequest: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            messageRequest.predicate = NSPredicate(format: "messageID IN %@", messageIDs)
            let storedMessages = try context.fetch(messageRequest)
            let storedMessageIDs = Set(storedMessages.map {
                JWZThreader.normalizeIdentifier($0.messageID)
            })
            let storedScopedIDs = Set(storedMessages.map {
                ActionItem.scopedID(messageID: $0.messageID,
                                    accountName: $0.accountName ?? "")
            })
            let visibleMessages = storedMessages.compactMap { entity -> EmailMessage? in
                guard entity.sourceAbsentAt == nil,
                      let message = entity.toModel(),
                      !message.isCalendarRSVP else { return nil }
                return message
            }
            let visibleMessageIDs = Set(visibleMessages.map {
                JWZThreader.normalizeIdentifier($0.messageID)
            })
            let visibleScopedIDs = Set(visibleMessages.map { ActionItem.scopedID(for: $0) })
            return entities.compactMap { entity in
                // Older action-item rows can predate message caching. Preserve
                // those records; suppress only items whose stored source row
                // is known to be absent or an attendance-only RSVP.
                let accountName = (entity.accountName ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if accountName.isEmpty {
                    let normalizedMessageID = JWZThreader.normalizeIdentifier(entity.messageID)
                    guard !storedMessageIDs.contains(normalizedMessageID) ||
                            visibleMessageIDs.contains(normalizedMessageID) else { return nil }
                } else {
                    let scopedID = ActionItem.scopedID(messageID: entity.messageID,
                                                      accountName: accountName)
                    guard !storedScopedIDs.contains(scopedID) ||
                            visibleScopedIDs.contains(scopedID) else { return nil }
                }
                return entity.toModel()
            }
        }) ?? []
    }

    internal func fetchActionItemIDs() async -> Set<String> {
        Set(await fetchActionItems().map(\.id))
    }
}

@objc(MessageEntity)
internal final class MessageEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var messageID: String
    @NSManaged var normalizedMessageID: String
    @NSManaged var internalMailID: String?
    @NSManaged var mailboxID: String
    @NSManaged var accountName: String?
    @NSManaged var subject: String
    @NSManaged var fromAddress: String
    @NSManaged var toAddress: String
    @NSManaged var date: Date
    @NSManaged var snippet: String
    @NSManaged var isUnread: Bool
    @NSManaged var isCalendarRSVP: Bool
    @NSManaged var calendarMessageKindRaw: String?
    @NSManaged var inReplyTo: String?
    @NSManaged var referencesData: Data?
    @NSManaged var embeddedMessagesData: Data?
    @NSManaged var threadID: String?
    @NSManaged var rawSourcePath: String?
    @NSManaged var sourceAbsentAt: Date?
    @NSManaged var sourceAbsentScopeKey: String?

    internal func toModel() -> EmailMessage? {
        let refs: [String]
        if let data = referencesData, let decoded = try? JSONDecoder().decode([String].self, from: data) {
            refs = decoded
        } else {
            refs = []
        }
        let embeddedMessages: [EmbeddedEmailMessage]
        if let data = embeddedMessagesData,
           let decoded = try? JSONDecoder().decode([EmbeddedEmailMessage].self, from: data) {
            embeddedMessages = decoded
        } else {
            embeddedMessages = []
        }
        let rawURL = rawSourcePath.flatMap { URL(fileURLWithPath: $0) }
        return EmailMessage(id: id,
                            messageID: messageID,
                            internalMailID: internalMailID,
                            mailboxID: mailboxID,
                            accountName: accountName ?? "",
                            subject: subject,
                            from: fromAddress,
                            to: toAddress,
                            date: date,
                            snippet: snippet,
                            isUnread: isUnread,
                            isCalendarRSVP: isCalendarRSVP,
                            calendarMessageKind: calendarMessageKindRaw.flatMap(CalendarMessageKind.init(rawValue:)),
                            inReplyTo: inReplyTo,
                            references: refs,
                            threadID: threadID,
                            rawSourceLocation: rawURL,
                            embeddedMessages: embeddedMessages)
    }
}

internal extension MessageEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<MessageEntity> {
        NSFetchRequest<MessageEntity>(entityName: "MessageEntity")
    }
}

@objc(DayFetchCoverageEntity)
internal final class DayFetchCoverageEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var scopeKey: String
    @NSManaged var mailbox: String
    @NSManaged var account: String?
    @NSManaged var dayStart: Date
    @NSManaged var dayEnd: Date
    @NSManaged var firstTouchedAt: Date
    @NSManaged var lastAttemptAt: Date
    @NSManaged var lastSuccessAt: Date?
    @NSManaged var coveredThrough: Date?
    @NSManaged var expectedCount: Int64
    @NSManaged var fetchedCount: Int64
    @NSManaged var absentCount: Int64
    @NSManaged var stateRaw: String
    @NSManaged var errorMessage: String?

    internal func toModel() -> DayFetchCoverage {
        DayFetchCoverage(id: id,
                         scopeKey: scopeKey,
                         mailbox: mailbox,
                         account: account,
                         dayStart: dayStart,
                         dayEnd: dayEnd,
                         firstTouchedAt: firstTouchedAt,
                         lastAttemptAt: lastAttemptAt,
                         lastSuccessAt: lastSuccessAt,
                         coveredThrough: coveredThrough,
                         expectedCount: Int(expectedCount),
                         fetchedCount: Int(fetchedCount),
                         absentCount: Int(absentCount),
                         state: DayCoverageState(rawValue: stateRaw) ?? .unknown,
                         errorMessage: errorMessage)
    }
}

internal extension DayFetchCoverageEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<DayFetchCoverageEntity> {
        NSFetchRequest<DayFetchCoverageEntity>(entityName: "DayFetchCoverageEntity")
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
    @NSManaged var mailboxAccount: String?
    @NSManaged var mailboxPath: String?
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

@objc(GraphAutomationRecordEntity)
internal final class GraphAutomationRecordEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var status: String
    @NSManaged var updatedAt: Date
    @NSManaged var payload: Data
}

internal extension GraphAutomationRecordEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<GraphAutomationRecordEntity> {
        NSFetchRequest<GraphAutomationRecordEntity>(entityName: "GraphAutomationRecordEntity")
    }
}

@objc(GraphAutomationObservationEntity)
internal final class GraphAutomationObservationEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var scopeID: String
    @NSManaged var sourceID: String
    @NSManaged var fingerprint: String
    @NSManaged var providerVersion: String
    @NSManaged var wasBaseline: Bool
    @NSManaged var evaluatedAt: Date

    internal func toModel() -> GraphAutomationObservation {
        GraphAutomationObservation(scopeID: scopeID,
                                   sourceID: sourceID,
                                   fingerprint: fingerprint,
                                   providerVersion: providerVersion,
                                   wasBaseline: wasBaseline,
                                   evaluatedAt: evaluatedAt)
    }
}

internal extension GraphAutomationObservationEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<GraphAutomationObservationEntity> {
        NSFetchRequest<GraphAutomationObservationEntity>(entityName: "GraphAutomationObservationEntity")
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

@objc(ActionItemEntity)
private final class ActionItemEntity: NSManagedObject {
    @NSManaged var messageID: String
    @NSManaged var accountName: String?
    @NSManaged var threadID: String
    @NSManaged var subject: String
    @NSManaged var fromAddress: String
    @NSManaged var date: Date
    @NSManaged var folderID: String?
    @NSManaged var tagsData: Data?   // JSON-encoded [String]
    @NSManaged var isDone: Bool
    @NSManaged var addedAt: Date

    fileprivate func toModel() -> ActionItem? {
        let tags: [String]
        if let data = tagsData,
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            tags = decoded
        } else {
            tags = []
        }
        return ActionItem(messageID: messageID,
                          accountName: accountName ?? "",
                          threadID: threadID,
                          subject: subject,
                          from: fromAddress,
                          date: date,
                          folderID: folderID,
                          tags: tags,
                          isDone: isDone,
                          addedAt: addedAt)
    }
}

private extension ActionItemEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ActionItemEntity> {
        NSFetchRequest<ActionItemEntity>(entityName: "ActionItemEntity")
    }
}

@objc(ArchivedInGraphEntity)
internal final class ArchivedInGraphEntity: NSManagedObject {
    @NSManaged var threadID: String
    @NSManaged var archivedAt: Date

    internal func toModel() -> ArchivedInGraphEntry {
        ArchivedInGraphEntry(threadID: threadID, archivedAt: archivedAt)
    }
}

internal extension ArchivedInGraphEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ArchivedInGraphEntity> {
        NSFetchRequest<ArchivedInGraphEntity>(entityName: "ArchivedInGraphEntity")
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
