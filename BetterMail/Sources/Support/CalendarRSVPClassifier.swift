import Foundation

internal nonisolated enum CalendarMessageKind: String, Codable, CaseIterable, Sendable {
    case invitation
    case attendanceOnlyResponse
    case supplementedResponse
    case otherSchedulingMessage
    case ordinaryMessage
    case indeterminate

    internal var isSchedulingMessage: Bool {
        switch self {
        case .invitation, .attendanceOnlyResponse, .supplementedResponse, .otherSchedulingMessage:
            return true
        case .ordinaryMessage, .indeterminate:
            return false
        }
    }

    internal var shouldSuppress: Bool {
        self == .attendanceOnlyResponse
    }
}

internal nonisolated struct CalendarMessageClassification: Equatable, Sendable {
    internal let kind: CalendarMessageKind
    internal let supplementText: String?

    internal init(kind: CalendarMessageKind, supplementText: String? = nil) {
        self.kind = kind
        self.supplementText = supplementText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    internal var shouldSuppress: Bool {
        kind.shouldSuppress
    }
}

/// Classifies real iMIP calendar parts without relying on localized subject
/// prefixes. Attendance-only replies are suppressible; invitations, ordinary
/// mail, and replies carrying an attendee-authored iCalendar COMMENT remain
/// visible.
internal nonisolated enum CalendarRSVPClassifier {
    private enum Inspection {
        case none
        case classified(CalendarMessageClassification)
        case indeterminate
    }

    private static let maximumSourceSize = 512 * 1024
    private static let maximumMultipartDepth = 10

    internal static func classify(_ source: String) -> CalendarMessageClassification {
        guard !source.isEmpty, source.utf8.count <= maximumSourceSize else {
            return CalendarMessageClassification(kind: .indeterminate)
        }

        let normalized = normalizedLineEndings(source)
        if normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .hasPrefix("--") == true {
            return classification(fromFragment: normalized)
        }

        let entity = splitEntity(normalized)
        guard !entity.headers.isEmpty else {
            return CalendarMessageClassification(kind: .ordinaryMessage)
        }
        return classification(from: inspect(headers: entity.headers,
                                             body: entity.body,
                                             depth: 0,
                                             isTopLevel: true))
    }

    internal static func isCalendarRSVP(in source: String) -> Bool {
        classify(source).shouldSuppress
    }

    private static func classification(from inspection: Inspection) -> CalendarMessageClassification {
        switch inspection {
        case .none:
            return CalendarMessageClassification(kind: .ordinaryMessage)
        case .classified(let classification):
            return classification
        case .indeterminate:
            return CalendarMessageClassification(kind: .indeterminate)
        }
    }

    private static func inspect(headers: [String: String],
                                body: String,
                                depth: Int,
                                isTopLevel: Bool) -> Inspection {
        guard depth < maximumMultipartDepth else { return .indeterminate }

        let contentType = headers["content-type"] ?? ""
        let type = mediaType(in: contentType)
        if type == "text/calendar" {
            if !isTopLevel, isSecondaryCalendarAttachment(headers: headers, contentType: contentType) {
                return .none
            }
            guard let decodedBody = decodeBody(body,
                                               transferEncoding: headers["content-transfer-encoding"],
                                               contentType: contentType) else {
                return .indeterminate
            }
            return inspectCalendarPayload(decodedBody, contentType: contentType)
        }

        if type == "message/rfc822" {
            guard let decodedBody = decodeBody(body,
                                               transferEncoding: headers["content-transfer-encoding"],
                                               contentType: contentType) else {
                return .indeterminate
            }
            let nested = splitEntity(normalizedLineEndings(decodedBody))
            guard !nested.headers.isEmpty else { return .none }
            return inspect(headers: nested.headers,
                           body: nested.body,
                           depth: depth + 1,
                           isTopLevel: false)
        }

        guard type.hasPrefix("multipart/") else { return .none }
        guard let boundary = parameter(named: "boundary", in: contentType),
              !boundary.isEmpty,
              let mimeParts = parts(in: body, boundary: boundary) else {
            return .indeterminate
        }

        let inspections = mimeParts.map { part -> Inspection in
            let entity = splitEntity(part)
            guard !entity.headers.isEmpty else { return .none }
            return inspect(headers: entity.headers,
                           body: entity.body,
                           depth: depth + 1,
                           isTopLevel: false)
        }
        return combined(inspections)
    }

    private static func inspectCalendarPayload(_ body: String, contentType: String) -> Inspection {
        let unfoldedLines = unfoldCalendarLines(body)
        let hasCalendarEnvelope = unfoldedLines.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("BEGIN:VCALENDAR") == .orderedSame
        } && unfoldedLines.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("END:VCALENDAR") == .orderedSame
        }
        guard hasCalendarEnvelope else { return .indeterminate }

        let payloadMethod = calendarProperty(named: "METHOD", in: unfoldedLines)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let declaredMethod = parameter(named: "method", in: contentType)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let effectiveMethod = payloadMethod?.nonEmpty ?? declaredMethod?.nonEmpty

        switch effectiveMethod {
        case "REQUEST":
            return .classified(CalendarMessageClassification(kind: .invitation))
        case "REPLY":
            let supplement = unfoldedLines
                .compactMap { calendarProperty(named: "COMMENT", in: [$0]) }
                .map(unescapeCalendarText)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if let supplement {
                return .classified(CalendarMessageClassification(kind: .supplementedResponse,
                                                                  supplementText: supplement))
            }
            return .classified(CalendarMessageClassification(kind: .attendanceOnlyResponse))
        case nil:
            return .classified(CalendarMessageClassification(kind: .otherSchedulingMessage))
        default:
            return .classified(CalendarMessageClassification(kind: .otherSchedulingMessage))
        }
    }

    private static func combined(_ inspections: [Inspection]) -> Inspection {
        var classifications: [CalendarMessageClassification] = []
        var sawIndeterminate = false
        for inspection in inspections {
            switch inspection {
            case .none:
                continue
            case .classified(let classification):
                classifications.append(classification)
            case .indeterminate:
                sawIndeterminate = true
            }
        }

        let priority: [CalendarMessageKind] = [
            .supplementedResponse,
            .attendanceOnlyResponse,
            .invitation,
            .otherSchedulingMessage
        ]
        for kind in priority {
            if let match = classifications.first(where: { $0.kind == kind }) {
                return .classified(match)
            }
        }
        return sawIndeterminate ? .indeterminate : .none
    }

    /// Legacy caches can contain only the multipart body. A boundary-led
    /// fragment is accepted, while arbitrary quoted calendar text is not.
    private static func classification(fromFragment fragment: String) -> CalendarMessageClassification {
        guard let firstLine = fragment
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first else {
            return CalendarMessageClassification(kind: .indeterminate)
        }
        let boundary = String(firstLine.dropFirst(2))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boundary.isEmpty, !boundary.hasSuffix("--"),
              let mimeParts = parts(in: fragment, boundary: boundary) else {
            return CalendarMessageClassification(kind: .indeterminate)
        }
        let inspections = mimeParts.map { part -> Inspection in
            let entity = splitEntity(part)
            guard !entity.headers.isEmpty else { return .none }
            return inspect(headers: entity.headers,
                           body: entity.body,
                           depth: 0,
                           isTopLevel: false)
        }
        return classification(from: combined(inspections))
    }

    private static func splitEntity(_ source: String) -> (headers: [String: String], body: String) {
        guard let headerEnd = source.range(of: "\n\n") else {
            return (parseHeaders(in: source), "")
        }
        return (parseHeaders(in: String(source[..<headerEnd.lowerBound])),
                String(source[headerEnd.upperBound...]))
    }

    private static func parseHeaders(in source: String) -> [String: String] {
        var values: [String: String] = [:]
        var currentKey: String?

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let currentKey else { continue }
                values[currentKey, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).lowercased()
            values[key] = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentKey = key
        }
        return values
    }

    private static func parts(in body: String, boundary: String) -> [String]? {
        let delimiter = "--" + boundary
        let closingDelimiter = delimiter + "--"
        var currentLines: [Substring] = []
        var parsedParts: [String] = []
        var isInsidePart = false
        var sawClosingDelimiter = false

        for line in normalizedLineEndings(body).split(separator: "\n", omittingEmptySubsequences: false) {
            let marker = line.trimmingCharacters(in: .whitespaces)
            if marker == delimiter {
                if isInsidePart {
                    parsedParts.append(currentLines.joined(separator: "\n"))
                }
                currentLines.removeAll(keepingCapacity: true)
                isInsidePart = true
            } else if marker == closingDelimiter {
                if isInsidePart {
                    parsedParts.append(currentLines.joined(separator: "\n"))
                }
                sawClosingDelimiter = true
                isInsidePart = false
                break
            } else if isInsidePart {
                currentLines.append(line)
            }
        }

        guard sawClosingDelimiter, !parsedParts.isEmpty else { return nil }
        return parsedParts
    }

    private static func mediaType(in contentType: String) -> String {
        let value = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        return value
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    private static func parameter(named name: String, in headerValue: String) -> String? {
        let wantedName = name.lowercased()
        for rawParameter in headerValue.split(separator: ";", omittingEmptySubsequences: false).dropFirst() {
            let pair = rawParameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wantedName else {
                continue
            }
            return pair[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private static func isSecondaryCalendarAttachment(headers: [String: String],
                                                       contentType: String) -> Bool {
        let disposition = headers["content-disposition"]?.lowercased() ?? ""
        if disposition.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "attachment" {
            return true
        }
        let candidateNames = [
            parameter(named: "filename", in: headers["content-disposition"] ?? ""),
            parameter(named: "name", in: contentType)
        ]
        return candidateNames.compactMap { $0 }.contains { $0.lowercased().hasSuffix(".ics") }
    }

    private static func unfoldCalendarLines(_ source: String) -> [String] {
        var lines: [String] = []
        for line in normalizedLineEndings(source).split(separator: "\n", omittingEmptySubsequences: false) {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += String(line.dropFirst())
            } else {
                lines.append(String(line))
            }
        }
        return lines
    }

    private static func calendarProperty(named name: String, in lines: [String]) -> String? {
        let wantedName = name.uppercased()
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let propertySection = line[..<separator]
            let propertyName = propertySection
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard propertyName == wantedName else { continue }
            return String(line[line.index(after: separator)...])
        }
        return nil
    }

    private static func unescapeCalendarText(_ value: String) -> String {
        var result = ""
        var isEscaped = false
        for character in value {
            if isEscaped {
                switch character {
                case "n", "N": result.append("\n")
                case ",": result.append(",")
                case ";": result.append(";")
                case "\\": result.append("\\")
                default: result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        if isEscaped { result.append("\\") }
        return result
    }

    private static func decodeBody(_ body: String,
                                   transferEncoding: String?,
                                   contentType: String) -> String? {
        let encoding = transferEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch encoding {
        case "", "7bit", "8bit", "binary":
            return body
        case "base64":
            guard let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
            return decodedString(from: data, contentType: contentType)
        case "quoted-printable":
            guard let data = decodeQuotedPrintable(body) else { return nil }
            return decodedString(from: data, contentType: contentType)
        default:
            return nil
        }
    }

    private static func decodeQuotedPrintable(_ value: String) -> Data? {
        let bytes = Array(normalizedLineEndings(value).utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 61 else {
                decoded.append(bytes[index])
                index += 1
                continue
            }
            if index + 1 < bytes.count, bytes[index + 1] == 10 {
                index += 2
                continue
            }
            guard index + 2 < bytes.count,
                  let high = hexadecimalValue(bytes[index + 1]),
                  let low = hexadecimalValue(bytes[index + 2]) else {
                return nil
            }
            decoded.append(high * 16 + low)
            index += 3
        }
        return Data(decoded)
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private static func decodedString(from data: Data, contentType: String) -> String? {
        let charset = parameter(named: "charset", in: contentType)?.lowercased() ?? "utf-8"
        if charset == "iso-8859-1" || charset == "latin1" || charset == "latin-1" {
            return String(data: data, encoding: .isoLatin1)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func normalizedLineEndings(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

private extension String {
    nonisolated var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
