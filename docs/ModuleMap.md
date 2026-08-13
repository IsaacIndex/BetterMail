# Module Map

This map lists the main modules and their responsibilities.

## DataSource
- `MailAppleScriptClient`: AppleScript mailbox-scope enumeration, uncapped day manifests, and ID-based payload requests.

## Services
- `DayFetchCoordinator`: serial day/range fetch pipeline, second-manifest stability verification, cancellation between payload requests, and authoritative reconciliation.
- `BatchBackfillService`: sequential calendar-day range adapter over `DayFetchCoordinator` with progress reporting and no total message limit.
- `EmailSummaryProvider`: optional Apple Intelligence summaries.
- `EmailTagProvider`: optional Apple Intelligence message tags.
- `SummaryRegenerationService`: regenerates cached email and folder summaries.

## Storage
- `MessageStore`: Core Data persistence for messages, source-absence audit state, day coverage, threads, folders, and summaries; normal message reads hide source-absent rows.

## Threading
- `JWZThreader`: JWZ threading algorithm and manual group overlay.

## ViewModels
- `ThreadCanvasViewModel`: UI state, today-only startup/manual/auto refresh, coverage/backfill orchestration, rethreading, selection, and summaries.

## UI
- `ThreadListView`: canvas container and chrome.
- `DayCoverageCalendarView`: month-grid coverage state and confirmed day recovery.
- `ThreadCanvasView`: main timeline canvas.
- `ThreadInspectorView` / `ThreadFolderInspectorView`: right-side inspector panels.
- `AutoRefreshSettingsView`: settings UI for refresh, inspector, and backfill, including the persisted 1–4 messages-per-request control, stop controls, and progress status.

## Support
- `Log`: OSLog categories.
- `SnippetFormatter`: snippet cleanup and stop phrase filtering.
- `ThreadSummaryFingerprint`: summary cache fingerprints.
- `MailControl`: Mail.app helper commands.
- `AppleScriptRunner`: AppleScript execution helpers.

## Settings
- `AutoRefreshSettings`, `InspectorViewSettings`, `ThreadCanvasDisplaySettings`, `BatchBackfillSettingsViewModel` (persists the 1–4 Apple Mail request batch size used by Batch Backfill; it is not a total limit).

## MailHelperExtension
- `MailExtension` plus `ContentBlocker`, `MessageActionHandler`, `ComposeSessionHandler`, `MessageSecurityHandler`.
