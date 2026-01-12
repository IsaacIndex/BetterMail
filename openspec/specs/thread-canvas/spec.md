# thread-canvas Specification

## Purpose
TBD - created by archiving change add-thread-canvas-ui. Update Purpose after archive.
## Requirements
### Requirement: Thread Canvas Axes
The system SHALL render emails on a canvas where the vertical axis represents day buckets and the horizontal axis represents thread columns.

#### Scenario: Day and thread mapping
- **WHEN** the canvas is displayed
- **THEN** each email node is positioned in the day bucket matching its message date and in the column for its thread

### Requirement: Default Range and Column Order
The system SHALL default the canvas to the most recent 7 days and SHALL order thread columns by most recent activity.

#### Scenario: Default range and ordering
- **WHEN** the canvas loads
- **THEN** day bands cover the last 7 days and thread columns are ordered by latest message date

### Requirement: Node Content and Selection
The system SHALL render each node with sender, subject, and time, and SHALL update the inspector panel when a node is selected. The inspector panel SHALL present a body preview trimmed to 10 lines with an ellipsis when the message body exceeds 10 lines, and SHALL provide an "Open in Mail" button to view the full message in Apple Mail.

#### Scenario: Selecting a node
- **WHEN** the user clicks a node
- **THEN** the node is highlighted and the inspector panel shows that message's details with a 10-line body preview and an "Open in Mail" button

#### Scenario: Large body preview
- **WHEN** the selected message body exceeds 10 lines
- **THEN** the inspector preview shows the first 10 lines followed by an ellipsis and does not render the full body

### Requirement: Navigation and Zoom
The system SHALL support two-axis scrolling and zoom with clamped limits for readability.

#### Scenario: Navigating the canvas
- **WHEN** the user scrolls or zooms
- **THEN** the canvas pans on both axes and scales within defined minimum and maximum zoom levels

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

### Requirement: Canvas Accessibility
The system SHALL expose nodes as accessibility elements and day bands as accessibility headers.

#### Scenario: VoiceOver navigation
- **WHEN** VoiceOver is enabled
- **THEN** users can navigate day headers and hear each node's sender, subject, and time

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

