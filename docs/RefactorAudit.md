# Refactor Audit

This audit catalogs module-level surfaces and the planned refactor updates for
access control, naming consistency, and actor isolation. It is scoped to the
current refactor change and should be updated if new modules or public surfaces
are added.

## DataSource

### MailAppleScriptClient
- Functions: `fetchMessages(since:limit:mailbox:snippetLineLimit:)`, `fetchMessages(in:limit:mailbox:snippetLineLimit:)`, `countMessages(in:mailbox:)`
- Helpers: `buildScript`, `buildCountScript`, `decodeMessages`, `HeaderDecoder`
- Proposed updates:
  - Make `MailAppleScriptClientError` `private` (used only in this file).
  - Add explicit access control to `MailAppleScriptClient` and its members.
  - `MailAppleScriptClient` is an actor to serialize AppleScript access.
- Dependencies: `NSAppleScriptRunner`, `MailControl`, `JWZThreader`, `Log`

## Services

### BatchBackfillService
- Functions: `countMessages(in:mailbox:)`, `runBackfill(range:mailbox:preferredBatchSize:totalExpected:snippetLineLimit:progressHandler:)`
- Types: `BatchBackfillProgress`, `BatchBackfillResult`
- Proposed updates:
  - Add explicit access control for service and progress/result types.
  - Keep actor isolation (`actor BatchBackfillService`) explicit.
- Dependencies: `MailAppleScriptClient`, `MessageStore`

### EmailSummaryProvider
- Protocols: `EmailSummaryProviding`
- Types: `EmailSummaryCapability`, `EmailSummaryRequest`, `FolderSummaryRequest`, `EmailSummaryContextEntry`, `EmailSummaryError`
- Proposed updates:
  - Add explicit access control for protocol and value types.
  - Keep `FoundationModelsEmailSummaryProvider` availability guard; no naming changes.
- Dependencies: `FoundationModels` (availability gated)

## Storage

### MessageStore
- Functions: CRUD for messages, threads, folders, summaries, and migrations.
- Proposed updates:
  - Add explicit access control for store, entities, and extensions.
  - Keep background Core Data operations and migration tasks unchanged.
- Dependencies: Core Data, `JWZThreader`, `Log`, model structs

## Threading

### JWZThreader
- Functions: `buildThreads(from:)`, `applyManualGroups(_:to:)`, `normalizeIdentifier`, `threadIdentifier(for:)`
- Types: `ThreadingResult`, `ManualGroupApplication`
- Proposed updates:
  - Add explicit access control for threader, result types, and helpers.
  - No naming changes needed; method names are guideline-compliant.
- Dependencies: `EmailMessage`, `EmailThread`, `ThreadNode`, `ManualThreadGroup`

## ViewModels

### ThreadCanvasViewModel
- Functions: refresh, rethread, summary generation, selection, folder edits, layout helpers.
- Proposed updates:
  - Add explicit access control for view model and nested helper types.
  - Keep `@MainActor` on the view model; keep `SidebarBackgroundWorker` actor.
- Dependencies: `MessageStore`, `MailAppleScriptClient`, `JWZThreader`, `EmailSummaryProvider`, UI helpers

## UI

### ThreadListView, ThreadCanvasView, ThreadInspectorView, ThreadFolderInspectorView
- Proposed updates:
  - Add explicit access control to views and helpers.
  - No naming changes required.
- Dependencies: `ThreadCanvasViewModel`, SwiftUI

## Support

### Log
- Proposed updates:
  - Add explicit access control to logger namespace.

### SnippetFormatter
- Proposed updates:
  - Add explicit access control.

### ThreadSummaryFingerprint
- Proposed updates:
  - Add explicit access control for helpers and entry structs.

### MailControl + AppleScriptRunner
- Functions: AppleScript execution, message open/search, mailbox helpers.
- Proposed updates:
  - Add explicit access control for public helpers and internal utilities.
  - Consider actor annotation for AppKit-bound calls if future work requires it.
- Dependencies: AppKit, `JWZThreader`, `Log`

## Settings

### AutoRefreshSettings, InspectorViewSettings, BatchBackfillSettingsViewModel
- Proposed updates:
  - Add explicit access control.
  - Preserve `@MainActor` annotation on view models.
- Dependencies: SwiftUI, Combine

## MailHelperExtension

### MailExtension + handlers
- Types: `MailExtension`, `ContentBlocker`, `MessageActionHandler`, `ComposeSessionHandler`, `MessageSecurityHandler`, view controllers.
- Proposed updates:
  - Add explicit access control for handler classes.
  - Keep protocol method names as defined by MailKit.
- Dependencies: MailKit

## Deprecated / Unused Surfaces

- `MessageRowView` (deprecated legacy thread list row) removed; documented in the migration log.
- Legacy thread list artifacts: no other live call sites found; keep `ThreadListView` for canvas navigation.

## Blocking Dependencies / Risks

- MailKit handlers are tied to MailKit protocols; avoid renaming required entry points.
- AppleScript helpers are shared between `MailAppleScriptClient` and `MailControl`; avoid breaking message ID normalization or script templates.
