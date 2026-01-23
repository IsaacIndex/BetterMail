import CryptoKit
import Foundation

enum ThreadSummaryFingerprint {
    static func make(subjects: [String], messageCount: Int, manualGroupID: String?) -> String {
        let components = subjects + ["count:\(messageCount)", "group:\(manualGroupID ?? "")"]
        return sha256Hex(components.joined(separator: "|"))
    }

    static func makeNode(subject: String, body: String, priorEntries: [NodeSummaryFingerprintEntry]) -> String {
        let priorComponents = priorEntries.map { "\($0.messageID)|\($0.subject)|\($0.bodySnippet)" }
        let components = ["subject:\(subject)", "body:\(body)"] + priorComponents
        return sha256Hex(components.joined(separator: "|"))
    }

    static func makeFolder(nodeEntries: [FolderSummaryFingerprintEntry]) -> String {
        let components = nodeEntries.map { "\($0.nodeID)|\($0.nodeFingerprint)" }
        return sha256Hex(components.joined(separator: "|"))
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct NodeSummaryFingerprintEntry: Hashable {
    let messageID: String
    let subject: String
    let bodySnippet: String
}

struct FolderSummaryFingerprintEntry: Hashable {
    let nodeID: String
    let nodeFingerprint: String
}
