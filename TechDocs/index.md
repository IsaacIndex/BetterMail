# BetterMail TechDocs

## Graph View

The Graph view is an opt-in sibling to the existing timeline canvas. `ThreadListView` owns the mode switch, keeps Timeline as the default, and mounts `GraphCanvasView` only when `GraphCanvasSettings.mode == .graph`.

`GraphCanvasViewModel` reuses the already-built `ThreadNode` roots from `ThreadCanvasViewModel`; it does not re-run JWZ threading. `GraphData` converts those roots into namespaced graph node IDs (`thread:<rawThreadID>`, `message:<rawMessageID>`) while retaining raw message IDs for AppleScript move operations.

Rendering is handled by `GraphRepresentable` and `GraphScene` with a custom force simulator in `GraphForceSimulator`. The live force model is the Whisper four-force preset: center pull, pairwise repel, spring links, and damping, with breeze left as a motion layer when reduce-motion is off. Thread subjects render as wrapped high-contrast SpriteKit label chips, while message summaries render as separate two-line `SummaryCalloutNode` overlays that auto-place around each message with hysteresis and participate in label-aware repulsion.

Edges render as deterministic Catmull-Rom splines seeded from the edge IDs. Curl amount, variability, tension, falloff, spring distances, damping, repel cutoff, and label repel settings are persisted in `GraphCanvasSettings` and exposed in `GraphSettingsSheet`, including a Restore defaults action for the Whisper preset.

The graph palette now routes through `DesignTokens.Graph.AppTheme`, which maps the canvas to the app's light/dark appearance instead of the retired v1 palette. SpriteKit nodes and SwiftUI chrome use the same AppTheme ink, panel, accent, snip, archive, live, and water tokens.

Viewport state is centralized through `GraphViewport` and shared by the SwiftUI toolbar and SpriteKit scene. The graph supports `20%...500%` zoom, multiplicative toolbar zoom, pinch-to-zoom through `GraphSKView`, command/control-scroll zoom around the cursor, two-finger trackpad pan without modifier keys, blank-canvas drag pan, right-drag pan, rubber-band camera bounds, and double-click empty-canvas recenter.

`ThreadListView` passes graph-specific chrome insets into `GraphCanvasView`: a trailing reservation for the inspector and a bottom reservation for the selected-message action bar. The SpriteKit canvas and SwiftUI graph toolbar therefore render in the remaining visible lane instead of under app chrome.

Pruning has two paths:

- Snip moves all raw message IDs in the thread to a Mail mailbox via `MailAppleScriptClient.moveMessages(messageIDs:toMailboxPath:)`, then adds a temporary compost chip with the previous mailbox for restore.
- Archive is app-only and persists `ArchivedInGraphEntry` rows through `MessageStore`, excluding archived threads from graph rendering until restored.

Focused graph coverage lives in `Tests/GraphTests.swift`: graph mapping invariants, force settling, spline envelopes, summary auto-placement, label-repel gating, directional selection, and prune state-machine round trips.
