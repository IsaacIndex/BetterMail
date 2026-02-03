# Change: Add pinned folders ordering and indicator

## Why
Users need to keep important folders at the top of the folder list without changing their visual appearance.

## What Changes
- Add a pin/unpin action in the folder context menu.
- Persist pinned folder IDs locally and restore them on launch.
- Sort folders so pinned folders appear before unpinned folders while preserving existing order.
- Show a pin icon in the top-right corner of pinned folder headers.

## Impact
- Affected specs: thread-folders
- Affected code: BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift, BetterMail/Sources/UI/ThreadCanvasView.swift, BetterMail/Sources/Settings (new settings store), BetterMail/Resources/Localizable.strings
