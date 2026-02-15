# Change: Add Folder Inspector Minimap Navigation

## Why
Folder details currently expose editable metadata but no quick spatial overview of where a folder's email nodes sit on the canvas. Users must manually pan/zoom to reorient inside large folders, which is slow and error-prone.

## What Changes
- Add a simple, interactive folder minimap to the folder details inspector that renders folder node structure as circles and connecting lines only.
- Place the minimap in its own non-scrollable inspector section so it remains visible while other folder fields scroll.
- Add click-to-navigate behavior from minimap coordinates to the corresponding location in the thread canvas.
- Keep navigation constrained to the selected folder region, with a nearest-node fallback when exact coordinate mapping is unstable/unavailable.

## Impact
- Affected specs:
  - `thread-folders` (new minimap UI/placement expectations in folder details)
  - `thread-canvas` (folder-scoped minimap jump resolution behavior)
- Affected code (expected):
  - `BetterMail/Sources/UI/ThreadFolderInspectorView.swift`
  - `BetterMail/Sources/UI/ThreadListView.swift`
  - `BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift`
  - `BetterMail/Sources/UI/ThreadCanvasView.swift`
