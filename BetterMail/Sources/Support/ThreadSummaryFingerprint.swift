import CryptoKit
import Foundation

internal enum ThreadSummaryFingerprint {
    internal static func make(subjects: [String], messageCount: Int, manualGroupID: String?) -> String {
        let components = subjects + ["count:\(messageCount)", "group:\(manualGroupID ?? "")"]
        return sha256Hex(components.joined(separator: "|"))
    }

    internal static func makeNode(subject: String, body: String, priorEntries: [NodeSummaryFingerprintEntry]) -> String {
        let priorComponents = priorEntries.map { "\($0.messageID)|\($0.subject)|\($0.bodySnippet)" }
        let components = ["subject:\(subject)", "body:\(body)"] + priorComponents
        return sha256Hex(components.joined(separator: "|"))
    }

    internal static func makeFolder(nodeEntries: [FolderSummaryFingerprintEntry]) -> String {
        let components = nodeEntries.map { "\($0.nodeID)|\($0.nodeFingerprint)" }
        return sha256Hex(components.joined(separator: "|"))
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

internal struct NodeSummaryFingerprintEntry: Hashable {
    internal let messageID: String
    internal let subject: String
    internal let bodySnippet: String
}

internal struct FolderSummaryFingerprintEntry: Hashable {
    internal let nodeID: String
    internal let nodeFingerprint: String
}
