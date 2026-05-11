import SwiftUI

internal struct ProcessingActivityMenuContent: View {
    @ObservedObject internal var activityCenter: ProcessingActivityCenter

    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(NSLocalizedString("activity.center.title", comment: "Processing activity panel title"),
                      systemImage: activityCenter.hasActiveActivity ? "bolt.horizontal.circle.fill" : "checkmark.circle")
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if activityCenter.visibleActivities.isEmpty {
                Text(NSLocalizedString("activity.center.idle", comment: "Idle activity center status"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(activityCenter.visibleActivities) { activity in
                        ProcessingActivityRow(activity: activity)
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, alignment: .leading)
    }

    private var statusText: String {
        guard activityCenter.activeCount > 0 else {
            return NSLocalizedString("activity.center.idle", comment: "Idle activity center status")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("activity.center.active_count", comment: "Active processing activity count"),
            activityCenter.activeCount
        )
    }
}

internal struct ProcessingActivityShelf: View {
    @ObservedObject internal var activityCenter: ProcessingActivityCenter
    @State private var isPopoverPresented = false

    internal var body: some View {
        if let activity = activityCenter.primaryActivity {
            Button {
                isPopoverPresented.toggle()
            } label: {
                HStack(spacing: 8) {
                    activityIcon(for: activity)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(activity.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(activity.detail ?? activity.state.localizedTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if activityCenter.activeCount > 1 {
                        Text(String(activityCenter.activeCount))
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: 300, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.processingActivityShelf)
            .accessibilityLabel(NSLocalizedString("accessibility.activity.shelf.label",
                                                  comment: "Accessibility label for processing activity shelf"))
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                ProcessingActivityMenuContent(activityCenter: activityCenter)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func activityIcon(for activity: ProcessingActivity) -> some View {
        if activity.isActive {
            if let progress = activity.progress {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .frame(width: 18)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18)
            }
        } else {
            Image(systemName: activity.state == .failed ? "exclamationmark.triangle.fill" : activity.kind.systemImage)
                .font(.caption)
                .foregroundStyle(activity.state == .failed ? Color.red : Color.secondary)
                .frame(width: 18)
        }
    }
}

private struct ProcessingActivityRow: View {
    let activity: ProcessingActivity

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if activity.isActive {
                if let progress = activity.progress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(width: 18)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18)
                }
            } else {
                Image(systemName: statusImage)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(activity.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(activity.kind.localizedTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(activity.detail ?? activity.state.localizedTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let progress = activity.progress, activity.isActive {
                    ProgressView(value: progress)
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusImage: String {
        switch activity.state {
        case .running:
            return activity.kind.systemImage
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch activity.state {
        case .running:
            return .accentColor
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }
}
