## 1. Implementation
- [x] 1.1 Add a persisted canvas view-mode setting (Default vs Timeline) in `ThreadCanvasDisplaySettings`.
- [x] 1.2 Expose a toggle control in `navigationBarOverlay` to switch view modes and reflect the current state.
- [x] 1.3 Render node title lines as summaries when Timeline View is active, with subject fallback when no summary text is available.
- [ ] 1.4 Smoke-test the view toggle manually and ensure `openspec validate add-timeline-view-toggle --strict` passes.
