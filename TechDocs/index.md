# BetterMail TechDocs

## Graph View

The Graph view is an opt-in sibling to the existing timeline canvas. `ThreadListView` owns the mode switch, keeps Timeline as the default, and mounts `GraphCanvasView` only when `GraphCanvasSettings.mode == .graph`.

`GraphCanvasViewModel` reuses the already-built `ThreadNode` roots from `ThreadCanvasViewModel`; it does not re-run JWZ threading. `GraphData` converts those roots into namespaced graph node IDs (`thread:<rawThreadID>`, `message:<rawMessageID>`) while retaining raw message IDs for AppleScript move operations.

Graph launch work is paged at the branch and message-leaf levels. The first render maps only the first 10 thread branches plus a synthetic `remaining:threads` branch; clicking that remaining node expands another 10 branches at a time until all source roots are visible. The remaining branch uses a dedicated graph edge kind so the force layout treats it like a trunk while SpriteKit renders it as a dashed lightweight connector into a hollow expandable hub, visually separating it from real email threads. Each visible branch renders only its first 10 message leaves, while the `GraphThread` keeps the complete message count and raw message IDs for snip/archive actions. Hidden roots and capped message leaves are not converted into force-simulation bodies until their page is visible, keeping the initial SpriteKit scene bounded even when the mailbox has thousands of messages.

Rendering is handled by `GraphRepresentable` and `GraphScene` with a custom force simulator in `GraphForceSimulator`. The live force model is the Whisper four-force preset: center pull, pairwise repel, spring links, and damping, run as a bounded settling pass so the layout becomes static when the user is idle. While settling or interacting, the SpriteKit view uses the active frame-rate budget; once settled it drops to a low idle cadence and skips per-frame node/edge recomputation until state changes. Thread subjects render as wrapped high-contrast SpriteKit label chips, while message summaries render as separate two-line `SummaryCalloutNode` overlays that auto-place around each message with hysteresis and participate in label-aware repulsion.

Edges render as deterministic, ribbon-filled Catmull-Rom branches seeded from the edge IDs, with tapered parent-to-child width, source joint caps, and an outward arc bias from the center node. Large graphs automatically fall back to the previous lightweight stroked spline renderer, while all graph sizes stop stepping physics after either a short bounded settling window or a low per-node energy threshold. During active settling, ribbons use the lighter preset sample count; once the layout is settled, they switch to the higher settled sample count. The scene caches the last full edge render by filter state and coarse viewport buckets so hover and selection-only updates do not rebuild every edge path. Curl amount, variability, tension, falloff, spring distances, damping, repel cutoff, and label repel settings are persisted in `GraphCanvasSettings` and exposed in `GraphSettingsSheet`, including a Restore defaults action for the Whisper preset.

The May 2026 Instruments pass on the graph user flow recorded a 530 ms main-thread hang, a 307 ms microhang, about 1.0 s of AppleScript refresh work on background threads, and visible samples in `GraphScene.renderEdges` / `GraphSpline.ribbonPath`. The follow-up fixes keep CoreAudio cold unless graph sound is enabled, avoid redundant edge-path generation for visual-state-only updates, and reserve the high ribbon sample count for settled output instead of every active layout frame.

The graph palette now routes through `DesignTokens.Graph.AppTheme`, which maps the canvas to the app's light/dark appearance instead of the retired v1 palette. SpriteKit nodes and SwiftUI chrome use the same AppTheme ink, panel, accent, snip, archive, live, and water tokens.

Viewport state is centralized through `GraphViewport` and shared by the SwiftUI toolbar and SpriteKit scene. The graph supports `20%...500%` zoom, multiplicative toolbar zoom, pinch-to-zoom through `GraphSKView`, command/control-scroll zoom around the cursor, two-finger trackpad pan without modifier keys, blank-canvas drag pan, right-drag pan, rubber-band camera bounds, and double-click empty-canvas recenter.

`ThreadListView` passes graph-specific chrome insets into `GraphCanvasView`: a trailing reservation for the inspector and a bottom reservation for the selected-message action bar. The SpriteKit canvas and SwiftUI graph toolbar therefore render in the remaining visible lane instead of under app chrome.

Pruning has two paths:

- Snip moves all raw message IDs in the thread to a Mail mailbox via `MailAppleScriptClient.moveMessages(messageIDs:toMailboxPath:)`, then adds a temporary compost chip with the previous mailbox for restore.
- Archive is app-only and persists `ArchivedInGraphEntry` rows through `MessageStore`. Normal sidebar scopes exclude those archived threads across Default, Timeline, and Graph views; the `Graph Archive` sidebar item shows only the archived set until a compost restore removes the archive row.

Focused graph coverage lives in `Tests/GraphTests.swift`: graph mapping invariants, branch paging, force settling, spline envelopes, summary auto-placement, label-repel gating, directional selection, and prune state-machine round trips.

## Processing Activity Center

`ProcessingActivityCenter` is the shared observable model for app-wide loading and processing state. Long-running operations register an activity when they begin, update optional detail/progress while they run, and finish with completed, failed, or cancelled state. This keeps user-visible work such as latest-mail refreshes, mailbox hierarchy loading, visible-range backfill, batch import, Apple Intelligence summaries/tags, and Re-GenAI in one activity timeline instead of scattered loading indicators.

`BetterMailApp` owns a single activity center and passes it into `ContentView`, `ThreadCanvasViewModel`, and `AutoRefreshSettingsView`. The center is visible in two places:

- a `MenuBarExtra` for system-level visibility while the main window is covered or inactive
- `ProcessingActivityShelf` over the main app content for active/recent work in the current window

Operation-specific views may still keep action buttons disabled or show detailed settings text, but the canonical visual status for active processing is the activity center.
