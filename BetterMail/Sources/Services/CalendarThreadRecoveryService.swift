import Foundation
import OSLog

internal actor CalendarThreadRecoveryService {
    internal static let sourceLookupBatchSize = 4

    internal struct AncestorRecoveryResult: Sendable {
        internal let messages: [EmailMessage]
        internal let hadTransientFailure: Bool
    }

    private struct ScopedMessageID: Hashable {
        let account: String
        let messageID: String

        init?(messageID: String, account: String) {
            let normalizedMessageID = CalendarThreadRecoveryService.normalizeIdentifier(messageID)
            let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedMessageID.isEmpty, !normalizedAccount.isEmpty else { return nil }
            self.account = normalizedAccount
            self.messageID = normalizedMessageID
        }
    }

    private let client: any MailMessageFetching
    private let store: MessageStore

    internal init(client: any MailMessageFetching, store: MessageStore) {
        self.client = client
        self.store = store
    }

    /// Runs once after a successful source pass. Missing source messages are a
    /// valid terminal outcome; thrown/transient batches leave the repair key
    /// unset so the next launch can retry.
    @discardableResult
    internal func repairStoredClassificationsIfNeeded() async -> Bool {
        guard await MainActor.run(body: { store.needsCalendarClassificationRepair }) else { return false }
        do {
            let candidates = try await store.fetchCalendarClassificationRepairCandidates()
            guard !candidates.isEmpty else {
                await MainActor.run { store.markCalendarClassificationRepairComplete() }
                return false
            }

            let scopedCandidates = candidates.filter {
                ScopedMessageID(messageID: $0.messageID, account: $0.accountName) != nil
            }
            let references = scopedCandidates
                .sorted { lhs, rhs in
                    if lhs.isCalendarRSVP != rhs.isCalendarRSVP {
                        return !lhs.isCalendarRSVP
                    }
                    let lhsReference = MessageReference(message: lhs)
                    let rhsReference = MessageReference(message: rhs)
                    let accountOrder = lhsReference.account.localizedCaseInsensitiveCompare(rhsReference.account)
                    if accountOrder != .orderedSame { return accountOrder == .orderedAscending }
                    return Self.normalizeIdentifier(lhsReference.messageID)
                        < Self.normalizeIdentifier(rhsReference.messageID)
                }
                .map { MessageReference(message: $0) }
            let skippedUnscopedCount = candidates.count - references.count
            if skippedUnscopedCount > 0 {
                await MainActor.run {
                    Log.refresh.info("Calendar classification repair skipped unscoped legacy records. count=\(skippedUnscopedCount, privacy: .public)")
                }
            }

            var updatedCount = 0
            var sawTransientFailure = false
            for batch in Self.batches(references, size: Self.sourceLookupBatchSize) {
                try Task.checkCancellation()
                do {
                    let fetched = try await fetchRepairMessages(references: batch)
                    updatedCount += try await store.applyCalendarClassificationRepair(fetched)
                } catch is CancellationError {
                    return false
                } catch {
                    sawTransientFailure = true
                    await MainActor.run {
                        Log.refresh.error("Calendar classification repair batch failed. count=\(batch.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            if !sawTransientFailure {
                await MainActor.run { store.markCalendarClassificationRepairComplete() }
            }
            return updatedCount > 0
        } catch is CancellationError {
            return false
        } catch {
            await MainActor.run {
                Log.refresh.error("Calendar classification repair failed before completion.")
            }
            return false
        }
    }

    /// Uses the cached mailbox location first, then searches only the same
    /// Apple Mail account for records that moved or came from a virtual inbox.
    /// Unscoped legacy rows never enter this path because cross-account lookup
    /// cannot safely identify their source message.
    private func fetchRepairMessages(references: [MessageReference]) async throws -> [EmailMessage] {
        let requestedKeys = Set(references.compactMap {
            ScopedMessageID(messageID: $0.messageID, account: $0.account)
        })
        guard !requestedKeys.isEmpty else { return [] }

        var messagesByKey: [ScopedMessageID: EmailMessage] = [:]
        func admit(_ messages: [EmailMessage]) {
            for message in messages {
                guard let key = ScopedMessageID(messageID: message.messageID,
                                                account: message.accountName),
                      requestedKeys.contains(key) else { continue }
                messagesByKey[key] = message
            }
        }

        admit(try await client.fetchMessages(references: references,
                                             profile: .full,
                                             snippetLineLimit: Int.max))

        let unresolvedReferences = references.filter { reference in
            guard let key = ScopedMessageID(messageID: reference.messageID,
                                            account: reference.account) else { return false }
            return messagesByKey[key] == nil
        }
        let referencesByAccount = Dictionary(grouping: unresolvedReferences) {
            $0.account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for account in referencesByAccount.keys.sorted() {
            let referencesByMessageID = referencesByAccount[account, default: []]
                .reduce(into: [String: MessageReference]()) { result, reference in
                    let messageID = Self.normalizeIdentifier(reference.messageID)
                    guard !messageID.isEmpty else { return }
                    if let existing = result[messageID],
                       existing.internalMailID?.isEmpty == false {
                        return
                    }
                    result[messageID] = reference
                }
            let scopedReferences = referencesByMessageID.keys.sorted().compactMap {
                referencesByMessageID[$0]
            }
            for batch in Self.batches(scopedReferences, size: Self.sourceLookupBatchSize) {
                try Task.checkCancellation()
                admit(try await client.fetchMessages(references: batch,
                                                     account: account,
                                                     snippetLineLimit: Int.max))
            }
        }
        return Array(messagesByKey.values)
    }

    /// Recovers only ancestry belonging to a component already known to be a
    /// scheduling conversation. This keeps unrelated email threads bounded,
    /// while a cached invitation/RSVP or a supplemented RSVP can recover older
    /// ancestors from the same Apple Mail account.
    internal func recoverCalendarAncestors(for messages: [EmailMessage]) async -> [EmailMessage] {
        await recoverCalendarAncestorsWithStatus(for: messages).messages
    }

    internal func recoverCalendarAncestorsWithStatus(
        for messages: [EmailMessage]
    ) async -> AncestorRecoveryResult {
        let keyedMessages = messages.compactMap { message -> (ScopedMessageID, EmailMessage)? in
            guard let key = ScopedMessageID(messageID: message.messageID,
                                            account: message.accountName) else { return nil }
            return (key, message)
        }
        var messagesByKey: [ScopedMessageID: EmailMessage] = [:]
        for (key, message) in keyedMessages {
            if let existing = messagesByKey[key], existing.date >= message.date { continue }
            messagesByKey[key] = message
        }
        let originalKeys = Set(messagesByKey.keys)
        var recoveredByKey: [ScopedMessageID: EmailMessage] = [:]
        var attemptedKeys: Set<ScopedMessageID> = []
        var shouldProbeOrdinaryRoots = true
        var hadTransientFailure = false

        for _ in 0..<64 {
            try? Task.checkCancellation()
            if Task.isCancelled {
                return AncestorRecoveryResult(messages: [], hadTransientFailure: false)
            }
            let eventKeys = Self.eventScopedKeys(in: messagesByKey)
            // A Reply All supplement can be an ordinary MIME message whose
            // first calendar signal is its missing parent. Probe one hop from
            // each current root, then continue recursively only for a chain
            // that actually resolves to scheduling mail.
            let lookupKeys = shouldProbeOrdinaryRoots
                ? eventKeys.union(originalKeys)
                : eventKeys
            shouldProbeOrdinaryRoots = false
            guard !lookupKeys.isEmpty else { break }

            var unresolved: Set<ScopedMessageID> = []
            for key in lookupKeys {
                guard let message = messagesByKey[key] else { continue }
                for parentID in message.references + (message.inReplyTo.map { [$0] } ?? []) {
                    guard let parentKey = ScopedMessageID(messageID: parentID,
                                                          account: message.accountName),
                          messagesByKey[parentKey] == nil,
                          !attemptedKeys.contains(parentKey) else { continue }
                    unresolved.insert(parentKey)
                }
            }
            guard !unresolved.isEmpty else { break }
            attemptedKeys.formUnion(unresolved)

            var addedAny = false
            let grouped = Dictionary(grouping: unresolved, by: \.account)
            for account in grouped.keys.sorted() {
                let ids = grouped[account, default: []].map(\.messageID).sorted()
                for batch in Self.batches(ids, size: Self.sourceLookupBatchSize) {
                    if Task.isCancelled {
                        return AncestorRecoveryResult(messages: [], hadTransientFailure: false)
                    }
                    do {
                        let fetched = try await client.fetchMessages(messageIDs: batch,
                                                                     account: account,
                                                                     snippetLineLimit: Int.max)
                        for message in fetched {
                            guard let key = ScopedMessageID(messageID: message.messageID,
                                                            account: message.accountName),
                                  key.account == account,
                                  unresolved.contains(key) else { continue }
                            messagesByKey[key] = message
                            recoveredByKey[key] = message
                            addedAny = true
                        }
                    } catch is CancellationError {
                        return AncestorRecoveryResult(messages: [], hadTransientFailure: false)
                    } catch {
                        hadTransientFailure = true
                        await MainActor.run {
                            Log.refresh.error("Calendar ancestor lookup batch failed. count=\(batch.count, privacy: .public) account=\(account, privacy: .private) error=\(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
            if !addedAny { break }
        }

        let admittedKeys = Self.admittedRecoveredAncestorKeys(in: messagesByKey,
                                                               originalKeys: originalKeys,
                                                               recoveredKeys: Set(recoveredByKey.keys))
        let recoveredMessages = recoveredByKey
            .filter { admittedKeys.contains($0.key) }
            .map(\.value)
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.messageID < rhs.messageID }
                return lhs.date > rhs.date
            }
        return AncestorRecoveryResult(messages: recoveredMessages,
                                      hadTransientFailure: hadTransientFailure)
    }

    private static func eventScopedKeys(in messagesByKey: [ScopedMessageID: EmailMessage]) -> Set<ScopedMessageID> {
        var neighbors: [ScopedMessageID: Set<ScopedMessageID>] = [:]
        for (key, message) in messagesByKey {
            if neighbors[key] == nil { neighbors[key] = [] }
            for parentID in message.references + (message.inReplyTo.map { [$0] } ?? []) {
                guard let parentKey = ScopedMessageID(messageID: parentID,
                                                      account: message.accountName),
                      messagesByKey[parentKey] != nil else { continue }
                neighbors[key, default: []].insert(parentKey)
                neighbors[parentKey, default: []].insert(key)
            }
        }

        var result: Set<ScopedMessageID> = []
        var visited: Set<ScopedMessageID> = []
        for start in messagesByKey.keys where !visited.contains(start) {
            var component: Set<ScopedMessageID> = []
            var pending = [start]
            var isCalendarComponent = false
            while let current = pending.popLast() {
                guard visited.insert(current).inserted else { continue }
                component.insert(current)
                if Self.isScheduling(messagesByKey[current]?.calendarMessageKind) {
                    isCalendarComponent = true
                }
                pending.append(contentsOf: neighbors[current, default: []].filter { !visited.contains($0) })
            }
            if isCalendarComponent { result.formUnion(component) }
        }
        return result
    }

    /// Recovered ordinary messages are only admitted when they form a path to
    /// a recovered or already-cached scheduling ancestor. This allows a real
    /// calendar chain to traverse an intermediate record without broadening an
    /// unrelated email conversation merely because its descendant was an event
    /// response.
    private static func admittedRecoveredAncestorKeys(
        in messagesByKey: [ScopedMessageID: EmailMessage],
        originalKeys: Set<ScopedMessageID>,
        recoveredKeys: Set<ScopedMessageID>
    ) -> Set<ScopedMessageID> {
        func resolveAncestors(from key: ScopedMessageID,
                              visiting: Set<ScopedMessageID>) -> (resolves: Bool, admitted: Set<ScopedMessageID>) {
            guard !visiting.contains(key), let message = messagesByKey[key] else { return (false, []) }
            var nextVisiting = visiting
            nextVisiting.insert(key)
            var resolves = false
            var admitted: Set<ScopedMessageID> = []

            for parentID in message.references + (message.inReplyTo.map { [$0] } ?? []) {
                guard let parentKey = ScopedMessageID(messageID: parentID, account: message.accountName),
                      let parent = messagesByKey[parentKey] else { continue }
                let deeper = resolveAncestors(from: parentKey, visiting: nextVisiting)
                let parentResolves = isScheduling(parent.calendarMessageKind) || deeper.resolves
                guard parentResolves else { continue }
                resolves = true
                admitted.formUnion(deeper.admitted)
                if recoveredKeys.contains(parentKey) {
                    admitted.insert(parentKey)
                }
            }
            return (resolves, admitted)
        }

        var admitted: Set<ScopedMessageID> = []
        for key in originalKeys {
            admitted.formUnion(resolveAncestors(from: key, visiting: []).admitted)
        }
        return admitted
    }

    private nonisolated static func isScheduling(_ kind: CalendarMessageKind?) -> Bool {
        switch kind {
        case .invitation, .attendanceOnlyResponse, .supplementedResponse, .otherSchedulingMessage:
            return true
        case .ordinaryMessage, .indeterminate, nil:
            return false
        }
    }

    private static func batches<T>(_ values: [T], size: Int) -> [[T]] {
        guard size > 0, !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map { start in
            Array(values[start..<min(start + size, values.count)])
        }
    }

    private nonisolated static func normalizeIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") {
            return String(trimmed.dropFirst().dropLast()).lowercased()
        }
        return trimmed.lowercased()
    }
}
