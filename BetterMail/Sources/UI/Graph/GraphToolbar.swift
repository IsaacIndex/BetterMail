import SwiftUI

internal struct GraphToolbar: View {
    @ObservedObject internal var viewModel: GraphCanvasViewModel
    @ObservedObject internal var settings: GraphCanvasSettings
    internal let textScale: CGFloat

    internal var body: some View {
        HStack(spacing: 6) {
            toolbarButton(title: NSLocalizedString("graph.toolbar.snip", comment: "Graph snip mode"),
                          systemImage: "scissors",
                          isOn: viewModel.pruneMode == .snip,
                          tint: DesignTokens.Graph.snip,
                          accessibilityID: AccessibilityID.graphToolbarSnip,
                          action: viewModel.toggleSnipMode)
            toolbarButton(title: NSLocalizedString("graph.toolbar.archive", comment: "Graph archive mode"),
                          systemImage: "archivebox",
                          isOn: viewModel.pruneMode == .archive,
                          tint: DesignTokens.Graph.archive,
                          accessibilityID: AccessibilityID.graphToolbarArchive,
                          action: viewModel.toggleArchiveMode)
            Divider()
                .frame(height: 22)
            plainButton(systemImage: "minus.magnifyingglass",
                        accessibilityID: AccessibilityID.graphToolbarZoomOut,
                        action: viewModel.zoomOut)
            Text("\(Int((viewModel.zoomScale * 100).rounded()))%")
                .font(DesignTokens.font(size: 10.5, weight: .medium, textScale: textScale))
                .foregroundStyle(DesignTokens.Graph.inkSecondary)
                .frame(width: 46)
            plainButton(systemImage: "plus.magnifyingglass",
                        accessibilityID: AccessibilityID.graphToolbarZoomIn,
                        action: viewModel.zoomIn)
            plainButton(systemImage: "scope",
                        accessibilityID: AccessibilityID.graphToolbarRecenter,
                        action: viewModel.resetViewport)
            plainButton(systemImage: "slider.horizontal.3",
                        accessibilityID: AccessibilityID.graphToolbarSettings,
                        action: { viewModel.isSettingsPresented = true })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignTokens.Graph.panel)
                .shadow(color: Color.black.opacity(0.10), radius: 18, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DesignTokens.Graph.line, lineWidth: 1)
        )
        .accessibilityIdentifier(AccessibilityID.graphToolbar)
    }

    private func toolbarButton(title: String,
                               systemImage: String,
                               isOn: Bool,
                               tint: Color,
                               accessibilityID: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(DesignTokens.font(size: 12, weight: .semibold, textScale: textScale))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(isOn ? Color.white : DesignTokens.Graph.inkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isOn ? tint : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityIdentifier(accessibilityID)
    }

    private func plainButton(systemImage: String,
                             accessibilityID: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DesignTokens.font(size: 12, weight: .semibold, textScale: textScale))
                .frame(width: 24, height: 24)
                .foregroundStyle(DesignTokens.Graph.inkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DesignTokens.Graph.panelSecondary.opacity(0.001))
                )
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityIdentifier(accessibilityID)
    }
}
