import Foundation

internal nonisolated struct SnippetFormatter: Sendable {
    internal let lineLimit: Int
    internal let stopPhrases: [String]

    internal func format(_ text: String) -> String {
        let decoder = HeaderDecoder()
        let content: String
        if let decoded = decoder.readableMIMEContent(from: text) {
            content = decoded
        } else if decoder.containsMIMEFraming(text) {
            content = ""
        } else {
            content = text
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let filtered = removeStopPhrases(from: trimmed)
        return trimmedPreview(preserveFormatting(in: filtered), maxLines: lineLimit)
    }

    private func removeStopPhrases(from text: String) -> String {
        guard !stopPhrases.isEmpty else { return text }
        var updated = text
        for phrase in stopPhrases where !phrase.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            let regex = try? NSRegularExpression(pattern: escaped, options: [.caseInsensitive])
            let range = NSRange(updated.startIndex..<updated.endIndex, in: updated)
            updated = regex?.stringByReplacingMatches(in: updated, options: [], range: range, withTemplate: "") ?? updated
        }

        return updated
    }

    private func preserveFormatting(in text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var cleaned: [String] = []
        var previousLineWasBlank = true

        for line in lines {
            var value = String(line)
            while value.last?.isWhitespace == true {
                value.removeLast()
            }
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
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
        return cleaned.joined(separator: "\n")
    }

    private func trimmedPreview(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return text }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > maxLines else { return text }
        var limited = lines.prefix(maxLines).map(String.init)
        if let lastIndex = limited.indices.last, !limited[lastIndex].hasSuffix("…") {
            limited[lastIndex] = limited[lastIndex] + "…"
        }
        return limited.joined(separator: "\n")
    }
}
