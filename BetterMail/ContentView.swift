import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ThreadSidebarViewModel()

    var body: some View {
        ThreadListView(viewModel: viewModel)
            .frame(minWidth: 720, minHeight: 520)
    }
}
