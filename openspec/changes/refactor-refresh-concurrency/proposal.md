# Change: Refactor refresh concurrency for sidebar

## Why
- Refresh and summary work currently run on the main actor, making the SwiftUI sidebar less responsive and risking stuck `isRefreshing` state.

## What Changes
- Offload thread building and summary generation to detached `.utility` tasks to avoid inheriting `@MainActor`.
- Keep main-actor work limited to UI state updates (roots, unread totals, status, summaries, `isRefreshing`).
- Ensure `isRefreshing` is reset on all paths—including the initial refresh triggered at startup—so manual refreshes are never blocked.

## Impact
- Affected specs: auto-refresh
- Affected code: BetterMail/Sources/ViewModels/ThreadSidebarViewModel.swift
