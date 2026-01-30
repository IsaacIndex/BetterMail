# Architecture Overview

BetterMail is a macOS SwiftUI app that builds a threaded email canvas on top of Apple Mail.
The system is composed of ingestion, storage, threading, presentation, and optional summary layers.

## High-Level Components

- Ingestion: `MailAppleScriptClient` queries Apple Mail via AppleScript.
- Storage: `MessageStore` persists messages, threads, folders, and summaries in Core Data.
- Threading: `JWZThreader` builds threads and thread maps using JWZ-style references.
- Presentation: `ThreadCanvasViewModel` feeds SwiftUI views (`ThreadCanvasView`, `ThreadInspectorView`).
- Summaries: `EmailSummaryProvider` adds Apple Intelligence summaries when available.
- Tags: `EmailTagProvider` adds Apple Intelligence message tags when available.
- MailKit helper: `MailHelperExtension` ships example handlers for MailKit extension points.

## Guiding Principles

- Keep UI state on the main actor; move heavy work into background tasks or actors.
- Preserve behavior when refactoring; changes should be mechanical and test-backed.
- Prefer explicit access control and Swift API Design Guidelines.

## Key Entry Points

- App entry: `BetterMail/BetterMailApp.swift`
- Root view: `BetterMail/ContentView.swift`
- Canvas container: `BetterMail/Sources/UI/ThreadListView.swift`
