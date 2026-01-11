# manual-threading Specification

## Purpose
TBD - created by archiving change add-manual-thread-overrides. Update Purpose after archive.
## Requirements
### Requirement: Persisted Manual Thread Overrides
The system SHALL persist a manual override mapping from normalized message ID to a target JWZ thread ID.

#### Scenario: Grouping messages
- **WHEN** the user groups selected messages into a target thread
- **THEN** overrides are stored for each selected message with the target JWZ thread ID

### Requirement: Override Application During Rethread
The system SHALL apply manual overrides after JWZ threading so that overridden messages are assigned to the target JWZ thread and thread metadata reflects the merged group.

#### Scenario: Refresh after grouping
- **WHEN** a refresh rebuilds threads
- **THEN** messages with overrides are assigned to the target JWZ thread and the merged thread updates counts and last activity

### Requirement: Ungroup Restores JWZ Threads
The system SHALL remove manual overrides for selected messages and restore their JWZ-computed thread membership immediately.

#### Scenario: Ungroup selected messages
- **WHEN** the user triggers ungroup on selected messages
- **THEN** overrides are deleted and the next rethread restores their JWZ threads

