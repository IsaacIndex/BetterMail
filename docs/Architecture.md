# Architecture Overview

BetterMail is a macOS SwiftUI app that builds a threaded email canvas on top of Apple Mail.
The system is composed of ingestion, storage, threading, presentation, and optional summary layers.

## High-Level Components

- Ingestion: `MailAppleScriptClient` queries Apple Mail via AppleScript.
- Fetch coordination: `DayFetchCoordinator` serializes uncapped day manifests, bounded ID-based payload requests, manifest verification, and authoritative reconciliation for refresh and backfill.
- Storage: `MessageStore` persists messages, source-absence audit state, per-concrete-mailbox day coverage, threads, folders, and summaries in Core Data.
- Threading: `JWZThreader` builds threads and thread maps using JWZ-style references.
- Presentation: `ThreadCanvasViewModel` feeds SwiftUI views (`ThreadCanvasView`, `ThreadInspectorView`).
- Summaries: `EmailSummaryProvider` adds Apple Intelligence summaries when available.
- Tags: `EmailTagProvider` adds Apple Intelligence message tags when available.
- MailKit helper: `MailHelperExtension` ships example handlers for MailKit extension points.
- Coverage UI: `DayCoverageCalendarView` renders the active source's persisted unknown/fetching/partial/verified/failed state and routes every non-future day through confirmation.

## Guiding Principles

- Keep UI state on the main actor; move heavy work into background tasks or actors.
- Preserve behavior when refactoring; changes should be mechanical and test-backed.
- Prefer explicit access control and Swift API Design Guidelines.
- Treat a 1–4 message Apple Mail request size as a reliability boundary, never as a total fetch limit.
- Reconcile source absence only after two matching manifests; incomplete operations must leave existing message visibility unchanged.

## Key Entry Points

- App entry: `BetterMail/BetterMailApp.swift`
- Root view: `BetterMail/ContentView.swift`
- Canvas container: `BetterMail/Sources/UI/ThreadListView.swift`
