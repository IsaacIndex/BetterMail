## 1. Investigation
- [-] 1.1 Profile Timeline View scroll + zoom with Instruments/Time Profiler to identify main-thread hot spots (layout recompute, text measurement, geometry updates).

## 2. Implementation
- [x] 2.1 Introduce cached timeline layout keyed by zoom/view mode/day window/node set so scroll offset changes reuse frames instead of rebuilding.
- [x] 2.2 Reuse timeline text measurement assets (fonts, paragraph styles, bounding boxes) and cap tag measurement work to a small visible set.
- [x] 2.3 Throttle visible-range updates from GeometryReader to avoid per-pixel refresh; ensure paging still triggers correctly.

## 3. Validation
- [x] 3.1 Manual check Timeline View with ~50–200 entries: smooth scroll/pinch without blanking; note before/after fps or frame budget.
- [x] 3.2 Run `openspec validate improve-timeline-responsiveness --strict`.
