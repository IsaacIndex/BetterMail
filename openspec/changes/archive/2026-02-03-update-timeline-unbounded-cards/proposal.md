# Change: Unbound timeline entry layout

## Why
Timeline View currently confines summaries inside a tight card and shows the sender line. The requested design needs the summary text to flow naturally along the timeline with dot + time + AI tag chips, avoiding overlap between entries and hiding the sender row.

## What Changes
- Rework Timeline View entry layout so the row follows `(dot) time  [AI tags]  summary text`, with the summary allowed to wrap and grow the row height without clipping.
- Remove the sender line from timeline entries; rely on summary/subject plus optional AI-generated tags for context.
- Ensure dynamic heights and spacing keep entries legible with no visual overlap, matching the provided reference aesthetic.

## Impact
- Affected specs: thread-canvas
- Affected code: `ThreadCanvasView` timeline entry rendering, layout metrics for timeline rows, accessibility strings for the new layout.
