# Change: Add drag-and-drop threads into folders on the canvas

## Why
Users want to organize threads by dragging them onto folder columns directly on the canvas, including moving them back out by dragging to empty space. This enables faster foldering without extra controls.

## What Changes
- Enable dragging any thread node to add its thread to a folder column; highlight the target folder while hovering.
- Show a drag preview with the thread's latest subject and total messages.
- Allow dragging a thread out of a folder onto non-folder canvas space to remove it; delete the folder if it becomes empty.
- Keep manually attached nodes coupled to their thread when moving in or out of folders.

## Impact
- Affected specs: thread-canvas
- Affected code: ThreadCanvasView, ThreadCanvasViewModel, ThreadCanvasLayout (hit-testing/highlight), storage updates for folder membership
