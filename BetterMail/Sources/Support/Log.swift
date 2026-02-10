import Foundation
import OSLog

internal enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "BetterMail"

    internal static let app = Logger(subsystem: subsystem, category: "app")
    internal static let refresh = Logger(subsystem: subsystem, category: "refresh")
    internal static let appleScript = Logger(subsystem: subsystem, category: "applescript")
    internal static let performance = OSLog(subsystem: subsystem, category: "performance")
}
