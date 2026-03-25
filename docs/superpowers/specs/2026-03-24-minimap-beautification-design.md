# Minimap Beautification Design

**Date:** 2026-03-24
**Scope:** Visual refinements to `FolderMinimapSurface` in `ThreadFolderInspectorView.swift` (lines 529-708)
**Goal:** Polish the folder minimap in the right inspector panel with a "Clean Minimal" light-mode aesthetic while preserving all existing functionality.

## Design Decisions

- **Style direction:** Clean Minimal — subtle dot-grid background, delicate tick marks, light and airy
- **Node shape:** All pills (no circle for selected). Selected node distinguished by accent color + size increase
- **Background:** Subtle/translucent — blends into inspector, doesn't draw attention

## Changes

### 1. Background

- Increase corner radius from 10 to 12
- Keep translucent fill (`textBackgroundColor` at 0.18 opacity) and stroke
- Add faint dot-grid pattern behind the graph area: 0.5pt circles at 16pt spacing, secondary color at 0.06 opacity. Draw this first inside the Canvas block so it renders behind edges and nodes.
- Add subtle inner shadow via overlaid blurred stroke: `Color.black.opacity(0.04)`, lineWidth 4, blur radius 2, y-offset 1, masked to the rounded rect

### 2. Nodes (all pills)

**Unselected:**
- Keep current 10x3 rounded rect shape
- Lighten the shadow/halo: reduce from `Color.black.opacity(0.23)` to `Color.black.opacity(0.08)`
- Keep foreground fill at 0.96 opacity
- Keep stroke at secondary 0.45

**Selected:**
- Change from circle (8.5x8.5) to larger pill (12x4)
- Fill with SwiftUI `Color.accentColor` instead of the passed-in `foreground` color (note: this is a departure from using passed-in colors, but accent color is appropriate for selection highlighting)
- Replace dark halo (currently `Color.black.opacity(0.26)`) with accent outer ring: `Color.accentColor.opacity(0.2)`, 2pt outset (16x8 rounded rect behind)
- Keep stroke at secondary 0.55

### 3. Edges

- Add round line cap (`.round` stroke style) for softer line endings
- Keep 1.5pt line width
- Reduce opacity from 0.7 to 0.5

### 4. Viewport Rect

- Add corner radius: 5pt rounded rect instead of sharp rect
- Keep `secondaryForeground` fill at 0.12 opacity (unchanged)
- Reduce `secondaryForeground` stroke opacity from 0.9 to 0.4
- Add outer glow: 3pt spread ring at accent 0.04 opacity (achieved via a second slightly larger rounded rect behind)

### 5. Time Ticks

- Modify existing tick marks (currently 6pt, 0.85 opacity): shorten to 5pt and reduce opacity to 0.3
- Reduce font size from 9 to 8.5
- Reduce text opacity slightly (use secondary at 0.8 instead of 1.0)

### 6. No Changes

- Empty state text
- Click-to-navigate gesture
- Accessibility labels/hints
- Graph padding/layout calculations (`graphRect(in:)`, `normalizedPoint(_:in:)` helpers)
- Data models or ViewModel logic

## File Impact

| File | Change |
|------|--------|
| `BetterMail/Sources/UI/ThreadFolderInspectorView.swift` | Modify `FolderMinimapSurface.body` Canvas rendering (lines ~544-630) |

No new files. No API changes. No data model changes.

## Testing

- Visual verification only — build and inspect the minimap in the running app
- Existing unit tests in `ThreadCanvasLayoutTests` should continue to pass (they test data/layout, not rendering)
