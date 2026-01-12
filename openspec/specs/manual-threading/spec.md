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

### Requirement: Manual Group Persistence
The system SHALL persist manual thread groups with a stable manual thread ID, an attached set of JWZ thread IDs, and the message keys manually attached to the group.

#### Scenario: Persist manual group
- **WHEN** the user groups messages manually
- **THEN** the manual group is stored with its manual thread ID, JWZ thread ID set, and manual message keys

### Requirement: Manual Override Migration
The system SHALL migrate existing manual overrides into manual group records on upgrade.

#### Scenario: Upgrade with existing overrides
- **WHEN** stored manual overrides are present during upgrade
- **THEN** the system creates manual groups that preserve the existing merged memberships and deletes legacy overrides

### Requirement: Grouping Rules
The system SHALL apply grouping rules based on the selected nodes’ current membership.

#### Scenario: Manual + manual
- **WHEN** the user groups two nodes that are each manually grouped (or standalone manual nodes)
- **THEN** a new manual group is created and the selected manual memberships are moved into it, preserving any attached JWZ thread IDs

#### Scenario: JWZ + JWZ
- **WHEN** the user groups two nodes that are only in JWZ threads
- **THEN** a manual group is created whose JWZ thread ID set is the union of both JWZ thread IDs

#### Scenario: JWZ + manual
- **WHEN** the user groups a JWZ-threaded node with a node in a manual group
- **THEN** the manual group absorbs the JWZ thread ID into its JWZ thread set

### Requirement: JWZ Set Merge on Refresh
The system SHALL treat a manual group’s JWZ thread ID set as the authoritative merge criteria for incoming JWZ-threaded messages.

#### Scenario: New message arrives
- **WHEN** a new message arrives that belongs to any JWZ thread ID in a manual group’s set
- **THEN** the message is assigned to the manual group during rethread

### Requirement: Manual Ungrouping
The system SHALL allow ungrouping only for manually attached messages and SHALL restore their JWZ-computed membership.

#### Scenario: Ungroup manual selection
- **WHEN** the user ungroup-selects manually attached nodes
- **THEN** only those nodes are detached from the manual group and revert to their JWZ thread, and a rethread is triggered immediately

