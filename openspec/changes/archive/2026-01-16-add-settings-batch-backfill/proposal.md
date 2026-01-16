# Change: Add Settings-based batch backfill

## Why
Users need a reliable way to import historical mail in bulk without freezing the UI. Existing backfill is limited to visible-day ranges on the canvas; Settings lacks a batch-oriented control.

## What Changes
- Add a Settings entry to run a mailbox-scoped batch backfill over a user-selected date range (defaults to start of current year → today, resets each session).
- Show a progress view that reflects counting, per-batch advances, retries with smaller batch sizes on failures, and completion/failure states.
- Run ingestion on a side actor to keep the app responsive while marshaling UI updates to the main actor.

## Impact
- Affected specs: backfill (new capability)
- Affected code: Settings UI, backfill ingestion pipeline/service, status/progress state handling
