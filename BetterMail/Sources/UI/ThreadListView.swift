import SwiftUI

struct ThreadListView: View {
    @ObservedObject var viewModel: ThreadViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(viewModel.displayedGroups) { group in
                    ThreadGroupRowView(group: group,
                                       isExpanded: viewModel.isExpanded(group.id),
                                       onSetExpanded: { viewModel.setExpanded($0, for: group.id) },
                                       onAcceptMerge: { viewModel.acceptMerge(for: group.id) },
                                       onRevertMerge: { viewModel.revertMerge(for: group.id) },
                                       onPinToggle: { isPinned in
                        viewModel.pin(group.id, enabled: isPinned)
                    })
                    .listRowInsets(.init(top: 12, leading: 12, bottom: 12, trailing: 12))
                }
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 640, minHeight: 460)
        .task {
            viewModel.start()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Threads")
                    .font(.title2.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Status")
            }
            Spacer()
            limitControl
            if viewModel.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await viewModel.refreshNow() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isRefreshing)
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 6)
    }

    private var limitControl: some View {
        HStack(spacing: 6) {
            Text("Limit")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Limit", value: $viewModel.fetchLimit, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .accessibilityLabel("Fetch limit")
        }
        .fixedSize()
    }

    private var statusText: String {
        if viewModel.unreadTotal > 0 {
            return "Unread: \(viewModel.unreadTotal) • \(viewModel.statusMessage)"
        }
        return viewModel.statusMessage
    }
}
