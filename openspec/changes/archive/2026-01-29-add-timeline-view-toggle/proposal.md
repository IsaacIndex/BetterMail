# Change: Add timeline view toggle in thread canvas

## Why
- Users need a quick way to switch between the existing subject-centric canvas and a summary-centric timeline view without leaving the canvas.
- Persisting the choice avoids extra clicks for users who prefer summaries by default.

## What Changes
- Add a navigation bar toggle to switch between Default View (subject line) and Timeline View (summary-first).
- Persist the selected view mode in display settings so it survives app relaunches.
- Update thread canvas nodes to show summary text instead of the subject when Timeline View is active, with sensible fallbacks.

## Impact
- Affected specs: thread-canvas
- Affected code: ThreadListView navigation bar overlay, ThreadCanvas node presentation, display settings persistence
