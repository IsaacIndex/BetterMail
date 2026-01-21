## ADDED Requirements
### Requirement: Nested Folder Drag Targets
The system SHALL support dragging threads into or out of any folder depth on the canvas, treating each nested folder as its own drop target and updating membership accordingly.

#### Scenario: Drop into nested child
- **WHEN** the user drags a thread and drops it inside a child folder that sits within a parent folder
- **THEN** the thread moves into that child folder (not just the parent)
- **AND** the parent retains the child in its hierarchy

#### Scenario: Drag out of nested folder
- **WHEN** the user drags a thread out of a child folder and drops it on empty canvas
- **THEN** the thread is removed from that child folder while the hierarchy remains intact

#### Scenario: Nested folders as siblings and loose threads
- **WHEN** a parent folder contains multiple child folders and loose threads
- **THEN** drag/drop operations respect the exact hovered target: dropping on a child folder affects only that child, while dropping on the parent's open area affects the parent membership

### Requirement: Nested Folder Drop Highlighting
The system SHALL display a highlight with a brief entry pulse around the specific nested folder that is the active drop target, even when that folder is inside another folder's visual region.

#### Scenario: Pulse on nested target entry
- **WHEN** a drag enters the drop frame of a nested child folder
- **THEN** only that child's drop frame shows the pulsing highlight, and the parent highlight is suppressed

#### Scenario: Clear highlight on exit or other target
- **WHEN** the drag leaves the child folder's drop frame or enters a different folder
- **THEN** the previous highlight clears immediately and the new target (if any) pulses
