# Change: Add configurable zoom thresholds for thread canvas readability

## Why
Users need email nodes to remain readable and day labels to stay at the day granularity at moderate zoom (e.g., 0.673). Current hard-coded font-size thresholds flip to ellipsis/month view too early.

## What Changes
- Add user-configurable thresholds for three canvas states: (1) detailed (full node text + day labels), (2) compact (title-only with ellipsis + month labels), (3) minimal (no node text + year labels).
- Expose these thresholds and the current zoom value in Settings so users can tune readability.
- Apply thresholds in thread canvas rendering logic.

## Impact
- Affected specs: thread-canvas
- Affected code: ThreadCanvasView, settings UI/models, localization strings
