import Foundation

final class ThreadMergeDecisionStore {
    private let defaults: UserDefaults
    private let key = "ThreadMergeDecisions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func decision(for threadID: String) -> ThreadGroup.MergeState? {
        guard let raw = stored()[threadID],
              let state = ThreadGroup.MergeState(rawValue: raw) else {
            return nil
        }
        return state
    }

    func setDecision(_ state: ThreadGroup.MergeState?, for threadID: String) {
        var map = stored()
        if let state {
            map[threadID] = state.rawValue
        } else {
            map.removeValue(forKey: threadID)
        }
        defaults.set(map, forKey: key)
    }

    func allDecisions() -> [String: ThreadGroup.MergeState] {
        var results: [String: ThreadGroup.MergeState] = [:]
        for (key, value) in stored() {
            if let state = ThreadGroup.MergeState(rawValue: value) {
                results[key] = state
            }
        }
        return results
    }

    private func stored() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
