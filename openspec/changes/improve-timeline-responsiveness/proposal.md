# Change: Improve Timeline View responsiveness

## Why
Timeline View feels laggy during scrolling and zooming even with only a few visible entries. Users expect smooth panning/zooming when inspecting recent mail threads; current layout work appears to happen per-scroll tick, causing hitches on modest datasets.

## What Changes
- Reduce main-thread work during scroll/zoom by caching timeline layout and text measurements instead of recomputing per offset change.
- Throttle/compact geometry-driven updates so visible-day tracking does not trigger full layout refreshes on every scroll delta.
- Verify interaction smoothness in Timeline View with realistic sample data (≤200 visible entries) and document budget/limits.

## Impact
- Affected specs: thread-canvas (Timeline interaction responsiveness).
- Affected code: `ThreadCanvasView`, `ThreadCanvasViewModel`, timeline layout/measurement helpers.
