# Change: Custom drag for thread canvas (no system lift)

## Why
The system drag API forces the lift animation and pointer-attached snapshot, which we don’t want. We need full control of the drag visuals while keeping thread moves to folders and removing from folders working.

## What Changes
- Replace system `draggable`/`dropDestination` on the thread canvas with a custom DragGesture-driven drag layer for single-thread drags.
- Render a custom floating preview (subject + count) that follows the pointer without the system lift animation.
- Keep drop behavior: drag onto a folder column moves the thread; dragging off a folder onto the canvas removes folder membership.

## Impact
- Affected spec: `thread-canvas`
- Affected code: `BetterMail/Sources/UI/ThreadCanvasView.swift`
