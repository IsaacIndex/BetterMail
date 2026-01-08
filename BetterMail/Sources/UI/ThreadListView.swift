import AppKit
import SwiftUI

struct ThreadListView: View {
    @ObservedObject var viewModel: ThreadCanvasViewModel
    @ObservedObject var settings: AutoRefreshSettings
    @ObservedObject var inspectorSettings: InspectorViewSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var navHeight: CGFloat = 96

    private let navCornerRadius: CGFloat = 18
    private let navHorizontalPadding: CGFloat = 16
    private let navTopPadding: CGFloat = 12
    private let navBottomSpacing: CGFloat = 12
    private let navCanvasSpacing: CGFloat = 6
    private let inspectorWidth: CGFloat = 320

    var body: some View {
        content
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

    private var content: some View {
        ZStack(alignment: .top) {
            GlassWindowBackground()
                .ignoresSafeArea()
            glassLayeredContent
        }
    }

    @ViewBuilder
    private var glassLayeredContent: some View {
        if #available(macOS 26, *) {
            layeredContent
        } else {
            layeredContent
        }
    }

    private var layeredContent: some View {
        ZStack(alignment: .top) {
            if #available(macOS 26, *) {
                GlassEffectContainer {
                    canvasContent
                }
            } else {
                canvasContent
            }
            inspectorOverlay
            navigationBarOverlay
        }
    }

    private var canvasContent: some View {
        ThreadCanvasView(viewModel: viewModel,
                         selectedNodeID: selectionBinding,
                         topInset: canvasTopPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, navHorizontalPadding)
    }

    private var inspectorOverlay: some View {
        ThreadInspectorView(node: viewModel.selectedNode,
                            summaryState: selectedSummaryState,
                            summaryExpansion: selectedSummaryExpansion,
                            inspectorSettings: inspectorSettings,
                            onOpenInMail: viewModel.openMessageInMail)
            .frame(width: inspectorWidth)
            .padding(.top, navInsetHeight)
            .padding(.trailing, navHorizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .zIndex(0.5)
    }

    private var navInsetHeight: CGFloat {
        max(navHeight + navTopPadding + navBottomSpacing, 88)
    }

    private var canvasTopPadding: CGFloat {
        navHeight + navTopPadding + navCanvasSpacing
    }

    private var navigationBarOverlay: some View {
        navBar
            .padding(.horizontal, navHorizontalPadding)
            .padding(.top, navTopPadding)
            .onPreferenceChange(NavHeightPreferenceKey.self) { navHeight = $0 }
            .zIndex(1)
    }

    private var isGlassNavEnabled: Bool {
        if #available(macOS 26, *) {
            return !reduceTransparency
        }
        return false
    }

    private var navPrimaryForegroundStyle: Color {
        isGlassNavEnabled ? Color.white : Color.primary
    }

    private var navSecondaryForegroundStyle: Color {
        isGlassNavEnabled ? Color.white.opacity(0.75) : Color.secondary
    }

    @ViewBuilder
    private var navBar: some View {
        if isGlassNavEnabled {
            navBarContent
                .colorScheme(.dark)
        } else {
            navBarContent
        }
    }

    private var navBarContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Threads")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(navSecondaryForegroundStyle)
                refreshTimingView
            }
            Spacer()
            if viewModel.isRefreshing {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("Limit")
                    .font(.caption)
                    .foregroundStyle(navSecondaryForegroundStyle)
                limitField
            }
            .fixedSize()
            refreshButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(navPrimaryForegroundStyle)
        .shadow(color: Color.black.opacity(isGlassNavEnabled ? 0.45 : 0), radius: 1.5, x: 0, y: 1)
        .background(navBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(reduceTransparency ? 0.2 : 0.12))
                .frame(height: 1)
                .blur(radius: reduceTransparency ? 0 : 0.5)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: NavHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
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
                    .foregroundStyle(navSecondaryForegroundStyle)
            }
            if settings.isEnabled, let nextRefreshDate = viewModel.nextRefreshDate {
                Text("Next refresh: \(nextRefreshDate.formatted(date: .numeric, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(navSecondaryForegroundStyle)
            }
        }
    }

    @ViewBuilder
    private var limitField: some View {
        if isGlassNavEnabled {
            TextField("Limit", value: $viewModel.fetchLimit, format: .number)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.55))
                )
                .foregroundStyle(Color.white)
                .tint(Color.white)
                .frame(width: 60)
        } else {
            TextField("Limit", value: $viewModel.fetchLimit, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        let button = Button(action: { viewModel.refreshNow() }) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isRefreshing)

        if #available(macOS 26, *) {
            button.buttonStyle(.glass)
        } else {
            button
        }
    }

    @ViewBuilder
    private var navBackground: some View {
        let shape = RoundedRectangle(cornerRadius: navCornerRadius, style: .continuous)
        if reduceTransparency {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.96))
                .overlay(shape.stroke(Color.white.opacity(0.3)))
        } else if #available(macOS 26, *) {
            shape
                .fill(Color.white.opacity(0.08))
                .glassEffect(
                    .regular
                        .tint(Color.white.opacity(0.2))
                        .interactive(),
                    in: .rect(cornerRadius: navCornerRadius)
                )
                .overlay(shape.stroke(Color.white.opacity(0.35)))
                .shadow(color: Color.black.opacity(0.25), radius: 16, y: 8)
        } else {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.9))
                .overlay(shape.stroke(Color.white.opacity(0.25)))
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedNodeID },
            set: { viewModel.selectNode(id: $0) }
        )
    }

    private var selectedSummaryState: ThreadSummaryState? {
        guard let selectedNodeID = viewModel.selectedNodeID,
              let rootID = viewModel.rootID(containing: selectedNodeID) else {
            return nil
        }
        return viewModel.summaryState(for: rootID)
    }

    private var selectedSummaryExpansion: Binding<Bool>? {
        guard let selectedNodeID = viewModel.selectedNodeID,
              let rootID = viewModel.rootID(containing: selectedNodeID) else {
            return nil
        }
        return Binding(
            get: { viewModel.isSummaryExpanded(for: rootID) },
            set: { viewModel.setSummaryExpanded($0, for: rootID) }
        )
    }
}

private struct NavHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
