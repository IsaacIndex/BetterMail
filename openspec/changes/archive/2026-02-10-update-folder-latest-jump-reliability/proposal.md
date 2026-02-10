# Change: Improve folder boundary-jump reliability and responsiveness

## Why
The folder header jump actions ("Jump to latest email" and "Jump to first email") are currently inconsistent: they can select the expected message but fail to scroll to that node, and they feel laggy for folders with larger history. This creates a mismatch between selection state and viewport position, making navigation unreliable.

## What Changes
- Tighten both boundary-jump flows so they deterministically land the viewport on the resolved latest/first node (or a defined fallback) after selection.
- Replace fixed-step day-window expansion behavior with a bounded strategy that reaches required coverage for older folders without excessive rethread churn.
- Add explicit jump lifecycle state (resolving, expanding, awaiting anchor, scrolling) and retry semantics for cases where anchors are not yet rendered.
- Define consistent behavior for all folder scopes (top-level and nested folders) and for repeated user taps while a jump is already in flight, for both jump directions.
- Add telemetry/log markers to distinguish target-resolution, expansion, and scroll-anchor failures for easier triage.

## Impact
- Affected specs: `thread-canvas`
- Affected code:
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/UI/ThreadCanvasView.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/Storage/MessageStore.swift` (if boundary-query helpers need extension)
- Related active proposals:
  - `add-folder-header-jump-buttons` (this change narrows to reliability/perf fixes for both folder-header jump directions and should be merged or sequenced with that work)
