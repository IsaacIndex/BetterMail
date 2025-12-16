//
//  AppleScriptRunner.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import Foundation
import Cocoa

enum AppleScriptError: Error {
    case executionFailed(String)
}

func ensureMailRunning(timeout: TimeInterval = 10) throws {
    let bundleID = "com.apple.mail"

    // If Mail is already running, return
    if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
        return
    }

    // Explicitly launch Mail
    let url = URL(fileURLWithPath: "/System/Applications/Mail.app")
    let config = NSWorkspace.OpenConfiguration()
    try NSWorkspace.shared.openApplication(at: url, configuration: config)

    // Wait until it appears as running (max `timeout` seconds)
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
            return
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    throw AppleScriptError.executionFailed("Timed out waiting for Mail to launch")
}


func debugContext(_ whereAmI: String) {
    print("🔍 [\(whereAmI)]")
    print("  bundleIdentifier =", Bundle.main.bundleIdentifier ?? "nil")
    print("  processName      =", ProcessInfo.processInfo.processName)
}

func runAppleScript(_ script: String) throws -> NSAppleEventDescriptor {
    try ensureMailRunning()
    
    debugContext("runAppleScript caller")

    guard let appleScript = NSAppleScript(source: script) else {
        throw AppleScriptError.executionFailed("Invalid AppleScript source")
    }

    var errorDict: NSDictionary?
    let result = appleScript.executeAndReturnError(&errorDict)

    if let errorDict = errorDict {
        let message = errorDict[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        throw AppleScriptError.executionFailed(message)
    }

    return result
}
