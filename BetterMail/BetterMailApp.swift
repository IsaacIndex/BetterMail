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

    internal var body: some Scene {
        WindowGroup {
            ContentView(settings: settings,
                        inspectorSettings: inspectorSettings,
                        displaySettings: displaySettings)
        }
        Settings {
            AutoRefreshSettingsView(settings: settings,
                                    inspectorSettings: inspectorSettings,
                                    displaySettings: displaySettings)
        }
    }
}
