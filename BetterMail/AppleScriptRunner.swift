//
//  AppleScriptRunner.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import Foundation
import Cocoa
import OSLog

internal enum AppleScriptError: Error {
    case executionFailed(String)
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

    internal func run(_ source: String) throws -> NSAppleEventDescriptor {
        try ensureMailRunning()

        guard let script = NSAppleScript(source: source) else { throw ScriptError.compileFailed }

        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err { throw ScriptError.executionFailed(err) }
        return result
    }
}

private func ensureMailRunning(timeout: TimeInterval = 10) throws {
    let bundleID = "com.apple.mail"

    // If Mail is already running, return
    if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
        Log.appleScript.debug("Mail already running; no launch needed.")
        return
    }

    Log.appleScript.info("Mail is not running. Launching Mail.app")
    // Explicitly launch Mail
    let url = URL(fileURLWithPath: "/System/Applications/Mail.app")
    let config = NSWorkspace.OpenConfiguration()
    try NSWorkspace.shared.openApplication(at: url, configuration: config)

    // Wait until it appears as running (max `timeout` seconds)
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
            let elapsed = Date().timeIntervalSince(start)
            Log.appleScript.info("Mail launch confirmed after \(elapsed, privacy: .public)s")
            return
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    Log.appleScript.error("Timed out waiting for Mail to launch after \(timeout, privacy: .public)s")
    throw AppleScriptError.executionFailed("Timed out waiting for Mail to launch")
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
