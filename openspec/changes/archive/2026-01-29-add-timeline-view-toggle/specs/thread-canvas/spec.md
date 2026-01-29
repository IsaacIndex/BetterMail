## ADDED Requirements
### Requirement: Thread Canvas View Modes
The system SHALL provide a navigation bar toggle to switch between Default View and Timeline View, SHALL default to Default View on first launch, and SHALL persist the last chosen view mode between app launches using display settings.

#### Scenario: Toggle between modes
- **WHEN** the user taps the view toggle in the navigation bar
- **THEN** the canvas switches between Default View and Timeline View without requiring a refresh

#### Scenario: Persisted view preference
- **WHEN** the user relaunches the app after selecting a view mode
- **THEN** the canvas starts in the previously selected view mode

## MODIFIED Requirements
### Requirement: Node Content and Selection
The system SHALL render each node with sender, a title line, and time; in Default View the title line SHALL be the message subject, and in Timeline View the title line SHALL be the message summary text when available, falling back to the subject when no summary text or status message exists. The system SHALL update the inspector panel when a node is selected. The inspector panel SHALL present a body preview trimmed to 10 lines with an ellipsis when the message body exceeds 10 lines, and SHALL provide an "Open in Mail" button to view the full message in Apple Mail.

#### Scenario: Default view title line
- **WHEN** Default View is active
- **THEN** each node shows the message subject as the title line along with sender and time

#### Scenario: Timeline view uses summary
- **WHEN** Timeline View is active and a node has summary text or a summary status message
- **THEN** the node shows that summary text as the title line while still showing sender and time

#### Scenario: Timeline view subject fallback
- **WHEN** Timeline View is active and a node has no summary text or status message
- **THEN** the node shows the subject as the title line

#### Scenario: Selecting a node
- **WHEN** the user clicks a node
- **THEN** the node is highlighted and the inspector panel shows that message's details with a 10-line body preview and an "Open in Mail" button

#### Scenario: Large body preview
- **WHEN** the selected message body exceeds 10 lines
- **THEN** the inspector preview shows the first 10 lines followed by an ellipsis and does not render the full body
