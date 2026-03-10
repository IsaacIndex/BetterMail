import Combine
import Foundation
import SwiftUI

@MainActor
internal final class ThreadCanvasDisplaySettings: ObservableObject {
    internal static let defaultDetailedThreshold: CGFloat = 0.65
    internal static let defaultCompactThreshold: CGFloat = 0.4
    internal static let defaultMinimalThreshold: CGFloat = 0.2
    internal static let defaultTextScale: CGFloat = 1.0
    internal static let minimumTextScale: CGFloat = 0.8
    internal static let maximumTextScale: CGFloat = 1.6
    internal static let defaultViewMode: ThreadCanvasViewMode = .default

    @AppStorage("threadCanvasZoomDetailedThreshold") private var storedDetailedThreshold = ThreadCanvasDisplaySettings.defaultDetailedThreshold
    @AppStorage("threadCanvasZoomCompactThreshold") private var storedCompactThreshold = ThreadCanvasDisplaySettings.defaultCompactThreshold
    @AppStorage("threadCanvasZoomMinimalThreshold") private var storedMinimalThreshold = ThreadCanvasDisplaySettings.defaultMinimalThreshold
    @AppStorage("threadCanvasTextScale") private var storedTextScale = ThreadCanvasDisplaySettings.defaultTextScale
    @AppStorage("threadCanvasViewMode") private var storedViewMode = ThreadCanvasDisplaySettings.defaultViewMode.rawValue

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
        didSet { normalizeSettings() }
    }
    @Published internal var viewMode: ThreadCanvasViewMode = ThreadCanvasDisplaySettings.defaultViewMode {
        didSet { storedViewMode = viewMode.rawValue }
    }

    @Published internal private(set) var currentZoom: CGFloat = ThreadCanvasDisplaySettings.defaultDetailedThreshold

    private var isNormalizing = false

    internal init() {
        detailedThreshold = storedDetailedThreshold
        compactThreshold = storedCompactThreshold
        minimalThreshold = storedMinimalThreshold
        textScale = storedTextScale
        viewMode = ThreadCanvasViewMode(rawValue: storedViewMode) ?? ThreadCanvasDisplaySettings.defaultViewMode
        normalizeSettings()
    }

    internal func updateCurrentZoom(_ value: CGFloat) {
        currentZoom = value
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
        let textScale = min(max(self.textScale, Self.minimumTextScale), Self.maximumTextScale)

        if detailed != detailedThreshold { detailedThreshold = detailed }
        if compact != compactThreshold { compactThreshold = compact }
        if minimal != minimalThreshold { minimalThreshold = minimal }
        if textScale != self.textScale { self.textScale = textScale }

        storedDetailedThreshold = detailed
        storedCompactThreshold = compact
        storedMinimalThreshold = minimal
        storedTextScale = textScale

        isNormalizing = false
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
