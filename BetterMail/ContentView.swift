import SwiftUI

internal struct ContentView: View {
    @ObservedObject internal var settings: AutoRefreshSettings
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    @StateObject private var viewModel: ThreadCanvasViewModel

    internal init(settings: AutoRefreshSettings, inspectorSettings: InspectorViewSettings) {
        self.settings = settings
        self.inspectorSettings = inspectorSettings
        _viewModel = StateObject(wrappedValue: ThreadCanvasViewModel(settings: settings,
                                                                     inspectorSettings: inspectorSettings))
    }

    internal var body: some View {
        ThreadListView(viewModel: viewModel, settings: settings, inspectorSettings: inspectorSettings)
            .frame(minWidth: 720, minHeight: 520)
    }
}
