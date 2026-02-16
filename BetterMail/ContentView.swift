import SwiftUI

internal struct ContentView: View {
    @ObservedObject internal var settings: AutoRefreshSettings
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    @ObservedObject internal var pinnedFolderSettings: PinnedFolderSettings
    @StateObject private var viewModel: ThreadCanvasViewModel

    internal init(settings: AutoRefreshSettings,
                  inspectorSettings: InspectorViewSettings,
                  displaySettings: ThreadCanvasDisplaySettings,
                  pinnedFolderSettings: PinnedFolderSettings) {
        self.settings = settings
        self.inspectorSettings = inspectorSettings
        self.displaySettings = displaySettings
        self.pinnedFolderSettings = pinnedFolderSettings
        _viewModel = StateObject(wrappedValue: ThreadCanvasViewModel(settings: settings,
                                                                     inspectorSettings: inspectorSettings,
                                                                     pinnedFolderSettings: pinnedFolderSettings))
    }

    internal var body: some View {
        NavigationSplitView {
            MailboxSidebarView(viewModel: viewModel)
                .frame(minWidth: 220, idealWidth: 260)
        } detail: {
            ThreadListView(viewModel: viewModel,
                           settings: settings,
                           inspectorSettings: inspectorSettings,
                           displaySettings: displaySettings)
                .frame(minWidth: 720, minHeight: 520)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
