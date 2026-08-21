import Carbon
import Foundation
import OSLog

private enum MailAppleScriptClientError: LocalizedError {
    case malformedDescriptor
    case missingMessageID
    case noMessagesMoved
    case invalidPayloadBatch

    var errorDescription: String? {
        switch self {
        case .malformedDescriptor:
            return NSLocalizedString("mail.applescript.error.malformed_result",
                                     comment: "Mail returned an unexpected AppleScript result")
        case .missingMessageID:
            return NSLocalizedString("mail.applescript.error.missing_move_target",
                                     comment: "A Mail move target was missing")
        case .noMessagesMoved:
            return NSLocalizedString("graph.snip.error.no_messages_moved",
                                     comment: "No messages matched a graph snip move")
        case .invalidPayloadBatch:
            return NSLocalizedString("dayfetch.error.invalid_payload_batch",
                                     comment: "Error when a day fetch payload request is too large")
        }
    }
}

internal enum MailFetchProfile: Equatable, Sendable {
    case refresh
    case full
}

internal actor MailAppleScriptClient: GraphSnipMailMoving {
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

    private enum ManifestRowIndex {
        static let internalMailID = 1
        static let messageID = 2
        static let subject = 3
        static let mailbox = 4
        static let account = 5
        static let date = 6
        static let read = 7
    }

    internal func fetchMessages(since date: Date?,
                                limit: Int = 10,
                                mailbox: String = "inbox",
                                account: String? = nil,
                                snippetLineLimit: Int = 10,
                                profile: MailFetchProfile = .full) async throws -> [EmailMessage] {
        try Task.checkCancellation()
        let sinceDisplay = date?.ISO8601Format() ?? "nil"
        Log.appleScript.info("fetchMessages requested. mailbox=\(mailbox, privacy: .public) account=\(account ?? "", privacy: .public) limit=\(limit, privacy: .public) since=\(sinceDisplay, privacy: .public) profile=\(String(describing: profile), privacy: .public)")
        let script = buildScript(mailbox: mailbox, account: account, limit: limit, since: date, profile: profile)
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

    internal func fetchMessageManifest(in range: DateInterval,
                                       mailbox: String = "inbox",
                                       account: String? = nil) async throws -> [MessageReference] {
        try Task.checkCancellation()
        let script = buildManifestScript(range: range, mailbox: mailbox, account: account)
        Log.appleScript.info("[DAYFETCH][MANIFEST] requested. mailbox=\(mailbox, privacy: .private) account=\(account ?? "all", privacy: .private) rangeStart=\(range.start, privacy: .private) rangeEnd=\(range.end, privacy: .private)")
        let descriptor = try await scriptRunner.run(script, logPrefix: "[DAYFETCH][MANIFEST]")
        try Task.checkCancellation()
        return try decodeManifest(from: descriptor, fallbackMailbox: mailbox)
    }

    internal func resolveDayFetchScopes(mailbox: String = "inbox",
                                        account: String? = nil) async throws -> [DayFetchScope] {
        try Task.checkCancellation()
        let descriptor = try await scriptRunner.run(
            buildDayFetchScopeScript(mailbox: mailbox, account: account),
            logPrefix: "[DAYFETCH][SCOPES]"
        )
        try Task.checkCancellation()
        return try decodeDayFetchScopes(from: descriptor)
    }

    internal func fetchMessages(references: [MessageReference],
                                profile: MailFetchProfile,
                                snippetLineLimit: Int) async throws -> [EmailMessage] {
        guard !references.isEmpty else { return [] }
        guard references.count <= DayFetchCoordinator.maximumRequestBatchSize else {
            throw MailAppleScriptClientError.invalidPayloadBatch
        }
        try Task.checkCancellation()
        let script = buildPayloadScript(references: references, profile: profile)
        Log.appleScript.info("[DAYFETCH][PAYLOAD] requested. count=\(references.count, privacy: .public) profile=\(String(describing: profile), privacy: .public)")
        let descriptor = try await scriptRunner.run(script, logPrefix: "[DAYFETCH][PAYLOAD]")
        try Task.checkCancellation()
        return try decodeMessages(from: descriptor,
                                  mailbox: references.first?.mailbox ?? "inbox",
                                  snippetLineLimit: snippetLineLimit)
    }

    internal func fetchMessages(messageIDs: [String],
                                account: String,
                                snippetLineLimit: Int) async throws -> [EmailMessage] {
        let normalizedIDs = Array(Set(messageIDs.map(JWZThreader.normalizeIdentifier)))
            .filter { !$0.isEmpty }
            .sorted()
        guard !normalizedIDs.isEmpty else { return [] }
        guard normalizedIDs.count <= DayFetchCoordinator.maximumRequestBatchSize else {
            throw MailAppleScriptClientError.invalidPayloadBatch
        }
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return [] }

        try Task.checkCancellation()
        let script = buildMessageIDLookupScript(messageIDs: normalizedIDs,
                                                internalIDs: Array(repeating: "", count: normalizedIDs.count),
                                                account: trimmedAccount)
        Log.appleScript.info("[THREADING][ANCESTOR] requested. count=\(normalizedIDs.count, privacy: .public) account=\(trimmedAccount, privacy: .private)")
        let descriptor = try await scriptRunner.run(script, logPrefix: "[THREADING][ANCESTOR]")
        try Task.checkCancellation()
        return try decodeMessages(from: descriptor,
                                  mailbox: "",
                                  snippetLineLimit: snippetLineLimit)
    }

    internal func fetchMessages(references: [MessageReference],
                                account: String,
                                snippetLineLimit: Int) async throws -> [EmailMessage] {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return [] }
        let scopedReferences = references.filter {
            $0.account.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(trimmedAccount) == .orderedSame
                && !JWZThreader.normalizeIdentifier($0.messageID).isEmpty
        }
        guard !scopedReferences.isEmpty else { return [] }
        guard scopedReferences.count <= DayFetchCoordinator.maximumRequestBatchSize else {
            throw MailAppleScriptClientError.invalidPayloadBatch
        }

        let messageIDs = scopedReferences.map { JWZThreader.normalizeIdentifier($0.messageID) }
        let internalIDs = scopedReferences.map { $0.internalMailID ?? "" }
        try Task.checkCancellation()
        let script = buildMessageIDLookupScript(messageIDs: messageIDs,
                                                internalIDs: internalIDs,
                                                account: trimmedAccount)
        Log.appleScript.info("[CALENDAR][RECOVERY] requested. count=\(scopedReferences.count, privacy: .public) account=\(trimmedAccount, privacy: .private)")
        let descriptor = try await scriptRunner.run(script, logPrefix: "[CALENDAR][RECOVERY]")
        try Task.checkCancellation()
        return try decodeMessages(from: descriptor,
                                  mailbox: "",
                                  snippetLineLimit: snippetLineLimit)
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

    internal func subMailboxes(of parentPath: String) async throws -> [MailboxFolder] {
        let trimmedParent = parentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let folders = try await fetchMailboxHierarchy()
        guard !trimmedParent.isEmpty else { return folders }
        return folders.filter { folder in
            folder.parentPath?.caseInsensitiveCompare(trimmedParent) == .orderedSame ||
            folder.path.caseInsensitiveCompare(trimmedParent) == .orderedSame ||
            folder.path.lowercased().hasPrefix(trimmedParent.lowercased() + "/")
        }
    }

    internal func moveMessages(messageIDs: [String],
                               toMailboxPath mailboxPath: String,
                               account: String? = nil,
                               sourceMailboxPath: String? = nil,
                               sourceAccount: String? = nil) async throws -> GraphMailMoveResult {
        let cleanedIDs = Array(Set(messageIDs.map { MailControl.cleanMessageIDPreservingCase($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted()
        guard !cleanedIDs.isEmpty else { return GraphMailMoveResult(movedMessageIDs: []) }
        let trimmedMailboxPath = mailboxPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMailboxPath.isEmpty else { throw MailAppleScriptClientError.missingMessageID }
        let script = buildMoveMessagesByMessageIDScript(messageIDs: cleanedIDs,
                                                        mailboxPath: trimmedMailboxPath,
                                                        account: account,
                                                        sourceMailboxPath: sourceMailboxPath,
                                                        sourceAccount: sourceAccount)
        Log.appleScript.debug("Generated graph snip move AppleScript for \(cleanedIDs.count, privacy: .public) messages.")
        let descriptor = try await scriptRunner.run(script)
        try Task.checkCancellation()
        let movedIDs = try Self.decodeMovedMessageIDs(from: descriptor)
        let result = GraphMailMoveResult(movedMessageIDs: movedIDs)
        Log.appleScript.info("Graph snip moved \(result.movedMessageIDs.count, privacy: .public) of \(cleanedIDs.count, privacy: .public) requested messages to mailbox=\(trimmedMailboxPath, privacy: .public) account=\(account ?? "", privacy: .public)")
        return result
    }

    internal nonisolated static func decodeMovedMessageIDs(
        from descriptor: NSAppleEventDescriptor
    ) throws -> [String] {
        guard descriptor.descriptorType == typeAEList else {
            throw MailAppleScriptClientError.malformedDescriptor
        }
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { index in
            descriptor.atIndex(index)?.stringValue
        }
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

    private func mailboxResolverScript(mailbox: String,
                                       account: String?,
                                       resolveInitialMailbox: Bool = true) -> String {
        let safeMailboxPath = escapedForAppleScript(mailbox.trimmingCharacters(in: .whitespacesAndNewlines))
        let safeAccount = escapedForAppleScript((account ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let initialResolutionScript = resolveInitialMailbox ? """
        set _mailboxPathToken to "\(safeMailboxPath)"
        set _accountToken to "\(safeAccount)"
        set _mbx to my resolveMailboxByPath(_accountToken, _mailboxPathToken)
        if _mbx is missing value then
          error "Mailbox not found for path: " & _mailboxPathToken & " account: " & _accountToken number -1728
        end if
        """ : ""
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

        on resolveMailboxesByPath(_accountToken, _mailboxPathToken)
          set _resolvedMailboxes to {}
          set _accounts to my matchingAccounts(_accountToken)
          tell application id "com.apple.mail"
            repeat with _acct in _accounts
              set _acctToken to ""
              try
                set _acctToken to (name of _acct as string)
              on error
                try
                  set _acctToken to (id of _acct as string)
                end try
              end try
              if _acctToken is not "" then
                set _resolvedMailbox to my resolveMailboxByPath(_acctToken, _mailboxPathToken)
                if _resolvedMailbox is not missing value then
                  set _resolvedPath to my mailboxPathForMailbox(_resolvedMailbox)
                  ignoring case
                    if _resolvedPath is (my trimText(_mailboxPathToken)) then
                      copy _resolvedMailbox to end of _resolvedMailboxes
                    end if
                  end ignoring
                end if
              end if
            end repeat
          end tell
          return _resolvedMailboxes
        end resolveMailboxesByPath

        \(initialResolutionScript)
        """
    }

    private func exactDateHelpersScript() -> String {
        """
        on dateFromParts(_yearValue, _monthValue, _dayValue, _secondsValue)
          set _dateValue to current date
          set day of _dateValue to 1
          set year of _dateValue to _yearValue
          set month of _dateValue to _monthValue
          set day of _dateValue to _dayValue
          set time of _dateValue to _secondsValue
          return _dateValue
        end dateFromParts
        """
    }

    private func exactDateExpression(_ date: Date) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = components.year ?? 2001
        let day = components.day ?? 1
        let seconds = (components.hour ?? 0) * 3_600
            + (components.minute ?? 0) * 60
            + (components.second ?? 0)
        let monthName: String
        switch components.month ?? 1 {
        case 2: monthName = "February"
        case 3: monthName = "March"
        case 4: monthName = "April"
        case 5: monthName = "May"
        case 6: monthName = "June"
        case 7: monthName = "July"
        case 8: monthName = "August"
        case 9: monthName = "September"
        case 10: monthName = "October"
        case 11: monthName = "November"
        case 12: monthName = "December"
        default: monthName = "January"
        }
        return "my dateFromParts(\(year), \(monthName), \(day), \(seconds))"
    }

    private func buildManifestScript(range: DateInterval,
                                     mailbox: String,
                                     account: String?) -> String {
        """
        \(mailboxResolverScript(mailbox: mailbox, account: account))
        \(exactDateHelpersScript())
        set _startDate to \(exactDateExpression(range.start))
        set _endDate to \(exactDateExpression(range.end))
        set _rows to {}
        set _mailboxes to my resolveMailboxesByPath(_accountToken, _mailboxPathToken)
        if (count of _mailboxes) is 0 then
          error "Mailbox not found for path: " & _mailboxPathToken & " account: " & _accountToken number -1728
        end if
        tell application id "com.apple.mail"
          with timeout of 300 seconds
            repeat with _mailboxRef in _mailboxes
              set _mailboxValue to contents of _mailboxRef
              set _mailboxPath to my mailboxPathForMailbox(_mailboxValue)
              set _accountName to ""
              try
                set _accountName to (name of account of _mailboxValue as string)
              end try
              set _messages to (messages of _mailboxValue whose date received is greater than or equal to _startDate and date received is less than _endDate)
              repeat with _messageRef in _messages
                set _messageValue to contents of _messageRef
                set _internalID to ""
                set _messageID to ""
                set _subject to ""
                try
                  set _internalID to (id of _messageValue as string)
                end try
                try
                  set _messageID to (message id of _messageValue as string)
                end try
                try
                  set _subject to (subject of _messageValue as string)
                end try
                copy {_internalID, _messageID, _subject, _mailboxPath, _accountName, (date received of _messageValue), (read status of _messageValue)} to end of _rows
              end repeat
            end repeat
          end timeout
        end tell
        return _rows
        """
    }

    private func buildDayFetchScopeScript(mailbox: String,
                                          account: String?) -> String {
        """
        \(mailboxResolverScript(mailbox: mailbox, account: account))
        set _rows to {}
        set _mailboxes to my resolveMailboxesByPath(_accountToken, _mailboxPathToken)
        repeat with _mailboxRef in _mailboxes
          set _mailboxValue to contents of _mailboxRef
          set _mailboxPath to my mailboxPathForMailbox(_mailboxValue)
          set _accountName to ""
          try
            tell application id "com.apple.mail" to set _accountName to (name of account of _mailboxValue as string)
          end try
          if _accountName is not "" then
            copy {_mailboxPath, _accountName} to end of _rows
          end if
        end repeat
        return _rows
        """
    }

    private func buildPayloadScript(references: [MessageReference],
                                    profile: MailFetchProfile) -> String {
        let internalIDs = references.map { $0.internalMailID ?? "" }
        let messageIDs = references.map(\.messageID)
        let mailboxes = references.map(\.mailbox)
        let accounts = references.map(\.account)
        let contentFetchScript: String
        switch profile {
        case .refresh:
            contentFetchScript = ""
        case .full:
            contentFetchScript = """
                try
                  set _body to (content of _messageValue as string)
                end try
            """
        }

        return """
        \(mailboxResolverScript(mailbox: references.first?.mailbox ?? "inbox",
                                account: references.first?.account,
                                resolveInitialMailbox: false))
        set _internalIDs to \(appleScriptStringList(internalIDs))
        set _messageIDs to \(appleScriptStringList(messageIDs))
        set _mailboxPaths to \(appleScriptStringList(mailboxes))
        set _accountNames to \(appleScriptStringList(accounts))
        set _rows to {}
        tell application id "com.apple.mail"
          with timeout of 300 seconds
            repeat with _index from 1 to (count of _internalIDs)
              set _wantedInternalID to item _index of _internalIDs as string
              set _wantedMessageID to item _index of _messageIDs as string
              set _wantedMailboxPath to item _index of _mailboxPaths as string
              set _wantedAccountName to item _index of _accountNames as string
              set _sourceMailbox to my resolveMailboxByPath(_wantedAccountName, _wantedMailboxPath)
              set _matches to {}
              if _sourceMailbox is not missing value then
                if _wantedInternalID is not "" then
                  try
                    set _matches to (messages of _sourceMailbox whose id is (_wantedInternalID as integer))
                  end try
                end if
                -- Apple Mail's numeric ID may change while the RFC Message-ID
                -- and mailbox remain valid. Retry in the resolved mailbox
                -- before escalating to the account-wide recovery scan.
                if ((count of _matches) is 0) and (_wantedMessageID is not "") then
                  try
                    set _matches to (messages of _sourceMailbox whose message id is _wantedMessageID)
                  end try
                  if (count of _matches) is 0 then
                    set _alternateMessageID to "<" & _wantedMessageID & ">"
                    try
                      set _matches to (messages of _sourceMailbox whose message id is _alternateMessageID)
                    end try
                  end if
                end if
              end if
              repeat with _messageRef in _matches
                set _messageValue to contents of _messageRef
                set _src to ""
                set _body to ""
                set _actualInternalID to _wantedInternalID
                set _actualMessageID to _wantedMessageID
                set _subject to ""
                set _actualMailboxPath to _wantedMailboxPath
                set _actualAccountName to _wantedAccountName
                try
                  set _actualInternalID to (id of _messageValue as string)
                end try
                try
                  set _actualMessageID to (message id of _messageValue as string)
                end try
                try
                  set _subject to (subject of _messageValue as string)
                end try
                try
                  set _actualMailbox to mailbox of _messageValue
                  set _actualMailboxPath to my mailboxPathForMailbox(_actualMailbox)
                  try
                    set _actualAccountName to (name of account of _actualMailbox as string)
                  end try
                end try
                try
                  set _src to (source of _messageValue as string)
                end try
        \(contentFetchScript)
                copy {_actualInternalID, _actualMessageID, _subject, _actualMailboxPath, _actualAccountName, (date received of _messageValue), (read status of _messageValue), _src, _body} to end of _rows
                exit repeat
              end repeat
            end repeat
          end timeout
        end tell
        return _rows
        """
    }

    private func buildMessageIDLookupScript(messageIDs: [String],
                                            internalIDs: [String],
                                            account: String) -> String {
        let safeAccount = escapedForAppleScript(account)
        let alignedInternalIDs = internalIDs.count == messageIDs.count
            ? internalIDs
            : Array(repeating: "", count: messageIDs.count)
        return """
        \(mailboxPathHelpersScript())
        on allMailboxes(_containerRef)
          set _results to {}
          set _children to {}
          tell application id "com.apple.mail"
            try
              set _children to every mailbox of _containerRef
            on error
              try
                set _children to mailboxes of _containerRef
              end try
            end try
          end tell
          repeat with _childRef in _children
            set _child to contents of _childRef
            copy _child to end of _results
            set _descendants to my allMailboxes(_child)
            repeat with _descendant in _descendants
              copy (contents of _descendant) to end of _results
            end repeat
          end repeat
          return _results
        end allMailboxes

        on matchingAccount(_accountToken)
          tell application id "com.apple.mail"
            repeat with _accountRef in every account
              set _accountValue to contents of _accountRef
              set _matches to false
              ignoring case
                try
                  if (name of _accountValue as string) is _accountToken then set _matches to true
                end try
                if not _matches then
                  try
                    if (id of _accountValue as string) is _accountToken then set _matches to true
                  end try
                end if
              end ignoring
              if _matches then return _accountValue
            end repeat
          end tell
          return missing value
        end matchingAccount

        set _wantedMessageIDs to \(appleScriptStringList(messageIDs))
        set _wantedInternalIDs to \(appleScriptStringList(alignedInternalIDs))
        set _accountToken to "\(safeAccount)"
        set _rows to {}
        set _accountRef to my matchingAccount(_accountToken)
        if _accountRef is missing value then return _rows
        set _mailboxesToScan to my allMailboxes(_accountRef)
        tell application id "com.apple.mail"
          with timeout of 300 seconds
            repeat with _index from 1 to (count of _wantedMessageIDs)
              set _wantedMessageID to item _index of _wantedMessageIDs as string
              set _wantedInternalID to item _index of _wantedInternalIDs as string
              set _alternateMessageID to "<" & _wantedMessageID & ">"
              set _found to false
              repeat with _mailboxRef in _mailboxesToScan
                set _mailboxValue to contents of _mailboxRef
                set _matches to {}
                if _wantedInternalID is not "" then
                  try
                    set _matches to (messages of _mailboxValue whose id is (_wantedInternalID as integer))
                  end try
                end if
                if (count of _matches) is 0 then
                  try
                    set _matches to (messages of _mailboxValue whose message id is _wantedMessageID)
                  end try
                end if
                if (count of _matches) is 0 then
                  try
                    set _matches to (messages of _mailboxValue whose message id is _alternateMessageID)
                  end try
                end if
                repeat with _messageRef in _matches
                  set _messageValue to contents of _messageRef
                  set _src to ""
                  set _body to ""
                  set _internalID to ""
                  set _actualMessageID to _wantedMessageID
                  set _subject to ""
                  set _mailboxPath to my mailboxPathForMailbox(_mailboxValue)
                  try
                    set _internalID to (id of _messageValue as string)
                  end try
                  try
                    set _actualMessageID to (message id of _messageValue as string)
                  end try
                  try
                    set _subject to (subject of _messageValue as string)
                  end try
                  set _actualAccountName to _accountToken
                  try
                    set _actualAccountName to (name of account of _mailboxValue as string)
                  on error
                    set _actualAccountName to _accountToken
                  end try
                  try
                    set _src to (source of _messageValue as string)
                  end try
                  try
                    set _body to (content of _messageValue as string)
                  end try
                  copy {_internalID, _actualMessageID, _subject, _mailboxPath, _actualAccountName, (date received of _messageValue), (read status of _messageValue), _src, _body} to end of _rows
                  set _found to true
                  exit repeat
                end repeat
                if _found then exit repeat
              end repeat
            end repeat
          end timeout
        end tell
        return _rows
        """
    }

    private func buildScript(mailbox: String,
                             account: String?,
                             limit: Int,
                             since: Date?,
                             profile: MailFetchProfile) -> String {
        let windowSeconds: Int
        if let since {
            windowSeconds = max(0, Int(Date().timeIntervalSince(since)))
        } else {
            windowSeconds = 0
        }

        let contentFetchScript: String
        switch profile {
        case .refresh:
            contentFetchScript = ""
        case .full:
            contentFetchScript = """
                try
                  set _body to (content of m as string)
                on error
                  set _body to ""
                end try
            """
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
        \(contentFetchScript)
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

#if DEBUG
    internal func buildPayloadScriptForTesting(references: [MessageReference],
                                               profile: MailFetchProfile = .full) -> String {
        buildPayloadScript(references: references, profile: profile)
    }

    internal func buildMessageIDLookupScriptForTesting(messageIDs: [String], account: String) -> String {
        buildMessageIDLookupScript(messageIDs: messageIDs,
                                   internalIDs: Array(repeating: "", count: messageIDs.count),
                                   account: account)
    }

    internal func buildReferenceLookupScriptForTesting(references: [MessageReference],
                                                       account: String) -> String {
        buildMessageIDLookupScript(messageIDs: references.map { JWZThreader.normalizeIdentifier($0.messageID) },
                                   internalIDs: references.map { $0.internalMailID ?? "" },
                                   account: account)
    }

    internal func buildManifestScriptForTesting(range: DateInterval,
                                                mailbox: String = "inbox",
                                                account: String? = nil) -> String {
        buildManifestScript(range: range, mailbox: mailbox, account: account)
    }

    internal func buildRefreshScriptForTesting(mailbox: String = "inbox",
                                               account: String? = nil,
                                               limit: Int = 10,
                                               since: Date? = nil) -> String {
        buildScript(mailbox: mailbox,
                    account: account,
                    limit: limit,
                    since: since,
                    profile: .refresh)
    }
#endif

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

    private func buildMoveMessagesByMessageIDScript(messageIDs: [String],
                                                    mailboxPath: String,
                                                    account: String?,
                                                    sourceMailboxPath: String?,
                                                    sourceAccount: String?) -> String {
        let escapedIDs = messageIDs.map { "\"\(escapedForAppleScript($0))\"" }.joined(separator: ", ")
        let trimmedSourcePath = sourceMailboxPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mailboxScanSetup: String
        if !trimmedSourcePath.isEmpty {
            let escapedSourcePath = escapedForAppleScript(trimmedSourcePath)
            let escapedSourceAccount = escapedForAppleScript(
                (sourceAccount ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
            mailboxScanSetup = """
            set _sourceMailbox to my resolveMailboxByPath("\(escapedSourceAccount)", "\(escapedSourcePath)")
            if _sourceMailbox is missing value then
              error "Source mailbox not found for path: \(escapedSourcePath) account: \(escapedSourceAccount)" number -1728
            end if
            set _mailboxesToScan to {_sourceMailbox}
            """
        } else {
            mailboxScanSetup = """
            set _mailboxesToScan to {}
            tell application id "com.apple.mail"
              repeat with _account in every account
                set _accountMailboxes to my allMailboxesIn(_account)
                repeat with _mailbox in _accountMailboxes
                  copy _mailbox to end of _mailboxesToScan
                end repeat
              end repeat
            end tell
            """
        }
        return """
        \(mailboxResolverScript(mailbox: mailboxPath, account: account))
        set _destinationMailbox to _mbx
        set _targetMessageIDs to {\(escapedIDs)}
        set _movedMessageIDs to {}

        on containsTargetMessageID(_messageID, _targetMessageIDs)
          if _messageID is "" then return false
          repeat with _targetMessageID in _targetMessageIDs
            ignoring case
              if (_messageID as string) is equal to (_targetMessageID as string) then return true
            end ignoring
          end repeat
          return false
        end containsTargetMessageID

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

        on allMailboxesIn(_containerRef)
          set _results to {}
          set _children to my childMailboxes(_containerRef)
          repeat with _child in _children
            copy _child to end of _results
            set _grandchildren to my allMailboxesIn(_child)
            repeat with _grandchild in _grandchildren
              copy _grandchild to end of _results
            end repeat
          end repeat
          return _results
        end allMailboxesIn

        \(mailboxScanSetup)

        tell application id "com.apple.mail"
          with timeout of 120 seconds
            repeat with _mailbox in _mailboxesToScan
              set _messages to {}
              try
                set _messages to messages of _mailbox
              end try
              repeat with _message in _messages
                set _messageID to ""
                try
                  set _messageID to (message id of _message as string)
                end try
                if my containsTargetMessageID(_messageID, _targetMessageIDs) then
                  try
                    move _message to _destinationMailbox
                    copy _messageID to end of _movedMessageIDs
                  end try
                  if (count of _movedMessageIDs) is greater than or equal to (count of _targetMessageIDs) then exit repeat
                end if
              end repeat
            end repeat
          end timeout
        end tell
        return _movedMessageIDs
        """
    }

    private func canonicalMessageID(rawMessageID: String,
                                    internalMailID: String?,
                                    account: String,
                                    mailbox: String,
                                    date: Date,
                                    subject: String) -> String {
        let normalizedID = JWZThreader.normalizeIdentifier(rawMessageID)
        if !normalizedID.isEmpty {
            return normalizedID
        }
        let cleanedRawMessageID = MailControl.cleanMessageIDPreservingCase(rawMessageID)
        if !cleanedRawMessageID.isEmpty {
            return cleanedRawMessageID
        }
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let internalMailID, !internalMailID.isEmpty {
            return "mail-internal|\(normalizedAccount)|\(normalizedMailbox)|\(internalMailID)"
        }
        let normalizedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "mail-legacy|\(normalizedAccount)|\(normalizedMailbox)|\(date.timeIntervalSinceReferenceDate)|\(normalizedSubject)"
    }

    private func decodeManifest(from descriptor: NSAppleEventDescriptor,
                                fallbackMailbox: String) throws -> [MessageReference] {
        guard descriptor.descriptorType == typeAEList else {
            throw MailAppleScriptClientError.malformedDescriptor
        }
        guard descriptor.numberOfItems > 0 else { return [] }

        var references: [MessageReference] = []
        references.reserveCapacity(descriptor.numberOfItems)
        for index in 1...descriptor.numberOfItems {
            guard let row = descriptor.atIndex(index),
                  row.numberOfItems >= ManifestRowIndex.read,
                  let date = row.atIndex(ManifestRowIndex.date)?.dateValue else {
                continue
            }
            let rawInternalID = row.atIndex(ManifestRowIndex.internalMailID)?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let internalMailID = rawInternalID.isEmpty ? nil : rawInternalID
            let rawMessageID = row.atIndex(ManifestRowIndex.messageID)?.stringValue ?? ""
            let subject = row.atIndex(ManifestRowIndex.subject)?.stringValue ?? "(No Subject)"
            let mailbox = row.atIndex(ManifestRowIndex.mailbox)?.stringValue ?? fallbackMailbox
            let account = row.atIndex(ManifestRowIndex.account)?.stringValue ?? ""
            let messageID = canonicalMessageID(rawMessageID: rawMessageID,
                                               internalMailID: internalMailID,
                                               account: account,
                                               mailbox: mailbox,
                                               date: date,
                                               subject: subject)
            let isRead = row.atIndex(ManifestRowIndex.read)?.booleanValue ?? true
            references.append(MessageReference(internalMailID: internalMailID,
                                               messageID: messageID,
                                               mailbox: mailbox,
                                               account: account,
                                               subject: subject,
                                               date: date,
                                               isUnread: !isRead))
        }
        return references
    }

    private func decodeDayFetchScopes(from descriptor: NSAppleEventDescriptor) throws -> [DayFetchScope] {
        guard descriptor.descriptorType == typeAEList else {
            throw MailAppleScriptClientError.malformedDescriptor
        }
        guard descriptor.numberOfItems > 0 else { return [] }

        var seen = Set<String>()
        var scopes: [DayFetchScope] = []
        for index in 1...descriptor.numberOfItems {
            guard let row = descriptor.atIndex(index), row.numberOfItems >= 2 else { continue }
            let mailbox = row.atIndex(1)?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let account = row.atIndex(2)?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !mailbox.isEmpty, !account.isEmpty else { continue }
            let scope = DayFetchScope(mailbox: mailbox,
                                      account: account,
                                      displayName: "\(account) / \(mailbox)")
            if seen.insert(scope.key).inserted {
                scopes.append(scope)
            }
        }
        return scopes.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
        let collapsedHistoryParser = CollapsedEmailHistoryParser(decoder: decoder)
        guard descriptor.numberOfItems > 0 else {
            Log.appleScript.info("Descriptor contained no items.")
            return []
        }

        for index in 1...descriptor.numberOfItems {
            guard let row = descriptor.atIndex(index), row.numberOfItems >= RowIndex.body else { continue }
            let internalMailID = row.atIndex(RowIndex.internalMailID)?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawMessageID = row.atIndex(RowIndex.messageID)?.stringValue ?? ""
            let subject = row.atIndex(RowIndex.subject)?.stringValue ?? "(No Subject)"
            let mailboxID = row.atIndex(RowIndex.mailbox)?.stringValue ?? mailbox
            let accountName = row.atIndex(RowIndex.account)?.stringValue ?? ""
            let dateValue = row.atIndex(RowIndex.date)?.dateValue ?? Date()
            let canonicalID = canonicalMessageID(rawMessageID: rawMessageID,
                                                 internalMailID: internalMailID,
                                                 account: accountName,
                                                 mailbox: mailboxID,
                                                 date: dateValue,
                                                 subject: subject)
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
            let calendarClassification = CalendarRSVPClassifier.classify(source)
            let decodedSnippet = decoder.bodySnippet(fromBody: bodyText,
                                                     fallbackSource: source,
                                                     maxLines: snippetPreviewLineLimit)
            let snippet = calendarClassification.supplementText ?? decodedSnippet
            let embeddedMessages = collapsedHistoryParser.parse(source: source,
                                                                 body: bodyText,
                                                                 parentMessageID: canonicalID,
                                                                 parentAccountName: accountName,
                                                                 parentSubject: subject)

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
                                     isCalendarRSVP: calendarClassification.shouldSuppress,
                                     calendarMessageKind: calendarClassification.kind,
                                     inReplyTo: inReplyTo,
                                     references: references,
                                     embeddedMessages: embeddedMessages)
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

internal nonisolated struct HeaderDecoder: Sendable {
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
                let continuation = line.trimmingCharacters(in: .whitespaces)
                let separator = (headers[key]?.isEmpty == false && !continuation.isEmpty) ? " " : ""
                let value = (headers[key] ?? "") + separator + continuation
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
        if let mimeBody = readableMIMEContent(from: body) {
            let cleaned = cleanedSnippetLines(from: mimeBody, maxLines: maxLines)
            if !cleaned.isEmpty {
                return truncate(cleaned, maxLength: maxLength)
            }
        }

        let cleanedBody = cleanedSnippetLines(from: body, maxLines: maxLines)
        if !cleanedBody.isEmpty, !containsMIMEFraming(body) {
            return truncate(cleanedBody, maxLength: maxLength)
        }
        return bodySnippetFromSource(source, maxLength: maxLength, maxLines: maxLines)
    }

    private func bodySnippetFromSource(_ source: String, maxLength: Int, maxLines: Int) -> String {
        if let mimeText = readableMIMEContent(from: source) {
            let cleaned = cleanedSnippetLines(from: mimeText, maxLines: maxLines)
            if !cleaned.isEmpty {
                Log.appleScript.debug("MIME parsing: using extracted text/plain for snippet")
                return truncate(cleaned, maxLength: maxLength)
            }
        }
        Log.appleScript.debug("MIME parsing: falling back to naive header/body split")
        let normalizedSource = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = normalizedSource.range(of: "\n\n") else { return "" }
        let body = normalizedSource[range.upperBound...]
        guard !containsMIMEFraming(String(body)) else {
            Log.appleScript.debug("MIME parsing: refusing to expose unparsed MIME framing")
            return ""
        }
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
        var cleaned: [String] = []
        var previousLineWasBlank = true
        for line in lines {
            let value = cleanSnippetLine(String(line))
            if value.isEmpty {
                if !previousLineWasBlank {
                    cleaned.append("")
                }
                previousLineWasBlank = true
            } else {
                cleaned.append(value)
                previousLineWasBlank = false
            }
        }
        while cleaned.last?.isEmpty == true {
            cleaned.removeLast()
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

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func extractBoundary(from contentType: String) -> String? {
        let lower = contentType.lowercased()
        guard let range = lower.range(of: "boundary") else { return nil }
        let afterKey = contentType[range.upperBound...]
        let trimmed = afterKey.drop { $0.isWhitespace || $0 == "=" }
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "\"" {
            let unquoted = trimmed.dropFirst()
            guard let endQuote = unquoted.firstIndex(of: "\"") else {
                return String(unquoted)
            }
            return String(unquoted[..<endQuote])
        }
        let end = trimmed.firstIndex(where: { $0 == ";" || $0.isWhitespace }) ?? trimmed.endIndex
        return String(trimmed[..<end])
    }

    func decodeMIMEBody(_ text: String, transferEncoding: String, contentType: String) -> String {
        let data = decodeTransferEncodingToData(text, encoding: transferEncoding)
        return decodeCharset(data, contentType: contentType)
    }

    private func decodeTransferEncodingToData(_ text: String, encoding: String) -> Data {
        switch encoding.lowercased().trimmingCharacters(in: .whitespaces) {
        case "quoted-printable":
            return decodeQuotedPrintable(text)
        case "base64":
            let cleaned = text.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Data(base64Encoded: cleaned) ?? Data(text.utf8)
        default:
            return Data(text.utf8)
        }
    }

    private func decodeCharset(_ data: Data, contentType: String) -> String {
        let encoding = charsetEncoding(from: contentType)
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) ?? ""
    }

    private func charsetEncoding(from contentType: String) -> String.Encoding {
        let lower = contentType.lowercased()
        guard let range = lower.range(of: "charset=") else { return .utf8 }
        let afterCharset = lower[range.upperBound...]
        let value: String
        if afterCharset.first == "\"" {
            let unquoted = afterCharset.dropFirst()
            let end = unquoted.firstIndex(of: "\"") ?? unquoted.endIndex
            value = String(unquoted[..<end])
        } else {
            let end = afterCharset.firstIndex(where: { $0 == ";" || $0.isWhitespace }) ?? afterCharset.endIndex
            value = String(afterCharset[..<end])
        }
        switch value.trimmingCharacters(in: .whitespaces) {
        case "us-ascii":
            return .ascii
        case "iso-8859-1", "latin1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        default:
            return .utf8
        }
    }

    private func decodeQuotedPrintable(_ text: String) -> Data {
        var result = Data()
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x3D {
                if i + 1 < bytes.count && bytes[i + 1] == 0x0A {
                    i += 2
                    continue
                }
                if i + 2 < bytes.count,
                   let high = hexValue(bytes[i + 1]),
                   let low = hexValue(bytes[i + 2]) {
                    result.append(high << 4 | low)
                    i += 3
                    continue
                }
            }
            result.append(bytes[i])
            i += 1
        }
        return result
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30
        case 0x41...0x46:
            return byte - 0x41 + 10
        case 0x61...0x66:
            return byte - 0x61 + 10
        default:
            return nil
        }
    }

    private static let maxMIMESourceSize = 512 * 1024
    private static let maxMIMEDepth = 10

    private struct MIMETextCandidate {
        let text: String
        let isPlainText: Bool
    }

    func readableMIMEContent(from source: String) -> String? {
        guard !source.isEmpty, source.utf8.count <= Self.maxMIMESourceSize else {
            return nil
        }

        let normalized = normalizedLineEndings(source)
        if let multipartText = extractPlainTextFromMIME(normalized) {
            return multipartText
        }

        if let boundary = openingBoundary(in: normalized),
           let candidate = extractTextFromParts(normalized, boundary: boundary, depth: 0) {
            return candidate.text
        }

        let topHeaders = headers(from: normalized)
        let contentType = topHeaders["content-type"] ?? ""
        let normalizedContentType = contentType.lowercased()
        guard normalizedContentType.contains("text/plain") || normalizedContentType.contains("text/html"),
              !isAttachment(topHeaders),
              let headerEnd = normalized.range(of: "\n\n") else {
            return nil
        }

        let transferEncoding = topHeaders["content-transfer-encoding"] ?? ""
        let encodedBody = String(normalized[headerEnd.upperBound...])
        let decoded = decodeMIMEBody(encodedBody,
                                     transferEncoding: transferEncoding,
                                     contentType: contentType)
        if normalizedContentType.contains("text/html") {
            return stripHTML(decoded)
        }
        return decoded
    }

    func containsMIMEFraming(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let normalized = normalizedLineEndings(text)
        if openingBoundary(in: normalized) != nil {
            return true
        }
        let leadingHeaders = headers(from: normalized)
        if leadingHeaders["mime-version"] != nil || leadingHeaders["content-transfer-encoding"] != nil {
            return true
        }
        guard let contentType = leadingHeaders["content-type"]?.lowercased() else {
            return false
        }
        return contentType.contains("multipart/")
            || contentType.contains("text/plain")
            || contentType.contains("text/html")
            || contentType.contains("message/rfc822")
    }

    func extractPlainTextFromMIME(_ source: String) -> String? {
        guard source.utf8.count <= Self.maxMIMESourceSize else {
            Log.appleScript.debug("MIME parsing skipped: source exceeds 512 KB")
            return nil
        }
        let normalized = normalizedLineEndings(source)
        let topHeaders = headers(from: normalized)
        guard let contentType = topHeaders["content-type"],
              contentType.lowercased().contains("multipart"),
              let boundary = extractBoundary(from: contentType) else {
            return nil
        }
        guard let headerEnd = normalized.range(of: "\n\n") else { return nil }
        let body = String(normalized[headerEnd.upperBound...])
        Log.appleScript.debug("MIME parsing: attempting multipart extraction with boundary")
        let result = extractTextFromParts(body, boundary: boundary, depth: 0)?.text
        if result == nil {
            Log.appleScript.debug("MIME parsing: no text/plain part found")
        }
        return result
    }

    func embeddedRFC822Sources(from source: String) -> [String] {
        guard !source.isEmpty, source.utf8.count <= Self.maxMIMESourceSize else {
            return []
        }
        var results: [String] = []
        collectEmbeddedRFC822Sources(in: normalizedLineEndings(source),
                                     depth: 0,
                                     results: &results)
        return results
    }

    private func collectEmbeddedRFC822Sources(in source: String,
                                               depth: Int,
                                               results: inout [String]) {
        guard depth < Self.maxMIMEDepth,
              let headerEnd = source.range(of: "\n\n") else {
            return
        }
        let partHeaders = headers(from: source)
        guard !isAttachment(partHeaders) else { return }
        let contentType = partHeaders["content-type"] ?? ""
        let normalizedContentType = contentType.lowercased()
        let body = String(source[headerEnd.upperBound...])

        if normalizedContentType.contains("multipart"),
           let boundary = extractBoundary(from: contentType) {
            for part in splitMIMEParts(body, boundary: boundary) {
                collectEmbeddedRFC822Sources(in: part,
                                             depth: depth + 1,
                                             results: &results)
            }
            return
        }

        guard normalizedContentType.contains("message/rfc822") else { return }
        let decoded = decodeMIMEBody(body,
                                     transferEncoding: partHeaders["content-transfer-encoding"] ?? "",
                                     contentType: contentType)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty, decoded.range(of: "\n\n") != nil else { return }
        results.append(decoded)
        collectEmbeddedRFC822Sources(in: decoded,
                                     depth: depth + 1,
                                     results: &results)
    }

    private func extractTextFromParts(_ body: String,
                                      boundary: String,
                                      depth: Int) -> MIMETextCandidate? {
        guard depth < Self.maxMIMEDepth else { return nil }
        let parts = splitMIMEParts(body, boundary: boundary)
        var htmlFallback: MIMETextCandidate?

        for part in parts {
            guard let headerEnd = part.range(of: "\n\n") else { continue }
            let partHeaderStr = String(part[..<headerEnd.lowerBound])
            let partBody = String(part[headerEnd.upperBound...])
            let partHeaders = headers(from: partHeaderStr + "\n\n")
            guard !isAttachment(partHeaders) else { continue }
            let rawPartContentType = partHeaders["content-type"] ?? ""
            let partContentType = rawPartContentType.lowercased()
            let transferEncoding = partHeaders["content-transfer-encoding"] ?? ""

            if partContentType.contains("multipart"),
               let nestedBoundary = extractBoundary(from: rawPartContentType) {
                if let nested = extractTextFromParts(partBody, boundary: nestedBoundary, depth: depth + 1) {
                    if nested.isPlainText {
                        return nested
                    }
                    if htmlFallback == nil {
                        htmlFallback = nested
                    }
                }
            } else if partContentType.contains("text/plain") || (partContentType.isEmpty && depth > 0) {
                let decoded = decodeMIMEBody(partBody, transferEncoding: transferEncoding, contentType: rawPartContentType)
                if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return MIMETextCandidate(text: decoded, isPlainText: true)
                }
            } else if partContentType.contains("text/html") && htmlFallback == nil {
                let decoded = decodeMIMEBody(partBody, transferEncoding: transferEncoding, contentType: rawPartContentType)
                let stripped = stripHTML(decoded)
                if !stripped.isEmpty {
                    htmlFallback = MIMETextCandidate(text: stripped, isPlainText: false)
                }
            }
        }

        return htmlFallback
    }

    private func splitMIMEParts(_ body: String, boundary: String) -> [String] {
        let normalized = normalizedLineEndings(body)
        let delimiter = "--" + boundary
        let closingDelimiter = delimiter + "--"
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var parts: [String] = []
        var currentLines: [Substring] = []
        var isCollecting = false
        var didClose = false

        for line in lines {
            let marker = line.trimmingCharacters(in: .whitespaces)
            if marker == delimiter {
                if isCollecting {
                    parts.append(currentLines.map(String.init).joined(separator: "\n"))
                }
                currentLines.removeAll(keepingCapacity: true)
                isCollecting = true
                continue
            }
            if marker == closingDelimiter {
                if isCollecting {
                    parts.append(currentLines.map(String.init).joined(separator: "\n"))
                }
                didClose = true
                break
            }
            if isCollecting {
                currentLines.append(line)
            }
        }

        if isCollecting, !didClose, !currentLines.isEmpty {
            parts.append(currentLines.map(String.init).joined(separator: "\n"))
        }
        return parts
    }

    private func openingBoundary(in source: String) -> String? {
        let firstContentLine = normalizedLineEndings(source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
        guard var marker = firstContentLine,
              marker.hasPrefix("--"),
              marker.count > 2 else {
            return nil
        }
        marker.removeFirst(2)
        if marker.hasSuffix("--") {
            marker.removeLast(2)
        }
        guard !marker.isEmpty, !marker.contains(where: \.isWhitespace) else {
            return nil
        }
        return marker
    }

    private func isAttachment(_ headers: [String: String]) -> Bool {
        headers["content-disposition"]?
            .lowercased()
            .contains("attachment") == true
    }

    private func normalizedLineEndings(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func stripHTML(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(
            of: "(?is)<style[^>]*>.*?</style>",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?is)<script[^>]*>.*?</script>",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "(?i)<br\\s*/?>",
                                             with: "\n",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)</(?:p|div|h[1-6]|blockquote|tr)\\s*>",
                                             with: "\n\n",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)<li(?:\\s[^>]*)?>",
                                             with: "• ",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)</li\\s*>",
                                             with: "\n",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)</?(?:ul|ol)(?:\\s[^>]*)?>",
                                             with: "\n",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "[\\t ]+",
                                             with: " ",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: "[\\t ]+([.,!?;:])",
                                             with: "$1",
                                             options: .regularExpression)
        result = result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&mdash;", with: "—")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

internal nonisolated struct CollapsedEmailHistoryParser: Sendable {
    private struct Draft: Sendable {
        let originalMessageID: String?
        let subject: String
        let from: String
        let to: String
        let date: Date?
        let snippet: String
        let identityContent: String
    }

    private enum HeaderKey: Hashable, Sendable {
        case from
        case date
        case to
        case cc
        case subject
        case messageID
    }

    private enum BlockKind: Sendable {
        case headers
        case quotedReply(dateText: String, sender: String)
    }

    private struct BlockStart: Sendable {
        let lineIndex: Int
        let kind: BlockKind
    }

    private static let maximumInputBytes = 1024 * 1024
    private static let maximumMIMEScanBytes = 512 * 1024
    private static let maximumEmbeddedMessages = 64
    private static let maximumSnippetCharacters = 1_500

    private let decoder: HeaderDecoder

    internal init(decoder: HeaderDecoder = HeaderDecoder()) {
        self.decoder = decoder
    }

    internal func parse(source: String,
                        body: String,
                        parentMessageID: String,
                        parentAccountName: String = "",
                        parentSubject: String) -> [EmbeddedEmailMessage] {
        let boundedSource = boundedMIMESource(source)
        var drafts = decoder.embeddedRFC822Sources(from: boundedSource).compactMap(draft(fromRFC822Source:))

        if let text = bestTextCandidate(source: boundedSource, body: body) {
            drafts.append(contentsOf: draftsFromCollapsedText(text,
                                                              parentSubject: parentSubject))
        }

        var seenOriginalMessageIDs = Set<String>()
        var seenFingerprints = Set<String>()
        var results: [EmbeddedEmailMessage] = []
        results.reserveCapacity(min(drafts.count, Self.maximumEmbeddedMessages))

        for draft in drafts {
            guard results.count < Self.maximumEmbeddedMessages else { break }
            let normalizedOriginalID = draft.originalMessageID.map(JWZThreader.normalizeIdentifier)
                .flatMap { $0.isEmpty ? nil : $0 }
            if let normalizedOriginalID,
               !seenOriginalMessageIDs.insert(normalizedOriginalID).inserted {
                continue
            }

            let fingerprint = contentFingerprint(for: draft)
            guard seenFingerprints.insert(fingerprint).inserted else { continue }
            let identity = normalizedOriginalID.map { "message|\($0)" } ?? "content|\(fingerprint)"
            let parentScope = stableHash([
                parentAccountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                JWZThreader.normalizeIdentifier(parentMessageID)
            ].joined(separator: "\n"))
            let logicalID = "embedded-history|\(parentScope)|\(stableHash(identity))"
            results.append(EmbeddedEmailMessage(id: logicalID,
                                                originalMessageID: normalizedOriginalID,
                                                subject: draft.subject,
                                                from: draft.from,
                                                to: draft.to,
                                                date: draft.date,
                                                snippet: draft.snippet,
                                                sourceOrder: results.count))
        }
        return results
    }

    /// Large messages are commonly large because an attachment follows the
    /// human-readable MIME part. Keep the parser within the decoder's existing
    /// safety budget while allowing that leading text part to be inspected.
    private func boundedMIMESource(_ source: String) -> String {
        guard source.utf8.count > Self.maximumMIMEScanBytes else { return source }
        return String(decoding: source.utf8.prefix(Self.maximumMIMEScanBytes), as: UTF8.self)
    }

    private func bestTextCandidate(source: String, body: String) -> String? {
        var candidates: [String] = []
        if let decodedBody = decoder.readableMIMEContent(from: body) {
            candidates.append(decodedBody)
        }
        if !body.isEmpty,
           body.utf8.count <= Self.maximumInputBytes,
           !decoder.containsMIMEFraming(body) {
            candidates.append(body)
        }
        if let decodedSource = decoder.readableMIMEContent(from: source) {
            candidates.append(decodedSource)
        }

        return candidates
            .filter { !$0.isEmpty && $0.utf8.count <= Self.maximumInputBytes }
            .max { lhs, rhs in
                let lhsScore = collapsedBlockStarts(in: normalizedLines(lhs)).count
                let rhsScore = collapsedBlockStarts(in: normalizedLines(rhs)).count
                if lhsScore == rhsScore { return lhs.count < rhs.count }
                return lhsScore < rhsScore
            }
            .flatMap { collapsedBlockStarts(in: normalizedLines($0)).isEmpty ? nil : $0 }
    }

    private func draft(fromRFC822Source source: String) -> Draft? {
        let headers = decoder.headers(from: source)
        let from = cleanedHeaderValue(headers["from"] ?? "")
        let subject = cleanedHeaderValue(headers["subject"] ?? "")
        guard !from.isEmpty, !subject.isEmpty else { return nil }
        let body = decoder.readableMIMEContent(from: source) ?? ""
        let snippet = cleanedSnippet(body)
        return Draft(originalMessageID: headers["message-id"],
                     subject: subject,
                     from: from,
                     to: cleanedHeaderValue(headers["to"] ?? ""),
                     date: parseDate(headers["date"] ?? ""),
                     snippet: snippet,
                     identityContent: body)
    }

    private func draftsFromCollapsedText(_ text: String,
                                         parentSubject: String) -> [Draft] {
        let lines = normalizedLines(text)
        let starts = collapsedBlockStarts(in: lines)
        guard !starts.isEmpty else { return [] }

        return starts.enumerated().compactMap { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1].lineIndex : lines.count
            switch start.kind {
            case .headers:
                return headerDraft(lines: lines,
                                   start: start.lineIndex,
                                   end: end,
                                   fallbackSubject: parentSubject)
            case let .quotedReply(dateText, sender):
                let bodyStart = min(start.lineIndex + 1, end)
                let body = lines[bodyStart..<end]
                    .map(removingQuotePrefix)
                    .joined(separator: "\n")
                let snippet = cleanedSnippet(body)
                guard !sender.isEmpty, !snippet.isEmpty else { return nil }
                return Draft(originalMessageID: nil,
                             subject: fallbackSubject(from: parentSubject),
                             from: cleanedHeaderValue(sender),
                             to: "",
                             date: parseDate(dateText),
                             snippet: snippet,
                             identityContent: body)
            }
        }
    }

    private func collapsedBlockStarts(in lines: [String]) -> [BlockStart] {
        var starts: [BlockStart] = []
        for index in lines.indices {
            if let (key, _) = parsedHeaderLine(lines[index]),
               key == .from,
               isStrongHeaderBlock(lines: lines, start: index) {
                starts.append(BlockStart(lineIndex: index, kind: .headers))
                continue
            }
            if let marker = quotedReplyMarker(from: lines[index]),
               nextNonemptyLineIsQuoted(lines: lines, after: index) {
                starts.append(BlockStart(lineIndex: index,
                                         kind: .quotedReply(dateText: marker.dateText,
                                                            sender: marker.sender)))
            }
        }
        return starts
    }

    private func isStrongHeaderBlock(lines: [String], start: Int) -> Bool {
        let upperBound = min(lines.count, start + 18)
        var keys = Set<HeaderKey>()
        var currentKey: HeaderKey?
        for index in start..<upperBound {
            let line = lines[index]
            let cleaned = normalizedVisibleLine(line)
            if cleaned.isEmpty || (index > start && isForwardingSeparator(cleaned)) {
                break
            }
            if let (key, value) = parsedHeaderLine(line), !value.isEmpty {
                keys.insert(key)
                currentKey = key
                if keys.contains(.from), keys.contains(.date), keys.contains(.subject) {
                    return true
                }
                continue
            }
            guard isRecipientHeaderContinuation(line, for: currentKey) else { break }
        }
        return false
    }

    private func headerDraft(lines: [String],
                             start: Int,
                             end: Int,
                             fallbackSubject parentSubject: String) -> Draft? {
        var values: [HeaderKey: String] = [:]
        var currentKey: HeaderKey?
        var bodyStart = end

        for index in start..<end {
            let line = lines[index]
            if let (key, value) = parsedHeaderLine(line) {
                values[key] = [values[key], value]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                currentKey = key
                continue
            }

            let cleaned = normalizedVisibleLine(line)
            if cleaned.isEmpty {
                if values[.from] != nil,
                   values[.date] != nil,
                   values[.subject] != nil {
                    bodyStart = min(index + 1, end)
                    break
                }
                return nil
            }

            if let currentKey,
               isRecipientHeaderContinuation(line, for: currentKey),
               values[.subject] == nil {
                values[currentKey] = [values[currentKey], cleaned]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                continue
            }
            bodyStart = index
            break
        }

        let from = cleanedHeaderValue(values[.from] ?? "")
        let dateText = cleanedHeaderValue(values[.date] ?? "")
        let parsedSubject = cleanedHeaderValue(values[.subject] ?? "")
        guard !from.isEmpty, !dateText.isEmpty, !parsedSubject.isEmpty else { return nil }
        let recipients = [values[.to], values[.cc]]
            .compactMap { $0 }
            .map(cleanedHeaderValue)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let body = bodyStart < end
            ? lines[bodyStart..<end].map(removingQuotePrefix).joined(separator: "\n")
            : ""
        let snippet = cleanedSnippet(body)
        let originalMessageID = cleanedHeaderValue(values[.messageID] ?? "")
        return Draft(originalMessageID: originalMessageID.isEmpty ? nil : originalMessageID,
                     subject: parsedSubject.isEmpty ? fallbackSubject(from: parentSubject) : parsedSubject,
                     from: from,
                     to: recipients,
                     date: parseDate(dateText),
                     snippet: snippet,
                     identityContent: body)
    }

    private func isRecipientHeaderContinuation(_ line: String,
                                               for key: HeaderKey?) -> Bool {
        guard key == .to || key == .cc else { return false }
        let value = normalizedVisibleLine(line)
        return value.contains("@") || value.contains("mailto:") || value.contains("<")
    }

    private func parsedHeaderLine(_ line: String) -> (HeaderKey, String)? {
        let normalized = normalizedVisibleLine(line)
        guard let separator = normalized.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return nil
        }
        let rawKey = normalized[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let value = normalized[normalized.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key: HeaderKey
        switch rawKey {
        case "from", "寄件者", "寄件人", "发件人": key = .from
        case "date", "sent", "寄件日期", "发送时间", "寄件時間": key = .date
        case "to", "收件者", "收件人": key = .to
        case "cc", "副本", "抄送": key = .cc
        case "subject", "主旨", "主题": key = .subject
        case "message-id", "message id": key = .messageID
        default: return nil
        }
        return (key, String(value))
    }

    private func normalizedVisibleLine(_ line: String) -> String {
        removingQuotePrefix(line)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removingQuotePrefix(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespaces)
        while value.hasPrefix(">") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private func nextNonemptyLineIsQuoted(lines: [String], after index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        for line in lines[(index + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            return trimmed.hasPrefix(">")
        }
        return false
    }

    private func quotedReplyMarker(from line: String) -> (dateText: String, sender: String)? {
        let normalized = normalizedVisibleLine(line)
        let lowered = normalized.lowercased()
        guard lowered.hasPrefix("on "), lowered.hasSuffix(" wrote:") else { return nil }
        let suffixStart = normalized.index(normalized.endIndex, offsetBy: -" wrote:".count)
        let markerBody = String(normalized[normalized.index(normalized.startIndex, offsetBy: 3)..<suffixStart])
        guard let comma = markerBody.lastIndex(of: ",") else { return nil }
        let dateText = markerBody[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = markerBody[markerBody.index(after: comma)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dateText.isEmpty, !sender.isEmpty else { return nil }
        return (String(dateText), String(sender))
    }

    private func fallbackSubject(from parentSubject: String) -> String {
        let stripped = parentSubject.replacingOccurrences(
            of: "(?i)^(?:(?:re|fw|fwd|aw|sv|wg):\\s*)+",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? "Quoted reply" : stripped
    }

    private func cleanedHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanedSnippet(_ value: String) -> String {
        let lines = normalizedLines(value)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var start = 0
        var end = lines.count
        while start < end,
              lines[start].isEmpty || isForwardingSeparator(lines[start]) {
            start += 1
        }
        while end > start,
              lines[end - 1].isEmpty || isForwardingSeparator(lines[end - 1]) {
            end -= 1
        }
        guard start < end else { return "" }
        let joined = lines[start..<end].joined(separator: "\n")
        return String(joined.prefix(Self.maximumSnippetCharacters))
    }

    private func isForwardingSeparator(_ line: String) -> Bool {
        let lowered = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered == "begin forwarded message:"
            || (lowered.hasPrefix("--")
                && (lowered.contains("original message") || lowered.contains("forwarded message")))
    }

    private func normalizedLines(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private func parseDate(_ value: String) -> Date? {
        let normalized = cleanedHeaderValue(value)
            .replacingOccurrences(of: " at ", with: " ", options: .caseInsensitive)
        guard !normalized.isEmpty else { return nil }
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "EEEE, d MMMM yyyy h:mm a",
            "EEEE, d MMMM yyyy HH:mm",
            "EEEE, d MMMM, yyyy HH:mm",
            "EEEE, MMMM d, yyyy h:mm a",
            "EEEE, MMMM d, yyyy HH:mm",
            "EEE, MMM d, yyyy h:mm a",
            "MMM d, yyyy h:mm a",
            "d MMM yyyy h:mm a",
            "d MMM yyyy HH:mm"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return date
            }
        }
        return ISO8601DateFormatter().date(from: normalized)
    }

    private func contentFingerprint(for draft: Draft) -> String {
        stableHash([
            draft.subject,
            draft.from,
            draft.to,
            draft.date.map { String($0.timeIntervalSince1970) } ?? "",
            draft.identityContent
        ]
        .map { cleanedHeaderValue($0).lowercased() }
        .joined(separator: "\n"))
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

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
