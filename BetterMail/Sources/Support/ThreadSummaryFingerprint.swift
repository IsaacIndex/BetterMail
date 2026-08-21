import CryptoKit
import Foundation

internal nonisolated enum ThreadSummaryFingerprint {
    internal static let nodePromptVersion = "node-summary-context-v2"

    internal static func make(subjects: [String], messageCount: Int, manualGroupID: String?) -> String {
        let components = subjects + ["count:\(messageCount)", "group:\(manualGroupID ?? "")"]
        return sha256Hex(components.joined(separator: "|"))
    }

    internal static func makeThreadRevision(entries: [ThreadSummaryRevisionEntry]) -> String {
        let components = ["version:effective-thread-revision-v1"] + entries.map {
            [
                $0.messageID,
                String($0.date.timeIntervalSinceReferenceDate),
                $0.subject,
                $0.body,
                $0.automaticThreadID,
                $0.isManualAttachment ? "manual-attachment" : "thread-member"
            ].joined(separator: "|")
        }
        return sha256Hex(components.joined(separator: "|"))
    }

    internal static func makeNode(subject: String,
                                  body: String,
                                  threadRevision: String,
                                  context: EmailSummaryThreadContext,
                                  providerID: String) -> String {
        let neighbourComponents = context.neighbours.map {
            [
                $0.direction.rawValue,
                $0.relationship.rawValue,
                $0.messageID,
                $0.subject,
                $0.bodySnippet
            ].joined(separator: "|")
        }
        let components = [
            "version:\(nodePromptVersion)",
            "provider:\(providerID)",
            "thread:\(threadRevision)",
            "position:\(context.position)/\(context.totalMessages)",
            "subject:\(subject)",
            "body:\(body)"
        ] + neighbourComponents
        return sha256Hex(components.joined(separator: "|"))
    }

    internal static func makeFolder(title: String = "",
                                    nodeEntries: [FolderSummaryFingerprintEntry],
                                    providerID: String = "") -> String {
        let components = [
            "version:folder-summary-v2",
            "provider:\(providerID)",
            "title:\(title)"
        ] + nodeEntries.map { "\($0.nodeID)|\($0.nodeFingerprint)" }
        return sha256Hex(components.joined(separator: "|"))
    }

    internal static func makeTags(subject: String, from: String, snippet: String, providerID: String) -> String {
        let components = ["subject:\(subject)", "from:\(from)", "snippet:\(snippet)", "provider:\(providerID)"]
        return sha256Hex(components.joined(separator: "|"))
    }

    internal static func makeGraphTitle(subject: String,
                                        summary: String,
                                        summaryGenerationID: String? = nil,
                                        threadRevision: String,
                                        context: EmailSummaryThreadContext,
                                        providerID: String) -> String {
        let neighbourComponents = context.neighbours.map {
            [
                $0.direction.rawValue,
                $0.relationship.rawValue,
                $0.messageID,
                $0.subject,
                $0.bodySnippet
            ].joined(separator: "|")
        }
        let components = [
            "version:graph-title-v5",
            "prompt:\(GraphTitlePromptBuilder.promptVersion)",
            "thread:\(threadRevision)",
            "position:\(context.position)/\(context.totalMessages)",
            "subject:\(subject)",
            "summary:\(summary)",
            "summary-generation:\(summaryGenerationID ?? "")",
            "provider:\(providerID)"
        ] + neighbourComponents
        return sha256Hex(components.joined(separator: "|"))
    }

    internal static func makeGraphTopic(subject: String,
                                        threadSummary: String,
                                        representativeContent: String,
                                        providerID: String) -> String {
        let components = [
            "version:graph-topic-v1",
            "subject:\(subject)",
            "summary:\(threadSummary)",
            "content:\(representativeContent)",
            "provider:\(providerID)"
        ]
        return sha256Hex(components.joined(separator: "|"))
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

internal nonisolated struct ThreadSummaryRevisionEntry: Hashable, Sendable {
    internal let messageID: String
    internal let subject: String
    internal let body: String
    internal let date: Date
    internal let automaticThreadID: String
    internal let isManualAttachment: Bool
}

internal nonisolated struct FolderSummaryFingerprintEntry: Hashable, Sendable {
    internal let nodeID: String
    internal let nodeFingerprint: String
}
