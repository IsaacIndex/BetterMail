# Change: Refine timeline view message entries

## Why
Timeline view currently only toggles layout without clear message-level presentation. We need per-message entries with time stamps, concise summaries, and tags similar to the provided reference so users can scan activity quickly while still opening the inspector.

## What Changes
- Render timeline view as a vertical list of message entries with time, sender/subject summary, and tag/title chips inspired by the provided sample.
- Allow (optional) Apple Intelligence generation of tags or titles when metadata is missing or unclear, with graceful fallback when unavailable.
- Keep inspector behavior: clicking a timeline entry selects the message and opens the existing inspector panel.

## Impact
- Affected specs: thread-canvas
- Affected code: timeline view rendering on the canvas, inspector selection handling, optional Apple Intelligence summary/tag generation hooks.
