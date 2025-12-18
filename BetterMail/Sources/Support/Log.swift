import Foundation
import OSLog

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "BetterMail"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let refresh = Logger(subsystem: subsystem, category: "refresh")
    static let appleScript = Logger(subsystem: subsystem, category: "applescript")
}
