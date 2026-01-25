import Foundation

internal struct SnippetFormatter {
    internal let lineLimit: Int
    internal let stopPhrases: [String]

    internal func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let filtered = removeStopPhrases(from: trimmed)
        return trimmedPreview(filtered, maxLines: lineLimit)
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

        let lines = updated.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let cleaned = lines.compactMap { line -> String? in
            let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }
        return cleaned.joined(separator: "\n")
    }

    private func trimmedPreview(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return text }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > maxLines else { return text }
        var limited = lines.prefix(maxLines).map(String.init)
        if let lastIndex = limited.indices.last {
            limited[lastIndex] = limited[lastIndex] + "…"
        }
        return limited.joined(separator: "\n")
    }
}
