# Module Map

This map lists the main modules and their responsibilities.

## DataSource
- `MailAppleScriptClient`: AppleScript ingestion of messages and counts.

## Services
- `BatchBackfillService`: backfill ranges via exhaustive time-sliced fetches, forcing each AppleScript fetch below 5 messages and splitting intervals when needed, plus progress reporting.
- `EmailSummaryProvider`: optional Apple Intelligence summaries.
- `EmailTagProvider`: optional Apple Intelligence message tags.
- `SummaryRegenerationService`: regenerates cached email and folder summaries.

## Storage
- `MessageStore`: Core Data persistence for messages, threads, folders, and summaries.

## Threading
- `JWZThreader`: JWZ threading algorithm and manual group overlay.

## ViewModels
- `ThreadCanvasViewModel`: UI state, refresh/rethread orchestration, selection, and summaries.

## UI
- `ThreadListView`: canvas container and chrome.
- `ThreadCanvasView`: main timeline canvas.
- `ThreadInspectorView` / `ThreadFolderInspectorView`: right-side inspector panels.
- `AutoRefreshSettingsView`: settings UI for refresh, inspector, and backfill, including stop controls and slice-aware status text.

## Support
- `Log`: OSLog categories.
- `SnippetFormatter`: snippet cleanup and stop phrase filtering.
- `ThreadSummaryFingerprint`: summary cache fingerprints.
- `MailControl`: Mail.app helper commands.
- `AppleScriptRunner`: AppleScript execution helpers.

## Settings
- `AutoRefreshSettings`, `InspectorViewSettings`, `ThreadCanvasDisplaySettings`, `BatchBackfillSettingsViewModel`.

## MailHelperExtension
- `MailExtension` plus `ContentBlocker`, `MessageActionHandler`, `ComposeSessionHandler`, `MessageSecurityHandler`.
