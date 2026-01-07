## Context
The current UI renders threads in a list. The change replaces that list with a canvas that maps days vertically and threads horizontally while preserving the existing data model, refresh behavior, and top nav bar. A new inspector panel is introduced for selected nodes.

## Goals / Non-Goals
- Goals:
  - Visualize emails as nodes on a 2D canvas with day buckets (vertical) and thread columns (horizontal).
  - Keep the top nav bar intact and add a right-side inspector panel for selected nodes.
  - Support both-axis scrolling and zoom with readable clamps.
  - Use Liquid Glass styling on macOS 26+ for nav and inspector, with solid fallbacks for Reduce Transparency.
- Non-Goals:
  - No changes to threading logic, data ingestion, or persistence.
  - No new dependencies or changes to app signing, bundle IDs, or minimum OS versions.

## Decisions
- Thread columns are derived from JWZ root threads, ordered by most recent activity (latest message date).
- Vertical placement is based on day buckets in the user calendar/time zone; default range is last 7 days.
- Nodes in the same day/thread are stacked with small intra-day offsets to avoid overlap.
- Vertical connectors link consecutive nodes within the same thread column.
- Selection is click-only: selecting a node updates the inspector panel; no inline expansion.
- Zoom scales day height and column width together, clamped for legibility.

## Alternatives Considered
- Grouped list with day sections: simpler but does not communicate cross-thread relationships.
- Timeline-only view: loses explicit thread column structure.
- Free-form graph: more flexible but adds complexity and ambiguity compared to fixed axes.

## Risks / Trade-offs
- Dense days could create overlapping nodes. Mitigation: intra-day offsets, minimum spacing, and zoom controls.
- Performance risks when rendering many nodes. Mitigation: limit to last 7 days, cull offscreen nodes, and avoid complex paths.
- Accessibility complexity on a custom canvas. Mitigation: expose nodes as accessibility elements and day bands as headers.

## Migration Plan
- Add the canvas and inspector views alongside existing UI.
- Replace the list view in `ContentView` with the canvas container while keeping the nav bar.
- Remove list-specific row styling once the new UI is verified.

## Open Questions
- None.
