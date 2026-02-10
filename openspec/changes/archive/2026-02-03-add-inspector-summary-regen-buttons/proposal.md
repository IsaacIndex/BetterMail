# Change: Add inspector summary regeneration controls

## Why
Users currently have no direct way to force-refresh Apple Intelligence summaries for a single email node or a folder from the inspector, making it hard to recover from stale caches or failed generations without running bulk backfills.

## What Changes
- Add manual "Regenerate" controls next to the thread summary and folder summary shown in the inspector.
- Trigger immediate summary recomputation for the selected node or folder, bypassing cached fingerprints while respecting provider availability.
- Surface inline status/disable states so users know when a regeneration is running or unavailable.

## Impact
- Affected specs: apple-intelligence-summaries, thread-canvas
- Affected code: ThreadInspectorView, ThreadFolderInspectorView, ThreadCanvasViewModel summary triggers and state management
