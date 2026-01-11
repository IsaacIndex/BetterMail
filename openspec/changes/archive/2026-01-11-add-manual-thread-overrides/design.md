## Context
BetterMail uses JWZ threading to build conversation roots and thread columns. Users need an override mechanism to merge selected messages into a single thread while retaining JWZ as the default and allowing reversibility.

## Goals / Non-Goals
- Goals:
  - Persist manual thread overrides across refreshes.
  - Allow multi-select (Cmd+click) to group or ungroup messages.
  - Distinguish JWZ vs manual thread connectors visually.
- Non-Goals:
  - Creating brand-new thread IDs for manual groups.
  - Editing message metadata or modifying Apple Mail.

## Decisions
- Decision: Persist manual overrides in Core Data as message ID -> target thread ID mapping.
  - Why: aligns with existing storage patterns and supports durable, queryable overrides.
- Decision: Apply overrides after JWZ threading and before summary updates.
  - Why: keeps JWZ canonical while ensuring overrides influence ordering/counts.
- Decision: Use the last clicked node as the target thread for grouping.
  - Why: consistent with macOS selection conventions and minimal UI complexity.

## Alternatives considered
- UserDefaults mapping: simpler but less robust and harder to clean up.
- Sidecar JSON: avoids Core Data changes but adds custom file IO and integrity risks.

## Risks / Trade-offs
- Core Data model change requires a lightweight migration.
- Override conflicts (target thread missing) must be cleaned up to avoid stale state.

## Migration Plan
- Add new `ManualThreadOverride` entity and bump the Core Data model.
- Provide store helpers for create/delete/fetch overrides.
- Apply overrides during background rethread to update thread IDs and metadata.

## Open Questions
- None.
