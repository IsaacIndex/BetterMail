# Change: Add thread canvas UI

## Why
The current list view does not convey temporal and thread relationships at a glance. A canvas with time on the vertical axis and threads on the horizontal axis will make recency and thread activity patterns easier to scan while preserving existing refresh and threading behavior.

## What Changes
- Replace the thread list with a scrollable, zoomable canvas that positions email nodes by day (vertical) and thread column (horizontal).
- Keep the top nav bar and introduce a right-side inspector panel that updates when a node is selected.
- Render vertical connectors within each thread column to show continuity across days.
- Apply Liquid Glass styling to the nav bar and inspector on macOS 26+, with solid fallbacks when Reduce Transparency is enabled.

## Impact
- Affected specs: `openspec/specs/ui-visual-style/spec.md` (modified), new `thread-canvas` capability.
- Affected code: `BetterMail/ContentView.swift`, `BetterMail/Sources/UI/ThreadListView.swift` (replaced), new canvas/inspector views, `BetterMail/Sources/ViewModels/ThreadSidebarViewModel.swift` (selection + layout helpers).
