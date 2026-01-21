# Change: Add folder header inspector panel for editing details

## Why
Users cannot currently rename a folder or adjust its color once created. They want a quick way to edit folder details directly from the canvas without leaving the inspector area.

## What Changes
- Show a folder details panel in the inspector region when a folder header is clicked on the canvas.
- Allow editing the folder title and choosing a new folder background color with live preview.
- Persist edits so folder names and colors survive refreshes/relaunches and immediately update canvas backgrounds.

## Impact
- Affected specs: thread-folders, thread-canvas
- Affected code: ThreadCanvasView/ThreadCanvasLayout (folder header hit-testing and gestures), ThreadListView inspector overlay selection handling, ThreadCanvasViewModel folder selection/persistence, ThreadFolder storage model, localization strings for the folder editor UI
