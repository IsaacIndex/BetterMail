## Context
The request introduces a new visual language across multiple SwiftUI views. The change spans several UI surfaces and should be applied consistently without duplicating styling code.

## Goals / Non-Goals
- Goals: deliver a cohesive glassmorphism look, keep text legible, respect accessibility settings, avoid new dependencies.
- Non-Goals: redesign layout, add new functionality, or change data behavior.

## Decisions
- Decision: use SwiftUI materials plus subtle gradient/stroke overlays to simulate glass depth while keeping native performance.
- Decision: centralize styling in reusable view modifiers/helpers under the UI layer.
- Decision: honor Reduce Transparency by falling back to solid backgrounds and stronger borders.

## Risks / Trade-offs
- Glass effects can reduce contrast; mitigate with careful opacity, strokes, and fallback colors.

## Migration Plan
- Apply styles incrementally to each surface; no data migration required.

## Open Questions
- None.
