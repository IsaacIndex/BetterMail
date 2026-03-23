import SwiftUI

// MARK: - ThreadCanvasViewModel

private struct CanvasViewModelKey: FocusedValueKey {
    typealias Value = ThreadCanvasViewModel
}

// MARK: - ThreadCanvasDisplaySettings

private struct DisplaySettingsKey: FocusedValueKey {
    typealias Value = ThreadCanvasDisplaySettings
}

extension FocusedValues {
    internal var canvasViewModel: ThreadCanvasViewModel? {
        get { self[CanvasViewModelKey.self] }
        set { self[CanvasViewModelKey.self] = newValue }
    }

    internal var displaySettings: ThreadCanvasDisplaySettings? {
        get { self[DisplaySettingsKey.self] }
        set { self[DisplaySettingsKey.self] = newValue }
    }
}
