import Combine
import Foundation
import SwiftUI

internal struct MailboxThreadMoveRule: Hashable, Codable {
    internal let account: String
    internal let threadID: String
    internal let destinationPath: String
}

@MainActor
internal final class MailboxThreadAutoMoveSettings: ObservableObject {
    @AppStorage("mailboxThreadAutoMoveRules") private var storedRules = ""

    @Published private(set) internal var rules: [MailboxThreadMoveRule] = [] {
        didSet {
            storedRules = Self.encode(rules)
        }
    }

    internal init() {
        rules = Self.decode(storedRules)
    }

    internal func upsert(threadIDs: Set<String>,
                         destinationPath: String,
                         account: String) {
        let trimmedDestination = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty, !trimmedAccount.isEmpty else { return }
        guard !threadIDs.isEmpty else { return }

        var updatedByCompositeID = Dictionary(uniqueKeysWithValues: rules.map { rule in
            ("\(rule.account.lowercased())|\(rule.threadID)", rule)
        })
        for threadID in threadIDs {
            let trimmedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedThreadID.isEmpty else { continue }
            let key = "\(trimmedAccount.lowercased())|\(trimmedThreadID)"
            updatedByCompositeID[key] = MailboxThreadMoveRule(account: trimmedAccount,
                                                              threadID: trimmedThreadID,
                                                              destinationPath: trimmedDestination)
        }
        rules = updatedByCompositeID.values.sorted { lhs, rhs in
            if lhs.account == rhs.account {
                return lhs.threadID < rhs.threadID
            }
            return lhs.account < rhs.account
        }
    }

    private static func encode(_ rules: [MailboxThreadMoveRule]) -> String {
        guard !rules.isEmpty else { return "" }
        if let data = try? JSONEncoder().encode(rules),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }

    private static func decode(_ text: String) -> [MailboxThreadMoveRule] {
        guard !text.isEmpty else { return [] }
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MailboxThreadMoveRule].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        var normalized: [MailboxThreadMoveRule] = []
        normalized.reserveCapacity(decoded.count)
        for rule in decoded {
            let trimmedAccount = rule.account.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedThreadID = rule.threadID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDestination = rule.destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAccount.isEmpty, !trimmedThreadID.isEmpty, !trimmedDestination.isEmpty else {
                continue
            }
            let key = "\(trimmedAccount.lowercased())|\(trimmedThreadID)"
            guard seen.insert(key).inserted else { continue }
            normalized.append(MailboxThreadMoveRule(account: trimmedAccount,
                                                    threadID: trimmedThreadID,
                                                    destinationPath: trimmedDestination))
        }
        return normalized
    }
}
