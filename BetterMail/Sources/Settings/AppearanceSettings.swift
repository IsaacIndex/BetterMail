import Combine
import SwiftUI

internal enum AppAppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    internal static let defaultMode: AppAppearanceMode = .system

    internal static func resolvedMode(from storedValue: String) -> AppAppearanceMode {
        AppAppearanceMode(rawValue: storedValue) ?? defaultMode
    }

    internal var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    internal var localizedTitle: String {
        switch self {
        case .system:
            return NSLocalizedString("settings.appearance.mode.system", comment: "System appearance mode option")
        case .light:
            return NSLocalizedString("settings.appearance.mode.light", comment: "Light appearance mode option")
        case .dark:
            return NSLocalizedString("settings.appearance.mode.dark", comment: "Dark appearance mode option")
        }
    }
}

@MainActor
internal final class AppearanceSettings: ObservableObject {
    @AppStorage("appAppearanceMode") private var storedMode = AppAppearanceMode.defaultMode.rawValue

    @Published internal var mode: AppAppearanceMode = AppAppearanceMode.defaultMode {
        didSet {
            storedMode = mode.rawValue
        }
    }

    internal var preferredColorScheme: ColorScheme? {
        mode.preferredColorScheme
    }

    internal init() {
        let resolvedMode = AppAppearanceMode.resolvedMode(from: _storedMode.wrappedValue)
        if resolvedMode.rawValue != _storedMode.wrappedValue {
            storedMode = resolvedMode.rawValue
        }
        mode = resolvedMode
    }
}
