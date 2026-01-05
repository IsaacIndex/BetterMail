import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AutoRefreshSettings
    @StateObject private var viewModel: ThreadSidebarViewModel

    init(settings: AutoRefreshSettings) {
        self.settings = settings
        _viewModel = StateObject(wrappedValue: ThreadSidebarViewModel(settings: settings))
    }

    var body: some View {
        ThreadListView(viewModel: viewModel, settings: settings)
            .frame(minWidth: 720, minHeight: 520)
    }
}
