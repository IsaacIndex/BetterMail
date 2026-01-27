//
//  MailControl.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import Foundation
import OSLog

internal enum MailControlError: LocalizedError {
    case invalidMessageID
    case heuristicFailed

    var errorDescription: String? {
        switch self {
        case .invalidMessageID:
            return "Invalid Message-ID."
        case .heuristicFailed:
            return "Failed to search Mail for the message."
        }
    }
}

internal struct MailControl {
    internal struct OpenMessageMetadata: Hashable {
        internal let subject: String
        internal let sender: String
        internal let date: Date
        internal let mailbox: String
        internal let account: String
    }

    internal enum HeuristicScope: String {
        case mailbox
        case account
        case global
    }

    internal enum HeuristicOutcome: Equatable {
        case opened(HeuristicScope)
        case notFound
    }

    internal enum TargetingResolution: Equatable {
        case openedMessageID
        case openedHeuristic(HeuristicScope)
        case notFound
    }

    /// Escape arbitrary user text so embedding it inside AppleScript stays well-formed.
    private static func escapedForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Convert a "Projects/ACME" style path into the nested `mailbox` reference Mail expects.
    internal static func mailboxReference(path: String, account: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        let accountSuffix: (String) -> String = { ref in
            guard let account, !account.isEmpty else { return ref }
            return "\(ref) of account \"\(escapedForAppleScript(account))\""
        }

        let builtin: Set<String> = ["inbox", "sent", "drafts", "junk", "trash", "outbox"]
        if builtin.contains(lowered) {
            return accountSuffix(lowered)
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else {
            return accountSuffix("inbox")
        }

        var reference = "mailbox \"\(escapedForAppleScript(components.last!))\""
        for parent in components.dropLast().reversed() {
            reference += " of mailbox \"\(escapedForAppleScript(parent))\""
        }
        return accountSuffix(reference)
    }

    nonisolated internal static func openMessageViaAppleScript(messageID: String) throws -> Bool {
        let normalized = try normalizedMessageID(messageID)
        let bracketed = "<\(normalized)>"
        let script = buildMessageOpenScript(normalized: normalized, bracketed: bracketed)
        let result = try runAppleScript(script)
        if result.descriptorType == typeBoolean {
            return result.booleanValue
        }
        return false
    }

    nonisolated internal static func resolveTargetingPath(messageID: String,
                                                          metadata: OpenMessageMetadata,
                                                          openViaAppleScript: (String) throws -> Bool = openMessageViaAppleScript,
                                                          openViaHeuristic: (OpenMessageMetadata) throws -> HeuristicOutcome = openMessageViaHeuristic,
                                                          onMessageIDFailure: (() -> Void)? = nil) throws -> TargetingResolution {
        let openedByMessageID = try openViaAppleScript(messageID)
        if openedByMessageID {
            return .openedMessageID
        }

        onMessageIDFailure?()

        let heuristicOutcome = try openViaHeuristic(metadata)
        switch heuristicOutcome {
        case .opened(let scope):
            return .openedHeuristic(scope)
        case .notFound:
            return .notFound
        }
    }

    nonisolated internal static func openMessageViaHeuristic(_ metadata: OpenMessageMetadata) throws -> HeuristicOutcome {
        let subject = metadata.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderToken = heuristicSenderToken(from: metadata.sender)
        let mailbox = metadata.mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = metadata.account.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: metadata.date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0

        if !mailbox.isEmpty {
            let script = heuristicOpenScript(subject: subject,
                                             sender: senderToken,
                                             year: year,
                                             month: month,
                                             day: day,
                                             scope: .mailbox,
                                             mailbox: mailbox,
                                             account: account)
            let result = try runAppleScript(script)
            if result.descriptorType != typeBoolean {
                throw MailControlError.heuristicFailed
            }
            if result.booleanValue {
                return .opened(.mailbox)
            }
        } else if !account.isEmpty {
            let script = heuristicOpenScript(subject: subject,
                                             sender: senderToken,
                                             year: year,
                                             month: month,
                                             day: day,
                                             scope: .account,
                                             mailbox: mailbox,
                                             account: account)
            let result = try runAppleScript(script)
            if result.descriptorType != typeBoolean {
                throw MailControlError.heuristicFailed
            }
            if result.booleanValue {
                return .opened(.account)
            }
        }

        let script = heuristicOpenScript(subject: subject,
                                         sender: senderToken,
                                         year: year,
                                         month: month,
                                         day: day,
                                         scope: .global,
                                         mailbox: mailbox,
                                         account: account)
        let result = try runAppleScript(script)
        if result.descriptorType == typeBoolean {
            return result.booleanValue ? .opened(.global) : .notFound
        }
        throw MailControlError.heuristicFailed
    }

    internal static func normalizedMessageID(_ messageID: String) throws -> String {
        let normalized = JWZThreader.normalizeIdentifier(messageID)
        guard !normalized.isEmpty else { throw MailControlError.invalidMessageID }
        return normalized
    }

    internal static func cleanMessageIDPreservingCase(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    internal static func moveSelection(to mailboxPath: String, in account: String) throws {
        let destReference = mailboxReference(path: mailboxPath, account: account)
        let script = """
        tell application "Mail"
          set destMailbox to \(destReference)
          repeat with m in selection
            move m to destMailbox
          end repeat
        end tell
        """
        _ = try runAppleScript(script)
    }

    internal static func flagSelection(colorIndex: Int = 4) throws {
        // Apple Mail uses 0..7; common mapping: 1=red 2=orange 3=yellow 4=green 5=blue 6=purple 7=gray
        let script = """
        tell application "Mail"
          repeat with m in selection
            set flagged status of m to true
            set flag index of m to \(colorIndex)
          end repeat
        end tell
        """
        _ = try runAppleScript(script)
    }

    internal static func searchInboxSubject(contains text: String, limit: Int = 50) throws -> [String] {
        // Returns subjects for simplicity (you can expand to return more fields)
        let safeText = escapedForAppleScript(text)
        let script = """
        set _hits to {}
        tell application "Mail"
          repeat with m in (messages of inbox whose subject contains "\(safeText)")
            copy (subject of m as string) to end of _hits
            if (count of _hits) is greater than or equal to \(limit) then exit repeat
          end repeat
        end tell
        return _hits
        """
        guard let r = try? runAppleScript(script) else { return [] }
        return (0..<r.numberOfItems).map { r.atIndex($0+1)?.stringValue ?? "" }
    }

    internal static func fetchRecent(from mailbox: String = "inbox",
                                     account: String? = nil,
                                     daysBack: Int = 7,
                                     limit: Int = 200) throws -> [[String: String]] {
        // Pulls a lightweight timeline: subject, sender, date received
        print("fetchRecent bundle id:", Bundle.main.bundleIdentifier ?? "nil",
              "mailbox:", mailbox,
              "account:", account ?? "nil",
              "daysBack:", daysBack,
              "limit:", limit)
        let mailboxRef = mailboxReference(path: mailbox, account: account)
        let script = """
        set _rows to {}
        set _cutoff to (current date) - (#{DAYS} * days)
        tell application id "com.apple.mail"
          set _mbx to \(mailboxRef)
          set _msgs to messages of _mbx
          set _count to 0
          repeat with m in _msgs
            if (date received of m) is greater than or equal to _cutoff then
              set _row to (subject of m as string) & "||" & (sender of m as string) & "||" & ((date received of m) as string)
              copy _row to end of _rows
              set _count to _count + 1
              if _count is greater than or equal to #{LIMIT} then exit repeat
            end if
          end repeat
        end tell
        return _rows
        """
        .replacingOccurrences(of: "#{DAYS}", with: String(daysBack))
        .replacingOccurrences(of: "#{LIMIT}", with: String(limit))

        guard let r = try? runAppleScript(script) else { return [] }
        return (0..<r.numberOfItems).compactMap { i in
            guard let row = r.atIndex(i+1)?.stringValue else { return nil }
            let parts = row.components(separatedBy: "||")
            guard parts.count >= 3 else { return nil }
            return ["subject": parts[0], "sender": parts[1], "date": parts[2]]
        }
    }

    private static func heuristicOpenScript(subject: String,
                                            sender: String,
                                            year: Int,
                                            month: Int,
                                            day: Int,
                                            scope: HeuristicScope,
                                            mailbox: String,
                                            account: String) -> String {
        let safeSubject = escapedForAppleScript(subject)
        let safeSender = escapedForAppleScript(sender)
        let mailboxRef: String
        switch scope {
        case .mailbox:
            mailboxRef = mailboxReference(path: mailbox, account: account.isEmpty ? nil : account)
        case .account, .global:
            mailboxRef = ""
        }

        let scopeScript: String
        switch scope {
        case .mailbox:
            scopeScript = "set _scopeMessages to messages of \(mailboxRef)"
        case .account:
            let safeAccount = escapedForAppleScript(account)
            scopeScript = "set _scopeMessages to messages of account \"\(safeAccount)\""
        case .global:
            scopeScript = "set _scopeMessages to every message"
        }

        return """
        tell application "Mail"
          with timeout of 30 seconds
            set _targetSubject to "\(safeSubject)"
            set _targetSender to "\(safeSender)"
            set _targetYear to \(year)
            set _targetMonth to \(month)
            set _targetDay to \(day)
            \(scopeScript)

            on matchesDate(theDate)
              try
                if (year of theDate as integer) is not _targetYear then return false
                if (month of theDate as integer) is not _targetMonth then return false
                if (day of theDate as integer) is not _targetDay then return false
                return true
              on error
                return false
              end try
            end matchesDate

            on matchesMetadata(m)
              set _subjectMatch to true
              set _senderMatch to true
              set _dateMatch to true
              try
                if _targetSubject is not "" then
                  set _subjectMatch to ((subject of m as string) contains _targetSubject)
                end if
              on error
                set _subjectMatch to false
              end try
              try
                if _targetSender is not "" then
                  set _senderMatch to ((sender of m as string) contains _targetSender)
                end if
              on error
                set _senderMatch to false
              end try
              try
                set _dateMatch to my matchesDate(date received of m)
              on error
                set _dateMatch to false
              end try
              return _subjectMatch and _senderMatch and _dateMatch
            end matchesMetadata

            set _match to missing value
            ignoring case
              repeat with m in _scopeMessages
                if my matchesMetadata(m) then
                  set _match to m
                  exit repeat
                end if
              end repeat
            end ignoring

            if _match is missing value then return false
            try
              open _match
            on error
              try
                set _viewer to message viewer 1
                set selected messages of _viewer to {_match}
              end try
            end try
            activate
            return true
          end timeout
        end tell
        """
    }

    private static func buildMessageOpenScript(normalized: String,
                                               bracketed: String) -> String {
        let safeNormalized = escapedForAppleScript(normalized)
        let safeBracketed = escapedForAppleScript(bracketed)
        return """
        tell application "Mail"
          with timeout of 30 seconds
            set _matches to {}
            set _id1 to "\(safeBracketed)"
            set _id2 to "\(safeNormalized)"
            ignoring case
              try
                repeat with m in (every message whose message id is _id1)
                  copy m to end of _matches
                end repeat
              end try
              if _id2 is not equal to _id1 then
                try
                  repeat with m in (every message whose message id is _id2)
                    copy m to end of _matches
                  end repeat
                end try
              end if
            end ignoring
            if (count of _matches) is 0 then return false
            set _msg to item 1 of _matches
            try
              open _msg
            on error
              try
                set _viewer to message viewer 1
                set selected messages of _viewer to {_msg}
              end try
            end try
            activate
            return true
          end timeout
        end tell
        """
    }

    private static func heuristicSenderToken(from rawSender: String) -> String {
        let trimmed = rawSender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let start = trimmed.firstIndex(of: "<"),
           let end = trimmed.firstIndex(of: ">"),
           start < end {
            let email = trimmed[trimmed.index(after: start)..<end]
            return email.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
