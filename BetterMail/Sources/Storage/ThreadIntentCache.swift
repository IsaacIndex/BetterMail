import Foundation

actor ThreadIntentCache {
    struct Record: Codable {
        let threadID: String
        var summary: String
        var topicTag: String?
        var intentSignals: ThreadIntentSignals
        var badges: [ThreadBadge]
        var lastUpdated: Date
    }

    private var records: [String: Record] = [:]
    private let storeURL: URL

    init(filename: String = "intent-annotations.json") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
            .appendingPathComponent("BetterMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        storeURL = appSupport.appendingPathComponent(filename)
        loadFromDisk()
    }

    func record(for threadID: String) -> Record? {
        records[threadID]
    }

    func upsert(_ record: Record) {
        records[record.threadID] = record
        saveToDisk()
    }

    func removeAll() {
        records.removeAll()
        saveToDisk()
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode([String: Record].self, from: data)
            records = decoded
        } catch {
            records = [:]
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            // best-effort cache; ignore errors
        }
    }
}
