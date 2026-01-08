import SwiftUI

@available(*, deprecated, message: "MessageRowView is deprecated. Use the thread canvas with inspector details instead.")
struct MessageRowView: View {
    let node: ThreadNode
    let summaryState: ThreadSummaryState?
    let summaryExpansion: Binding<Bool>?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summaryState, let summaryExpansion {
                ThreadSummaryDisclosureView(title: NSLocalizedString("threadcanvas.summary.apple_intelligence",
                                                                     comment: "Title for the Apple Intelligence summary disclosure"),
                                             state: summaryState,
                                             isExpanded: summaryExpansion)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(node.message.subject.isEmpty ? "(No Subject)" : node.message.subject)
                            .fontWeight(node.message.isUnread ? .bold : .regular)
                        if node.children.isEmpty == false {
                            Text("\(node.children.count + 1)")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15)))
                        }
                    }
                    .lineLimit(1)

                    Text(node.message.from)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(node.message.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(Self.dateFormatter.string(from: node.message.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if node.message.isUnread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
