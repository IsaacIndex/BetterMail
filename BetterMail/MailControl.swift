//
//  MailControl.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import Foundation

struct MailControl {

    static func moveSelection(to mailboxPath: String, in account: String) throws {
        let script = """
        tell application "Mail"
          set destMailbox to mailbox "\(mailboxPath)" of account "\(account)"
          repeat with m in selection
            move m to destMailbox
          end repeat
        end tell
        """
        _ = try runAppleScript(script)
    }

    static func flagSelection(colorIndex: Int = 4) throws {
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

    static func searchInboxSubject(contains text: String, limit: Int = 50) throws -> [String] {
        // Returns subjects for simplicity (you can expand to return more fields)
        let script = """
        set _hits to {}
        tell application "Mail"
          repeat with m in (messages of inbox whose subject contains "\(text)")
            copy (subject of m as string) to end of _hits
            if (count of _hits) ≥ \(limit) then exit repeat
          end repeat
        end tell
        return _hits
        """
        guard let r = try runAppleScript(script) else { return [] }
        return (0..<r.numberOfItems).map { r.atIndex($0+1)?.stringValue ?? "" }
    }

    static func fetchRecent(from mailbox: String = "inbox",
                            account: String? = nil,
                            daysBack: Int = 7,
                            limit: Int = 200) throws -> [[String: String]] {
        // Pulls a lightweight timeline: subject, sender, date received
        let script = """
        set _rows to {}
        set _cutoff to (current date) - (#{DAYS} * days)
        tell application "Mail"
          #{MAILBOX_RESOLVE}
          set _msgs to messages of _mbx
          set _count to 0
          repeat with m in _msgs
            if (date received of m) ≥ _cutoff then
              set _row to (subject of m as string) & "||" & (sender of m as string) & "||" & ((date received of m) as string)
              copy _row to end of _rows
              set _count to _count + 1
              if _count ≥ #{LIMIT} then exit repeat
            end if
          end repeat
        end tell
        return _rows
        """
        .replacingOccurrences(of: "#{DAYS}", with: String(daysBack))
        .replacingOccurrences(of: "#{LIMIT}", with: String(limit))
        .replacingOccurrences(of: "#{MAILBOX_RESOLVE}", with:
            account == nil
            ? "set _mbx to \(mailbox)"
            : "set _mbx to mailbox \"\(mailbox)\" of account \"\(account!)\""
        )

        guard let r = try runAppleScript(script) else { return [] }
        return (0..<r.numberOfItems).compactMap { i in
            (r.atIndex(i+1)?.stringValue ?? "").split(separator: "|", omittingEmptySubsequences: false).count == 6
            ? { let parts = (r.atIndex(i+1)?.stringValue ?? "").components(separatedBy: "||")
                return ["subject": parts[0], "sender": parts[1], "date": parts[2]] }()
            : nil
        }
    }
}
