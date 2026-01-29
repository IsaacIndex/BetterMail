# Module Map

This map lists the main modules and their responsibilities.

## DataSource
- `MailAppleScriptClient`: AppleScript ingestion of messages and counts.

## Services
- `BatchBackfillService`: backfill ranges and progress reporting.
- `EmailSummaryProvider`: optional Apple Intelligence summaries.

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
- `AutoRefreshSettingsView`: settings UI for refresh, inspector, and backfill.

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
