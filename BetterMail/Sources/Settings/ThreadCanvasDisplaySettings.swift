import Combine
import Foundation
import SwiftUI

@MainActor
internal final class ThreadCanvasDisplaySettings: ObservableObject {
    private enum StorageKey {
        static let detailedThreshold = "threadCanvasZoomDetailedThreshold"
        static let compactThreshold = "threadCanvasZoomCompactThreshold"
        static let minimalThreshold = "threadCanvasZoomMinimalThreshold"
        static let currentZoom = "threadCanvasCurrentZoom"
        static let textScale = "threadCanvasTextScale"
        static let viewMode = "threadCanvasViewMode"
    }

    internal static let defaultDetailedThreshold: CGFloat = 0.65
    internal static let defaultCompactThreshold: CGFloat = 0.4
    internal static let defaultMinimalThreshold: CGFloat = 0.2
    internal static let defaultCurrentZoom: CGFloat = 1.0
    internal static let defaultTextScale: CGFloat = 1.0
    internal static let minimumTextScale: CGFloat = 0.5
    internal static let maximumTextScale: CGFloat = 1.6
    internal static let defaultViewMode: ThreadCanvasViewMode = .default

    @Published internal var detailedThreshold: CGFloat = ThreadCanvasDisplaySettings.defaultDetailedThreshold {
        didSet { normalizeSettings() }
    }
    @Published internal var compactThreshold: CGFloat = ThreadCanvasDisplaySettings.defaultCompactThreshold {
        didSet { normalizeSettings() }
    }
    @Published internal var minimalThreshold: CGFloat = ThreadCanvasDisplaySettings.defaultMinimalThreshold {
        didSet { normalizeSettings() }
    }
    @Published internal var textScale: CGFloat = ThreadCanvasDisplaySettings.defaultTextScale {
        didSet { normalizeTextScale() }
    }
    @Published internal var viewMode: ThreadCanvasViewMode = ThreadCanvasDisplaySettings.defaultViewMode {
        didSet { userDefaults.set(viewMode.rawValue, forKey: StorageKey.viewMode) }
    }

    @Published internal private(set) var currentZoom: CGFloat = ThreadCanvasDisplaySettings.defaultCurrentZoom

    private var isNormalizing = false
    private let userDefaults: UserDefaults

    internal init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        detailedThreshold = storedCGFloat(forKey: StorageKey.detailedThreshold,
                                          defaultValue: Self.defaultDetailedThreshold)
        compactThreshold = storedCGFloat(forKey: StorageKey.compactThreshold,
                                         defaultValue: Self.defaultCompactThreshold)
        minimalThreshold = storedCGFloat(forKey: StorageKey.minimalThreshold,
                                         defaultValue: Self.defaultMinimalThreshold)
        currentZoom = storedCGFloat(forKey: StorageKey.currentZoom,
                                    defaultValue: Self.defaultCurrentZoom)
        textScale = storedCGFloat(forKey: StorageKey.textScale,
                                  defaultValue: Self.defaultTextScale)
        viewMode = storedViewMode()
        normalizeSettings()
    }

    internal func updateCurrentZoom(_ value: CGFloat) {
        let clamped = min(max(value, ThreadCanvasLayoutMetrics.minZoom), ThreadCanvasLayoutMetrics.maxZoom)
        currentZoom = clamped
        storeCGFloat(clamped, forKey: StorageKey.currentZoom)
    }

    internal func toggleViewMode() {
        viewMode = viewMode == .default ? .timeline : .default
    }

    internal func readabilityMode(for zoom: CGFloat) -> ThreadCanvasReadabilityMode {
        if zoom >= detailedThreshold {
            return .detailed
        }
        if zoom >= compactThreshold {
            return .compact
        }
        return .minimal
    }

    private func normalizeSettings() {
        guard !isNormalizing else { return }
        isNormalizing = true

        let minZoom = ThreadCanvasLayoutMetrics.minZoom
        let maxZoom = ThreadCanvasLayoutMetrics.maxZoom

        var detailed = min(max(detailedThreshold, minZoom), maxZoom)
        var compact = min(max(compactThreshold, minZoom), maxZoom)
        var minimal = min(max(minimalThreshold, minZoom), maxZoom)

        detailed = max(detailed, compact)
        compact = min(max(compact, minimal), detailed)
        minimal = min(minimal, compact)

        if detailed != detailedThreshold { detailedThreshold = detailed }
        if compact != compactThreshold { compactThreshold = compact }
        if minimal != minimalThreshold { minimalThreshold = minimal }

        storeCGFloat(detailed, forKey: StorageKey.detailedThreshold)
        storeCGFloat(compact, forKey: StorageKey.compactThreshold)
        storeCGFloat(minimal, forKey: StorageKey.minimalThreshold)

        isNormalizing = false
    }

    private func normalizeTextScale() {
        let clamped = min(max(textScale, Self.minimumTextScale), Self.maximumTextScale)
        if clamped != textScale {
            textScale = clamped
            return
        }
        storeCGFloat(clamped, forKey: StorageKey.textScale)
    }

    private func storedCGFloat(forKey key: String, defaultValue: CGFloat) -> CGFloat {
        guard userDefaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return CGFloat(userDefaults.double(forKey: key))
    }

    private func storeCGFloat(_ value: CGFloat, forKey key: String) {
        userDefaults.set(Double(value), forKey: key)
    }

    private func storedViewMode() -> ThreadCanvasViewMode {
        guard let storedValue = userDefaults.string(forKey: StorageKey.viewMode) else {
            return Self.defaultViewMode
        }
        return ThreadCanvasViewMode(rawValue: storedValue) ?? Self.defaultViewMode
    }
}

internal enum ThreadCanvasReadabilityMode {
    case detailed
    case compact
    case minimal
}

internal enum ThreadCanvasViewMode: String {
    case `default`
    case timeline
}
