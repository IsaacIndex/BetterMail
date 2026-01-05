import SwiftUI

struct ThreadListView: View {
    @ObservedObject var viewModel: ThreadSidebarViewModel
    @ObservedObject var settings: AutoRefreshSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                OutlineGroup(viewModel.roots, children: \.childNodes) { node in
                    MessageRowView(node: node,
                                   summaryState: viewModel.summaryState(for: node.id),
                                   summaryExpansion: Binding(get: {
                        viewModel.isSummaryExpanded(for: node.id)
                    }, set: { newValue in
                        viewModel.setSummaryExpanded(newValue, for: node.id)
                    }))
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 480, minHeight: 400)
        .task {
            viewModel.start()
        }
        .onChange(of: settings.isEnabled) { _, _ in
            viewModel.applyAutoRefreshSettings()
        }
        .onChange(of: settings.interval) { _, _ in
            viewModel.applyAutoRefreshSettings()
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
                refreshTimingView
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
            return String.localizedStringWithFormat(
                NSLocalizedString("threadlist.status.unread", comment: "Status showing unread count"),
                viewModel.unreadTotal,
                viewModel.status
            )
        }
        return viewModel.status
    }

    private var refreshTimingView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let lastRefreshDate = viewModel.lastRefreshDate {
                Text("Last updated: \(lastRefreshDate.formatted(date: .numeric, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if settings.isEnabled, let nextRefreshDate = viewModel.nextRefreshDate {
                Text("Next refresh: \(nextRefreshDate.formatted(date: .numeric, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

}
