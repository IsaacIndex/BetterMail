# Change: Add floating date rail pinned to left of thread canvas

## Why
Users want day/month/year labels to remain visible while panning/zooming the canvas. Today labels sit inside each day band and scroll away with horizontal movement.

## What Changes
- Add a floating left-rail component that pins the day/month/year labels while keeping full-width day band backgrounds.
- Keep existing zoom readability behaviour (day → month → year legend transitions) synced with the rail.
- Ensure the rail stays vertically aligned with day band positions during scrolling and paging.

## Impact
- Affected specs: thread-canvas
- Affected code: ThreadCanvasView layout + day band/legend rendering
