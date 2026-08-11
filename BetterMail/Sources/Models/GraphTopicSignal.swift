import Foundation

/// One bounded topic signal for one whole email conversation.
///
/// Signals are generated on device and cached per raw thread ID. They are not
/// folder mutations; `GraphTopicRanker` decides whether multiple conversations
/// provide enough evidence to render a non-mutating ghost suggestion.
internal struct GraphTopicSignal: Codable, Hashable {
    internal let normalizedTopic: String
    internal let displayTitle: String
    internal let confidence: Double
    internal let supportingReason: String

    internal init(topic: String,
                  displayTitle: String,
                  confidence: Double,
                  supportingReason: String) {
        let normalizedTopic = GraphTopicNormalizer.normalize(topic)
        let cleanedDisplayTitle = GraphTopicNormalizer.displayTitle(displayTitle)
        self.normalizedTopic = normalizedTopic
        self.displayTitle = cleanedDisplayTitle.isEmpty
            ? GraphTopicNormalizer.displayTitle(topic)
            : cleanedDisplayTitle
        self.confidence = min(max(confidence, 0), 1)
        self.supportingReason = GraphTopicNormalizer.supportingReason(supportingReason)
    }

    internal var isUsable: Bool {
        !normalizedTopic.isEmpty &&
            !displayTitle.isEmpty &&
            !GraphTopicQualityPolicy.isGeneric(normalizedTopic)
    }
}

internal struct GraphTopicMember: Identifiable, Codable, Hashable {
    internal let rawThreadID: String
    internal let graphThreadID: String
    internal let fullTitle: String
    internal let existingFolderID: String?
    internal let existingFolderTitle: String?

    internal var id: String { rawThreadID }
}

/// Locale-invariant identity used by ranking and both local preference modes.
internal enum GraphTopicNormalizer {
    private static let invariantLocale = Locale(identifier: "en_US_POSIX")

    internal static func normalize(_ rawValue: String) -> String {
        let folded = rawValue
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: invariantLocale)
            .lowercased(with: invariantLocale)
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(folded.unicodeScalars.count)
        var lastWasSeparator = true

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                scalars.append(" ")
                lastWasSeparator = true
            }
        }

        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    internal static func displayTitle(_ rawValue: String) -> String {
        boundedSingleLine(rawValue, maximumCharacterCount: 80)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.,;:!? "))
    }

    internal static func supportingReason(_ rawValue: String) -> String {
        boundedSingleLine(rawValue, maximumCharacterCount: 240)
    }

    internal static func identifierComponent(_ rawValue: String) -> String {
        normalize(rawValue).replacingOccurrences(of: " ", with: "-")
    }

    private static func boundedSingleLine(_ rawValue: String,
                                          maximumCharacterCount: Int) -> String {
        let cleaned = rawValue
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(maximumCharacterCount))
    }
}

/// Deterministic policy shared by the provider boundary and pure ranker.
internal enum GraphTopicQualityPolicy {
    /// A single generic workflow word is not meaningful folder evidence.
    private static let genericLabels: Set<String> = [
        "action", "announcement", "discussion", "email", "follow up", "general",
        "information", "meeting", "message", "notification", "project", "reminder",
        "request", "review", "status", "task", "update", "weekly meeting"
    ]
    private static let genericTokens: Set<String> = [
        "action", "announcement", "discussion", "email", "follow", "general", "information",
        "meeting", "message", "notification", "project", "reminder", "request", "review",
        "status", "task", "update", "weekly"
    ]

    internal static func isGeneric(_ rawTopic: String) -> Bool {
        let normalized = GraphTopicNormalizer.normalize(rawTopic)
        guard !normalized.isEmpty else { return true }
        if genericLabels.contains(normalized) { return true }
        let tokens = normalized.split(separator: " ").map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy(genericTokens.contains)
    }

    internal static func specificity(of rawTopic: String) -> Double {
        let normalized = GraphTopicNormalizer.normalize(rawTopic)
        guard !normalized.isEmpty, !isGeneric(normalized) else { return 0 }
        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return 0 }

        var score = tokens.count == 1 ? 0.35 : 0.55 + Double(min(tokens.count - 2, 3)) * 0.08
        if tokens.contains(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) {
            score += 0.20
        }
        if tokens.contains(where: { $0.count >= 7 }) {
            score += 0.08
        }
        let genericCount = tokens.filter(genericTokens.contains).count
        score -= 0.30 * Double(genericCount) / Double(tokens.count)
        return min(max(score, 0), 1)
    }
}
