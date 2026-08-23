import SwiftUI

internal struct GraphToolbar: View {
    @ObservedObject internal var viewModel: GraphCanvasViewModel
    @ObservedObject internal var settings: GraphCanvasSettings
    internal let textScale: CGFloat
    internal let selectedThreadID: String?
    internal let restoreHistoryEntries: [GraphCompostEntry]
    internal let restoringHistoryEntryIDs: Set<String>
    internal let automationAttentionCount: Int
    internal let onRestoreHistoryEntry: (GraphCompostEntry) -> Void
    internal let onDismissHistoryEntry: (GraphCompostEntry) -> Void
    internal let onAutomation: () -> Void

    internal var body: some View {
        HStack(spacing: 8) {
            ControlGroup {
                toolbarButton(title: viewModel.snipActionTitle,
                              systemImage: "scissors",
                              isOn: viewModel.snipPhase != .idle,
                              tint: DesignTokens.Graph.AppTheme.snip,
                              accessibilityID: AccessibilityID.graphToolbarSnip,
                              help: NSLocalizedString("graph.toolbar.snip.help.mode",
                                                      comment: "Help for entering graph branch snip mode"),
                              action: performSnip)
                toolbarButton(title: NSLocalizedString("graph.toolbar.archive", comment: "Graph archive mode"),
                              systemImage: "archivebox",
                              isOn: viewModel.pruneMode == .archive,
                              tint: DesignTokens.Graph.AppTheme.archive,
                              accessibilityID: AccessibilityID.graphToolbarArchive,
                              isDisabled: viewModel.isArchiveDisabledForSnip,
                              help: selectedThreadID == nil
                              ? NSLocalizedString("graph.toolbar.archive.help.mode",
                                                  comment: "Help for entering graph branch archive mode")
                              : NSLocalizedString("graph.toolbar.archive.help.selected",
                                                  comment: "Help for archiving the selected graph thread"),
                              action: performArchive)
                GraphRestoreHistoryControl(entries: restoreHistoryEntries,
                                           restoringEntryIDs: restoringHistoryEntryIDs,
                                           textScale: textScale,
                                           onRestore: onRestoreHistoryEntry,
                                           onDismiss: onDismissHistoryEntry)
                toolbarButton(title: NSLocalizedString("graph.toolbar.automation",
                                                       comment: "Open graph automation queue"),
                              systemImage: "wand.and.stars",
                              isOn: false,
                              tint: DesignTokens.Graph.AppTheme.accent,
                              accessibilityID: AccessibilityID.graphToolbarAutomation,
                              badgeCount: automationAttentionCount,
                              help: NSLocalizedString("graph.toolbar.automation.help",
                                                      comment: "Help for graph automation queue"),
                              action: onAutomation)
            }
            .controlSize(.small)

            ControlGroup {
                plainButton(systemImage: "minus.magnifyingglass",
                            title: NSLocalizedString("graph.toolbar.zoom_out", comment: "Graph zoom out"),
                            accessibilityID: AccessibilityID.graphToolbarZoomOut,
                            action: viewModel.zoomOut)
                plainButton(systemImage: "plus.magnifyingglass",
                            title: NSLocalizedString("graph.toolbar.zoom_in", comment: "Graph zoom in"),
                            accessibilityID: AccessibilityID.graphToolbarZoomIn,
                            action: viewModel.zoomIn)
            }
            .controlSize(.small)

            Text("\(Int((viewModel.zoomScale * 100).rounded()))%")
                .font(DesignTokens.font(size: 10.5, weight: .medium, textScale: textScale))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 44)

            ControlGroup {
                plainButton(systemImage: "scope",
                            title: NSLocalizedString("graph.toolbar.recenter", comment: "Graph recenter"),
                            accessibilityID: AccessibilityID.graphToolbarRecenter,
                            action: viewModel.resetViewport)
                plainButton(systemImage: "slider.horizontal.3",
                            title: NSLocalizedString("graph.toolbar.settings", comment: "Graph settings"),
                            accessibilityID: AccessibilityID.graphToolbarSettings,
                            action: { viewModel.isSettingsPresented = true })
            }
            .controlSize(.small)
        }
        .padding(4)
        .accessibilityIdentifier(AccessibilityID.graphToolbar)
    }

    private func toolbarButton(title: String,
                               systemImage: String,
                               isOn: Bool,
                               tint: Color,
                               accessibilityID: String,
                               badgeCount: Int = 0,
                               isDisabled: Bool = false,
                               help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Label(title, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
                    .symbolVariant(isOn ? .fill : .none)
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                        .accessibilityHidden(true)
                }
            }
            .font(DesignTokens.font(size: 12, weight: .semibold, textScale: textScale))
            .foregroundStyle(isOn ? tint : DesignTokens.Graph.AppTheme.inkSecondary)
            .frame(minWidth: 104, minHeight: 24)
        }
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue(for: accessibilityID,
                                               badgeCount: badgeCount,
                                               isOn: isOn))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(accessibilityID)
        .disabled(isDisabled)
        .help(help)
    }

    private func accessibilityValue(for accessibilityID: String,
                                    badgeCount: Int,
                                    isOn: Bool) -> String {
        if accessibilityID == AccessibilityID.graphToolbarAutomation, badgeCount > 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("graph.automation.attention_count",
                                  comment: "Automation items needing attention"),
                badgeCount
            )
        }
        let modeState: String? = {
            guard accessibilityID == AccessibilityID.graphToolbarSnip
                    || accessibilityID == AccessibilityID.graphToolbarArchive else {
                return nil
            }
            return NSLocalizedString(
                isOn
                    ? "accessibility.graph.toolbar.mode.active"
                    : "accessibility.graph.toolbar.mode.inactive",
                comment: "Accessibility state for a stateful graph toolbar mode"
            )
        }()
        if accessibilityID == AccessibilityID.graphToolbarSnip,
           viewModel.stagedSnipCount > 0 {
            let detail = String.localizedStringWithFormat(
                NSLocalizedString("graph.snip.staging.count",
                                  comment: "Number of staged graph branches"),
                viewModel.stagedSnipCount
            )
            return String.localizedStringWithFormat(
                NSLocalizedString("accessibility.graph.toolbar.mode.state_with_detail",
                                  comment: "Graph toolbar mode state followed by detail"),
                modeState ?? "",
                detail
            )
        }
        return modeState ?? ""
    }

    private func performSnip() {
        viewModel.activateSnip()
    }

    private func performArchive() {
        viewModel.activateArchive(selectedThreadID: selectedThreadID)
    }

    private func plainButton(systemImage: String,
                             title: String,
                             accessibilityID: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(DesignTokens.font(size: 12, weight: .semibold, textScale: textScale))
                .frame(minWidth: 24, minHeight: 24)
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityID)
        .help(title)
    }
}
