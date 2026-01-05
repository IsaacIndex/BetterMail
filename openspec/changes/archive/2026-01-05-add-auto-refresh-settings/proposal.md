# Change: Add auto refresh settings and timing status

## Why
Auto refresh is currently hard-coded, so users cannot control whether it runs or how often. We also do not surface the last or next refresh timing in the UI.

## What Changes
- Add persisted auto refresh settings (enabled toggle, interval) with defaults of disabled and 5 minutes.
- Add a Settings window that lets users enable auto refresh and set the refresh interval.
- Surface last updated time and next scheduled refresh time in the thread list header.

## Impact
- Affected specs: auto-refresh
- Affected code: settings scene and storage, `BetterMail/Sources/ViewModels/ThreadSidebarViewModel.swift`, `BetterMail/Sources/UI/ThreadListView.swift`, app entry point for Settings scene
