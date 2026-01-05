//
//  BetterMailApp.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import SwiftUI

@main
struct BetterMailApp: App {
    @StateObject private var settings = AutoRefreshSettings()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings)
        }
        Settings {
            AutoRefreshSettingsView(settings: settings)
        }
    }
}
