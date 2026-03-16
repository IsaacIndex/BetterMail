//
//  AppleScriptRunner.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import Foundation
import Cocoa
import OSLog

internal enum AppleScriptError: Error, LocalizedError {
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .executionFailed(message):
            return message
        }
    }
}

internal actor NSAppleScriptRunner {
    internal enum ScriptError: Error, LocalizedError {
        case compileFailed
        case executionFailed(NSDictionary)

        var errorDescription: String? {
            switch self {
            case .compileFailed:
                return "Failed to compile AppleScript."
            case let .executionFailed(dict):
                return "AppleScript error: \(dict)"
            }
        }
    }

    internal func run(_ source: String, logPrefix: String? = nil) throws -> NSAppleEventDescriptor {
        try Task.checkCancellation()
        try ensureMailRunning(logPrefix: logPrefix)
        try Task.checkCancellation()

        guard let script = NSAppleScript(source: source) else { throw ScriptError.compileFailed }

        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        try Task.checkCancellation()
        if let err { throw ScriptError.executionFailed(err) }
        return result
    }
}

private func ensureMailRunning(timeout: TimeInterval = 10, logPrefix: String? = nil) throws {
    let bundleID = "com.apple.mail"

    // If Mail is already running, return
    if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
        Log.appleScript.debug("\(prefixedLogMessage(logPrefix, "Mail already running; no launch needed."), privacy: .public)")
        return
    }

    Log.appleScript.info("\(prefixedLogMessage(logPrefix, "Mail is not running. Launching Mail.app"), privacy: .public)")
    // Explicitly launch Mail
    let url = URL(fileURLWithPath: "/System/Applications/Mail.app")
    let config = NSWorkspace.OpenConfiguration()
    try NSWorkspace.shared.openApplication(at: url, configuration: config)

    // Wait until it appears as running (max `timeout` seconds)
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
            let elapsed = Date().timeIntervalSince(start)
            Log.appleScript.info("\(prefixedLogMessage(logPrefix, "Mail launch confirmed after \(elapsed)s"), privacy: .public)")
            return
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    Log.appleScript.error("\(prefixedLogMessage(logPrefix, "Timed out waiting for Mail to launch after \(timeout)s"), privacy: .public)")
    throw AppleScriptError.executionFailed("Timed out waiting for Mail to launch")
}

private func prefixedLogMessage(_ prefix: String?, _ message: String) -> String {
    guard let prefix, !prefix.isEmpty else { return message }
    return "\(prefix) \(message)"
}


private func debugContext(_ whereAmI: String) {
    print("🔍 [\(whereAmI)]")
    print("  bundleIdentifier =", Bundle.main.bundleIdentifier ?? "nil")
    print("  processName      =", ProcessInfo.processInfo.processName)
}

internal func runAppleScript(_ script: String) throws -> NSAppleEventDescriptor {
    try ensureMailRunning()
    
    debugContext("runAppleScript caller")
    let preview = script.split(separator: "\n").first.map(String.init) ?? "empty script"
    Log.appleScript.debug("Executing AppleScript. length=\(script.count, privacy: .public) firstLine=\(preview, privacy: .public)")

    guard let appleScript = NSAppleScript(source: script) else {
        Log.appleScript.error("Failed to initialize NSAppleScript (source invalid).")
        throw AppleScriptError.executionFailed("Invalid AppleScript source")
    }

    var errorDict: NSDictionary?
    let result = appleScript.executeAndReturnError(&errorDict)

    if let errorDict = errorDict {
        let message = errorDict[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        let number = errorDict[NSAppleScript.errorNumber] as? Int ?? 0
        let range = errorDict[NSAppleScript.errorRange] as? NSValue
        Log.appleScript.error("AppleScript execution failed. message=\(message, privacy: .public) code=\(number, privacy: .public) range=\(String(describing: range), privacy: .public)")
        throw AppleScriptError.executionFailed(message)
    }

    Log.appleScript.debug("AppleScript executed successfully.")
    return result
}
