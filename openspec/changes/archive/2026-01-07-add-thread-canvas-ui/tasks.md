## 1. Implementation
- [x] 1.1 Define layout metrics (day height, column width, spacing, zoom clamps) and date bucketing helpers for last-7-day range.
- [x] 1.2 Add view model helpers for thread column ordering (latest activity) and per-node canvas positions.
- [x] 1.3 Build the thread canvas view with day bands, thread columns, and node rendering (sender, subject, time).
- [x] 1.4 Render vertical connectors between consecutive nodes in each thread column.
- [x] 1.5 Implement two-axis scrolling and zoom gestures, with clamped zoom and state persistence during selection.
- [x] 1.6 Introduce a right-side inspector panel that updates on node selection.
- [x] 1.7 Keep the existing top nav bar and integrate it with the new canvas container layout.
- [x] 1.8 Apply Liquid Glass styling to nav and inspector on macOS 26+, with solid fallbacks for Reduce Transparency.
- [x] 1.9 Add accessibility labels for nodes and day headers; ensure localization-ready strings for new UI text.
- [x] 1.10 Add unit tests for date bucketing, column ordering, and selection mapping helpers.

## 2. Validation
- [x] 2.1 Run `openspec validate add-thread-canvas-ui --strict`.
- [x] 2.2 Run relevant unit tests (Xcode or `xcodebuild test -scheme BetterMail -destination 'platform=macOS'`).
