# Change: Update threading merge rules and connectors

## Why
Current manual overrides collapse selected threads into a single synthetic thread ID, which loses JWZ lineage and prevents per-subthread connectors. The new grouping rules need to preserve JWZ membership while allowing manual merges that stay compatible with future inbound messages.

## What Changes
- Replace single-target manual overrides with a manual grouping model that can merge JWZ sub-threads while retaining the set of JWZ thread IDs for future merges.
- Revise grouping rules for manual/manual, manual/JWZ, and JWZ/JWZ cases; ungrouping applies only to manual selections.
- Render separate connector lanes for each JWZ sub-thread within a merged group, with dynamic offsets.

## Impact
- Affected specs: `thread-canvas`, new `manual-threading` capability.
- Affected code: `BetterMail/Sources/Threading/JWZThreader.swift`, `BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift`, `BetterMail/Sources/UI/ThreadCanvasView.swift`, `BetterMail/Sources/Storage/MessageStore.swift`, Core Data model definitions, tests under `Tests/`.
