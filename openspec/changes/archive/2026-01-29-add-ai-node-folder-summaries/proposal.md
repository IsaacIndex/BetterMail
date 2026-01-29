# Change: Add Apple Intelligence summaries for individual emails and folders

## Why
Current Apple Intelligence integration only summarizes at the thread-root level using subjects, missing per-email context and folder overviews. Users need concise per-message digests and folder-level rollups to understand what changed where without reading entire threads.

## What Changes
- Add per-email node summaries that compare each message to prior emails (including manual attachments) using subject and body content.
- Add folder-level summaries derived from member email summaries (including nested folders) with debounced refresh and cancel/overwrite behavior.
- Surface node summaries in the inspector panel and folder summaries in both folder headers and the folder inspector.
- Regeneration rules tied to upstream data changes (new prior emails, manual attachments, folder membership updates).

## Impact
- Affected specs: apple-intelligence-summaries (new), thread-folders
- Affected code: ThreadCanvasViewModel summary pipeline, EmailSummaryProvider inputs, summary cache schema/logic, folder UI (header + inspector), summary scheduling/debounce utilities, tests around summaries and folders.
