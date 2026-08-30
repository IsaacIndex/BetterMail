## MODIFIED Requirements

### Requirement: Thread Canvas View Modes
The system SHALL provide a navigation bar presentation control for Default, Timeline, and Organize. It SHALL default to Default on first launch and persist the last chosen presentation using display settings. Default and Timeline SHALL continue to use the same two-axis canvas renderer and data source so thread columns, manual group connectors, and folder backgrounds/adjacency render identically, with Timeline applying only its existing styling/legend overlays. Organize SHALL use the active Obsidian graph renderer beside the scoped Unorganized rail and SHALL share mailbox scope, search, and effective-conversation selection with the other presentations. The existing persisted internal `.graph` value SHALL migrate to the user-facing Organize presentation without resetting other graph settings.

#### Scenario: Toggle between modes
- **WHEN** the user changes between Default and Timeline
- **THEN** the shared canvas switches styling without requiring a mailbox refresh

#### Scenario: Enter Organize
- **WHEN** the user chooses Organize
- **THEN** the Unorganized rail and active Obsidian graph canvas appear
- **AND** active mailbox scope, search query, and valid effective-conversation selection remain unchanged

#### Scenario: Persisted view preference
- **WHEN** the user relaunches the app after selecting a presentation
- **THEN** the app starts in that presentation
- **AND** a previously stored `.graph` value starts in Organize

#### Scenario: Timeline reuses canvas and honors grouping
- **WHEN** the user switches to Timeline
- **THEN** manual thread group connectors, JWZ thread columns, and folder backgrounds/adjacency remain present as in Default, with only timeline-specific overlays changing

#### Scenario: Organize does not redefine canvas drag semantics
- **WHEN** the user returns from Organize to Default or Timeline
- **THEN** the existing custom thread-canvas single-drag, drag-out-to-remove, nested-target, and highlight behavior remains unchanged
- **AND** Organize-specific lasso, multi-drag, and empty-canvas Group creation remain owned by the Organize surface
