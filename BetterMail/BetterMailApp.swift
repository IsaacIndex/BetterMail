//
//  BetterMailApp.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import SwiftUI

@main
struct BetterMailApp: App {
    @StateObject private var selfAddressStore = SelfAddressStore()

    var body: some Scene {
        WindowGroup {
            ContentView(selfAddressStore: selfAddressStore)
        }
        Settings {
            SelfAddressSettingsView(store: selfAddressStore)
        }
    }
}
