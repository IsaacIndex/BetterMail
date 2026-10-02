//
//  BetterMailApp.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import Foundation
import SwiftUI

@main
internal struct BetterMailApp: App {
    @StateObject private var settings: AutoRefreshSettings
    @StateObject private var mailAccountSelectionSettings: MailAccountSelectionSettings
    @StateObject private var inspectorSettings: InspectorViewSettings
    @StateObject private var displaySettings: ThreadCanvasDisplaySettings
    @StateObject private var pinnedFolderSettings: PinnedFolderSettings
    @StateObject private var appearanceSettings: AppearanceSettings
    @StateObject private var activityCenter: ProcessingActivityCenter

#if DEBUG
    private let organizerBenchmarkLaunchSelection: OrganizerBenchmarkLaunchSelection
    private let runsAsXCTestHost: Bool
#endif

    @FocusedValue(\.canvasViewModel) private var focusedViewModel
    @FocusedValue(\.displaySettings) private var focusedDisplaySettings

    internal init() {
        let defaults: UserDefaults
#if DEBUG
        let processInfo = ProcessInfo.processInfo
        let isXCTestHost = Self.isXCTestHost(environment: processInfo.environment)
        runsAsXCTestHost = isXCTestHost
        var benchmarkSelection: OrganizerBenchmarkLaunchSelection = isXCTestHost
            ? .inactive
            : OrganizerBenchmarkLaunchSelection.parse(arguments: processInfo.arguments)
        if !isXCTestHost, case .active(let configuration) = benchmarkSelection {
            do {
                try OrganizerBenchmarkEnvironment.prepare(configuration)
            } catch {
                benchmarkSelection = .invalid(
                    error.localizedDescription.isEmpty
                        ? "The synthetic benchmark workspace could not be prepared."
                        : error.localizedDescription
                )
            }
        }
        organizerBenchmarkLaunchSelection = benchmarkSelection
        if isXCTestHost {
            defaults = UserDefaults(
                suiteName: "com.bettermail.xctest-host.\(processInfo.processIdentifier)"
            ) ?? .standard
        } else {
            switch benchmarkSelection {
            case .active(let configuration):
                defaults = UserDefaults(suiteName: configuration.defaultsSuiteName) ?? .standard
            case .invalid:
                defaults = UserDefaults(suiteName: "com.bettermail.organizer-benchmark.invalid") ?? .standard
            case .inactive:
                defaults = .standard
            }
        }
#else
        defaults = .standard
#endif
        _settings = StateObject(wrappedValue: AutoRefreshSettings(userDefaults: defaults))
        let mailAccountSelectionSettings = MailAccountSelectionSettings(userDefaults: defaults)
        if let launchAccount = Self.mailAccountLaunchOverride(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            mailAccountSelectionSettings.selectAccount(named: launchAccount)
        }
        _mailAccountSelectionSettings = StateObject(
            wrappedValue: mailAccountSelectionSettings
        )
        _inspectorSettings = StateObject(wrappedValue: InspectorViewSettings(userDefaults: defaults))
        _displaySettings = StateObject(wrappedValue: ThreadCanvasDisplaySettings(userDefaults: defaults))
        _pinnedFolderSettings = StateObject(wrappedValue: PinnedFolderSettings(userDefaults: defaults))
        _appearanceSettings = StateObject(wrappedValue: AppearanceSettings(userDefaults: defaults))
        _activityCenter = StateObject(wrappedValue: ProcessingActivityCenter())
    }

    internal var body: some Scene {
        WindowGroup {
            rootContent
                .preferredColorScheme(appearanceSettings.preferredColorScheme)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    focusedViewModel?.refreshNow()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(NSLocalizedString("graph.automation.command.open",
                                         comment: "Open graph automation queue app command")) {
                    focusedViewModel?.presentGraphAutomation()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

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
        MenuBarExtra {
            ProcessingActivityMenuContent(activityCenter: activityCenter)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: activityCenter.hasActiveActivity ? "bolt.horizontal.circle.fill" : "checkmark.circle")
                if activityCenter.activeCount > 0 {
                    Text("\(activityCenter.activeCount)")
                }
            }
        }
        .menuBarExtraStyle(.window)
        Settings {
            AutoRefreshSettingsView(settings: settings,
                                    mailAccountSelectionSettings: mailAccountSelectionSettings,
                                    inspectorSettings: inspectorSettings,
                                    displaySettings: displaySettings,
                                    appearanceSettings: appearanceSettings,
                                    activityCenter: activityCenter)
                .preferredColorScheme(appearanceSettings.preferredColorScheme)
        }
    }

    @ViewBuilder
    private var rootContent: some View {
#if DEBUG
        if runsAsXCTestHost {
            Color.clear
        } else {
            switch organizerBenchmarkLaunchSelection {
            case .inactive:
                productionContent
            case .active(let configuration):
                OrganizerBenchmarkRootView(configuration: configuration,
                                           settings: settings,
                                           inspectorSettings: inspectorSettings,
                                           displaySettings: displaySettings,
                                           pinnedFolderSettings: pinnedFolderSettings,
                                           activityCenter: activityCenter)
            case .invalid(let message):
                OrganizerBenchmarkLaunchErrorView(message: message)
            }
        }
#else
        productionContent
#endif
    }

    internal nonisolated static func mailAccountLaunchOverride(arguments: [String]) -> String? {
        guard let optionIndex = arguments.firstIndex(of: "--mail-account"),
              arguments.indices.contains(optionIndex + 1) else {
            return nil
        }
        return MailAccountSelectionSettings.normalizedAccountName(arguments[optionIndex + 1])
    }

#if DEBUG
    internal nonisolated static func isXCTestHost(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
#endif

    private var productionContent: some View {
        ContentView(settings: settings,
                    mailAccountSelectionSettings: mailAccountSelectionSettings,
                    inspectorSettings: inspectorSettings,
                    displaySettings: displaySettings,
                    pinnedFolderSettings: pinnedFolderSettings,
                    activityCenter: activityCenter)
    }
}
