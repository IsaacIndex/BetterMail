import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 15.2, *)
internal enum FoundationModelsSupport {
    static func makeDefaultModel() -> SystemLanguageModel {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel(guardrails: .permissiveContentTransformations)
        }
        return .default
    }
}
#endif
