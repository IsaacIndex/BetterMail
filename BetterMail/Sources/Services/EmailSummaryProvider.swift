import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

internal enum EmailSummaryError: LocalizedError {
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

internal protocol EmailSummaryProviding {
    /// Inbox subject-line digest. Currently not wired into the UI.
    @available(*, deprecated, message: "Not wired into the UI. Use summarizeEmail(_:) or summarizeFolder(_:) instead.")
    func summarize(subjects: [String]) async throws -> String
    func summarizeEmail(_ request: EmailSummaryRequest) async throws -> String
    func summarizeFolder(_ request: FolderSummaryRequest) async throws -> String
}

internal struct EmailSummaryCapability {
    internal let provider: EmailSummaryProviding?
    internal let statusMessage: String
    internal let providerID: String
}

internal struct EmailSummaryContextEntry: Hashable {
    internal let messageID: String
    internal let subject: String
    internal let bodySnippet: String
}

internal struct EmailSummaryRequest: Hashable {
    internal let subject: String
    internal let body: String
    internal let priorMessages: [EmailSummaryContextEntry]
}

internal struct FolderSummaryRequest: Hashable {
    internal let title: String
    internal let messageSummaries: [String]
}

internal enum EmailSummaryProviderFactory {
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

#if canImport(FoundationModels)
@available(macOS 15.2, *)
internal final class FoundationModelsEmailSummaryProvider: EmailSummaryProviding {
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
                                         prior: request.priorMessages)
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
                                   prior: [EmailSummaryContextEntry]) -> String {
        let priorLines = prior.prefix(10).enumerated().map { index, entry in
            let subjectLine = entry.subject.isEmpty ? "No subject" : entry.subject
            let snippetLine = entry.bodySnippet.isEmpty ? "" : " — \(entry.bodySnippet)"
            return "\(index + 1). \(subjectLine)\(snippetLine)"
        }.joined(separator: "\n")
        
        let priorSection = priorLines.isEmpty ? "None" : priorLines
        let resolvedSubject = subject.isEmpty ? "No subject" : subject
        let resolvedBody = body.isEmpty ? "No body content available." : body
        
        return """
            ### TASK
            Write a plain-language digest of what matters in the current email AND what is new compared to the prior thread context.

            ### RULES
            - Use ONLY the provided text.
            - Output 1–2 short sentences (plain text).
            - No bullet points, headings, labels, greetings, apologies, or meta commentary.
            - Do NOT quote the email body; paraphrase and compress.
            - Do NOT add facts, speculate, or infer missing details.
            - If the current email adds nothing meaningfully new or actionable, output: No new updates.

            ### CURRENT EMAIL
            Subject: \(resolvedSubject)
            Body: \(resolvedBody)

            ### PRIOR THREAD CONTEXT
            \(priorSection)
        """
    }
    
    private static func folderPrompt(title: String,
                                     summaries: [String]) -> String {
        let bullets = summaries.prefix(20).enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let resolvedTitle = title.isEmpty ? "Folder" : title
        
        return """
        Transform the following email summaries into a concise folder overview.
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
    
    Your job: summarize what matters in the CURRENT email and what is NEW compared to the prior thread context.
    
    Rules:
    - Use ONLY the provided text.
    - Output 1–2 short sentences (plain text).
    - Do NOT add facts, speculate, or infer missing details.
    - Do NOT include headings, bullet points, labels, greetings, apologies, or meta commentary.
    - Do NOT quote the email text; paraphrase and compress.
    - If the current email adds nothing meaningfully new or actionable, output exactly: No new updates.
    
    Write the digest directly as the final output.
    """
}

@available(macOS 15.2, *)
private extension FoundationModels.SystemLanguageModel.Availability {
    var userFacingMessage: String {
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
    var userFacingMessage: String {
        switch self {
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence summaries."
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in System Settings to see inbox summaries."
        case .modelNotReady:
            return "Apple Intelligence is preparing the on-device model. Try again shortly."
        }
    }
}
#endif
