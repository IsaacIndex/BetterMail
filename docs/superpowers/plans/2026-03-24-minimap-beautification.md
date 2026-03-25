# Minimap Beautification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Polish the folder minimap's visual presentation with a Clean Minimal aesthetic — dot-grid background, softer edges, refined nodes, and delicate time ticks.

**Architecture:** All changes are confined to the `FolderMinimapSurface` view's Canvas rendering closure and its background shape in `ThreadFolderInspectorView.swift`. No data model, layout calculation, or API changes.

**Tech Stack:** SwiftUI Canvas API, Path, RoundedRectangle, StrokeStyle

**Spec:** `docs/superpowers/specs/2026-03-24-minimap-beautification-design.md`

---

### Task 1: Update background shape and add inner shadow

**Files:**
- Modify: `BetterMail/Sources/UI/ThreadFolderInspectorView.swift:547-552`

- [ ] **Step 1: Update corner radius and add inner shadow overlay**

Change the background `RoundedRectangle` from corner radius 10 to 12, and add an inner shadow overlay after the existing stroke overlay:

```swift
RoundedRectangle(cornerRadius: 12, style: .continuous)
    .fill(Color(nsColor: .textBackgroundColor).opacity(0.18))
    .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.25))
    )
    .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.black.opacity(0.04), lineWidth: 4)
            .blur(radius: 2)
            .offset(y: 1)
            .mask(RoundedRectangle(cornerRadius: 12, style: .continuous))
    )
```

- [ ] **Step 2: Build and verify**

Run:
```bash
xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build > /tmp/xcodebuild.log 2>&1 && grep -n "error:" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add BetterMail/Sources/UI/ThreadFolderInspectorView.swift
git commit -m "style: update minimap background corner radius and add inner shadow"
```

---

### Task 2: Add dot-grid pattern to Canvas

**Files:**
- Modify: `BetterMail/Sources/UI/ThreadFolderInspectorView.swift:555-559` (start of Canvas closure, before edge drawing)

- [ ] **Step 1: Draw dot-grid as first Canvas operation**

Insert immediately after `let graphFrame = graphRect(in: size)` and before the `pointsByID` dictionary construction:

```swift
// Dot-grid background
let gridSpacing: CGFloat = 16
let dotRadius: CGFloat = 0.5
for gridX in stride(from: graphFrame.minX, through: graphFrame.maxX, by: gridSpacing) {
    for gridY in stride(from: graphFrame.minY, through: graphFrame.maxY, by: gridSpacing) {
        let dotRect = CGRect(x: gridX - dotRadius, y: gridY - dotRadius,
                             width: dotRadius * 2, height: dotRadius * 2)
        context.fill(Path(ellipseIn: dotRect),
                     with: .color(secondaryForeground.opacity(0.06)))
    }
}
```

- [ ] **Step 2: Build and verify**

Run:
```bash
xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build > /tmp/xcodebuild.log 2>&1 && grep -n "error:" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add BetterMail/Sources/UI/ThreadFolderInspectorView.swift
git commit -m "style: add dot-grid background pattern to minimap"
```

---

### Task 3: Soften edges

**Files:**
- Modify: `BetterMail/Sources/UI/ThreadFolderInspectorView.swift:569-571` (edge stroke call)

- [ ] **Step 1: Add round line cap and reduce opacity**

Replace the edge stroke call:

```swift
// Before:
context.stroke(path,
               with: .color(secondaryForeground.opacity(0.7)),
               lineWidth: 1.5)

// After:
context.stroke(path,
               with: .color(secondaryForeground.opacity(0.5)),
               style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
```

- [ ] **Step 2: Build and verify**

Run:
```bash
xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build > /tmp/xcodebuild.log 2>&1 && grep -n "error:" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add BetterMail/Sources/UI/ThreadFolderInspectorView.swift
git commit -m "style: soften minimap edges with round caps and lower opacity"
```

---

### Task 4: Refine viewport rect

**Files:**
- Modify: `BetterMail/Sources/UI/ThreadFolderInspectorView.swift:574-581` (viewport drawing)

- [ ] **Step 1: Add corner radius, outer glow, and reduce stroke opacity**

Replace the viewport drawing block:

```swift
// Before:
if let viewportRect {
    let viewportDrawRect = rect(for: viewportRect, in: graphFrame)
    context.fill(Path(viewportDrawRect),
                 with: .color(secondaryForeground.opacity(0.12)))
    context.stroke(Path(viewportDrawRect),
                   with: .color(secondaryForeground.opacity(0.9)),
                   lineWidth: 1)
}

// After:
if let viewportRect {
    let viewportDrawRect = rect(for: viewportRect, in: graphFrame)
    let cornerRadius: CGFloat = 5

    // Outer glow ring
    let glowRect = viewportDrawRect.insetBy(dx: -3, dy: -3)
    context.fill(Path(roundedRect: glowRect, cornerRadius: cornerRadius + 3),
                 with: .color(secondaryForeground.opacity(0.04)))

    // Fill
    context.fill(Path(roundedRect: viewportDrawRect, cornerRadius: cornerRadius),
                 with: .color(secondaryForeground.opacity(0.12)))

    // Stroke
    context.stroke(Path(roundedRect: viewportDrawRect, cornerRadius: cornerRadius),
                   with: .color(secondaryForeground.opacity(0.4)),
                   lineWidth: 1)
}
```

- [ ] **Step 2: Build and verify**

Run:
```bash
xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build > /tmp/xcodebuild.log 2>&1 && grep -n "error:" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add BetterMail/Sources/UI/ThreadFolderInspectorView.swift
git commit -m "style: refine minimap viewport rect with rounded corners and glow"
```

---

### Task 5: Update node rendering (all pills)

**Files:**
- Modify: `BetterMail/Sources/UI/ThreadFolderInspectorView.swift:583-608` (node drawing loop)

- [ ] **Step 1: Replace selected node circle with accent pill, lighten unselected halo**

Replace the entire node drawing block (the `for node in model.nodes` loop body):

```swift
for node in model.nodes {
    let center = point(for: node, in: graphFrame)
    let isSelected = node.id == selectedNodeID

    if isSelected {
        // Accent outer ring (pill shape, 2pt outset)
        let haloRect = CGRect(x: center.x - 8, y: center.y - 4, width: 16, height: 8)
        context.fill(Path(roundedRect: haloRect, cornerRadius: 4),
                     with: .color(Color.accentColor.opacity(0.2)))

        // Selected pill: 12x4
        let markerRect = CGRect(x: center.x - 6, y: center.y - 2, width: 12, height: 4)
        context.fill(Path(roundedRect: markerRect, cornerRadius: 2),
                     with: .color(Color.accentColor))
        context.stroke(Path(roundedRect: markerRect, cornerRadius: 2),
                       with: .color(secondaryForeground.opacity(0.55)),
                       lineWidth: 0.8)
    } else {
        // Lightened halo
        let haloRect = CGRect(x: center.x - 6.5, y: center.y - 3.5, width: 13, height: 7)
        context.fill(Path(roundedRect: haloRect, cornerRadius: 3.5),
                     with: .color(Color.black.opacity(0.08)))

        // Unselected pill: 10x3 (unchanged shape)
        let tickRect = CGRect(x: center.x - 5, y: center.y - 1.5, width: 10, height: 3)
        context.fill(Path(roundedRect: tickRect, cornerRadius: 1.5),
                     with: .color(foreground.opacity(0.96)))
        context.stroke(Path(roundedRect: tickRect, cornerRadius: 1.5),
                       with: .color(secondaryForeground.opacity(0.45)),
                       lineWidth: 0.8)
    }
}
```

- [ ] **Step 2: Build and verify**

Run:
```bash
xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build > /tmp/xcodebuild.log 2>&1 && grep -n "error:" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add BetterMail/Sources/UI/ThreadFolderInspectorView.swift
git commit -m "style: update minimap nodes to all-pill shape with accent selection"
```

---

### Task 6: Refine time ticks

**Files:**
- Modify: `BetterMail/Sources/UI/ThreadFolderInspectorView.swift:611-629` (time tick drawing)

- [ ] **Step 1: Shorten tick marks, reduce opacities, reduce font size**

Replace the time tick drawing block:

```swift
for tick in model.timeTicks {
    let tickY = graphFrame.minY + (tick.normalizedY * graphFrame.height)

    // Shortened tick mark: 5pt instead of 6pt, reduced opacity
    var tickPath = Path()
    tickPath.move(to: CGPoint(x: graphFrame.maxX + 3, y: tickY))
    tickPath.addLine(to: CGPoint(x: graphFrame.maxX + 8, y: tickY))
    context.stroke(tickPath,
                   with: .color(secondaryForeground.opacity(0.3)),
                   lineWidth: 1)

    // Smaller font, slightly reduced opacity
    let text = Self.timeFormatter.string(from: tick.date)
    let resolved = context.resolve(
        Text(text)
            .font(.system(size: 8.5 * textScale, weight: .medium))
            .foregroundStyle(secondaryForeground.opacity(0.8))
    )
    context.draw(resolved,
                 at: CGPoint(x: graphFrame.maxX + 10, y: tickY),
                 anchor: .leading)
}
```

- [ ] **Step 2: Build and verify**

Run:
```bash
xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build > /tmp/xcodebuild.log 2>&1 && grep -n "error:" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add BetterMail/Sources/UI/ThreadFolderInspectorView.swift
git commit -m "style: refine minimap time tick marks and labels"
```

---

### Task 7: Run existing tests

**Files:**
- Test: `Tests/ThreadCanvasLayoutTests.swift`

- [ ] **Step 1: Run tests to confirm no regressions**

Run:
```bash
xcodebuild test -project BetterMail.xcodeproj -scheme BetterMail -destination 'platform=macOS' -only-testing:BetterMailTests/ThreadCanvasLayoutTests > /tmp/xcodebuild-test.log 2>&1 && tail -n 20 /tmp/xcodebuild-test.log
```
Expected: All tests pass

- [ ] **Step 2: Visual verification**

Launch the app and inspect the minimap in the folder inspector panel. Verify:
- Dot-grid background is visible but subtle
- Unselected nodes are pills with light halos
- Selected node is an accent-colored larger pill with outer ring
- Edges have rounded ends and are softer
- Viewport rect has rounded corners and faint glow
- Time tick marks are shorter and labels are lighter
