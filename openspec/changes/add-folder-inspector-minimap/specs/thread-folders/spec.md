## ADDED Requirements
### Requirement: Folder Details Minimap Section
The system SHALL display a dedicated minimap section in the folder details inspector that is separate from the scrollable folder edit content, so the minimap remains visible while users scroll name/color/summary fields.

#### Scenario: Minimap stays visible while details scroll
- **WHEN** a folder is selected and the user scrolls within folder details content
- **THEN** the minimap section remains visible in its own non-scrollable area
- **AND** only the editable details section scrolls

### Requirement: Folder Details Minimap Visual Simplicity
The system SHALL render the selected folder's email-node structure in the minimap using only circles (nodes) and lines (connections), without rendering full node cards or message metadata inside the minimap.

#### Scenario: Minimap uses primitive structure glyphs
- **WHEN** the folder details inspector renders the minimap
- **THEN** the minimap displays node positions as circles and relationships as lines
- **AND** it omits full node text blocks and rich canvas card UI
