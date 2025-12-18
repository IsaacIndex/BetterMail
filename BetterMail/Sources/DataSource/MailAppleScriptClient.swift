import Carbon
import Foundation
import OSLog

enum MailAppleScriptClientError: Error {
    case malformedDescriptor
    case missingMessageID
}

struct MailAppleScriptClient {
    private enum RowIndex {
        static let messageID = 1
        static let subject = 2
        static let mailbox = 3
        static let date = 4
        static let read = 5
        static let source = 6
    }

    func fetchMessages(since date: Date?, limit: Int = 10, mailbox: String = "inbox") throws -> [EmailMessage] {
        let sinceDisplay = date?.ISO8601Format() ?? "nil"
        Log.appleScript.info("fetchMessages requested. mailbox=\(mailbox, privacy: .public) limit=\(limit, privacy: .public) since=\(sinceDisplay, privacy: .public)")
        let script = buildScript(mailbox: mailbox, limit: limit, since: date)
        Log.appleScript.debug("Generated AppleScript of \(script.count, privacy: .public) characters.")
        let descriptor = try runAppleScript(script)
        Log.appleScript.debug("AppleScript returned \(descriptor.numberOfItems, privacy: .public) rows.")
        guard descriptor.descriptorType == typeAEList else {
            throw MailAppleScriptClientError.malformedDescriptor
        }

        var messages: [EmailMessage] = []
        messages.reserveCapacity(descriptor.numberOfItems)

        let decoder = HeaderDecoder()
        guard descriptor.numberOfItems > 0 else {
            Log.appleScript.info("Descriptor contained no items.")
            return []
        }

        for index in 1...descriptor.numberOfItems {
            guard let row = descriptor.atIndex(index), row.numberOfItems >= RowIndex.source else { continue }
            guard let rawMessageID = row.atIndex(RowIndex.messageID)?.stringValue else { continue }
            let normalizedID = JWZThreader.normalizeIdentifier(rawMessageID)
            let canonicalID = normalizedID.isEmpty ? UUID().uuidString.lowercased() : normalizedID
            let subject = row.atIndex(RowIndex.subject)?.stringValue ?? "(No Subject)"
            let mailboxID = row.atIndex(RowIndex.mailbox)?.stringValue ?? mailbox
            let dateValue = row.atIndex(RowIndex.date)?.dateValue ?? Date()
            let isRead = row.atIndex(RowIndex.read)?.booleanValue ?? true
            guard let source = row.atIndex(RowIndex.source)?.stringValue else { continue }
            let headers = decoder.headers(from: source)
            let references = decoder.references(from: headers)
            let replyHeader = headers["in-reply-to"].flatMap { JWZThreader.normalizeIdentifier($0) }
            let inReplyTo = (replyHeader?.isEmpty == false) ? replyHeader : nil
            let recipients = headers["to"] ?? ""
            let sender = headers["from"] ?? ""
            let snippet = decoder.bodySnippet(from: source)

            let email = EmailMessage(messageID: canonicalID,
                                     mailboxID: mailboxID,
                                     subject: subject,
                                     from: sender,
                                     to: recipients,
                                     date: dateValue,
                                     snippet: snippet,
                                     isUnread: !isRead,
                                     inReplyTo: inReplyTo,
                                     references: references)
            messages.append(email)
        }
        Log.appleScript.info("Decoded \(messages.count, privacy: .public) messages from AppleScript response.")
        return messages
    }

    private func buildScript(mailbox: String, limit: Int, since: Date?) -> String {
        let windowSeconds: Int
        if let since {
            windowSeconds = max(0, Int(Date().timeIntervalSince(since)))
        } else {
            windowSeconds = 0
        }

        let escapedPath = MailControl.mailboxReference(path: mailbox, account: nil)
        return """
        set _rows to {}
        set _limit to \(limit)
        set _window to \(windowSeconds)
        set _now to (current date)
        set _cutoff to _now
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _mbx to \(escapedPath)
            set _mailboxName to (name of _mbx as string)
            set _msgs to messages of _mbx
            set _count to 0
            if _window > 0 then
              set _cutoff to _now - _window
            end if
            repeat with m in _msgs
              set _shouldInclude to true
              if _window > 0 then
                set _shouldInclude to ((date received of m) is greater than or equal to _cutoff)
              end if
              if _shouldInclude then
                set _src to ""
                try
                  set _src to (source of m as string)
                on error
                  set _src to ""
                end try
                copy {(message id of m as string), (subject of m as string), _mailboxName, (date received of m), (read status of m), _src} to end of _rows
                set _count to _count + 1
                if _count is greater than or equal to _limit then exit repeat
              end if
            end repeat
          end timeout
        end tell
        return _rows
        """
    }
}

private struct HeaderDecoder {
    func headers(from source: String) -> [String: String] {
        let normalizedSource = source.replacingOccurrences(of: "\r\n", with: "\n")
        var headers: [String: String] = [:]
        var currentKey: String?
        let lines = normalizedSource.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            if line.isEmpty {
                break
            }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let key = currentKey else { continue }
                let value = (headers[key] ?? "") + line.trimmingCharacters(in: .whitespaces)
                headers[key] = value
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
            currentKey = key
        }
        return headers
    }

    func references(from headers: [String: String]) -> [String] {
        let refs = headers[ "references"] ?? ""
        return extractIdentifiers(from: refs)
    }

    func bodySnippet(from source: String, maxLength: Int = 120) -> String {
        let normalizedSource = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = normalizedSource.range(of: "\n\n") else { return "" }
        let body = normalizedSource[range.upperBound...]
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstLine = lines.first(where: { !$0.isEmpty }) else { return "" }
        if firstLine.count > maxLength {
            let index = firstLine.index(firstLine.startIndex, offsetBy: maxLength)
            return String(firstLine[..<index]) + "…"
        }
        return firstLine
    }

    private func extractIdentifiers(from value: String) -> [String] {
        var identifiers: [String] = []
        var current = ""
        var recording = false
        for char in value {
            if char == "<" {
                recording = true
                current = ""
            } else if char == ">" {
                recording = false
                let normalized = JWZThreader.normalizeIdentifier(current)
                if !normalized.isEmpty {
                    identifiers.append(normalized)
                }
            } else if recording {
                current.append(char)
            }
        }
        return identifiers
    }
}
 
private extension String {
    var fourCharCodeValue: FourCharCode {
        var result: FourCharCode = 0
        for scalar in unicodeScalars.prefix(4) {
            result = (result << 8) + FourCharCode(scalar.value)
        }
        let missing = 4 - unicodeScalars.count
        if missing > 0 {
            for _ in 0..<missing {
                result = result << 8
            }
        }
        return result
    }
}
