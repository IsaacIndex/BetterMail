//
//  MailControl.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import Foundation
import OSLog

internal enum MailControlError: LocalizedError {
    case filteredFallbackFailed
    case invalidMailboxName
    case noMessagesMoved

    var errorDescription: String? {
        switch self {
        case .filteredFallbackFailed:
            return "Failed to search Mail for the message."
        case .invalidMailboxName:
            return "Mailbox name cannot be empty."
        case .noMessagesMoved:
            return "No selected messages could be moved."
        }
    }
}

internal struct MailControl {
    internal struct InternalIDMoveTarget: Hashable {
        internal let internalID: String
        internal let sourceAccount: String
        internal let sourceMailboxPath: String
    }

    internal struct MailboxMoveResult: Equatable {
        internal let requestedCount: Int
        internal let matchedCount: Int
        internal let movedCount: Int
        internal let errorCount: Int
        internal let firstErrorNumber: Int?
        internal let firstErrorMessage: String?
    }

    internal struct OpenMessageMetadata: Hashable {
        internal let subject: String
        internal let sender: String
        internal let date: Date
        internal let mailbox: String
        internal let account: String
    }

    internal enum InternalMailIDResolution: Equatable {
        case resolved(String)
        case ambiguous
        case notFound
    }

    internal enum FilteredFallbackOutcome: Equatable {
        case opened
        case notFound
    }

    private static let scriptRunner = NSAppleScriptRunner()

    /// Escape arbitrary user text so embedding it inside AppleScript stays well-formed.
    private static func escapedForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated private static func runScript(_ script: String) async throws -> NSAppleEventDescriptor {
        try await scriptRunner.run(script)
    }

    nonisolated internal static func appleScriptErrorCode(from error: Error) -> Int? {
        guard let scriptError = error as? NSAppleScriptRunner.ScriptError,
              case let .executionFailed(details) = scriptError else {
            return nil
        }
        return details[NSAppleScript.errorNumber] as? Int
    }

    private static func mailboxPathResolverHandlersScript() -> String {
        """
        on splitMailboxPath(_pathText)
          if _pathText is "" then return {}
          set _originalTIDs to AppleScript's text item delimiters
          set AppleScript's text item delimiters to "/"
          set _parts to text items of _pathText
          set AppleScript's text item delimiters to _originalTIDs
          set _trimmedParts to {}
          repeat with _part in _parts
            set _value to contents of _part as string
            if _value is not "" then
              copy _value to end of _trimmedParts
            end if
          end repeat
          return _trimmedParts
        end splitMailboxPath

        on matchingAccounts(_accountToken)
          set _results to {}
          tell application id "com.apple.mail"
            set _allAccounts to every account
            repeat with _acct in _allAccounts
              set _acctValue to contents of _acct
              if _accountToken is "" then
                copy _acctValue to end of _results
              else
                set _matched to false
                ignoring case
                  try
                    if (name of _acctValue as string) is _accountToken then
                      set _matched to true
                    end if
                  end try
                end ignoring
                if not _matched then
                  try
                    if (id of _acctValue as string) is _accountToken then
                      set _matched to true
                    end if
                  end try
                end if
                if _matched then
                  copy _acctValue to end of _results
                end if
              end if
            end repeat
          end tell
          return _results
        end matchingAccounts

        on resolveMailboxByPath(_accountName, _mailboxPath)
          set _accounts to my matchingAccounts(_accountName)
          if (count of _accounts) is 0 then return missing value
          tell application id "com.apple.mail"
            set _parts to my splitMailboxPath(_mailboxPath)
            if (count of _parts) is 0 then return missing value
            repeat with _accountRef in _accounts
              set _accountValue to contents of _accountRef
              try
                set _candidates to every mailbox of _accountValue
              on error
                set _candidates to {}
              end try
              set _resolvedMailbox to missing value
              repeat with _part in _parts
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
            return missing value
          end tell
        end resolveMailboxByPath
        """
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

    nonisolated internal static func openMessageViaFilteredFallback(_ metadata: OpenMessageMetadata) async throws -> FilteredFallbackOutcome {
        let subject = metadata.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderToken = heuristicSenderToken(from: metadata.sender)
        let mailbox = metadata.mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = metadata.account.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: metadata.date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0

        let script = filteredFallbackOpenScript(subject: subject,
                                                sender: senderToken,
                                                mailbox: mailbox,
                                                account: account,
                                                year: year,
                                                month: month,
                                                day: day)
        let result = try await runScript(script)
        if let outcome = filteredFallbackOutcome(from: result) {
            return outcome
        }
        throw MailControlError.filteredFallbackFailed
    }

    nonisolated internal static func filteredFallbackOutcome(from result: NSAppleEventDescriptor) -> FilteredFallbackOutcome? {
        switch result.descriptorType {
        case typeBoolean, typeTrue:
            return result.booleanValue ? .opened : .notFound
        case typeFalse:
            return .notFound
        default:
            return nil
        }
    }

    nonisolated internal static func cleanMessageIDPreservingCase(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    nonisolated internal static func moveSelection(to mailboxPath: String, in account: String) async throws {
        let destReference = mailboxReference(path: mailboxPath, account: account)
        let script = """
        tell application "Mail"
          set destMailbox to \(destReference)
          repeat with m in selection
            move m to destMailbox
          end repeat
        end tell
        """
        _ = try await runScript(script)
    }

    nonisolated internal static func moveMessages(messageIDs: [String],
                                                  to mailboxPath: String,
                                                  in account: String) async throws -> MailboxMoveResult {
        let cleanedIDs = Array(
            Set(
                messageIDs
                    .map(cleanMessageIDPreservingCase)
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        guard !cleanedIDs.isEmpty else {
            return MailboxMoveResult(requestedCount: 0,
                                     matchedCount: 0,
                                     movedCount: 0,
                                     errorCount: 0,
                                     firstErrorNumber: nil,
                                     firstErrorMessage: nil)
        }
        let script = buildMoveMessagesScript(messageIDs: cleanedIDs,
                                             mailboxPath: mailboxPath,
                                             account: account)
        Log.appleScript.debug("Executing mailbox move script (Message-ID) for account=\(account, privacy: .public) destination=\(mailboxPath, privacy: .public) ids=\(cleanedIDs.count, privacy: .public) scriptLength=\(script.count, privacy: .public)")
        let result = try await runScript(script)
        let parsed = MailboxMoveResult(requestedCount: cleanedIDs.count,
                                       matchedCount: result.descriptorType == typeAEList
                                           ? Int(result.atIndex(1)?.int32Value ?? 0)
                                           : 0,
                                       movedCount: result.descriptorType == typeAEList
                                           ? Int(result.atIndex(2)?.int32Value ?? 0)
                                           : 0,
                                       errorCount: result.descriptorType == typeAEList
                                           ? Int(result.atIndex(3)?.int32Value ?? 0)
                                           : 0,
                                       firstErrorNumber: nil,
                                       firstErrorMessage: nil)
        if parsed.movedCount <= 0 {
            throw MailControlError.noMessagesMoved
        }
        return parsed
    }

    nonisolated internal static func moveMessagesByInternalID(internalIDs: [String],
                                                              to mailboxPath: String,
                                                              in account: String) async throws -> MailboxMoveResult {
        let dedupedTargets = Array(
            Set(
                internalIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map {
                        InternalIDMoveTarget(internalID: $0,
                                             sourceAccount: "",
                                             sourceMailboxPath: "")
                    }
            )
        ).sorted { lhs, rhs in
            lhs.internalID < rhs.internalID
        }
        return try await moveMessagesByInternalID(targets: dedupedTargets, to: mailboxPath, in: account)
    }

    nonisolated internal static func moveMessagesByInternalID(targets: [InternalIDMoveTarget],
                                                              to mailboxPath: String,
                                                              in account: String) async throws -> MailboxMoveResult {
        let dedupedTargets = Array(
            Dictionary(grouping: targets) { $0.internalID.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap { key, groupedTargets -> InternalIDMoveTarget? in
                    let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedKey.isEmpty else { return nil }
                    if let preferred = groupedTargets.first(where: { !$0.sourceMailboxPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        return InternalIDMoveTarget(internalID: trimmedKey,
                                                    sourceAccount: preferred.sourceAccount.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    sourceMailboxPath: preferred.sourceMailboxPath.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    if let first = groupedTargets.first {
                        return InternalIDMoveTarget(internalID: trimmedKey,
                                                    sourceAccount: first.sourceAccount.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    sourceMailboxPath: first.sourceMailboxPath.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    return nil
                }
        ).sorted { lhs, rhs in
            lhs.internalID < rhs.internalID
        }

        guard !dedupedTargets.isEmpty else {
            return MailboxMoveResult(requestedCount: 0,
                                     matchedCount: 0,
                                     movedCount: 0,
                                     errorCount: 0,
                                     firstErrorNumber: nil,
                                     firstErrorMessage: nil)
        }
        let script = buildMoveMessagesByInternalIDScript(targets: dedupedTargets,
                                                         mailboxPath: mailboxPath,
                                                         account: account)
        Log.appleScript.debug("Executing mailbox move script (internal ID) for account=\(account, privacy: .public) destination=\(mailboxPath, privacy: .public) ids=\(dedupedTargets.count, privacy: .public) scriptLength=\(script.count, privacy: .public)")
        let result = try await runScript(script)
        guard result.descriptorType == typeAEList else {
            return MailboxMoveResult(requestedCount: dedupedTargets.count,
                                     matchedCount: 0,
                                     movedCount: 0,
                                     errorCount: 0,
                                     firstErrorNumber: nil,
                                     firstErrorMessage: nil)
        }
        let firstErrorNumberRaw = Int(result.atIndex(4)?.int32Value ?? 0)
        let firstErrorMessageRaw = result.atIndex(5)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parsed = MailboxMoveResult(requestedCount: dedupedTargets.count,
                                       matchedCount: Int(result.atIndex(1)?.int32Value ?? 0),
                                       movedCount: Int(result.atIndex(2)?.int32Value ?? 0),
                                       errorCount: Int(result.atIndex(3)?.int32Value ?? 0),
                                       firstErrorNumber: firstErrorNumberRaw == 0 ? nil : firstErrorNumberRaw,
                                       firstErrorMessage: firstErrorMessageRaw.isEmpty ? nil : firstErrorMessageRaw)
        Log.appleScript.debug("Mailbox move result account=\(account, privacy: .public) destination=\(mailboxPath, privacy: .public) requested=\(parsed.requestedCount, privacy: .public) matched=\(parsed.matchedCount, privacy: .public) moved=\(parsed.movedCount, privacy: .public) errors=\(parsed.errorCount, privacy: .public) firstErrorNumber=\(parsed.firstErrorNumber ?? 0, privacy: .public) firstErrorMessage=\(parsed.firstErrorMessage ?? "", privacy: .public)")
        return parsed
    }

    nonisolated internal static func resolveInternalMailID(mailboxPath: String,
                                                           account: String,
                                                           subject: String,
                                                           sender: String,
                                                           receivedAt: Date,
                                                           toleranceSeconds: Int = 120,
                                                           allowAccountWideFallback: Bool = true) async throws -> InternalMailIDResolution {
        let trimmedMailboxPath = mailboxPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderToken = heuristicSenderToken(from: sender)
        guard !trimmedAccount.isEmpty else {
            return .notFound
        }
        guard !trimmedSubject.isEmpty || !senderToken.isEmpty else {
            return .notFound
        }

        let script = buildResolveInternalMailIDScript(mailboxPath: trimmedMailboxPath,
                                                      account: trimmedAccount,
                                                      subject: trimmedSubject,
                                                      senderToken: senderToken,
                                                      receivedAt: receivedAt,
                                                      toleranceSeconds: toleranceSeconds,
                                                      allowAccountWideFallback: allowAccountWideFallback)
        Log.appleScript.debug("Executing internal-ID resolver script for account=\(trimmedAccount, privacy: .public) mailboxPath=\(trimmedMailboxPath, privacy: .public) scriptLength=\(script.count, privacy: .public)")
        let result = try await runScript(script)
        guard result.descriptorType == typeAEList else { return .notFound }
        let matchCount = Int(result.atIndex(1)?.int32Value ?? 0)
        let resolvedID = result.atIndex(2)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usedAccountWideFallback = result.atIndex(3)?.booleanValue ?? false
        let fallbackMailboxCount = Int(result.atIndex(4)?.int32Value ?? 0)
        let fallbackMessageCount = Int(result.atIndex(5)?.int32Value ?? 0)
        Log.appleScript.debug("Internal-ID resolver result account=\(trimmedAccount, privacy: .public) mailboxPath=\(trimmedMailboxPath, privacy: .public) matchCount=\(matchCount, privacy: .public) resolvedID=\(resolvedID, privacy: .public) usedAccountWideFallback=\(usedAccountWideFallback, privacy: .public) fallbackMailboxCount=\(fallbackMailboxCount, privacy: .public) fallbackMessageCount=\(fallbackMessageCount, privacy: .public)")
        if matchCount == 1, !resolvedID.isEmpty {
            return .resolved(resolvedID)
        }
        if matchCount > 1 {
            return .ambiguous
        }
        return .notFound
    }

    @discardableResult
    nonisolated internal static func createMailbox(named folderName: String,
                                                   in account: String,
                                                   parentPath: String?) async throws -> String {
        let trimmedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MailControlError.invalidMailboxName }
        let script = buildCreateMailboxScript(folderName: trimmedName,
                                              account: account,
                                              parentPath: parentPath)
        _ = try await runScript(script)
        let trimmedParent = parentPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedParent.isEmpty {
            return trimmedName
        }
        return "\(trimmedParent)/\(trimmedName)"
    }

    nonisolated internal static func flagSelection(colorIndex: Int = 4) async throws {
        // Apple Mail uses 0..7; common mapping: 1=red 2=orange 3=yellow 4=green 5=blue 6=purple 7=gray
        let script = """
        tell application "Mail"
          repeat with m in selection
            set flagged status of m to true
            set flag index of m to \(colorIndex)
          end repeat
        end tell
        """
        _ = try await runScript(script)
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

    internal static func filteredFallbackOpenScript(subject: String,
                                                    sender: String,
                                                    mailbox: String,
                                                    account: String,
                                                    year: Int,
                                                    month: Int,
                                                    day: Int) -> String {
        let safeSubject = escapedForAppleScript(subject)
        let safeSender = escapedForAppleScript(sender)
        let safeMailbox = escapedForAppleScript(mailbox)
        let safeAccount = escapedForAppleScript(account)

        return """
        \(mailboxPathResolverHandlersScript())
        on monthEnumFromNumber(mNum)
          if mNum is 1 then return January
          if mNum is 2 then return February
          if mNum is 3 then return March
          if mNum is 4 then return April
          if mNum is 5 then return May
          if mNum is 6 then return June
          if mNum is 7 then return July
          if mNum is 8 then return August
          if mNum is 9 then return September
          if mNum is 10 then return October
          if mNum is 11 then return November
          if mNum is 12 then return December
          error "Invalid month number: " & mNum
        end monthEnumFromNumber

        on startOfDayForYMD(y, mNum, d)
          set dt to current date
          set year of dt to y
          set month of dt to my monthEnumFromNumber(mNum)
          set day of dt to d
          set time of dt to 0
          return dt
        end startOfDayForYMD

        using terms from application "Mail"
          on messageMatchesTarget(_msg, _targetSubject, _targetSender)
            set _msgValue to _msg
            try
              set _msgValue to contents of _msg
            end try
            set _subjectText to ""
            set _senderText to ""
            try
              set _subjectText to (subject of _msgValue as string)
            end try
            try
              set _senderText to (sender of _msgValue as string)
            end try
            set _include to true
            ignoring case
              if _targetSubject is not "" then
                set _include to _include and (_subjectText contains _targetSubject)
              end if
              if _targetSender is not "" then
                set _include to _include and (_senderText contains _targetSender)
              end if
            end ignoring
            return _include
          end messageMatchesTarget

          on collectDescendantMailboxes(_container)
            set _results to {}
            set _directMailboxes to {}
            try
              set _directMailboxes to every mailbox of _container
            on error
              return _results
            end try
            repeat with _mailbox in _directMailboxes
              set _mailboxValue to _mailbox
              try
                set _mailboxValue to contents of _mailbox
              end try
              copy _mailboxValue to end of _results
              set _results to _results & my collectDescendantMailboxes(_mailboxValue)
            end repeat
            return _results
          end collectDescendantMailboxes

          on openFirstMatchingMessageInMailbox(_mailboxRef, _startDate, _endDate, _targetSubject, _targetSender)
            set _candidateMessages to {}
            try
              set _candidateMessages to (messages of _mailboxRef whose date received is greater than or equal to _startDate and date received is less than _endDate)
            on error
              return false
            end try
            repeat with _candidateMessage in _candidateMessages
              set _candidateMessageValue to _candidateMessage
              try
                set _candidateMessageValue to contents of _candidateMessage
              end try
              if my messageMatchesTarget(_candidateMessageValue, _targetSubject, _targetSender) then
                try
                  open _candidateMessageValue
                on error
                  try
                    set _viewer to message viewer 1
                    set selected messages of _viewer to {_candidateMessageValue}
                  on error
                    return false
                  end try
                end try
                activate
                return true
              end if
            end repeat
            return false
          end openFirstMatchingMessageInMailbox
        end using terms from

        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _targetSubject to "\(safeSubject)"
            set _targetSender to "\(safeSender)"
            set _sourceMailboxPath to "\(safeMailbox)"
            set _sourceAccount to "\(safeAccount)"
            set _targetYear to \(year)
            set _targetMonth to \(month)
            set _targetDay to \(day)
            set _startDate to my startOfDayForYMD(_targetYear, _targetMonth, _targetDay)
            set _endDate to _startDate + (1 * days)
            set _sourceMailbox to missing value
            if _sourceMailboxPath is not "" and _sourceAccount is not "" then
              try
                set _sourceMailbox to my resolveMailboxByPath(_sourceAccount, _sourceMailboxPath)
              end try
            end if
            if _sourceMailbox is not missing value then
              if my openFirstMatchingMessageInMailbox(_sourceMailbox, _startDate, _endDate, _targetSubject, _targetSender) then return true
            end if

            set _accounts to my matchingAccounts(_sourceAccount)
            repeat with _accountRef in _accounts
              set _accountValue to _accountRef
              try
                set _accountValue to contents of _accountRef
              end try
              set _candidateMailboxes to my collectDescendantMailboxes(_accountValue)
              repeat with _candidateMailbox in _candidateMailboxes
                set _candidateMailboxValue to _candidateMailbox
                try
                  set _candidateMailboxValue to contents of _candidateMailbox
                end try
                if my openFirstMatchingMessageInMailbox(_candidateMailboxValue, _startDate, _endDate, _targetSubject, _targetSender) then return true
              end repeat
            end repeat
            return false
          end timeout
        end tell
        """
    }

    internal static func buildMoveMessagesScript(messageIDs: [String],
                                                 mailboxPath: String,
                                                 account: String) -> String {
        let escapedIDs = messageIDs.map { "\"\(escapedForAppleScript($0))\"" }.joined(separator: ", ")
        let destinationReference = mailboxReference(path: mailboxPath, account: account)
        return """
        set _messageIDs to {\(escapedIDs)}
        set _matchedCount to 0
        set _movedCount to 0
        set _errorCount to 0
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _destMailbox to \(destinationReference)
            repeat with _targetID in _messageIDs
              set _normalizedID to (contents of _targetID)
              set _bracketedID to "<" & _normalizedID & ">"
              set _matches to {}
              ignoring case
                try
                  repeat with _m in (every message whose message id is _normalizedID)
                    copy _m to end of _matches
                    set _matchedCount to _matchedCount + 1
                  end repeat
                end try
                try
                  repeat with _m in (every message whose message id is _bracketedID)
                    copy _m to end of _matches
                    set _matchedCount to _matchedCount + 1
                  end repeat
                end try
                if (count of _matches) is 0 then
                  try
                    repeat with _m in (every message whose message id contains _normalizedID)
                      copy _m to end of _matches
                      set _matchedCount to _matchedCount + 1
                    end repeat
                  end try
                end if
              end ignoring
              repeat with _match in _matches
                try
                  move _match to _destMailbox
                  set _movedCount to _movedCount + 1
                on error
                  set _errorCount to _errorCount + 1
                end try
              end repeat
            end repeat
          end timeout
        end tell
        return {_matchedCount, _movedCount, _errorCount}
        """
    }

    internal static func buildMoveMessagesByInternalIDScript(internalIDs: [String],
                                                             mailboxPath: String,
                                                             account: String) -> String {
        let targets = internalIDs.map {
            InternalIDMoveTarget(internalID: $0, sourceAccount: "", sourceMailboxPath: "")
        }
        return buildMoveMessagesByInternalIDScript(targets: targets, mailboxPath: mailboxPath, account: account)
    }

    internal static func buildMoveMessagesByInternalIDScript(targets: [InternalIDMoveTarget],
                                                             mailboxPath: String,
                                                             account: String) -> String {
        let escapedIDs = targets.map { "\"\(escapedForAppleScript($0.internalID))\"" }.joined(separator: ", ")
        let escapedSourceAccounts = targets.map { "\"\(escapedForAppleScript($0.sourceAccount))\"" }.joined(separator: ", ")
        let escapedSourceMailboxPaths = targets.map { "\"\(escapedForAppleScript($0.sourceMailboxPath))\"" }.joined(separator: ", ")
        let safeAccount = escapedForAppleScript(account)
        let safeMailboxPath = escapedForAppleScript(mailboxPath)
        return """
        \(mailboxPathResolverHandlersScript())
        on indexOfText(_values, _needle)
          repeat with _i from 1 to (count of _values)
            if (item _i of _values as string) is _needle then return _i
          end repeat
          return 0
        end indexOfText

        on appendResolvedMessages(_queryResults, _matches)
          repeat with _m in _queryResults
            set _resolvedMessage to _m
            try
              set _resolvedMessage to contents of _m
            end try
            copy _resolvedMessage to end of _matches
          end repeat
          return _matches
        end appendResolvedMessages

        set _internalIDs to {\(escapedIDs)}
        set _sourceAccounts to {\(escapedSourceAccounts)}
        set _sourceMailboxPaths to {\(escapedSourceMailboxPaths)}
        set _destinationAccount to "\(safeAccount)"
        set _destinationPath to "\(safeMailboxPath)"
        set _matchedCount to 0
        set _movedCount to 0
        set _errorCount to 0
        set _firstErrorNumber to 0
        set _firstErrorMessage to ""
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _destMailbox to my resolveMailboxByPath(_destinationAccount, _destinationPath)
            if _destMailbox is missing value then
              error "Destination mailbox not found for path: " & _destinationPath & " account: " & _destinationAccount number -1728
            end if
            set _sourceCacheKeys to {}
            set _sourceCacheMailboxes to {}
            repeat with _index from 1 to (count of _internalIDs)
              set _idText to (item _index of _internalIDs as string)
              set _sourceAccount to ""
              if _index is less than or equal to (count of _sourceAccounts) then
                set _sourceAccount to (item _index of _sourceAccounts as string)
              end if
              set _sourceMailboxPath to ""
              if _index is less than or equal to (count of _sourceMailboxPaths) then
                set _sourceMailboxPath to (item _index of _sourceMailboxPaths as string)
              end if
              set _matches to {}
              set _idNumberKnown to false
              set _idNumber to 0
              try
                set _idNumber to (_idText as integer)
                set _idNumberKnown to true
              end try

              if _sourceMailboxPath is not "" then
                set _sourceMailbox to missing value
                set _sourceCacheKey to _sourceAccount & "||" & _sourceMailboxPath
                set _sourceCacheIndex to my indexOfText(_sourceCacheKeys, _sourceCacheKey)
                if _sourceCacheIndex is greater than 0 then
                  set _sourceMailbox to item _sourceCacheIndex of _sourceCacheMailboxes
                else
                  try
                    set _sourceMailbox to my resolveMailboxByPath(_sourceAccount, _sourceMailboxPath)
                  on error
                    set _sourceMailbox to missing value
                  end try
                  copy _sourceCacheKey to end of _sourceCacheKeys
                  copy _sourceMailbox to end of _sourceCacheMailboxes
                end if
                if _sourceMailbox is not missing value then
                  if _idNumberKnown then
                    try
                      set _matches to my appendResolvedMessages((messages of _sourceMailbox whose id is _idNumber), _matches)
                    end try
                  end if
                  if (count of _matches) is 0 then
                    try
                      set _matches to my appendResolvedMessages((messages of _sourceMailbox whose id is _idText), _matches)
                    end try
                  end if
                end if
              end if

              if (count of _matches) is 0 and _sourceMailboxPath is "" then
                  try
                    set _matches to my appendResolvedMessages((every message whose id is _idText), _matches)
                  end try
              end if
              if (count of _matches) is 0 and _idNumberKnown and _sourceMailboxPath is "" then
                try
                  set _matches to my appendResolvedMessages((every message whose id is _idNumber), _matches)
                end try
              end if
              set _matchedCount to _matchedCount + (count of _matches)
              repeat with _match in _matches
                try
                  set _resolvedMatch to _match
                  try
                    set _resolvedMatch to contents of _match
                  end try
                  move _resolvedMatch to _destMailbox
                  set _movedCount to _movedCount + 1
                on error _errMsg number _errNum
                  set _errorCount to _errorCount + 1
                  if _firstErrorMessage is "" then
                    set _firstErrorMessage to (_errMsg as string)
                    set _firstErrorNumber to _errNum
                  end if
                end try
              end repeat
            end repeat
          end timeout
        end tell
        return {_matchedCount, _movedCount, _errorCount, _firstErrorNumber, _firstErrorMessage}
        """
    }

    internal static func buildResolveInternalMailIDScript(mailboxPath: String,
                                                          account: String,
                                                          subject: String,
                                                          senderToken: String,
                                                          receivedAt: Date,
                                                          toleranceSeconds: Int,
                                                          allowAccountWideFallback: Bool = true) -> String {
        let safeAccount = escapedForAppleScript(account)
        let safeMailboxPath = escapedForAppleScript(mailboxPath)
        let safeSubject = escapedForAppleScript(subject)
        let safeSenderToken = escapedForAppleScript(senderToken)
        let start = receivedAt.addingTimeInterval(TimeInterval(-max(toleranceSeconds, 1)))
        let end = receivedAt.addingTimeInterval(TimeInterval(max(toleranceSeconds, 1)))
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let endComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end)
        return """
        \(mailboxPathResolverHandlersScript())
        on monthEnumFromNumber(mNum)
          if mNum is 1 then return January
          if mNum is 2 then return February
          if mNum is 3 then return March
          if mNum is 4 then return April
          if mNum is 5 then return May
          if mNum is 6 then return June
          if mNum is 7 then return July
          if mNum is 8 then return August
          if mNum is 9 then return September
          if mNum is 10 then return October
          if mNum is 11 then return November
          if mNum is 12 then return December
          error "Invalid month number: " & mNum
        end monthEnumFromNumber

        on dateFromParts(y, mNum, d, h, minV, s)
          set dt to current date
          set year of dt to y
          set month of dt to my monthEnumFromNumber(mNum)
          set day of dt to d
          set time of dt to ((h * hours) + (minV * minutes) + s)
          return dt
        end dateFromParts

        on messageMatchesTarget(_msg, _targetSubject, _targetSender)
          set _msgValue to _msg
          try
            set _msgValue to contents of _msg
          end try
          set _subjectText to ""
          set _senderText to ""
          try
            set _subjectText to (subject of _msgValue as string)
          on error
            set _subjectText to ""
          end try
          try
            set _senderText to (sender of _msgValue as string)
          on error
            set _senderText to ""
          end try
          set _include to true
          ignoring case
            if _targetSubject is not "" then
              set _include to _include and (_subjectText contains _targetSubject)
            end if
            if _targetSender is not "" then
              set _include to _include and (_senderText contains _targetSender)
            end if
          end ignoring
          return _include
        end messageMatchesTarget

        set _targetSubject to "\(safeSubject)"
        set _targetSender to "\(safeSenderToken)"
        set _sourceAccount to "\(safeAccount)"
        set _sourceMailboxPath to "\(safeMailboxPath)"
        set _allowAccountWideFallback to \(allowAccountWideFallback ? "true" : "false")
        set _startDate to my dateFromParts(\(startComponents.year ?? 1970), \(startComponents.month ?? 1), \(startComponents.day ?? 1), \(startComponents.hour ?? 0), \(startComponents.minute ?? 0), \(startComponents.second ?? 0))
        set _endDate to my dateFromParts(\(endComponents.year ?? 1970), \(endComponents.month ?? 1), \(endComponents.day ?? 1), \(endComponents.hour ?? 0), \(endComponents.minute ?? 0), \(endComponents.second ?? 0))
        set _matchCount to 0
        set _firstID to ""
        set _usedAccountWideFallback to false
        set _fallbackMailboxCount to 0
        set _fallbackMessageCount to 0
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _mbx to missing value
            if _sourceMailboxPath is not "" then
              set _mbx to my resolveMailboxByPath(_sourceAccount, _sourceMailboxPath)
            end if
            if _mbx is not missing value then
              repeat with _m in (messages of _mbx whose date received is greater than or equal to _startDate and date received is less than or equal to _endDate)
                set _mValue to _m
                try
                  set _mValue to contents of _m
                end try
                if my messageMatchesTarget(_mValue, _targetSubject, _targetSender) then
                  set _matchCount to _matchCount + 1
                  if _firstID is "" then
                    set _firstID to (id of _mValue as string)
                  end if
                end if
              end repeat
            end if

            if _allowAccountWideFallback and (_matchCount is 0) then
              set _usedAccountWideFallback to true
              try
                set _mailboxes to {}
                set _accounts to my matchingAccounts(_sourceAccount)
                repeat with _acct in _accounts
                  set _acctValue to contents of _acct
                  try
                    set _candidateMailboxes to every mailbox of _acctValue
                  on error
                    set _candidateMailboxes to {}
                  end try
                  repeat with _candidateMailbox in _candidateMailboxes
                    set _fallbackMailboxCount to _fallbackMailboxCount + 1
                    set _candidateMailboxValue to _candidateMailbox
                    try
                      set _candidateMailboxValue to contents of _candidateMailbox
                    end try
                    set _candidateMessages to {}
                    try
                      set _candidateMessages to (messages of _candidateMailboxValue whose date received is greater than or equal to _startDate and date received is less than or equal to _endDate)
                    on error
                      set _candidateMessages to {}
                    end try
                    repeat with _candidateMessage in _candidateMessages
                      set _fallbackMessageCount to _fallbackMessageCount + 1
                      set _candidateMessageValue to _candidateMessage
                      try
                        set _candidateMessageValue to contents of _candidateMessage
                      end try
                      if my messageMatchesTarget(_candidateMessageValue, _targetSubject, _targetSender) then
                        set _matchCount to _matchCount + 1
                        if _firstID is "" then
                          set _firstID to (id of _candidateMessageValue as string)
                        end if
                      end if
                    end repeat
                  end repeat
                end repeat
              on error
                set _matchCount to 0
                set _firstID to ""
                set _usedAccountWideFallback to false
              end try
            end if
          end timeout
        end tell
        return {_matchCount, _firstID, _usedAccountWideFallback, _fallbackMailboxCount, _fallbackMessageCount}
        """
    }

    internal static func buildCreateMailboxScript(folderName: String,
                                                  account: String,
                                                  parentPath: String?) -> String {
        let safeName = escapedForAppleScript(folderName)
        let trimmedParent = parentPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let containerReference: String
        if trimmedParent.isEmpty {
            containerReference = "account \"\(escapedForAppleScript(account))\""
        } else {
            containerReference = mailboxReference(path: trimmedParent, account: account)
        }
        return """
        tell application id "com.apple.mail"
          with timeout of 60 seconds
            set _container to \(containerReference)
            set _newMailbox to make new mailbox at _container with properties {name:"\(safeName)"}
            return (name of _newMailbox as string)
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
