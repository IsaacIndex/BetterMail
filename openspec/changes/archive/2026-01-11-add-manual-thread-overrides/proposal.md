# Change: Add manual thread overrides

## Why
JWZ threading is accurate but users sometimes want to merge related messages that lack headers or have split conversations. Manual overrides let users group selected messages into a single thread while preserving JWZ as the default.

## What Changes
- Add persisted manual thread overrides that merge selected messages into an existing JWZ thread.
- Expose multi-select (Cmd+click) with a bottom action bar to group or ungroup messages.
- Visually distinguish JWZ vs manual thread connectors (solid vs dotted) with distinct colors.

## Impact
- Affected specs: `thread-canvas`, new `manual-threading` capability.
- Affected code: `BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift`, `BetterMail/Sources/UI/ThreadCanvasView.swift`, `BetterMail/Sources/UI/ThreadListView.swift`, `BetterMail/Sources/Threading/JWZThreader.swift` (post-processing), `BetterMail/Sources/Storage/MessageStore.swift`, Core Data model definitions.
