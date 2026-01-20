## MODIFIED Requirements
### Requirement: Default Range and Column Order
The system SHALL default the canvas to the most recent 7 days, SHALL order thread columns by most recent activity, and SHALL allow the day range to expand in 7-day increments using cache-only paging when the user scrolls downward. Scroll detection SHALL be driven by GeometryReader updates of the canvas content frame so two-axis scrolling can still trigger paging. When threads belong to a folder, the system SHALL order the folder as a unit by the folder's most recent activity and SHALL keep member threads adjacent horizontally.

#### Scenario: Default range and ordering
- **WHEN** the canvas loads
- **THEN** day bands cover the last 7 days and thread columns are ordered by latest message date, with foldered threads ordered by their folder's latest date

#### Scenario: Folder adjacency
- **WHEN** multiple threads belong to the same folder
- **THEN** those threads are laid out in adjacent horizontal columns

#### Scenario: Cache-only paging
- **WHEN** the user scrolls near the end of the current day range
- **THEN** the canvas expands by the next 7-day block using cached messages only

#### Scenario: Two-axis scroll detection
- **WHEN** the user scrolls the canvas vertically or diagonally
- **THEN** GeometryReader content-frame updates drive the scroll position used for paging

### Requirement: Manual Thread Grouping Controls
The system SHALL support multi-select with Cmd+click and SHALL present a bottom action bar when one or more nodes are selected, offering actions to group into a target thread, add to folder, or ungroup manual overrides.

#### Scenario: Multi-select action bar
- **WHEN** the user Cmd+clicks to select one or more nodes
- **THEN** a bottom action bar appears with "Group", "Add to Folder", and "Ungroup" actions, and the last clicked node is treated as the target thread
