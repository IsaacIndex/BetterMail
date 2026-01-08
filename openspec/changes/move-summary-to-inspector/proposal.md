# Change: Move Apple Intelligence summary into inspector

## Why
The current canvas UI no longer uses `MessageRowView`, so the Apple Intelligence summary disclosure is effectively hidden. Moving the summary into the inspector keeps the feature visible in the active UI while aligning with the canvas layout.

## What Changes
- Move the Apple Intelligence summary disclosure UI into the inspector panel, positioned before the “From” field.
- Keep summary generation logic unchanged and reuse the existing disclosure behavior (collapsed preview + expanded text).
- Mark `MessageRowView` as deprecated while keeping it available for reference.
- Rename `ThreadSidebarViewModel` to `ThreadCanvasViewModel` to match the current UI and file naming.

## Impact
- Affected specs: `thread-canvas`
- Affected code: `BetterMail/Sources/UI/ThreadInspectorView.swift`, `BetterMail/Sources/UI/ThreadListView.swift`, `BetterMail/Sources/ViewModels/ThreadSidebarViewModel.swift` (rename), `BetterMail/Sources/UI/MessageRowView.swift`
