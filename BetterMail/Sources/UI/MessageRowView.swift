import SwiftUI

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
                summaryDisclosure(for: summaryState, expansion: summaryExpansion)
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

    @ViewBuilder
    private func summaryDisclosure(for state: ThreadSummaryState,
                                   expansion: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expansion.wrappedValue.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                    Text("Apple Intelligence")
                        .font(.caption.weight(.semibold))
                    if state.isSummarizing {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    if !state.text.isEmpty {
                        Text(state.text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .opacity(expansion.wrappedValue ? 0 : 1)
                    } else if !state.statusMessage.isEmpty {
                        Text(state.statusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(expansion.wrappedValue ? .degrees(180) : .degrees(0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expansion.wrappedValue {
                VStack(alignment: .leading, spacing: 4) {
                    if !state.text.isEmpty {
                        Text(state.text)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !state.statusMessage.isEmpty {
                        Text(state.statusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(8)
        .background(summaryBackground)
    }

    private var summaryBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
            .fill(Color.accentColor.opacity(0.08))
            .overlay(shape.stroke(Color.accentColor.opacity(0.25)))
    }
}
