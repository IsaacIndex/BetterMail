import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel: ThreadViewModel

    init(selfAddressStore: SelfAddressStore = .shared) {
        _viewModel = StateObject(wrappedValue: ThreadViewModel(selfAddressStore: selfAddressStore))
    }

    var body: some View {
        ThreadListView(viewModel: viewModel)
            .frame(minWidth: 720, minHeight: 520)
    }
}
