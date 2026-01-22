import CryptoKit
import Foundation

enum ThreadSummaryFingerprint {
    static func make(subjects: [String], messageCount: Int, manualGroupID: String?) -> String {
        let components = subjects + ["count:\(messageCount)", "group:\(manualGroupID ?? "")"]
        return sha256Hex(components.joined(separator: "|"))
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
