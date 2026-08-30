# Change: Add a Fast Visual Email Organizer

## Why
BetterMail already has a capable graph, manual Groups, selection actions, suggestion review, and Mail-moving workflows, but the fastest organization path is fragmented across separate surfaces and interaction models. The current Graph mode emphasizes paging, display, and force controls; multi-selection is difficult to discover; graph positions are lost across launches; and Archive, Snip, Group, Move, and automation do not share one durable action history or one consistent explanation of Apple Mail effects.

The product objective is to let a user quickly and visually organize existing email. This change makes that objective the primary interaction contract and turns the existing graph infrastructure into a calm, searchable, reversible Organize workspace.

## What Changes
- Rename the user-facing Graph presentation to **Organize** while retaining the existing internal `.graph` setting value for migration compatibility.
- Add a collapsible, searchable **Unorganized** rail beside the active Obsidian graph canvas, scoped to the current mailbox and backed by the same effective-thread and selection state as the canvas.
- Add discoverable Cmd-click, Shift-click, lasso, keyboard, and VoiceOver multi-selection plus batch drag to a confirmed Group and empty-canvas Group creation with inline naming.
- Persist graph positions, confirmed Group anchors, zoom, and pan per mailbox scope across refreshes and relaunches; add active-scope Reset Layout and safe stale-ID pruning.
- Bring suggested Groups and automation proposals into the Organize loop with inline rationale, members, confidence, last-evaluated state, editable impact, and explicit BetterMail-only versus Apple Mail effects.
- Add a durable organization-operation ledger and a separately authorized Apple Mail gateway so Group, Archive, Snip, Move, mailbox creation, automation, recovery, and undo use one auditable vocabulary and no physical Mail mutation is silent.
- Move paging, display, and physics tuning under **Advanced**; keep search, Unorganized, Group, Archive, Move, and Undo as the primary controls.
- Extract organizer projection, selection, command, layout, history, suggestion-policy, Mail-boundary, and metrics seams from the current `ThreadCanvasViewModel`, `GraphCanvasViewModel`, `GraphAutomationCoordinator`, and `MessageStore` hubs without extending the legacy graph renderer.
- Add privacy-safe measurement and explicit automated plus installed-app acceptance gates for speed, drop reliability, wrong placement, suggestion precision, retrieval, and Mail-side safety.

## Impact
- Affected specs:
  - `email-organizer` (new)
  - `organization-safety` (new)
  - `organizer-quality` (new)
  - `code-health` (new organizer-boundary requirement)
  - `thread-canvas` (modified presentation-mode contract)
  - `thread-folders` (modified Group creation and persistence contracts)
  - `manual-threading` (added durable manual-operation history contract)
- Affected code (expected):
  - `BetterMail/Sources/UI/ThreadListView.swift`
  - `BetterMail/Sources/UI/Graph/GraphCanvasView.swift`
  - `BetterMail/Sources/UI/Graph/GraphRepresentable.swift`
  - `BetterMail/Sources/UI/Graph/ObsidianGraphScene.swift`
  - `BetterMail/Sources/UI/Graph/ObsidianGraphSceneNode.swift`
  - `BetterMail/Sources/UI/Graph/ObsidianGraphControls.swift`
  - `BetterMail/Sources/UI/Graph/GraphSuggestionReviewSheet.swift`
  - `BetterMail/Sources/UI/Graph/GraphAutomationQueueSheet.swift`
  - `BetterMail/Sources/ViewModels/GraphCanvasViewModel.swift`
  - `BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift`
  - `BetterMail/Sources/Services/GraphAutomationCoordinator.swift`
  - `BetterMail/Sources/Storage/MessageStore.swift`
  - `BetterMail/Sources/DataSource/MailAppleScriptClient.swift`
  - `BetterMail/MailControl.swift`
  - `BetterMail/Sources/UI/Graph/GraphSnipModels.swift`
  - new organizer projection, selection, command, layout, history, Mail gateway, and metrics types
  - `BetterMail/Sources/UI/AccessibilityIdentifiers.swift`
  - `BetterMail/Resources/Localizable.strings`
  - focused test files under `Tests/`
  - `README.md` and `TechDocs/index.md`
- Existing compatibility constraints:
  - Preserve the current queue-wide Graph Automation **Approve All** work and define its all-pending/conflict behavior instead of reverting it.
  - Preserve existing Thread Folder data, Graph Archive data, automation records, graph settings, mailbox mappings, and unrelated dirty worktree state.
  - Do not change bundle identifiers, signing, entitlements, target membership, or minimum OS versions.

The new `email-organizer` capability owns the cross-surface Organize workflow. Existing `thread-canvas`, `thread-folders`, and `manual-threading` capabilities continue to own their canonical presentation, Group, and manual-thread semantics; this change includes explicit deltas wherever the cross-surface workflow changes those contracts.
