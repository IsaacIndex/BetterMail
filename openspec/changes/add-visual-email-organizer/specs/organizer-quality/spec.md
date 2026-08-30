## ADDED Requirements

### Requirement: Reproducible Organizer Evidence
The system SHALL keep versioned anonymized fixtures under `Tests/Fixtures/Organizer/`, exact benchmark manifests and instructions under `docs/acceptance/visual-email-organizer/`, and sanitized result artifacts under `docs/acceptance/visual-email-organizer/results/`. Evidence SHALL distinguish automated logic, build, installed-app launch, live pointer interaction, accessibility, and timed human-task results.

#### Scenario: Evidence types are reported accurately
- **WHEN** an acceptance report is produced
- **THEN** it identifies the fixture, app build, benchmark protocol, metric schema, and evidence type for every result
- **AND** does not claim build success, process survival, deterministic tests, or provider confidence as proof of human task speed or visual usability

#### Scenario: Sensitive data is absent
- **WHEN** a fixture, metric export, screenshot note, sanitized Mail-boundary audit, or benchmark result is shared
- **THEN** it contains no raw personal email content, sender identity, account name, mailbox path, message/thread identifier, authorization token, exact recovery route, encryption key, or provider prompt

### Requirement: Timed Trial Contract
The system SHALL use `ContinuousClock` monotonic instants and a frozen benchmark manifest to define task-ready, action, commit, rethread, visible-result, search-start, retrieval-visible, cancellation, and failure events. P80 SHALL be the sole contractual percentile for the two organization-time targets; median and P90 SHALL be reported as diagnostics only.

#### Scenario: Valid and failed trials are counted consistently
- **WHEN** a task fixture and instructions become fully rendered and interactive
- **THEN** the task-ready event starts the relevant organization timer
- **AND** user cancellation, action failure, wrong completion, or app termination counts as a failed over-threshold trial rather than being excluded

#### Scenario: Invalid trial is narrowly defined
- **WHEN** fixture or instrumentation failure occurs before task-ready and prevents a task from starting
- **THEN** the trial is marked invalid with an exact reason and rerun
- **AND** invalid trials remain disclosed in the result artifact

#### Scenario: Warm and cold strata remain separate
- **WHEN** a timed result is calculated
- **THEN** warm and cold/relaunch trials are reported and gated separately
- **AND** aggregation cannot hide a failing stratum

### Requirement: First Organization Time Target
The system SHALL benchmark the exact conversation and destination declared in the frozen manifest, starting at task-ready and stopping only when the intended first Group assignment is persisted, rethreaded, and visibly plus accessibly confirmed.

#### Scenario: First organization gate
- **GIVEN** at least 20 trials split evenly between declared warm and cold/relaunch strata
- **WHEN** first-organization duration is calculated
- **THEN** each stratum reports median, P80, and P90
- **AND** P80 in each stratum is no more than 30 seconds

### Requirement: Five-Conversation Organization Time Target
The system SHALL benchmark the five exact effective conversations and known destinations declared in the frozen manifest and SHALL stop only when all five intended assignments are persisted, rethreaded, visibly confirmed, and one declared retrieval check succeeds.

#### Scenario: Five-conversation gate
- **GIVEN** at least 20 trials split evenly between declared warm and cold/relaunch strata
- **WHEN** complete task duration is calculated
- **THEN** each stratum reports median, P80, and P90
- **AND** P80 in each stratum is no more than 120 seconds

### Requirement: Drop Reliability Target
The system SHALL count a drop as successful only when the intended eligible target is visibly highlighted before release, exactly one normalized command occurs, the intended BetterMail destination persists, and no unauthorized Mail mutation occurs.

#### Scenario: Deterministic drop matrix gate
- **GIVEN** 120 attempts comprising 10 attempts in every combination of 100/500 nodes, low/medium/high zoom, and flat/nested Group target, with half of each stratum using long labels
- **WHEN** target geometry, callback count, and persisted outcome are evaluated
- **THEN** at least 95 percent succeed overall
- **AND** at least 90 percent succeed in every stratum
- **AND** invalid, cancelled, ghost-target, and virtual-target attempts produce zero membership mutation

#### Scenario: Installed-app pointer drop gate
- **GIVEN** at least 40 live installed-app pointer attempts covering single and multi-selection, both scale fixtures, every zoom band, flat and nested Groups, and long labels
- **WHEN** the recorded highlight, release, and persisted outcome are adjudicated
- **THEN** at least 95 percent succeed
- **AND** each failed attempt remains visible in the result artifact

### Requirement: Wrong Placement Target
The system SHALL classify BetterMail membership errors separately from Apple Mail account/source/destination route errors and SHALL count any partial or unresolved operation that was presented as completed as a wrong placement.

#### Scenario: Five independent placement sets
- **GIVEN** five independent sets of 20 intended completed placements executed through the live installed Organize surface on the frozen fixtures
- **WHEN** persisted BetterMail state and authorized Apple Mail receipts are compared with fixture truth
- **THEN** every set contains no more than one wrong placement
- **AND** a good aggregate cannot hide a set that exceeds the limit

#### Scenario: Cancellation and partial outcome accounting
- **WHEN** an attempt is cancelled before mutation
- **THEN** it is reported as an unsuccessful attempt but not a wrong persisted placement
- **AND** any unintended, partial, unresolved, or incorrectly routed mutation is counted as wrong in its applicable BetterMail and/or Apple Mail category

### Requirement: Suggestion Precision Target
The system SHALL measure suggestion precision against frozen, anonymized, balanced, structurally separate provider-input and evaluator-only gold artifacts rather than provider confidence or deterministic provider doubles. Provider input SHALL contain production-relevant synthetic evidence and opaque keys assigned before adjudication, predictions SHALL bind the SHA-256 digest of the exact provider-input bytes, and the sanitized report SHALL pin corpus, provider/model, prompt/policy, strictness, app-build, evidence origin, and input/gold digests; deduplicate effective sources; and disclose coverage plus abstention.

#### Scenario: Precision and coverage gates
- **GIVEN** at least 200 labeled candidate decisions balanced across attach, append, unrelated, confidence bands, and provenance
- **AND** at least 100 accepted or auto-applied decisions overall
- **AND** at least 25 accepted placements in every attach, append, confidence-band, and provenance slice
- **AND** at least 25 non-abstained decisions in the unrelated relation slice, whose gold outcomes are rejections
- **WHEN** precision is calculated as correct accepted or auto-applied placements divided by all accepted or auto-applied placements
- **THEN** overall precision is at least 80 percent
- **AND** conservative mode precision is at least 85 percent
- **AND** overall non-abstained coverage is at least 50 percent

#### Scenario: Unrelated negative controls do not reward false positives
- **GIVEN** a candidate adjudicated as unrelated
- **WHEN** the provider rejects it
- **THEN** the decision contributes to the unrelated non-abstained denominator without creating an accepted placement
- **AND** any accepted destination is counted as a false positive rather than qualifying the corpus by construction

#### Scenario: Provider input and gold remain structurally separate
- **WHEN** the three acceptance artifacts are loaded
- **THEN** unknown fields or any gold/evaluation field in provider input make the evidence insufficient
- **AND** a prediction-input digest mismatch, malformed artifact, identity mismatch, non-opaque key, invalid adjudication, or invalid decision shape makes the evidence insufficient

#### Scenario: Insufficient denominator is not a pass
- **WHEN** corpus size, accepted denominator, per-slice denominator, version metadata, or coverage is below the required contract
- **THEN** the result is reported as insufficient evidence
- **AND** is not counted as satisfying the target

#### Scenario: Duplicate-source candidate is counted once
- **WHEN** multiple proposals target the same effective source in one evaluation batch
- **THEN** the corpus adjudicates one intended mutation or an explicit conflict
- **AND** silent deduplication cannot inflate precision or reduce the denominator

### Requirement: Organized Mail Retrieval Target
The system SHALL measure the fixed query declared in the benchmark manifest from the search-start event until the correct previously organized effective conversation is both visible in the active Organize viewport/rail and selectable through the accessibility model.

#### Scenario: Retrieval gate after commit and relaunch
- **GIVEN** at least 20 post-commit trials and at least 20 post-relaunch trials
- **WHEN** retrieval durations are evaluated
- **THEN** at least 95 percent of trials in each stratum complete within 5 seconds
- **AND** failed, wrong-result, cancelled, and crashed trials count as misses

### Requirement: Zero Silent Apple Mail Mutations Target
The system SHALL treat any production Apple Mail mailbox creation, message move, or restore call without valid disclosed current authorization as a release-blocking failure.

#### Scenario: Authorization invariant gate
- **WHEN** every Group, Archive, suggestion, automation, queue, drag/drop, Move, Snip, restore, mailbox-create, retry, recovery, startup, and proposal-evaluation entry point is exercised with a Mail spy
- **THEN** app-only and unauthorized paths make zero Apple Mail calls
- **AND** every authorized call contains the exact disclosed effect and message/source/destination routes applicable to that operation

#### Scenario: Live audit agrees with automated evidence
- **WHEN** the installed-app benchmark completes
- **THEN** its operation ledger and sanitized Mail-boundary log contain no undisclosed physical Mail mutation
- **AND** any mismatch blocks acceptance

### Requirement: Installed-App Acceptance
The system SHALL be built, installed at the configured local application path, registered, launched, and exercised through the rendered Organize surface before the change is declared complete. Because the project currently has no XCUITest target, pure accessibility-descriptor tests SHALL be paired with a named live installed-app accessibility audit rather than described as automated UI proof.

#### Scenario: Build and installed bundle both pass
- **WHEN** delivery validation runs
- **THEN** the full build log is captured in `/tmp/xcodebuild.log`
- **AND** the installed `/Users/isaacibm/Applications/BetterMail.app` launches and survives the required process check

#### Scenario: Live interaction and accessibility checklist passes
- **WHEN** the installed app is exercised using the versioned protocol
- **THEN** mode migration, rail/canvas synchronization, search, selection, lasso, batch drop, empty-canvas Group creation, relaunch layout restore, suggestion review, effect disclosure, authorization, undo/recovery, narrow-width layout, keyboard, VoiceOver roles/actions, and opaque stable accessibility identifiers are visibly verified
- **AND** no bottom overlay obstructs a required control or target

#### Scenario: Unmeasured human target remains pending
- **WHEN** required live or timed benchmark evidence is unavailable
- **THEN** the corresponding task and target remain explicitly pending
- **AND** the implementation is not described as meeting that target
