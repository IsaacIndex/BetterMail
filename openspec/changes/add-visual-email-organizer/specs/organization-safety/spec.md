## ADDED Requirements

### Requirement: Visible Organization Effects
The system SHALL classify every organization command as BetterMail-only, Apple-Mail-changing, or mixed and SHALL display that effect before confirmation using consistent localized terminology.

#### Scenario: BetterMail-only Group action
- **WHEN** the user creates, adds to, removes from, or archives a BetterMail Group without a physical Mail move
- **THEN** the confirmation or action surface states that Apple Mail messages stay in place

#### Scenario: Apple Mail-changing action
- **WHEN** an action will Snip, Move, restore, or create a mailbox in Apple Mail
- **THEN** the preview identifies the affected message count, exact source account/mailbox routes, destination, and known reversibility limits

#### Scenario: Mixed operation separates phases
- **WHEN** an operation changes both BetterMail organization and Apple Mail
- **THEN** the UI distinguishes the BetterMail phase from the Apple Mail phase
- **AND** History reports each phase's actual state

### Requirement: Explicit Apple Mail Authorization
The system SHALL route every production Apple Mail mailbox creation, message move, and restore through one `OrganizationMailGateway` and SHALL NOT invoke that gateway without valid, current authorization produced by an explicit user-confirmation path for the disclosed effect.

#### Scenario: App-only command cannot mutate Mail
- **WHEN** Group, Unorganized, Graph Archive, spatial layout, suggestion review, or BetterMail-only queue actions execute
- **THEN** zero Apple Mail mailbox-creation, move, or restore calls occur

#### Scenario: Recommendation is not authorization
- **WHEN** a model, heuristic, automatic-mode flag, mailbox-mapping flag, refresh, or drop callback recommends a mailbox creation, physical move, or restore
- **THEN** it cannot construct Mail authorization
- **AND** the Mail mutation remains pending until the user confirms the disclosed effect or has separately granted current-version Mail-automation consent for that effect

#### Scenario: Exact routes are mandatory
- **WHEN** authorized Mail work begins
- **THEN** every affected message has an exact normalized identifier plus source account and mailbox route
- **AND** an unresolved or mismatched source stops that item for review instead of using a similarly named fallback

#### Scenario: Upgrade preserves safety
- **GIVEN** an existing installation has automatic organization enabled
- **WHEN** the authorization model is introduced
- **THEN** BetterMail-only automatic actions may continue
- **AND** legacy automatic and mailbox-mapping settings do not create Mail consent
- **AND** physical Mail mutation remains off until separate current-version consent is granted

#### Scenario: Consent schema defaults safely
- **WHEN** Mail-automation consent is absent, disabled, revoked, or has an unknown schema version
- **THEN** automatic mailbox creation, move, and restore remain off
- **AND** proposal evaluation presents the pending effect for review rather than calling Mail

#### Scenario: Consent revocation has deterministic boundaries
- **WHEN** the user revokes Mail-automation consent
- **THEN** new and prepared-but-not-started Mail phases are blocked
- **AND** an already-running external call may only finish into a recorded receipt, partial, or recovery state
- **AND** it is never implicitly repeated

#### Scenario: Exhaustive call-site matrix
- **WHEN** the authorization regression suite exercises every inventoried production Mail mutator
- **THEN** each mailbox creation, move, and restore reaches the shared gateway
- **AND** no direct bypass remains in a view model, automation coordinator, Mail service, retry, or recovery path

### Requirement: Durable Organization Lifecycle
The system SHALL persist every organization operation through a durable lifecycle that distinguishes prepared BetterMail work, applied BetterMail work, pending spatial receipt, Mail work, completion, partial failure, recovery, and undo.

#### Scenario: BetterMail delta and prepared record are crash-consistent
- **WHEN** a BetterMail organization command commits
- **THEN** its prepared operation record is durable before one atomic BetterMail membership transaction begins
- **AND** a failure before the BetterMail commit leaves a recoverable prepared record with no membership change
- **AND** a failure after the BetterMail commit resumes from fingerprints without applying the same delta twice or showing a falsely completed History row
- **AND** the system does not claim that the separate JSON ledger and Core Data stores commit atomically

#### Scenario: App terminates before Mail work finishes
- **GIVEN** BetterMail state committed but authorized Mail work did not complete
- **WHEN** the app relaunches
- **THEN** History shows Resume, Retry, or Recovery as appropriate
- **AND** does not report the operation as fully completed

#### Scenario: App terminates before spatial receipt
- **GIVEN** semantic Group state committed with an anchor intent but the separate spatial file did not record the anchor
- **WHEN** the app relaunches
- **THEN** recovery replays the idempotent anchor intent and records its receipt
- **AND** does not duplicate or roll back the committed Group

#### Scenario: Partial Mail failure retains exact residuals
- **WHEN** only some exact message moves succeed
- **THEN** the ledger records receipts, compensation results, and remaining exact routes
- **AND** Retry operates only on unresolved residuals

### Requirement: Unified Conditional Undo and Recovery
The system SHALL present manual Group changes, suggestion acceptance, Graph Archive, Snip, explicit Mail moves, mapped automation, mailbox creation, retry, and recovery through one organization History vocabulary, while applying operation-specific conditional inverse rules.

#### Scenario: Undo preserves later edits
- **GIVEN** an organization result was changed by a later unrelated user edit
- **WHEN** the user requests Undo
- **THEN** the system validates current fingerprints and membership
- **AND** presents review/retry instead of overwriting the later edit

#### Scenario: Archive remains BetterMail-only
- **WHEN** Graph Archive or Restore executes
- **THEN** only the Graph Archive record changes
- **AND** Apple Mail locations remain untouched

#### Scenario: Snip recovery survives relaunch
- **GIVEN** a Snip move is partial or its restore is incomplete
- **WHEN** BetterMail relaunches
- **THEN** the exact recovery state and Retry Restore action remain available

#### Scenario: Dismiss does not destroy recovery evidence
- **WHEN** the user dismisses a History row
- **THEN** it may be hidden from the current view
- **AND** its durable operation and unresolved recovery state are not deleted

### Requirement: Reviewable Suggestions
The system SHALL show each suggested organization with rationale, confidence or provenance, complete affected-member count, editable member list, current and proposed destination, last-evaluated state, and visible organization effect before any required approval.

#### Scenario: Inline preview predicts impact
- **WHEN** a suggested Group or automation proposal appears in Organize
- **THEN** its compact surface shows why, how many conversations are affected, where they are now, where they would go, when it was evaluated, and whether Apple Mail changes

#### Scenario: Detailed review remains editable
- **WHEN** the user opens the suggestion details
- **THEN** the complete member list and valid Group name can be edited before confirmation
- **AND** excluded members are not mutated

#### Scenario: Rejection choices remain distinct
- **WHEN** the user chooses Not this Group or Hide this topic
- **THEN** the system records the distinct intent
- **AND** exposes undo where supported without treating rejection as a Mail mutation

#### Scenario: AI is unavailable
- **WHEN** Foundation Models or an AI provider is unavailable
- **THEN** manual search, selection, grouping, Archive, Move, and History remain functional
- **AND** any deterministic heuristic candidate is labeled review-only with its provenance

### Requirement: Queue-Wide Approval Semantics
The system SHALL define queue-wide Approve All as an operation over every proposal pending at invocation time and SHALL present conflicts and Mail-changing effects rather than silently omitting them.

#### Scenario: Mixed queue impact confirmation
- **GIVEN** the pending queue contains BetterMail-only and Apple-Mail-changing proposals
- **WHEN** the user invokes Approve All
- **THEN** the confirmation separates the two counts and destinations
- **AND** Mail-changing proposals require valid Mail authorization before execution

#### Scenario: Duplicate-source proposals are explicit
- **GIVEN** more than one pending proposal affects the same effective source
- **WHEN** Approve All plans the batch
- **THEN** the proposals are deterministically resolved or remain visible as conflict/pending
- **AND** no conflict is silently skipped or counted as approved

### Requirement: Recoverable Mailbox Creation and Move
The system SHALL represent create-mailbox-and-move as a durable mixed operation whose UI states that external mailbox creation may remain even when later message movement fails.

#### Scenario: Feature remains disabled
- **GIVEN** create-and-move is not enabled in production
- **WHEN** the Move sheet is presented
- **THEN** it does not advertise an unavailable Create Folder success path

#### Scenario: Re-enabled flow reports irreversible state
- **WHEN** an explicitly authorized create-and-move operation creates the Apple Mail mailbox but the message move fails
- **THEN** History records the created mailbox and failed move separately
- **AND** provides recovery without claiming the external mailbox was rolled back

### Requirement: Organization Privacy
The system SHALL keep organizer telemetry and shareable artifacts free of raw subject, sender, body, snippet, account name, mailbox path, message identifier, and provider prompt data; SHALL use per-install opaque fingerprints for non-executable identity; and SHALL minimize persisted raw semantic inputs to what is necessary for local review, exact authorized recovery, and stale-state validation.

#### Scenario: Metrics record aggregate evidence
- **WHEN** organizer metrics record a session or action
- **THEN** they store only aggregate counts, durations, status, coarse action type, and non-reversible correlation values

#### Scenario: Legacy semantic payload cannot migrate safely
- **WHEN** an existing automation payload is malformed or cannot be minimized safely
- **THEN** it is retained in a quarantined recoverable state
- **AND** is not silently discarded or executed

#### Scenario: Exact recovery routes are protected and expire
- **WHEN** an operation requires exact Mail routes for execution, undo, or recovery
- **THEN** those routes are encrypted at rest with a Keychain-held key and accessible only through the operation store and Mail gateway
- **AND** completed or undone terminal routes are redacted after 30 days while aggregate effect/status data may remain
- **AND** unresolved routes remain only until resolution or explicit deletion with a recovery warning

#### Scenario: Route-encryption key is unavailable
- **GIVEN** an unresolved operation has an encrypted Mail-route envelope
- **WHEN** the original route-encryption key is unavailable during migration, relaunch, retry, or recovery
- **THEN** the operation enters a visible fail-closed recovery state
- **AND** the encrypted envelope is preserved byte-for-byte
- **AND** no replacement key is used for that envelope, no Mail work executes or repeats, and the operation is not marked complete
- **AND** explicit deletion warns that recovery will be lost

#### Scenario: Shareable artifact excludes sensitive organization data
- **WHEN** benchmark, history, diagnostics, or acceptance evidence is exported or committed as a shareable artifact
- **THEN** it contains no raw semantic content, exact Mail route, raw identifier, authorization token, or encryption key

#### Scenario: Logs protect identifiers and routes
- **WHEN** organization or Mail operations emit OSLog entries
- **THEN** message, thread, account, and mailbox identifiers are private or omitted
