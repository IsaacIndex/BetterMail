# Change: Restore timeline view canvas parity

## Why
The recent Timeline View implementation replaced the two-axis canvas with a vertical list, which dropped manual thread grouping and folder layout behaviors. Users want Timeline View to keep the canvas experience so manual groups, folders, and connector visuals remain consistent across view modes.

## What Changes
- Make Timeline View use the same canvas renderer and layout engine as Default View instead of a separate vertical list.
- Ensure manual thread groups, JWZ threads, and folder stacking/adjacency all render identically in Timeline View.
- Preserve timeline-specific affordances (time legend, summaries/tags) as overlays without breaking canvas grouping semantics.

## Impact
- Affected specs: thread-canvas (view modes, timeline parity)
- Affected code: `ThreadListView`, `ThreadTimelineView`/canvas renderer, thread/folder layout pipeline, any timeline-specific overlays.
