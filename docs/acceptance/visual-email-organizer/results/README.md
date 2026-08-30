# Sanitized Organizer Results

This directory holds versioned, sanitized evidence artifacts. Acceptance-status
and primary metric artifacts must identify the protocol, fixture, app build,
evidence type, and applicable schema. Corpus-preparation and suggestion-
evaluation artifacts instead use their own closed, versioned schemas and exact-
byte digest bindings. No shareable artifact may contain raw mail content, exact
routes, raw identifiers, credentials, or provider prompts.

Evidence types remain separate:

- `automated-logic`: deterministic XCTest and static-contract results only;
- `build`: compile/package/install/process-survival evidence;
- `installed-app-launch`: installed-bundle launch and process-survival proof;
- `live-pointer`: native pointer attempts against the installed bundle;
- `accessibility-audit`: named layout, relaunch, keyboard, and accessibility
  observations against `/Users/isaacibm/Applications/BetterMail.app`;
- `timed-human-task`: adjudicated human task and retrieval trials under the
  frozen protocol.

Use the adjacent `../timed-human-runbook.md` for the exact warm, cold/relaunch,
post-commit, and post-relaunch collection sequence. Its guarded
`script/run_organizer_human_trial.py` workflow verifies the installed signing
identity and one-binary session pin, preserves each mutable runtime report
byte-for-byte without overwriting prior evidence, and never sends UI input. It
also documents the mandatory pre-relaunch capture and visible
source/destination labels. Its `preflight` phase performs the same installed
app/extension signing and stopped-host check without launching or creating
evidence. Agent-assisted rehearsals never enter the human
denominators. Its `aggregate-human` phase produces only a local, validated,
non-overwriting acceptance-status proposal; repository promotion remains a
separate reviewed action.

For the current goal, the owner has excluded all task-7.7 human timing and
retrieval trials and has excluded only the actual VoiceOver session from task
8.5. The authorized disposable-route Apple Mail move-and-restore is complete.
`revised-goal-scope-2026-08-30.md` records this decision and its proof boundary.
The exclusions do not change the frozen protocol or turn the pending items in
`acceptance-status-2026-08-28.json` into passes.

Automated tests and build success do not establish installed-app usability,
rendered accessibility, timing thresholds, or suggestion precision. A pending
artifact must retain `status: "pending"` and contain no synthetic success
records.

Recorded evidence:

- `implementation-evidence-2026-08-24.md` — deterministic tests, build,
  install, process-survival, and read-only installed-app AX smoke evidence,
  with incomplete gates called out explicitly.
- `revised-goal-scope-2026-08-30.md` — owner-approved exclusions and the
  remaining proof required for the revised goal; this is a scope record, not a
  passing benchmark artifact.
- `authorized-mail-roundtrip-2026-08-30.md` — sanitized action-time
  authorization, one-message move, source-scoped restore, and direct Apple Mail
  original-source verification; it contains no mail content or routes.
- `acceptance-status-2026-08-28.json` — sanitized status-summary schema with
  evidence type declared per record, final-source installed runtime-boundary
  evidence, partial named accessibility audit, completed deterministic,
  suggestion, native-pointer, and five-by-twenty placement gates, plus the
  separately disclosed cancelled/uncommitted placement attempt and every
  still-pending human/VoiceOver gate. Its declared shape is
  `../acceptance-status-schema-v1.json`; it is not a mixed primary metrics run.
- `organizer-metrics-evidence-v1.pending.json` — reserved pending artifact for
  the frozen human and installed-app benchmark protocol.

The adjacent `suggestion-corpus-integrity-erratum-2026-08-24.md` records a
resolved contract correction, not a benchmark result. It explains why the frozen v1
suggestion corpus and aggregate-only counts cannot satisfy precision task 7.5.
The split v2 schema, byte-digest binding, unrelated rejection-control
denominator, frozen corpus, production-provider predictions, and passing
evaluation are recorded in the adjacent v2 result artifacts.
