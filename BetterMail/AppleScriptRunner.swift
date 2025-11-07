//
//  AppleScriptRunner.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import Cocoa

enum AppleScriptError: Error { case execution(String) }

@discardableResult
func runAppleScript(_ source: String) throws -> NSAppleEventDescriptor? {
    var err: NSDictionary?
    let script = NSAppleScript(source: source)!
    let result = script.executeAndReturnError(&err)
    if let e = err {
        throw AppleScriptError.execution(e.description)
    }
    return result
}
