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

@MainActor
internal struct ProcessingActivityShelf: View {
    @ObservedObject internal var activityCenter: ProcessingActivityCenter
    @State private var referenceDate = Date()

    private var activity: ProcessingActivity? {
        activityCenter.shelfActivity(at: referenceDate)
    }

    internal var body: some View {
        Group {
            if let activity {
                HStack(spacing: 7) {
                    activityIcon(for: activity)

                    Text(activity.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(width: 224, alignment: .leading)
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.processingActivityShelf)
                .accessibilityLabel(NSLocalizedString("accessibility.activity.shelf.label",
                                                      comment: "Accessibility label for processing activity shelf"))
                .accessibilityValue(activity.detail ?? activity.state.localizedTitle)
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: activityCenter.shelfPresentationVersion) {
            let presentationVersion = activityCenter.shelfPresentationVersion
            referenceDate = Date()
            guard activityCenter.shelfActivity(at: referenceDate) != nil else { return }

            do {
                try await Task.sleep(nanoseconds: ProcessingActivityShelfPolicy.displayDurationNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  presentationVersion == activityCenter.shelfPresentationVersion else { return }
            referenceDate = Date()
        }
        .animation(.easeInOut(duration: 0.18), value: activity?.id)
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
            Image(systemName: statusImage(for: activity.state))
                .font(.caption)
                .foregroundStyle(statusColor(for: activity.state))
                .frame(width: 18)
        }
    }

    private func statusImage(for state: ProcessingActivityState) -> String {
        switch state {
        case .running:
            return "circle"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "xmark.circle.fill"
        }
    }

    private func statusColor(for state: ProcessingActivityState) -> Color {
        switch state {
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
