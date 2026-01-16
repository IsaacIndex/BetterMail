## Context
The thread canvas currently renders a fixed 7-day window and rethreads based on the cached messages. Users want to scroll further back without triggering AppleScript fetches on scroll. Fetching older mail should be explicit, scoped to what the user is looking at, and limited to avoid performance regressions.

## Goals / Non-Goals
- Goals:
  - Enable cache-only paging on the canvas in 7-day increments.
  - Detect empty day bands within the visible viewport and expose a backfill action.
  - Keep AppleScript fetches user-initiated and constrained to the visible date range.
- Non-Goals:
  - Automatic background backfill of older mail.
  - Changes to the deprecated sidebar list.

## Decisions
- Decision: Drive day-count expansion from the view model and feed it into the canvas layout.
  - Why: Keeps UI state centralized and makes it possible to compute visible date ranges for backfill decisions.
- Decision: Use a viewport-based empty-band detector to show the toolbar action.
  - Why: Aligns backfill intent with what the user can see and avoids surprise background fetches.
- Decision: Add a date-range AppleScript fetch path used only for backfill.
  - Why: Precise scoping reduces Mail.app load and avoids fetching unnecessary messages.

## Risks / Trade-offs
- Larger day ranges increase layout work; mitigate by growing in small increments and relying on cache-only fetches.
- Visible-range calculations depend on scroll geometry; mitigate by isolating logic and adding tests for range math.

## Migration Plan
- No data migrations. Existing caches are used as-is. Backfill adds new messages through standard upsert flow.

## Open Questions
- None.
