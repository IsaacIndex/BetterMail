## ADDED Requirements
### Requirement: Folder Header Jump Actions
The system SHALL provide two icon-only action buttons in the footer row of each folder header block on the thread canvas: one to jump to the latest email node in that folder and one to jump to the first email node in that folder. Each button SHALL expose tooltip text on hover and SHALL be keyboard-focusable with accessible labels.

#### Scenario: Folder header actions are visible with tooltips
- **WHEN** a folder header is rendered on the canvas
- **THEN** the footer shows a latest-jump icon button and a first-jump icon button
- **AND** hovering each button shows tooltip text describing its action
- **AND** each button is exposed as an accessible control with a descriptive label

### Requirement: DataStore-Backed Jump Target Resolution
The system SHALL resolve jump targets for folder-header jump actions from DataStore-backed message bounds within the folder scope, rather than limiting targets to currently rendered day bands.

#### Scenario: Latest jump uses DataStore newest bound
- **GIVEN** a folder whose newest email is outside the currently rendered day range
- **WHEN** the user activates the latest-jump button
- **THEN** the system resolves the newest in-scope email node from DataStore-backed bounds
- **AND** the canvas navigates to that node once its day is renderable

#### Scenario: First jump uses DataStore oldest bound
- **GIVEN** a folder whose oldest email is outside the currently rendered day range
- **WHEN** the user activates the first-jump button
- **THEN** the system resolves the oldest in-scope email node from DataStore-backed bounds
- **AND** the canvas navigates to that node once its day is renderable

### Requirement: Responsive Range Expansion for Jump Actions
When a resolved jump target falls outside the rendered day range, the system SHALL expand day-window coverage incrementally and stop as soon as the target day is included, avoiding unbounded synchronous expansion that would stall interaction.

#### Scenario: Incremental expansion stops at target day
- **WHEN** a jump target day is older or newer than the currently rendered day window
- **THEN** day-window expansion proceeds in bounded increments toward the target day
- **AND** expansion stops immediately once the target day is included
- **AND** the system proceeds to scroll to the target node without requiring manual paging

#### Scenario: Jump controls avoid repeated heavy work while busy
- **WHEN** a jump action is already expanding coverage toward a target
- **THEN** additional activations for that folder are ignored or disabled until the active jump completes
- **AND** normal canvas interaction remains responsive during the in-progress jump
