import CoreData
import XCTest
@testable import BetterMail

@MainActor
final class CalendarThreadRecoveryTests: XCTestCase {
    func test_threadingFetch_recoversCachedOlderInvitationAcrossMailboxWindow() async throws {
        let defaults = UserDefaults(suiteName: "CalendarThreadingFetch-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let recent = Date(timeIntervalSince1970: 2_000_000)
        let invitation = makeCalendarMessage(id: "invite",
                                             mailbox: "Archive",
                                             account: "Work",
                                             date: recent.addingTimeInterval(-30 * 86_400),
                                             kind: .invitation)
        let rsvp = makeCalendarMessage(id: "rsvp",
                                       mailbox: "Inbox",
                                       account: "Work",
                                       date: recent,
                                       kind: .attendanceOnlyResponse,
                                       inReplyTo: invitation.messageID,
                                       references: [invitation.messageID])
        let supplement = makeCalendarMessage(id: "supplement",
                                             mailbox: "Inbox",
                                             account: "Work",
                                             date: recent.addingTimeInterval(60),
                                             kind: .ordinaryMessage,
                                             inReplyTo: rsvp.messageID,
                                             references: [invitation.messageID, rsvp.messageID])
        try await store.upsert(messages: [invitation, rsvp, supplement])

        let messages = try await store.fetchMessagesForThreading(
            since: recent.addingTimeInterval(-60),
            mailbox: "Inbox",
            account: "Work"
        )

        XCTAssertEqual(Set(messages.map(\.messageID)), ["invite", "rsvp", "supplement"])
        XCTAssertTrue(messages.first { $0.messageID == "rsvp" }?.isCalendarRSVP == true)
    }

    func test_threadingFetch_neverUsesSameMessageIDFromAnotherAccountAsAncestor() async throws {
        let defaults = UserDefaults(suiteName: "CalendarThreadingAccountScope-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let recent = Date(timeIntervalSince1970: 2_000_000)
        let otherAccountInvite = makeCalendarMessage(id: "shared-id",
                                                      mailbox: "Archive",
                                                      account: "Personal",
                                                      date: recent.addingTimeInterval(-30 * 86_400),
                                                      kind: .invitation)
        let supplement = makeCalendarMessage(id: "supplement",
                                             mailbox: "Inbox",
                                             account: "Work",
                                             date: recent,
                                             kind: .supplementedResponse,
                                             inReplyTo: "shared-id",
                                             references: ["shared-id"])
        try await store.upsert(messages: [otherAccountInvite, supplement])

        let messages = try await store.fetchMessagesForThreading(
            since: recent.addingTimeInterval(-60),
            mailbox: "Inbox",
            account: "Work"
        )

        XCTAssertEqual(messages.map(\.messageID), ["supplement"])
    }

    func test_threadingFetch_hydratesExplicitManualMemberOutsideDateAndMailboxWindow() async throws {
        let defaults = UserDefaults(suiteName: "ManualThreadingMemberFetch-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let recent = Date(timeIntervalSince1970: 2_000_000)
        let visible = makeCalendarMessage(id: "visible-manual-member",
                                          mailbox: "Inbox",
                                          account: "Work",
                                          date: recent,
                                          kind: .ordinaryMessage)
        let olderManualMember = makeCalendarMessage(id: "older-manual-member",
                                                     mailbox: "Archive",
                                                     account: "Work",
                                                     date: recent.addingTimeInterval(-90 * 86_400),
                                                     kind: .ordinaryMessage)
        try await store.upsert(messages: [visible, olderManualMember])

        let messages = try await store.fetchMessagesForThreading(
            since: recent.addingTimeInterval(-60),
            mailbox: "Inbox",
            account: "Work",
            includeMessageKeys: [olderManualMember.threadKey]
        )

        XCTAssertEqual(Set(messages.map(\.messageID)),
                       Set([visible.messageID, olderManualMember.messageID]))
    }

    func test_repair_reclassifiesEditedResponseAndIsIdempotent() async throws {
        let defaults = UserDefaults(suiteName: "CalendarRepairIdempotence-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let legacy = makeCalendarMessage(id: "response",
                                         kind: .attendanceOnlyResponse)
        let repaired = makeCalendarMessage(id: "response",
                                           snippet: "I will join after lunch.",
                                           kind: .supplementedResponse)
        try await store.upsert(messages: [legacy])
        let client = CalendarLookupClient(messagesByAccountAndID: ["work|response": repaired])
        let service = CalendarThreadRecoveryService(client: client, store: store)

        let didRepair = await service.repairStoredClassificationsIfNeeded()
        let visibleAfterRepair = try await store.fetchMessages()
        XCTAssertTrue(didRepair)
        XCTAssertFalse(store.needsCalendarClassificationRepair)
        XCTAssertEqual(visibleAfterRepair.map(\.messageID), ["response"])
        let repeatedRepair = await service.repairStoredClassificationsIfNeeded()
        let calls = await client.lookupCalls()
        XCTAssertFalse(repeatedRepair)
        XCTAssertEqual(calls.count, 1)
    }

    func test_repair_skipsUnscopedLegacyCandidateAndStillRepairsScopedCandidate() async throws {
        let defaults = UserDefaults(suiteName: "CalendarRepairSkipsUnscoped-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let unscoped = makeCalendarMessage(id: "unscoped",
                                           mailbox: "All Inboxes",
                                           account: "",
                                           kind: .attendanceOnlyResponse)
        let scoped = makeCalendarMessage(id: "scoped", kind: .attendanceOnlyResponse)
        let repaired = makeCalendarMessage(id: "scoped",
                                           snippet: "I added the requested figures.",
                                           kind: .supplementedResponse)
        try await store.upsert(messages: [unscoped, scoped])
        let client = CalendarLookupClient(messagesByAccountAndID: ["work|scoped": repaired])
        let service = CalendarThreadRecoveryService(client: client, store: store)

        let didRepair = await service.repairStoredClassificationsIfNeeded()
        let visible = try await store.fetchMessages()
        let calls = await client.lookupCalls()

        XCTAssertTrue(didRepair)
        XCTAssertFalse(store.needsCalendarClassificationRepair)
        XCTAssertEqual(visible.map(\.messageID), ["scoped"])
        XCTAssertEqual(calls.map(\.account), ["work"])
        XCTAssertFalse(calls.contains { $0.account.isEmpty })
    }

    func test_repair_transientFailureRemainsEligibleThenRetries() async throws {
        let defaults = UserDefaults(suiteName: "CalendarRepairRetry-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let legacy = makeCalendarMessage(id: "response", kind: .attendanceOnlyResponse)
        let repaired = makeCalendarMessage(id: "response",
                                           snippet: "Bringing the updated deck.",
                                           kind: .supplementedResponse)
        try await store.upsert(messages: [legacy])
        let client = CalendarLookupClient(messagesByAccountAndID: ["work|response": repaired],
                                          failuresBeforeSuccess: 1)
        let service = CalendarThreadRecoveryService(client: client, store: store)

        let firstAttempt = await service.repairStoredClassificationsIfNeeded()
        let visibleAfterFailure = try await store.fetchMessages()
        XCTAssertFalse(firstAttempt)
        XCTAssertTrue(store.needsCalendarClassificationRepair)
        XCTAssertTrue(visibleAfterFailure.isEmpty)

        let secondAttempt = await service.repairStoredClassificationsIfNeeded()
        let visibleAfterRetry = try await store.fetchMessages()
        let calls = await client.lookupCalls()
        XCTAssertTrue(secondAttempt)
        XCTAssertFalse(store.needsCalendarClassificationRepair)
        XCTAssertEqual(visibleAfterRetry.map(\.messageID), ["response"])
        XCTAssertEqual(calls.count, 2)
    }

    func test_repair_fetchesCandidatesInBatchesOfFour() async throws {
        let defaults = UserDefaults(suiteName: "CalendarRepairBatching-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let legacy = (0..<5).map { makeCalendarMessage(id: "response-\($0)", kind: .attendanceOnlyResponse) }
        let repaired = legacy.reduce(into: [String: EmailMessage]()) { result, message in
            result["work|\(message.messageID)"] = makeCalendarMessage(
                id: message.messageID,
                snippet: "Supplement \(message.messageID)",
                kind: .supplementedResponse
            )
        }
        try await store.upsert(messages: legacy)
        let client = CalendarLookupClient(messagesByAccountAndID: repaired)
        let service = CalendarThreadRecoveryService(client: client, store: store)

        let didRepair = await service.repairStoredClassificationsIfNeeded()
        let calls = await client.lookupCalls()
        let visible = try await store.fetchMessages()
        XCTAssertTrue(didRepair)
        XCTAssertEqual(calls.map(\.messageIDs.count), [4, 1])
        XCTAssertEqual(visible.count, 5)
    }

    func test_repair_prioritizesVisibleLegacyCandidatesAheadOfAlreadyHiddenResponses() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterMailCalendarRepairPriority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Messages.sqlite")
        try await makeLegacyStore(
            at: storeURL,
            messageDate: Date(timeIntervalSince1970: 2_000_000),
            snippet: "Content-Type: text/calendar\n\nCached response preview unavailable"
        )

        let defaults = UserDefaults(suiteName: "CalendarRepairPriority-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeURL: storeURL)
        let hidden = (0..<4).map {
            makeCalendarMessage(id: "aaa-hidden-\($0)", kind: .attendanceOnlyResponse)
        }
        try await store.upsert(messages: hidden)

        var repairedByKey = hidden.reduce(into: [String: EmailMessage]()) { result, message in
            result["work|\(message.messageID)"] = message
        }
        repairedByKey["work|legacy-message"] = makeCalendarMessage(
            id: "legacy-message",
            kind: .attendanceOnlyResponse
        )
        let client = CalendarLookupClient(messagesByAccountAndID: repairedByKey)
        let service = CalendarThreadRecoveryService(client: client, store: store)

        _ = await service.repairStoredClassificationsIfNeeded()
        let calls = await client.lookupCalls()
        let firstCall = try XCTUnwrap(calls.first)

        XCTAssertEqual(firstCall.kind, .references)
        XCTAssertTrue(firstCall.messageIDs.contains("legacy-message"),
                      "The visible legacy candidate should not wait behind already-hidden RSVP rows")
    }

    func test_repair_usesSameAccountFallbackWhenCachedMailboxLocationMisses() async throws {
        let defaults = UserDefaults(suiteName: "CalendarRepairStaleMailbox-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let legacy = makeCalendarMessage(id: "response", kind: .attendanceOnlyResponse)
        let repaired = makeCalendarMessage(id: "response",
                                           snippet: "I will bring the final numbers.",
                                           kind: .supplementedResponse)
        try await store.upsert(messages: [legacy])
        let client = CalendarLookupClient(messagesByAccountAndID: ["work|response": repaired],
                                          referenceFetchReturnsEmpty: true)
        let service = CalendarThreadRecoveryService(client: client, store: store)

        let didRepair = await service.repairStoredClassificationsIfNeeded()
        let calls = await client.lookupCalls()
        let visible = try await store.fetchMessages()

        XCTAssertTrue(didRepair)
        XCTAssertEqual(calls.map(\.kind), [.references, .accountReferences])
        XCTAssertEqual(calls.map(\.account), ["work", "work"])
        XCTAssertEqual(visible.map(\.messageID), ["response"])
    }

    func test_applyCalendarClassificationRepair_promotesBlankAccountRowToFetchedAccount() async throws {
        let defaults = UserDefaults(suiteName: "CalendarRepairBlankAccountPromote-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let date = Date(timeIntervalSince1970: 2_000_000)
        let legacy = makeCalendarMessage(id: "response",
                                         mailbox: "All Inboxes",
                                         account: "",
                                         date: date,
                                         kind: .ordinaryMessage)
        try await store.upsert(messages: [legacy])
        let repaired = makeCalendarMessage(id: "response",
                                           mailbox: "Inbox",
                                           account: "Work",
                                           date: date,
                                           snippet: "Calendar reply",
                                           kind: .attendanceOnlyResponse)
        let updatedCount = try await store.applyCalendarClassificationRepair([repaired])
        let visible = try await store.fetchMessages()
        let reconciled = try await store.fetchMessagesForReconciliation(
            in: DateInterval(start: date.addingTimeInterval(-60), end: date.addingTimeInterval(60)),
            scope: DayFetchScope(mailbox: "Inbox", account: nil, displayName: "Inbox")
        )

        XCTAssertEqual(updatedCount, 1)
        XCTAssertTrue(visible.isEmpty)
        XCTAssertEqual(reconciled.map(\.messageID), ["response"])
        XCTAssertEqual(reconciled.first?.accountName, "Work")
        XCTAssertEqual(reconciled.first?.calendarMessageKind, .attendanceOnlyResponse)
    }

    func test_applyCalendarClassificationRepair_doesNotPromoteAmbiguousBlankAccountRows() async throws {
        let defaults = UserDefaults(suiteName: "CalendarRepairAmbiguousBlankAccount-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let first = makeCalendarMessage(id: "shared-response",
                                        mailbox: "All Inboxes",
                                        account: "",
                                        kind: .ordinaryMessage)
        let second = makeCalendarMessage(id: "shared-response",
                                         mailbox: "Archive",
                                         account: "",
                                         kind: .ordinaryMessage)
        try await store.upsert(messages: [first, second])
        let repaired = makeCalendarMessage(id: "shared-response",
                                           mailbox: "Inbox",
                                           account: "Work",
                                           kind: .attendanceOnlyResponse)

        let updatedCount = try await store.applyCalendarClassificationRepair([repaired])
        let visible = try await store.fetchMessages()

        XCTAssertEqual(updatedCount, 0)
        XCTAssertEqual(visible.count, 2)
    }

    func test_storeLightweightMigration_addsCalendarKindWithoutDeletingLegacyMessage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterMailCalendarMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Messages.sqlite")
        let date = Date(timeIntervalSince1970: 2_000_000)
        try await makeLegacyStore(at: storeURL, messageDate: date)

        let defaults = UserDefaults(suiteName: "CalendarStoreMigration-\(UUID().uuidString)")!
        let migratedStore = MessageStore(userDefaults: defaults, storeURL: storeURL)
        let reconciled = try await migratedStore.fetchMessagesForReconciliation(
            in: DateInterval(start: date.addingTimeInterval(-1), end: date.addingTimeInterval(1)),
            scope: DayFetchScope(mailbox: "Inbox", account: "Work", displayName: "Work / Inbox")
        )

        XCTAssertEqual(reconciled.map(\.messageID), ["legacy-message"])
        XCTAssertEqual(reconciled.first?.calendarMessageKind, .ordinaryMessage)
    }

    func test_repair_refetchesLegacyCalendarMIMEFragmentThatWasNotPreviouslySuppressed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterMailCalendarFragmentRepair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Messages.sqlite")
        let date = Date(timeIntervalSince1970: 2_000_000)
        try await makeLegacyStore(
            at: storeURL,
            messageDate: date,
            snippet: "Content-Type: text/calendar\n\nCached response preview unavailable"
        )

        let defaults = UserDefaults(suiteName: "CalendarFragmentRepair-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeURL: storeURL)
        let sourceMessage = makeCalendarMessage(id: "legacy-message",
                                                date: date,
                                                kind: .attendanceOnlyResponse)
        let client = CalendarLookupClient(messagesByAccountAndID: ["work|legacy-message": sourceMessage])
        let service = CalendarThreadRecoveryService(client: client, store: store)

        let didRepair = await service.repairStoredClassificationsIfNeeded()
        let visible = try await store.fetchMessages()
        let reconciled = try await store.fetchMessagesForReconciliation(
            in: DateInterval(start: date.addingTimeInterval(-1), end: date.addingTimeInterval(1)),
            scope: DayFetchScope(mailbox: "Inbox", account: "Work", displayName: "Work / Inbox")
        )

        XCTAssertTrue(didRepair)
        XCTAssertTrue(visible.isEmpty)
        XCTAssertEqual(reconciled.map(\.messageID), ["legacy-message"])
        XCTAssertEqual(reconciled.first?.calendarMessageKind, .attendanceOnlyResponse)
        XCTAssertTrue(reconciled.first?.isCalendarRSVP == true)
    }

    func test_sourceRecovery_recoversOnlySameAccountCalendarAncestry() async {
        let defaults = UserDefaults(suiteName: "CalendarAncestorRecovery-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let invitation = makeCalendarMessage(id: "invite",
                                             mailbox: "Archive",
                                             account: "Work",
                                             kind: .invitation)
        let hidden = makeCalendarMessage(id: "rsvp",
                                         account: "Work",
                                         kind: .attendanceOnlyResponse,
                                         inReplyTo: invitation.messageID,
                                         references: [invitation.messageID])
        let supplement = makeCalendarMessage(id: "supplement",
                                             account: "Work",
                                             kind: .ordinaryMessage,
                                             inReplyTo: hidden.messageID,
                                             references: [invitation.messageID, hidden.messageID])
        let client = CalendarLookupClient(messagesByAccountAndID: ["work|invite": invitation])
        let service = CalendarThreadRecoveryService(client: client, store: store)

        let recovered = await service.recoverCalendarAncestors(for: [hidden, supplement])

        XCTAssertEqual(recovered.map(\.messageID), ["invite"])
        let calls = await client.lookupCalls()
        XCTAssertEqual(calls.map(\.account), ["work"])
    }

    func test_sourceRecovery_ordinaryReplyAllRecoversImmediateInvitation() async {
        let defaults = UserDefaults(suiteName: "CalendarOrdinaryReplyRecovery-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let invitation = makeCalendarMessage(id: "invite",
                                             mailbox: "Archive",
                                             account: "Work",
                                             kind: .invitation)
        let replyAll = makeCalendarMessage(id: "reply-all",
                                           account: "Work",
                                           snippet: "I added the updated figures.",
                                           kind: .ordinaryMessage,
                                           inReplyTo: invitation.messageID,
                                           references: [invitation.messageID])
        let client = CalendarLookupClient(messagesByAccountAndID: ["work|invite": invitation])
        let service = CalendarThreadRecoveryService(client: client, store: store)

        let recovered = await service.recoverCalendarAncestors(for: [replyAll])

        XCTAssertEqual(recovered.map(\.messageID), ["invite"])
        let calls = await client.lookupCalls()
        XCTAssertEqual(calls, [
            .init(kind: .messageIDs, messageIDs: ["invite"], account: "work")
        ])
    }

    func test_sourceRecovery_rejectsCrossAccountAndUnrelatedChains() async {
        let defaults = UserDefaults(suiteName: "CalendarAncestorGuard-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let crossAccountInvite = makeCalendarMessage(id: "invite",
                                                      account: "Personal",
                                                      kind: .invitation)
        let supplemented = makeCalendarMessage(id: "supplement",
                                               account: "Work",
                                               kind: .supplementedResponse,
                                               inReplyTo: "invite",
                                               references: ["invite"])
        let unrelatedParent = makeCalendarMessage(id: "ordinary-parent",
                                                  account: "Work",
                                                  kind: .ordinaryMessage)
        let client = CalendarLookupClient(messagesByAccountAndID: [
            "work|invite": crossAccountInvite,
            "work|ordinary-parent": unrelatedParent
        ])
        let service = CalendarThreadRecoveryService(client: client, store: store)

        let crossAccountRecovered = await service.recoverCalendarAncestors(for: [supplemented])
        XCTAssertTrue(crossAccountRecovered.isEmpty)

        let ordinary = makeCalendarMessage(id: "ordinary",
                                           account: "Work",
                                           kind: .ordinaryMessage,
                                           inReplyTo: "ordinary-parent",
                                           references: ["ordinary-parent"])
        let callsBeforeOrdinary = await client.lookupCalls().count
        let ordinaryRecovered = await service.recoverCalendarAncestors(for: [ordinary])
        let callsAfterOrdinary = await client.lookupCalls()
        XCTAssertTrue(ordinaryRecovered.isEmpty)
        XCTAssertEqual(callsAfterOrdinary.count, callsBeforeOrdinary + 1)
        XCTAssertEqual(callsAfterOrdinary.last,
                       .init(kind: .messageIDs,
                             messageIDs: ["ordinary-parent"],
                             account: "work"),
                       "Unrelated mail may be probed once but must never be admitted or recursively expanded")
    }

    func test_sourceRecovery_failureLeavesSupplementAsVisibleTemporaryRoot() async {
        let defaults = UserDefaults(suiteName: "CalendarAncestorFailure-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let supplement = makeCalendarMessage(id: "supplement",
                                             account: "Work",
                                             snippet: "I will send the follow-up.",
                                             kind: .supplementedResponse,
                                             inReplyTo: "missing-invite",
                                             references: ["missing-invite"])
        let client = CalendarLookupClient(messagesByAccountAndID: [:], failuresBeforeSuccess: 1)
        let service = CalendarThreadRecoveryService(client: client, store: store)

        let recoveryResult = await service.recoverCalendarAncestorsWithStatus(for: [supplement])
        let threaded = JWZThreader().buildThreads(from: [supplement] + recoveryResult.messages)

        XCTAssertTrue(recoveryResult.messages.isEmpty)
        XCTAssertTrue(recoveryResult.hadTransientFailure)
        XCTAssertEqual(threaded.roots.map(\.message.messageID), ["supplement"])
    }

    func test_sourceRecovery_cancellationReturnsWithoutRecoveredAncestry() async {
        let defaults = UserDefaults(suiteName: "CalendarAncestorCancellation-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let supplement = makeCalendarMessage(id: "supplement",
                                             account: "Work",
                                             kind: .supplementedResponse,
                                             inReplyTo: "invite",
                                             references: ["invite"])
        let client = CalendarLookupClient(messagesByAccountAndID: [:], suspendsLookup: true)
        let service = CalendarThreadRecoveryService(client: client, store: store)
        let task = Task { await service.recoverCalendarAncestors(for: [supplement]) }

        for _ in 0..<1_000 {
            if !(await client.lookupCalls()).isEmpty { break }
            await Task.yield()
        }
        task.cancel()

        let recovered = await task.value
        XCTAssertTrue(recovered.isEmpty)
    }

    private func makeLegacyStore(at storeURL: URL,
                                 messageDate: Date,
                                 snippet: String = "Legacy body") async throws {
        let container = NSPersistentContainer(
            name: "BetterMailModel",
            managedObjectModel: MessageStore.makeModel(includeCalendarMessageKind: false)
        )
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        try container.viewContext.performAndWait {
            let message = NSEntityDescription.insertNewObject(forEntityName: "MessageEntity",
                                                               into: container.viewContext)
            message.setValue(UUID(), forKey: "id")
            message.setValue("legacy-message", forKey: "messageID")
            message.setValue("legacy-message", forKey: "normalizedMessageID")
            message.setValue("internal-legacy-message", forKey: "internalMailID")
            message.setValue("Inbox", forKey: "mailboxID")
            message.setValue("Work", forKey: "accountName")
            message.setValue("Legacy message", forKey: "subject")
            message.setValue("sender@example.com", forKey: "fromAddress")
            message.setValue("me@example.com", forKey: "toAddress")
            message.setValue(messageDate, forKey: "date")
            message.setValue(snippet, forKey: "snippet")
            message.setValue(false, forKey: "isUnread")
            message.setValue(false, forKey: "isCalendarRSVP")
            try container.viewContext.save()
        }

        for persistentStore in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(persistentStore)
        }
    }
}

private actor CalendarLookupClient: MailMessageFetching {
    enum LookupKind: Equatable, Sendable {
        case references
        case accountReferences
        case messageIDs
    }

    struct LookupCall: Equatable, Sendable {
        let kind: LookupKind
        let messageIDs: [String]
        let account: String
    }

    enum TestError: Error {
        case transient
    }

    private let messagesByAccountAndID: [String: EmailMessage]
    private var failuresBeforeSuccess: Int
    private let suspendsLookup: Bool
    private let referenceFetchReturnsEmpty: Bool
    private var calls: [LookupCall] = []

    init(messagesByAccountAndID: [String: EmailMessage],
         failuresBeforeSuccess: Int = 0,
         suspendsLookup: Bool = false,
         referenceFetchReturnsEmpty: Bool = false) {
        self.messagesByAccountAndID = messagesByAccountAndID
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.suspendsLookup = suspendsLookup
        self.referenceFetchReturnsEmpty = referenceFetchReturnsEmpty
    }

    func fetchMessages(messageIDs: [String],
                       account: String,
                       snippetLineLimit: Int) async throws -> [EmailMessage] {
        calls.append(LookupCall(kind: .messageIDs, messageIDs: messageIDs, account: account))
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw TestError.transient
        }
        if suspendsLookup {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        return messageIDs.compactMap { messagesByAccountAndID["\(account.lowercased())|\($0)"] }
    }

    func fetchMessages(references: [MessageReference],
                       account: String,
                       snippetLineLimit: Int) async throws -> [EmailMessage] {
        calls.append(LookupCall(kind: .accountReferences,
                                messageIDs: references.map(\.messageID),
                                account: account))
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw TestError.transient
        }
        if suspendsLookup {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        return references.compactMap { reference in
            messagesByAccountAndID["\(account.lowercased())|\(reference.messageID)"]
        }
    }

    func fetchMessages(references: [MessageReference],
                       profile: MailFetchProfile,
                       snippetLineLimit: Int) async throws -> [EmailMessage] {
        let account = references.first?.account.lowercased() ?? ""
        calls.append(LookupCall(kind: .references,
                                messageIDs: references.map(\.messageID),
                                account: account))
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw TestError.transient
        }
        if suspendsLookup {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        if referenceFetchReturnsEmpty { return [] }
        return references.compactMap { reference in
            messagesByAccountAndID["\(reference.account.lowercased())|\(reference.messageID)"]
        }
    }

    func lookupCalls() -> [LookupCall] { calls }

    func countMessages(in range: DateInterval, mailbox: String, account: String?) async throws -> Int { 0 }

    func fetchMessages(in range: DateInterval,
                       limit: Int,
                       mailbox: String,
                       account: String?,
                       snippetLineLimit: Int) async throws -> [EmailMessage] { [] }

    func countMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                       mailbox: String,
                       account: String?) async throws -> Int { 0 }

    func fetchMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                       limit: Int,
                       mailbox: String,
                       account: String?,
                       snippetLineLimit: Int) async throws -> [EmailMessage] { [] }
}

private func makeCalendarMessage(id: String,
                                 mailbox: String = "Inbox",
                                 account: String = "Work",
                                 date: Date = Date(timeIntervalSince1970: 2_000_000),
                                 snippet: String = "Calendar message",
                                 kind: CalendarMessageKind,
                                 inReplyTo: String? = nil,
                                 references: [String] = []) -> EmailMessage {
    EmailMessage(messageID: id,
                 internalMailID: "internal-\(id)-\(account)",
                 mailboxID: mailbox,
                 accountName: account,
                 subject: "Planning",
                 from: "sender@example.com",
                 to: "me@example.com",
                 date: date,
                 snippet: snippet,
                 isUnread: false,
                 calendarMessageKind: kind,
                 inReplyTo: inReplyTo,
                 references: references)
}
