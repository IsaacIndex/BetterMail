import Combine
import Foundation

@MainActor
internal final class GraphAutomationSettings: ObservableObject {
    private enum StorageKey {
        static let paused = "graphAutomationPaused"
        static let attachMode = "graphAutomationAttachMode"
        static let appendMode = "graphAutomationAppendMode"
        static let attachStrictness = "graphAutomationAttachStrictness"
        static let appendStrictness = "graphAutomationAppendStrictness"
        static let followsFolderMailboxMapping = "graphAutomationFollowsFolderMailboxMapping"
    }

    @Published internal var isPaused: Bool {
        didSet { userDefaults.set(isPaused, forKey: StorageKey.paused) }
    }
    @Published internal var attachMode: GraphAutomationMode {
        didSet { userDefaults.set(attachMode.rawValue, forKey: StorageKey.attachMode) }
    }
    @Published internal var appendMode: GraphAutomationMode {
        didSet { userDefaults.set(appendMode.rawValue, forKey: StorageKey.appendMode) }
    }
    @Published internal var attachStrictness: GraphAutomationStrictness {
        didSet { userDefaults.set(attachStrictness.rawValue, forKey: StorageKey.attachStrictness) }
    }
    @Published internal var appendStrictness: GraphAutomationStrictness {
        didSet { userDefaults.set(appendStrictness.rawValue, forKey: StorageKey.appendStrictness) }
    }
    @Published internal var followsFolderMailboxMapping: Bool {
        didSet { userDefaults.set(followsFolderMailboxMapping, forKey: StorageKey.followsFolderMailboxMapping) }
    }

    private let userDefaults: UserDefaults

    internal init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isPaused = userDefaults.object(forKey: StorageKey.paused) as? Bool ?? false
        attachMode = GraphAutomationMode(
            rawValue: userDefaults.string(forKey: StorageKey.attachMode) ?? ""
        ) ?? .automatic
        appendMode = GraphAutomationMode(
            rawValue: userDefaults.string(forKey: StorageKey.appendMode) ?? ""
        ) ?? .automatic
        attachStrictness = GraphAutomationStrictness(
            rawValue: userDefaults.string(forKey: StorageKey.attachStrictness) ?? ""
        ) ?? .conservative
        appendStrictness = GraphAutomationStrictness(
            rawValue: userDefaults.string(forKey: StorageKey.appendStrictness) ?? ""
        ) ?? .conservative
        followsFolderMailboxMapping = userDefaults.object(forKey: StorageKey.followsFolderMailboxMapping) as? Bool ?? true
    }

    internal func mode(for action: GraphAutomationAction) -> GraphAutomationMode {
        switch action {
        case .attachToThread: attachMode
        case .appendToFolder: appendMode
        }
    }

    internal func strictness(for action: GraphAutomationAction) -> GraphAutomationStrictness {
        switch action {
        case .attachToThread: attachStrictness
        case .appendToFolder: appendStrictness
        }
    }

    internal func automaticThreshold(for action: GraphAutomationAction) -> Double {
        let thresholds = strictness(for: action).thresholds
        switch action {
        case .attachToThread:
            return thresholds.autoAttach
        case .appendToFolder:
            return thresholds.autoFolder
        }
    }
}
