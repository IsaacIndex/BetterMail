## 1. Implementation
- [x] 1.1 Adjust layout metrics to reserve a fixed left rail area that stays pinned while the canvas scrolls.
- [x] 1.2 Render floating day/month/year labels in the left rail that remain vertically aligned with day bands.
- [x] 1.3 Preserve existing zoom readability thresholds (day→month→year) in the rail and ensure they stay in sync with node readability state.
- [x] 1.4 Verify behaviour in Default and Timeline view modes, including multi-axis scrolling and paging.
- [x] 1.5 Run `openspec validate update-thread-canvas-floating-date-rail --strict` and build the app to confirm no regressions.
