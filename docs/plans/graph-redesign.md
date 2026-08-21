# BetterMail · Graph View Redesign — Implementation Plan

> 2026-08-06 replacement: the mounted runtime is now the Swift-native
> Obsidian-style adapter documented in `README.md` and `TechDocs/index.md`.
> `GraphRepresentable` mounts `ObsidianGraphScene` /
> `ObsidianGraphForceSimulator` rather than the radial/ribbon `GraphScene`.
> BetterMail's `GraphData`, grouping confirmation, paging, selection, triage,
> prune, and persistence contracts are unchanged. The renderer boundary follows
> the same preserve-the-model/replace-the-view strategy established in Codex
> task `019fb780-ef94-7fd2-8134-2872ce095627`. This plan remains historical
> context for the retired renderer and its regression coverage.
>
> 2026-07-27 follow-up: the shipped four-force canvas now has a centered,
> full-circle tree layer, persisted folder branches, confirmable Apple
> Intelligence ghost branches, frame-timed live-neighbor response during
> fixed-node drag, and canopy-pressure feedback. This latest centered-root
> direction supersedes both this plan's original flat layout and the interim
> bottom-rooted layout, as well as its static-neighbor drag and "aliveness
> extras out of scope" boundaries.
> The current runtime contract is documented in `README.md` and
> `TechDocs/index.md`.

A second-pass redesign of the existing graph canvas
([`Sources/UI/Graph/`](../../BetterMail/Sources/UI/Graph)). The first version
shipped (see [graph-view.md](graph-view.md)); this redesign replaces the
radial "branch" force model with a pure D3-style four-force system, adds
per-message AI summaries, retires the legacy botanical palette in favor of the main
app theme, and switches to native macOS scroll/zoom semantics.

## Objective

- Replace the current radial branch-shaping force with **pure
  Center / Repel / Link (spring) / Link-distance** forces so threads grow
  organically rather than along straight spokes.
- Render edges as Catmull–Rom splines through deterministic perpendicular
  control points (cosmetic curl that tapers at endpoints).
- Show per-message AI summaries inline (auto-placed) the way the timeline
  view already does.
- Replace the legacy botanical palette with the main-app theme tokens; honor the
  user's app appearance setting (light/dark).
- Adopt native macOS gestures: 2-finger trackpad pan with momentum, pinch
  zoom around the cursor, `⌘`/`ctrl`+scroll zoom for mouse users,
  double-click empty canvas to recenter. No modifier required for panning.

## Scope

**In**
- `Sources/UI/Graph/GraphForceSimulator.swift` — remove
  `applyBranchShapeForces` + related constants; tune the four classic forces.
- `Sources/UI/Graph/GraphScene.swift` — Catmull–Rom edge rendering; native
  scroll/pinch handling with momentum/rubber-band; double-click recenter on
  empty canvas; theme-aware colors.
- `Sources/UI/Graph/GraphSceneNodes.swift` — per-message summary callout node
  with auto-placement and tether; thread label sizing unchanged behaviorally.
- `Sources/UI/Graph/GraphCanvasViewModel.swift` — pipe `nodeSummaries` down
  into the scene; recompute label/summary occluder radii when summaries
  arrive.
- `Sources/UI/DesignTokens.swift` — add `DesignTokens.Graph.AppTheme` mapping
  to existing app tokens (panel/ink/accent); leave `legacy botanical` in place but
  unreferenced.
- `Sources/Settings/GraphCanvasSettings.swift` — expose tunable force
  constants (center, repel, repelCutoff, linkSpring, trunkLength,
  chainLength, damping, curl, curlVariability, splineTension, curlFalloff,
  labelRepelOn, labelRepelStrength).
- `Sources/UI/Graph/GraphSettingsSheet.swift` — add a "Forces" section with
  the new sliders plus a "Restore defaults" action (binds the **Whisper /
  Organic** preset).
- Tests in `Tests/GraphTests.swift` (or new file) for the simplified
  simulator and auto-placement scoring.

**Out of scope**
- Re-introducing the variant toggles (Lines / Synaptic) — legacy botanical stays
  retired but its tokens remain in the file as dead code, no UI references.
- Changes to the snip / archive / compost flows.
- Aliveness extras beyond what is needed to keep breath + water working
  under the new force model.
- Mobile / iPad layouts.
- Mini-map, multi-galaxy.

## Confirmed decisions (Q&A summary)

1. **Edge geometry** — option **C**: physics runs on real nodes only (no
   intermediate joint nodes); edges render as Catmull–Rom splines through
   3 perpendicular control points seeded deterministically per edge.
2. **Summary placement** — option **B**: auto-place via 8-direction free-space
   scan with hysteresis; labels participate in repulsion via an enlarged
   occluder radius (`labelRepel` on by default).
3. **Theme** — match the app's appearance setting. `Light` uses the existing
   main-app tokens (`bm-bg / bm-panel / bm-ink* / bm-accent`); `Dark`
   inherits the same token names from `DesignTokens` dark variants.
4. **Scroll/zoom map (native)** —
   - 2-finger trackpad scroll → pan, no modifier, momentum preserved.
   - Pinch → zoom around cursor.
   - `⌘`/`ctrl`+scroll → zoom around cursor (for mouse users).
   - Double-click empty canvas → recenter + reset zoom to 1×.
   - Drag empty canvas → pan (fallback for trackballs / no scroll).
   - Right-drag → pan (retained from current behavior).
5. **Forces exposed in settings** — option **B**: sliders live in
   `GraphSettingsSheet` so the user can re-tune at runtime; "Restore
   defaults" snaps to the **Whisper** preset below.

### Approved force preset ("Whisper" — default)

| Constant | Value |
|---|---|
| `center` | `0.006` |
| `repel` | `4200` |
| `repelCutoff` (px) | `360` (cutoff² = `129_600`) |
| `linkSpring` | `0.045` |
| `trunkLength` (px) | `210` |
| `chainLength` (px) | `104` |
| `damping` | `0.86` |
| `breeze` amplitude | `0.7` |
| `curl` (px) | `3` |
| `curlVariability` | `0.2` |
| `splineTension` | `0.35` |
| `curlFalloff` | `0.45` |
| `labelRepel` | `true` |
| `labelRepelStrength` | `0.12` |

Forces dropped from the previous design:
`branchStraightening`, `branchOutward`, `branchStartSpacing`,
`branchStepSpacing`, and the radial axis projection in
`applyBranchShapeForces`. The "Whisper" curl is a render-time deterministic
spline only — no per-frame perpendicular force on physics nodes.

### Auto-placement contract for summaries

- Each message node samples 8 cardinal angles at radius `dist =
  14 + max(boxW, boxH) * 0.35`.
- Score each candidate by **distance to nearest other physics node**, plus a
  hysteresis bias toward the previously chosen angle (`+600` weighted by
  `cos(Δθ)`) to prevent flicker.
- Smooth the chosen angle with `lerp(prev, picked, 0.18)` per frame.
- Render the callout as a rounded panel (`5 px` radius), 2-line wrap at
  `160 px` max width, hairline `summaryLine` stroke, tether from node edge to
  nearest box edge along the chosen angle.

### Label-aware repulsion

Repulsion uses an **effective radius** equal to
`node.radius + labelRadius(node)`, where `labelRadius` returns:
- `60 px` for messages when `showSummaries` is on,
- `34 px` for thread nodes when `showLabels` is on,
- `0` otherwise.

The contribution is an additive overlap term:
`force += max(0, preferredDistance - distance) * labelRepelStrength`. Gated
by `labelRepel` so we can A/B without recompiling.

### Native scroll/zoom — implementation contract

- `scrollWheel(with:)`: if `event.hasPreciseScrollingDeltas` (trackpad), pan
  using `scrollingDeltaX/Y` and integrate **momentum from the existing
  AppKit scroll phase** (`event.phase` / `momentumPhase`). No modifier-key
  gating for pan.
- `⌘` or `ctrl` + scroll → zoom around `event.location(in: self)` using
  `exp(deltaY * -0.005)`.
- `magnify(with:)`: zoom around the pinch focal point (already half-wired —
  reuse).
- `mouseDown` on empty canvas + immediate `mouseUp` within ~250 ms and no
  drag → treat as click. **Double-click** on empty canvas → animate
  zoom→1.0 and pan→origin over `0.24 s` with `spring(0.7)`.
- Rubber-band: when the camera position exits `constrainedCameraPosition`'s
  envelope, apply a `0.5 ×` damping factor instead of hard clamping; snap
  back on `momentumPhase = .ended`.

### Theme contract

- `DesignTokens.Graph.AppTheme.background = DesignTokens.panel.background`
  (light/dark resolved via `NSAppearance`).
- Trunk stroke = `DesignTokens.ink.tertiary` at `0.72` alpha; chain stroke =
  `DesignTokens.ink.quaternary` at `0.62` alpha.
- Node fill = `DesignTokens.panel.surface`; node stroke =
  `DesignTokens.ink.primary` at `1.2 px` (thread) / `0.9 px` (message).
- Center "You" fill = `DesignTokens.accent.primary`.
- Summary callout: fill = `panel.surface`, stroke = `ink.line` at `1 px`,
  text = `ink.primary` at `10.5 px / 500`.
- Reduce motion still respected (no breeze, no breath rotation).

## Component touchpoints

```
ThreadListView
└── GraphCanvasView ── GraphRepresentable ── SKView ── GraphScene
                                                       ├── EdgeLayer (spline paths)  [CHANGED]
                                                       ├── NodeLayer
                                                       │   ├── Center / Thread / Message
                                                       │   └── SummaryCalloutNode    [NEW]
                                                       └── ScrollMomentumDriver      [NEW]
└── GraphSettingsSheet  ── Forces section (sliders)    [EXTENDED]
```

`GraphCanvasViewModel` already receives `summariesByNodeID`; new work is
purely down-stream of that into scene nodes.

## Milestones

- [x] **M1: Strip radial branch forces and lock the four-force model**
  - **Intent**: Remove the branch-straightening / outward forces and the
    `messageDepthsByID` plumbing; keep Center + Repel + Link + Damping +
    Breeze only. Validate the system still settles for the existing fixture.
  - **Files**:
    - `BetterMail/Sources/UI/Graph/GraphForceSimulator.swift` (delete
      `applyBranchShapeForces`, `messageDepthsByID`, `branchStraightening`,
      `branchOutward`, `branchStartSpacing`, `branchStepSpacing`; remove the
      call site in `step`).
    - `Tests/GraphTests.swift` (drop the assertion that messages settle on
      a radial axis; assert energy decreases monotonically over 2 s instead).
  - **Validation**:
    - `xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -destination 'platform=macOS,arch=arm64' build`
    - `xcodebuild test … -only-testing:BetterMailTests/GraphTests`
    - Manual: open Graph mode → branches no longer hug straight spokes.
  - **Implementation note (2026-05-11)**: Removed radial branch-shaping
    constants, `messageDepthsByID`, and the branch force call from
    `GraphForceSimulator`; replaced the radial-axis test with a deterministic
    settling-energy trend test in `Tests/GraphTests.swift`.
    Validation: `xcodebuild build` succeeded; focused graph tests succeeded.
    Blockers: none.

- [x] **M2: Expose force constants in `GraphCanvasSettings` and load Whisper preset**
  - **Intent**: Move the constants out of `GraphForceConstants` into
    `GraphCanvasSettings` as `@AppStorage` (or equivalent) values; default
    them to the Whisper preset; pass them into `GraphForceSimulator.step`.
  - **Files**:
    - `BetterMail/Sources/Settings/GraphCanvasSettings.swift` (new keys with
      defaults from the table above).
    - `BetterMail/Sources/UI/Graph/GraphForceSimulator.swift` (accept a
      `GraphForceConfig` struct in `step`; remove static `GraphForceConstants`
      references, keep `GraphForceConstants` as a static defaults provider).
    - `BetterMail/Sources/UI/Graph/GraphScene.swift` (read settings, pass
      config each tick).
  - **Validation**:
    - `xcodebuild build` succeeds; `xcodebuild test` green.
    - Toggling values via temporary debug bindings affects the live scene.
  - **Implementation note (2026-05-11)**: Added `GraphForceConfig`,
    `GraphCurlConfig`, `GraphForceConstants.defaults`, persisted Whisper
    settings in `GraphCanvasSettings`, and passed `settings.forceConfig`
    through `GraphRepresentable` into `GraphScene` each tick.
    Validation: `xcodebuild build` succeeded; focused graph tests succeeded.
    Blockers: none.

- [x] **M3: Catmull–Rom edge rendering with curl/falloff/tension**
  - **Intent**: Replace straight `path.move/addLine` edge geometry with a
    Catmull–Rom spline through 3 deterministic perpendicular control points
    per edge. Curl tapers via `sin(πt)^(1 - falloff*0.7)` so endpoints stay
    flush with node circles.
  - **Files**:
    - `BetterMail/Sources/UI/Graph/GraphScene.swift` (replace edge path
      builder in trunk + chain layers).
    - `BetterMail/Sources/UI/Graph/GraphSceneNodes.swift` (helper:
      `func splinePath(from a: CGPoint, to b: CGPoint, seed: UInt32, config: GraphCurlConfig) -> CGMutablePath`).
  - **Validation**:
    - Visual: with Whisper preset, edges are perceptibly non-straight but
      still attach cleanly to node circles; with curl=0 the path is straight.
    - Perf: `showsFPS` stays ≥ 55 fps on a 200-node fixture during a
      simulated 30 s breeze.
  - **Implementation note (2026-05-11)**: Added deterministic spline helpers
    in `GraphSceneNodes.swift` and switched trunk/chain rendering in
    `GraphScene` to seeded Catmull-Rom paths using a stable FNV-style edge ID
    hash. Validation: spline envelope test and focused graph tests succeeded.
    Blockers: none.

- [x] **M4: Per-message summary callout (auto-placed, label-aware)**
  - **Intent**: Add a `SummaryCalloutNode` (SKShapeNode + SKLabelNode) for
    each message whose `nodeSummaries` entry has non-empty text. Place using
    the 8-direction free-space scan + smoothed angle described above.
  - **Files**:
    - `BetterMail/Sources/UI/Graph/GraphSceneNodes.swift` (new node type).
    - `BetterMail/Sources/UI/Graph/GraphScene.swift` (lifecycle: create on
      summary arrival, update on tick, destroy on removal; cache angle state
      per node ID).
    - `BetterMail/Sources/UI/Graph/GraphCanvasViewModel.swift` (forward
      `nodeSummaries` updates to the scene with a stable diff signature).
  - **Validation**:
    - With the existing fixture, summaries appear next to every message that
      has a `ThreadSummaryState.text`.
    - Dragging a message reposition the callout; the chosen angle does not
      flicker (no more than 1 angle change per second under steady state).
  - **Implementation note (2026-05-11)**: Added `SummaryCalloutNode` and
    `GraphSummaryPlacement`; message summaries now render as separate two-line
    callouts with 8-direction scoring, hysteresis, smoothed angles, and tethers.
    Validation: summary placement test and focused graph tests succeeded.
    Blockers: none.

- [x] **M5: Label-aware repulsion in `GraphForceSimulator`**
  - **Intent**: Add an overlap term that uses `effectiveRadius = node.radius
    + labelRadius(node)` when `labelRepel` is on. Gate via settings so the
    behavior is reversible.
  - **Files**:
    - `BetterMail/Sources/UI/Graph/GraphForceSimulator.swift`
      (`applyRepulsionForces` now consults a `LabelOccluderProvider` closure
      passed in `step`).
    - `BetterMail/Sources/UI/Graph/GraphScene.swift` (build the provider
      from current scene state: which nodes have visible labels/summaries).
  - **Validation**: With repel-strength = `0.12` and Whisper forces,
    summaries no longer overlap each other on the existing fixture (verify
    by snapshotting positions of 3 nearby messages and asserting their
    rectangles don't intersect after `60` steps from seeded initial state).
  - **Implementation note (2026-05-11)**: Added label-aware overlap inside the
    existing repulsion cutoff and passed a scene-backed label occluder provider
    into `GraphForceSimulator.step`; the toggle short-circuits label radii when
    off. Validation: label-repel-off regression test and focused graph tests
    succeeded. Blockers: none.

- [x] **M6: Theme migration to main-app tokens**
  - **Intent**: Add `DesignTokens.Graph.AppTheme` mapped to existing app
    tokens; route all scene/edge/node/summary colors through it; honor light
    vs dark via `NSAppearance`. Leave the legacy v1 palette namespace defined
    for historical compatibility, but stop referencing it.
  - **Files**:
    - `BetterMail/Sources/UI/DesignTokens.swift`.
    - `BetterMail/Sources/UI/Graph/GraphScene.swift`,
      `GraphSceneNodes.swift`, `GraphHoverCard.swift`, `GraphToolbar.swift`,
      `GraphRestoreHistoryControl.swift`, `GraphSettingsSheet.swift` — replace the
      legacy v1 palette references with `DesignTokens.Graph.AppTheme.*`.
  - **Validation**:
    - Light + dark appearance both render legibly (manual smoke screenshot).
    - No remaining references to the legacy v1 palette in the Graph module.
  - **Implementation note (2026-05-11)**: Added
    `DesignTokens.Graph.AppTheme` dynamic NSColor/SwiftUI tokens and routed the
    graph scene, nodes, hover card, toolbar, restore history, canvas background,
    and settings sheet through AppTheme. Validation:
    the retired palette name no longer appears in `BetterMail/Sources/UI/Graph`;
    no matches; build/tests succeeded. Blockers: manual light/dark screenshot
    review remains recommended.

- [x] **M7: Native scroll/pan with momentum + rubber-band**
  - **Intent**: Rewrite `scrollWheel` to honor trackpad phase + momentum;
    drop the Option/Cmd requirement for panning; add rubber-band damping at
    the constrained-camera envelope; double-click empty canvas recenters and
    resets zoom over `0.24 s`.
  - **Files**:
    - `BetterMail/Sources/UI/Graph/GraphScene.swift` (`scrollWheel`,
      `magnify`, `mouseDown`, new `momentumPan` helper, double-click
      detection).
    - `BetterMail/Sources/UI/Graph/GraphRepresentable.swift` (no behavior
      change; verify forwarding).
  - **Validation**:
    - Trackpad 2-finger swipe pans without `⌥`/`⌘`; flick-pan continues
      after lift-off.
    - Pinch zooms around the pinch focal point.
    - `⌘` or `ctrl`+scroll on a mouse zooms around cursor.
    - Dragging the camera past the envelope feels elastic; releasing snaps
      back.
    - Double-click on empty canvas reanimates to `zoom=1, pan=(0,0)`.
  - **Implementation note (2026-05-11)**: Updated `GraphScene.scrollWheel`,
    blank-canvas mouse handling, camera rubber-banding, snapback, and
    double-click recenter while preserving node drag and right-drag pan.
    Validation: `xcodebuild build` succeeded. Manual trackpad/mouse gesture
    smoke remains follow-up. Blockers: none.

- [x] **M8: GraphSettingsSheet — Forces section**
  - **Intent**: Add a "Forces" group of sliders bound to
    `GraphCanvasSettings`. Mirror the playground's grouping:
    `Center / Repel / Repel cutoff / Link spring / Trunk length /
    Chain length / Damping / Curl / Curl variability / Spline tension /
    Curl falloff / Label repel toggle + strength`. Provide a "Restore
    defaults" button that writes the Whisper preset.
  - **Files**:
    - `BetterMail/Sources/UI/Graph/GraphSettingsSheet.swift`.
    - `BetterMail/Sources/Settings/GraphCanvasSettings.swift` (add a
      `restoreWhisperDefaults()` method).
  - **Validation**:
    - Sliders move → scene reacts within one tick.
    - Quit + relaunch preserves user edits.
    - "Restore defaults" snaps everything back to Whisper.
  - **Implementation note (2026-05-11)**: Added the Forces section sliders and
    label-repel toggle to `GraphSettingsSheet`; added
    `restoreWhisperDefaults()` to `GraphCanvasSettings`. Validation:
    `xcodebuild build` succeeded; focused graph tests succeeded. Blockers:
    manual persistence/relaunch check remains follow-up.

- [x] **M9: Tests**
  - **Intent**: Cover the new deterministic seams.
  - **Files**: `BetterMail/Tests/GraphTests.swift` (or new
    `Tests/Graph/GraphLayoutTests.swift`).
  - **Cases**:
    - Simulator energy decreases monotonically over 2 s on a fixed seed.
    - Spline path passes through `(start, end)` and stays within `curl + 4 px`
      of the straight line between them (envelope test).
    - Auto-placement scoring picks the cardinal with greatest free space on
      a hand-built fixture of 5 nearby nodes.
    - Label-repel adds zero force when the toggle is off (regression guard).
  - **Validation**: `xcodebuild test … -only-testing:BetterMailTests/Graph*`
    passes; suite remains deterministic.
  - **Implementation note (2026-05-11)**: Added deterministic coverage for
    settling trend, spline envelope, auto-placement free-space scoring, and the
    label-repel-off gate in `Tests/GraphTests.swift`. Validation: focused graph
    tests succeeded after rerunning with Xcode result-bundle permissions.
    Blockers: none.

- [x] **M10: Cleanup + docs**
  - **Intent**: Update `docs/thread-canvas-zstack-components.md` and
    `TechDocs/index.md` to reflect the redesign; mark `docs/plans/graph-view.md`
    M1–M15 superseded by this plan where they conflict; archive the
    legacy botanical token table in the original plan as historical.
  - **Files**: `docs/thread-canvas-zstack-components.md`,
    `TechDocs/index.md`, `docs/plans/graph-view.md` (add a "Superseded by
    graph-redesign.md (2026-05-11)" note at top).
  - **Validation**: docs grep for the retired palette name returns only the historical
    note; no functional refs to it in `BetterMail/Sources/UI/Graph/`.
  - **Implementation note (2026-05-11)**: Updated `TechDocs/index.md`,
    `docs/thread-canvas-zstack-components.md`, and the superseded
    `docs/plans/graph-view.md` note; normalized docs/playground wording so
    docs grep for the retired palette name returns only the historical note. Validation:
    docs grep checks passed. Blockers: none.

## Risks

- **Edge spline cost** — recomputing curved paths every frame for many
  edges can be expensive. Mitigation: reuse the existing
  `coalesce-every-other-frame` strategy from the v1 perf pass; consider
  only rebuilding chain edges whose endpoints moved more than `0.5 px`.
- **Auto-placement thrashing** — fast force changes can flip the chosen
  angle. Mitigation: hysteresis + slerp described above; cap angle changes
  to one every `~16` ticks.
- **Native momentum disagreement** — AppKit's `scrollWheel` momentum phase
  on some external mice can be missing. Mitigation: fall back to manual
  velocity-decay panning when `event.phase == []` and `hasPreciseScrolling
  Deltas == false`.
- **Dark theme contrast** — the existing app tokens were chosen for chrome,
  not canvas. Mitigation: gate the dark variant on a manual visual review
  before merging M6.

## Acceptance criteria

- With Whisper preset, branches visibly curl but settle within ~2 s of
  layout; no two messages share an identical perpendicular bias.
- Every message with a `ThreadSummaryState.text` shows a 2-line summary
  callout placed away from the nearest neighbor; no callout overlaps
  another in the existing fixture inbox.
- Graph mode uses the main app palette in both light and dark appearance;
  no `legacy botanical.*` symbol is referenced from `Sources/UI/Graph/`.
- Trackpad 2-finger pan works without modifier keys and exhibits momentum;
  pinch + `⌘`/`ctrl`-scroll zoom around cursor; double-click on empty
  canvas recenters.
- `GraphSettingsSheet` "Forces" section round-trips every value and exposes
  "Restore defaults".
- All `GraphTests` pass under `xcodebuild test` and remain deterministic.

## Open questions

1. **Per-thread label sizing** — should thread labels also auto-place using
   the same 8-direction scan, or stick with the current below-disc layout?
   (Default proposal: keep below-disc; auto-place only messages.)
2. **Curl seed stability** — should the seed survive `MessageStore` thread
   id changes (e.g., when JWZ re-merges threads)? (Default proposal: yes —
   seed off `subject + earliestMessageDate` rather than the live thread id.)
3. **Dark-mode tokens for the canvas** — reuse the chrome tokens verbatim,
   or author a dedicated `Graph.AppTheme.dark` set with slightly higher
   contrast? (Default proposal: ship verbatim; revisit if M6 visual review
   flags issues.)

## Design artifacts

- Playground (interactive): [docs/playgrounds/graph-redesign.html](../playgrounds/graph-redesign.html)
  — Whisper preset; sliders for every force constant; theme matches
  `DesignTokens` light/dark.
- Original (superseded for force-shape, retained for snip/archive/compost):
  [docs/plans/graph-view.md](graph-view.md).
