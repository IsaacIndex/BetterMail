# auto-refresh Specification

## Purpose
TBD - created by archiving change add-auto-refresh-settings. Update Purpose after archive.
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

