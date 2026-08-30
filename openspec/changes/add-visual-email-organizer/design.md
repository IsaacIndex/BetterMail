## Context
The mounted graph path is `GraphCanvasView` -> `GraphRepresentable` -> `ObsidianGraphScene`. It supports a stable visual hierarchy, confirmed Group drop targets, suggestion review, paging, and additive selection, but scene interaction still drags one node at a time and layout state is in memory only. The legacy `GraphScene` path remains compiled but is not the product surface for this work.

`ThreadCanvasViewModel` owns canonical mailbox scope, threaded roots, search, selection, and manual Group operations. `GraphCanvasViewModel` owns the graph projection and mixes presentation with Archive and Snip behavior. `GraphAutomationCoordinator` owns proposal policy, persistence orchestration, and optional post-commit Mail movement. `MessageStore` provides the serialized Core Data organization context but the product has no single durable operation lifecycle spanning BetterMail state and external Apple Mail work.

This design keeps the proven renderers and data models, then adds narrow boundaries around them. It does not attempt a graph rewrite.

## Goals / Non-Goals
- Goals:
  - Make search -> select -> organize -> verify -> undo the shortest and most discoverable path.
  - Preserve a calm, readable hierarchy and spatial memory across refreshes and relaunches.
  - Make every organization effect predictable before confirmation and recoverable afterward.
  - Keep core manual organization usable when AI/Foundation Models are unavailable.
  - Make every success target measurable with reproducible evidence.
- Non-Goals:
  - Replace the Default or Timeline presentations.
  - Add decorative continuous motion, more force presets, or new graph styling systems.
  - Add third-party dependencies or a new persistence framework.
  - Treat Apple Mail and Core Data as one impossible atomic transaction.
  - Treat the JSON operation ledger and Core Data as one impossible atomic
    transaction; crash consistency is provided by write-ahead state and
    idempotent recovery instead.
  - Automatically create Apple Mail mailboxes/rules or move/restore physical messages without explicit consent.

## Decisions

### Decision 1: Turn the existing Graph presentation into the Organize workspace
The user-facing mode label becomes **Organize**, but the stored `.graph` value remains unchanged. When that mode is active, `ThreadListView` hosts an `OrganizerWorkspaceView` containing a collapsible `UnorganizedRail` and the active `GraphCanvasView`. Default and Timeline remain peer modes.

The rail is a stable scanning and accessibility surface; the graph remains the spatial organization surface. Both share mailbox scope, search, effective-thread identity, and selection. A narrow window collapses the rail before covering the canvas or existing inspectors.

An item is Unorganized when its visible effective BetterMail thread is not a member of any confirmed `ThreadFolder` and is not in Graph Archive. Apple Mail mailbox location and unconfirmed suggestions do not change that classification.

### Decision 2: Use one explicit organizer selection model
Add a pure `OrganizerSelectionController` that maps rail rows and graph nodes to deduplicated effective conversation IDs while preserving the existing `ThreadCanvasViewModel` selection as the application authority. The controller owns the range anchor, lasso result, focus order, and graph-to-thread normalization; it does not persist mail state.

Interaction rules:
- Cmd-click toggles one selectable conversation.
- Shift-click extends from the range anchor in deterministic visible order.
- Shift-drag on blank canvas starts a world-coordinate lasso; the visible **Select Area** mode arms that same lasso without requiring Shift. Command makes either path additive, node-origin drag remains direct manipulation, and an unmodified blank drag outside Select Area continues to pan.
- A click is committed on mouse-up only after the drag threshold resolves the click/drag ambiguity.
- Selection is visible in the rail, canvas, inspector, and shared action bar.
- Keyboard and VoiceOver paths expose the same selection and organization actions.

### Decision 3: Make batch grouping a deliberate, atomic BetterMail action
Dragging any selected conversation carries the deduplicated selected batch while preserving relative visual offsets. Confirmed Groups are eligible targets; ghost/suggested Groups and virtual remainder nodes are not.

- Drop on a confirmed Group highlights exactly one target and performs one BetterMail batch membership transaction.
- A Group's optional Apple Mail mailbox mapping does not turn a drop into a physical Mail move. That external effect is a separate, explicitly authorized command.
- Drop a selection of two or more conversations on empty canvas to open an inline, accessible Group-name composer at that location. A valid name creates one confirmed `ThreadFolder` and assigns the batch in the atomic BetterMail phase. The prepared ledger also stores an opaque anchor intent; the separate spatial store writes an anchor receipt afterward and replays a missing receipt after relaunch.
- Drop one conversation on empty canvas only repositions it.
- Removing membership remains an explicit **Remove from Group** action so an imprecise empty-canvas drop cannot silently ungroup mail.
- A cancelled or invalid drop causes no membership mutation.

Rail rows may initiate the same batch drag payload, but all mutations route through the organizer command boundary rather than SwiftUI or SpriteKit callbacks writing state directly.

### Decision 4: Persist spatial state separately from semantic organization
Add a `GraphSpatialStateStore` actor backed by a versioned JSON file in Application Support. Use Codable, Sendable value models and atomic file replacement. The store is protocol-backed so tests can use an in-memory/file-accessor double.

Each scope stores stable node positions, confirmed Group anchors, zoom, pan, schema version, and last-updated time. Scope and node keys are opaque HMAC tokens derived from stable internal identifiers with a per-install secret held in the Keychain; raw subject, sender, body, snippet, account name, mailbox path, and message identifier are never stored in this file. If the secret is unavailable, BetterMail resets only unreadable spatial state to the seeded layout rather than writing raw identifiers.

Writes are debounced/coalesced and occur after settled drag or viewport changes rather than every render callback. Stable hidden/paged IDs are retained; virtual remainder IDs are never persisted; genuinely deleted source and Group IDs are pruned. Missing, corrupt, or future-version state falls back to the deterministic seeded layout. Reset Layout clears the active scope only.

### Decision 5: Use one effect model and a separately authorized Mail gateway
Every command declares one of these visible effects before execution:
- **BetterMail only**: Group membership, Graph Archive, spatial layout, suggestion review state.
- **Changes Apple Mail**: Snip, physical Move, mapped automation move, restore, or mailbox creation.
- **Mixed**: a BetterMail organization delta followed by explicitly authorized Apple Mail work.

Add an `OrganizationMailGateway` around every production mailbox creation, message move, and restore call. It requires an `OrganizationMailAuthorization` value created only by a user-confirmation path showing affected message count, source account/mailbox routes, destination, and reversibility. A provider recommendation, automatic-mode flag, Group drop, queue refresh, or app-only approval cannot manufacture authorization. The implementation begins with an exhaustive call-site inventory covering `GraphCanvasViewModel`, `ThreadCanvasViewModel`, `GraphAutomationCoordinator`, `MailControl`, `MailAppleScriptClient`, and direct test seams; any direct mutation outside the gateway fails the authorization matrix.

Persist Mail-automation consent separately from the existing automation mode and mailbox-mapping setting as `{schemaVersion, enabled, grantedAt, allowedEffects}`. Absence, an unknown version, or a revoked value means no automatic Mail mutation. On upgrade, existing automatic organization may continue applying BetterMail-only changes, but legacy automatic/mapping values do not create consent; Mail mutation remains disabled until the user grants the current consent version. New users start in Review mode with Mail mutation off. Revocation blocks new work and prepared-but-not-started Mail phases; already-running external calls complete into a receipt/recovery state and are never repeated implicitly. The setting and current effect are always visible at startup and proposal evaluation.

### Decision 6: Record every organization operation durably
Add a durable `OrganizationOperation` ledger with an operation ID, kind, opaque source/target fingerprints, BetterMail before/after delta, encrypted exact Mail-route envelopes where applicable, authorization metadata, optional spatial-anchor intent/receipt, timestamps, retry/error metadata, and lifecycle phase:

`prepared -> appApplied -> layoutPending | mailApplying -> completed | partial | recovery -> undone`

The serialized organization command uses a crash-consistent write-ahead
protocol across the separate JSON ledger and Core Data stores: first persist a
`prepared` operation, then commit one atomic BetterMail delta, then advance the
ledger to `appApplied` or its next required phase. A failure before the Core Data
commit leaves a prepared/recovery marker with no membership mutation. A failure
after the Core Data commit is detected by the stored fingerprints and resumes
without applying the same delta twice. No cross-store atomicity is claimed.
Spatial-anchor and external Mail work then advance the ledger with receipts and
compensation results. A missing spatial receipt is replayable and does not roll
back valid semantic Group membership. Relaunch resumes or surfaces incomplete
work; it cannot interpret `appApplied` as fully completed while required layout
or Mail work remains.

The history UI projects legacy Graph Archive, Snip, and Graph Automation records through adapters during migration, then includes manual Group/ungroup, suggestion acceptance, folder moves, and mapped Mail moves. Conditional undo verifies current fingerprints and preserves later unrelated user edits. Dismiss hides a row without deleting its recovery record.

Mailbox creation plus move uses this lifecycle through the same authorization-gated gateway. The preview states that mailbox creation may be irreversible even if the subsequent message move fails. Failure leaves a visible recovery record rather than an apparent all-or-nothing success.

Exact Mail routes are encrypted at rest with a CryptoKit key held in the Keychain and are accessible only through the operation store/gateway for execution, undo, and recovery. They never enter telemetry, OSLog public fields, suggestion prompts, or shareable exports. If the route-encryption key is unavailable, the operation fails closed into `recoveryKeyUnavailable`: BetterMail preserves the encrypted envelope byte-for-byte, does not create a replacement key for that envelope, does not execute/repeat Mail work, and does not mark the operation complete. Recovery may resume only if the original key becomes available; explicit deletion requires a warning that Mail recovery will be lost. Completed/undone terminal records retain encrypted routes for 30 days and are then redacted to aggregate effect/status data; unresolved or quarantined records retain the minimum encrypted recovery envelope until resolution or explicit user deletion with that warning. Schema-versioned migration redacts terminal legacy payloads and quarantines malformed or unsafe active payloads.

Queue-wide Approve All means every pending proposal at invocation time. The confirmation separates BetterMail-only counts from Mail-changing counts. Duplicate-source proposals are resolved or presented as conflicts; they are never silently skipped.

### Decision 7: Put suggestions inside the organization loop
Use a compact inline suggestion card/rail state that shows proposed Group name, why it was suggested, confidence/provenance, complete affected-member count, current and proposed destinations, last-evaluated time, and effect badge. The existing detailed review sheet remains the member-editing surface.

Approve, edit, reject, Not this Group, Hide this topic, retry, recovery, and undo use the same vocabulary in ghost suggestions and Graph Automation. No suggestion mutates membership before its required review/consent state. When Foundation Models are unavailable, the manual organizer remains fully functional and the UI explains that suggestions are unavailable; deterministic heuristics may be offered only as visibly labeled review-only candidates.

Raw semantic input remains local and ephemeral wherever possible. Organizer telemetry never records it. Persisted proposal evidence is minimized to the data needed for user review and stale-source validation, and existing raw proposal payloads receive a migration/quarantine path rather than being silently discarded.

### Decision 8: Make controls task-first and move tuning under Advanced
Primary controls are search/filter, Unorganized visibility/count, selected count, Create/Add Group, Move, Archive, and Undo/History. Paging, display toggles, force tuning, and diagnostic visualization move under a single **Advanced** disclosure while retaining their existing setting keys and behavior.

### Decision 9: Extract seams incrementally
Introduce these narrow units in dependency order:
1. `OrganizerProjection` for pure scoped Unorganized/grouped/suggested derivation.
2. `OrganizerSelectionController` for effective-ID selection semantics.
3. `OrganizationOperationStore` plus ledger schema/migration.
4. `OrganizationMutationStore` facade over the existing serialized `MessageStore` transaction context.
5. `OrganizationCommandService` for ledger-backed batch commands.
6. `GraphSpatialStateStore` for scoped layout persistence and anchor receipts.
7. `OrganizationMailGateway` for authorization-gated mailbox creation, exact-route move, and restore effects.
8. `OrganizationHistoryCoordinator` for the unified history projection.
9. Pure `OrganizationSourceSnapshotBuilder` and `PlacementPolicy`/`SuggestionRanker` extracted from automation orchestration.
10. `OrganizerMetricsRecorder` for local aggregate benchmarks.

`ThreadCanvasViewModel` remains the mailbox/thread source and schedules refresh. `GraphCanvasViewModel` remains the graph presenter. `GraphAutomationCoordinator` becomes orchestration rather than policy/storage/Mail ownership. `GraphData` and `ObsidianGraphScene` remain projection and interaction layers. Production work targets the Obsidian renderer only.

### Decision 10: Treat success targets as release gates, not aspirations
Automated fixtures prove deterministic geometry, persistence, transactional behavior, authorization invariants, and suggestion precision on a frozen labeled corpus. Installed-app runs prove time-to-organize, live drop reliability, discoverability, wrong-placement rate, retrieval, rendered accessibility, and process survival. Benchmark definitions and sanitized results live under `docs/acceptance/visual-email-organizer/`; reproducible fixtures live under `Tests/Fixtures/Organizer/`. Build success or unit tests alone cannot satisfy human-interaction targets.

## Alternatives Considered
- Replace the graph with a Kanban board or table.
  - Rejected for this change because it discards the existing visual hierarchy and direct-manipulation investment. The Unorganized rail supplies the stable scanning advantages without removing spatial organization.
- Add a separate Organize mode beside Graph.
  - Rejected because it duplicates mode state and asks users to choose between organizing and visualizing. The existing stored Graph mode can migrate safely through a user-facing label and wrapper.
- Store layout in `UserDefaults`.
  - Rejected because per-scope positions can grow substantially. A versioned atomic file has clearer failure handling, test seams, and size behavior.
- Reuse each feature's existing history independently.
  - Rejected because it leaves crash gaps and inconsistent undo semantics at the Apple Mail boundary.
- Define automatic mode as blanket consent to Mail moves.
  - Rejected because it does not make each external effect predictable and cannot uphold zero silent Apple Mail moves for existing settings.

## Risks / Trade-offs
- Risk: Three visible regions (rail, canvas, inspector) compete at narrow widths.
  - Mitigation: collapse/condense the rail first, preserve action-bar and inspector hit areas, and test representative window widths.
- Risk: Lasso, pan, click, and multi-drag gestures conflict.
  - Mitigation: explicit scene state machine, movement threshold, Shift-lasso, and cancellation tests.
- Risk: Persisting every physics callback causes I/O churn.
  - Mitigation: debounce and save only settled user-relevant state.
- Risk: Position IDs become stale or expose internal message identifiers as threads, pages, or Groups change.
  - Mitigation: per-install opaque HMAC IDs, virtual-ID exclusion, source-aware pruning, secret-loss fallback, and shareable-artifact tests.
- Risk: BetterMail and Apple Mail cannot commit atomically.
  - Mitigation: durable prepared state, exact-route receipts, compensation, recovery, and explicit irreversible mailbox-creation wording.
- Risk: The JSON operation ledger and Core Data cannot commit atomically.
  - Mitigation: write-ahead `prepared` state, one atomic Core Data mutation,
    fingerprinted idempotent replay, explicit `ledgerBoundary` recovery, and
    failure-injection tests on both sides of the boundary.
- Risk: A common ledger migration could regress existing Archive/Snip/automation history.
  - Mitigation: adapters first, fixture migrations, conditional undo tests, and no destructive record deletion.
- Risk: Suggestion metrics overfit deterministic test doubles.
  - Mitigation: separate unit behavior from a versioned, anonymized gold-labeled quality corpus and human review.
- Trade-off: Task-first controls make advanced graph customization less immediate.
  - Benefit: lower navigation cost for the product's main organization objective without removing settings.

## Migration Plan
1. Add specs, frozen fixtures, exact benchmark protocol, a Mail mutation call-site inventory, and explicit effect/authorization/consent types with no behavior change.
2. Add the durable operation ledger, schema migration, privacy/redaction policy, and adapters for existing Archive, Snip, and automation records.
3. Extract pure organizer projection/selection and add the Organize wrapper plus Unorganized rail.
4. Add scoped opaque-ID layout storage, anchor receipts/replay, restore, reset, pruning, and compatibility with current `.graph` settings.
5. Route mailbox creation, physical Mail move, and restore through the authorization-gated gateway; migrate existing automatic settings to BetterMail-only until explicit current-version Mail consent.
6. Add lasso, multi-drag, confirmed-Group drop, and empty-canvas inline Group creation through the ledger-backed command service.
7. Integrate inline suggestions, unified history/undo, and queue-wide impact confirmation.
8. Move tuning controls under Advanced; complete localization, keyboard, VoiceOver, privacy, docs, and migration tests.
9. Run focused and full tests, capture the required build log, install the local app bundle, verify process survival, and complete the installed-app benchmark protocol.
10. Do not declare the change complete unless every hard acceptance gate has recorded evidence; label unavailable human-study evidence as pending rather than inferred.

## Rollback Plan
- Keep existing persisted Graph setting keys and ignore, rather than delete, new layout/ledger files on an app rollback.
- Feature-gate the Organize wrapper, direct multi-drag, and unified ledger migration independently during implementation.
- If ledger migration fails, quarantine the affected record, retain the legacy record, and disable its mutation action until review.
- If the Mail gateway cannot prove current consent/authorization or exact routes, stop before mailbox creation, move, or restore and leave a recoverable BetterMail-only or prepared operation.

## Open Questions
- None. Interaction modifiers, Unorganized semantics, Mail consent, persistence scope, and acceptance evidence are defined above.
