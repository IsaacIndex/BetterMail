# BetterMail · Graph View — Implementation Plan

Reimagine the canvas as an Obsidian-style **force-directed graph view** that
sits alongside the existing horizontal timeline. A "You" node anchors the
center; threads radiate outward as branches; pruning is a tactile gesture
(Snip vs Archive) with a compost ring for restoration; the canvas feels alive
through physics, breath, sway, water, and sprout-on-arrival.

## Design Input Summary

- **Source of truth**: `/Users/isaacibm/Downloads/BetterMail Design/`
  - `DESIGN-NOTES.md` — design brief (intent, decisions, files)
  - `BetterMail Graph View.html` — wires everything together
  - `graph.jsx` — force engine, rendering, prune logic, compost, hover card,
    toolbar (canonical reference for `FORCES`, layout radii, animations)
  - `reader.jsx` — inline reader spec (we reuse the app's inspector instead)
  - `tweaks-panel.jsx` — variant toggles (we ship Botanical only)
  - `sidebar.jsx` — app chrome (already present in BetterMail)
  - `data.jsx` — placeholder thread data (replaced with live `MessageStore`)
  - `styles.css` — token values and animation timings (canonical reference)
- **Approved variant**: **Botanical** only (no Lines / Synaptic in v1).
- **Approved direction**: graph view is **opt-in via a top-bar segmented
  toggle**; default remains the timeline.

### Visual tokens (extracted from `styles.css`, lifted into `DesignTokens.swift`)

| Token | Value | Notes |
|---|---|---|
| `bm-bg` | `#FAFAF8` | paper white |
| `bm-panel` | `#FFFFFF` | window fill |
| `bm-panel-2` | `#F5F5F2` | sidebar / segmented track |
| `bm-line` | `#ECECE7` | hairline separator |
| `bm-ink` | `#16181D` | primary ink |
| `bm-ink-3` | `#5A5E68` | secondary ink |
| `bm-ink-4` | `#8C8F98` | tertiary ink |
| `bm-ink-5` | `#B8BAC0` | edge stroke (low importance) |
| `bm-accent` | `#4F46E5` | warm indigo (unread / hover / selected) |
| `bm-accent-soft` | `#EEF0FF` | selected fill |
| `bm-snip` | `#B45A3C` | warm rust (snip mode + compost) |
| `bm-snip-soft` | `#FBEFE8` | wilt fill |
| `bm-archive` | `#6B7280` | slate (archive mode + compost) |
| `bm-archive-soft` | `#F1F2F4` | settle fill |
| `bm-live` | `#0EA5A4` | breath ring |
| `bm-water` | `#14B8A6` | water pulse aura |
| Botanical edge | `#A6B098` | (default) |
| Botanical trunk | `#6B7A5C` (1.6 px) | thicker than non-trunk |
| Botanical message | `#7A8F66` | sage dot |
| Botanical thread (high) | `#4A5640` (1.6 px) | high-importance ring |

Typography:
- UI: **Inter** (`-apple-system` fallback), `13 px` body, `letter-spacing -0.005em`.
- Mono / metadata: **JetBrains Mono** (SF Mono fallback), `10.5 px`.
- Reader subject: `17 px / 600 / -0.02em`.
- Thread label: `10.4 px / 600`, wrapped to three lines inside a subtle paper
  chip for contrast. Thread meta remains hover-card only.

Geometry (from `graph.jsx`):
- "You" radius `38 px`, pinned center.
- Thread radius `14 + min(messageCount, 12) * 1.4` px.
- Thread orbit radius `200 px` (bumped `+30` if `messageCount > 8`).
- Message radius `6 px` (`+2` if unread), rendered as a directional
  leaf/message marker with a compact horizontal AI-summary callout.
- Trunk edge target length `210 px`; non-trunk `104 px`.
- Edge: straight hairline `1.0 px` default, trunk `1.4 px`, prunable `1.4 px`
  dashed `4 3`.
- Background dot grid: `28 px` spacing, `rgba(20,22,28,0.035)` masked to a
  soft elliptical vignette.
- Viewport: zoom clamps to `20%...500%`; toolbar zoom is multiplicative so it
  reaches the expanded range quickly. Normal wheel/trackpad scrolling pans,
  option/command-scroll zooms, pinch gestures zoom around the pointer, and
  right-drag or option-drag pans even when the graph is dense.

Force constants (from `graph.jsx::FORCES`):
- `centerPull 0.012`, `edgeSpring 0.045`, `repulsion 4600`, `damping 0.82`,
  `sway 0.0008`, pairwise repulsion cutoff `160000`. Message chains also get a
  radial straightening force so replies stay outside their thread orbit instead
  of curling back. Breeze: `sin(t·0.0006)·0.06` (x),
  `cos(t·0.0009)·0.04` (y); applied with **3× weight to messages vs threads**
  (matches `1.2` vs `0.4`).

Animations:
- `bm-snip-wilt` 1.6 s ease-out: opacity 1→0, gravity-fall (`vy += 0.4`),
  rotation `+0.04 rad/frame`, x jitter ±0.2.
- `bm-archive-settle` 1.0 s ease-out: opacity 1→0.25, scale 1→0.85.
- `bm-breath` 3.4 s ease-in-out infinite: scale 1→1.18, opacity 0.35→0.
- `bm-water-pulse` 2.4 s ease-out infinite: scale 0.8→1.5, opacity 0.6→0.
- `bm-sprout` 0.55 s ease-out: scale 0→1.2→1, opacity 0→1.

### Responsive strategy

This is a desktop-only macOS window. The window respects existing minimums
(`minWidth: 480, minHeight: 400`). Toolbar collapses tool-sub labels under
`720 px` width; the compost ring caps at `280 px` and wraps; the inspector
panel keeps its existing 320 px width.

### Interaction & animation notes

- **Pan** = drag empty canvas. **Zoom** = scroll wheel + magnification gesture.
  Range `0.4×` – `2.4×`. "Recenter" button resets pan + zoom.
- **Drag a node** = manually re-position; physics resumes on release.
- **Click thread** = select + open inspector (existing overlay).
- **Hover thread/message** = preview card (subject, snippet, sender, tags).
- **Double-click thread** = water (teal aura, persistent, increments importance
  counter; emits a "water" sound).
- **Snip mode** (toolbar): cursor swaps to ✂; clicking any edge in the thread
  prompts the **SnipMoveSheet** (folder picker), then animates wilt.
- **Archive mode** (toolbar): cursor swaps to ⏚; clicking any edge in the
  thread immediately settles + adds to compost (no Mail-side change).
- **Compost chip** = click to restore (Mail move-back for snip; tag-remove for
  archive).
- **Sprout** = new message arrives → spawn at thread tip with sprout animation.

### Accessibility requirements

- WCAG 2.1 AA on all text colors against their backgrounds (validated for
  `bm-ink-3 #5A5E68` on `bm-panel #FFFFFF`).
- All toolbar buttons keyboard-reachable with `.focusable()` and visible
  focus rings (`bm-accent` outline at 1.5 px).
- Keyboard map:
  - `↑/↓/←/→` move selection across the graph (nearest-neighbor, computed
    in scene coordinates).
  - `Return` open selected thread in inspector.
  - `S` enter snip mode; `A` enter archive mode; `Esc` exit prune mode.
  - `W` water selected thread.
  - `+/-` zoom in/out; `0` reset zoom + pan.
- VoiceOver: each node exposes `accessibilityLabel`
  (`"Thread <subject>, <messageCount> messages, <importance> importance"`),
  `accessibilityValue` (`"<unread> unread"`), `accessibilityHint`
  (`"Double-tap to open"`). Snip / Archive announce as
  `"Thread snipped, moved to <folder>"` / `"Thread archived"`.
- Respect `accessibilityReduceMotion`: disable breeze, breath, water pulse,
  and wilt rotation; keep simple fade-out for snip/archive.
- Optional sound is **off by default**; controlled by an `AppearanceSettings`
  bool (new key) and respects system "play user-interface sound effects".

## Scope

In:
- New `Sources/UI/Graph/` module: `GraphCanvasView`, `GraphScene`,
  `GraphSceneNodes`, `GraphForceSimulator`, `GraphToolbar`, `GraphHoverCard`,
  `GraphCompostRing`, `GraphCanvasViewModel`.
- Topbar segmented toggle: `Timeline | Graph` in `ThreadListView`.
- New `Settings/GraphCanvasSettings.swift` (variant, soundOn,
  reduceMotionOverride, snipParentMailbox).
- `MailAppleScriptClient` extension: `moveMessages(messageIDs:toMailboxPath:)`
  and a "list mailboxes under a parent" query for the snip picker.
- New manual-group tag: `archivedInGraph` on `ManualThreadGroup` (or new
  overlay) so archive is reversible in-app and survives reloads.
- Sprout pipeline: hook into the existing refresh callback in
  `ThreadCanvasViewModel` to detect new messages since last tick and emit
  sprout events to the scene.
- Botanical token additions in `DesignTokens.swift`.
- Tests for `GraphForceSimulator` (deterministic seeds), nearest-neighbor
  selection, snip/archive state machine, sprout detection.

Out of scope:
- Lines and Synaptic visual variants (Lines tokens stay in the design notes
  but are not wired up).
- Dark mode (tracked in Open Questions; light only for v1).
- Multi-galaxy / multiple "You" nodes.
- Partial pruning (snip from this point downward) — whole-thread snip only.
- Mobile / iPad layouts.
- Replacing the existing timeline.

## Assumptions and Confirmed Decisions

1. **Coexistence**: Graph mode is a sibling rendering mode, selectable from
   the top bar. Default remains timeline. Selection state is shared across
   modes (selecting a thread in graph mode and switching to timeline scrolls
   to it; vice-versa).
2. **Engine**: `SpriteKit` (`SKView` inside `NSViewRepresentable`). Reasoning:
   60 fps hit-testing on thousands of nodes, easy custom rendering for
   breath/water/wilt, native gesture pipeline. Force step is **custom code in
   `update(_:)`** (not `SKPhysicsBody`) so we can match `FORCES` exactly and
   add a Barnes-Hut quadtree if N grows.
3. **Snip = real Mail move**. Sub-folder is user-chosen each time, with a
   **default parent mailbox** ("Unimportant", configurable in settings).
   Performed via AppleScript through `MailAppleScriptClient`. Compost chip
   stores the prior folder so restore can move it back.
4. **Archive = app-only**. Stored as a `ManualThreadGroup` overlay flag
   (`isArchivedInGraph`). No AppleScript side effects. Restore unsets flag.
5. **Variant**: Botanical only.
6. **Light mode only** for v1.
7. **Reader**: reuse `ThreadInspectorView` (no new reader panel).
8. **Aliveness**: all six (physics, sway, breath, water, sprout, sound).
   Sound off by default.
9. Selection in graph mode mirrors `ThreadCanvasViewModel.selectedNodeID`
   (string thread id) so the existing inspector lights up unchanged.
10. Filter (top-bar search) dims non-matching nodes to ~22 % opacity in graph
    mode, matching the existing search semantics in timeline mode.

## Component decomposition

```
ThreadListView
└── topbar
    └── ModeSegmentedControl (Timeline | Graph)         [NEW]
└── canvasContainer
    ├── ThreadCanvasView (timeline)                     [existing]
    └── GraphCanvasView                                 [NEW]
        └── GraphRepresentable : NSViewRepresentable
            └── SKView
                └── GraphScene : SKScene
                    ├── BackgroundGridNode
                    ├── EdgeLayer (SKShapeNode per edge)
                    ├── NodeLayer
                    │   ├── CenterYouNode
                    │   ├── ThreadNode (× N)
                    │   └── MessageNode (× M)
                    └── OverlayLayer (sprout / wilt FX)
        └── GraphHoverCard (SwiftUI overlay)            [NEW]
        └── GraphToolbar (SwiftUI overlay)              [NEW]
            ├── SnipModeButton
            ├── ArchiveModeButton
            ├── ZoomOut / ZoomLabel / ZoomIn / Recenter
        └── GraphCompostRing (SwiftUI overlay)          [NEW]
└── inspectorOverlay
    └── ThreadInspectorView                             [reused as-is]
```

State machine (prune):
```
idle ─(toolbar Snip)─> snipMode
idle ─(toolbar Archive)─> archiveMode
snipMode ─(edge click)─> pickingFolder ─(picked)─> wilting ─(end)─> composted
archiveMode ─(edge click)─> settling ─(end)─> composted
{snipMode|archiveMode} ─(Esc / toolbar tap)─> idle
composted ─(chip click)─> restoring ─(end)─> idle
```

## Layout grid / spacing

- App padding unchanged. Topbar height `38 px`; bottom toolbar floats
  `24 px` from canvas bottom, centered.
- Compost ring floats `24 px` from bottom-right. Max width `280 px`.
- Inspector slides in over the canvas (existing animation: `spring(0.24,
  0.82)`). Graph reserves the visible 320 px inspector lane plus app chrome
  spacing so nodes and toolbar controls do not sit underneath it.
- When the bottom selection/action bar is visible, the graph toolbar and
  compost ring reserve the same bottom chrome lane before applying their
  `24 px` floating offset.

## Milestones

- [x] **M1: Botanical tokens + GraphCanvasSettings scaffold**
  - **Intent**: Add the visual tokens and a settings object so the canvas can
    read variant + sound + snip parent mailbox.
  - **Files**: `Sources/UI/DesignTokens.swift`,
    `Sources/Settings/GraphCanvasSettings.swift` (new),
    `Sources/Settings/AppearanceSettings.swift` (extend if needed).
  - **Spec ref**: `styles.css` :12-43 (color tokens), :276-278 (botanical),
    :393-395 (botanical msg/thread).
  - **Tokens to apply**: All values in the table above. Botanical edge
    `#A6B098`, trunk `#6B7A5C`, msg `#7A8F66`, thread-high stroke `#4A5640`.
  - **Validation**: Build succeeds. Add a Snapshot/Preview rendering of a
    swatch grid in a #if DEBUG view; eyeball against `styles.css` values.
  - **Notes / blockers**: Implemented in `DesignTokens.swift` and new
    `GraphCanvasSettings.swift`; validated by app build and focused graph
    tests. Swatch preview/manual browser pixel check remains a follow-up.

- [x] **M2: ModeSegmentedControl + container split**
  - **Intent**: Add `Timeline | Graph` toggle in the top bar; render either
    `ThreadCanvasView` or a `GraphCanvasView` placeholder. Persist choice in
    `GraphCanvasSettings.mode` (defaults to `.timeline`).
  - **Files**: `Sources/UI/ThreadListView.swift` (add toggle), new
    `Sources/UI/Graph/GraphCanvasView.swift` (placeholder body).
  - **Spec ref**: `styles.css` :165-187 (`.bm-segmented`).
  - **Styles**: segmented track `bm-panel-2` with `1 px bm-line` border,
    `8 px` radius, `2 px` inner pad; active button `bm-panel` with the
    standard 0.5 px hairline + 1 px shadow.
  - **States**: hover (subtle `bm-panel-2` ↔ `bm-panel` swap), focus ring
    `bm-accent` 1.5 px, selected.
  - **Validation**: Toggle round-trips across app restarts (UserDefaults).
    Both modes mount without console errors. Existing timeline behavior
    unchanged when `mode = .timeline`.
  - **Notes / blockers**: Implemented in `ThreadListView.swift` and
    `GraphCanvasView.swift`; mode persistence is backed by UserDefaults.

- [x] **M3: GraphCanvasViewModel + JWZ → graph data mapping**
  - **Intent**: Subscribe to `MessageStore` updates and build a
    `GraphData { center, threads, edges, messages }` from `JWZThreader`.
    Reuse the threads `ThreadCanvasViewModel` already exposes; do not run
    JWZ twice.
  - **Files**: `Sources/ViewModels/GraphCanvasViewModel.swift` (new),
    `Sources/UI/Graph/GraphData.swift` (new — value types).
  - **Spec ref**: `data.jsx` (shape of `threads`, `edges`, `messages`,
    `tags`, `importance`).
  - **Mapping**:
    - `center.id = "you"`.
    - `thread.id = EmailThread.id`; `subject = EmailThread.subject`;
      `messageCount = EmailThread.messageCount`;
      `importance = .low if messageCount < 4, .med if < 9, else .high`;
      `live = lastUpdated > now - 24h`;
      `angle = goldenAngle(index)` (`(i * 137.5°) mod 360°`) for stable
      starting positions.
    - `message.id = ThreadNode.id`; `message.threadId`; `message.index`;
      `message.unread = !message.isRead`.
    - `edges`: trunk `you -> thread`; chain `thread -> msg0 -> msg1 -> ...`
      following `ThreadNode.children` depth-first.
  - **Validation**: Unit test `GraphMappingTests` — given a fixture inbox of
    9 threads × 3-12 messages, assert edge count = `T + sum(messageCount)`,
    every message has exactly one inbound edge, no orphans.
  - **Notes / blockers**: Implemented in `GraphCanvasViewModel.swift` and
    `GraphData.swift`; graph node IDs are namespaced while raw Mail message
    IDs are preserved for moves. `GraphMappingTests` passes.

- [x] **M4: SpriteKit scene skeleton + force simulator**
  - **Intent**: Render center/threads/messages/edges with the full custom
    force step. Drag-to-rearrange works. No prune/sound/water yet.
  - **Files**: new
    `Sources/UI/Graph/GraphRepresentable.swift` (`NSViewRepresentable`),
    `Sources/UI/Graph/GraphScene.swift`,
    `Sources/UI/Graph/GraphForceSimulator.swift`,
    `Sources/UI/Graph/GraphSceneNodes.swift`.
  - **Spec ref**: `graph.jsx` :11-17 (FORCES), :64-144 (step), :19-62
    (initLayout), adapted in Swift for straight edge paths.
  - **Force step (per frame, dt clamped to 32 ms)**:
    - Edge spring force: `f = (dist - target) * k`; trunk target `210`,
      non-trunk `104`; `k = edgeSpring (1.2 × for non-trunk)`.
    - Pairwise repulsion: skip if `d² > 160000`; `f = repulsion / (d² + 160)`
      plus overlap padding based on node radii.
    - Branch straightening: message nodes are pulled back toward the thread's
      outward radial axis and pushed forward when a chain segment curls behind
      the thread orbit.
    - Center pull (orphans): `vx += dxc * 0.0006` for thread, `0.0002` for
      message.
    - Breeze: `sin(t·0.0006)·0.06` (x), `cos(t·0.0009)·0.04` (y); weight
      `1.2` for messages, `0.4` for threads/center.
    - Damping `0.82`.
    - Center node pinned at scene midpoint via fixed `position`.
  - **Edge rendering**: straight line segments for trunk and chain edges.
  - **Importance ring** stroke widths: low `1.0`, med `1.2`, high `1.6`.
  - **States**: `.is-hover` (`bm-accent` stroke 1.6 + drop-shadow), `.is-low`
    (`bm-ink-5` 1 px), `.is-med` (`bm-ink-3` 1.2 px), `.is-high` (`bm-ink`
    1.6 px). Botanical overrides per token table.
  - **Validation**: Open the app, switch to Graph mode with a real inbox,
    confirm 60 fps in Instruments (`SKView.showsFPS = true` debug-only),
    drag works, pan via empty-space drag works, zoom via wheel works, and
    nothing crashes when the inbox refreshes.
  - **Notes / blockers**: Implemented with `GraphRepresentable`,
    `GraphScene`, `GraphSceneNodes`, and `GraphForceSimulator`; app build and
    direct Computer Use smoke verification cover launch/mount. Live debug
    verification showed the Graph canvas mounted at ~57-58 fps on 69 nodes.
    Instruments 60-fps capture remains a follow-up.

- [x] **M5: Hover preview card + selection + filter dimming**
  - **Intent**: SwiftUI overlay shows the design's hover card on hover.
    Selection highlights the disc (`bm-accent` stroke 2 + soft fill). Top-bar
    filter dims non-matching nodes/edges to 22 %.
  - **Files**: `Sources/UI/Graph/GraphHoverCard.swift` (new),
    `Sources/UI/Graph/GraphCanvasView.swift` (overlay + filter binding),
    `Sources/ViewModels/GraphCanvasViewModel.swift` (hover/filter state).
  - **Spec ref**: `styles.css` :434-503 (hover card),
    `graph.jsx` :541-624 (HoverCard).
  - **Card**: `260 px` wide, `12-14 px` padding, white panel with the design's
    triple shadow, contains:
    - Thread: folder · `Nh ago` row, subject (13 px / 600), tag chips,
      `<count> messages · <importance> importance`, kbd hint
      (`click open · dbl water`).
    - Message: sender · time, snippet, tag chips.
  - **Validation**: Pixel-compare card against `BetterMail Graph View.html`
    rendered in a browser at 1× zoom.
  - **Notes / blockers**: Implemented in `GraphHoverCard.swift`,
    `GraphCanvasView.swift`, and `GraphScene.swift`; manual pixel comparison
    against the HTML artifact remains a follow-up.

- [x] **M6: Toolbar + zoom/pan/recenter**
  - **Intent**: Floating bottom toolbar matching the design (Snip / Archive /
    divider / zoom-out / zoom% / zoom-in / recenter).
  - **Files**: `Sources/UI/Graph/GraphToolbar.swift` (new), wire into
    `GraphCanvasView`.
  - **Spec ref**: `styles.css` :505-570 (`.bm-graph-toolbar`),
    `graph.jsx` :625-653 (`GraphToolbar`).
  - **States**: `is-on` for active prune mode (Snip → `bm-snip` bg, Archive
    → `bm-archive` bg, both with white text); hover on plain buttons fills
    `bm-panel-2`. Zoom range `0.4×` – `2.4×`; cursor swaps to a
    custom `✂` / `⏚` cursor when in prune mode (`NSCursor` with
    SF-Symbol-rendered image).
  - **Validation**: Keyboard shortcuts `S/A/Esc/+/-/0` work and update the
    toolbar visual state.
  - **Notes / blockers**: Implemented in `GraphToolbar.swift`,
    `GraphCanvasView.swift`, and graph-mode key handling in
    `ThreadListView.swift`. The toolbar also consumes the bottom action-bar
    reservation supplied by `ThreadListView` so it does not overlap selected
    message actions.

- [x] **M7: Aliveness — breath, sway, water, sprout**
  - **Intent**: Add the four ambient animations.
  - **Files**: `Sources/UI/Graph/GraphScene.swift` (per-frame in `update`),
    `Sources/UI/Graph/GraphSceneNodes.swift` (aura nodes).
  - **Spec ref**: `styles.css` :353-375 (breath, water), :716-722 (sprout);
    `graph.jsx` :108-142 (breeze in step), :391-400 (water handler),
    :483-485 (per-thread breath scale).
  - **Implementation**:
    - **Breath** on `thread.live`: scale modulated by
      `1 + sin((t + breathPhase·1000)·0.0025)·0.06`. Aura ring
      (`SKShapeNode`) with `bm-live` stroke `0.8 px`, opacity `0.35→0`
      over `3.4 s`.
    - **Sway**: already in M4 via breeze; verify it visibly nudges leaf
      messages more than threads.
    - **Water**: double-click on thread fires a one-shot `SKAction` that
      spawns a `bm-water` ring scaling `0.8→1.5` over `2.4 s`,
      `opacity 0.6→0`. Subsequent double-clicks add `+4 px` to the
      base aura radius (matches `n.radius + 18 + watered*4`). Persist
      `wateredCount` per thread in `GraphCanvasSettings` keyed by
      thread id.
    - **Sprout**: when `GraphCanvasViewModel` detects a new
      `EmailMessage` since last tick, the corresponding `MessageNode`
      runs `scale 0→1.2→1` over `0.55 s`.
  - **Validation**: With three "live" threads, breath rings visibly pulse;
    double-click watered threads accumulate; refresh that introduces a
    message animates that node in.
  - **Notes / blockers**: Implemented in `GraphScene.swift`,
    `GraphSceneNodes.swift`, and `GraphCanvasViewModel.swift`; build/tests
    pass. Manual multi-live-thread visual validation remains a follow-up.

- [x] **M8: Optional sound**
  - **Intent**: Hover, snip, archive, water sounds — off by default, toggle
    in `GraphCanvasSettings`.
  - **Files**: `Sources/UI/Graph/GraphAudio.swift` (new — wraps
    `AVAudioEngine` with synth oscillators, mirroring `graph.jsx` :262-298),
    settings sheet in `Sources/UI/Graph/GraphSettingsSheet.swift` (new) or
    extend an existing settings surface.
  - **Spec ref**: `graph.jsx` :262-298 (synth params per kind).
  - **Implementation**: tone synthesis via `AVAudioSourceNode` with the
    exact frequency/gain envelopes from JS. Respect system "play UI sounds".
  - **Validation**: Toggle on, perform each action, confirm tone fires;
    toggle off, confirm silence.
  - **Notes / blockers**: Implemented in `GraphAudio.swift` and
    `GraphSettingsSheet.swift`; sound defaults off. Manual audible validation
    remains a follow-up.

- [x] **M9: Compost ring + restore**
  - **Intent**: Bottom-right floating panel listing pruned threads as chips.
    Click chip = restore (route per action).
  - **Files**: `Sources/UI/Graph/GraphCompostRing.swift` (new), wire into
    `GraphCanvasViewModel`.
  - **Spec ref**: `styles.css` :572-636, `graph.jsx` :655-680.
  - **Behavior**: chips render with the action color (snip = rust, archive
    = slate); icon `✂` / `⏚`; subject ellipsized at `130 px`. Hover lifts
    the chip `1 px`. Empty state hides the panel.
  - **Validation**: Snip a thread → chip appears → click → thread reappears
    in graph; archive a thread → chip appears → click → flag cleared. State
    survives mode toggle (timeline ↔ graph).
  - **Notes / blockers**: Implemented in `GraphCompostRing.swift` and
    `GraphCanvasViewModel.swift`; archive restore is persisted via
    `MessageStore`. Real Mail snip restore requires manual account-folder
    validation.

- [x] **M10: Snip pipeline (real Mail.app move)**
  - **Intent**: Edge click in snip mode opens `SnipMoveSheet` rooted at the
    user's chosen "Unimportant" parent mailbox (settable in
    `GraphCanvasSettings`). Confirm → AppleScript move all messages of the
    thread → wilt animation → compost chip stores `priorMailboxPath` for
    restore.
  - **Files**: `Sources/UI/Graph/SnipMoveSheet.swift` (new),
    `Sources/DataSource/MailAppleScriptClient.swift` (extend with
    `func moveMessages(messageIDs: [String], toMailboxPath: String)
       async throws` and a `func subMailboxes(of: String) async throws ->
       [MailboxHierarchy]`),
    `Sources/Settings/GraphCanvasSettings.swift`
    (`@AppStorage var snipParentMailboxPath: String`).
  - **Spec ref**: `graph.jsx` :300-321 (`performPrune` flow);
    `styles.css` :404-417 (`bm-snip-shape`, `bm-snip-wilt`).
  - **Wilt animation**: opacity 1→0 over `1.6 s`, `vy += 0.4` per frame,
    rotation `+0.04 rad/frame`, x jitter ±0.2.
  - **Restore**: chip click → AppleScript move messages back to
    `priorMailboxPath` → re-enable nodes (clear `dead/snipped` flags) →
    physics resumes from current scene positions.
  - **Validation**: Manual test on a real Mail.app inbox: snip a thread →
    pick a sub-folder → confirm Mail moved the messages (verify in
    Mail.app). Restore returns them to the original folder. Errors from
    AppleScript surface as a toast in `ToastOverlay`; the wilt is rolled
    back if the move fails.
  - **Notes / blockers**: Implemented in `SnipMoveSheet.swift`,
    `GraphCanvasViewModel.swift`, and `MailAppleScriptClient.swift`.
    Direct Mail-side move/restore validation is intentionally left as a
    manual test to avoid mutating live mail during automated validation.

- [x] **M11: Archive pipeline (app-only overlay)**
  - **Intent**: Edge click in archive mode → settle animation → compost.
    No AppleScript. Persisted in a new `archivedInGraph` overlay.
  - **Files**: `Sources/Models/ManualThreadGroup.swift` (extend with
    `var isArchivedInGraph: Bool = false`) **or**
    `Sources/Storage/ArchivedInGraphStore.swift` (new — Core Data entity
    `ArchivedInGraphEntry { threadID: String, archivedAt: Date }`).
    Prefer the new store to avoid bloating `ManualThreadGroup`.
  - **Spec ref**: `styles.css` :419-432 (`bm-archive-settle`),
    `graph.jsx` :300-321 (action branch).
  - **Behavior**: When archived, threads are excluded from graph rendering
    (and optionally from timeline — confirm in Open Questions). On restore,
    the entry is deleted and the thread reappears.
  - **Validation**: Archive a thread, restart the app, confirm it stays in
    compost. Restore, restart, confirm it returns.
  - **Notes / blockers**: Implemented with an `ArchivedInGraphEntry` Core
    Data overlay in `MessageStore`; focused prune state-machine tests pass.

- [x] **M12: Keyboard navigation + reduce-motion**
  - **Intent**: Arrow keys move selection (nearest-neighbor in 2D),
    `Return` opens, `S/A/Esc/W/+/-/0` fire toolbar actions; reduced-motion
    disables breeze/breath/water/wilt-rotation.
  - **Files**: `Sources/UI/Graph/GraphCanvasView.swift` (`.onKeyPress`),
    `Sources/UI/Graph/GraphScene.swift` (gate animations on
    `accessibilityReduceMotion`).
  - **Spec ref**: app convention from `ThreadListView` :30-35.
  - **Validation**: Run with VoiceOver on; tab into the canvas; confirm
    spoken labels per the Accessibility section.
  - **Notes / blockers**: Implemented graph-mode shortcuts and directional
    selection; `GraphSelectionTests` passes. Full VoiceOver walkthrough
    remains a follow-up.

- [x] **M13: VoiceOver labels + accessibility identifiers**
  - **Intent**: Each node has VO labels; toolbar buttons + chips have
    accessibility identifiers for UI tests.
  - **Files**: `Sources/UI/AccessibilityIdentifiers.swift` (extend),
    `Sources/UI/Graph/GraphRepresentable.swift` (expose accessibility
    elements via `NSAccessibility`).
  - **Validation**: Existing UI test infra resolves new identifiers
    (`graphCanvas`, `graphToolbar.snip`, `graphToolbar.archive`,
    `graphCompostRing.chip.<id>`). New unit tests for label generation.
  - **Notes / blockers**: Implemented graph accessibility identifiers and
    node labels. UI-test identifier lookup was not run because no graph UI
    test target exists in the current suite.

- [x] **M14: Tests**
  - **Intent**: Cover the deterministic seams.
  - **Files**: `Tests/Graph/GraphForceSimulatorTests.swift`,
    `Tests/Graph/GraphMappingTests.swift`,
    `Tests/Graph/GraphSelectionTests.swift`,
    `Tests/Graph/GraphPruneStateMachineTests.swift`.
  - **Cases**:
    - Mapping (M3 case): edge invariant.
    - Force simulator: with a fixed seed, energy decreases monotonically
      over 2 s and the system settles to within `±2 px` of a reference
      layout.
    - Selection: nearest-neighbor across 9 threads × 6 messages picks the
      expected ID for each arrow direction from a chosen origin.
    - Prune machine: `idle → snipMode → pickingFolder → wilting →
       composted` and `composted → idle` round-trip.
  - **Validation**: `xcodebuild test … -only-testing:BetterMailTests/Graph*`
    passes; suite must be deterministic (no real AppleScript / network).
  - **Notes / blockers**: Implemented in `Tests/GraphTests.swift`. Validated
    with focused XCTest slice: 5 tests, 0 failures.

- [x] **M15: Polish + perf pass**
  - **Intent**: Hit the 60 fps target on a realistic inbox.
  - **Files**: `Sources/UI/Graph/GraphForceSimulator.swift` (Barnes-Hut),
    `Sources/UI/Graph/GraphScene.swift` (cull off-screen edges; reuse
    `SKShapeNode` paths via `CGMutablePath`).
  - **Implementation**: If a 1000-node fixture stays under 60 fps, add
    Barnes-Hut quadtree (theta `0.85`) for the repulsion sum. Cull edges
    whose midpoint is outside scene bounds + `120 px`. Coalesce path
    rebuilds every other frame for non-trunk edges.
  - **Validation**: Instruments: 60 fps on a 1000-node fixture for 60 s on
    M-series Mac; CPU < 35 %.
  - **Notes / blockers**: Implemented simulator cutoff/damping safeguards,
    deterministic simulator seams, `preferredFramesPerSecond = 60`, batched
    SpriteKit edge layers, viewport edge culling, and coalesced chain-edge
    path rebuilds. Computer Use verified ~57-58 fps on the live 69-node inbox;
    Computer Use also verified inspector and bottom action-bar chrome no
    longer overlap graph controls after the inset pass;
    the full 1000-node Instruments run and Barnes-Hut threshold decision
    remain follow-ups.

## Risks

- **AppleScript move performance / failures**: Mail.app can be slow or
  permission-prompt the user. Mitigation: optimistic wilt with rollback,
  toast-surfaced errors, and a per-thread "move in flight" lock to prevent
  double-firing.
- **SpriteKit/SwiftUI bridging quirks**: keyboard focus and VoiceOver inside
  an `NSViewRepresentable` need care. Mitigation: keep the toolbar +
  hover card in SwiftUI (focusable there), forward only graph nodes to
  SpriteKit accessibility.
- **Force simulation jitter at high zoom-out**: very small dt or very large
  scenes can let nodes oscillate. Mitigation: clamp dt to `32 ms`, freeze
  velocities below `0.05 px/frame`, snap to grid when `|v| < ε`.
- **Sound on macOS**: AVAudioEngine's source nodes incur first-tap latency.
  Mitigation: warm the engine on graph mount; reuse a single engine.
- **Thread/folder model coupling**: archive-overlay store must invalidate
  on thread merge / split. Mitigation: archive entries keyed by
  `EmailThread.id`; on merge, both ids stay archived until restored.

## Acceptance Criteria

- Graph mode is selectable from the top bar; default remains timeline; choice
  persists across launches.
- The center "You" node is fixed at the canvas midpoint; threads orbit at
  ~200 px; messages chain outward following the JWZ tree.
- Importance is encoded by ring stroke weight (1.0 / 1.2 / 1.6 px); live
  threads pulse a teal breath ring at the spec'd cadence.
- Drag any thread/message → physics rearranges; release → settles within
  ~2 s; "You" cannot be dragged.
- Pan + zoom + recenter work via gesture, scroll wheel, and toolbar; zoom
  range `0.4×` – `2.4×`.
- Hover on thread/message shows the design's hover card with the correct
  copy and tokens.
- Search dims non-matching nodes and edges to ~22 % opacity.
- Snip flow: edge click in snip mode opens the folder picker rooted at the
  configured "Unimportant" parent; on confirm, Mail.app moves the messages,
  the thread wilts, and a rust chip appears in the compost. Restore moves
  the messages back to the original folder.
- Archive flow: edge click settles + grays the thread, slate chip appears in
  compost. Restore returns it. State persists across restart.
- Double-click a thread spawns a teal water aura that persists; subsequent
  double-clicks grow it.
- New messages on refresh sprout into the canvas at the thread tip.
- All animations respect Reduce Motion.
- VoiceOver reads thread/message labels; keyboard shortcuts `S/A/Esc/W/0`
  and arrow-keys/Return work.
- Botanical token set is applied throughout (no Lines / Synaptic anywhere).
- 60 fps sustained on a 1000-node fixture in Instruments on Apple-silicon.

## Open Questions

1. **Should archived-in-graph threads also disappear from the timeline view,
   or only from graph?** (Default proposal: only graph; the user can still
   see them on the timeline and in Mail.app.)
2. **"Unimportant" parent mailbox**: if the user has not configured one,
   should the picker show the full mailbox tree, or block snip until set?
   (Default proposal: show full tree, with a "Set as default Unimportant
   parent" affordance on first snip.)
3. **Sound effect file vs synth**: ship synthesized tones (matches design
   exactly) or curated audio assets? (Default proposal: synth, mirroring the
   web prototype.)
4. **Dark mode**: is there a desired visual direction now (so we can author
   dark tokens up front), or fully defer? (Defaulting to defer.)
5. **Mode persistence scope**: per-mailbox or app-global? (Default proposal:
   app-global.)
6. **Compost retention**: should compost survive app restart? (Default
   proposal: yes for archive, no for snip — snip is already reflected in
   Mail.app.)

## Design artifact links

- Brief: `/Users/isaacibm/Downloads/BetterMail Design/DESIGN-NOTES.md`
- Force engine reference: `/Users/isaacibm/Downloads/BetterMail Design/graph.jsx`
- Tokens & animations: `/Users/isaacibm/Downloads/BetterMail Design/styles.css`
- Live demo (browser): `/Users/isaacibm/Downloads/BetterMail Design/BetterMail Graph View.html`
