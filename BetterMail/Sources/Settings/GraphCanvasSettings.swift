import Combine
import Foundation
import SwiftUI

internal enum GraphCanvasMode: String, CaseIterable, Identifiable {
    case timeline
    case graph

    internal var id: String { rawValue }

    internal var localizedTitle: String {
        switch self {
        case .timeline:
            return NSLocalizedString("graph.mode.timeline", comment: "Timeline graph mode segment")
        case .graph:
            return NSLocalizedString("graph.mode.graph", comment: "Graph graph mode segment")
        }
    }
}

internal enum GraphCanvasVariant: String, CaseIterable {
    case botanical
}

internal enum GraphReduceMotionOverride: String, CaseIterable, Identifiable {
    case system
    case reduce
    case full

    internal var id: String { rawValue }

    internal var localizedTitle: String {
        switch self {
        case .system:
            return NSLocalizedString("graph.settings.motion.system", comment: "Use system reduce motion setting")
        case .reduce:
            return NSLocalizedString("graph.settings.motion.reduce", comment: "Always reduce graph motion")
        case .full:
            return NSLocalizedString("graph.settings.motion.full", comment: "Always allow graph motion")
        }
    }
}

@MainActor
internal final class GraphCanvasSettings: ObservableObject {
    private enum StorageKey {
        static let mode = "graphCanvasMode"
        static let variant = "graphCanvasVariant"
        static let soundOn = "graphCanvasSoundOn"
        static let reduceMotionOverride = "graphCanvasReduceMotionOverride"
        static let snipParentMailboxPath = "graphCanvasSnipParentMailboxPath"
        static let wateredCounts = "graphCanvasWateredCounts"
    }

    @AppStorage(StorageKey.mode) private var storedMode = GraphCanvasMode.timeline.rawValue
    @AppStorage(StorageKey.variant) private var storedVariant = GraphCanvasVariant.botanical.rawValue
    @AppStorage(StorageKey.soundOn) private var storedSoundOn = false
    @AppStorage(StorageKey.reduceMotionOverride) private var storedReduceMotionOverride = GraphReduceMotionOverride.system.rawValue
    @AppStorage(StorageKey.snipParentMailboxPath) private var storedSnipParentMailboxPath = "Unimportant"

    @Published internal var mode: GraphCanvasMode = .timeline {
        didSet { storedMode = mode.rawValue }
    }
    @Published internal var variant: GraphCanvasVariant = .botanical {
        didSet { storedVariant = variant.rawValue }
    }
    @Published internal var soundOn: Bool = false {
        didSet { storedSoundOn = soundOn }
    }
    @Published internal var reduceMotionOverride: GraphReduceMotionOverride = .system {
        didSet { storedReduceMotionOverride = reduceMotionOverride.rawValue }
    }
    @Published internal var snipParentMailboxPath: String = "Unimportant" {
        didSet { storedSnipParentMailboxPath = snipParentMailboxPath }
    }
    @Published internal private(set) var wateredCounts: [String: Int] = [:]

    private let userDefaults: UserDefaults

    internal init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        mode = GraphCanvasMode(rawValue: storedMode) ?? .timeline
        variant = GraphCanvasVariant(rawValue: storedVariant) ?? .botanical
        soundOn = storedSoundOn
        reduceMotionOverride = GraphReduceMotionOverride(rawValue: storedReduceMotionOverride) ?? .system
        snipParentMailboxPath = storedSnipParentMailboxPath
        wateredCounts = Self.decodeWateredCounts(from: userDefaults.data(forKey: StorageKey.wateredCounts))
    }

    internal func wateredCount(for threadID: String) -> Int {
        wateredCounts[threadID] ?? 0
    }

    internal func incrementWateredCount(for threadID: String) {
        wateredCounts[threadID, default: 0] += 1
        persistWateredCounts()
    }

    internal func shouldReduceMotion(systemReduceMotion: Bool) -> Bool {
        switch reduceMotionOverride {
        case .system:
            return systemReduceMotion
        case .reduce:
            return true
        case .full:
            return false
        }
    }

    private func persistWateredCounts() {
        guard let data = try? JSONEncoder().encode(wateredCounts) else { return }
        userDefaults.set(data, forKey: StorageKey.wateredCounts)
    }

    private static func decodeWateredCounts(from data: Data?) -> [String: Int] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
