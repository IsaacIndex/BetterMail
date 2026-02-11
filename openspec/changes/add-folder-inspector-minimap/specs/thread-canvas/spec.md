## ADDED Requirements
### Requirement: Folder Minimap Click Navigation
The system SHALL support folder-scoped canvas navigation requests initiated from the folder-details minimap. A minimap click SHALL attempt to navigate to the corresponding in-folder canvas location first; if that mapping is unstable or unavailable, the system SHALL navigate to the nearest renderable node that belongs to the same folder.

#### Scenario: Coordinate mapping succeeds
- **WHEN** the user clicks a minimap position that can be reliably mapped to a folder-local canvas target
- **THEN** the canvas navigates to the corresponding location for that folder
- **AND** the resulting target remains within the selected folder scope

#### Scenario: Coordinate mapping fallback to nearest node
- **WHEN** the user clicks a minimap position that cannot be mapped reliably to a valid folder-local canvas target
- **THEN** the system resolves the nearest renderable node in the selected folder
- **AND** navigates the canvas to that fallback node

#### Scenario: Target day is outside the current rendered range
- **WHEN** the minimap-resolved target is in a day band outside the currently rendered range
- **THEN** the system expands range coverage incrementally until the target becomes renderable
- **AND** then completes navigation without requiring manual paging
