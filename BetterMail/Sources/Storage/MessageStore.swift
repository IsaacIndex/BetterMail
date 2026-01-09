import CoreData
import Foundation

final class MessageStore {
    static let shared = MessageStore()

    private let container: NSPersistentContainer
    private let userDefaults: UserDefaults
    private let lastSyncKey = "MessageStore.lastSync"

    var lastSyncDate: Date? {
        get { userDefaults.object(forKey: lastSyncKey) as? Date }
        set { userDefaults.set(newValue, forKey: lastSyncKey) }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let model = MessageStore.makeModel()
        container = NSPersistentContainer(name: "BetterMailModel", managedObjectModel: model)
        let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BetterMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        let sqliteURL = storeURL.appendingPathComponent("Messages.sqlite")
        let description = NSPersistentStoreDescription(url: sqliteURL)
        description.shouldInferMappingModelAutomatically = true
        description.shouldMigrateStoreAutomatically = true
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Failed to load persistent store: \(error)")
            }
        }
    }

    func upsert(messages: [EmailMessage]) async throws {
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

    func fetchMessages(limit: Int? = nil) async throws -> [EmailMessage] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(MessageEntity.date), ascending: false)]
            if let limit { request.fetchLimit = limit }
            let entities = try context.fetch(request)
            return entities.compactMap { $0.toModel() }
        }
    }

    func fetchThreads(limit: Int? = nil) async throws -> [EmailThread] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ThreadEntity> = ThreadEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(ThreadEntity.lastUpdated), ascending: false)]
            if let limit { request.fetchLimit = limit }
            return try context.fetch(request).map { $0.toModel() }
        }
    }

    func fetchManualThreadOverrides() async throws -> [String: String] {
        try await container.performBackgroundTask { context in
            let request: NSFetchRequest<ManualThreadOverrideEntity> = ManualThreadOverrideEntity.fetchRequest()
            let overrides = try context.fetch(request)
            return overrides.reduce(into: [String: String]()) { result, override in
                result[override.messageKey] = override.threadID
            }
        }
    }

    func upsertManualThreadOverrides(_ overrides: [String: String]) async throws {
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

    func deleteManualThreadOverrides(messageKeys: [String]) async throws {
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

    func updateThreadMembership(_ map: [String: String], threads: [EmailThread]) async throws {
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

        model.entities = [messageEntity, threadEntity, overrideEntity]
        return model
    }
}

@objc(MessageEntity)
final class MessageEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var messageID: String
    @NSManaged var normalizedMessageID: String
    @NSManaged var mailboxID: String
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

    func toModel() -> EmailMessage? {
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

extension MessageEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<MessageEntity> {
        NSFetchRequest<MessageEntity>(entityName: "MessageEntity")
    }
}

@objc(ThreadEntity)
final class ThreadEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var rootMessageID: String?
    @NSManaged var subject: String
    @NSManaged var lastUpdated: Date
    @NSManaged var unreadCount: Int32
    @NSManaged var messageCount: Int32

    func toModel() -> EmailThread {
        EmailThread(id: id,
                    rootMessageID: rootMessageID,
                    subject: subject,
                    lastUpdated: lastUpdated,
                    unreadCount: Int(unreadCount),
                    messageCount: Int(messageCount))
    }
}

extension ThreadEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ThreadEntity> {
        NSFetchRequest<ThreadEntity>(entityName: "ThreadEntity")
    }
}

@objc(ManualThreadOverrideEntity)
final class ManualThreadOverrideEntity: NSManagedObject {
    @NSManaged var messageKey: String
    @NSManaged var threadID: String
}

extension ManualThreadOverrideEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ManualThreadOverrideEntity> {
        NSFetchRequest<ManualThreadOverrideEntity>(entityName: "ManualThreadOverrideEntity")
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
