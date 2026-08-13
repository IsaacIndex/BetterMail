# backfill Specification

## Purpose

Provide explicit, exhaustive recovery for calendar days that may not have been fetched while BetterMail was closed, without treating an Apple Mail request batch size as a total email limit.

## Requirements

### Requirement: Exhaustive Calendar-Day Backfill

The system SHALL fetch a confirmed day or date range as sequential half-open calendar-day intervals through the shared day-fetch coordinator and SHALL impose no total message-count limit.

#### Scenario: Settings backfill uses inclusive dates

- **WHEN** the user runs Settings backfill for an inclusive start and end date
- **THEN** the system enumerates every non-future calendar day from the start through the end in the user's current calendar and timezone

#### Scenario: Visible risky range uses coverage state

- **WHEN** the visible canvas contains a day whose coverage is unknown, partial, or failed
- **THEN** the range backfill action includes that day even if cached messages already exist, and omits verified closed days

#### Scenario: One bulk confirmation

- **WHEN** the user starts a visible-range backfill
- **THEN** the system presents one editable range confirmation and does not prompt again for each day

#### Scenario: No total email limit

- **WHEN** a day contains more than four messages, including messages with the same received timestamp
- **THEN** an uncapped manifest discovers every message and payload requests proceed in 1–4-message batches until the manifest is exhausted

#### Scenario: Zero-message day

- **WHEN** an authoritative day manifest contains zero messages
- **THEN** the system records a successful complete or partial coverage row with zero expected, fetched, and absent messages

#### Scenario: Calendar boundaries

- **WHEN** a backfill crosses midnight or a daylight-saving transition
- **THEN** each interval uses calendar-derived day boundaries rather than an assumed 86,400-second duration

### Requirement: Authoritative Reconciliation

The system SHALL change cached source-presence state only after a second manifest matches the initial manifest for the same concrete account, mailbox, and day interval.

#### Scenario: Stable manifest

- **WHEN** both manifests match and every required payload is returned
- **THEN** returned messages are upserted, prior absence is cleared, cached messages absent from that concrete source interval are flagged and hidden, and day coverage records the absent count

#### Scenario: Mail changes during backfill

- **WHEN** the second manifest differs from the first
- **THEN** the system retries the day once, and if it changes again records a failed/incomplete attempt without committing staged payloads or changing absence flags

#### Scenario: Missing payload or cancellation

- **WHEN** an ID payload request is incomplete or the operation is cancelled between request batches
- **THEN** the system records failure/cancellation progress and leaves existing cached-message visibility unchanged

#### Scenario: Aggregate Inbox

- **WHEN** backfill targets Inbox across all accounts
- **THEN** every concrete account Inbox, including a zero-message Inbox, receives its own coverage row and the aggregate state reports the least-complete child scope

### Requirement: Settings Batch Controls and Progress

The system SHALL expose “Messages per Apple Mail request” as a persisted integer from 1 through 4 and SHALL explain that it is not a total limit.

#### Scenario: Progress and completion

- **WHEN** backfill runs
- **THEN** the UI reports manifest/payload progress, total processed messages, completion or failure, and any cached-message absence count while remaining responsive

#### Scenario: Stop backfill

- **WHEN** the user stops a running backfill
- **THEN** cancellation is observed between Apple Mail request batches and no non-authoritative reconciliation occurs

### Requirement: Re-GenAI Range Operation

The system SHALL retain the Settings Re-GenAI action for regenerating cached email and folder summaries over the chosen date range off the main actor.

#### Scenario: Re-GenAI completion

- **WHEN** Re-GenAI finishes
- **THEN** the UI reports the processed count and any remaining error while preserving completed progress
