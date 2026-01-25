//
//  MailControl.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import AppKit
import Foundation
import OSLog

internal enum MailControlError: LocalizedError {
    case invalidMessageID
    case openFailed
    case searchFailed

    var errorDescription: String? {
        switch self {
        case .invalidMessageID:
            return "Invalid Message-ID for message:// URL."
        case .openFailed:
            return "Failed to open the message in Mail."
        case .searchFailed:
            return "Failed to search Mail for the Message-ID."
        }
    }
}

internal struct MailControl {
    internal struct MessageMatch: Hashable {
        internal let messageID: String
        internal let subject: String
        internal let mailbox: String
        internal let account: String
        internal let date: String
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

    internal static func openMessage(messageID: String) throws {
        // Prefer AppleScript so we can fail fast and surface fallback without Mail's alert.
        let opened = try openMessageViaAppleScript(messageID: messageID)
        if opened {
            Log.appleScript.debug("Open in Mail via AppleScript succeeded. id=\(messageID, privacy: .public)")
            return
        }

        let url = try messageURL(for: messageID)
        Log.appleScript.debug("Open in Mail via message:// URL fallback. id=\(messageID, privacy: .public) url=\(url.absoluteString, privacy: .public)")
        guard NSWorkspace.shared.open(url) else { throw MailControlError.openFailed }
    }

    internal static func openMessageViaAppleScript(messageID: String) throws -> Bool {
        let normalized = try normalizedMessageID(messageID)
        let bracketed = "<\(normalized)>"
        let script = buildMessageOpenScript(normalized: normalized, bracketed: bracketed)
        let result = try runAppleScript(script)
        if result.descriptorType == typeBoolean {
            return result.booleanValue
        }
        return false
    }

    internal static func searchMessages(messageID: String, limit: Int = 5) throws -> [MessageMatch] {
        let normalized = try normalizedMessageID(messageID)
        let bracketed = "<\(normalized)>"
        let script = messageSearchScript(normalized: normalized, bracketed: bracketed, limit: limit)
        let result = try runAppleScript(script)
        guard result.descriptorType == typeAEList else {
            throw MailControlError.searchFailed
        }
        return decodeMatches(from: result)
    }

    internal static func messageURL(for messageID: String) throws -> URL {
        let normalized = try normalizedMessageID(messageID)
        let wrapped = "<\(normalized)>"
        let disallowed = CharacterSet(charactersIn: "/?&%#<>\"")
        let allowed = CharacterSet.urlPathAllowed.subtracting(disallowed)
        guard let encoded = wrapped.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "message://\(encoded)") else {
            throw MailControlError.invalidMessageID
        }
        return url
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

    internal static func messageSearchScript(for messageID: String, limit: Int = 5) throws -> String {
        let normalized = try normalizedMessageID(messageID)
        let bracketed = "<\(normalized)>"
        return messageSearchScript(normalized: normalized, bracketed: bracketed, limit: limit)
    }

    private static func messageSearchScript(normalized: String,
                                            bracketed: String,
                                            limit: Int) -> String {
        let safeNormalized = escapedForAppleScript(normalized)
        let safeBracketed = escapedForAppleScript(bracketed)
        return """
        set _rows to {}
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
            set _count to 0
            repeat with m in _matches
              set _mailbox to mailbox of m
              set _mailboxName to (name of _mailbox as string)
              set _accountName to ""
              try
                set _accountName to (name of account of _mailbox as string)
              on error
                set _accountName to ""
              end try
              set _subject to ""
              try
                set _subject to (subject of m as string)
              on error
                set _subject to ""
              end try
              set _msgID to (message id of m as string)
              set _date to ""
              try
                set _date to (date received of m as string)
              on error
                set _date to ""
              end try
              copy (_msgID & "||" & _subject & "||" & _mailboxName & "||" & _accountName & "||" & _date) to end of _rows
              set _count to _count + 1
              if _count is greater than or equal to \(limit) then exit repeat
            end repeat
          end timeout
        end tell
        return _rows
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

    private static func decodeMatches(from result: NSAppleEventDescriptor) -> [MessageMatch] {
        var matches: [MessageMatch] = []
        guard result.numberOfItems > 0 else { return [] }
        matches.reserveCapacity(result.numberOfItems)
        for index in 1...result.numberOfItems {
            guard let row = result.atIndex(index)?.stringValue else { continue }
            let parts = row.components(separatedBy: "||")
            guard parts.count >= 5 else { continue }
            let rawID = parts[0]
            let cleanedID = cleanMessageIDPreservingCase(rawID)
            let messageID = cleanedID.isEmpty ? JWZThreader.normalizeIdentifier(rawID) : cleanedID
            let subject = parts[1]
            let mailbox = parts[2]
            let account = parts[3]
            let date = parts[4]
            matches.append(MessageMatch(messageID: messageID,
                                        subject: subject,
                                        mailbox: mailbox,
                                        account: account,
                                        date: date))
        }
        return matches
    }
}
