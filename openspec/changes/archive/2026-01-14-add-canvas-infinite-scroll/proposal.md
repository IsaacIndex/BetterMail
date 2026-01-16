# Change: Add cache-only infinite scroll with visible-range backfill

## Why
The thread canvas currently defaults to a fixed 7-day window, which limits exploration of older mail. Users need to scroll further back while keeping AppleScript fetches bounded and performance predictable.

## What Changes
- Expand the thread canvas to support cache-only paging beyond the default 7-day window.
- Add a toolbar backfill action that fetches missing messages for the currently visible day bands only.
- Update the canvas range behavior to keep AppleScript activity user-initiated and scoped to visible empty bands.

## Impact
- Affected specs: thread-canvas
- Affected code: Sources/UI/ThreadCanvasView.swift, Sources/UI/ThreadCanvasLayout.swift, Sources/ViewModels/ThreadCanvasViewModel.swift, Sources/DataSource/MailAppleScriptClient.swift, Sources/Storage/MessageStore.swift
