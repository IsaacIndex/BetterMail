import Combine
import Foundation
import SwiftUI

@MainActor
internal final class InspectorViewSettings: ObservableObject {
    internal static let minimumSnippetLineLimit = 1
    internal static let maximumSnippetLineLimit = Int.max
    internal static let defaultSnippetLineLimit = 10

    @AppStorage("inspectorSnippetLineLimit") private var storedSnippetLineLimit = InspectorViewSettings.defaultSnippetLineLimit
    @AppStorage("inspectorSnippetStopWords") private var storedStopPhrases = ""

    @Published internal var snippetLineLimit: Int = InspectorViewSettings.defaultSnippetLineLimit {
        didSet {
            let clamped = Self.clampLineLimit(snippetLineLimit)
            if clamped != snippetLineLimit {
                snippetLineLimit = clamped
                return
            }
            storedSnippetLineLimit = clamped
        }
    }

    @Published internal var stopPhrasesText: String = "" {
        didSet {
            storedStopPhrases = stopPhrasesText
        }
    }

    internal init() {
        let normalized = Self.clampLineLimit(_storedSnippetLineLimit.wrappedValue)
        storedSnippetLineLimit = normalized
        snippetLineLimit = normalized
        stopPhrasesText = _storedStopPhrases.wrappedValue
    }

    internal var stopPhrases: [String] {
        let phrases = stopPhrasesText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return phrases
    }

    private static func clampLineLimit(_ value: Int) -> Int {
        max(value, minimumSnippetLineLimit)
    }
}
