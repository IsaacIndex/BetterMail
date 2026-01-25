import Carbon
import Foundation
import OSLog

private enum MailAppleScriptClientError: Error {
    case malformedDescriptor
    case missingMessageID
}

internal actor MailAppleScriptClient {
    private let scriptRunner: NSAppleScriptRunner

    internal init(scriptRunner: NSAppleScriptRunner = NSAppleScriptRunner()) {
        self.scriptRunner = scriptRunner
    }

    private enum RowIndex {
        static let messageID = 1
        static let subject = 2
        static let mailbox = 3
        static let date = 4
        static let read = 5
        static let source = 6
        static let body = 7
    }

    internal func fetchMessages(since date: Date?,
                                limit: Int = 10,
                                mailbox: String = "inbox",
                                snippetLineLimit: Int = 10) async throws -> [EmailMessage] {
        let sinceDisplay = date?.ISO8601Format() ?? "nil"
        Log.appleScript.info("fetchMessages requested. mailbox=\(mailbox, privacy: .public) limit=\(limit, privacy: .public) since=\(sinceDisplay, privacy: .public)")
        let script = buildScript(mailbox: mailbox, limit: limit, since: date)
        Log.appleScript.debug("Generated AppleScript of \(script.count, privacy: .public) characters.")
        let descriptor = try await scriptRunner.run(script)
        return try decodeMessages(from: descriptor, mailbox: mailbox, snippetLineLimit: snippetLineLimit)
    }

    internal func fetchMessages(in range: DateInterval,
                                limit: Int = 10,
                                mailbox: String = "inbox",
                                snippetLineLimit: Int = 10) async throws -> [EmailMessage] {
        let now = Date()
        let startWindow = max(0, Int(now.timeIntervalSince(range.start)))
        let clampedEnd = min(range.end, now)
        let endWindow = max(0, Int(now.timeIntervalSince(clampedEnd)))
        Log.appleScript.info("fetchMessages requested. mailbox=\(mailbox, privacy: .public) limit=\(limit, privacy: .public) rangeStart=\(range.start.ISO8601Format(), privacy: .public) rangeEnd=\(range.end.ISO8601Format(), privacy: .public)")
        let script = buildScript(mailbox: mailbox,
                                 limit: limit,
                                 startWindow: startWindow,
                                 endWindow: endWindow)
        Log.appleScript.debug("Generated AppleScript of \(script.count, privacy: .public) characters.")
        let descriptor = try await scriptRunner.run(script)
        return try decodeMessages(from: descriptor, mailbox: mailbox, snippetLineLimit: snippetLineLimit)
    }

    internal func countMessages(in range: DateInterval, mailbox: String = "inbox") async throws -> Int {
        let now = Date()
        let startWindow = max(0, Int(now.timeIntervalSince(range.start)))
        let clampedEnd = min(range.end, now)
        let endWindow = max(0, Int(now.timeIntervalSince(clampedEnd)))
        Log.appleScript.info("countMessages requested. mailbox=\(mailbox, privacy: .public) rangeStart=\(range.start.ISO8601Format(), privacy: .public) rangeEnd=\(range.end.ISO8601Format(), privacy: .public)")
        let script = buildCountScript(mailbox: mailbox,
                                      startWindow: startWindow,
                                      endWindow: endWindow)
        Log.appleScript.debug("Generated count AppleScript of \(script.count, privacy: .public) characters.")
        let descriptor = try await scriptRunner.run(script)
        if descriptor.descriptorType != typeSInt32 && descriptor.descriptorType != typeSInt16 {
            Log.appleScript.error("countMessages failed to decode count; descriptorType=\(descriptor.descriptorType, privacy: .public)")
            throw MailAppleScriptClientError.malformedDescriptor
        }
        let countValue = descriptor.int32Value
        Log.appleScript.info("countMessages result=\(countValue, privacy: .public)")
        return Int(countValue)
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
                set _body to ""
                try
                  set _src to (source of m as string)
                on error
                  set _src to ""
                end try
                try
                  set _body to (content of m as string)
                on error
                  set _body to ""
                end try
                copy {(message id of m as string), (subject of m as string), _mailboxName, (date received of m), (read status of m), _src, _body} to end of _rows
                set _count to _count + 1
                if _count is greater than or equal to _limit then exit repeat
              end if
            end repeat
          end timeout
        end tell
        return _rows
        """
    }

    private func buildScript(mailbox: String, limit: Int, startWindow: Int, endWindow: Int) -> String {
        let escapedPath = MailControl.mailboxReference(path: mailbox, account: nil)
        return """
        set _rows to {}
        set _limit to \(limit)
        set _startWindow to \(startWindow)
        set _endWindow to \(endWindow)
        set _now to (current date)
        set _startCutoff to _now
        set _endCutoff to _now
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _mbx to \(escapedPath)
            set _mailboxName to (name of _mbx as string)
            set _msgs to messages of _mbx
            set _count to 0
            if _startWindow > 0 then
              set _startCutoff to _now - _startWindow
            end if
            if _endWindow > 0 then
              set _endCutoff to _now - _endWindow
            end if
            repeat with m in _msgs
              set _shouldInclude to true
              if _startWindow > 0 then
                set _shouldInclude to ((date received of m) is greater than or equal to _startCutoff)
              end if
              if _shouldInclude and _endWindow > 0 then
                set _shouldInclude to ((date received of m) is less than _endCutoff)
              end if
              if _shouldInclude then
                set _src to ""
                set _body to ""
                try
                  set _src to (source of m as string)
                on error
                  set _src to ""
                end try
                try
                  set _body to (content of m as string)
                on error
                  set _body to ""
                end try
                copy {(message id of m as string), (subject of m as string), _mailboxName, (date received of m), (read status of m), _src, _body} to end of _rows
                set _count to _count + 1
                if _count is greater than or equal to _limit then exit repeat
              end if
            end repeat
          end timeout
        end tell
        return _rows
        """
    }

    private func buildCountScript(mailbox: String, startWindow: Int, endWindow: Int) -> String {
        let escapedPath = MailControl.mailboxReference(path: mailbox, account: nil)
        return """
        set _count to 0
        set _startWindow to \(startWindow)
        set _endWindow to \(endWindow)
        set _now to (current date)
        set _startCutoff to _now
        set _endCutoff to _now
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _mbx to \(escapedPath)
            set _msgs to messages of _mbx
            if _startWindow > 0 then
              set _startCutoff to _now - _startWindow
            end if
            if _endWindow > 0 then
              set _endCutoff to _now - _endWindow
            end if
            repeat with m in _msgs
              set _shouldInclude to true
              if _startWindow > 0 then
                set _shouldInclude to ((date received of m) is greater than or equal to _startCutoff)
              end if
              if _shouldInclude and _endWindow > 0 then
                set _shouldInclude to ((date received of m) is less than _endCutoff)
              end if
              if _shouldInclude then
                set _count to _count + 1
              end if
            end repeat
          end timeout
        end tell
        return _count
        """
    }

    private func decodeMessages(from descriptor: NSAppleEventDescriptor,
                                mailbox: String,
                                snippetLineLimit: Int) throws -> [EmailMessage] {
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
            guard let row = descriptor.atIndex(index), row.numberOfItems >= RowIndex.body else { continue }
            guard let rawMessageID = row.atIndex(RowIndex.messageID)?.stringValue else { continue }
            let normalizedID = JWZThreader.normalizeIdentifier(rawMessageID)
            let canonicalID = normalizedID.isEmpty ? UUID().uuidString.lowercased() : normalizedID
            let subject = row.atIndex(RowIndex.subject)?.stringValue ?? "(No Subject)"
            let mailboxID = row.atIndex(RowIndex.mailbox)?.stringValue ?? mailbox
            let dateValue = row.atIndex(RowIndex.date)?.dateValue ?? Date()
            let isRead = row.atIndex(RowIndex.read)?.booleanValue ?? true
            guard let source = row.atIndex(RowIndex.source)?.stringValue else { continue }
            let bodyText = row.atIndex(RowIndex.body)?.stringValue ?? ""
            let headers = decoder.headers(from: source)
            let references = decoder.references(from: headers)
            let replyHeader = headers["in-reply-to"].flatMap { JWZThreader.normalizeIdentifier($0) }
            let inReplyTo = (replyHeader?.isEmpty == false) ? replyHeader : nil
            let recipients = headers["to"] ?? ""
            let sender = headers["from"] ?? ""
            let snippetPreviewLineLimit = snippetLineLimit == Int.max ? snippetLineLimit : snippetLineLimit + 1
            let snippet = decoder.bodySnippet(fromBody: bodyText,
                                              fallbackSource: source,
                                              maxLines: snippetPreviewLineLimit)

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

    func bodySnippet(fromBody body: String,
                     fallbackSource source: String,
                     maxLength: Int = 400,
                     maxLines: Int = 20) -> String {
        let cleanedBody = cleanedSnippetLines(from: body, maxLines: maxLines)
        if !cleanedBody.isEmpty {
            return truncate(cleanedBody, maxLength: maxLength)
        }
        return bodySnippetFromSource(source, maxLength: maxLength, maxLines: maxLines)
    }

    private func bodySnippetFromSource(_ source: String, maxLength: Int, maxLines: Int) -> String {
        let normalizedSource = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = normalizedSource.range(of: "\n\n") else { return "" }
        let body = normalizedSource[range.upperBound...]
        let cleaned = cleanedSnippetLines(from: String(body), maxLines: maxLines)
        if cleaned.isEmpty {
            return ""
        }
        return truncate(cleaned, maxLength: maxLength)
    }

    private func cleanedSnippetLines(from text: String, maxLines: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let cleaned = lines.compactMap { line -> String? in
            let value = cleanSnippetLine(String(line))
            return value.isEmpty ? nil : value
        }
        guard !cleaned.isEmpty else { return "" }
        let limited = maxLines > 0 ? Array(cleaned.prefix(maxLines)) : cleaned
        return limited.joined(separator: "\n")
    }

    private func cleanSnippetLine(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if cleaned.contains("<") && cleaned.contains(">") {
            cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }

        cleaned = cleaned
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        let parts = cleaned.split { $0.isWhitespace }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        if text.count > maxLength {
            let index = text.index(text.startIndex, offsetBy: maxLength)
            return String(text[..<index]) + "…"
        }
        return text
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
