# auto-refresh Specification

## Purpose
Define configurable automatic refresh behavior while ensuring startup, manual, and scheduled refreshes exhaustively discover today's messages without imposing a total email limit.
## Requirements
### Requirement: Auto Refresh Configuration
The system SHALL persist user-configured auto refresh settings including an enabled toggle and a refresh interval, with defaults of disabled and 300 seconds.

#### Scenario: Default settings
- **WHEN** the app launches with no prior user settings
- **THEN** auto refresh is disabled and the interval is 300 seconds

#### Scenario: User updates settings
- **WHEN** the user enables auto refresh or changes the interval in Settings
- **THEN** the new values are persisted and used by the refresh scheduler

### Requirement: Refresh Timing Status
The system SHALL display the last refresh time and, when auto refresh is enabled, the next scheduled refresh time in the thread list header.

#### Scenario: Manual refresh completed
- **WHEN** a refresh completes successfully
- **THEN** the header shows the last updated time

#### Scenario: Auto refresh enabled
- **WHEN** auto refresh is enabled with a valid interval
- **THEN** the header shows the next scheduled refresh time

### Requirement: Exhaustive Today Refresh
Startup, manual, and automatic refreshes SHALL use the shared day-fetch coordinator to refresh the current calendar day for the active mailbox source. The coordinator SHALL enumerate an uncapped manifest for the half-open interval from the start of today through the fetch boundary and SHALL fetch payloads in Apple Mail requests of 1 through 4 messages without imposing a total message limit.

#### Scenario: More messages than one Apple Mail request
- **GIVEN** more than four messages exist in today's active mailbox scope
- **WHEN** startup, manual, or automatic refresh runs
- **THEN** every manifest entry is discovered and payload requests continue in batches until the required messages have been processed

#### Scenario: Aggregate Inbox refresh
- **GIVEN** the active source is an aggregate mode
- **WHEN** today's refresh resolves its mailbox scope
- **THEN** Inbox is enumerated across every Mail account rather than selecting only the first account

#### Scenario: Selected folder refresh
- **GIVEN** the active source is a selected Mail folder
- **WHEN** today's refresh resolves its mailbox scope
- **THEN** only the exact account and mailbox path are refreshed

#### Scenario: Open-day coverage
- **WHEN** today's refresh completes successfully before the day ends
- **THEN** coverage is recorded as successfully covered through the fetch boundary and remains partial rather than claiming the full day is closed

### Requirement: Authoritative Refresh Reconciliation
The system SHALL verify today's manifest again before final reconciliation. It SHALL retry the fetch once when the manifest changes during the operation, and otherwise record an incomplete attempt without committing staged payloads or changing source-absence flags.

#### Scenario: Stable manifest
- **WHEN** both manifest reads identify the same messages and all required payloads succeed
- **THEN** returned messages are upserted, reappearing messages have source absence cleared, and cached messages missing from the authoritative scope and interval are flagged as absent

#### Scenario: Unstable manifest after retry
- **WHEN** the manifest remains unstable after one retry
- **THEN** the attempt is recorded as incomplete and cached messages and existing absence flags remain unchanged

#### Scenario: Payload failure or cancellation
- **WHEN** a payload request fails or the operation is cancelled between request batches
- **THEN** no reconciliation occurs and existing cached-message absence state remains unchanged

### Requirement: Refresh Scope and Recovery Policy
Automatic recovery SHALL cover today only. Past unknown, partial, or failed days SHALL remain user-triggered through the coverage calendar or batch backfill. The legacy `lastSyncDate` preference SHALL be retained for compatibility but SHALL NOT be read or advanced for fetch correctness.

#### Scenario: App reopens after missed days
- **GIVEN** the app was closed during one or more prior days
- **WHEN** the app launches
- **THEN** it refreshes today only and leaves prior risky days available for explicit recovery

#### Scenario: Legacy checkpoint exists
- **GIVEN** `lastSyncDate` contains a value from an older app version
- **WHEN** refresh coverage is evaluated
- **THEN** the value neither limits today's enumeration nor marks historical days as covered

### Requirement: Refresh Responsiveness
The system SHALL keep refresh heavy work off the main actor while applying UI-facing state on the main actor.

#### Scenario: Background refresh execution
- **WHEN** a refresh rebuilds threads and generates summaries
- **THEN** thread reconstruction and summary generation run in detached background tasks that do not inherit `@MainActor`, and roots, unread totals, status, and summary state are updated on the main actor only.

#### Scenario: Initial refresh on start
- **WHEN** the app initializes and triggers its first refresh
- **THEN** the initial threading and summary work run in detached background tasks with UI state changes (roots, unread totals, status, summaries, `isRefreshing`) applied on the main actor.

#### Scenario: Refresh flag reset
- **WHEN** a refresh completes, fails, or exits early
- **THEN** `isRefreshing` is set to `false` on the main actor so subsequent refreshes are unblocked.
