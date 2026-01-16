# backfill Specification

## Purpose
TBD - created by archiving change add-settings-batch-backfill. Update Purpose after archive.
## Requirements
### Requirement: Settings Batch Backfill
The system SHALL provide a Settings action to run a batch backfill for the currently selected mailbox over a user-chosen date range (defaulting to January 1 of the current year through today on each invocation) and execute ingestion off the main actor.

#### Scenario: User starts backfill with defaults
- **WHEN** the user opens Settings and taps "Run Backfill" without changing dates
- **THEN** the date range defaults to January 1 of the current year through today and backfill begins for the currently selected mailbox

#### Scenario: Progress reflects counting and batches
- **WHEN** backfill runs
- **THEN** the UI shows counting state, total message count once known, per-batch progress, and a status string for the active batch

#### Scenario: Retry with smaller batches on failure
- **WHEN** a batch of 5 fails to import
- **THEN** the system retries that range by splitting into smaller batches (<5) until success or a single-message failure is identified

#### Scenario: Completion states
- **WHEN** backfill finishes
- **THEN** the UI shows success with total imported messages; if failures remain, it shows the error while preserving progress achieved

#### Scenario: UI remains responsive
- **WHEN** backfill is running
- **THEN** the work occurs on a side actor and the app UI remains responsive, with UI updates marshaled on the main actor

