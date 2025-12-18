import SwiftUI

struct ThreadGroupRowView: View {
    let group: ThreadGroup
    let isExpanded: Bool
    let onSetExpanded: (Bool) -> Void
    let onAcceptMerge: () -> Void
    let onRevertMerge: () -> Void
    let onPinToggle: (Bool) -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(gradient(for: group.topicTag))
                    .frame(width: 6)
                    .cornerRadius(3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    topRow
                    participantRow
                    badgeRow
                    summaryRow
                }
                Spacer()
                actions
            }
            if isExpanded {
                ThreadGroupDetailView(group: group,
                                      onAcceptMerge: onAcceptMerge,
                                      onRevertMerge: onRevertMerge)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.08))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(group.subject))
        .accessibilityHint(Text(accessibilityHint))
    }

    private var topRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.subject.isEmpty ? "No Subject" : group.subject)
                    .font(.headline)
                    .lineLimit(1)
                if group.unreadCount > 0 {
                    Text("\(group.unreadCount)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        .accessibilityLabel(Text("Unread messages \(group.unreadCount)"))
                }
            }
            Text(Self.dateFormatter.string(from: group.lastUpdated))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var participantRow: some View {
        HStack(alignment: .center, spacing: 8) {
            AvatarStack(participants: group.participants)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(group.participants.prefix(4)) { participant in
                        Label {
                            Text(participant.name)
                                .font(.caption)
                        } icon: {
                            Text(roleIcon(for: participant.role))
                                .font(.caption)
                        }
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                        .accessibilityLabel(Text("\(participant.role.displayName): \(participant.name)"))
                    }
                }
            }
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 6) {
            ForEach(group.badges) { badge in
                Text(badge.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
                    .accessibilityLabel(Text(badge.accessibilityLabel))
            }
        }
    }

    private var summaryRow: some View {
        Text(group.summary)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(isExpanded ? nil : 2)
            .accessibilityHint(Text("AI summary"))
    }

    private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                onPinToggle(!group.pinned)
            } label: {
                Image(systemName: group.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(group.pinned ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    onSetExpanded(!isExpanded)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .rotationEffect(isExpanded ? .degrees(180) : .degrees(0))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .contain)
    }

    private func gradient(for topic: String?) -> LinearGradient {
        let seed = topic ?? group.id
        var hasher = Hasher()
        hasher.combine(seed)
        let hash = abs(hasher.finalize())
        let hue = Double(hash % 360) / 360.0
        let start = Color(hue: hue, saturation: 0.55, brightness: 0.9)
        let end = Color(hue: min(hue + 0.08, 1.0), saturation: 0.7, brightness: 0.7)
        return LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom)
    }

    private func roleIcon(for role: ThreadParticipant.Role) -> String {
        switch role {
        case .requester:
            return "R"
        case .owner:
            return "O"
        case .collaborator:
            return "C"
        case .observer:
            return "V"
        case .unknown:
            return "P"
        }
    }

    private var accessibilityHint: String {
        let badgeText = group.badges.map(\.accessibilityLabel).joined(separator: ", ")
        let summary = group.summary
        if badgeText.isEmpty {
            return summary
        }
        return "\(summary). \(badgeText)"
    }
}

private struct AvatarStack: View {
    let participants: [ThreadParticipant]

    var body: some View {
        HStack(spacing: -12) {
            ForEach(Array(participants.prefix(3)).enumerated(), id: \.offset) { item in
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Text(initials(for: item.element))
                            .font(.caption2.weight(.bold))
                    )
                    .accessibilityLabel(Text(item.element.name))
            }
        }
    }

    private func initials(for participant: ThreadParticipant) -> String {
        let components = participant.name.split(separator: " ").map(String.init)
        if components.count >= 2 {
            return "\(components[0].prefix(1))\(components[1].prefix(1))"
        }
        return String(participant.name.prefix(2)).uppercased()
    }
}

private struct ThreadGroupDetailView: View {
    let group: ThreadGroup
    let onAcceptMerge: () -> Void
    let onRevertMerge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversation")
                .font(.headline)
            ThreadTreeView(node: group.rootNodes.first)
            ForEach(group.relatedConversations) { conversation in
                Divider()
                Text(conversation.reason.description)
                    .font(.subheadline.weight(.semibold))
                ForEach(conversation.nodes) { node in
                    ThreadTreeView(node: node)
                        .padding(.leading, 8)
                }
            }
            if showsMergeControls {
                mergeControls
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.3))
        )
    }

    private var showsMergeControls: Bool {
        !group.relatedConversations.isEmpty || !group.mergeReasons.isEmpty
    }

    private var mergeControls: some View {
        HStack {
            Button("Accept Merge") {
                onAcceptMerge()
            }
            .buttonStyle(.borderedProminent)
            Button("Revert Merge") {
                onRevertMerge()
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct ThreadTreeView: View {
    let node: ThreadNode?

    var body: some View {
        if let node {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.message.subject.isEmpty ? "(No subject)" : node.message.subject)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(node.message.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if let children = node.childNodes {
                    ForEach(children) { child in
                        ThreadTreeView(node: child)
                            .padding(.leading, 16)
                    }
                }
            }
        } else {
            EmptyView()
        }
    }
}

#if DEBUG
struct ThreadGroupRowView_Previews: PreviewProvider {
    static var previews: some View {
        let message = EmailMessage(messageID: UUID().uuidString,
                                   mailboxID: "inbox",
                                   subject: "Travel Plans",
                                   from: "Alex <alex@example.com>",
                                   to: "Taylor <taylor@example.com>",
                                   date: Date(),
                                   snippet: "Can you review the itinerary by EOD?",
                                   isUnread: true,
                                   inReplyTo: nil,
                                   references: [])
        let node = ThreadNode(message: message)
        let participant = ThreadParticipant(name: "Alex",
                                            email: "alex@example.com",
                                            role: .requester,
                                            isVIP: true)
        let group = ThreadGroup(id: "preview",
                                subject: message.subject,
                                topicTag: "Travel",
                                summary: "Need to finalize the hotel and flights for next week’s trip.",
                                participants: [participant],
                                badges: [
                                    ThreadBadge(kind: .urgent,
                                                label: "Urgent",
                                                accessibilityLabel: "Urgent, awaiting reply")
                                ],
                                intentSignals: ThreadIntentSignals(intentRelevance: 0.9,
                                                                   urgencyScore: 0.9,
                                                                   personalPriorityScore: 0.8,
                                                                   timelinessScore: 0.6),
                                lastUpdated: Date(),
                                unreadCount: 2,
                                rootNodes: [node],
                                relatedConversations: [],
                                mergeReasons: [],
                                mergeState: .suggested,
                                isWaitingOnMe: true,
                                hasActiveTask: true,
                                pinned: false,
                                chronologicalIndex: 0)
        ThreadGroupRowView(group: group,
                           isExpanded: true,
                           onSetExpanded: { _ in },
                           onAcceptMerge: {},
                           onRevertMerge: {},
                           onPinToggle: { _ in })
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
#endif
