import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AutoRefreshSettings
    @ObservedObject var inspectorSettings: InspectorViewSettings
    @StateObject private var viewModel: ThreadCanvasViewModel

    init(settings: AutoRefreshSettings, inspectorSettings: InspectorViewSettings) {
        self.settings = settings
        self.inspectorSettings = inspectorSettings
        _viewModel = StateObject(wrappedValue: ThreadCanvasViewModel(settings: settings,
                                                                     inspectorSettings: inspectorSettings))
    }

    var body: some View {
        ThreadListView(viewModel: viewModel, settings: settings, inspectorSettings: inspectorSettings)
            .frame(minWidth: 720, minHeight: 520)
    }
}
