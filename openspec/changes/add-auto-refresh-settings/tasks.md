## 1. Implementation
- [ ] 1.1 Add persisted settings model using `@AppStorage` for auto refresh enabled + interval (default disabled, 300s).
- [ ] 1.2 Add Settings scene UI to edit auto refresh toggle and interval.
- [ ] 1.3 Wire `ThreadSidebarViewModel` to read settings, start/stop auto refresh, and track last/next refresh timestamps.
- [ ] 1.4 Update thread list header to show last updated and next refresh when enabled.
- [ ] 1.5 Validate strings are localizable and refresh timing updates correctly.

## 2. Validation
- [ ] 2.1 Run `openspec validate add-auto-refresh-settings --strict`.
- [ ] 2.2 Manual check: toggle auto refresh, adjust interval, verify last updated/next refresh display.
