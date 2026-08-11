import SwiftUI

internal struct GraphToolbar: View {
    @ObservedObject internal var viewModel: GraphCanvasViewModel
    @ObservedObject internal var settings: GraphCanvasSettings
    internal let textScale: CGFloat
    internal let selectedThreadID: String?

    internal var body: some View {
        HStack(spacing: 6) {
            toolbarButton(title: NSLocalizedString("graph.toolbar.snip", comment: "Graph snip mode"),
                          systemImage: "scissors",
                          isOn: viewModel.pruneMode == .snip,
                          tint: DesignTokens.Graph.AppTheme.snip,
                          accessibilityID: AccessibilityID.graphToolbarSnip,
                          help: selectedThreadID == nil
                          ? NSLocalizedString("graph.toolbar.snip.help.mode",
                                              comment: "Help for entering graph branch snip mode")
                          : NSLocalizedString("graph.toolbar.snip.help.selected",
                                              comment: "Help for snipping the selected graph thread"),
                          action: performSnip)
            toolbarButton(title: NSLocalizedString("graph.toolbar.archive", comment: "Graph archive mode"),
                          systemImage: "archivebox",
                          isOn: viewModel.pruneMode == .archive,
                          tint: DesignTokens.Graph.AppTheme.archive,
                          accessibilityID: AccessibilityID.graphToolbarArchive,
                          help: selectedThreadID == nil
                          ? NSLocalizedString("graph.toolbar.archive.help.mode",
                                              comment: "Help for entering graph branch archive mode")
                          : NSLocalizedString("graph.toolbar.archive.help.selected",
                                              comment: "Help for archiving the selected graph thread"),
                          action: performArchive)
            Divider()
                .frame(height: 18)
            plainButton(systemImage: "minus.magnifyingglass",
                        title: NSLocalizedString("graph.toolbar.zoom_out", comment: "Graph zoom out"),
                        accessibilityID: AccessibilityID.graphToolbarZoomOut,
                        action: viewModel.zoomOut)
            Text("\(Int((viewModel.zoomScale * 100).rounded()))%")
                .font(DesignTokens.font(size: 10.5, weight: .medium, textScale: textScale))
                .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                .frame(width: 46)
            plainButton(systemImage: "plus.magnifyingglass",
                        title: NSLocalizedString("graph.toolbar.zoom_in", comment: "Graph zoom in"),
                        accessibilityID: AccessibilityID.graphToolbarZoomIn,
                        action: viewModel.zoomIn)
            plainButton(systemImage: "scope",
                        title: NSLocalizedString("graph.toolbar.recenter", comment: "Graph recenter"),
                        accessibilityID: AccessibilityID.graphToolbarRecenter,
                        action: viewModel.resetViewport)
            plainButton(systemImage: "slider.horizontal.3",
                        title: NSLocalizedString("graph.toolbar.settings", comment: "Graph settings"),
                        accessibilityID: AccessibilityID.graphToolbarSettings,
                        action: { viewModel.isSettingsPresented = true })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignTokens.Graph.AppTheme.panel)
                .shadow(color: Color.black.opacity(0.10), radius: 18, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
        .accessibilityIdentifier(AccessibilityID.graphToolbar)
    }

    private func toolbarButton(title: String,
                               systemImage: String,
                               isOn: Bool,
                               tint: Color,
                               accessibilityID: String,
                               help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(DesignTokens.font(size: 12, weight: .semibold, textScale: textScale))
                .frame(minWidth: 84, minHeight: 26)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(isOn ? Color.white : DesignTokens.Graph.AppTheme.inkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isOn ? tint : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityID)
        .help(help)
    }

    private func performSnip() {
        viewModel.activateSnip(selectedThreadID: selectedThreadID)
    }

    private func performArchive() {
        viewModel.activateArchive(selectedThreadID: selectedThreadID)
    }

    private func plainButton(systemImage: String,
                             title: String,
                             accessibilityID: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DesignTokens.font(size: 12, weight: .semibold, textScale: textScale))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DesignTokens.Graph.AppTheme.panelSecondary.opacity(0.001))
                )
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityID)
        .help(title)
    }
}
