import Combine
import Foundation
import SwiftUI

@MainActor
internal final class AutoRefreshSettings: ObservableObject {
    internal static let minimumInterval: TimeInterval = 60
    internal static let maximumInterval: TimeInterval = 3600
    internal static let defaultInterval: TimeInterval = 300

    @AppStorage("autoRefreshEnabled") private var storedEnabled = false
    @AppStorage("autoRefreshIntervalSeconds") private var storedInterval = AutoRefreshSettings.defaultInterval

    @Published internal var isEnabled: Bool = false {
        didSet {
            storedEnabled = isEnabled
        }
    }

    @Published internal var interval: TimeInterval = AutoRefreshSettings.defaultInterval {
        didSet {
            let clamped = Self.clampInterval(interval)
            if clamped != interval {
                interval = clamped
                return
            }
            storedInterval = clamped
        }
    }

    internal init() {
        let normalized = Self.clampInterval(_storedInterval.wrappedValue)
        storedInterval = normalized
        isEnabled = _storedEnabled.wrappedValue
        interval = normalized
    }

    private static func clampInterval(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minimumInterval), maximumInterval)
    }
}
