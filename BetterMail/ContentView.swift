import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AutoRefreshSettings
    @StateObject private var viewModel: ThreadCanvasViewModel

    init(settings: AutoRefreshSettings) {
        self.settings = settings
        _viewModel = StateObject(wrappedValue: ThreadCanvasViewModel(settings: settings))
    }

    var body: some View {
        ThreadListView(viewModel: viewModel, settings: settings)
            .frame(minWidth: 720, minHeight: 520)
    }
}
