## MODIFIED Requirements
### Requirement: Thread Canvas View Modes
The system SHALL provide a navigation bar toggle to switch between Default View and Timeline View, SHALL default to Default View on first launch, and SHALL persist the last chosen view mode between app launches using display settings. Both view modes SHALL use the same two-axis canvas renderer and data source so thread columns, manual group connectors, and folder backgrounds/adjacency are rendered identically, with Timeline View applying only styling/legend overlays (e.g., time labels or tags) on top of the shared canvas.

#### Scenario: Toggle between modes
- **WHEN** the user taps the view toggle in the navigation bar
- **THEN** the canvas switches between Default View and Timeline View without requiring a refresh

#### Scenario: Persisted view preference
- **WHEN** the user relaunches the app after selecting a view mode
- **THEN** the canvas starts in the previously selected view mode

#### Scenario: Timeline reuses canvas and honors grouping
- **WHEN** the user switches to Timeline View
- **THEN** manual thread group connectors, JWZ thread columns, and folder backgrounds/adjacency remain present as in Default View, with only timeline-specific overlays changing
