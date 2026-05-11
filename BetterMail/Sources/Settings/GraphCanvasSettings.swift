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
        static let forceCenter = "graphCanvasForceCenter"
        static let forceRepel = "graphCanvasForceRepel"
        static let forceRepelCutoff = "graphCanvasForceRepelCutoff"
        static let forceLinkSpring = "graphCanvasForceLinkSpring"
        static let forceTrunkLength = "graphCanvasForceTrunkLength"
        static let forceChainLength = "graphCanvasForceChainLength"
        static let forceDamping = "graphCanvasForceDamping"
        static let forceBreezeAmplitude = "graphCanvasForceBreezeAmplitude"
        static let forceCurl = "graphCanvasForceCurl"
        static let forceCurlVariability = "graphCanvasForceCurlVariability"
        static let forceSplineTension = "graphCanvasForceSplineTension"
        static let forceCurlFalloff = "graphCanvasForceCurlFalloff"
        static let forceLabelRepelOn = "graphCanvasForceLabelRepelOn"
        static let forceLabelRepelStrength = "graphCanvasForceLabelRepelStrength"
    }

    @AppStorage(StorageKey.mode) private var storedMode = GraphCanvasMode.timeline.rawValue
    @AppStorage(StorageKey.variant) private var storedVariant = GraphCanvasVariant.botanical.rawValue
    @AppStorage(StorageKey.soundOn) private var storedSoundOn = false
    @AppStorage(StorageKey.reduceMotionOverride) private var storedReduceMotionOverride = GraphReduceMotionOverride.system.rawValue
    @AppStorage(StorageKey.snipParentMailboxPath) private var storedSnipParentMailboxPath = "Unimportant"
    @AppStorage(StorageKey.forceCenter) private var storedForceCenter = Double(GraphForceConstants.defaults.center)
    @AppStorage(StorageKey.forceRepel) private var storedForceRepel = Double(GraphForceConstants.defaults.repel)
    @AppStorage(StorageKey.forceRepelCutoff) private var storedForceRepelCutoff = Double(GraphForceConstants.defaults.repelCutoff)
    @AppStorage(StorageKey.forceLinkSpring) private var storedForceLinkSpring = Double(GraphForceConstants.defaults.linkSpring)
    @AppStorage(StorageKey.forceTrunkLength) private var storedForceTrunkLength = Double(GraphForceConstants.defaults.trunkLength)
    @AppStorage(StorageKey.forceChainLength) private var storedForceChainLength = Double(GraphForceConstants.defaults.chainLength)
    @AppStorage(StorageKey.forceDamping) private var storedForceDamping = Double(GraphForceConstants.defaults.damping)
    @AppStorage(StorageKey.forceBreezeAmplitude) private var storedForceBreezeAmplitude = Double(GraphForceConstants.defaults.breezeAmplitude)
    @AppStorage(StorageKey.forceCurl) private var storedForceCurl = Double(GraphForceConstants.defaults.curl)
    @AppStorage(StorageKey.forceCurlVariability) private var storedForceCurlVariability = Double(GraphForceConstants.defaults.curlVariability)
    @AppStorage(StorageKey.forceSplineTension) private var storedForceSplineTension = Double(GraphForceConstants.defaults.splineTension)
    @AppStorage(StorageKey.forceCurlFalloff) private var storedForceCurlFalloff = Double(GraphForceConstants.defaults.curlFalloff)
    @AppStorage(StorageKey.forceLabelRepelOn) private var storedForceLabelRepelOn = GraphForceConstants.defaults.labelRepelOn
    @AppStorage(StorageKey.forceLabelRepelStrength) private var storedForceLabelRepelStrength = Double(GraphForceConstants.defaults.labelRepelStrength)

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
    @Published internal var forceCenter: CGFloat = GraphForceConstants.defaults.center {
        didSet { storedForceCenter = Double(forceCenter) }
    }
    @Published internal var forceRepel: CGFloat = GraphForceConstants.defaults.repel {
        didSet { storedForceRepel = Double(forceRepel) }
    }
    @Published internal var forceRepelCutoff: CGFloat = GraphForceConstants.defaults.repelCutoff {
        didSet { storedForceRepelCutoff = Double(forceRepelCutoff) }
    }
    @Published internal var forceLinkSpring: CGFloat = GraphForceConstants.defaults.linkSpring {
        didSet { storedForceLinkSpring = Double(forceLinkSpring) }
    }
    @Published internal var forceTrunkLength: CGFloat = GraphForceConstants.defaults.trunkLength {
        didSet { storedForceTrunkLength = Double(forceTrunkLength) }
    }
    @Published internal var forceChainLength: CGFloat = GraphForceConstants.defaults.chainLength {
        didSet { storedForceChainLength = Double(forceChainLength) }
    }
    @Published internal var forceDamping: CGFloat = GraphForceConstants.defaults.damping {
        didSet { storedForceDamping = Double(forceDamping) }
    }
    @Published internal var forceBreezeAmplitude: CGFloat = GraphForceConstants.defaults.breezeAmplitude {
        didSet { storedForceBreezeAmplitude = Double(forceBreezeAmplitude) }
    }
    @Published internal var forceCurl: CGFloat = GraphForceConstants.defaults.curl {
        didSet { storedForceCurl = Double(forceCurl) }
    }
    @Published internal var forceCurlVariability: CGFloat = GraphForceConstants.defaults.curlVariability {
        didSet { storedForceCurlVariability = Double(forceCurlVariability) }
    }
    @Published internal var forceSplineTension: CGFloat = GraphForceConstants.defaults.splineTension {
        didSet { storedForceSplineTension = Double(forceSplineTension) }
    }
    @Published internal var forceCurlFalloff: CGFloat = GraphForceConstants.defaults.curlFalloff {
        didSet { storedForceCurlFalloff = Double(forceCurlFalloff) }
    }
    @Published internal var forceLabelRepelOn: Bool = GraphForceConstants.defaults.labelRepelOn {
        didSet { storedForceLabelRepelOn = forceLabelRepelOn }
    }
    @Published internal var forceLabelRepelStrength: CGFloat = GraphForceConstants.defaults.labelRepelStrength {
        didSet { storedForceLabelRepelStrength = Double(forceLabelRepelStrength) }
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
        forceCenter = CGFloat(storedForceCenter)
        forceRepel = CGFloat(storedForceRepel)
        forceRepelCutoff = CGFloat(storedForceRepelCutoff)
        forceLinkSpring = CGFloat(storedForceLinkSpring)
        forceTrunkLength = CGFloat(storedForceTrunkLength)
        forceChainLength = CGFloat(storedForceChainLength)
        forceDamping = CGFloat(storedForceDamping)
        forceBreezeAmplitude = CGFloat(storedForceBreezeAmplitude)
        forceCurl = CGFloat(storedForceCurl)
        forceCurlVariability = CGFloat(storedForceCurlVariability)
        forceSplineTension = CGFloat(storedForceSplineTension)
        forceCurlFalloff = CGFloat(storedForceCurlFalloff)
        forceLabelRepelOn = storedForceLabelRepelOn
        forceLabelRepelStrength = CGFloat(storedForceLabelRepelStrength)
        wateredCounts = Self.decodeWateredCounts(from: userDefaults.data(forKey: StorageKey.wateredCounts))
    }

    internal var forceConfig: GraphForceConfig {
        GraphForceConfig(center: forceCenter,
                         repel: forceRepel,
                         repelCutoff: forceRepelCutoff,
                         linkSpring: forceLinkSpring,
                         trunkLength: forceTrunkLength,
                         chainLength: forceChainLength,
                         damping: forceDamping,
                         breezeAmplitude: forceBreezeAmplitude,
                         curl: forceCurl,
                         curlVariability: forceCurlVariability,
                         splineTension: forceSplineTension,
                         curlFalloff: forceCurlFalloff,
                         labelRepelOn: forceLabelRepelOn,
                         labelRepelStrength: forceLabelRepelStrength)
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

    internal func restoreWhisperDefaults() {
        let defaults = GraphForceConstants.defaults
        forceCenter = defaults.center
        forceRepel = defaults.repel
        forceRepelCutoff = defaults.repelCutoff
        forceLinkSpring = defaults.linkSpring
        forceTrunkLength = defaults.trunkLength
        forceChainLength = defaults.chainLength
        forceDamping = defaults.damping
        forceBreezeAmplitude = defaults.breezeAmplitude
        forceCurl = defaults.curl
        forceCurlVariability = defaults.curlVariability
        forceSplineTension = defaults.splineTension
        forceCurlFalloff = defaults.curlFalloff
        forceLabelRepelOn = defaults.labelRepelOn
        forceLabelRepelStrength = defaults.labelRepelStrength
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
