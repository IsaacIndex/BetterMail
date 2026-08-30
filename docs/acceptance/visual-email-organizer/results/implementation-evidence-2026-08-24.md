# Visual Email Organizer Implementation Evidence

- Status: revised-goal evidence and closing audit complete except for the
  required final source fetch; the final-source deterministic suite, guarded
  Apple Development build/install, production runtime boundaries, deterministic
  drop matrix, suggestion quality, zero-Mail invariant, and the native installed
  pointer, five-by-twenty placement, and non-VoiceOver installed interaction/AX
  checks and the authorized Mail move-and-restore are proved. Timed-human
  trials and actual VoiceOver operation are owner-excluded from the revised
  goal and are not claimed as passing. The frozen v1 protocol therefore remains
  partial and `insufficient-evidence`.
- Evidence date: 2026-08-30 HKT
- Artifact initiated: 2026-08-24; the original filename is retained as the
  stable evidence-series path while dated observations are refreshed in place.
- Repository revision: `1e3e4b39609d0aabf8435a29df4e8052ee095ccb`
- Provenance boundary: evidence was produced from the dirty working tree based
  on that revision; the base commit alone does not contain the tested change.
- Installed app: `isaacwongnh.BetterMail` version `1.0` build `1`
- Protocol: `benchmark-protocol-v1.md`
- Fixtures: `organizer-100-v1.json`, `organizer-500-v1.json`, and the
  acceptance-ineligible legacy harness `suggestion-gold-v1.json`; frozen v2
  provider input, evaluator-only gold, production predictions,
  corpus-preparation record, and passing aggregate quality result now exist
- Metric schema: `metric-schema-v1.json`

This artifact contains no raw mail content, exact Mail routes, raw organizer
identifiers, credentials, or provider prompts.

Commands below name ephemeral `/tmp` capture paths. They document the original
capture locations, not durable repository artifacts; an independent current
verification must recreate any missing log rather than infer a pass from an
expired path.

## Automated logic

- Focused benchmark-runtime XCTest run: 13 tests, 0 failures,
  `TEST SUCCEEDED`. It verifies argument fail-closed behavior, exact fixture
  parity, isolated settings/storage, a deny-only Mail transport with zero
  external calls, and complete 500-conversation rethreading independent of the
  production rolling-day window. Full output:
  `/tmp/xcodebuild-organizer-benchmark-runtime-tests.log`.
- Focused Core Data regression runs: the formerly crashing
  `testFolderSummaryDebouncePublishesLatestRefresh` passed after summary-cache
  operations were made to await initial migrations, and the complete
  `ThreadSummaryCacheTests` class passed 22/22. Full outputs:
  `/tmp/xcodebuild-folder-summary-debounce-fixed.log` and
  `/tmp/xcodebuild-thread-summary-cache-fixed.log`.
- Latest signed deterministic XCTest run: 720 tests executed, one intentional
  production-only skip, zero failures, `TEST SUCCEEDED`. Full output:
  `/tmp/xcodebuild-organizer-tests-final.log`.
- The latest focused topic/suggestion-review regression run passed 8/8 with the
  same manual non-ad-hoc Apple Development signing settings. It proves a fresh
  published topic snapshot immediately replaces stale suggestion state, and
  its storage-backed cases prove that accepting trim-normalized selected
  conversations may remove an actually emptied source leaf while preserving
  unrelated empty flat and nested Groups. Full output:
  `/tmp/xcodebuild-latest-review-tests.log`.
- Focused suggestion-evaluator run after the corpus-integrity audit: 13 tests,
  0 failures, `TEST SUCCEEDED`. It proves a separate no-gold prediction-input
  type, post-prediction gold join, all relation/confidence/provenance slices,
  version-pin and corpus-integrity gates, duplicate-source conflict accounting,
  deterministic-double rejection, and detection of the sequential-key label
  channel present in v1. Full output:
  `/tmp/xcodebuild-suggestion-evaluator.log`.
- The task-7.5 harness now decodes exact-field input/gold/prediction artifacts,
  binds predictions to the SHA-256 digest of the exact provider-input bytes,
  validates opaque keys and evidence origin, and uses explicit unrelated
  rejection-control denominators. The split 216-candidate input/gold corpus and
  preparation record pass their one-shot validator. The explicit gold-blind
  production-provider XCTest evaluated all 216 candidates in 1,414.136 seconds
  and passed with 140 correct accepted placements, zero false positives, four
  conservative false negatives, 100% precision, and 100% coverage. Every
  relation, confidence-band, and provenance denominator passed. Full output:
  `/tmp/xcodebuild-suggestion-production-full.log`.
- `OrganizerMetricsRecorder` owns a `ContinuousClock` session and is wired
  through benchmark readiness, task visibility, selection, drag/drop,
  organization commit/rethread/visibility, Mail authorization/results,
  undo/recovery, and exact-query retrieval boundaries. The final focused
  visibility/recorder run executed 47 tests with one intentional
  production-only skip and zero failures. Full output:
  `/tmp/xcodebuild-organizer-visibility-count-fix.log`.
- `OrganizerDropMetricsCoordinator` now serializes each installed drop's
  action-start, intent, highlight, release, authoritative mutation, and outcome
  on the Main Actor. The recorder rejects early or duplicate lifecycle events,
  and attempt UUIDs prevent a stale empty-canvas composer from completing a
  newer attempt. A focused signed regression run executed 57 tests with one
  intentional skip and zero failures. Full output:
  `/tmp/xcodebuild-drop-ordering-focused-2.log`.
- An installed 500-fixture placement preflight exposed a main-thread stall
  while 20 conversations were selected and the graph viewport was panned. A
  five-second process sample traced the hot path to per-node accessibility
  projection repeatedly rebuilding `GraphData`'s computed Group/thread/message
  dictionaries. `GraphSceneLookupIndex` now materializes all four scene maps
  once per data revision and reuses them across accessibility and interaction;
  duplicate geometry refreshes were also removed from the viewport application
  helpers. The focused signed graph run passed 5/5, and the latest clean signed
  suite passed 617 tests with one skip and zero failures. Full outputs:
  `/tmp/xcodebuild-lookup-index-focused-3.log` and
  `/tmp/xcodebuild-all-tests-lookup-final-2.log`.
- A later installed 500-fixture placement preflight crossed local midnight and
  exposed a separate benchmark-readiness defect: the frozen fixture was being
  filtered by the production seven-day cutoff, leaving 1,441 messages and 481
  roots instead of 1,500 messages and 500 roots. The benchmark-created
  `ThreadCanvasViewModel` now explicitly rethreads all messages in its isolated
  synthetic store, while every ordinary mailbox view model retains the existing
  rolling-day behavior. The regression test observed exactly 1,500 messages
  and 500 roots and the complete 13-test benchmark-runtime class passed. In the
  newly installed bundle, `synthetic-placement-final-01` reached the Ready
  boundary with all 500 conversations and its exact first 20-source range was
  selected. The desktop locked before the pointer release, so this is readiness
  and selection evidence only—not a completed placement set.
- The original fifth placement-set attempt, `synthetic-placement-proof-05`,
  then exposed a distinct settled-position feedback loop: each scene physics
  report republished authoritative ViewModel positions, rebuilt the scene, and
  restarted settling. The app remained near 100% CPU and the attempt was
  cancelled before any action or mutation. A five-second sample is retained at
  `/tmp/bettermail-set05.sample.txt`. Scene-owned interim positions are now
  coalesced privately; only a settled report merges and persists them, while
  explicit bridge updates and Reset Layout undo remain authoritative. The
  focused signed regression run passed 6/6 and the full signed suite passed
  627 tests with one skip and zero failures. Full outputs:
  `/tmp/xcodebuild-spatial-scene-coalescing.log` and
  `/tmp/xcodebuild-all-tests-spatial-scene-coalescing.log`.
- The final benchmark/metrics/accessibility follow-up run executed 68 tests with one
  intentional production-provider skip and zero failures. It proves explicit
  diagnostic, live-pointer, placement-set, first-organization,
  five-conversation, and retrieval modes; a single contractual timer per timed
  task; frozen task/source/destination/query pins in every trial; unit/synthetic
  GraphThread identity at the rendered retrieval boundary; and nonzero AppKit
  retained AppKit accessibility proxies with true onscreen-window geometry,
  window-attachment republishing, normalized render generations, and a final
  MainActor currentness check before retrieval-success commit. Installed
  active-viewport/selectability proof was subsequently observed once in the
  final installed bundle, but the complete audit remains pending. Full
  output: `/tmp/xcodebuild-focused-final-p1.log`.
- Final-source installed run `synthetic-runtime-boundary-003` recorded the
  canonical production sequence from `workspace-ready` through two-item
  selection, atomic Group commit, BetterMail commit, rethread completion,
  rendered `group-visible(count: 2)`, and finished
  `visible-result(count: 2)`. The same run recorded exact-query
  `retrieval-visible(count: 5)`, one normalized command, and zero external
  Mail calls. This completes task 7.1; the agent-assisted retrieval duration is
  diagnostic only and does not satisfy task 7.7.
- The deterministic drop matrix ran exactly 120 attempts across both fixture
  sizes, all three zoom bands, flat and nested targets, with five long-label
  attempts in every ten-attempt stratum. Its overall and per-stratum gates
  passed.
- Installed runs `synthetic-live-pointer-005` through `-020` contain 40 counted
  native attempts: 38 successful and two retained no-highlight failures, for an
  exact 95% success rate. They span single and multi-selection, 100- and
  500-conversation fixtures, 69%/100%/173% zoom, flat and nested confirmed
  targets, and short and long labels. The aggregate contains 38 normalized
  BetterMail commands, zero invalid-target mutations, and zero Mail calls. A
  successful attempt records `action-start` -> `drop-intent` ->
  `drop-highlight` -> `drop-release` -> `group-committed` ->
  `bettermail-commit` -> `group-rethreaded` -> `rethread-complete` ->
  `drop-outcome` -> `group-visible` -> `visible-result`; each failed attempt
  records failed release/outcome and no command. This completes task 7.3.
- Five independent signed installed-app placement runs completed the frozen
  500-conversation sets: `synthetic-placement-proof-01` through `-04` and the
  repaired `synthetic-placement-proof-05b`. Each run selected its exact 20
  frozen sources and committed them to its exact frozen destination. The
  adjudicated aggregate is 100/100 correct placements, zero BetterMail
  membership errors, zero Apple Mail route errors, five normalized BetterMail
  commands, and zero Mail calls. The earlier
  `synthetic-placement-proof-05` reached task-ready but was cancelled before
  action, command, or mutation; it is disclosed separately as an unsuccessful
  uncommitted attempt and is not counted as a wrong persisted placement. This
  completes task 7.4.
- Fixture generation check and benchmark-manifest validation passed. The same
  validator now rejects unknown result schemas and fields, non-vocabulary text,
  and unsupported pass claims without every hard gate plus the required 12 drop
  strata, pointer coverage, five exact placement sets, warm/cold timing,
  retrieval, signing, and accessibility denominators. Thirteen adversarial
  fail-closed regression cases pass.
- Property-list validation for the localized strings and Xcode project passed.
- JSON syntax validation passed for all 13 frozen fixture, schema, manifest,
  status, and evaluation artifacts. `plutil` also passed the Xcode project and
  localized strings; JSON was validated with the JSON parser rather than
  treating `plutil`'s unsupported JSON input as a failure.
- `git diff --check` passed.
- The final non-human safety follow-up wired production spatial-anchor replay,
  added prepare-to-Core-Data fault injection, preserved known mailbox-create
  recovery evidence without raw-route leakage, narrowed History undo metadata
  to implemented commands, and added exact/stale effect checks for Move and
  Snip. A signed focused run passed 60/60 tests, and those tests are included in
  the 715-test full run. Zero-message backfill continues through the exhaustive
  coverage service but no longer schedules a pointless rethread when it fetched
  no messages.
- The Organize search synchronization, direct published-topic consumption,
  reviewed-suggestion empty-Group preservation, rendered-group receipt,
  scene-index, scene-position coalescing, retained accessibility-role, and
  benchmark date-window fixes are included in the 715-test final-source run,
  the exact-signing clean build, and the installed benchmark evidence above.
- Strict OpenSpec CLI validation could not be run because the `openspec`
  executable is not installed in this workspace. No package was downloaded.

Automated results establish deterministic logic only. Separate installed runs
establish the named production event boundaries, search visibility, relaunch
persistence, partial accessibility observations, and the complete 40-attempt
native pointer denominator. Pointer acceptance does not establish complete
VoiceOver operation or human task timing.

The frozen v1 suggestion corpus is explicitly classified as harness-only, not
quality evidence: sequential keys leak its labels and no provider-relevant
input artifact exists. Aggregate-only suggestion counts can no longer report a
pass. The v2 split-artifact code, frozen input/gold corpus, preparation record,
exact-byte-bound production predictions, and sanitized passing evaluation are
now frozen. Their four SHA-256 digests are pinned in the benchmark manifest;
task 7.5 is complete.

## Build and installed bundle

- The required simulator cache clear completed successfully.
- Keychain exposes exactly one valid code-signing identity at SHA-1
  `59D9099E689B4FCF247C0E2C021C3B62E80AE4B2`. Its certificate display name
  carries UID `MSTX4LWLXN`; its subject organizational unit and correct expected
  Team Identifier are `TN3L2WBKR5`.
- The certificate validates for code signing through Apple Worldwide Developer
  Relations G3 to Apple Root CA, including a successful OCSP result. User and
  admin trust settings contain no custom leaf-certificate or Apple WWDR trust
  override, so no relevant override needed resetting; unrelated enterprise-root
  trust settings were preserved.
- The final guarded workflow completed a clean build using that exact SHA-1 and
  `DEVELOPMENT_TEAM=TN3L2WBKR5`. Before installation, both `BetterMail.app` and
  `MailHelperExtension.appex` passed `codesign --verify --deep --strict`; the
  same checks passed independently after installation. Full clean-build output
  is `/tmp/xcodebuild.log`.
- The guarded workflow now independently extracts each staged and installed
  CMS certificate chain, validates its leaf for the code-signing policy, and
  requires the extracted leaf SHA-1 to equal
  `59D9099E689B4FCF247C0E2C021C3B62E80AE4B2`. Both targets passed this stronger
  check. The installed and build-product entitlement payloads compare
  byte-for-byte equal for the app and extension.
- The installed app and extension are CMS-signed, not ad hoc, report the Apple
  Development, Apple WWDR, and Apple Root authorities, and both report
  `TeamIdentifier=TN3L2WBKR5`. Their bundle IDs remain
  `isaacwongnh.BetterMail` and
  `isaacwongnh.BetterMail.MailHelperExtension`; their existing entitlements are
  preserved.
- The final installed bundle was quit out of benchmark mode, then launched
  twice in normal mode. On both launches the populated BetterMail window
  appeared, the running executable path resolved to
  `/Users/isaacibm/Applications/BetterMail.app/Contents/MacOS/BetterMail`, no
  sheet/dialog or SecurityAgent/Keychain UI was present, and the
  `com.bettermail.graph-spatial` prompt did not recur.
- After the drop-ordering fix, a final clean install repeated the exact-SHA,
  trust-chain, deep/strict, Team Identifier, bundle-ID, and entitlement checks
  for both targets. Independent extraction from the installed app and extension
  confirmed the requested leaf SHA-1, the Apple Development/WWDR G3/Apple Root
  chain, `TeamIdentifier=TN3L2WBKR5`, and successful code-signing-policy trust
  validation. Normal launches at 19:18:46 and 19:20:19 HKT both showed the
  populated Applications-bundle window with no sheet, Keychain dialog,
  SecurityAgent UI, or `com.bettermail.graph-spatial` text. A SecurityAgent
  process that had started at 19:15:37 predated both launches; it was excluded
  from the launch-associated recurrence count because neither UI inspection nor
  the unified log linked it to BetterMail.
- After the scene-index fix, the guarded clean install again passed the exact
  SHA-1, trust-chain, deep/strict, Team Identifier, bundle-ID, and entitlement
  checks for the staged and installed app and extension. Two explicit normal
  Applications-bundle launches started at 20:48:26 and 20:49:28 HKT. Neither
  launch created a SecurityAgent process, and the unified log contained no
  `com.bettermail.graph-spatial` event. After the macOS session was unlocked,
  the populated window from the 20:49:28 launch was visibly inspected at
  23:17:02 with no sheet, dialog, SecurityAgent/Keychain UI, or prompt text. A
  further clean normal relaunch started at 23:17:32 and was visibly inspected
  at 23:18:50 with the same no-dialog result; a narrowly filtered unified-log
  query from that launch time returned no SecurityAgent or
  `com.bettermail.graph-spatial` event.
- After the retained accessibility-role and benchmark date-window fixes, the
  2026-08-30 guarded workflow performed another clean build and install. The
  staged and installed app and extension again passed deep strict verification,
  exact leaf-SHA validation, certificate-chain validation, Team Identifier,
  bundle-ID, and entitlement equality checks. Independent full-trust inspection
  reports the Apple Development / Apple WWDR / Apple Root chain and
  `TeamIdentifier=TN3L2WBKR5` for both targets; user and admin trust settings
  still contain no custom Apple Development or WWDR override. The desktop
  locked during the subsequent placement run, so that build's normal-launch
  check was not used as final proof; the later clean bundle below supersedes it.
- After the scene-position coalescing fix, the final guarded clean build/install
  again used only SHA-1 `59D9099E689B4FCF247C0E2C021C3B62E80AE4B2` with
  `DEVELOPMENT_TEAM=TN3L2WBKR5`. Both staged and installed app and extension
  passed deep strict verification, exact leaf-SHA validation, code-signing
  chain validation, bundle-ID checks, and entitlement equality. The guarded
  workflow and independent inspection logs are
  `/tmp/bettermail-install-spatial-scene-coalescing.log`, `/tmp/xcodebuild.log`,
  and `/tmp/bettermail-independent-signing-spatial-scene-coalescing.log`.
  Independent inspection reported CMS signatures—not ad hoc—and
  `TeamIdentifier=TN3L2WBKR5` for both targets. User and admin trust settings
  again contained no custom Apple Development or Apple WWDR override, so no
  relevant trust entry was reset. A later verification from the restricted
  execution context reproduced `CSSMERR_TP_NOT_TRUSTED`; immediate
  trust-aware verification outside that restriction passed deep strict checks
  and `security verify-cert -p codeSign -N -L` for both unchanged bundles with
  the exact requested leaf SHA-1. The error was therefore an execution-context
  trust-access boundary, not a custom certificate-trust override or a bad
  installed signature.
- That exact final installed bundle was then launched normally at 03:41:25 and
  03:42:20 HKT. Both launches displayed the populated BetterMail window from
  `/Users/isaacibm/Applications/BetterMail.app/Contents/MacOS/BetterMail`, with
  no sheet, password dialog, Keychain/SecurityAgent UI, or
  `com.bettermail.graph-spatial` prompt. The pre-existing SecurityAgent process
  retained PID 78810 and its 01:25:57 start time across both launches, and a
  narrow unified-log query from 03:41:00 found no BetterMail-linked
  SecurityAgent or `com.bettermail.graph-spatial` event.
- After the direct topic-publication and reviewed-suggestion preservation fixes,
  the guarded workflow clean-built and installed the current source again. Both
  installed targets passed deep strict verification; independent extraction
  confirmed the exact requested leaf SHA-1, Apple Development / Apple WWDR /
  Apple Root chain, code-signing-policy trust, preserved bundle identifiers,
  and `TeamIdentifier=TN3L2WBKR5`. Current user and admin trust settings contain
  no custom Apple Development, matching leaf, or WWDR override, so there was no
  relevant custom trust entry to reset. Full independent output is
  `/tmp/bettermail-final-signing-proof.log`.
- The same final installed bundle was launched normally twice and inspected at
  04:57:38 and 04:58:03 HKT. Both populated windows had no sheet, password
  dialog, Keychain/SecurityAgent UI, Allow/Deny control, or
  `com.bettermail.graph-spatial` text. The second launch's running executable
  was `/Users/isaacibm/Applications/BetterMail.app/Contents/MacOS/BetterMail`.
- After the visible Select Area control was added, the guarded workflow
  clean-built and installed the new current source. The app and Mail extension
  again passed deep strict verification before and after installation. An
  independent inspection confirmed CMS signatures rather than ad-hoc,
  preserved identifiers `isaacwongnh.BetterMail` and
  `isaacwongnh.BetterMail.MailHelperExtension`, the exact requested leaf SHA-1,
  the Apple Development / Apple WWDR / Apple Root chain, and
  `TeamIdentifier=TN3L2WBKR5` for both targets. The build/install and independent
  proof logs are `/tmp/bettermail-lasso-final-install.log`,
  `/tmp/xcodebuild.log`, and
  `/tmp/bettermail-lasso-final-signing-proof.log`.
- That latest installed bundle was launched normally twice at 12:04:33 and
  12:05:08 HKT. Settled inspections at 12:04:41 and 12:05:13 found only the
  populated BetterMail window: no sheet, password dialog, Keychain prompt,
  SecurityAgent UI, or `com.bettermail.graph-spatial` text. A narrow system-log
  query beginning at 12:03 found no matching graph-spatial or SecurityAgent
  event, and no SecurityAgent process remained after the launches.
- This signing repair did not modify bundle IDs, entitlements, or Xcode project
  signing files. Its signing configuration/workflow edits are limited to the
  ignored local signing xcconfigs, guarded local build/install script, and Codex
  local install action; they use the exact certificate and `TN3L2WBKR5`, with no
  ad-hoc fallback.
- The final non-human completion pass on 2026-08-30 reset the simulator cache,
  then the guarded workflow clean-built and installed the current source at
  15:42 HKT. Both the staged and installed app and Mail extension passed deep
  strict verification, exact leaf-SHA validation, code-signing-policy chain
  validation, preserved bundle identifiers, and entitlement equality. An
  independent installed-bundle check again reported CMS signatures rather than
  ad hoc, `TeamIdentifier=TN3L2WBKR5`, leaf SHA-1
  `59D9099E689B4FCF247C0E2C021C3B62E80AE4B2`, and the Apple Development / Apple
  WWDR / Apple Root chain for both targets. User and admin trust settings contain
  no custom Apple Development, matching-leaf, or Apple WWDR override, so no
  relevant trust entry was reset and unrelated enterprise trust remained
  untouched. Logs: `/tmp/xcodebuild.log`,
  `/tmp/bettermail-nonhuman-final-install.log`, and
  `/tmp/bettermail-nonhuman-final-signing-proof.log`.
- The guarded first launch and an explicit second normal relaunch were each
  inspected through the installed Applications bundle. Both showed the
  populated BetterMail window without an authorization sheet or Keychain
  prompt. The second launch began at 15:44:22 HKT from
  `/Users/isaacibm/Applications/BetterMail.app/Contents/MacOS/BetterMail`; no
  `SecurityAgent` process was present, and a launch-window unified-log query
  contained no `com.bettermail.graph-spatial` or SecurityAgent event. Keychain
  Access happened to be open separately, but it showed its ordinary item list,
  not a BetterMail authorization dialog.
- After the graph-centering, drag-coalescing, and production-log privacy fixes,
  the final signed suite at 22:39 HKT executed 720 tests with one intentional
  skip and zero failures. The simulator cache was then erased and the guarded
  workflow clean-built and installed that exact current source at 22:41 HKT;
  `/tmp/xcodebuild.log` ends with `BUILD SUCCEEDED`, and the workflow's launch
  survival check completed successfully. A fresh trust-aware inspection of the
  installed app and Mail extension independently passed deep strict
  verification and code-signing-policy chain validation. Both are CMS-signed,
  not ad hoc, use leaf SHA-1
  `59D9099E689B4FCF247C0E2C021C3B62E80AE4B2`, report
  `TeamIdentifier=TN3L2WBKR5`, and retain bundle identifiers
  `isaacwongnh.BetterMail` and
  `isaacwongnh.BetterMail.MailHelperExtension`. After the desktop was unlocked,
  that exact final bundle was quit and normally relaunched twice. Both settled
  on the populated Organize workspace without a sheet, password dialog,
  SecurityAgent UI, or `com.bettermail.graph-spatial` prompt. The second launch
  process started at 22:47:29 HKT from the installed Applications path; no
  SecurityAgent process was present, and a ten-minute unified-log query
  excluding the query process itself returned no graph-spatial prompt event.

## Synthetic benchmark safety

- The DEBUG-only benchmark accepts only the frozen 100- and 500-conversation
  fixtures, declared warm/cold-relaunch strata, and explicit diagnostic,
  live-pointer, placement-set, first-organization, five-conversation, or
  retrieval tasks; malformed or unknown arguments fail closed into a safe
  error view. Timed tasks additionally fail closed on the 500-node fixture.
- Diagnostic mode is the default and declares accessibility-audit evidence,
  not timed-human evidence. First-organization and five-conversation each
  start only their own timer at task-ready; retrieval starts only at
  search-start. Trial output pins only the frozen synthetic task, source,
  destination, and query keys.
- Installed run `synthetic-task-mode-smoke-001` exercised that separation in
  the signed Applications bundle. Its exported record declares
  `evidenceType: accessibility-audit`, `taskId: diagnostic`, an instantaneous
  task-ready event, zero samples for every timed metric, and zero Mail calls.
  The result privacy/shape validator accepts the emitted JSON. This is an
  instrumentation smoke check, not timed-human or complete accessibility
  evidence.
- Each run has separate Application Support storage, spatial state, operation
  ledger, route key, secret, and UserDefaults suite.
- Source refresh is disabled, the injected Mail client contains only synthetic
  messages, and the mutation transport denies every external Mail operation.
- The in-app banner reports the fixture/stratum plus `Apple Mail locked` and
  `External Mail calls: 0`.
- Final-source installed benchmark run `synthetic-runtime-boundary-003`
  confirmed the 100-conversation fixture, zero external Mail calls, two-row
  grouping, a visible confirmed Group, and one Organization History entry.
- Entering the exact frozen query `synthetic-query-organized-0004` surfaced the
  expected synthetic conversation and recorded `retrieval-visible(count: 5)`.
  The observed 238 ms duration is agent-assisted diagnostic evidence, not an
  eligible timed-human result.
- A cold relaunch without resetting benchmark storage restored the same Group,
  history count, and stable opaque Group accessibility identifier. Collapsing
  and restoring the rail left the graph and bottom controls unobstructed.

## Installed-app visual and accessibility smoke check

A named accessibility-assisted inspection against the installed Applications
bundle confirmed that the following rendered in the active Organize mode:

- the independently scrollable Unorganized rail and selected-count action bar;
- Group, Move, and Archive actions;
- compact suggestion cards with rationale, confidence, membership summary,
  destination, evaluation time, source, and effect label;
- graph organization controls and graph canvas;
- the unified Organization History control with a populated item count;
- opaque stable identifiers shaped as
  `bettermail.organizer.<role>.<opaque-token>` for rail, suggestion, Group, and
  conversation elements;
- labels, hints, stable identifiers, and secondary selection actions in the
  accessibility tree.

The first installed audit exposed custom SpriteKit marks with an unknown AX role
and no reliable screen geometry. The final signed bundle's unlocked AX tree now
exposes 61 organizer elements, including 45 graph elements, with retained button
semantics, usable screen geometry, and 59 press-capable organizer elements. A
native `AXPress` on a confirmed Group returned success and changed its value from
Not selected to Selected. This proves the installed AppKit proxy role, frame,
and press bridge; it does not substitute for an actual VoiceOver session or the
remaining named interaction audit.

The benchmark mutations stayed inside BetterMail and made zero external Mail
calls. Thirty-eight native pointer attempts completed with visibly correct
highlight, release, persisted Group destination, and the authoritative
lifecycle above; two no-highlight releases failed without a command or
mutation and remain in the denominator. Installed run
`synthetic-live-audit-20260830b` additionally proved two-conversation native
empty-canvas release, inline naming, atomic Group creation, a 100-to-98
Unorganized count change, one ledger operation with spatial anchor intent and
receipt, and the canonical commit/rethread/render lifecycle through
`group-visible(count: 2)` and `visible-result(count: 2)`. The same installed
audit resized the Organize workspace through its 660-point threshold and
observed the compact, independently identified Unorganized rail while the graph
remained visible. A focused keyboard audit moved selection and focus together
between rail and graph conversations.

Fresh installed run `synthetic-suggestion-audit-20260830c` surfaced
`Potential Group 01` from the one-shot published topic result without a search
or settings nudge. Review & Edit displayed 100 of 100 proposed conversations;
the name was changed to `Reviewed Potential Group`, Create Group completed, all
100 synthetic conversations became members, the suggestion disappeared, and
all eight unrelated empty fixture Groups remained in the store. The persistent
banner stayed Ready with Apple Mail locked and zero external Mail calls.

Fresh installed run `synthetic-approved-audit-20260830a` performed an approved
BetterMail-only archive/restore round-trip on one isolated synthetic
conversation. All Emails changed from 100 to 99 conversations after Archive;
Graph Archive then showed exactly one conversation and Organization History
exposed its explicit Restore action. Restore cleared the history item and the
`ZARCHIVEDINGRAPHENTITY` row, and All Emails returned to 100 conversations.
The banner remained Ready with Apple Mail locked and zero external Mail calls
throughout. This covers the live BetterMail-local undo/recovery path; it does
not claim an authorized Apple Mail mutation or external-Mail recovery.

Fresh installed run `synthetic-lasso-control-audit-20260830b` armed the visible
Select Area toolbar control and exposed the instruction to drag on empty graph
space. One ordinary pointer drag, with no Shift modifier, selected ten synthetic
conversations in both the graph and rail; the selected control remained armed.
The runtime recorded one successful `selection(count: 10)` event, zero
normalized organization commands, and zero external Mail calls while the
banner continued to report Apple Mail locked. This advances the live-lasso
gate without changing BetterMail organization state or Apple Mail.

The review follow-up also corrected the empty Snip-staging transition into
Archive so the two toolbar modes cannot remain active together. The exact
signed focused suite passed 25 tests with zero failures, including armed lasso,
node-origin drag, unarmed blank-canvas pan, and lasso/Archive/Snip mode
exclusivity. Its full log is `/tmp/xcodebuild-lasso-mode-tests.log`.

VoiceOver remained off, so no VoiceOver operation is claimed. The owner later
excluded the actual VoiceOver session from the revised goal while leaving the
authorized disposable-route Apple Mail mutation in scope. The frozen v1
acceptance artifact still records VoiceOver as unobserved; the scope exclusion
is not a pass. The live-lasso and separate five-set placement gates are complete
as described above.

Two installed, Apple-Mail-locked first-organization rehearsals were used to
verify the timed workflow before handing it to a human participant. They are
explicitly agent-assisted and do not enter any human denominator:

- `synthetic-first-rehearsal-20260830a` selected the frozen source but invoked
  the rail's **Group** action. That created a new Group rather than using
  `group-flat-00`; after the canonical commit and rethread events, the runtime
  correctly ended the 30,001 ms attempt as `wrong-completion`.
- `synthetic-first-rehearsal-20260830b` selected the same source and invoked
  **Move selection here** on `Confirmed Group 01`. The report contains the
  canonical commit/rethread/render lifecycle through `visible-result`, zero
  Mail calls, and one normalized command. Its 33,583 ms duration remains
  `insufficient-evidence` and is diagnostic only because it was agent-assisted
  and represents one rehearsal, not a human timing stratum.

The guarded `script/run_organizer_human_trial.py` workflow is now ready for the
actual unaided session. It independently deep-strict-verifies both installed
targets, rejects ad-hoc or mismatched signed identifiers/bundle identifiers,
pins `TeamIdentifier=TN3L2WBKR5`, validates the exact certificate SHA-1 and
code-signing chain, and pins one executable SHA-256 per dated capture session.
It never sends UI input, refuses capture overwrites, requires cold/retrieval
prerequisites, and rejects a continuation whose mutable runtime report was not
rewritten. Its no-launch `preflight` phase exposes the exact installed signing,
chain-trust, stopped-host, and executable-hash gate without creating evidence.
Its local-only `aggregate-human` phase now retains pre-Ready invalid
rows outside the denominator, encodes post-Ready failures above threshold,
uses nearest-rank percentiles, separates all six frozen timing slices, and
validates a sanitized acceptance-status proposal without editing repository
results. It also binds setup evidence to the same app build, requires complete
ordered success lifecycles and successful retrieval prerequisites, and binds
the proposal to the exact frozen fixture and protocol. Twenty-nine focused
helper/aggregation tests, all thirteen adversarial benchmark validator tests,
and the complete frozen-contract validator pass. A live
real-keychain invocation of the no-launch `preflight` command passed for the
installed app and extension and reported executable SHA-256
`957ddef2d982efcb456361b83918ed976d8873dc79967b5604e97b214ceeef10`. No timed
trial was launched by this workflow verification, so the human denominators
remain zero.

The rehearsals exposed two operational hazards now addressed by
`../timed-human-runbook.md`: the source-row **Group** label does not mean move to
the frozen Group, and relaunching a run ID replaces its single
`OrganizerMetrics.json`. The runbook standardizes the correct visible actions,
untouched diagnostic prewarm for cold organization trials, capture-before-
relaunch sequence, exact five-item mapping, and post-commit/post-relaunch
retrieval accounting. No timed-human gate is advanced by this clarification.

## Source synchronization boundary

The source comparison must be refreshed immediately before a scoped success
conclusion. The final non-human milestone therefore records a closing
`git fetch origin` immediately before its conclusion. The owner excluded the
timed-human gate and the actual VoiceOver session from the revised goal; the
authorized disposable-route Mail move-and-restore is complete. The frozen v1
protocol therefore remains `insufficient-evidence`. No merge, rebase, or pull
is attempted in the dirty worktree.

## Graph centering and active-drag performance follow-up

The follow-up keeps `You` pinned to the scene midpoint and coalesces active-drag
rendering while pausing full-graph force simulation and deferring global
accessibility geometry refresh until release. The same deterministic
100-conversation, 120-pointer-event workload measured a 242.497 ms baseline and
a 13.111 ms final median, a 94.6 percent reduction. Full render passes changed
from 142 to 1, force steps from 30 to 0, and accessibility refreshes from 142 to
1. The logs are `/tmp/bettermail-drag-perf-baseline.log` and
`/tmp/xcodebuild-graph-fix-tests-final.log`.

This focused benchmark proves that retaining the drag-path change satisfies the
requested performance-improvement condition. It is engineering evidence for
the fixed workload, not a claim that every installed-app scene now sustains a
particular FPS.

## Implemented safety and workflow coverage

- The JSON organization ledger and Core Data use a deliberate write-ahead
  protocol rather than an impossible cross-store atomicity claim: a prepared
  record is durable first, one atomic BetterMail mutation follows, and
  fingerprinted `ledgerBoundary` recovery prevents duplicate application. The
  focused failure-injection suite covers failures on both sides of that
  boundary.
- Every production mailbox create/move/restore transport call is statically
  confined to `OrganizationMailGateway`; the source-tree invariant is tested.
- Mail accounts, mailbox paths, resolved identifiers, script previews, and
  error text are private OSLog fields. The raw debug mailbox-tree dump was
  removed. A production-source privacy scan now rejects these values if they
  regress to public interpolation or terminal output.
- Authorization denial is covered across every operation kind and every Mail
  effect, with zero transport calls and zero ledger writes required.
- Partial and unknown Mail outcomes cannot replay the same operation ID;
  compensation and restore IDs bind the exact residual route set.
- Relaunch converts an interrupted external Mail call to explicit manual
  recovery without replaying it.
- Queue-wide Approve All resolves duplicate-source conflicts deterministically
  and reports BetterMail-only and Apple Mail effects separately.
- Unified Organization History projects organizer, Mail, recovery, automation,
  and legacy actions; only completed manual Group/ungroup commands advertise
  command-service undo.

The signed focused follow-up at `/tmp/xcodebuild-goal-focused.log` executed 38
command-service, Mail-gateway/privacy, and graph-drag tests with zero failures.
The closed benchmark validator also passed after the scope and evidence updates.

## Authorized Apple Mail round trip

After the exact immutable one-message effect disclosure was staged, the user
gave explicit action-time approval for both the move and immediate restore. The
installed Snip workflow completed one Mail move, removed the conversation from
Unorganized, and recorded a completed Mail-moving History entry affecting one
message. The source-scoped Restore action then completed one Mail restore,
returned the conversation to Unorganized, displayed `Thread restored`, and
recorded a completed Apple Mail restoration affecting one message. A final
read-only Apple Mail inspection independently showed the restored message in
its original source mailbox under its original account.

The sanitized artifact
`authorized-mail-roundtrip-2026-08-30.md` records only action types, counts,
coarse outcomes, and the installed bundle path. It contains no subject, sender,
account, route, raw identifier, or message content.

## Revised goal and frozen-protocol status

- Task 7.7: owner-excluded in full; no warm/cold timing or retrieval trials are
  run, and none are claimed as passing.
- Task 7.8: the sanitized package records the exclusions and completed live Mail
  round trip without inventing human records; the privacy/pass-claim validator
  passes.
- Task 8.5: the non-VoiceOver installed interaction/AX checks are complete. The
  owner excluded only the actual VoiceOver session; the authorized
  disposable-route Apple Mail move-and-restore is complete.
- Task 8.7: the revised goal may close after every non-excluded gate is proven,
  while the frozen v1 acceptance status remains `insufficient-evidence` for the
  excluded timing and VoiceOver requirements.

The authoritative scope decision is
`revised-goal-scope-2026-08-30.md`. Exclusions are reported as exclusions, not
as evidence that the original hard gates passed.
