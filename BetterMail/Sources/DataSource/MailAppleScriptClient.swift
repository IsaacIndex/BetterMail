import Carbon
import Foundation
import OSLog

private enum MailAppleScriptClientError: Error {
    case malformedDescriptor
    case missingMessageID
}

internal actor MailAppleScriptClient {
    private enum LogPrefix {
        static let backfillCount = "[BACKFILL][COUNT]"
        static let backfillFetch = "[BACKFILL][FETCH]"
        static let subjectCount = "[SUBJECT][COUNT]"
        static let subjectFetch = "[SUBJECT][FETCH]"
    }

    private let scriptRunner: NSAppleScriptRunner

    internal init(scriptRunner: NSAppleScriptRunner = NSAppleScriptRunner()) {
        self.scriptRunner = scriptRunner
    }

    private func escapedForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private enum RowIndex {
        static let internalMailID = 1
        static let messageID = 2
        static let subject = 3
        static let mailbox = 4
        static let account = 5
        static let date = 6
        static let read = 7
        static let source = 8
        static let body = 9
    }

    private enum MailboxRowIndex {
        static let account = 1
        static let path = 2
        static let name = 3
        static let parentPath = 4
    }

    internal func fetchMessages(since date: Date?,
                                limit: Int = 10,
                                mailbox: String = "inbox",
                                account: String? = nil,
                                snippetLineLimit: Int = 10) async throws -> [EmailMessage] {
        try Task.checkCancellation()
        let sinceDisplay = date?.ISO8601Format() ?? "nil"
        Log.appleScript.info("fetchMessages requested. mailbox=\(mailbox, privacy: .public) account=\(account ?? "", privacy: .public) limit=\(limit, privacy: .public) since=\(sinceDisplay, privacy: .public)")
        let script = buildScript(mailbox: mailbox, account: account, limit: limit, since: date)
        Log.appleScript.debug("Generated AppleScript of \(script.count, privacy: .public) characters.")
        let descriptor = try await scriptRunner.run(script)
        try Task.checkCancellation()
        return try decodeMessages(from: descriptor, mailbox: mailbox, snippetLineLimit: snippetLineLimit)
    }

    internal func fetchMessages(in range: DateInterval,
                                limit: Int = 10,
                                mailbox: String = "inbox",
                                account: String? = nil,
                                snippetLineLimit: Int = 10) async throws -> [EmailMessage] {
        try Task.checkCancellation()
        let now = Date()
        let startWindow = max(0, Int(now.timeIntervalSince(range.start)))
        let clampedEnd = min(range.end, now)
        let endWindow = max(0, Int(now.timeIntervalSince(clampedEnd)))
        Log.appleScript.info("\(LogPrefix.backfillFetch, privacy: .public) fetchMessages requested. mailbox=\(mailbox, privacy: .public) account=\(account ?? "", privacy: .public) limit=\(limit, privacy: .public) rangeStart=\(range.start.ISO8601Format(), privacy: .public) rangeEnd=\(range.end.ISO8601Format(), privacy: .public)")
        let script = buildScript(mailbox: mailbox,
                                 account: account,
                                 limit: limit,
                                 startWindow: startWindow,
                                 endWindow: endWindow)
        Log.appleScript.debug("\(LogPrefix.backfillFetch, privacy: .public) Generated AppleScript of \(script.count, privacy: .public) characters.")
        let descriptor = try await scriptRunner.run(script, logPrefix: LogPrefix.backfillFetch)
        try Task.checkCancellation()
        return try decodeMessages(from: descriptor, mailbox: mailbox, snippetLineLimit: snippetLineLimit)
    }

    internal func countMessages(in range: DateInterval, mailbox: String = "inbox", account: String? = nil) async throws -> Int {
        try Task.checkCancellation()
        let now = Date()
        let startWindow = max(0, Int(now.timeIntervalSince(range.start)))
        let clampedEnd = min(range.end, now)
        let endWindow = max(0, Int(now.timeIntervalSince(clampedEnd)))
        Log.appleScript.info("\(LogPrefix.backfillCount, privacy: .public) countMessages requested. mailbox=\(mailbox, privacy: .public) account=\(account ?? "", privacy: .public) rangeStart=\(range.start.ISO8601Format(), privacy: .public) rangeEnd=\(range.end.ISO8601Format(), privacy: .public)")
        let script = buildCountScript(mailbox: mailbox,
                                      account: account,
                                      startWindow: startWindow,
                                      endWindow: endWindow)
        Log.appleScript.debug("\(LogPrefix.backfillCount, privacy: .public) Generated count AppleScript of \(script.count, privacy: .public) characters.")
        let descriptor = try await scriptRunner.run(script, logPrefix: LogPrefix.backfillCount)
        try Task.checkCancellation()
        if descriptor.descriptorType != typeSInt32 && descriptor.descriptorType != typeSInt16 {
            Log.appleScript.error("\(LogPrefix.backfillCount, privacy: .public) countMessages failed to decode count; descriptorType=\(descriptor.descriptorType, privacy: .public)")
            throw MailAppleScriptClientError.malformedDescriptor
        }
        let countValue = descriptor.int32Value
        Log.appleScript.info("\(LogPrefix.backfillCount, privacy: .public) countMessages result=\(countValue, privacy: .public)")
        return Int(countValue)
    }

    internal func fetchMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                                limit: Int = 10,
                                mailbox: String = "inbox",
                                account: String? = nil,
                                snippetLineLimit: Int = 10) async throws -> [EmailMessage] {
        let filteredSubjects = normalizedSubjects
            .map { MailboxRefreshSubjectNormalizer.normalize($0) }
            .filter { !$0.isEmpty }
        guard !filteredSubjects.isEmpty else { return [] }
        try Task.checkCancellation()
        Log.appleScript.info("\(LogPrefix.subjectFetch, privacy: .public) fetchMessages requested. mailbox=\(mailbox, privacy: .public) account=\(account ?? "", privacy: .public) limit=\(limit, privacy: .public) subjectCount=\(filteredSubjects.count, privacy: .public)")
        let script = buildSubjectScopedScript(mailbox: mailbox,
                                              account: account,
                                              normalizedSubjects: filteredSubjects,
                                              limit: limit)
        Log.appleScript.debug("\(LogPrefix.subjectFetch, privacy: .public) Generated subject AppleScript of \(script.count, privacy: .public) characters.")
        let descriptor = try await scriptRunner.run(script, logPrefix: LogPrefix.subjectFetch)
        try Task.checkCancellation()
        return try decodeMessages(from: descriptor, mailbox: mailbox, snippetLineLimit: snippetLineLimit)
    }

    internal func countMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                                mailbox: String = "inbox",
                                account: String? = nil) async throws -> Int {
        let filteredSubjects = normalizedSubjects
            .map { MailboxRefreshSubjectNormalizer.normalize($0) }
            .filter { !$0.isEmpty }
        guard !filteredSubjects.isEmpty else { return 0 }
        try Task.checkCancellation()
        Log.appleScript.info("\(LogPrefix.subjectCount, privacy: .public) countMessages requested. mailbox=\(mailbox, privacy: .public) account=\(account ?? "", privacy: .public) subjectCount=\(filteredSubjects.count, privacy: .public)")
        let script = buildSubjectScopedCountScript(mailbox: mailbox,
                                                   account: account,
                                                   normalizedSubjects: filteredSubjects)
        Log.appleScript.debug("\(LogPrefix.subjectCount, privacy: .public) Generated subject count AppleScript of \(script.count, privacy: .public) characters.")
        let descriptor = try await scriptRunner.run(script, logPrefix: LogPrefix.subjectCount)
        try Task.checkCancellation()
        if descriptor.descriptorType != typeSInt32 && descriptor.descriptorType != typeSInt16 {
            Log.appleScript.error("\(LogPrefix.subjectCount, privacy: .public) countMessages failed to decode count; descriptorType=\(descriptor.descriptorType, privacy: .public)")
            throw MailAppleScriptClientError.malformedDescriptor
        }
        let countValue = descriptor.int32Value
        Log.appleScript.info("\(LogPrefix.subjectCount, privacy: .public) countMessages result=\(countValue, privacy: .public)")
        return Int(countValue)
    }

    internal func fetchMailboxHierarchy() async throws -> [MailboxFolder] {
        let script = buildMailboxHierarchyScript()
        Log.appleScript.debug("Generated mailbox hierarchy AppleScript of \(script.count, privacy: .public) characters.")
        let descriptor = try await scriptRunner.run(script)
        return try decodeMailboxFolders(from: descriptor)
    }

    private func mailboxPathHelpersScript() -> String {
        """
        on mailboxPathForMailbox(_mailboxRef)
          set _parts to {}
          set _current to _mailboxRef
          repeat
            try
              set _name to (name of _current as string)
            on error
              exit repeat
            end try
            set beginning of _parts to _name
            try
              set _current to (mailbox of _current)
            on error
              exit repeat
            end try
          end repeat
          set _originalTIDs to AppleScript's text item delimiters
          set AppleScript's text item delimiters to "/"
          set _path to _parts as string
          set AppleScript's text item delimiters to _originalTIDs
          return _path
        end mailboxPathForMailbox
        """
    }

    private func mailboxResolverScript(mailbox: String, account: String?) -> String {
        let safeMailboxPath = escapedForAppleScript(mailbox.trimmingCharacters(in: .whitespacesAndNewlines))
        let safeAccount = escapedForAppleScript((account ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        return """
        \(mailboxPathHelpersScript())
        on trimText(_value)
          set _s to _value as string
          set _ws to {space, tab, return, linefeed}
          repeat while _s is not "" and character 1 of _s is in _ws
            set _s to text 2 thru -1 of _s
          end repeat
          repeat while _s is not "" and character -1 of _s is in _ws
            set _s to text 1 thru -2 of _s
          end repeat
          return _s
        end trimText

        on splitMailboxPath(_pathText)
          set _trimmedPath to my trimText(_pathText)
          if _trimmedPath is "" then return {}
          set _originalTIDs to AppleScript's text item delimiters
          set AppleScript's text item delimiters to "/"
          set _parts to text items of _trimmedPath
          set AppleScript's text item delimiters to _originalTIDs
          set _trimmedParts to {}
          repeat with _part in _parts
            set _value to my trimText(contents of _part as string)
            if _value is not "" then
              copy _value to end of _trimmedParts
            end if
          end repeat
          return _trimmedParts
        end splitMailboxPath

        on matchingAccounts(_accountToken)
          set _results to {}
          set _token to my trimText(_accountToken)
          tell application id "com.apple.mail"
            repeat with _acct in every account
              set _acctValue to contents of _acct
              set _matched to false
              if _token is "" then
                set _matched to true
              else
                ignoring case
                  try
                    if (name of _acctValue as string) is _token then
                      set _matched to true
                    end if
                  end try
                  if not _matched then
                    try
                      if (id of _acctValue as string) is _token then
                        set _matched to true
                      end if
                    end try
                  end if
                end ignoring
              end if
              if _matched then
                copy _acctValue to end of _results
              end if
            end repeat
          end tell
          return _results
        end matchingAccounts

        on resolveMailboxByPath(_accountToken, _mailboxPathToken)
          set _wantedPath to my trimText(_mailboxPathToken)
          set _wantedParts to my splitMailboxPath(_wantedPath)
          if (count of _wantedParts) is 0 then return missing value
          set _leaf to item -1 of _wantedParts as string
          set _accounts to my matchingAccounts(_accountToken)
          if (count of _accounts) is 0 then return missing value

          tell application id "com.apple.mail"
            -- pass 1: hierarchical path walk
            repeat with _acct in _accounts
              set _candidates to {}
              try
                set _candidates to every mailbox of _acct
              end try
              set _resolvedMailbox to missing value
              repeat with _part in _wantedParts
                set _partName to contents of _part as string
                set _foundMailbox to missing value
                ignoring case
                  repeat with _candidate in _candidates
                    try
                      if (name of _candidate as string) is _partName then
                        set _foundMailbox to _candidate
                        exit repeat
                      end if
                    end try
                  end repeat
                end ignoring
                if _foundMailbox is missing value then
                  set _resolvedMailbox to missing value
                  exit repeat
                end if
                set _resolvedMailbox to _foundMailbox
                try
                  set _candidates to every mailbox of _resolvedMailbox
                on error
                  set _candidates to {}
                end try
              end repeat
              if _resolvedMailbox is not missing value then
                return _resolvedMailbox
              end if
            end repeat

            -- pass 2: exact full-path match among all account mailboxes
            repeat with _acct in _accounts
              set _allMailboxes to {}
              try
                set _allMailboxes to every mailbox of _acct
              end try
              repeat with _candidate in _allMailboxes
                set _candidatePath to my mailboxPathForMailbox(_candidate)
                ignoring case
                  if _candidatePath is _wantedPath then
                    return _candidate
                  end if
                end ignoring
              end repeat
            end repeat

            -- pass 3: leaf fallback only when no exact path match exists
            repeat with _acct in _accounts
              set _allMailboxes to {}
              try
                set _allMailboxes to every mailbox of _acct
              end try
              repeat with _candidate in _allMailboxes
                try
                  ignoring case
                    if (name of _candidate as string) is _leaf then
                      return _candidate
                    end if
                  end ignoring
                end try
              end repeat
            end repeat
          end tell
          return missing value
        end resolveMailboxByPath

        set _mailboxPathToken to "\(safeMailboxPath)"
        set _accountToken to "\(safeAccount)"
        set _mbx to my resolveMailboxByPath(_accountToken, _mailboxPathToken)
        if _mbx is missing value then
          error "Mailbox not found for path: " & _mailboxPathToken & " account: " & _accountToken number -1728
        end if
        """
    }

    private func buildScript(mailbox: String, account: String?, limit: Int, since: Date?) -> String {
        let windowSeconds: Int
        if let since {
            windowSeconds = max(0, Int(Date().timeIntervalSince(since)))
        } else {
            windowSeconds = 0
        }

        return """
        \(mailboxResolverScript(mailbox: mailbox, account: account))
        set _rows to {}
        set _limit to \(limit)
        set _window to \(windowSeconds)
        set _now to (current date)
        set _cutoff to _now
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _mailboxName to (name of _mbx as string)
            set _accountName to ""
            try
              set _accountName to (name of account of _mbx as string)
            on error
              set _accountName to ""
            end try
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
                set _msgMailboxPath to _mailboxName
                set _msgAccountName to _accountName
                try
                  set _msgMailbox to (mailbox of m)
                  set _msgMailboxPath to my mailboxPathForMailbox(_msgMailbox)
                  try
                    set _msgAccountName to (name of account of _msgMailbox as string)
                  on error
                    set _msgAccountName to _accountName
                  end try
                on error
                  set _msgMailboxPath to _mailboxName
                  set _msgAccountName to _accountName
                end try
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
                copy {(id of m as string), (message id of m as string), (subject of m as string), _msgMailboxPath, _msgAccountName, (date received of m), (read status of m), _src, _body} to end of _rows
                set _count to _count + 1
                if _count is greater than or equal to _limit then exit repeat
              end if
            end repeat
          end timeout
        end tell
        return _rows
        """
    }

    private func buildScript(mailbox: String, account: String?, limit: Int, startWindow: Int, endWindow: Int) -> String {
        return """
        \(mailboxResolverScript(mailbox: mailbox, account: account))
        set _rows to {}
        set _limit to \(limit)
        set _startWindow to \(startWindow)
        set _endWindow to \(endWindow)
        set _now to (current date)
        set _startCutoff to _now
        set _endCutoff to _now
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _mailboxName to (name of _mbx as string)
            set _accountName to ""
            try
              set _accountName to (name of account of _mbx as string)
            on error
              set _accountName to ""
            end try
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
                set _msgMailboxPath to _mailboxName
                set _msgAccountName to _accountName
                try
                  set _msgMailbox to (mailbox of m)
                  set _msgMailboxPath to my mailboxPathForMailbox(_msgMailbox)
                  try
                    set _msgAccountName to (name of account of _msgMailbox as string)
                  on error
                    set _msgAccountName to _accountName
                  end try
                on error
                  set _msgMailboxPath to _mailboxName
                  set _msgAccountName to _accountName
                end try
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
                copy {(id of m as string), (message id of m as string), (subject of m as string), _msgMailboxPath, _msgAccountName, (date received of m), (read status of m), _src, _body} to end of _rows
                set _count to _count + 1
                if _count is greater than or equal to _limit then exit repeat
              end if
            end repeat
          end timeout
        end tell
        return _rows
        """
    }

    private func appleScriptStringList(_ values: [String]) -> String {
        let escapedValues = values.map { "\"\(escapedForAppleScript($0))\"" }
        return "{\(escapedValues.joined(separator: ", "))}"
    }

    private func normalizedSubjectHelpersScript(normalizedSubjects: [String]) -> String {
        let subjectList = appleScriptStringList(normalizedSubjects)
        return """
        global _normalizedSubjects
        set _normalizedSubjects to \(subjectList)

        on collapseWhitespace(_value)
          set _trimmed to my trimText(_value)
          if _trimmed is "" then return ""
          set _originalTIDs to AppleScript's text item delimiters
          set AppleScript's text item delimiters to {space, tab, return, linefeed}
          set _parts to text items of _trimmed
          set AppleScript's text item delimiters to _originalTIDs
          set _cleanParts to {}
          repeat with _part in _parts
            set _piece to my trimText(contents of _part as string)
            if _piece is not "" then copy _piece to end of _cleanParts
          end repeat
          set AppleScript's text item delimiters to space
          set _collapsed to _cleanParts as string
          set AppleScript's text item delimiters to _originalTIDs
          return _collapsed
        end collapseWhitespace

        on stripLeadingBracketToken(_value)
          set _trimmed to my trimText(_value)
          if _trimmed begins with "[" then
            set _closeOffset to offset of "]" in _trimmed
            if _closeOffset is greater than 0 and _closeOffset < (length of _trimmed) then
              return my trimText(text (_closeOffset + 1) thru -1 of _trimmed)
            else if _closeOffset is greater than 0 then
              return ""
            end if
          end if
          return _trimmed
        end stripLeadingBracketToken

        on normalizedMailboxRefreshSubject(_value)
          set _normalized to my collapseWhitespace(_value)
          if _normalized is "" then return ""
          repeat with _guard from 1 to 12
            set _previous to _normalized
            set _normalized to my stripLeadingBracketToken(_normalized)
            set _changedPrefix to false
            ignoring case
              repeat with _prefix in {"re:", "fw:", "fwd:", "aw:", "sv:", "wg:"}
                if _normalized begins with (contents of _prefix as string) then
                  if (length of _normalized) is greater than (length of (contents of _prefix as string)) then
                    set _normalized to text ((length of (contents of _prefix as string)) + 1) thru -1 of _normalized
                  else
                    set _normalized to ""
                  end if
                  set _normalized to my trimText(_normalized)
                  set _changedPrefix to true
                  exit repeat
                end if
              end repeat
            end ignoring
            set _normalized to my collapseWhitespace(_normalized)
            if _normalized is _previous and _changedPrefix is false then exit repeat
          end repeat
          return my collapseWhitespace(_normalized)
        end normalizedMailboxRefreshSubject

        on normalizedSubjectSetContains(_subjectValue)
          global _normalizedSubjects
          set _candidate to my normalizedMailboxRefreshSubject(_subjectValue)
          if _candidate is "" then return false
          ignoring case
            repeat with _subject in _normalizedSubjects
              if _candidate is (contents of _subject as string) then return true
            end repeat
          end ignoring
          return false
        end normalizedSubjectSetContains
        """
    }

    private func buildSubjectScopedScript(mailbox: String,
                                          account: String?,
                                          normalizedSubjects: [String],
                                          limit: Int) -> String {
        return """
        \(mailboxResolverScript(mailbox: mailbox, account: account))
        \(normalizedSubjectHelpersScript(normalizedSubjects: normalizedSubjects))
        set _rows to {}
        set _limit to \(limit)
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _mailboxName to (name of _mbx as string)
            set _accountName to ""
            try
              set _accountName to (name of account of _mbx as string)
            on error
              set _accountName to ""
            end try
            set _msgs to messages of _mbx
            set _count to 0
            repeat with m in _msgs
              set _subject to ""
              try
                set _subject to (subject of m as string)
              end try
              if my normalizedSubjectSetContains(_subject) then
                set _src to ""
                set _body to ""
                set _msgMailboxPath to _mailboxName
                set _msgAccountName to _accountName
                try
                  set _msgMailbox to (mailbox of m)
                  set _msgMailboxPath to my mailboxPathForMailbox(_msgMailbox)
                  try
                    set _msgAccountName to (name of account of _msgMailbox as string)
                  on error
                    set _msgAccountName to _accountName
                  end try
                on error
                  set _msgMailboxPath to _mailboxName
                  set _msgAccountName to _accountName
                end try
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
                copy {(id of m as string), (message id of m as string), _subject, _msgMailboxPath, _msgAccountName, (date received of m), (read status of m), _src, _body} to end of _rows
                set _count to _count + 1
                if _count is greater than or equal to _limit then exit repeat
              end if
            end repeat
          end timeout
        end tell
        return _rows
        """
    }

    private func buildSubjectScopedCountScript(mailbox: String,
                                               account: String?,
                                               normalizedSubjects: [String]) -> String {
        return """
        \(mailboxResolverScript(mailbox: mailbox, account: account))
        \(normalizedSubjectHelpersScript(normalizedSubjects: normalizedSubjects))
        set _count to 0
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _msgs to messages of _mbx
            repeat with m in _msgs
              set _subject to ""
              try
                set _subject to (subject of m as string)
              end try
              if my normalizedSubjectSetContains(_subject) then
                set _count to _count + 1
              end if
            end repeat
          end timeout
        end tell
        return _count
        """
    }

    private func buildCountScript(mailbox: String, account: String?, startWindow: Int, endWindow: Int) -> String {
        return """
        \(mailboxResolverScript(mailbox: mailbox, account: account))
        set _count to 0
        set _startWindow to \(startWindow)
        set _endWindow to \(endWindow)
        set _now to (current date)
        set _startCutoff to _now
        set _endCutoff to _now
        tell application id "com.apple.mail"
          with timeout of 60 seconds
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

    private func buildMailboxHierarchyScript() -> String {
        """
        on trimText(_value)
          set _s to _value as string
          set _ws to {space, tab, return, linefeed}
          repeat while _s is not "" and character 1 of _s is in _ws
            set _s to text 2 thru -1 of _s
          end repeat
          repeat while _s is not "" and character -1 of _s is in _ws
            set _s to text 1 thru -2 of _s
          end repeat
          return _s
        end trimText

        on childMailboxes(_containerRef)
          tell application id "com.apple.mail"
            try
              return (every mailbox of _containerRef)
            on error
              try
                return (mailboxes of _containerRef)
              on error
                return {}
              end try
            end try
          end tell
        end childMailboxes

        on accountDisplayName(_accountRef)
          set _accountName to ""
          tell application id "com.apple.mail"
            try
              set _accountName to my trimText(name of _accountRef as string)
            end try
            if _accountName is "" then
              try
                set _accountName to my trimText(id of _accountRef as string)
              end try
            end if
          end tell
          if _accountName is "" then set _accountName to "Unknown Account"
          return _accountName
        end accountDisplayName

        on mailboxPathWithinAccount(_mailboxRef, _accountName)
          set _parts to {}
          set _current to _mailboxRef
          repeat with _depth from 1 to 128
            set _name to ""
            tell application id "com.apple.mail"
              try
                set _name to my trimText(name of _current as string)
              end try
            end tell
            if _name is "" then exit repeat
            set beginning of _parts to _name

            set _nextContainer to missing value
            tell application id "com.apple.mail"
              try
                set _nextContainer to (container of _current)
              end try
            end tell
            if _nextContainer is missing value then exit repeat

            set _nextName to ""
            tell application id "com.apple.mail"
              try
                set _nextName to my trimText(name of _nextContainer as string)
              end try
            end tell
            ignoring case
              if _nextName is _accountName then exit repeat
            end ignoring

            set _hasParentContainer to true
            tell application id "com.apple.mail"
              try
                set _probe to container of _nextContainer
              on error
                set _hasParentContainer to false
              end try
            end tell
            if _hasParentContainer is false then exit repeat

            set _current to _nextContainer
          end repeat

          set _originalTIDs to AppleScript's text item delimiters
          set AppleScript's text item delimiters to "/"
          set _path to (_parts as string)
          set AppleScript's text item delimiters to _originalTIDs
          return _path
        end mailboxPathWithinAccount

        on mailboxParentPathWithinAccount(_mailboxRef, _accountName)
          set _containerRef to missing value
          tell application id "com.apple.mail"
            try
              set _containerRef to (container of _mailboxRef)
            end try
          end tell
          if _containerRef is missing value then return ""

          set _isMailboxContainer to true
          tell application id "com.apple.mail"
            try
              set _probe to container of _containerRef
            on error
              set _isMailboxContainer to false
            end try
          end tell
          if _isMailboxContainer is false then return ""

          return my mailboxPathWithinAccount(_containerRef, _accountName)
        end mailboxParentPathWithinAccount

        set _rows to {}
        tell application id \"com.apple.mail\"
          with timeout of 60 seconds
            repeat with _account in (every account)
              set _accountName to my accountDisplayName(_account)
              set _allMailboxes to my childMailboxes(_account)
              repeat with _mailbox in _allMailboxes
                set _name to ""
                try
                  set _name to my trimText(name of _mailbox as string)
                end try
                if _name is not "" then
                  set _path to my mailboxPathWithinAccount(_mailbox, _accountName)
                  if _path is "" then set _path to _name
                  set _parentPath to my mailboxParentPathWithinAccount(_mailbox, _accountName)
                  copy {_accountName, _path, _name, _parentPath} to end of _rows
                end if
              end repeat
            end repeat
          end timeout
        end tell
        return _rows
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
            let internalMailID = row.atIndex(RowIndex.internalMailID)?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawMessageID = row.atIndex(RowIndex.messageID)?.stringValue else { continue }
            let normalizedID = JWZThreader.normalizeIdentifier(rawMessageID)
            let cleanedRawMessageID = MailControl.cleanMessageIDPreservingCase(rawMessageID)
            let canonicalID: String
            if !normalizedID.isEmpty {
                canonicalID = normalizedID
            } else if !cleanedRawMessageID.isEmpty {
                canonicalID = cleanedRawMessageID
            } else {
                canonicalID = UUID().uuidString.lowercased()
            }
            let subject = row.atIndex(RowIndex.subject)?.stringValue ?? "(No Subject)"
            let mailboxID = row.atIndex(RowIndex.mailbox)?.stringValue ?? mailbox
            let accountName = row.atIndex(RowIndex.account)?.stringValue ?? ""
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
                                     internalMailID: (internalMailID?.isEmpty == false) ? internalMailID : nil,
                                     mailboxID: mailboxID,
                                     accountName: accountName,
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

    private func decodeMailboxFolders(from descriptor: NSAppleEventDescriptor) throws -> [MailboxFolder] {
        guard descriptor.descriptorType == typeAEList else {
            throw MailAppleScriptClientError.malformedDescriptor
        }
        guard descriptor.numberOfItems > 0 else { return [] }

        var folders: [MailboxFolder] = []
        folders.reserveCapacity(descriptor.numberOfItems)

        for index in 1...descriptor.numberOfItems {
            guard let row = descriptor.atIndex(index),
                  row.numberOfItems >= MailboxRowIndex.parentPath else {
                continue
            }
            let account = row.atIndex(MailboxRowIndex.account)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let path = row.atIndex(MailboxRowIndex.path)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = row.atIndex(MailboxRowIndex.name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawParentPath = row.atIndex(MailboxRowIndex.parentPath)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parentPath = rawParentPath.isEmpty ? nil : rawParentPath
            guard !account.isEmpty, !path.isEmpty, !name.isEmpty else { continue }

            folders.append(MailboxFolder(account: account,
                                         path: path,
                                         name: name,
                                         parentPath: parentPath))
        }

        return folders
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
