# BetterMail TechDocs

## Graph View

The Graph view is an opt-in sibling to the existing timeline canvas. `ThreadListView` owns the mode switch, keeps Timeline as the default, and mounts `GraphCanvasView` only when `GraphCanvasSettings.mode == .graph`.

`GraphCanvasViewModel` reuses the already-built `ThreadNode` roots from `ThreadCanvasViewModel`; it does not re-run JWZ threading. `GraphData` converts those roots into namespaced graph node IDs (`thread:<rawThreadID>`, `message:<rawMessageID>`) while retaining raw message IDs for AppleScript move operations.

Rendering is handled by `GraphRepresentable` and `GraphScene` with a custom force simulator in `GraphForceSimulator`. Thread subjects render as wrapped high-contrast SpriteKit label chips that keep the title inside the chip shape, while message nodes render as directional leaf/message markers with compact AI-summary callouts. Edge paths stay straight, and branch-shaping forces keep message chains spaced outward so the summary callouts can be scanned without rotating text. SwiftUI owns the toolbar, hover card, compost ring, settings sheet, and snip destination sheet so keyboard focus and app-level overlays remain outside SpriteKit.

Viewport state is centralized through `GraphViewport` and shared by the SwiftUI toolbar and SpriteKit scene. The graph now supports `20%...500%` zoom, multiplicative toolbar zoom, pinch-to-zoom through `GraphSKView`, option/command-scroll zoom, normal wheel or trackpad pan, blank-canvas drag pan, option-drag pan, and right-drag pan. Camera movement is bounded against the current graph content plus summary-callout padding so users can roam across large graphs without losing the graph entirely off-screen.

`ThreadListView` passes graph-specific chrome insets into `GraphCanvasView`: a trailing reservation for the inspector and a bottom reservation for the selected-message action bar. The SpriteKit canvas and SwiftUI graph toolbar therefore render in the remaining visible lane instead of under app chrome.

Pruning has two paths:

- Snip moves all raw message IDs in the thread to a Mail mailbox via `MailAppleScriptClient.moveMessages(messageIDs:toMailboxPath:)`, then adds a temporary compost chip with the previous mailbox for restore.
- Archive is app-only and persists `ArchivedInGraphEntry` rows through `MessageStore`, excluding archived threads from graph rendering until restored.

Focused graph coverage lives in `Tests/GraphTests.swift`: graph mapping invariants, force settling, directional selection, and prune state-machine round trips.
