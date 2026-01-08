## ADDED Requirements
### Requirement: Manual Thread Grouping Controls
The system SHALL support multi-select with Cmd+click and SHALL present a bottom action bar when two or more nodes are selected, offering actions to group into a target thread or ungroup manual overrides.

#### Scenario: Multi-select action bar
- **WHEN** the user Cmd+clicks to select two or more nodes
- **THEN** a bottom action bar appears with "Group" and "Ungroup" actions, and the last clicked node is treated as the target thread

### Requirement: Thread Source Visualization
The system SHALL distinguish JWZ-derived thread connectors from manual override connectors using distinct colors, with JWZ connectors rendered as solid lines and manual override connectors rendered as dotted lines.

#### Scenario: Manual connector styling
- **WHEN** a connector represents a manual override relationship
- **THEN** it renders as a dotted line using the manual thread color while JWZ connectors remain solid
