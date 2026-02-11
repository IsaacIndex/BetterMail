## Context
Folder selection opens `ThreadFolderInspectorView`, which today uses a single scrollable content region for editable fields (name, color, summary, preview). The canvas already supports folder jump actions and incremental day-window expansion through existing view-model jump orchestration.

The requested feature adds an always-visible minimap to folder details that supports direct navigation from minimap clicks into the folder's canvas region.

## Goals / Non-Goals
- Goals:
  - Provide a minimal visual structure of folder nodes using circles and lines only.
  - Keep minimap visible in a dedicated non-scrollable section of the folder inspector.
  - Map minimap clicks to canvas navigation inside the selected folder scope.
  - Favor stable behavior over perfect geometric precision.
- Non-Goals:
  - Add rich graph styling, labels, thumbnails, or per-node metadata inside minimap.
  - Replace the existing canvas as the primary exploration surface.
  - Introduce cross-folder navigation from the minimap.

## Decisions
- Decision: Minimap rendering stays primitive-only (circles + connector lines).
  - Why: Meets the requested “simplest form,” keeps rendering cheap, and avoids legibility issues in small inspector areas.

- Decision: Inspector layout splits into fixed minimap section + independently scrollable edit section.
  - Why: Satisfies “different section that is not scrollable” while preserving existing editable controls.

- Decision: Click navigation is folder-scoped and stability-first.
  - Why: User requested either coordinate jump or nearest-node fallback depending on stability.
  - Mapping policy:
    - Prefer deterministic coordinate mapping when a valid in-folder target can be resolved.
    - If the click cannot be mapped reliably, fall back to nearest in-folder node.
    - Never navigate outside the selected folder scope.

- Decision: Reuse existing folder jump orchestration for expansion/scroll dispatch where possible.
  - Why: Existing jump path already handles off-range dates, incremental expansion, and pending-scroll consumption.

## Alternatives Considered
- Alternative: Always jump to nearest node (ignore clicked position).
  - Rejected because it reduces spatial predictability and does not honor position intent when mapping is stable.

- Alternative: Build a fully custom coordinate transform tied 1:1 to current zoom and viewport state.
  - Rejected because it is brittle and likely to regress with layout/readability mode changes.

## Risks / Trade-offs
- Risk: Coordinate mapping drift when layout metrics or visibility windows change.
  - Mitigation: Keep mapping deterministic and folder-local; explicitly define nearest-node fallback.

- Risk: Inspector space pressure on small window sizes.
  - Mitigation: Cap minimap height and keep edit controls in a separate scroll view.

- Trade-off: Simplicity over detail in minimap visualization.
  - Benefit: Better responsiveness and lower implementation complexity.

## Migration Plan
1. Add minimap section contract to folder-details spec.
2. Add folder-scoped minimap jump contract to canvas spec.
3. Implement inspector layout split and minimap component.
4. Wire click mapping into existing jump request flow.
5. Validate with unit/UI checks and build.

## Open Questions
- None. The fallback rule is explicitly defined as “nearest in-folder node when coordinate mapping is unstable/unavailable.”
