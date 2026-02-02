import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

internal enum EmailTagError: LocalizedError {
    case noContent
    case unavailable(String)
    case generationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noContent:
            return "No email content is available to tag."
        case .unavailable(let reason):
            return reason
        case .generationFailed(let error):
            return "Apple Intelligence could not generate tags: \(error.localizedDescription)"
        }
    }
}

internal protocol EmailTagProviding {
    func generateTags(_ request: EmailTagRequest) async throws -> [String]
}

internal struct EmailTagCapability {
    internal let provider: EmailTagProviding?
    internal let statusMessage: String
    internal let providerID: String
}

internal struct EmailTagRequest: Hashable {
    internal let subject: String
    internal let from: String
    internal let snippet: String

    internal var hasContent: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

internal enum EmailTagProviderFactory {
    internal static func makeCapability() -> EmailTagCapability {
#if canImport(FoundationModels)
        if #available(macOS 15.2, *) {
            let model = FoundationModelsSupport.makeDefaultModel()
            switch model.availability {
            case .available:
                let provider = FoundationModelsEmailTagProvider(model: model)
                return EmailTagCapability(provider: provider,
                                          statusMessage: "Apple Intelligence tags ready.",
                                          providerID: "foundation-models")
            case .unavailable(let reason):
                return EmailTagCapability(provider: nil,
                                          statusMessage: reason.userFacingMessage,
                                          providerID: "foundation-models")
            }
        }
#endif
        return EmailTagCapability(provider: nil,
                                  statusMessage: "Apple Intelligence tags require a compatible Mac with Apple Intelligence enabled.",
                                  providerID: "foundation-models")
    }
}

#if canImport(FoundationModels)
@available(macOS 15.2, *)
internal final class FoundationModelsEmailTagProvider: EmailTagProviding {
    private let model: SystemLanguageModel

    internal init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    internal func generateTags(_ request: EmailTagRequest) async throws -> [String] {
        guard case .available = model.availability else {
            throw EmailTagError.unavailable(model.availability.userFacingMessage)
        }
        guard request.hasContent else {
            throw EmailTagError.noContent
        }

        do {
            let prompt = Self.tagPrompt(subject: request.subject,
                                        from: request.from,
                                        snippet: request.snippet)
            let session = LanguageModelSession(model: model,
                                               instructions: Self.instructions)
            var options = GenerationOptions()
            options.temperature = 0.2
            options.maximumResponseTokens = 64
            let response = try await session.respond(to: prompt, options: options)
            return Self.parseTags(from: response.content)
        } catch {
            throw EmailTagError.generationFailed(error)
        }
    }

    private static let instructions = """
    You are labeling an email for quick scanning.

    Transform the provided email text into tags only; do not add facts or assumptions.
    Provide exactly three short tags (1-2 words each).
    Return only a comma-separated list of tags.
    Do not include any extra text, numbering, or commentary.
    """

    private static func tagPrompt(subject: String, from: String, snippet: String) -> String {
        let cleanedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        Generate tags by transforming only the provided email text.
        Use only the information in the subject, sender, and snippet; do not add new facts.

        Subject: \(cleanedSubject.isEmpty ? "No subject" : cleanedSubject)
        From: \(cleanedFrom.isEmpty ? "Unknown sender" : cleanedFrom)
        Snippet: \(cleanedSnippet.isEmpty ? "No snippet" : cleanedSnippet)
        """
    }

    private static func parseTags(from response: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\n")
        let rawTags = response
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•0123456789. ")) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var unique: [String] = []
        for tag in rawTags {
            let normalized = tag.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            unique.append(tag)
            if unique.count == 3 {
                break
            }
        }
        return unique
    }
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
            return "This Mac does not support Apple Intelligence tags."
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in System Settings to see message tags."
        case .modelNotReady:
            return "Apple Intelligence is preparing the on-device model. Try again shortly."
        }
    }
}
#endif
