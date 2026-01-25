## Context
- The codebase spans AppleScript ingestion, Core Data storage, JWZ threading, SwiftUI canvas UI, and a MailKit helper extension; naming/access control/actor annotations differ across modules.
- A deprecated thread list artifact (`MessageRowView`) remains in-tree and the user requested broader deprecation cleanup plus repo-wide refactors.
- There is no centralized technical documentation beyond README, making onboarding and future refactors harder.

## Goals / Non-Goals
- Goals: establish consistent API naming and access control, annotate concurrency boundaries, remove or formally gate deprecated surfaces, and add a TechDocs folder that maps architecture and refactor migrations.
- Non-Goals: introduce new product features, change entitlements/targets, alter OS support, or add third-party dependencies.

## Decisions
- Perform an audit-first pass that inventories functions/variables per module with proposed renames, actor isolation, and visibility changes before modifying code.
- Prioritize mechanical, behavior-preserving refactors (renames, access control, explicit actors) and keep changes scoped per module to simplify verification.
- Handle deprecated artifacts with explicit @available annotations or removal accompanied by migration notes so callers can adjust.
- Add `TechDocs/` with stable anchors: architecture overview, module map, dataflow/concurrency, MailKit helper notes, and a deprecation log/migration ledger.

## Risks / Trade-offs
- Risk: regressions from widespread renames; mitigation: module-scoped passes, companion test updates, and migration notes/typealiases where necessary for ABI stability.
- Risk: doc drift; mitigation: tie documentation updates to refactor tasks and add a checklist item in tasks.md.
- Risk: time/scope creep from "entire repo" request; mitigation: prioritize core modules (ingestion, storage, threading, UI, services) and phase lower-risk helpers.

## Migration Plan
- Sequence modules: Support & models → DataSource/Services → Storage/Threading → ViewModels/UI → MailHelperExtension.
- Preserve temporary typealiases or forwarding initializers where needed to avoid breaking call sites during staged renames; remove once call sites are updated.
- Record renamed/removed symbols in the TechDocs migration log and update README/AGENTS pointers to the new docs.

## Open Questions
- Should any legacy UI (e.g., MessageRowView or other unused views) remain behind a compatibility flag, or can they be fully removed?
- Is there an existing style guide for naming beyond Swift API Guidelines (e.g., specific prefixes/suffixes for actors, async functions)?
- Do we need to preserve binary compatibility for any external clients, or can all public symbols be renamed if the app is the only consumer?
