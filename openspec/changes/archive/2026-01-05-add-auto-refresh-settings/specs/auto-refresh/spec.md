## ADDED Requirements
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
