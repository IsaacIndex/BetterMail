# Change: Add folder-header jump buttons for first/latest email nodes

## Why
Navigating large folder regions by manual scroll is slow and error-prone, especially when the target email is far outside the currently rendered day window. Users need direct navigation controls in the folder header to jump to the newest or oldest email node in that folder.

## What Changes
- Add two icon-only actions to the bottom row of each folder header block on the thread canvas.
- Add tooltip text for each action:
  - Jump to latest email
  - Jump to first email
- Resolve jump targets from DataStore-backed folder/thread membership bounds rather than only the currently rendered day bands.
- Expand day-window coverage only as needed to make the target day visible, then scroll to the target email node.
- Add safeguards so long jumps do not trigger unbounded synchronous day-band expansion or UI stalls.

## Impact
- Affected specs: `thread-canvas`
- Affected code:
  - `BetterMail/Sources/UI/ThreadCanvasView.swift` (folder header footer actions)
  - `BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift` (jump orchestration, range expansion strategy)
  - `BetterMail/Sources/Storage/MessageStore.swift` (query support for oldest/newest message bounds per folder scope)
