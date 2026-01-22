import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum EmailSummaryError: LocalizedError {
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

protocol EmailSummaryProviding {
    func summarize(subjects: [String]) async throws -> String
}

struct EmailSummaryCapability {
    let provider: EmailSummaryProviding?
    let statusMessage: String
    let providerID: String
}

enum EmailSummaryProviderFactory {
    static func makeCapability() -> EmailSummaryCapability {
#if canImport(FoundationModels)
        if #available(macOS 15.2, *) {
            let model = FoundationModels.SystemLanguageModel.default
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
final class FoundationModelsEmailSummaryProvider: EmailSummaryProviding {
    private let model: SystemLanguageModel

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    func summarize(subjects: [String]) async throws -> String {
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

    private static func prompt(for subjects: [String]) -> String {
        let bullets = subjects.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return """
        Summarize the following email subject lines into at most two concise sentences.
        Highlight the main themes and call out any urgent follow ups that may require attention.
        Keep the tone professional and actionable.

        Subjects:
        \(bullets)
        """
    }

    private static let instructions = """
    You are an organized executive assistant reviewing an email inbox.
    Provide short plain-language digests that help the user understand what to focus on.
    Avoid bullet lists and instead write one or two compact sentences.
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
