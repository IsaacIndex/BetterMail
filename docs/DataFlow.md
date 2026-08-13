# Data Flow and Concurrency

This document describes the primary data flow and concurrency boundaries.

## Refresh Flow

1. App start, toolbar Refresh, and the auto-refresh timer call `ThreadCanvasViewModel.refreshNow()` for today only.
2. `DayFetchCoordinator` serializes the operation and resolves the active concrete account/mailbox or every account's Inbox child scope.
3. `MailAppleScriptClient` returns an uncapped lightweight manifest for `[dayStart, now)`, then returns new or changed payloads by Apple Mail ID in requests of 1–4 messages. This request size is not a total limit.
4. The coordinator re-reads the manifest. It retries the day once if identity or metadata changed and commits staged payloads only after a stable result.
5. `MessageStore` upserts returned messages, reconciles source absence within the authoritative interval, and persists partial open-day coverage for every concrete scope.
6. `JWZThreader` rebuilds from normal visible-message queries, which exclude source-absent records, and the view model applies SwiftUI state on the main actor.

## Backfill Flow

1. A confirmed calendar day, visible risky range, or Settings range invokes `BatchBackfillService`/`DayFetchCoordinator` with the full payload profile.
2. Ranges are enumerated as calendar days sequentially; DST days are not treated as fixed 86,400-second windows.
3. Each day follows the same uncapped manifest, 1–4-message ID payload requests, second-manifest verification, and authoritative reconciliation path as refresh.
4. A zero-message day still writes successful coverage. Failed, cancelled, incomplete-payload, and unstable-manifest attempts write red coverage without changing source-absence flags.
5. UI progress and completion counts are applied through `@MainActor` view models. Bulk ranges use one confirmation; individual calendar dates always confirm, including previously verified days.

## Coverage and Reconciliation Flow

1. `DayFetchCoverageEntity` stores one row per concrete account/mailbox/calendar day.
2. Aggregate Inbox state sums child counts and displays the least-complete child state; accounts with zero messages are included because source scopes are enumerated independently from the manifest.
3. An authoritative manifest clears absence for returned messages and flags cached rows missing from the same concrete scope and half-open interval.
4. Normal store reads exclude flagged rows. Explicit reconciliation reads include them so reappearing messages can be restored.
5. Historical cache contents and the retained legacy `lastSyncDate` preference never synthesize coverage.

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
- Background work: `DayFetchCoordinator`, `BatchBackfillService`, and `SidebarBackgroundWorker` are actors. The coordinator explicitly serializes whole day/range operations across actor suspension points.
- AppleScript access: `MailAppleScriptClient` is an actor to serialize AppleScript calls.
- Core Data: `MessageStore` uses `performBackgroundTask` for persistence.
