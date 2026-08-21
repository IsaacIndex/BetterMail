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
        .overlay(alignment: .bottomTrailing) {
            ProcessingActivityShelf(activityCenter: activityCenter)
                .padding(.trailing, ProcessingActivityShelfLayout.trailingInset)
                .padding(.bottom, ProcessingActivityShelfLayout.bottomInset)
                .zIndex(10)
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
    internal static let trailingInset: CGFloat = 18
    internal static let bottomInset: CGFloat = 18
}
