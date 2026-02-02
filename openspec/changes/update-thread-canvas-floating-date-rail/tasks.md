## 1. Implementation
- [ ] 1.1 Adjust layout metrics to reserve a fixed left rail area that stays pinned while the canvas scrolls.
- [ ] 1.2 Render floating day/month/year labels in the left rail that remain vertically aligned with day bands.
- [ ] 1.3 Preserve existing zoom readability thresholds (day→month→year) in the rail and ensure they stay in sync with node readability state.
- [ ] 1.4 Verify behaviour in Default and Timeline view modes, including multi-axis scrolling and paging.
- [ ] 1.5 Run `openspec validate update-thread-canvas-floating-date-rail --strict` and build the app to confirm no regressions.
