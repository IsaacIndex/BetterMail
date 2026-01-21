# Change: Nested thread folders with stacked headers and drag highlights

## Why
Users need to nest folders indefinitely so conversations can be organized hierarchically, while preserving clarity in the canvas layout and drag/drop interactions.

## What Changes
- Allow creating a child folder from a thread already inside another folder; the parent retains the child folder and may also keep loose threads or multiple child folders.
- Render nested folders with stacked headers whose combined height adjusts dynamically; parent headers widen to encapsulate their children.
- Extend drag/drop so threads can move into/out of nested folders with a clear entry pulse highlight on the exact target folder.

## Impact
- Affected specs: thread-folders, thread-canvas
- Affected code: ThreadCanvasLayout, ThreadCanvasView, ThreadCanvasViewModel, ThreadFolder model/persistence, drag/drop hit testing and folder chrome rendering
