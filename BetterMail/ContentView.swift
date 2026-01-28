import SwiftUI

internal struct ContentView: View {
    @ObservedObject internal var settings: AutoRefreshSettings
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    @StateObject private var viewModel: ThreadCanvasViewModel

    internal init(settings: AutoRefreshSettings,
                  inspectorSettings: InspectorViewSettings,
                  displaySettings: ThreadCanvasDisplaySettings) {
        self.settings = settings
        self.inspectorSettings = inspectorSettings
        self.displaySettings = displaySettings
        _viewModel = StateObject(wrappedValue: ThreadCanvasViewModel(settings: settings,
                                                                     inspectorSettings: inspectorSettings))
    }

    internal var body: some View {
        ThreadListView(viewModel: viewModel,
                       settings: settings,
                       inspectorSettings: inspectorSettings,
                       displaySettings: displaySettings)
            .frame(minWidth: 720, minHeight: 520)
    }
}
