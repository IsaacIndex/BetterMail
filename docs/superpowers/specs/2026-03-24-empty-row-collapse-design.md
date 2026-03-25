# Empty Date Row Collapse in All Emails View

**Date:** 2026-03-24
**Status:** Approved

## Problem

In the "All Emails" view (dateBucketed mode), date rows with no threads across any folder still render at full height (~120pt), wasting significant vertical space and pushing actual content further apart.

## Solution

Collapse empty date rows to thin 24pt separators while keeping the date label visible. This is a layout-level change in the `dayHeights()` function.

## Design

### Behavior

- Date rows with **zero threads across all visible folders** collapse from ~120pt to **24pt**
- The date label remains visible but naturally renders smaller in the reduced height
- Collapsed rows are static dividers — no click/hover interaction
- Rows with any content render at normal computed height (unchanged)

### Scope

**Changes:**
- `ThreadCanvasViewModel.swift` — `dayHeights()` function: return `collapsedDayHeight` (24pt) when `maxCountsByDay[dayIndex]` is 0

**No changes to:**
- `folderAlignedDense` mode (All Folders view) — has its own dense packing
- `ThreadCanvasView.swift` — already renders based on `day.height`
- Scroll math, virtualization, 7-day block expansion — all derive from day heights
- `populatedDayIndices` — unaffected, backfill still works

### Constants

- `collapsedDayHeight`: 24pt (at 1.0 zoom), scales with zoom factor like other metrics

### Edge Cases

- **All days empty:** All rows collapse to 24pt — correct, shows compact date rail
- **Zoom:** Collapsed height scales proportionally
- **Backfill:** Empty collapsed rows still participate in backfill date range detection

## Implementation

Single-point change in `dayHeights()` (~line 6201-6250 of `ThreadCanvasViewModel.swift`):

```swift
// When a day has 0 messages, use collapsed height instead of default
if count == 0 {
    heights[dayIndex] = collapsedDayHeight
} else {
    heights[dayIndex] = max(metrics.dayHeight, requiredDefaultDayHeight(nodeCount: count, metrics: metrics))
}
```

## Testing

- Verify empty rows render at 24pt height
- Verify rows with content render at normal height
- Verify scrolling and virtualization work correctly with mixed heights
- Verify zoom scaling applies to collapsed height
