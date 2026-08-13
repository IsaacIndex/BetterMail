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
    internal static let visibleBranchCountRange = 4...24
    internal static let defaultVisibleBranchCount = 10
    internal static let visibleBranchesPerNodeRange = 2...12
    internal static let defaultVisibleBranchesPerNode = 6

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
        static let obsidianCenterStrength = "graphCanvasObsidianCenterStrength"
        static let obsidianRepelStrength = "graphCanvasObsidianRepelStrength"
        static let obsidianLinkStrength = "graphCanvasObsidianLinkStrength"
        static let obsidianLinkDistance = "graphCanvasObsidianLinkDistance"
        static let obsidianDamping = "graphCanvasObsidianDamping"
        static let obsidianShowsArrows = "graphCanvasObsidianShowsArrows"
        static let obsidianTextFadeThreshold = "graphCanvasObsidianTextFadeThreshold"
        static let obsidianNodeSize = "graphCanvasObsidianNodeSize"
        static let obsidianLinkThickness = "graphCanvasObsidianLinkThickness"
        static let visibleBranchCount = "graphCanvasVisibleBranchCount"
        static let visibleBranchesPerNode = "graphCanvasVisibleBranchesPerNode"
        static let dismissedSuggestedTopicIDs = "graphCanvasDismissedSuggestedTopicIDs"
        static let hiddenSuggestedTopics = "graphCanvasHiddenSuggestedTopics"
        static let obsidianExpandedSpacingMigration = "graphCanvasObsidianExpandedSpacingMigrationV1"
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
    @AppStorage(StorageKey.obsidianCenterStrength) private var storedObsidianCenterStrength = Double(ObsidianGraphForceConfig.defaults.centerStrength)
    @AppStorage(StorageKey.obsidianRepelStrength) private var storedObsidianRepelStrength = Double(ObsidianGraphForceConfig.defaults.repelStrength)
    @AppStorage(StorageKey.obsidianLinkStrength) private var storedObsidianLinkStrength = Double(ObsidianGraphForceConfig.defaults.linkStrength)
    @AppStorage(StorageKey.obsidianLinkDistance) private var storedObsidianLinkDistance = Double(ObsidianGraphForceConfig.defaults.linkDistance)
    @AppStorage(StorageKey.obsidianDamping) private var storedObsidianDamping = Double(ObsidianGraphForceConfig.defaults.damping)
    @AppStorage(StorageKey.obsidianShowsArrows) private var storedObsidianShowsArrows = ObsidianGraphDisplayConfig.defaults.showsArrows
    @AppStorage(StorageKey.obsidianTextFadeThreshold) private var storedObsidianTextFadeThreshold = Double(ObsidianGraphDisplayConfig.defaults.textFadeThreshold)
    @AppStorage(StorageKey.obsidianNodeSize) private var storedObsidianNodeSize = Double(ObsidianGraphDisplayConfig.defaults.nodeSize)
    @AppStorage(StorageKey.obsidianLinkThickness) private var storedObsidianLinkThickness = Double(ObsidianGraphDisplayConfig.defaults.linkThickness)

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
    @Published internal var visibleBranchCount = GraphCanvasSettings.defaultVisibleBranchCount {
        didSet { userDefaults.set(visibleBranchCount, forKey: StorageKey.visibleBranchCount) }
    }
    @Published internal var visibleBranchesPerNode = GraphCanvasSettings.defaultVisibleBranchesPerNode {
        didSet {
            let clampedValue = Self.clampedVisibleBranchesPerNode(visibleBranchesPerNode)
            if clampedValue != visibleBranchesPerNode {
                visibleBranchesPerNode = clampedValue
            }
            userDefaults.set(clampedValue, forKey: StorageKey.visibleBranchesPerNode)
        }
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
    @Published internal var obsidianCenterStrength: CGFloat = ObsidianGraphForceConfig.defaults.centerStrength {
        didSet { storedObsidianCenterStrength = Double(obsidianCenterStrength) }
    }
    @Published internal var obsidianRepelStrength: CGFloat = ObsidianGraphForceConfig.defaults.repelStrength {
        didSet { storedObsidianRepelStrength = Double(obsidianRepelStrength) }
    }
    @Published internal var obsidianLinkStrength: CGFloat = ObsidianGraphForceConfig.defaults.linkStrength {
        didSet { storedObsidianLinkStrength = Double(obsidianLinkStrength) }
    }
    @Published internal var obsidianLinkDistance: CGFloat = ObsidianGraphForceConfig.defaults.linkDistance {
        didSet { storedObsidianLinkDistance = Double(obsidianLinkDistance) }
    }
    @Published internal var obsidianDamping: CGFloat = ObsidianGraphForceConfig.defaults.damping {
        didSet { storedObsidianDamping = Double(obsidianDamping) }
    }
    @Published internal var obsidianShowsArrows = ObsidianGraphDisplayConfig.defaults.showsArrows {
        didSet { storedObsidianShowsArrows = obsidianShowsArrows }
    }
    @Published internal var obsidianTextFadeThreshold: CGFloat = ObsidianGraphDisplayConfig.defaults.textFadeThreshold {
        didSet { storedObsidianTextFadeThreshold = Double(obsidianTextFadeThreshold) }
    }
    @Published internal var obsidianNodeSize: CGFloat = ObsidianGraphDisplayConfig.defaults.nodeSize {
        didSet { storedObsidianNodeSize = Double(obsidianNodeSize) }
    }
    @Published internal var obsidianLinkThickness: CGFloat = ObsidianGraphDisplayConfig.defaults.linkThickness {
        didSet { storedObsidianLinkThickness = Double(obsidianLinkThickness) }
    }
    @Published internal private(set) var wateredCounts: [String: Int] = [:]
    @Published internal private(set) var dismissedSuggestedTopicIDs: Set<String> = []
    @Published internal private(set) var hiddenSuggestedTopics: Set<String> = []

    private let userDefaults: UserDefaults

    internal init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        mode = GraphCanvasMode(rawValue: storedMode) ?? .timeline
        variant = GraphCanvasVariant(rawValue: storedVariant) ?? .botanical
        soundOn = storedSoundOn
        reduceMotionOverride = GraphReduceMotionOverride(rawValue: storedReduceMotionOverride) ?? .system
        snipParentMailboxPath = storedSnipParentMailboxPath
        let storedVisibleBranchCount = userDefaults.object(forKey: StorageKey.visibleBranchCount) as? Int
        visibleBranchCount = Self.clampedVisibleBranchCount(storedVisibleBranchCount ?? Self.defaultVisibleBranchCount)
        let storedVisibleBranchesPerNode = userDefaults.object(forKey: StorageKey.visibleBranchesPerNode) as? Int
        visibleBranchesPerNode = Self.clampedVisibleBranchesPerNode(
            storedVisibleBranchesPerNode ?? Self.defaultVisibleBranchesPerNode
        )
        let storedForceConfig = GraphForceConfig(center: CGFloat(storedForceCenter),
                                                 repel: CGFloat(storedForceRepel),
                                                 repelCutoff: CGFloat(storedForceRepelCutoff),
                                                 linkSpring: CGFloat(storedForceLinkSpring),
                                                 trunkLength: CGFloat(storedForceTrunkLength),
                                                 chainLength: CGFloat(storedForceChainLength),
                                                 damping: CGFloat(storedForceDamping),
                                                 breezeAmplitude: CGFloat(storedForceBreezeAmplitude),
                                                 curl: CGFloat(storedForceCurl),
                                                 curlVariability: CGFloat(storedForceCurlVariability),
                                                 splineTension: CGFloat(storedForceSplineTension),
                                                 curlFalloff: CGFloat(storedForceCurlFalloff),
                                                 labelRepelOn: storedForceLabelRepelOn,
                                                 labelRepelStrength: CGFloat(storedForceLabelRepelStrength))
        let resolvedForceConfig = storedForceConfig == GraphForceConstants.legacySpringDefaults
            ? GraphForceConstants.defaults
            : storedForceConfig
        applyForceConfig(resolvedForceConfig)
        let storedObsidianForceConfig = ObsidianGraphForceConfig(
            centerStrength: CGFloat(storedObsidianCenterStrength),
            repelStrength: CGFloat(storedObsidianRepelStrength),
            linkStrength: CGFloat(storedObsidianLinkStrength),
            linkDistance: CGFloat(storedObsidianLinkDistance),
            damping: CGFloat(storedObsidianDamping)
        )
        var resolvedObsidianForceConfig = ObsidianGraphForceConfig
            .migratingHistoricalDefaults(storedObsidianForceConfig)
        if !userDefaults.bool(forKey: StorageKey.obsidianExpandedSpacingMigration) {
            resolvedObsidianForceConfig = ObsidianGraphForceConfig
                .migratingToExpandedSpacing(resolvedObsidianForceConfig)
            userDefaults.set(true, forKey: StorageKey.obsidianExpandedSpacingMigration)
        }
        applyObsidianForceConfig(resolvedObsidianForceConfig)
        applyObsidianDisplayConfig(ObsidianGraphDisplayConfig(showsArrows: storedObsidianShowsArrows,
                                                             textFadeThreshold: CGFloat(storedObsidianTextFadeThreshold),
                                                             nodeSize: CGFloat(storedObsidianNodeSize),
                                                             linkThickness: CGFloat(storedObsidianLinkThickness)))
        wateredCounts = Self.decodeWateredCounts(from: userDefaults.data(forKey: StorageKey.wateredCounts))
        dismissedSuggestedTopicIDs = Set(
            (userDefaults.stringArray(forKey: StorageKey.dismissedSuggestedTopicIDs) ?? [])
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        hiddenSuggestedTopics = Set(
            (userDefaults.stringArray(forKey: StorageKey.hiddenSuggestedTopics) ?? [])
                .map(GraphTopicNormalizer.normalize)
                .filter { !$0.isEmpty }
        )
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

    internal var obsidianForceConfig: ObsidianGraphForceConfig {
        ObsidianGraphForceConfig(centerStrength: obsidianCenterStrength,
                                 repelStrength: obsidianRepelStrength,
                                 linkStrength: obsidianLinkStrength,
                                 linkDistance: obsidianLinkDistance,
                                 damping: obsidianDamping)
    }

    internal var obsidianDisplayConfig: ObsidianGraphDisplayConfig {
        ObsidianGraphDisplayConfig(showsArrows: obsidianShowsArrows,
                                   textFadeThreshold: obsidianTextFadeThreshold,
                                   nodeSize: obsidianNodeSize,
                                   linkThickness: obsidianLinkThickness)
    }

    internal func wateredCount(for threadID: String) -> Int {
        wateredCounts[threadID] ?? 0
    }

    internal func incrementWateredCount(for threadID: String) {
        wateredCounts[threadID, default: 0] += 1
        persistWateredCounts()
    }

    internal func dismissSuggestedTopic(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        var updatedIDs = dismissedSuggestedTopicIDs
        guard updatedIDs.insert(trimmedID).inserted else { return }
        dismissedSuggestedTopicIDs = updatedIDs
        userDefaults.set(updatedIDs.sorted(), forKey: StorageKey.dismissedSuggestedTopicIDs)
    }

    internal func rejectSuggestedGroup(id: String) {
        dismissSuggestedTopic(id: id)
    }

    internal func hideSuggestedTopic(_ topic: String) {
        let normalizedTopic = GraphTopicNormalizer.normalize(topic)
        guard !normalizedTopic.isEmpty else { return }
        var updatedTopics = hiddenSuggestedTopics
        guard updatedTopics.insert(normalizedTopic).inserted else { return }
        hiddenSuggestedTopics = updatedTopics
        userDefaults.set(updatedTopics.sorted(), forKey: StorageKey.hiddenSuggestedTopics)
    }

    internal var hasSuggestedTopicPreferences: Bool {
        !dismissedSuggestedTopicIDs.isEmpty || !hiddenSuggestedTopics.isEmpty
    }

    internal func resetSuggestedTopicPreferences() {
        dismissedSuggestedTopicIDs = []
        hiddenSuggestedTopics = []
        userDefaults.removeObject(forKey: StorageKey.dismissedSuggestedTopicIDs)
        userDefaults.removeObject(forKey: StorageKey.hiddenSuggestedTopics)
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
        applyForceConfig(GraphForceConstants.defaults)
    }

    internal func restoreObsidianDefaults() {
        applyObsidianForceConfig(.defaults)
        applyObsidianDisplayConfig(.defaults)
    }

    internal static func clampedVisibleBranchCount(_ value: Int) -> Int {
        min(max(value, visibleBranchCountRange.lowerBound), visibleBranchCountRange.upperBound)
    }

    internal static func clampedVisibleBranchesPerNode(_ value: Int) -> Int {
        min(max(value, visibleBranchesPerNodeRange.lowerBound), visibleBranchesPerNodeRange.upperBound)
    }

    private func applyForceConfig(_ config: GraphForceConfig) {
        forceCenter = config.center
        forceRepel = config.repel
        forceRepelCutoff = config.repelCutoff
        forceLinkSpring = config.linkSpring
        forceTrunkLength = config.trunkLength
        forceChainLength = config.chainLength
        forceDamping = config.damping
        forceBreezeAmplitude = config.breezeAmplitude
        forceCurl = config.curl
        forceCurlVariability = config.curlVariability
        forceSplineTension = config.splineTension
        forceCurlFalloff = config.curlFalloff
        forceLabelRepelOn = config.labelRepelOn
        forceLabelRepelStrength = config.labelRepelStrength
    }

    private func applyObsidianForceConfig(_ config: ObsidianGraphForceConfig) {
        obsidianCenterStrength = config.centerStrength
        obsidianRepelStrength = config.repelStrength
        obsidianLinkStrength = config.linkStrength
        obsidianLinkDistance = config.linkDistance
        obsidianDamping = config.damping
    }

    private func applyObsidianDisplayConfig(_ config: ObsidianGraphDisplayConfig) {
        obsidianShowsArrows = config.showsArrows
        obsidianTextFadeThreshold = config.textFadeThreshold
        obsidianNodeSize = config.nodeSize
        obsidianLinkThickness = config.linkThickness
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
