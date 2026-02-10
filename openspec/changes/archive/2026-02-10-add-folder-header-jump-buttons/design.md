## Context
Folder headers already provide summary context, but they do not provide direct navigation to extreme nodes. The canvas currently pages day bands in fixed increments when users scroll near the bottom. A jump action that targets historical extremes can require significantly more day coverage than is currently rendered.

## Goals / Non-Goals
- Goals:
  - Add two folder-header actions that jump to newest/oldest email nodes in that folder.
  - Resolve targets from DataStore data, not from only currently loaded day bands.
  - Prevent UI lag during large-range jumps.
- Non-Goals:
  - Add additional folder-header actions beyond newest/oldest.
  - Change backfill behavior or fetch policy for these jumps.
  - Add text labels to the buttons outside tooltips.

## Decisions
- Decision: Use DataStore date bounds and message IDs as the source of truth for jump targets.
  - Why: Ensures jumps work even when the target is outside the rendered day window.
  - Alternative considered: Use currently rendered layout bounds only. Rejected because it cannot reach unloaded historical nodes.

- Decision: Perform bounded, incremental day-window expansion toward the target day before final scroll.
  - Why: Prevents large one-shot expansion that can block the main thread due to repeated layout/rethread work.
  - Alternative considered: Expand to a very large day window in one step. Rejected due to responsiveness risk.

- Decision: Keep controls icon-only with tooltip labels.
  - Why: Matches requested compact footer affordance and avoids expanding header footprint.

## Risks / Trade-offs
- Risk: Repeated expansion cycles can still be expensive on very large history windows.
  - Mitigation: Use capped step sizes, stop as soon as target day is covered, and expose transient in-progress/disabled states to avoid repeated triggers.

- Risk: Target node may be missing after range expansion if the local cache lacks that message.
  - Mitigation: Define deterministic fallback behavior (scroll to nearest covered day and keep control enabled for retry after cache changes).

## Migration Plan
1. Add UI affordances in folder header footer with tooltips and disabled/loading affordances.
2. Add view-model jump commands that query DataStore-backed first/latest targets for folder scope.
3. Add bounded expansion orchestration and final node-scroll handoff.
4. Validate behavior and responsiveness with large date-range folders.

## Open Questions
- None.
