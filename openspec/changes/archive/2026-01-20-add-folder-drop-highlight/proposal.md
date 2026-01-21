# Change: Add folder drop highlight on thread canvas

## Why
Dragging a thread onto a folder column currently has little visual confirmation; the colored column background sits under nodes and the stroke feedback is hidden, so users cannot tell whether letting go will file the thread into that folder.

## What Changes
- Add an explicit drop-target border that appears while a thread drag is inside a folder column's drop zone (the colored background area), drawn above existing content.
- Animate a brief pulse when the drag enters a folder drop zone so the target feels responsive, then keep a steady highlight while hovering.
- Ensure the highlight clears immediately when the drag leaves, cancels, or drops elsewhere, without altering drop hit-testing.
- Keep drag/drop mechanics unchanged; this is purely visual feedback for folder targets.

## Impact
- Affected specs: thread-canvas
- Affected code: ThreadCanvasView (folder column background + drag state), related drag hit-testing helpers if needed
