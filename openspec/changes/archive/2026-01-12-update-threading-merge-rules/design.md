## Context
Manual overrides currently map individual message keys to a single synthetic thread ID. This collapses JWZ lineage, prevents multi-connector rendering per JWZ sub-thread, and fails to retain a stable set of JWZ thread IDs for future inbound merges.

## Goals / Non-Goals
- Goals:
  - Preserve JWZ as the base threading model while allowing manual merges that attach to JWZ thread sets.
  - Support the four grouping cases with deterministic outcomes.
  - Render separate connector lanes per JWZ sub-thread within a merged group, with dynamic offsets.
  - Allow ungrouping only for manual selections without breaking JWZ membership.
- Non-Goals:
  - Change AppleScript ingestion or MailKit behaviors.
  - Introduce third-party dependencies.

## Decisions
- Decision: Represent manual groups as a stable manual thread ID plus a set of JWZ thread IDs and a set of manually attached message keys.
  - Rationale: Allows future messages from any JWZ sub-thread to rejoin the merged group while still tracking which items were manually attached for ungrouping.
- Decision: Apply manual grouping after JWZ threading, then rebuild thread membership and metadata based on the merged JWZ set.
  - Rationale: Keeps JWZ as the source of truth while enabling manual overrides as a post-processing step.
- Decision: Connector lanes are computed per JWZ sub-thread within the merged group, with dynamic offsets based on zoom and node width.
  - Rationale: Preserves visual separation of natural JWZ threads while keeping layout responsive.

## Alternatives considered
- Alternative: Encode merged JWZ IDs into a composite thread ID string.
  - Rejected because it complicates lookup and makes ungrouping ambiguous.
- Alternative: Only store manual overrides per message without a group record.
  - Rejected because it cannot retain JWZ sets for future merges.

## Risks / Trade-offs
- Risk: Migration complexity from existing manual overrides.
  - Mitigation: On upgrade, create a new manual group per existing merged thread ID and backfill JWZ thread IDs from current membership.
- Risk: Connector density in large merged groups.
  - Mitigation: Clamp lane offsets and reuse existing zoom constraints.

## Migration Plan
1. Introduce new manual group entities and mappings.
2. Migrate existing manual overrides into new group records and delete old overrides.
3. Update threading post-processing to use group records and JWZ set logic.
4. Update canvas connector rendering and selection actions.

## Open Questions
- None.
