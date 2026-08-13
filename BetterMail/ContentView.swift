import SwiftUI

internal struct ContentView: View {
    @ObservedObject internal var settings: AutoRefreshSettings
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    @ObservedObject internal var pinnedFolderSettings: PinnedFolderSettings
    @ObservedObject internal var activityCenter: ProcessingActivityCenter
    @StateObject private var viewModel: ThreadCanvasViewModel

    internal init(settings: AutoRefreshSettings,
                  inspectorSettings: InspectorViewSettings,
                  displaySettings: ThreadCanvasDisplaySettings,
                  pinnedFolderSettings: PinnedFolderSettings,
                  activityCenter: ProcessingActivityCenter) {
        self.settings = settings
        self.inspectorSettings = inspectorSettings
        self.displaySettings = displaySettings
        self.pinnedFolderSettings = pinnedFolderSettings
        self.activityCenter = activityCenter
        _viewModel = StateObject(wrappedValue: ThreadCanvasViewModel(settings: settings,
                                                                     inspectorSettings: inspectorSettings,
                                                                     pinnedFolderSettings: pinnedFolderSettings,
                                                                     activityCenter: activityCenter))
    }

    internal var body: some View {
        NavigationSplitView {
            MailboxSidebarView(viewModel: viewModel)
                .frame(minWidth: 220, idealWidth: 260)
        } detail: {
            if viewModel.activeMailboxScope == .actionItems {
                ActionItemsView(viewModel: viewModel,
                                inspectorSettings: inspectorSettings,
                                textScale: displaySettings.textScale)
                    .frame(minWidth: 480, minHeight: 400)
            } else {
                ThreadListView(viewModel: viewModel,
                               settings: settings,
                               inspectorSettings: inspectorSettings,
                               displaySettings: displaySettings)
                    .frame(minWidth: 720, minHeight: 520)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .overlayPreferenceValue(GraphCompostPanelAnchorPreferenceKey.self) { compostPanelAnchor in
            GeometryReader { proxy in
                let compostPanelTop = compostPanelAnchor.map { proxy[$0].minY }
                let bottomInset = ProcessingActivityShelfLayout.bottomInset(
                    containerHeight: proxy.size.height,
                    compostPanelTop: compostPanelTop
                )

                ProcessingActivityShelf(activityCenter: activityCenter)
                    .padding(.trailing, ProcessingActivityShelfLayout.defaultTrailingInset)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity,
                           maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .zIndex(10)
            }
        }
        .accessibilityIdentifier(AccessibilityID.contentRoot)
        .focusedValue(\.canvasViewModel, viewModel)
        .focusedValue(\.displaySettings, displaySettings)
        .task {
            viewModel.start()
        }
    }
}

internal enum ProcessingActivityShelfLayout {
    internal static let defaultTrailingInset: CGFloat = 18
    internal static let defaultBottomInset: CGFloat = 18
    internal static let compostGap: CGFloat = 8

    internal static func bottomInset(containerHeight: CGFloat,
                                    compostPanelTop: CGFloat?) -> CGFloat {
        guard containerHeight.isFinite,
              containerHeight > 0,
              let compostPanelTop,
              compostPanelTop.isFinite else {
            return defaultBottomInset
        }

        return max(defaultBottomInset,
                   containerHeight - compostPanelTop + compostGap)
    }
}
