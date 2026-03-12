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

    internal func remap(threadIDs sourceThreadIDs: Set<String>,
                        to replacementThreadID: String,
                        preferredSourceThreadID: String? = nil) {
        let trimmedReplacement = replacementThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReplacement.isEmpty else { return }

        let normalizedSourceIDs = Set(sourceThreadIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard !normalizedSourceIDs.isEmpty else { return }

        let matchingRules = rules.filter { normalizedSourceIDs.contains($0.threadID) }
        guard !matchingRules.isEmpty else { return }

        let normalizedPreferredID = preferredSourceThreadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var updatedByCompositeID = Dictionary(uniqueKeysWithValues: rules.map { rule in
            ("\(rule.account.lowercased())|\(rule.threadID)", rule)
        })

        for sourceThreadID in normalizedSourceIDs {
            updatedByCompositeID.keys
                .filter { $0.hasSuffix("|\(sourceThreadID)") }
                .forEach { updatedByCompositeID.removeValue(forKey: $0) }
        }

        let rulesByAccount = Dictionary(grouping: matchingRules, by: \.account)
        for (account, accountRules) in rulesByAccount {
            let preferredRule = accountRules.first { rule in
                guard let normalizedPreferredID else { return false }
                return rule.threadID == normalizedPreferredID
            }
            let chosenRule = preferredRule ?? accountRules.sorted {
                if $0.destinationPath == $1.destinationPath {
                    return $0.threadID < $1.threadID
                }
                return $0.destinationPath < $1.destinationPath
            }.first
            guard let chosenRule else { continue }

            updatedByCompositeID["\(account.lowercased())|\(trimmedReplacement)"] = MailboxThreadMoveRule(account: account,
                                                                                                          threadID: trimmedReplacement,
                                                                                                          destinationPath: chosenRule.destinationPath)
        }

        rules = updatedByCompositeID.values.sorted { lhs, rhs in
            if lhs.account == rhs.account {
                return lhs.threadID < rhs.threadID
            }
            return lhs.account < rhs.account
        }
    }

    internal func updateDestination(threadIDs: Set<String>,
                                    destinationPath: String,
                                    account: String) {
        let trimmedDestination = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty, !trimmedAccount.isEmpty else { return }

        let normalizedThreadIDs = Set(threadIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard !normalizedThreadIDs.isEmpty else { return }

        var updatedRules = rules
        var didChange = false
        for index in updatedRules.indices {
            let rule = updatedRules[index]
            guard rule.account.caseInsensitiveCompare(trimmedAccount) == .orderedSame,
                  normalizedThreadIDs.contains(rule.threadID),
                  rule.destinationPath.caseInsensitiveCompare(trimmedDestination) != .orderedSame else {
                continue
            }
            updatedRules[index] = MailboxThreadMoveRule(account: rule.account,
                                                        threadID: rule.threadID,
                                                        destinationPath: trimmedDestination)
            didChange = true
        }

        guard didChange else { return }
        rules = updatedRules.sorted { lhs, rhs in
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
