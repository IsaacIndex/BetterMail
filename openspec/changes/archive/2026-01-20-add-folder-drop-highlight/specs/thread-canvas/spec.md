## ADDED Requirements
### Requirement: Folder Drop Target Highlight
The system SHALL visually highlight a folder column while a thread drag is inside that folder's drop zone so users can confirm the drop target before releasing, including a brief entry pulse animation.

#### Scenario: Highlight while hovering folder area
- **WHEN** the user drags a thread node into the colored background area of a folder column (including its extended header zone)
- **THEN** a distinct border appears on top of that folder's background for as long as the pointer remains inside, with a brief pulse animation on entry
- **AND** the highlight clears immediately when the pointer leaves or the drag cancels/ends elsewhere

#### Scenario: Single active highlight
- **WHEN** multiple folder columns are visible
- **THEN** only the folder whose drop frame currently contains the drag pointer shows the highlight
