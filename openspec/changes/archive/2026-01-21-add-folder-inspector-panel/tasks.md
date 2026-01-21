# 1. Proposal Prep
- [x] 1.1 Confirm current folder header tap/click handlers and inspector overlay flow in `ThreadCanvasView` / `ThreadListView`.

# 2. Implementation
- [x] 2.1 Add folder selection state in `ThreadCanvasViewModel` and propagate header tap gestures to select a folder.
- [x] 2.2 Render a folder details inspector panel (title + color picker with live preview) when a folder is selected.
- [x] 2.3 Persist folder title/color edits and refresh canvas overlays immediately after save.
- [x] 2.4 Ensure edits survive refresh/relaunch by updating storage/persistence paths.

# 3. Validation
- [x] 3.1 Run targeted previews or manual check to verify folder header click opens the panel and edits reflect on canvas.
- [x] 3.2 `openspec validate add-folder-inspector-panel --strict`
