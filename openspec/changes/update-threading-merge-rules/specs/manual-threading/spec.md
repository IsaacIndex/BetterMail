## ADDED Requirements
### Requirement: Manual Group Persistence
The system SHALL persist manual thread groups with a stable manual thread ID, an attached set of JWZ thread IDs, and the message keys manually attached to the group.

#### Scenario: Persist manual group
- **WHEN** the user groups messages manually
- **THEN** the manual group is stored with its manual thread ID, JWZ thread ID set, and manual message keys

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
- **THEN** only those nodes are detached from the manual group and revert to their JWZ thread
