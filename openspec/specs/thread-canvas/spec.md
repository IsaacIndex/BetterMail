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
The system SHALL render each node with sender, subject, and time, and SHALL update the inspector panel when a node is selected.

#### Scenario: Selecting a node
- **WHEN** the user clicks a node
- **THEN** the node is highlighted and the inspector panel shows that message's details

### Requirement: Navigation and Zoom
The system SHALL support two-axis scrolling and zoom with clamped limits for readability.

#### Scenario: Navigating the canvas
- **WHEN** the user scrolls or zooms
- **THEN** the canvas pans on both axes and scales within defined minimum and maximum zoom levels

### Requirement: Thread Continuity Connectors
The system SHALL render vertical connectors between consecutive nodes in the same thread column.

#### Scenario: Multi-day thread
- **WHEN** a thread has messages on multiple days
- **THEN** connector segments link the nodes in date order within that column

### Requirement: Canvas Accessibility
The system SHALL expose nodes as accessibility elements and day bands as accessibility headers.

#### Scenario: VoiceOver navigation
- **WHEN** VoiceOver is enabled
- **THEN** users can navigate day headers and hear each node's sender, subject, and time

