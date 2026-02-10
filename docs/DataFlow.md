# Data Flow and Concurrency

This document describes the primary data flow and concurrency boundaries.

## Refresh Flow

1. `ThreadCanvasViewModel` triggers refresh.
2. `SidebarBackgroundWorker` (actor) calls `MailAppleScriptClient` to fetch messages.
3. `MessageStore` persists new messages in Core Data.
4. `JWZThreader` rebuilds threads.
5. The view model updates SwiftUI state on the main actor.

## Backfill Flow

1. `BatchBackfillSettingsViewModel` and `ThreadCanvasViewModel` invoke `BatchBackfillService`.
2. `BatchBackfillService` (actor) paginates Apple Mail ranges.
3. Results are persisted by `MessageStore`.
4. UI updates occur via `@MainActor` view models.

## Re-GenAI Flow

1. `BatchBackfillSettingsViewModel` invokes `SummaryRegenerationService`.
2. `SummaryRegenerationService` (actor) paginates stored messages in the selected range.
3. `EmailSummaryProviding` regenerates per-email summaries, and `MessageStore` persists cache updates.
4. Folder summaries are refreshed after each batch.
5. UI updates occur via `@MainActor` view models.

## Summary Flow

1. `ThreadCanvasViewModel` builds summary inputs via `SnippetFormatter`.
2. `EmailSummaryProviding` generates summaries when available.
3. Summary caches are stored in `MessageStore`.

## Concurrency Boundaries

- UI state: `ThreadCanvasViewModel`, `AutoRefreshSettings`, `InspectorViewSettings` are `@MainActor`.
- Background work: `BatchBackfillService` and `SidebarBackgroundWorker` are actors.
- AppleScript access: `MailAppleScriptClient` is an actor to serialize AppleScript calls.
- Core Data: `MessageStore` uses `performBackgroundTask` for persistence.
