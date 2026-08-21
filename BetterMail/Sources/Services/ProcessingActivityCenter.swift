import Combine
import Foundation

internal typealias ProcessingActivityID = String

internal enum ProcessingActivityKind: String {
    case refresh
    case importing
    case generation
    case mailbox
    case maintenance

    internal var localizedTitle: String {
        switch self {
        case .refresh:
            return NSLocalizedString("activity.kind.refresh", comment: "Processing activity kind for refresh work")
        case .importing:
            return NSLocalizedString("activity.kind.import", comment: "Processing activity kind for import work")
        case .generation:
            return NSLocalizedString("activity.kind.generation", comment: "Processing activity kind for generation work")
        case .mailbox:
            return NSLocalizedString("activity.kind.mailbox", comment: "Processing activity kind for mailbox work")
        case .maintenance:
            return NSLocalizedString("activity.kind.maintenance", comment: "Processing activity kind for maintenance work")
        }
    }

    internal var systemImage: String {
        switch self {
        case .refresh:
            return "arrow.clockwise"
        case .importing:
            return "tray.and.arrow.down"
        case .generation:
            return "sparkles"
        case .mailbox:
            return "mail.stack"
        case .maintenance:
            return "hammer"
        }
    }
}

internal enum ProcessingActivityState: String {
    case running
    case completed
    case failed
    case cancelled

    internal var isActive: Bool {
        self == .running
    }

    internal var localizedTitle: String {
        switch self {
        case .running:
            return NSLocalizedString("activity.state.running", comment: "Running processing activity state")
        case .completed:
            return NSLocalizedString("activity.state.completed", comment: "Completed processing activity state")
        case .failed:
            return NSLocalizedString("activity.state.failed", comment: "Failed processing activity state")
        case .cancelled:
            return NSLocalizedString("activity.state.cancelled", comment: "Cancelled processing activity state")
        }
    }
}

internal struct ProcessingActivity: Identifiable, Equatable {
    internal let id: ProcessingActivityID
    internal var title: String
    internal var detail: String?
    internal var kind: ProcessingActivityKind
    internal var state: ProcessingActivityState
    internal var progress: Double?
    internal var startedAt: Date
    internal var updatedAt: Date
    internal var finishedAt: Date?

    internal var isActive: Bool {
        state.isActive
    }
}

internal enum ProcessingActivityShelfPolicy {
    internal static let displayDuration: TimeInterval = 4
    internal static let displayDurationNanoseconds: UInt64 = 4_000_000_000

    internal static func activity(from activities: [ProcessingActivity], at date: Date) -> ProcessingActivity? {
        let visibleActiveActivity = activities
            .filter { activity in
                activity.isActive && isWithinDisplayWindow(referenceDate: activity.startedAt, at: date)
            }
            .sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
            .first

        if let visibleActiveActivity {
            return visibleActiveActivity
        }

        return activities
            .filter { activity in
                guard !activity.isActive else { return false }
                return isWithinDisplayWindow(referenceDate: activity.finishedAt ?? activity.updatedAt, at: date)
            }
            .sorted { lhs, rhs in
                (lhs.finishedAt ?? lhs.updatedAt) > (rhs.finishedAt ?? rhs.updatedAt)
            }
            .first
    }

    private static func isWithinDisplayWindow(referenceDate: Date, at date: Date) -> Bool {
        date < referenceDate.addingTimeInterval(displayDuration)
    }
}

@MainActor
internal final class ProcessingActivityCenter: ObservableObject {
    @Published internal private(set) var activities: [ProcessingActivity] = []
    @Published internal private(set) var shelfPresentationVersion = 0

    private let retainedActivityCount = 12

    internal var activeActivities: [ProcessingActivity] {
        activities
            .filter(\.isActive)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    internal var visibleActivities: [ProcessingActivity] {
        activities
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(retainedActivityCount)
            .map { $0 }
    }

    internal var primaryActivity: ProcessingActivity? {
        activeActivities.first ?? visibleActivities.first
    }

    internal var activeCount: Int {
        activeActivities.count
    }

    internal var hasActiveActivity: Bool {
        activeCount > 0
    }

    internal func shelfActivity(at date: Date = Date()) -> ProcessingActivity? {
        ProcessingActivityShelfPolicy.activity(from: activities, at: date)
    }

    @discardableResult
    internal func begin(id: ProcessingActivityID = UUID().uuidString,
                        title: String,
                        detail: String? = nil,
                        kind: ProcessingActivityKind,
                        progress: Double? = nil,
                        date: Date = Date()) -> ProcessingActivityID {
        let normalizedProgress = Self.normalizedProgress(progress)
        if let existingIndex = activities.firstIndex(where: { $0.id == id }) {
            activities[existingIndex].title = title
            activities[existingIndex].detail = detail
            activities[existingIndex].kind = kind
            activities[existingIndex].state = .running
            activities[existingIndex].progress = normalizedProgress
            activities[existingIndex].startedAt = date
            activities[existingIndex].updatedAt = date
            activities[existingIndex].finishedAt = nil
        } else {
            activities.append(ProcessingActivity(id: id,
                                                 title: title,
                                                 detail: detail,
                                                 kind: kind,
                                                 state: .running,
                                                 progress: normalizedProgress,
                                                 startedAt: date,
                                                 updatedAt: date,
                                                 finishedAt: nil))
        }
        pruneFinishedActivities()
        advanceShelfPresentationVersion()
        return id
    }

    internal func update(_ id: ProcessingActivityID,
                         title: String? = nil,
                         detail: String? = nil,
                         progress: Double? = nil,
                         date: Date = Date()) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        if let title {
            activities[index].title = title
        }
        if let detail {
            activities[index].detail = detail
        }
        activities[index].progress = Self.normalizedProgress(progress)
        activities[index].updatedAt = date
    }

    internal func finish(_ id: ProcessingActivityID?,
                         state: ProcessingActivityState = .completed,
                         detail: String? = nil,
                         date: Date = Date()) {
        guard let id,
              let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].state = state
        if let detail {
            activities[index].detail = detail
        }
        activities[index].progress = state == .completed ? 1.0 : activities[index].progress
        activities[index].updatedAt = date
        activities[index].finishedAt = date
        pruneFinishedActivities()
        advanceShelfPresentationVersion()
    }

    private func pruneFinishedActivities() {
        let active = activities.filter(\.isActive)
        let finished = activities
            .filter { !$0.isActive }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(retainedActivityCount)
        activities = active + finished
    }

    private func advanceShelfPresentationVersion() {
        shelfPresentationVersion &+= 1
    }

    private static func normalizedProgress(_ progress: Double?) -> Double? {
        guard let progress, progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }
}
