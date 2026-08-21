import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

internal enum GraphRelationshipError: LocalizedError {
    case noContent
    case unavailable(String)
    case invalidResponse
    case generationFailed(Error)

    internal var errorDescription: String? {
        switch self {
        case .noContent:
            return NSLocalizedString("graph.automation.error.no_content",
                                     comment: "Automation relationship request has no content")
        case .unavailable(let reason):
            return reason
        case .invalidResponse:
            return NSLocalizedString("graph.automation.error.invalid_response",
                                     comment: "Automation relationship provider returned invalid content")
        case .generationFailed(let error):
            return String.localizedStringWithFormat(
                NSLocalizedString("graph.automation.error.generation_failed",
                                  comment: "Automation relationship provider failed"),
                error.localizedDescription
            )
        }
    }
}

internal protocol GraphRelationshipProviding {
    func relationship(for request: GraphAutomationRelationshipRequest) async throws -> GraphAutomationRelationshipSignal
}

internal struct GraphRelationshipCapability {
    internal let provider: GraphRelationshipProviding?
    internal let providerVersion: String
    internal let statusMessage: String
    internal let shouldRetry: Bool
}

internal enum GraphRelationshipProviderFactory {
    internal static let providerVersion = "foundation-models-graph-relationship-v2"

    internal static func makeCapability() -> GraphRelationshipCapability {
#if canImport(FoundationModels)
        if #available(macOS 15.2, *) {
            let model = FoundationModelsSupport.makeDefaultModel()
            switch model.availability {
            case .available:
                return GraphRelationshipCapability(
                    provider: FoundationModelsGraphRelationshipProvider(model: model),
                    providerVersion: providerVersion,
                    statusMessage: NSLocalizedString("graph.automation.provider.ready",
                                                     comment: "Automation relationship provider ready"),
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
                return GraphRelationshipCapability(provider: nil,
                                                   providerVersion: providerVersion,
                                                   statusMessage: unavailableMessage(for: reason),
                                                   shouldRetry: shouldRetry)
            }
        }
#endif
        return GraphRelationshipCapability(
            provider: nil,
            providerVersion: providerVersion,
            statusMessage: NSLocalizedString("graph.automation.provider.requires_compatible_mac",
                                             comment: "Automation relationship provider hardware requirement"),
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
            return NSLocalizedString("graph.automation.provider.device_not_eligible",
                                     comment: "Mac is not eligible for graph automation")
        case .appleIntelligenceNotEnabled:
            return NSLocalizedString("graph.automation.provider.intelligence_disabled",
                                     comment: "Apple Intelligence is disabled for graph automation")
        case .modelNotReady:
            return NSLocalizedString("graph.automation.provider.model_not_ready",
                                     comment: "Graph automation model is preparing")
        @unknown default:
            return NSLocalizedString("graph.automation.provider.unavailable",
                                     comment: "Graph automation provider is unavailable")
        }
    }
#endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable(description: "A conservative relationship between new email and an existing thread or confirmed folder profile.")
private struct GeneratedGraphRelationship {
    @Guide(description: "Use sameConversation only for the same named topic and concrete action; sameTopic for a distinct action under the same broader topic; otherwise unrelated.",
           .anyOf(["sameConversation", "sameTopic", "unrelated"]))
    var relationship: String

    @Guide(description: "Confidence from zero to one.", .range(0.0...1.0))
    var confidence: Double

    @Guide(description: "Specific shared project, customer, product, event, team, person, incident, or deliverable names.",
           .maximumCount(8))
    var sharedAnchors: [String]

    @Guide(description: "True only when both sides share a specific named topic.")
    var sharedNamedTopic: Bool

    @Guide(description: "True only when both sides concern the same concrete action, invitation, request, decision, incident, event, or deliverable.")
    var sameActionOrEvent: Bool

    @Guide(description: "A short user-facing explanation grounded in the supplied email evidence.")
    var reason: String
}

@available(macOS 15.2, *)
internal final class FoundationModelsGraphRelationshipProvider: GraphRelationshipProviding {
    private let model: SystemLanguageModel

    internal init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    internal func relationship(
        for request: GraphAutomationRelationshipRequest
    ) async throws -> GraphAutomationRelationshipSignal {
        guard case .available = model.availability else {
            throw GraphRelationshipError.unavailable(
                NSLocalizedString("graph.automation.provider.unavailable",
                                  comment: "Graph automation provider is unavailable")
            )
        }
        guard Self.hasContent(request) else { throw GraphRelationshipError.noContent }

        do {
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            var options = GenerationOptions()
            options.temperature = 0.05
            options.maximumResponseTokens = 260
            if #available(macOS 26.0, *) {
                let response = try await session.respond(
                    to: Self.prompt(for: request),
                    generating: GeneratedGraphRelationship.self,
                    options: options
                )
                return try Self.signal(from: response.content)
            }
            let response = try await session.respond(to: Self.prompt(for: request), options: options)
            return try Self.parse(response.content)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GraphRelationshipError {
            throw error
        } catch {
            throw GraphRelationshipError.generationFailed(error)
        }
    }

    private static let instructions = """
    Compare the supplied email source with one existing email thread or confirmed folder profile.

    Classify exactly one relationship:
    - sameConversation: the mail concerns the same named topic AND the same concrete action, invitation, request, decision, incident, event, or deliverable. Similar organizations or broad projects alone are insufficient.
    - sameTopic: the mail belongs under the same broader named topic but is a distinct conversation or action.
    - unrelated: the evidence does not establish either relationship.

    Be conservative. A folder profile can be sameTopic but cannot by itself prove sameConversation. List only specific shared anchors such as project, customer, product, event, team, person, incident, or deliverable names. The reason must be short and user-facing. Do not mention models, prompts, tokens, or internal analysis.

    Return JSON only with exactly these keys:
    {"relationship":"sameConversation|sameTopic|unrelated","confidence":0.0,"sharedAnchors":["anchor"],"sharedNamedTopic":true,"sameActionOrEvent":true,"reason":"Concise reason"}
    """

    private static func hasContent(_ request: GraphAutomationRelationshipRequest) -> Bool {
        !request.sourceSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !request.sourceSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !request.sourceContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func prompt(for request: GraphAutomationRelationshipRequest) -> String {
        """
        Source subject: \(bounded(request.sourceSubject, 240))
        Source summary: \(bounded(request.sourceSummary, 900))
        Source content: \(bounded(request.sourceContent, 2_000))

        Target kind: \(request.targetIsFolderProfile ? "confirmed folder profile" : "existing email thread")
        Target title: \(bounded(request.targetTitle, 240))
        Target summary: \(bounded(request.targetSummary, 1_200))
        Target content: \(bounded(request.targetContent, 2_000))
        """
    }

    private static func parse(_ response: String) throws -> GraphAutomationRelationshipSignal {
        guard let openingBrace = response.firstIndex(of: "{"),
              let closingBrace = response.lastIndex(of: "}"),
              openingBrace <= closingBrace,
              let data = String(response[openingBrace...closingBrace]).data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRelationship = payload["relationship"] as? String,
              let relationship = GraphAutomationRelationship(rawValue: rawRelationship) else {
            throw GraphRelationshipError.invalidResponse
        }
        let confidence = (payload["confidence"] as? NSNumber)?.doubleValue ?? 0
        let anchors = payload["sharedAnchors"] as? [String] ?? []
        let namedTopic = (payload["sharedNamedTopic"] as? NSNumber)?.boolValue ?? false
        let sameAction = (payload["sameActionOrEvent"] as? NSNumber)?.boolValue ?? false
        let reason = payload["reason"] as? String ?? ""
        return GraphAutomationRelationshipSignal(
            relationship: relationship,
            confidence: confidence,
            sharedAnchors: anchors,
            hasSharedNamedTopic: namedTopic,
            hasSameConcreteActionOrEvent: sameAction,
            reason: reason
        )
    }

    @available(macOS 26.0, *)
    private static func signal(
        from response: GeneratedGraphRelationship
    ) throws -> GraphAutomationRelationshipSignal {
        guard let relationship = GraphAutomationRelationship(rawValue: response.relationship) else {
            throw GraphRelationshipError.invalidResponse
        }
        return GraphAutomationRelationshipSignal(
            relationship: relationship,
            confidence: response.confidence,
            sharedAnchors: response.sharedAnchors,
            hasSharedNamedTopic: response.sharedNamedTopic,
            hasSameConcreteActionOrEvent: response.sameActionOrEvent,
            reason: response.reason
        )
    }

    private static func bounded(_ value: String, _ maximumCharacterCount: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumCharacterCount))
    }
}
#endif
