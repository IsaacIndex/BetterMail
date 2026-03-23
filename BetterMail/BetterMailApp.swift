//
//  BetterMailApp.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import SwiftUI

@main
internal struct BetterMailApp: App {
    @StateObject private var settings = AutoRefreshSettings()
    @StateObject private var inspectorSettings = InspectorViewSettings()
    @StateObject private var displaySettings = ThreadCanvasDisplaySettings()
    @StateObject private var pinnedFolderSettings = PinnedFolderSettings()
    @StateObject private var appearanceSettings = AppearanceSettings()

    @FocusedValue(\.canvasViewModel) private var focusedViewModel
    @FocusedValue(\.displaySettings) private var focusedDisplaySettings

    internal var body: some Scene {
        WindowGroup {
            ContentView(settings: settings,
                        inspectorSettings: inspectorSettings,
                        displaySettings: displaySettings,
                        pinnedFolderSettings: pinnedFolderSettings)
                .preferredColorScheme(appearanceSettings.preferredColorScheme)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    focusedViewModel?.refreshNow()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Toggle Inspector") {
                    guard let vm = focusedViewModel else { return }
                    if vm.selectedNodeID != nil || vm.selectedFolderID != nil {
                        vm.selectNode(id: nil)
                        vm.selectFolder(id: nil)
                    }
                }
                .keyboardShortcut("i", modifiers: .command)

                Divider()

                Button("Reset Zoom") {
                    focusedDisplaySettings?.updateCurrentZoom(1.0)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Zoom In") {
                    guard let ds = focusedDisplaySettings else { return }
                    ds.updateCurrentZoom(ds.currentZoom + 0.1)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    guard let ds = focusedDisplaySettings else { return }
                    ds.updateCurrentZoom(ds.currentZoom - 0.1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Divider()

                Button("Deselect") {
                    focusedViewModel?.selectNode(id: nil)
                    focusedViewModel?.selectFolder(id: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Show Action Items") {
                    focusedViewModel?.selectMailboxScope(.actionItems)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }
        Settings {
            AutoRefreshSettingsView(settings: settings,
                                    inspectorSettings: inspectorSettings,
                                    displaySettings: displaySettings,
                                    appearanceSettings: appearanceSettings)
                .preferredColorScheme(appearanceSettings.preferredColorScheme)
        }
    }
}
