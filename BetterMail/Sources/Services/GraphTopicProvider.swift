import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

internal enum GraphTopicError: LocalizedError {
    case noContent
    case unavailable(String)
    case invalidResponse
    case generationFailed(Error)

    internal var errorDescription: String? {
        switch self {
        case .noContent:
            return NSLocalizedString("graph.topic.error.no_content",
                                     comment: "Graph topic generation has no conversation content")
        case .unavailable(let reason):
            return reason
        case .invalidResponse:
            return NSLocalizedString("graph.topic.error.invalid_response",
                                     comment: "Graph topic generation returned unusable content")
        case .generationFailed(let error):
            return String.localizedStringWithFormat(
                NSLocalizedString("graph.topic.error.generation_failed",
                                  comment: "Graph topic generation failure with underlying error"),
                error.localizedDescription
            )
        }
    }
}

internal protocol GraphTopicProviding {
    /// Returns one specific signal for the whole conversation, or `nil` when
    /// the evidence is too generic to support a folder suggestion.
    func generateTopic(_ request: GraphTopicRequest) async throws -> GraphTopicSignal?
}

internal struct GraphTopicCapability {
    internal let provider: GraphTopicProviding?
    internal let statusMessage: String
    internal let providerID: String
    internal let shouldRetry: Bool
}

internal struct GraphTopicRequest: Hashable {
    internal let subject: String
    internal let threadSummary: String
    internal let representativeContent: String

    internal var hasContent: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !threadSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !representativeContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

internal struct GraphTopicCacheRecord: Codable, Hashable {
    internal let signal: GraphTopicSignal?
}

internal enum GraphTopicProviderFactory {
    internal static func makeCapability() -> GraphTopicCapability {
#if canImport(FoundationModels)
        if #available(macOS 15.2, *) {
            let model = FoundationModelsSupport.makeDefaultModel()
            switch model.availability {
            case .available:
                return GraphTopicCapability(
                    provider: FoundationModelsGraphTopicProvider(model: model),
                    statusMessage: NSLocalizedString("graph.topic.status.ready",
                                                     comment: "Graph topic provider ready status"),
                    providerID: "foundation-models-graph-topic-v1",
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
                return GraphTopicCapability(
                    provider: nil,
                    statusMessage: unavailableMessage(for: reason),
                    providerID: "foundation-models-graph-topic-v1",
                    shouldRetry: shouldRetry
                )
            }
        }
#endif
        return GraphTopicCapability(
            provider: nil,
            statusMessage: NSLocalizedString("graph.topic.status.requires_compatible_mac",
                                             comment: "Graph topic provider hardware requirement"),
            providerID: "foundation-models-graph-topic-v1",
            shouldRetry: false
        )
    }

#if canImport(FoundationModels)
    @available(macOS 15.2, *)
    private static func unavailableMessage(
        for reason: FoundationModels.SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return NSLocalizedString("graph.topic.status.device_not_eligible",
                                     comment: "Mac is not eligible for graph topics")
        case .appleIntelligenceNotEnabled:
            return NSLocalizedString("graph.topic.status.intelligence_disabled",
                                     comment: "Apple Intelligence is disabled for graph topics")
        case .modelNotReady:
            return NSLocalizedString("graph.topic.status.model_not_ready",
                                     comment: "Graph topic model is preparing")
        @unknown default:
            return NSLocalizedString("graph.topic.status.unavailable",
                                     comment: "Graph topic provider generic unavailable status")
        }
    }
#endif
}

#if canImport(FoundationModels)
@available(macOS 15.2, *)
internal final class FoundationModelsGraphTopicProvider: GraphTopicProviding {
    private let model: SystemLanguageModel

    internal init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    internal func generateTopic(_ request: GraphTopicRequest) async throws -> GraphTopicSignal? {
        guard case .available = model.availability else {
            throw GraphTopicError.unavailable(
                NSLocalizedString("graph.topic.status.unavailable",
                                  comment: "Graph topic provider generic unavailable status")
            )
        }
        guard request.hasContent else {
            throw GraphTopicError.noContent
        }

        do {
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            var options = GenerationOptions()
            options.temperature = 0.1
            options.maximumResponseTokens = 180
            let response = try await session.respond(to: Self.prompt(for: request), options: options)
            return try Self.parseSignal(from: response.content)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GraphTopicError {
            throw error
        } catch {
            throw GraphTopicError.generationFailed(error)
        }
    }

    private static let instructions = """
    Analyze one complete email conversation using only the supplied subject, conversation summary, and representative content.

    Return at most one specific, reusable topic that could connect this conversation to other conversations. Prefer named projects, products, customers, change requests, incidents, rollouts, systems, or events. Never use a generic workflow label such as Update, Review, Meeting, Status, Request, or Follow up.

    If there is no specific supported topic, return an empty topic and confidence 0.
    The reason must be a short user-facing explanation grounded in the supplied conversation. Do not mention prompts, tokens, confidence scores, models, or internal analysis.

    Return JSON only with exactly these keys:
    {"topic":"normalized topic","displayTitle":"Readable topic","confidence":0.0,"reason":"Concise supporting reason"}
    """

    private static func prompt(for request: GraphTopicRequest) -> String {
        let subject = bounded(request.subject, maximumCharacterCount: 240)
        let summary = bounded(request.threadSummary, maximumCharacterCount: 1_000)
        let content = bounded(request.representativeContent, maximumCharacterCount: 2_400)
        return """
        Subject: \(subject.isEmpty ? "No subject" : subject)
        Conversation summary: \(summary.isEmpty ? "No summary" : summary)
        Representative conversation content:
        \(content.isEmpty ? "No representative content" : content)
        """
    }

    private static func parseSignal(from response: String) throws -> GraphTopicSignal? {
        guard let openingBrace = response.firstIndex(of: "{"),
              let closingBrace = response.lastIndex(of: "}"),
              openingBrace <= closingBrace else {
            throw GraphTopicError.invalidResponse
        }
        let json = String(response[openingBrace...closingBrace])
        guard let data = json.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GraphTopicError.invalidResponse
        }

        let topic = payload["topic"] as? String ?? ""
        let displayTitle = payload["displayTitle"] as? String ?? topic
        let reason = payload["reason"] as? String ?? ""
        let confidence = (payload["confidence"] as? NSNumber)?.doubleValue ?? 0
        guard !GraphTopicNormalizer.normalize(topic).isEmpty else { return nil }

        let signal = GraphTopicSignal(topic: topic,
                                      displayTitle: displayTitle,
                                      confidence: confidence,
                                      supportingReason: reason)
        return signal.isUsable ? signal : nil
    }

    private static func bounded(_ value: String, maximumCharacterCount: Int) -> String {
        String(value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximumCharacterCount))
    }
}
#endif
