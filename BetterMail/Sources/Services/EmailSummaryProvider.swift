import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

internal nonisolated enum EmailSummaryError: LocalizedError {
    case noSubjects
    case unavailable(String)
    case generationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .noSubjects:
            return "No recent email subjects are available to summarize."
        case .unavailable(let reason):
            return reason
        case .generationFailed(let error):
            return "Apple Intelligence could not summarize the inbox: \(error.localizedDescription)"
        }
    }
}

internal nonisolated protocol EmailSummaryProviding: Sendable {
    /// Inbox subject-line digest. Currently not wired into the UI.
    @available(*, deprecated, message: "Not wired into the UI. Use summarizeEmail(_:) or summarizeFolder(_:) instead.")
    func summarize(subjects: [String]) async throws -> String
    func summarizeEmail(_ request: EmailSummaryRequest) async throws -> String
    func summarizeFolder(_ request: FolderSummaryRequest) async throws -> String
}

internal nonisolated protocol GraphTitleProviding: Sendable {
    func makeGraphTitle(_ request: GraphTitleRequest) async throws -> String
}

internal nonisolated struct EmailSummaryCapability: Sendable {
    internal let provider: (any EmailSummaryProviding)?
    internal let statusMessage: String
    internal let providerID: String
}

internal nonisolated struct GraphTitleCapability: Sendable {
    internal let provider: (any GraphTitleProviding)?
    internal let statusMessage: String
    internal let providerID: String
    internal let shouldRetry: Bool
}

internal nonisolated enum EmailSummaryContextDirection: String, Hashable, Sendable {
    case previous
    case next
}

internal nonisolated enum EmailSummaryRelationshipKind: String, Hashable, Sendable {
    case automaticReply
    case manualThreadLink
}

internal nonisolated struct EmailSummaryContextEntry: Hashable, Sendable {
    internal let messageID: String
    internal let subject: String
    internal let bodySnippet: String
    internal let direction: EmailSummaryContextDirection
    internal let relationship: EmailSummaryRelationshipKind
}

internal nonisolated struct EmailSummaryThreadContext: Hashable, Sendable {
    internal let position: Int
    internal let totalMessages: Int
    internal let previousMessage: EmailSummaryContextEntry?
    internal let nextMessage: EmailSummaryContextEntry?

    internal var neighbours: [EmailSummaryContextEntry] {
        [previousMessage, nextMessage].compactMap { $0 }
    }
}

internal nonisolated struct EmailSummaryRequest: Hashable, Sendable {
    internal let subject: String
    internal let body: String
    internal let threadContext: EmailSummaryThreadContext
}

internal nonisolated struct FolderSummaryRequest: Hashable, Sendable {
    internal let title: String
    internal let messageSummaries: [String]
}

internal nonisolated struct GraphTitleRequest: Hashable, Sendable {
    internal let subject: String
    internal let summary: String
    internal let threadContext: EmailSummaryThreadContext
    internal let effectiveThreadRevision: String
}

/// Builds the shared, versioned prompt used by automatic Graph title refreshes
/// and explicit "Regenerate message title" requests.
internal nonisolated enum GraphTitlePromptBuilder {
    internal static let promptVersion = "graph-title-context-v2"

    internal static let instructions = """
    You create concise semantic titles for the CURRENT email in an email relationship graph.

    Use the current email's completed content summary together with its chronological position and immediate neighbours to express what this specific email contributes to the conversation.

    Context rules:
    - Neighbouring emails are context only. Never attribute a neighbour's content, decision, or request to the current email.
    - Make the email's conversational role clear: for example, what it introduces, requests, answers, clarifies, confirms, decides, follows up, or supersedes.
    - Do not invent a conversation role when the supplied current summary does not support it.
    - Automatic reply and manual thread-link labels describe only the adjacency, not the email's content.
    - Express placement semantically through the current email's contribution, never as a sequence number.

    Output rules:
    - Output exactly one short plain-text phrase and nothing else.
    - Use 2 to 5 words and no more than 32 characters.
    - Do not output a numeric position, ordinal marker, email number, or position/total prefix.
    - Do not use generic placement-only labels such as Opening message, Intermediate reply, Latest message, or Standalone message.
    - Preserve the most identifying project name, acronym, ticket, or request number when present.
    - Remove reply and forwarding prefixes such as Re, FW, and Fwd.
    - Do not use quotation marks, headings, labels, a trailing period, or invented facts.
    """

    internal static func prompt(for request: GraphTitleRequest) -> String {
        let context = request.threadContext
        let position = clampedPosition(in: context)
        let total = max(1, context.totalMessages)
        let subject = boundedText(request.subject, maximumCharacters: 180, fallback: "No subject")
        let summary = boundedText(request.summary, maximumCharacters: 700, fallback: "No summary available")
        return """
        Create the semantic conversational title for the CURRENT email.

        Thread position: \(position) of \(total)
        Placement: \(placement(position: position, total: total))
        Current subject: \(subject)
        Current summary: \(summary)

        \(neighbourBlock(label: "Previous message", entry: context.previousMessage))

        \(neighbourBlock(label: "Next message", entry: context.nextMessage))

        Remember: neighbour details are context only and must not be attributed to the current email.
        """
    }

    private static func clampedPosition(in context: EmailSummaryThreadContext) -> Int {
        min(max(1, context.position), max(1, context.totalMessages))
    }

    private static func placement(position: Int, total: Int) -> String {
        if total == 1 { return "Standalone message" }
        if position == 1 { return "Opening message" }
        if position == total { return "Latest message" }
        return "Intermediate reply"
    }

    private static func neighbourBlock(label: String,
                                       entry: EmailSummaryContextEntry?) -> String {
        guard let entry else { return "\(label): None" }
        let subject = boundedText(entry.subject, maximumCharacters: 180, fallback: "No subject")
        let excerpt = boundedText(entry.bodySnippet, maximumCharacters: 220, fallback: "No excerpt")
        let relationship = switch entry.relationship {
        case .automaticReply:
            "automatic reply"
        case .manualThreadLink:
            "manual thread link"
        }
        return """
        \(label) (\(relationship)):
        Subject: \(subject)
        Excerpt: \(excerpt)
        """
    }

    private static func boundedText(_ value: String,
                                    maximumCharacters: Int,
                                    fallback: String) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = collapsed.isEmpty ? fallback : collapsed
        guard resolved.count > maximumCharacters else { return resolved }
        return String(resolved.prefix(maximumCharacters)) + "…"
    }
}

/// Keeps the graph contract bounded even if a model returns extra prose.
/// The model still performs the semantic compression; this formatter only
/// removes response decoration and enforces a hard one-line safety limit.
internal nonisolated enum GraphTitleFormatter {
    internal static let maximumCharacterCount = 32
    internal static let maximumWordCount = 5

    internal static func normalizedGeneratedTitle(_ rawTitle: String,
                                                  fallback: String) -> String {
        let firstLine = rawTitle
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let normalized = normalizedPhrase(firstLine)
        let fallbackPhrase = normalizedPhrase(fallback)
        return bounded(normalized.isEmpty ? fallbackPhrase : normalized)
    }

    private static func normalizedPhrase(_ rawValue: String) -> String {
        var value = rawValue
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappingQuotes = CharacterSet(charactersIn: "\"'“”‘’")
        let responsePrefixes = ["title:", "label:", "graph title:"]
        let emailPrefixes = ["re:", "fw:", "fwd:"]
        let leadingMarkerPatterns = [
            #"^[0-9]+\s*(/|of)\s*[0-9]+\s*([·•:.\-–—]\s*)?"#,
            #"^(email|message)\s+[0-9]+\s*((/|of)\s*[0-9]+)?\s*([·•:.\-–—]\s*)?"#,
            #"^[0-9]+\s*[.)]\s*"#
        ]

        // Strip response decoration, wrapping quotes, legacy ordinal markers,
        // and mail prefixes until stable. Repeating is important for persisted
        // combinations such as `Title: "1/2 · 1. Opening message"`.
        var previousValue: String?
        while previousValue != value {
            previousValue = value
            value = value.trimmingCharacters(in: wrappingQuotes.union(.whitespacesAndNewlines))

            for prefix in responsePrefixes where value.lowercased().hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }

            for pattern in leadingMarkerPatterns {
                if let range = value.range(of: pattern,
                                           options: [.regularExpression, .caseInsensitive]) {
                    value.removeSubrange(range)
                    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            for prefix in emailPrefixes where value.lowercased().hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }

            value = value.trimmingCharacters(in: wrappingQuotes.union(.whitespacesAndNewlines))
        }

        value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        value = value.trimmingCharacters(in: wrappingQuotes.union(.whitespacesAndNewlines))

        let placementOnlyTitles: Set<String> = [
            "email",
            "message",
            "reply",
            "opening message",
            "intermediate reply",
            "latest message",
            "standalone message"
        ]
        return placementOnlyTitles.contains(value.lowercased()) ? "" : value
    }

    private static func bounded(_ value: String,
                                maximumCharacterCount: Int = GraphTitleFormatter.maximumCharacterCount,
                                maximumWordCount: Int = GraphTitleFormatter.maximumWordCount) -> String {
        var words = value
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !["-", "–", "—", "/"].contains($0) }
        if words.count > maximumWordCount {
            let retainedWords = Array(words.prefix(maximumWordCount))
            let retainedHasIdentifier = retainedWords.contains(where: containsIdentifier)
            words = retainedWords
            if !retainedHasIdentifier,
               let identifyingWord = value
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .dropFirst(maximumWordCount)
                .first(where: containsIdentifier) {
                words[maximumWordCount - 1] = identifyingWord
            }
        }

        let value = words.joined(separator: " ")
        guard value.count > maximumCharacterCount else { return value }
        if let identifierIndex = words.lastIndex(where: containsIdentifier),
           words[identifierIndex].count < maximumCharacterCount {
            let identifier = words[identifierIndex]
            let candidatePrefixWords = Array(words[..<identifierIndex])
            var retainedPrefixWords: [String] = []
            for word in candidatePrefixWords {
                let omittedWords = retainedPrefixWords.count + 1 < candidatePrefixWords.count
                let candidate = (
                    retainedPrefixWords +
                    [word] +
                    (omittedWords ? ["…"] : []) +
                    [identifier]
                ).joined(separator: " ")
                guard candidate.count <= maximumCharacterCount else { break }
                retainedPrefixWords.append(word)
            }
            let omittedWords = retainedPrefixWords.count < candidatePrefixWords.count
            let identifierPreservingValue = (
                retainedPrefixWords +
                (omittedWords ? ["…"] : []) +
                [identifier]
            ).joined(separator: " ")
            if identifierPreservingValue.count <= maximumCharacterCount {
                return identifierPreservingValue
            }
        }
        let prefixLimit = max(1, maximumCharacterCount - 1)
        let prefix = String(value.prefix(prefixLimit))
        if let boundary = prefix.lastIndex(where: \.isWhitespace),
           prefix.distance(from: prefix.startIndex, to: boundary) >= 12 {
            return String(prefix[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return prefix + "…"
    }

    private static func containsIdentifier(_ word: String) -> Bool {
        word.contains("#") || word.contains(where: \.isNumber)
    }
}

internal nonisolated enum EmailSummaryProviderFactory {
    internal static func makeCapability() -> EmailSummaryCapability {
#if canImport(FoundationModels)
        if #available(macOS 15.2, *) {
            let model = FoundationModelsSupport.makeDefaultModel()
            switch model.availability {
            case .available:
                let provider = FoundationModelsEmailSummaryProvider(model: model)
                return EmailSummaryCapability(provider: provider,
                                              statusMessage: "Apple Intelligence summary ready.",
                                              providerID: "foundation-models")
            case .unavailable(let reason):
                return EmailSummaryCapability(provider: nil,
                                              statusMessage: reason.userFacingMessage,
                                              providerID: "foundation-models")
            }
        }
#endif
        return EmailSummaryCapability(provider: nil,
                                      statusMessage: "Apple Intelligence summaries require a compatible Mac with Apple Intelligence enabled.",
                                      providerID: "foundation-models")
    }
}

internal nonisolated enum GraphTitleProviderFactory {
    internal static func makeCapability() -> GraphTitleCapability {
#if canImport(FoundationModels)
        if #available(macOS 15.2, *) {
            let model = FoundationModelsSupport.makeDefaultModel()
            switch model.availability {
            case .available:
                return GraphTitleCapability(
                    provider: FoundationModelsEmailSummaryProvider(model: model),
                    statusMessage: "Apple Intelligence graph titles ready.",
                    providerID: "foundation-models-graph-title-v2",
                    shouldRetry: false
                )
            case .unavailable(let reason):
                let shouldRetry: Bool
                switch reason {
                case .modelNotReady:
                    shouldRetry = true
                case .deviceNotEligible, .appleIntelligenceNotEnabled:
                    shouldRetry = false
                @unknown default:
                    shouldRetry = false
                }
                return GraphTitleCapability(provider: nil,
                                            statusMessage: reason.userFacingMessage,
                                            providerID: "foundation-models-graph-title-v2",
                                            shouldRetry: shouldRetry)
            }
        }
#endif
        return GraphTitleCapability(
            provider: nil,
            statusMessage: "Apple Intelligence graph titles require a compatible Mac with Apple Intelligence enabled.",
            providerID: "foundation-models-graph-title-v2",
            shouldRetry: false
        )
    }
}

#if canImport(FoundationModels)
@available(macOS 15.2, *)
internal nonisolated final class FoundationModelsEmailSummaryProvider: EmailSummaryProviding, GraphTitleProviding, @unchecked Sendable {
    private let model: SystemLanguageModel
    
    internal init(model: SystemLanguageModel = .default) {
        self.model = model
    }
    
    @available(*, deprecated, message: "Not wired into the UI. Use summarizeEmail(_:) or summarizeFolder(_:) instead.")
    internal func summarize(subjects: [String]) async throws -> String {
        // NOTE: This digest path is not currently invoked by the UI.
        guard case .available = model.availability else {
            throw EmailSummaryError.unavailable(model.availability.userFacingMessage)
        }
        
        let cleanedSubjects = Self.prepareSubjects(from: subjects)
        guard !cleanedSubjects.isEmpty else {
            throw EmailSummaryError.noSubjects
        }
        
        do {
            let prompt = Self.prompt(for: cleanedSubjects)
            let session = LanguageModelSession(model: model,
                                               instructions: Self.instructions)
            var options = GenerationOptions()
            options.temperature = 0.2
            options.maximumResponseTokens = 120
            let response = try await session.respond(to: prompt, options: options)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw EmailSummaryError.generationFailed(error)
        }
    }
    
    internal func summarizeEmail(_ request: EmailSummaryRequest) async throws -> String {
        guard case .available = model.availability else {
            throw EmailSummaryError.unavailable(model.availability.userFacingMessage)
        }
        
        let cleanedSubject = request.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedBody = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSubject.isEmpty || !cleanedBody.isEmpty else {
            throw EmailSummaryError.noSubjects
        }
        
        do {
            let prompt = Self.nodePrompt(subject: cleanedSubject,
                                         body: cleanedBody,
                                         context: request.threadContext)
            let session = LanguageModelSession(model: model,
                                               instructions: Self.nodeInstructions)
            var options = GenerationOptions()
            options.temperature = 0.2
            options.maximumResponseTokens = 140
            let response = try await session.respond(to: prompt, options: options)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw EmailSummaryError.generationFailed(error)
        }
    }
    
    internal func summarizeFolder(_ request: FolderSummaryRequest) async throws -> String {
        guard case .available = model.availability else {
            throw EmailSummaryError.unavailable(model.availability.userFacingMessage)
        }
        
        let cleanedSummaries = request.messageSummaries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedSummaries.isEmpty else {
            throw EmailSummaryError.noSubjects
        }
        
        do {
            let prompt = Self.folderPrompt(title: request.title,
                                           summaries: cleanedSummaries)
            let session = LanguageModelSession(model: model,
                                               instructions: Self.instructions)
            var options = GenerationOptions()
            options.temperature = 0.2
            options.maximumResponseTokens = 160
            let response = try await session.respond(to: prompt, options: options)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw EmailSummaryError.generationFailed(error)
        }
    }

    internal func makeGraphTitle(_ request: GraphTitleRequest) async throws -> String {
        guard case .available = model.availability else {
            throw EmailSummaryError.unavailable(model.availability.userFacingMessage)
        }

        let cleanedSubject = String(request.subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(180))
        let cleanedSummary = String(request.summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(700))
        guard !cleanedSubject.isEmpty || !cleanedSummary.isEmpty else {
            throw EmailSummaryError.noSubjects
        }

        do {
            let session = LanguageModelSession(model: model,
                                               instructions: GraphTitlePromptBuilder.instructions)
            var options = GenerationOptions()
            options.temperature = 0.1
            options.maximumResponseTokens = 32
            let response = try await session.respond(
                to: GraphTitlePromptBuilder.prompt(for: request),
                options: options
            )
            return GraphTitleFormatter.normalizedGeneratedTitle(response.content,
                                                                fallback: cleanedSubject)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EmailSummaryError.generationFailed(error)
        }
    }
    
    private static func prepareSubjects(from subjects: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        
        for subject in subjects {
            let cleaned = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if seen.insert(cleaned).inserted {
                ordered.append(cleaned)
            }
            if ordered.count == 25 {
                break
            }
        }
        
        return ordered
    }
    
    @available(*, deprecated, message: "Not wired into the UI. Use nodePrompt(_:) instead.")
    private static func prompt(for subjects: [String]) -> String {
        let bullets = subjects.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        
        return """
### TASK
Write a plain-language inbox digest from the subject lines.

### RULES
- Use ONLY the provided subject lines.
- Output 1–2 short sentences (plain text).
- Do NOT add facts, speculate, or infer missing details.
- Do NOT include headings, bullet points, labels, greetings, apologies, or meta commentary.
- Do NOT quote any subject verbatim; paraphrase and compress.
- If nothing looks time-sensitive or actionable, output: No urgent updates.

### SUBJECT LINES
Subjects:
\(bullets)
"""
    }
    
    private static let instructions = """
        You are an executive assistant reviewing a user’s inbox.

        Produce a plain-language digest of what matters and what the user should focus on, using ONLY the provided text.

        Output rules:
        - Write 1–2 short sentences (plain text).
        - Do NOT add facts, speculate, or infer missing details.
        - Do NOT include headings, bullet points, labels, greetings, apologies, or meta commentary.
        - Do NOT quote the input verbatim; paraphrase and compress.
        - If nothing actionable or time-sensitive is present, output: No urgent updates.

        Write the digest directly as the final output.
    """
    
    private static func nodePrompt(subject: String,
                                   body: String,
                                   context: EmailSummaryThreadContext) -> String {
        func contextLine(_ entry: EmailSummaryContextEntry?) -> String {
            guard let entry else { return "None" }
            let subjectLine = entry.subject.isEmpty ? "No subject" : entry.subject
            let snippetLine = entry.bodySnippet.isEmpty ? "" : " — \(entry.bodySnippet)"
            let relationship = entry.relationship == .manualThreadLink
                ? "manual thread link"
                : "automatic email reply"
            return "\(subjectLine)\(snippetLine) [\(relationship)]"
        }

        let resolvedSubject = subject.isEmpty ? "No subject" : subject
        let resolvedBody = body.isEmpty ? "No body content available." : body
        
        return """
            ### TASK
            Summarize the content of the CURRENT email. Use its thread position and immediate neighbours only to clarify references and what is new in this email.

            ### RULES
            - Use ONLY the provided text.
            - Output 1–2 short sentences (plain text).
            - No bullet points, headings, labels, greetings, apologies, or meta commentary.
            - Do NOT quote the email body; paraphrase and compress.
            - Do NOT add facts, speculate, or infer missing details.
            - Neighbouring emails are context only. Never attribute their claims, decisions, or actions to the current email.
            - Focus on the current email's own information, request, decision, answer, confirmation, or action.
            - Mention its relationship to the conversation only when that helps explain the current email's content.
            - If the current email adds nothing meaningfully new, state what it acknowledges or repeats without inventing an update.

            ### CURRENT EMAIL
            Position: \(context.position) of \(context.totalMessages)
            Subject: \(resolvedSubject)
            Body: \(resolvedBody)

            ### IMMEDIATE PREVIOUS EMAIL
            \(contextLine(context.previousMessage))

            ### IMMEDIATE NEXT EMAIL
            \(contextLine(context.nextMessage))
        """
    }
    
    private static func folderPrompt(title: String,
                                     summaries: [String]) -> String {
        let bullets = summaries.prefix(20).enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let resolvedTitle = title.isEmpty ? "Group" : title
        
        return """
        Transform the following email summaries into a concise BetterMail Group overview.
        Use only the provided text; do not add new facts or assumptions.
        Highlight the main themes, decisions, or urgent follow ups.
        Keep the tone professional and actionable, in two or three sentences.
        Output only the overview text (no headings, labels, bullet points, or blank lines).
        
        \(resolvedTitle)
        
        \(bullets)
        """
    }

    private static let nodeInstructions = """
    You are an executive assistant reviewing a user’s email thread.
    
    Your job: summarize the CURRENT email's own content, using its thread position and immediate neighbours only to clarify context.
    
    Rules:
    - Use ONLY the provided text.
    - Output 1–2 short sentences (plain text).
    - Do NOT add facts, speculate, or infer missing details.
    - Do NOT include headings, bullet points, labels, greetings, apologies, or meta commentary.
    - Do NOT quote the email text; paraphrase and compress.
    - Focus on the current email's information, request, decision, answer, confirmation, or action.
    - Mention its conversational relationship only when it clarifies the current email's content.
    - Treat neighbouring emails as context only; never attribute their content to the current email.
    - If the current email adds nothing meaningfully new, state what it acknowledges or repeats without inventing an update.
    
    Write the digest directly as the final output.
    """
}

@available(macOS 15.2, *)
private extension FoundationModels.SystemLanguageModel.Availability {
    nonisolated var userFacingMessage: String {
        switch self {
        case .available:
            return ""
        case .unavailable(let reason):
            return reason.userFacingMessage
        }
    }
}

@available(macOS 15.2, *)
private extension FoundationModels.SystemLanguageModel.Availability.UnavailableReason {
    nonisolated var userFacingMessage: String {
        switch self {
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence summaries."
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in System Settings to see inbox summaries."
        case .modelNotReady:
            return "Apple Intelligence is preparing the on-device model. Try again shortly."
        @unknown default:
            return "Apple Intelligence summaries are currently unavailable."
        }
    }
}
#endif
