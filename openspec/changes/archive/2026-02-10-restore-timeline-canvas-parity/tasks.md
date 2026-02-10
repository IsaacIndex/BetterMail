## 1. Implementation
- [x] 1.1 Audit current timeline mode to document dropped behaviors (manual group connectors, folder backgrounds, selection).
- [x] 1.2 Rewire Timeline View to reuse the shared canvas layout/data source used by Default View while keeping timeline overlays.
- [x] 1.3 Validate manual grouping and folder behaviors render identically across modes (connectors, adjacency, drop targets).
- [x] 1.4 Adjust timeline-specific overlays (time labels, tags/summaries) to coexist with the canvas without breaking interactions.
- [x] 1.5 Update/extend view-model tests or snapshot coverage for both view modes ensuring parity.
- [x] 1.6 Run `openspec validate restore-timeline-canvas-parity --strict`.
