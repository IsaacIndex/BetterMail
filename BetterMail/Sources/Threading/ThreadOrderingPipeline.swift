import Foundation

struct ThreadOrderingPipeline {
    func ordered(groups: [ThreadGroup],
                 pins: Set<String>) -> [ThreadGroup] {
        groups.sorted { lhs, rhs in
            let lhsPinned = pins.contains(lhs.id)
            let rhsPinned = pins.contains(rhs.id)
            if lhsPinned != rhsPinned {
                return lhsPinned
            }
            let lhsScore = priorityScore(for: lhs)
            let rhsScore = priorityScore(for: rhs)
            if lhsScore == rhsScore {
                return lhs.chronologicalIndex < rhs.chronologicalIndex
            }
            return lhsScore > rhsScore
        }
    }

    private func priorityScore(for group: ThreadGroup) -> Double {
        var score = group.intentSignals.intentRelevance * 0.2
        score += group.intentSignals.urgencyScore * 0.4
        score += group.intentSignals.personalPriorityScore * 0.25
        score += group.intentSignals.timelinessScore * 0.15
        if group.hasActiveTask {
            score += 0.1
        }
        if group.isWaitingOnMe {
            score += 0.15
        }
        return score
    }
}
