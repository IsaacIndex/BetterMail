import SwiftUI

struct ThreadListView: View {
    @ObservedObject var viewModel: ThreadSidebarViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                OutlineGroup(viewModel.roots, children: \.childNodes) { node in
                    MessageRowView(node: node)
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 480, minHeight: 400)
        .task {
            viewModel.start()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Threads")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isRefreshing {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("Limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Limit", value: $viewModel.fetchLimit, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
            }
            .fixedSize()
            Button(action: { viewModel.refreshNow() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isRefreshing)
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 8)
    }

    private var statusText: String {
        if viewModel.unreadTotal > 0 {
            return "Unread: \(viewModel.unreadTotal) • \(viewModel.status)"
        }
        return viewModel.status
    }
}
