## ADDED Requirements
### Requirement: Folder Details Editing
The system SHALL allow users to edit a folder's title from a details panel surfaced from the canvas.

#### Scenario: Edit title from header click
- **WHEN** the user clicks a folder header on the canvas
- **THEN** a folder details panel opens in the inspector region
- **AND** the panel shows the current folder title in an editable field
- **AND** saving updates the folder title on the canvas

### Requirement: Folder Color Editing
The system SHALL allow users to update a folder's background color from the folder details panel with immediate visual feedback.

#### Scenario: Update folder color
- **WHEN** the user adjusts the color in the folder details panel
- **THEN** the folder's background on the canvas updates to match the new color
- **AND** the chosen color is persisted

### Requirement: Persist Edited Folder Details
The system SHALL persist edited folder titles and colors so they are restored after refreshes and relaunches.

#### Scenario: Relaunch retains edits
- **WHEN** the app is relaunched after editing a folder's title or color
- **THEN** the folder is restored with the edited title and color
