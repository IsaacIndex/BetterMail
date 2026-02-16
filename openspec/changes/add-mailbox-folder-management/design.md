## Context
- The current app UI is canvas-first and no longer includes a mailbox/sidebar navigation surface.
- Message records already contain `mailboxID` and `accountName`, but refresh/backfill paths still assume inbox-style scope in multiple places.
- Existing "Add to Folder" behavior applies to BetterMail thread folders (canvas grouping), not Apple Mail mailbox folders.
- `MailControl` already contains mailbox reference helpers and a `moveSelection` command tied to Mail.app's current selection, which is insufficient for deterministic moves from BetterMail node selections.

## Goals / Non-Goals
- Goals:
  - Keep **All Inboxes** as default while enabling account/folder drill-down.
  - Show Apple Mail account/folder hierarchy (including nested folders) in BetterMail UI.
  - Move selected canvas messages to existing Apple Mail folders.
  - Support creating a new Apple Mail folder under a user-chosen parent and moving selected messages into it.
  - Reduce ambiguity between thread folders and mailbox folders.
- Non-Goals:
  - Replacing/removing existing thread-folder features.
  - Reworking JWZ/manual threading semantics.
  - Introducing cross-provider sync beyond Apple Mail APIs already in use.

## Decisions
- Decision: Introduce explicit mailbox scope state in the view model (`All Inboxes` default, or a concrete account/folder target).
  - Why: Scope must drive data fetch/rethread behavior while preserving current default experience.

- Decision: Introduce a dedicated mailbox hierarchy model (account + folder path + children) populated from Apple Mail.
  - Why: Nested folders require structured tree semantics, not flat mailbox strings.

- Decision: Keep mailbox hierarchy fetch and selection lightweight; resolve source-of-truth from Apple Mail and refresh hierarchy after move/create actions.
  - Why: Avoid stale navigation state after folder mutations.

- Decision: Implement mailbox-folder move by resolving selected BetterMail node message IDs, not Mail.app selection.
  - Why: User intent originates in BetterMail selection; depending on external Mail selection is non-deterministic.

- Decision: Gate move/create flows to single-account selections in the initial version.
  - Why: Keeps behavior predictable in an `All Inboxes` context and avoids implicit cross-account moves.

## Risks / Trade-offs
- AppleScript mailbox tree parsing can vary by account/provider naming conventions.
  - Mitigation: Normalize mailbox paths and include parser-focused unit tests.
- Message-ID-based move resolution can fail when Mail metadata is inconsistent.
  - Mitigation: surface per-action failure states and keep actions retryable.
- Adding sidebar + move UI increases surface complexity.
  - Mitigation: keep default selection on All Inboxes, maintain existing canvas actions, and use explicit labels for mailbox vs thread folders.

## Migration Plan
1. Add mailbox hierarchy/domain types and AppleScript readers.
2. Add mailbox scope state + scoped fetch wiring in view model/store paths.
3. Add UI sidebar tree and selection bindings.
4. Add move-to-mailbox-folder and create-mailbox-folder action flows.
5. Refresh hierarchy/scope after mutations and validate by tests/build.

## Open Questions
- None blocking for proposal. Mixed-account selection is intentionally constrained for initial delivery and can be expanded in a follow-up change.
