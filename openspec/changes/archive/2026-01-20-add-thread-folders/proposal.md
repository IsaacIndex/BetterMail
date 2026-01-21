# Change: Add Thread Folders

## Why
Users need a higher-level grouping to organize related JWZ/manual threads into a single visual folder with shared styling and ordering.

## What Changes
- Add persistent thread folders that group one or more threads with a shared title and color.
- Extend the thread canvas layout to order threads by folder latest activity and keep folder members adjacent horizontally.
- Add a selection action to create folders from selected nodes and render folder title/background overlays.

## Impact
- Affected specs: thread-canvas, thread-folders (new)
- Affected code: ThreadCanvasViewModel, ThreadCanvasLayout, ThreadCanvasView, ThreadListView, MessageStore (Core Data)
