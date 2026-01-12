## MODIFIED Requirements
### Requirement: Thread Continuity Connectors
The system SHALL render vertical connector lanes between consecutive nodes in the same thread column. When a thread column represents a manual group that merges multiple JWZ sub-threads, the system SHALL render a separate connector lane for each JWZ sub-thread, with dynamic horizontal offsets based on layout metrics.

#### Scenario: Multi-day thread
- **WHEN** a thread has messages on multiple days
- **THEN** connector segments link the nodes in date order within that column

#### Scenario: Merged JWZ sub-threads
- **WHEN** a manual group contains messages from multiple JWZ thread IDs
- **THEN** each JWZ sub-thread renders its own connector lane with a distinct offset

#### Scenario: Grouping or ungrouping realigns connectors
- **WHEN** the user groups or ungroups messages
- **THEN** connector lanes are recalculated and offsets are realigned to the updated thread membership
