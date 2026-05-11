# BetterMail · Graph Branch-Style Edges — Implementation Plan

Make graph-canvas edges read as organic **branches** (tapered, gently arced
outward from the center, with a small joint at the parent) while staying
inside the existing monochrome ink theme. Builds on the post-redesign edge
system in [`graph-redesign.md`](graph-redesign.md).

## Objective

- Replace uniform-stroke Catmull–Rom edges with **tapered, filled "ribbon"
  branches** whose width shrinks from parent → child.
- Bias edge arc to bend **outward relative to the root center node** so
  branches fan symmetrically around the canvas instead of all curving the
  same screen direction.
- Add a small **filled joint cap** at the parent end of every edge so
  branches visibly "sprout" from their parent.
- Keep colors, theme tokens, and the rest of the graph's behavior unchanged.

## Scope

**In**
- `BetterMail/Sources/UI/Graph/GraphSceneNodes.swift` — extend `GraphSpline`
  (or add a sibling helper) to:
  - Accept an optional `anchor` (center) point and bias the asymmetric
    arc-sign to bend *away* from the anchor.
  - Provide a `ribbonPath(from:to:seed:config:widthStart:widthEnd:tipMin:taperPow:)`
    that samples the existing Catmull–Rom spline densely and returns a
    closed `CGPath` for a tapered fill.
- `BetterMail/Sources/UI/Graph/GraphScene.swift`
  - Switch edge layers from stroked `SKShapeNode` paths to **filled**
    `SKShapeNode` paths (one node per kind × dimmed/active, four total).
  - Build trunk/chain edge paths via the new `ribbonPath` helper, passing
    the root/center node position as the anchor.
  - Draw a small filled joint-cap circle (added into the same trunk/chain
    `CGMutablePath` via `path.addEllipse(in:)`) at the source position of
    each edge, sized per the approved spec.
  - Keep existing virtualization (visible-rect midpoint test) and
    coalescing behavior unchanged.
- `BetterMail/Sources/UI/Graph/GraphForceSimulator.swift` — extend
  `GraphCurlConfig` (or introduce a sibling `GraphBranchConfig` struct) to
  carry the new branch parameters (`trunkWidth`, `chainWidth`, `taper`,
  `tipMin`, `taperPow`, `asymmetricArc`, `jointRadius`) with the
  Organic-Limb defaults baked in. No new sliders are exposed.
- `Tests/GraphTests.swift` — extend with two deterministic geometry tests
  (ribbon width at endpoints, outward-arc sign).
- `BetterMail/docs/thread-canvas-zstack-components.md` and
  `TechDocs/index.md` — short note that edges are now ribbon-rendered.

**Out of scope**
- Exposing branch parameters in `GraphSettingsSheet`. Existing
  `curl / curlVariability / splineTension / curlFalloff` sliders continue
  to affect the spline centerline.
- Layout/force changes. The radial composition is produced by the
  existing four-force model; only edge *rendering* changes.
- Re-introducing the legacy botanical palette or color shifts along an
  edge.
- Hover/selection emphasis on edges, animated growth, or mobile/iPad.

## User-approved direction

- **Preset:** *Organic Limb* (the third preset in
  [`playgrounds/graph-branch-edges.html`](../playgrounds/graph-branch-edges.html)).
- **Outward arc:** every edge bends away from the canvas center node, so
  the 6+ threads fan radially around the root rather than all curving the
  same direction.
- **Joint:** small filled knob at the source (parent) end of every edge.
- **No new settings.** Hard-code the approved values; existing curl
  sliders already let the user dial the centerline.
- **Dimmed edges:** keep branch styling, drawn into the dimmed-color path
  at the existing dimmed alpha.

### Approved spec values (Organic Limb)

| Parameter | Trunk | Chain |
|---|---|---|
| Base width (pt) | `2.6` | `1.6` |
| Taper (fraction reduction at tip) | `0.6` | `0.6` |
| Tip min width (pt) | `0.5` | `0.5` |
| Taper curve exponent | `1.8` | `1.8` |
| Joint cap radius (pt) | `1.8` | `1.4` |
| Fill alpha (active) | `0.82` × inkTertiary | `0.68` × inkQuaternary |
| Fill alpha (dimmed) | `0.22` × inkTertiary | `0.22` × inkQuaternary |

Shared:
- Arc amount (px): `9`
- Asymmetric (outward) arc: **on**
- Curl variability: `0.35` (keep existing config default if user changed it)
- Spline tension: `0.4` (use existing config; default 0.35 stays close enough)
- Ribbon sample count along centerline: `36` per edge (matches playground)
- Round joins implicit in fill; no stroke needed

## Architecture / data flow

- `GraphScene.renderEdges()` is unchanged in **when** it runs (every
  frame on a 2-frame cadence) and in its visibility culling. Only the
  per-edge geometry builder swaps from `splinePath(...)` →
  `branchRibbonPath(...)` and the source ellipse is appended to the same
  `CGMutablePath`.
- The four edge layers (`trunkEdgeNode`, `chainEdgeNode`,
  `dimmedTrunkEdgeNode`, `dimmedChainEdgeNode`) keep their identities, but
  each one's `fillColor` is now used (currently they only stroke). Stroke
  width on these layers becomes `0`, `strokeColor = .clear`. Their alpha
  multiplier moves from the stroke-alpha argument to the fill color's
  alpha component.
- The anchor for the outward-arc bias is the root center node's current
  simulator position (`simulator.centerNode?.position` — verify the exact
  accessor during implementation; fallback to the scene's known center
  origin if unavailable).
- `GraphCurlConfig` (or new `GraphBranchConfig`) is passed through the
  same channel `forceConfig.curlConfig` is today, so the existing
  configuration plumbing already covers it.

## Reference

- Playground (interactive spec):
  [`docs/playgrounds/graph-branch-edges.html`](../playgrounds/graph-branch-edges.html)
  — load the *Organic Limb* preset to match the approved look.
- Prior redesign plan: [`graph-redesign.md`](graph-redesign.md).

## Milestones

- [ ] **M1: Add outward-arc bias + ribbon geometry helpers (no rendering change yet).**
  - Intent: extend `GraphSpline` with (a) an `anchor:`-aware variant of
    `points(...)` that flips the asymmetric-arc sign so curves bend away
    from the anchor, and (b) a new `ribbonPath(from:to:seed:config:widthStart:widthEnd:tipMin:taperPow:samples:)`
    helper that samples the existing Catmull–Rom spline (matching today's
    cubic interpolation) and returns a closed `CGPath` for a tapered fill.
  - Files: `BetterMail/Sources/UI/Graph/GraphSceneNodes.swift`,
    `BetterMail/Sources/UI/Graph/GraphForceSimulator.swift` (extend
    `GraphCurlConfig` with `asymmetricArc: Bool` defaulting to `false`
    initially so behavior is unchanged at this milestone).
  - Validation: `xcodebuild ... build` succeeds; add a unit test in
    `Tests/GraphTests.swift` that asserts ribbon endpoints match the
    requested widths and that the outward-arc sign returns `+1` when
    midpoint is on the positive-normal side of the anchor.
  - Notes: leave existing `splinePath(...)` call site in `GraphScene`
    untouched; this milestone is pure additions.

- [ ] **M2: Introduce `GraphBranchConfig` with approved Organic-Limb values.**
  - Intent: add a `GraphBranchConfig` struct (in
    `GraphForceSimulator.swift` alongside `GraphCurlConfig`) holding
    `trunkWidth`, `chainWidth`, `taper`, `tipMin`, `taperPow`,
    `jointRadiusTrunk`, `jointRadiusChain`, `asymmetricArc`,
    `outwardArcAnchorEnabled`, and `ribbonSamples`. Expose it via a
    computed `branchConfig: GraphBranchConfig` on whatever holds
    `curlConfig` today, with Organic-Limb defaults hard-coded per the
    spec table above. No settings UI.
  - Files: `BetterMail/Sources/UI/Graph/GraphForceSimulator.swift`.
  - Validation: build succeeds; values match the spec table verbatim.
  - Notes: not yet consumed.

- [ ] **M3: Swap `GraphScene` edge layers from stroked to filled, drawing tapered branches with outward arcs and joint caps.**
  - Intent: in `GraphScene.renderEdges()`, replace
    `edgePath(edge:source:target:)` with a call to the new ribbon helper,
    passing the root center position as the anchor and Organic-Limb
    widths/taper from `forceConfig.branchConfig`. Append a filled circle
    at the source position (using
    `path.addEllipse(in: CGRect(...))`) to the same `CGMutablePath` so
    joint caps are drawn in one pass per layer. Reconfigure
    `configureEdgeLayers()` so each `SKShapeNode` uses `fillColor` (with
    the approved alpha multiplier baked in) and `strokeColor = .clear`,
    `lineWidth = 0`.
  - Files: `BetterMail/Sources/UI/Graph/GraphScene.swift`.
  - Validation:
    - `xcodebuild ... build` succeeds.
    - Visual check: launch the app, scroll the graph; branches visibly
      taper, every branch curves outward from the root, every edge has a
      small knob at its parent end, and dimmed edges still read.
    - Capture a before/after screenshot pair into `/tmp` for review.
  - Notes: keep the visible-rect midpoint culling. Confirm the simulator
    exposes a center-node position; if not, fall back to
    `CGPoint.zero` (canvas origin where the root is pinned).

- [ ] **M4: Verify dimmed/filtered edges, hover, and performance; tidy docs.**
  - Intent: confirm filtered/dimmed branches render at the same alpha
    multiplier they used to (≈ 0.22), hover/selection emphasis on nodes
    still passes through, and frame timing is unchanged on a populated
    inbox. Update `TechDocs/index.md` and
    `BetterMail/docs/thread-canvas-zstack-components.md` with a one-line
    note that edges are now ribbon-rendered with outward-arc bias.
  - Files: docs only unless a regression is found.
  - Validation: full graph test suite (`-only-testing:BetterMailTests/GraphTests`)
    plus a manual scroll/zoom pass on the populated inbox; spot-check
    `Instruments` if anything looks janky.

## Risks

- **SpriteKit fill performance.** Four filled `SKShapeNode` layers, each
  a single batched `CGPath` of many sub-polygons, should match today's
  stroked cost — but `SKShapeNode` fills can be slower for very dense
  paths. Mitigation: keep `ribbonSamples = 36` (already conservative),
  re-evaluate only if frame timing regresses.
- **Centerline mismatch.** The new ribbon helper must sample the *exact
  same* Catmull–Rom curve as today's `splinePath` so the centerline
  doesn't visibly shift. Mitigation: share the cubic-Bezier control-point
  formula between `path(...)` and the new ribbon sampler.
- **Outward bias degenerate cases.** When midpoint coincides with the
  anchor (very short edge, or a node briefly stacked on the center), the
  dot product is ≈ 0 and the sign is arbitrary. Mitigation: fall back to
  the deterministic noise-based sign when the dot magnitude is below a
  small epsilon.
- **Visual regression at high zoom-out.** Tapered tips may disappear at
  very small scales. The `tipMin = 0.5pt` floor mitigates this; verify
  during M3.

## Acceptance criteria

- Trunk and chain edges visibly **taper** from parent → child.
- With multiple threads around the root, branches **fan radially** —
  edges on the left side bend leftward-outward, edges on the right bend
  rightward-outward, etc.
- A small **filled joint cap** is visible at the parent end of every
  edge, sized per spec.
- Theme tokens are unchanged (`inkTertiary` for trunk, `inkQuaternary`
  for chain) and the look matches the *Organic Limb* preset in the
  playground.
- No new sliders or settings sheet additions.
- Filtered/dimmed edges still distinguishable at the existing dimmed
  alpha.
- `xcodebuild` succeeds; `GraphTests` pass; new geometry tests pass.

## Open questions

- None blocking implementation.

