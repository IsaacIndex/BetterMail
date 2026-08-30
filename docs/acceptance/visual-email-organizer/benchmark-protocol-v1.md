# Visual Email Organizer Benchmark Protocol v1

Status: frozen contract; no benchmark results are implied by this file.

The protocol measures whether BetterMail can let a user quickly and visually organize existing conversations. It separates deterministic logic evidence, build evidence, installed-app evidence, live pointer evidence, accessibility evidence, and timed task evidence. A build or unit-test pass is never a substitute for installed-app or human-task evidence.

## Frozen inputs

- Manifest: `benchmark-manifest-v1.json`.
- Canvas fixtures: `Tests/Fixtures/Organizer/organizer-100-v1.json` and `organizer-500-v1.json`.
- Legacy suggestion harness: `Tests/Fixtures/Organizer/suggestion-gold-v1.json`
  (frozen but acceptance-ineligible).
- Acceptance suggestion contract: split `suggestion-input-v2.json`,
  `suggestion-gold-v2.json`, and `suggestion-predictions-v2.json` artifacts
  declared in the manifest, plus the corpus-preparation record under
  `results/`. Input and gold may be frozen before a production prediction run;
  their presence alone must not be reported as a passing suggestion-quality
  run. Only an exact-byte-bound production prediction artifact and passing
  evaluator result can change the manifest's acceptance status.
- Generator/validator: `Tests/Fixtures/Organizer/generate_fixtures.py --check`.
- Result artifacts: sanitized files only under `docs/acceptance/visual-email-organizer/results/`.

The manifest's frozen top-level `status: frozen-contract-no-results` is a
legacy label for the contract document itself, not an aggregate acceptance
state. Per-artifact states, including the separately passing suggestion-v2
evaluation and the still-incomplete overall acceptance summary, live in the
declared result artifacts. Do not infer all-gates completion from either field.

The canvas fixture keys, node counts, target groups, placement sets, query key,
legacy v1 suggestion labels, and frozen v2 input/gold bytes are immutable. The
v2 artifact shapes and denominators are frozen; existence is not completed
quality evidence. Do not regenerate any existing artifact with a different
algorithm under the same version. Bump every affected fixture or protocol
version when data or adjudication rules change.

## Installed synthetic fixture launch

The executable benchmark exists only in a Debug build. After installing that build at `/Users/isaacibm/Applications/BetterMail.app`, start a fresh 100-conversation run with:

```bash
/Users/isaacibm/Applications/BetterMail.app/Contents/MacOS/BetterMail \
  --organizer-benchmark-fixture 100 \
  --organizer-benchmark-run synthetic-run-live-001 \
  --organizer-benchmark-task diagnostic \
  --organizer-benchmark-stratum warm \
  --organizer-benchmark-reset
```

Use fixture value `500` for the large canvas. A run ID must start with `synthetic-` and contain only lowercase letters, digits, or hyphens. `--organizer-benchmark-task` accepts `diagnostic`, `live-pointer`, `placement-set`, `first-organization`, `five-conversation-organization`, or `retrieval`; omission defaults to `diagnostic`. A `placement-set` run must also provide `--organizer-benchmark-placement-set placement-set-01|placement-set-02|placement-set-03|placement-set-04|placement-set-05` and fixture `500`; the runtime rejects missing, unknown, or out-of-mode set IDs. Only the last three task modes declare `timed-human-task` evidence, and timed modes fail closed unless fixture `100` is selected. First-organization starts only its own timer at `task-ready`; five-conversation starts only its own timer there; retrieval starts only at `search-start` in a retrieval-capable task. Every retrieval request carries a monotonic generation, so cancellation supersedes a queued start, ends any active timer, and prevents a stale rendered receipt from completing the trial. Each sanitized trial pins its task ID plus the frozen synthetic source, destination, and query keys, while raw synthetic membership identities remain process-local. The optional reset flag deletes only that fixture/run's dedicated preferences and `Application Support/BetterMail/OrganizerBenchmark/<fixture>/<run>/` directory.

Operational clarification, with no change to the frozen gates: initialize an
organization cold/relaunch trial under the same fresh run ID in `diagnostic`
warm mode, quit at Ready before any mutation, and then launch its timed task as
`cold-relaunch` without reset. A retrieval post-relaunch trial instead follows
a completed five-conversation task. Copy `OrganizerMetrics.json` before that
relaunch because a run ID owns one mutable report file. Follow
`timed-human-runbook.md` for the exact capture sequence and visible labels.

Do not begin a valid trial until the persistent banner reads **Ready**, identifies the expected fixture and stratum, and displays **Apple Mail locked** plus **External Mail calls: 0**. The runtime withholds that state until the fixture model is complete and a rendered receipt proves the exact task conversations and confirmed Groups have visible, frame-backed accessibility elements. Malformed or unknown benchmark arguments must show the safe-stop screen and must not fall through to the normal mailbox. The benchmark uses synthetic messages, an isolated preferences/store/ledger/spatial directory, no initial real-source refresh, and a deny-only Mail transport. The banner and zero-call invariant establish fixture isolation; they do not by themselves establish any pointer, accessibility, precision, or timing target.

Every rendered receipt is bound to the monotonic normalized search-filter generation that configured that scene render. The retrieval completion path compares that generation before scheduling and after awaiting timer start, then the recorder invokes a MainActor currentness predicate immediately before committing success; query departure cancels the active timer. Readiness is based on each retained AppKit accessibility proxy's own finite parent-space frame only when its visible view is clipped into a visible onscreen window. A scene resize or window attachment publishes a new receipt after those frames refresh. A result marked `pass` must contain one passing aggregate trial, matching nonempty record and top-level event summaries, the complete ordered successful lifecycle for its task, safe bounded synthetic identifiers, and its aggregate denominator.

## Evidence separation

Every result record declares exactly one primary evidence type:

1. `automated-logic`: deterministic projection, selection, geometry, persistence, command-count, authorization, or suggestion-corpus checks.
2. `build`: the complete `/tmp/xcodebuild.log` and its pass/fail classification.
3. `installed-app-launch`: installed bundle path, launch result, process-survival result, and app build identifier.
4. `live-pointer`: rendered installed-app pointer attempts, target highlight, release, and persisted outcome.
5. `accessibility-audit`: named live audit of keyboard, VoiceOver, roles, actions, labels, and opaque identifiers.
6. `timed-human-task`: warm/cold task durations and retrieval durations from the rendered installed surface.

Do not infer live pointer success from geometry tests, process survival from build success, or human speed from deterministic fixtures.

## Clock and event contract

Use Swift `ContinuousClock` monotonic instants for all measured durations. Wall-clock timestamps may identify a run but may not calculate a duration. Record these event names when applicable:

- `task-ready`: fixture is fully rendered, interactive, and the requested scope is visible. This starts a task timer.
- `search-start`: the user begins the declared retrieval query or search action.
- `action-start`: the first deliberate organization action begins (for example, pointer press or Group command).
- `bettermail-commit`: the intended BetterMail mutation reports committed.
- `rethread-complete`: the effective conversation projection has refreshed after the mutation.
- `visible-result`: the intended result is visible and accessible/selectable.
- `retrieval-visible`: the declared previously organized conversation is visible and accessibility-selectable.
- `cancelled`: the participant or harness cancels after task-ready.
- `failure`: action failure, wrong completion, crash, or unresolved outcome.

The first-organization timer stops only at `visible-result`. The five-conversation timer stops only at `retrieval-visible`. Median and P90 are diagnostics; P80 is the only contractual percentile for the two organization-time gates.

A rendered Group delta can arrive before its active action's BetterMail commit. The recorder retains that aggregate delta and emits `visible-result` only after the matching `bettermail-commit` and `rethread-complete`; failure or cancellation clears it. A placement-set delta first observed while layout is moving remains pending until a settled rendered snapshot arrives. Startup rendering without an active action remains ineligible.

## Invalid and failed trials

An invalid trial is narrowly limited to fixture or instrumentation failure before `task-ready` prevents the task from starting. Record an exact coarse reason, keep the invalid row in the result artifact, and rerun it.

After `task-ready`, cancellation, action failure, wrong completion, app termination, missing rethread, missing visible confirmation, and missing retrieval are failed trials. Count them as over-threshold failures; never exclude them to improve a percentile.

Keep warm and cold/relaunch strata separate. A passing aggregate cannot conceal a failing stratum.

## Timed tasks

### First organization

Run 20 trials on `organizer-100-v1`, split evenly into 10 warm and 10 cold/relaunch trials. The exact source is `node-100-0000`; the exact destination is `group-flat-00`. Start at `task-ready`, and stop only after membership persistence, rethread completion, and visible plus accessible confirmation. Report median, P80, and P90 per stratum. The contractual P80 limit is 30 seconds per stratum.

### Five-conversation organization

Run 20 trials, again split evenly into warm and cold/relaunch strata. Use the exact five source/destination pairs in the manifest. Stop only after all five memberships persist, rethreading completes, the result is visible, and query `synthetic-query-organized-0004` retrieves the expected conversation. The contractual P80 limit is 120 seconds per stratum.

## Deterministic 120-attempt drop matrix

Run exactly 10 attempts in each of these 12 strata:

| Node fixture | Zoom | Target shape |
| --- | --- | --- |
| 100 | low | flat |
| 100 | low | nested |
| 100 | medium | flat |
| 100 | medium | nested |
| 100 | high | flat |
| 100 | high | nested |
| 500 | low | flat |
| 500 | low | nested |
| 500 | medium | flat |
| 500 | medium | nested |
| 500 | high | flat |
| 500 | high | nested |

Use five short-label and five long-label attempts in every stratum. Each valid attempt must record target highlight before release, exactly one normalized organizer command, persisted intended membership, and zero unauthorized Apple Mail calls. The overall success gate is at least 95%; every stratum must be at least 90%.

Also exercise the manifest’s ghost, virtual-remainder, and outside-canvas targets. Invalid, cancelled, and ghost/virtual-target attempts must produce zero membership mutation and zero Apple Mail calls. They are reported as unsuccessful attempts when applicable, not silently discarded.

## Installed-app pointer attempts

Run at least 40 attempts against the installed local app. Cover both fixtures, single and multi-selection, all three zoom bands, flat and nested targets, and short and long labels. Before each release, record whether the intended target visibly highlighted. After release, adjudicate the persisted BetterMail result and the operation ledger/Mail-boundary evidence. The success gate is at least 95%.

Every failed attempt remains in the sanitized result artifact with only a coarse reason such as `no-highlight`, `wrong-target`, `no-persisted-membership`, `duplicate-command`, `cancelled`, or `instrumentation-failure`.

## Five independent placement sets

Run the five manifest placement sets independently, resetting the fixture before each set. Each set has 20 exact source nodes and one exact destination, for 100 completed placements total. A set passes only when it contains no more than one wrong placement. Classify BetterMail membership errors separately from Apple Mail source/account/destination route errors. A cancellation before mutation is unsuccessful but not a wrong persisted placement; any unintended, partial, unresolved, or incorrectly routed mutation is wrong in its applicable category.

## Suggestion precision and coverage

Integrity erratum: `suggestion-gold-v1.json` remains frozen, but it cannot
produce acceptance evidence. Its sequential keys reveal alternating labels and
it has no separate production-relevant provider-input artifact. See
`suggestion-corpus-integrity-erratum-2026-08-24.md`.

Acceptance uses three independently handled v2 files. The provider sees only
`suggestion-input-v2.json`, containing opaque 256-bit random candidate/source/
destination keys assigned before adjudication plus synthetic source and target
titles, summaries, representative content, and target profile type. It must not
contain expected labels/destinations, relation, confidence-band, or provenance
fields. `suggestion-gold-v2.json` is evaluator-only. The production provider or
frozen production prediction run creates `suggestion-predictions-v2.json`
without gold access and binds the SHA-256 digest of the exact provider-input
bytes. Unreadable files, unknown fields, malformed JSON, digest mismatch, input/gold identity
mismatch, non-opaque keys, invalid gold adjudication, or invalid prediction
shape makes the run `insufficientEvidence`.

The corpus must contain at least 200 effective-source candidates and at least
100 accepted or auto-applied placements overall. Attach, append, every
confidence band, and both provenance slices each require at least 25 accepted
placements. `unrelated` is a negative-control relation: every unrelated gold
outcome is `rejected`, and that slice instead requires at least 25
non-abstained decisions. A rejected unrelated candidate is a correct negative;
an accepted destination is a false positive and never a corpus-qualification
shortcut.

The result must pin corpus ID, provider, model version, prompt/policy version,
strictness, app build, evidence origin, and the exact input/gold SHA-256 digests.
Deduplicate by `sourceKey` before calculating metrics; disclose identical
duplicates, and classify any conflicting gold or prediction semantics as
insufficient evidence. Precision is:

`correct accepted or auto-applied placements / all accepted or auto-applied placements`

Report coverage and abstention separately. The gates are overall precision
>=80%, conservative-mode precision >=85%, and overall non-abstained coverage
>=50%. Missing denominators, slice counts, version metadata, digest binding, or
coverage is insufficient evidence, not a pass. Aggregate recorder counts and
deterministic provider doubles remain diagnostics only.

## Retrieval

After the five-conversation task, run at least 20 post-commit and 20 post-relaunch retrieval trials. Start at `search-start` with query `synthetic-query-organized-0004`; stop at `retrieval-visible` only when the exact GraphThread for `node-100-0004` has a finite, nonempty accessibility frame intersecting the active Organize viewport and remains selectable. A matching reply node or offscreen result is not sufficient. Each stratum must complete within five seconds in at least 95% of trials. Wrong-result, abandoned-query, failed, cancelled, and crashed trials are misses.

## Installed-app and accessibility checklist

The delivery run must use Apple Development certificate SHA-1
`59D9099E689B4FCF247C0E2C021C3B62E80AE4B2` with
`DEVELOPMENT_TEAM=TN3L2WBKR5`; no ad-hoc fallback is allowed. Both the app and
Mail extension must pass `codesign --verify --deep --strict` before
installation and again at `/Users/isaacibm/Applications/BetterMail.app`. Their
reported Team Identifier must be `TN3L2WBKR5`. Register, launch, and verify
process survival. Capture the clean build log at `/tmp/xcodebuild.log`.

The named live audit must cover mode migration, rail/canvas synchronization, search, single and multi-selection, lasso, batch drop, empty-canvas Group creation, relaunch layout restoration, suggestion review, effect disclosure, authorization, undo/recovery, narrow-width layout, keyboard operation, VoiceOver roles/actions, and opaque stable identifiers. Verify that no bottom overlay obstructs required controls or targets.

## Sanitized metric rules

Shareable results may contain fixture keys, coarse action types, durations in milliseconds, status, aggregate counts, and coarse failure reasons. Do not export raw subjects, senders, bodies, snippets, account names, mailbox paths, exact routes, raw message/thread IDs, authorization tokens, encryption keys, or provider prompts. Result schemas are closed: unknown schema versions, fields, free-form notes, event names, observations, or reason strings fail validation. An overall pass requires every hard gate in `acceptance-status-schema-v1.json` to pass with its frozen denominator and an empty `unmetTargets` list. Use `metric-schema-v1.json` for the metric result shape.

No result file should claim a target was met until the corresponding evidence type exists. Missing live or timed evidence remains `pending`.
