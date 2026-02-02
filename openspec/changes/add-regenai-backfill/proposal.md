# Change: Add Re-GenAI backfill option in Settings

## Why
Users need a way to refresh Apple Intelligence summaries for historical email ranges without reimporting messages. Adding a Re-GenAI control alongside the existing backfill makes it easy to regenerate per-email and folder rollups after model improvements or summary drift.

## What Changes
- Add a new “Start Re-GenAI” action in Settings’ Batch Backfill section that honors the selected date range and mailbox.
- Run a background regeneration pass that re-summarizes each email in the range and refreshes any affected folder summaries, with progress feedback similar to backfill.
- Preserve UI responsiveness and clear completion/error states; reuse existing batching/progress plumbing where possible.

## Impact
- Affected specs: backfill, apple-intelligence-summaries
- Affected code: BatchBackfillSettingsViewModel, BatchBackfillService (or parallel service), EmailSummaryProvider / summary cache, folder summary refresh pipeline, settings UI strings
