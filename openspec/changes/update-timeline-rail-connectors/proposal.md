# Change: Make timeline rail connectors flush with dots

## Why
Timeline View currently shows small gaps between the vertical rail connectors and the entry dots, making the rail look visually broken and misaligned.

## What Changes
- Align the timeline rail so the vertical connector touches each entry dot at both the top and bottom with no visible gap.
- Preserve existing timeline entry layout (dot + time + tags + summary) and inspector selection behavior.
- Adjust spacing only as needed to achieve the visual alignment across variable entry heights.

## Impact
- Affected specs: thread-canvas (timeline rail alignment).
- Affected code: Timeline View rail/dot layout and drawing (e.g., timeline row view/renderer and spacing constants).
